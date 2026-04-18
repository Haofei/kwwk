import Foundation
import KWWKAI
import KWWKAgent

/// Register the V1 set of builtin slash commands on `registry`. Keep these
/// focused on things a user actually needs mid-session; heavier flows
/// (login, config persistence) live on the `kwwk` binary instead.
@MainActor
func registerBuiltinSlashCommands(_ registry: SlashCommandRegistry) {
    registry.register(SlashCommand(
        name: "model",
        description: "Pick a model for this session",
        handler: handleModelCommand
    ))
    registry.register(SlashCommand(
        name: "compact",
        description: "Summarize the transcript to reclaim context",
        handler: handleCompactCommand
    ))
    registry.register(SlashCommand(
        name: "queue",
        description: "Show or clear the steering-message queue",
        handler: handleQueueCommand
    ))
    registry.register(SlashCommand(
        name: "help",
        description: "List available slash commands",
        handler: { ctx, _ in
            ctx.notify(Style.dimmed("  available slash commands:"))
            for cmd in registry.all {
                ctx.notify(Style.dimmed("    /\(cmd.name) — \(cmd.description)"))
            }
        }
    ))
}

/// `/model` — opens a modal with every model the currently-authenticated
/// provider supports. Selection updates `agent.state.model` for the next
/// LLM request; the swap is session-scoped (restart = back to default).
///
/// Cross-provider switching (Codex → Anthropic or vice versa) needs a
/// second provider registered on APIRegistry at startup, which is out of
/// scope for V1.
@MainActor
private func handleModelCommand(_ ctx: SlashContext, _ args: String) async {
    let current = ctx.agent.state.model
    let agentProvider = current.provider
    let catalogKey = catalogProviderKey(forAgentProvider: agentProvider)

    let available = ModelsCatalog.models(for: catalogKey)
        .sorted { $0.id < $1.id }

    if available.isEmpty {
        ctx.notify(Style.error("  /model: no catalog entries for provider '\(agentProvider)'"))
        return
    }

    let modal = ModelSelectorModal(
        title: "Select a model  (provider: \(agentProvider))",
        models: available,
        currentModelId: current.id,
        onSelect: { [agent = ctx.agent, notify = ctx.notify, modal = ctx.modal] picked in
            let rebuilt = adoptFields(from: current, into: picked)
            agent.state.model = rebuilt
            modal.close()
            if picked.id == current.id {
                notify(Style.dimmed("  /model: already on \(picked.id)"))
            } else {
                notify(Style.dimmed("  /model: switched \(current.id) → \(picked.id)"))
            }
        },
        onCancel: { [modal = ctx.modal, notify = ctx.notify] in
            modal.close()
            notify(Style.dimmed("  /model: cancelled"))
        }
    )
    ctx.modal.open(modal)
}

/// Map an in-session agent `Model.provider` to the key used in
/// `ModelsCatalog.byProvider`. They're mostly identical except for Codex:
/// the chatgpt.com variant registers as `chatgpt-codex` on the agent side,
/// while the catalog lists its models under `openai-codex`.
/// Internal (not private) so regression tests can pin the mapping.
func catalogProviderKey(forAgentProvider provider: String) -> String {
    switch provider {
    case "chatgpt-codex": return "openai-codex"
    default: return provider
    }
}

/// Carry the current-session provider routing (api string, baseUrl, any
/// custom headers) over from the old model onto the newly-selected one.
/// The catalog lists models by their canonical provider (`openai-codex`),
/// but the live agent uses a provider-variant routing key
/// (`chatgpt-codex`, the Codex endpoint we registered at startup). Without
/// this copy the first request after a switch would hit the wrong
/// `APIRegistry` entry or try to call the canonical OpenAI endpoint that
/// we never registered a token for.
/// Internal (not private) so regression tests can pin the sentinel logic.
func adoptFields(from current: Model, into picked: Model) -> Model {
    // `maxTokens = 0` is a sentinel used by AuthResolver for Codex ("do
    // not emit max_output_tokens — the endpoint rejects it"). Preserve
    // the sentinel when switching inside the Codex provider; otherwise
    // adopt the picked model's real cap so we don't leak an unrelated
    // model's limit onto the new request.
    let resolvedMaxTokens = current.maxTokens == 0 ? 0 : picked.maxTokens
    return Model(
        id: picked.id,
        name: picked.name,
        api: current.api,
        provider: current.provider,
        baseUrl: current.baseUrl,
        reasoning: picked.reasoning,
        input: picked.input,
        cost: picked.cost,
        contextWindow: picked.contextWindow,
        maxTokens: resolvedMaxTokens,
        headers: current.headers
    )
}

