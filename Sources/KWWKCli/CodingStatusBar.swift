import Foundation
import KWWKAgent

/// One-line state bar. The line itself carries the contextual keyboard
/// hint so we don't burn a second row on a static "Ctrl-C: quit" banner.
///
///   ● generating…  · Esc to cancel  · N bg tasks running
///   ● aborting…    · Ctrl-C to force quit
///   ○ 3 background tasks running  · Esc to stop them
///   killed 2 background tasks    (flashes briefly)
///   (blank)                       when idle with nothing running
///
/// The bar is re-rendered on agent events AND on a poll timer (so background
/// task counts stay live even when the agent is idle).
@MainActor
final class CodingStatusBar {
    enum Mode { case idle, streaming, aborting, flashing, compacting, retrying }

    private let layout: CodingLayout
    private let runner: TUIRunner
    private let agent: Agent
    private let bgManager: BackgroundTaskManager
    private let sessionId: String
    private let terminal: Terminal
    private var mode: Mode = .idle
    private var flashText: String?
    /// Count of messages the auto-compact driver is rolling up. Displayed
    /// in the status line while `mode == .compacting`.
    private var compactingMessageCount: Int = 0
    /// Payload for `mode == .retrying`. `until` is an absolute deadline so
    /// the 500ms poll re-renders a live countdown without needing a
    /// dedicated timer. Populated via `setRetrying(...)`.
    private var retryInfo: (attempt: Int, until: Date, reason: String)?
    /// Optional capacity suffix (e.g. `42% ctx`) appended to the status
    /// line when non-empty. Updated by the auto-compact controller via
    /// `setCapacityHint`.
    private var capacityHint: String = ""
    private var lastRenderedLines: [String] = []

    init(
        layout: CodingLayout,
        runner: TUIRunner,
        agent: Agent,
        bgManager: BackgroundTaskManager,
        sessionId: String
    ) {
        self.layout = layout
        self.runner = runner
        self.agent = agent
        self.bgManager = bgManager
        self.sessionId = sessionId
        self.terminal = runner.terminal
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        if mode != .retrying { retryInfo = nil }
    }

    /// Enter the retrying state. The bar shows a live countdown on the
    /// existing 500ms poll tick. `attempt` is the zero-indexed attempt
    /// that just failed (so `attempt: 0` means the first request failed
    /// and we're scheduling attempt #2).
    func setRetrying(attempt: Int, delayMs: UInt64, reason: String) {
        mode = .retrying
        retryInfo = (
            attempt: attempt,
            until: Date().addingTimeInterval(Double(delayMs) / 1000.0),
            reason: reason
        )
    }

    /// Update the capacity suffix (`42% ctx` or the alert form when the
    /// threshold is crossed). Pass the empty string to hide it. Does not
    /// re-render — callers typically follow with `render()` anyway.
    func setCapacityHint(_ hint: String) {
        capacityHint = hint
    }

    /// Enter/leave the auto-compact "busy" state. `count` is the number
    /// of messages being rolled up; surfaced in the status line so the
    /// user sees what caused the pause.
    func setCompacting(messageCount: Int) {
        mode = .compacting
        compactingMessageCount = messageCount
    }

