import Foundation
import KWWKAI

/// Result of resolving which LLM + credentials to use for this session.
/// The provider has already been registered on `APIRegistry.shared`.
struct ResolvedAuth: Sendable {
    let model: Model
    let modelLabel: String
    /// For OAuth-backed providers (Codex), an `apiKeyResolver` that calls
    /// back into `OAuthManager.apiKey(for:)` so tokens refresh on demand.
    /// Nil for static api-key providers (Anthropic).
    let apiKeyResolver: (@Sendable (String) async -> String?)?
}

enum AuthResolveError: Error, LocalizedError {
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return """
            No credentials configured.

            Either:
              • Run `kwwk login` to log in with ChatGPT (Codex subscription).
              • Set ANTHROPIC_API_KEY to use Claude.
            """
        }
    }
}

/// Resolve credentials in priority order:
///   1. OAuth store has `openai-codex`  → ChatGPT Codex (gpt-5.4)
///   2. `ANTHROPIC_API_KEY` env var set → Anthropic
///   3. Throw a clear error.
///
/// Registers the chosen provider on `APIRegistry.shared` as a side effect so
/// the returned model can be used immediately.
func resolveAgentAuth() async throws -> ResolvedAuth {
    let store = OAuthStore()

    if let codex = await store.get("openai-codex") {
        return await registerCodex(store: store, creds: codex)
    }

    let env = ProcessInfo.processInfo.environment
    if let apiKey = env["ANTHROPIC_API_KEY"], !apiKey.isEmpty {
        return await registerAnthropic(apiKey: apiKey, env: env)
    }

    throw AuthResolveError.noCredentials
}

// MARK: - Codex

private func registerCodex(
    store: OAuthStore,
    creds: OAuthCredentials
) async -> ResolvedAuth {
    let manager = OAuthManager(store: store)
    // Grab a fresh token if expired. If the refresh fails we still register
    // the provider — the apiKeyResolver below will retry on the next request
    // and surface the error to the user there.
    _ = try? await manager.apiKey(for: "openai-codex")

    let refreshed = await store.get("openai-codex") ?? creds
    let accountId: String? = {
        if case .string(let s) = refreshed.extras["accountId"] ?? .null { return s }
        return nil
    }()

    // Register with a nil defaultAPIKey — the agent's apiKeyResolver will
    // supply a fresh token on every request, giving us automatic refresh
    // across long sessions.
    await APIRegistry.shared.register(ProviderVariants.chatgptCodex(
        accessToken: nil,
        accountId: accountId,
        originator: "kwwk"
    ))

    // Pull the default model from the bundled catalog (routing fields
    // overridden for the `chatgpt-codex` provider variant). This keeps
    // input modalities + contextWindow in sync with the canonical
    // upstream data — e.g. gpt-5.4 is multimodal `[text, image]`, not
    // text-only as the initial hardcoded definition claimed.
    let catalogEntry = ModelsCatalog.model(provider: "openai-codex", id: "gpt-5.4")
    let model = Model(
        id: "gpt-5.4",
        name: catalogEntry?.name ?? "gpt-5.4",
        api: "chatgpt-codex",
        provider: "chatgpt-codex",
        baseUrl: "https://chatgpt.com",
        reasoning: catalogEntry?.reasoning ?? true,
        input: catalogEntry?.input ?? [.text, .image],
        contextWindow: catalogEntry?.contextWindow ?? 272_000,
        // Codex rejects max_output_tokens — setting to 0 skips emitting
        // the field in the request body regardless of what the catalog
        // reports.
        maxTokens: 0
    )

    let resolver: @Sendable (String) async -> String? = { _ in
        try? await manager.apiKey(for: "openai-codex")
    }

    return ResolvedAuth(
        model: model,
        modelLabel: "gpt-5.4 · ChatGPT Codex",
        apiKeyResolver: resolver
    )
}

// MARK: - Anthropic

private func registerAnthropic(
    apiKey: String,
    env: [String: String]
) async -> ResolvedAuth {
    let modelId = env["ANTHROPIC_MODEL"] ?? "claude-sonnet-4-5-20250929"
    let baseURL = env["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"

    await APIRegistry.shared.register(AnthropicProvider(defaultAPIKey: apiKey))

    let model = Model(
        id: modelId,
        name: modelId,
        api: "anthropic-messages",
        provider: "anthropic",
        baseUrl: baseURL,
        reasoning: false,
        input: [.text, .image],
        contextWindow: 200_000,
        maxTokens: 8192
    )

    return ResolvedAuth(
        model: model,
        modelLabel: modelId,
        apiKeyResolver: nil
    )
}