// MARK: - /queue

/// `/queue` (no args) — list any steering messages waiting to be injected
/// at the next turn boundary. Use `/queue clear` (or `/queue cancel`) to
/// drop them. Queued messages are created implicitly when the user hits
/// Enter while the agent is streaming or auto-compacting.
@MainActor
private func handleQueueCommand(_ ctx: SlashContext, _ args: String) async {
    let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch trimmed {
    case "clear", "cancel", "drop":
        let dropped = ctx.agent.queuedSteeringCount()
        if dropped == 0 {
            ctx.notify(Style.dimmed("  /queue: nothing queued"))
            return
        }
        ctx.agent.clearSteeringQueue()
        ctx.notify(Style.prompt("  /queue: cleared \(dropped) queued \(dropped == 1 ? "message" : "messages")"))
    case "":
        let messages = ctx.agent.queuedSteeringMessages()
        if messages.isEmpty {
            ctx.notify(Style.dimmed("  /queue: nothing queued"))
            return
        }
        ctx.notify(Style.dimmed("  /queue: \(messages.count) waiting for the next turn boundary"))
        for (i, msg) in messages.enumerated() {
            let body = previewQueuedMessage(msg)
            ctx.notify(Style.dimmed("    \(i + 1). \(body)"))
        }
        ctx.notify(Style.dimmed("    (use /queue clear to drop them)"))
    default:
        ctx.notify(Style.error("  /queue: unknown arg '\(args)'. Try /queue or /queue clear"))
    }
}

/// One-line preview of a queued message for the `/queue` listing.
/// Truncates long bodies and flattens multi-line text so the listing
/// stays tidy.
private func previewQueuedMessage(_ msg: Message, max: Int = 80) -> String {
    let raw: String = {
        switch msg {
        case .user(let u):
            return u.content.compactMap { block -> String? in
                if case .text(let t) = block { return t.text }
                return nil
            }.joined(separator: " ")
        default:
            return "(\(msg.role.rawValue) message)"
        }
    }()
    let flat = raw.replacingOccurrences(of: "\n", with: " ")
    return flat.count <= max ? flat : String(flat.prefix(max)) + "…"
}

// MARK: - /compact

/// `/compact` — thin wrapper around `performCompact` (see CompactRunner.swift)
/// that surfaces each outcome as a dimmed transcript notification. The
/// auto-compact driver calls the same `performCompact` so the two
/// entry points produce bit-identical recap messages.
@MainActor
private func handleCompactCommand(_ ctx: SlashContext, _ args: String) async {
    let snapshot = ctx.agent.state.messages
    if !ctx.agent.state.isStreaming && snapshot.count >= compactMinMessages {
        ctx.notify(Style.dimmed("  /compact: summarizing \(snapshot.count) messages…"))
    }

    let outcome = await performCompact(
        agent: ctx.agent,
        backgroundManager: ctx.backgroundManager,
        sessionId: ctx.sessionId
    )

    switch outcome {
    case .refusedAgentBusy:
        ctx.notify(Style.error("  /compact: agent is busy; stop it first (Esc)"))
    case .refusedTooFewMessages(let count):
        ctx.notify(Style.dimmed("  /compact: only \(count) message(s); nothing to compact"))
    case .compacted(let n, let hasLedger):
        var note = "  /compact: compacted \(n) messages → 1 recap"
        if hasLedger { note += " (+ running-task ledger)" }
        ctx.notify(Style.prompt(note))
    case .failed(let msg):
        ctx.notify(Style.error("  /compact: \(msg)"))
    }
}
