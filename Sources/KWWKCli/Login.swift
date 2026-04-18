import Foundation
import KWWKAI

/// Providers shown in the `kwwk login` selector. Order is the display order.
private let loginProviders: [(id: String, display: String)] = [
    ("openai-codex",      "ChatGPT Codex (OpenAI Plus/Pro subscription)"),
    ("anthropic",         "Anthropic (Claude Pro/Max)"),
    ("google-gemini-cli", "Gemini CLI (Google Cloud Code Assist)"),
    ("github-copilot",    "GitHub Copilot"),
]

enum LoginError: Error, LocalizedError {
    case cancelled
    case unknownProvider(String)
    case oauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "login cancelled"
        case .unknownProvider(let id): return "unknown provider '\(id)'"
        case .oauthFailed(let msg): return "OAuth flow failed: \(msg)"
        }
    }
}

/// Interactive `kwwk login`:
///   1. Arrow-key selector over the known OAuth providers.
///   2. Enter → tear down the TUI and run the chosen provider's OAuth flow
///      (browser + localhost callback server for PKCE, or device flow for
///      Copilot).
///   3. Persist the resulting credentials to `~/.kw/oauth.json`.
///
/// The TUI is intentionally torn down before the OAuth flow begins so that
/// the browser handoff + stderr progress logs don't fight the raw-mode
/// terminal.
func runLoginInternal() async throws {
    let choice = try await selectProviderTUI()
    try await runOAuthFlow(providerId: choice)
}

// MARK: - Selector TUI

/// Small arrow-key selector built on top of TUIRunner. Returns the chosen
/// provider id, or throws `.cancelled` if the user hits Esc / Ctrl-C.
@MainActor
private func selectProviderTUI() async throws -> String {
    let runner = TUIRunner(useAlternateScreen: false, hideCursor: true)

    let header = TextComponent([
        Style.header("✻ kwwk login"),
        Style.dimmed("  choose a provider to log in"),
        "",
    ])
    let menu = TextComponent([])
    let footer = TextComponent([
        "",
        Style.dimmed("  ↑/↓: move   Enter: select   Esc/Ctrl-C: cancel"),
    ])

    let state = SelectorState(count: loginProviders.count)

    renderSelectorMenu(into: menu, state: state)

    runner.tui.addChild(header)
    runner.tui.addChild(menu)
    runner.tui.addChild(footer)

    runner.bind(.init("up")) { _ in
        Task { @MainActor in
            state.selectedIndex = (state.selectedIndex - 1 + loginProviders.count) % loginProviders.count
            renderSelectorMenu(into: menu, state: state)
            runner.tui.requestRender()
        }
    }
    runner.bind(.init("down")) { _ in
        Task { @MainActor in
            state.selectedIndex = (state.selectedIndex + 1) % loginProviders.count
            renderSelectorMenu(into: menu, state: state)
            runner.tui.requestRender()
        }
    }
    runner.bind(.init("enter")) { _ in
        Task { @MainActor in
            state.submit(state.selectedIndex)
            runner.exit()
        }
    }
    runner.bind(.init("escape")) { _ in
        Task { @MainActor in
            state.cancel()
            runner.exit()
        }
    }
    runner.bind(.ctrl("c")) { _ in
        Task { @MainActor in
            state.cancel()
            runner.exit()
        }
    }

    try await runner.run()

    guard let idx = state.chosen else { throw LoginError.cancelled }
    return loginProviders[idx].id
}

/// Mutable state shared between the key handlers and the caller.
@MainActor
private final class SelectorState {
    var selectedIndex: Int = 0
    var chosen: Int?
    let count: Int
    init(count: Int) { self.count = count }
    func submit(_ index: Int) { chosen = index }
    func cancel() { chosen = nil }
}

/// Regenerate the `menu` component's line strings based on the current
/// `state.selectedIndex`. Pulled out as a module-level function (rather than a
/// nested `func` inside `selectProviderTUI`) so the `@Sendable` key-binding
/// closures can invoke it without capturing a non-Sendable function
/// reference.
@MainActor
private func renderSelectorMenu(into menu: TextComponent, state: SelectorState) {
    menu.lines = loginProviders.enumerated().map { i, provider in
        let marker = i == state.selectedIndex ? Style.prompt("  ❯ ") : "    "
        let label  = i == state.selectedIndex ? Style.prompt(provider.display) : provider.display
        return marker + label
    }
    menu.invalidate()
}

// MARK: - OAuth flow dispatch

private func runOAuthFlow(providerId: String) async throws {
    // Clear a line so the OAuth progress logs start fresh below the TUI.
    FileHandle.standardError.write(Data("\nstarting \(providerId) login…\n".utf8))

    let credentials: OAuthCredentials
    do {
        switch providerId {
        case "anthropic":
            credentials = try await OAuthLogin.loginAnthropic()
        case "openai-codex":
            credentials = try await OAuthLogin.loginOpenAICodex()
        case "google-gemini-cli":
            credentials = try await OAuthLogin.loginGeminiCLI()
        case "github-copilot":
            credentials = try await OAuthLogin.loginGitHubCopilot()
        default:
            throw LoginError.unknownProvider(providerId)
        }
    } catch {
        throw LoginError.oauthFailed(error.localizedDescription)
    }

    let store = OAuthStore()
    try await store.set(credentials, for: providerId)
    let path = await store.url.path
    print("")
    print(Style.prompt("✓ saved \(providerId) credentials"))
    print(Style.dimmed("  → \(path)"))
}