    func flashKilled(count: Int) {
        let noun = count == 1 ? "task" : "tasks"
        flashText = "killed \(count) background \(noun)"
        mode = .flashing
        // Auto-clear the flash after ~1s.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            await MainActor.run {
                self.flashText = nil
                if self.mode == .flashing { self.mode = .idle }
            }
            await self.render()
        }
    }

    /// Recompute the two status lines and re-render.
    func render() async {
        let running = await bgManager.list(sessionId: sessionId)
            .filter { $0.status == .running }.count
        let isStreaming = agent.state.isStreaming

        // Contextual state + hint on a single line. When the agent is
        // idle and no background tasks are running, the line is blank —
        // there's nothing for the user to act on, so don't add visual
        // chrome. The row is still reserved by the layout so everything
        // below it (prompt, divider) doesn't jitter.
        // Queue visibility lives in its own panel above the prompt
        // (see `refreshQueuePanel` in CodingTUI.swift). The status bar
        // stays focused on "what's the agent doing right now" so the
        // two lines don't compete for eyeballs.
        let line: String
        if mode == .compacting {
            // Takes precedence over every other state: while compacting,
            // the agent itself is idle but we don't want the user to
            // type a prompt that would race the message replacement.
            line = Style.running("◐ auto-compacting \(compactingMessageCount) messages…") + " " +
                Style.dimmed("· new prompts will queue")
        } else if let flash = flashText {
            line = Style.dimmed(flash)
        } else if mode == .aborting {
            // Aborting takes precedence over streaming: after `agent.abort()`
            // fires, `isStreaming` stays true for a beat until agentEnd
            // lands, but we want the user to see "aborting…" immediately.
            line = Style.running("● aborting…") + " " +
                Style.dimmed("· Ctrl-C to force quit")
        } else if mode == .retrying, let info = retryInfo {
            let remaining = max(0, info.until.timeIntervalSinceNow)
            // "retry N/M in Xs" — N is the upcoming attempt (1-indexed),
            // M is the total attempt cap. reason is trimmed to keep the
            // status row single-line.
            let upcoming = info.attempt + 2
            let total = 5 // keep in sync with AgentLoop.maxRetries
            let countdown: String
            if remaining >= 1.0 {
                countdown = "\(Int(remaining.rounded(.up)))s"
            } else {
                countdown = "now"
            }
            let trimmedReason = info.reason.prefix(60)
            var parts = [
                Style.running("⟳ retry \(upcoming)/\(total) in \(countdown)"),
                Style.dimmed("· \(trimmedReason)"),
                Style.dimmed("· Esc to cancel"),
            ]
            if running > 0 {
                parts.append(Style.dimmed("· \(running) bg \(running == 1 ? "task" : "tasks") running"))
            }
            line = parts.joined(separator: " ")
        } else if isStreaming {
            var parts = [Style.running("● generating…")]
            parts.append(Style.dimmed("· Esc to cancel"))
            if running > 0 {
                parts.append(Style.dimmed("· \(running) bg \(running == 1 ? "task" : "tasks") running"))
            }
            line = parts.joined(separator: " ")
        } else if running > 0 {
            let noun = running == 1 ? "task" : "tasks"
            line = Style.dimmed("○ \(running) background \(noun) running") + " " +
                Style.dimmed("· Esc to stop them")
        } else {
            // Idle, no background tasks — nothing to surface.
            line = ""
        }

        // Right-align the capacity hint so the status row reads as a
        // balanced band: state/hints hug the left edge, `42% ctx` hugs
        // the right edge. When only one side has content the other side
        // is empty padding — visually that still reads as a single
        // working line instead of "mostly empty space".
        let fullLine = padBetween(
            left: line,
            right: capacityHint,
            width: terminal.width
        )

        let newLines = [fullLine]
        if newLines != lastRenderedLines {
            lastRenderedLines = newLines
            layout.status.lines = newLines
            runner.tui.requestRender()
        }
    }
}

/// Pad `left` and `right` out to `width` visible columns so `right` sits
/// at the right edge and `left` at the left. Falls back to either side
/// alone when the other is empty. If the two together already exceed the
/// width we concatenate with a single space — truncation is left to the
/// TUI's per-line width-clip.
func padBetween(left: String, right: String, width: Int) -> String {
    if left.isEmpty && right.isEmpty { return "" }
    if right.isEmpty { return left }
    if left.isEmpty {
        let pad = max(0, width - ANSI.visibleWidth(right))
        return String(repeating: " ", count: pad) + right
    }
    let combined = ANSI.visibleWidth(left) + ANSI.visibleWidth(right)
    if combined + 1 >= width {
        return left + " " + right
    }
    let spaces = width - combined
    return left + String(repeating: " ", count: spaces) + right
}
