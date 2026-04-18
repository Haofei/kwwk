import Foundation
import KWWKAI
import KWWKAgent

/// Watches each turn's reported token usage and triggers
/// `performCompact` when the transcript approaches the model's
/// `contextWindow`. Fires only on `agentEnd` — compacting mid-turn
/// would replace `agent.state.messages` while the agent loop is still
/// referencing them, so we wait until the loop is fully idle.
///
/// Usage math:
///   tokens  = last assistant `usage.input + usage.output`
///   window  = `agent.state.model.contextWindow`
///   ratio   = tokens / window
///
/// `usage.input` already reflects the cumulative transcript the LLM
/// was shown (system prompt + prior turns). Adding `output` gives
/// the size the next request's baseline would be before a new user
/// prompt is appended — the most honest "how full is the window right
/// now?" read we have without tokenizing ourselves.
@MainActor
final class AutoCompactController {

    struct Usage: Equatable, Sendable {
        let tokens: Int
        let window: Int
        var ratio: Double { window > 0 ? Double(tokens) / Double(window) : 0 }
    }

    /// Coarse status the UI can render. The actual compact flow goes
    /// through `performCompact`, whose outcome is surfaced separately
    /// via `onCompactFinished` so callers can notify the transcript.
    enum Status: Equatable {
        case idle
        case compacting(messagesCount: Int)
    }

    let agent: Agent
    let backgroundManager: BackgroundTaskManager
    let sessionId: String
    /// `nil` disables the controller entirely. A value in [0, 1] is a
    /// ratio; e.g. `0.75` fires at 75% context utilization.
    let threshold: Double?
    let onStatusChange: @MainActor (Status) -> Void
    let onUsageChange: @MainActor (Usage) -> Void
    let onCompactFinished: @MainActor (CompactOutcome) -> Void

    private(set) var isCompacting: Bool = false
    private(set) var lastUsage: Usage = Usage(tokens: 0, window: 0)

    init(
        agent: Agent,
        backgroundManager: BackgroundTaskManager,
        sessionId: String,
        threshold: Double?,
        onStatusChange: @MainActor @escaping (Status) -> Void,
        onUsageChange: @MainActor @escaping (Usage) -> Void,
        onCompactFinished: @MainActor @escaping (CompactOutcome) -> Void
    ) {
        self.agent = agent
        self.backgroundManager = backgroundManager
        self.sessionId = sessionId
        self.threshold = threshold
        self.onStatusChange = onStatusChange
        self.onUsageChange = onUsageChange
        self.onCompactFinished = onCompactFinished
    }

    /// Recompute usage from the most recent assistant turn's reported
    /// token counts.
    func currentUsage() -> Usage {
        var lastAssistant: AssistantMessage?
        for message in agent.state.messages.reversed() {
            if case .assistant(let a) = message {
                lastAssistant = a
                break
            }
        }
        let tokens = (lastAssistant?.usage.input ?? 0) + (lastAssistant?.usage.output ?? 0)
        let window = agent.state.model.contextWindow
        return Usage(tokens: tokens, window: window)
    }

    /// Agent event hook. Wire into `agent.subscribe` — we refresh the
    /// usage reading on every event so the capacity display stays live
    /// (and snaps to zero after /compact), and fire the threshold check
    /// only on `.agentEnd` (see note on the type doc).
    func observe(_ event: AgentEvent) async {
        let usage = currentUsage()
        if usage != lastUsage {
            lastUsage = usage
            onUsageChange(usage)
        }
        if case .agentEnd = event {
            await maybeCompact()
        }
    }

    /// Decides whether a compact should fire right now and runs it if
    /// so. Preconditions enforced here (so the pure `performCompact`
    /// stays unaware of threshold semantics):
    ///   - threshold is non-nil and > 0
    ///   - not already running a compact
    ///   - ratio has actually crossed the threshold (window > 0)
    private func maybeCompact() async {
        guard let threshold, threshold > 0, !isCompacting else { return }
        let usage = currentUsage()
        guard usage.window > 0, usage.ratio >= threshold else { return }
        let snapshotCount = agent.state.messages.count
        isCompacting = true
        onStatusChange(.compacting(messagesCount: snapshotCount))
        let outcome = await performCompact(
            agent: agent,
            backgroundManager: backgroundManager,
            sessionId: sessionId
        )
        isCompacting = false
        onCompactFinished(outcome)
        // Usage drops to whatever the recap weighs; push a fresh
        // reading so the header update isn't stuck at the pre-compact
        // value.
        let newUsage = currentUsage()
        lastUsage = newUsage
        onUsageChange(newUsage)
        onStatusChange(.idle)
    }
}

// MARK: - Header formatting

/// Format a capacity suffix for the header's model line. Returns "" when
/// we can't usefully report anything (no window, no usage yet), a muted
/// `42% ctx` when comfortably below threshold, or a yellow
/// `● 78% ctx · auto-compact at 75%` when a compact will or just did
/// fire.
func formatCapacityHint(usage: AutoCompactController.Usage, threshold: Double?) -> String {
    guard usage.window > 0, usage.tokens > 0 else { return "" }
    let pct = Int((usage.ratio * 100).rounded(.down))
    let body = "\(pct)% ctx"
    if let threshold, usage.ratio >= threshold {
        let thresholdPct = Int((threshold * 100).rounded(.down))
        return Style.running("● \(body)") + " " + Style.dimmed("· auto-compact at \(thresholdPct)%")
    }
    return Style.dimmed(body)
}
