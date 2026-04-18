import Foundation
import KWWKAgent

/// Two-line status bar with dynamic state + static keyboard hints.
///
///   row 1: ● generating… · Esc to cancel
///          ○ 3 background tasks running · Esc to stop them
///          ready
///          killed 2 background tasks (flashes briefly)
///   row 2: Esc: cancel generation / stop bg tasks · Ctrl-C: quit
///
/// The bar is re-rendered on agent events AND on a poll timer (so background
/// task counts stay live even when the agent is idle).
@MainActor
final class CodingStatusBar {
    enum Mode { case idle, streaming, aborting, flashing }

    private let layout: CodingLayout
    private let runner: TUIRunner
    private let agent: Agent
    private let bgManager: BackgroundTaskManager
    private let sessionId: String
    private var mode: Mode = .idle
    private var flashText: String?
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
    }

    func setMode(_ mode: Mode) { self.mode = mode }

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

        let line1: String
        if let flash = flashText {
            line1 = Style.dimmed(flash)
        } else if mode == .aborting {
            // Aborting takes precedence over streaming: after `agent.abort()`
            // fires, `isStreaming` stays true for a beat until agentEnd
            // lands, but we want the user to see "aborting…" immediately.
            line1 = Style.running("● aborting…") + " " +
                Style.dimmed("· Ctrl-C to force quit")
        } else if isStreaming {
            var parts = [Style.running("● generating…")]
            parts.append(Style.dimmed("· Esc to cancel"))
            if running > 0 {
                parts.append(Style.dimmed("· \(running) bg \(running == 1 ? "task" : "tasks") running"))
            }
            line1 = parts.joined(separator: " ")
        } else if running > 0 {
            let noun = running == 1 ? "task" : "tasks"
            line1 = Style.dimmed("○ \(running) background \(noun) running") + " " +
                Style.dimmed("· Esc to stop them")
        } else {
            line1 = Style.dimmed("ready")
        }

        let line2 = Style.dimmed("  Esc: cancel generation / stop bg tasks · Ctrl-C: quit")
        let newLines = [line1, line2]
        if newLines != lastRenderedLines {
            lastRenderedLines = newLines
            layout.status.lines = newLines
            runner.tui.requestRender()
        }
    }
}
