import Foundation
import KWWKAI
import KWWKAgent

/// Internal implementation of the coding-agent TUI. Public entry points
/// live on `KWWK` (see KWWK.swift) and resolve credentials before calling
/// in here. `@MainActor` because `TranscriptRenderer`, `CodingStatusBar`,
/// and the TUI layout mutate main-thread-only state.
@MainActor
func runCodingTUIInternal(
    model: Model,
    modelLabel: String,
    cwd: String,
    tools: CodingTools,
    apiKeyResolver: (@Sendable (String) async -> String?)? = nil
) async throws {
    // --- agent + background manager -------------------------------------
    let bgManager = BackgroundTaskManager()
    let sessionId = UUID().uuidString
    let agent = await makeCodingAgent(CodingAgentConfig(
        model: model,
        cwd: cwd,
        tools: tools,
        backgroundManager: bgManager,
        sessionId: sessionId
    ))
    // Wire the OAuth resolver (Codex) so access tokens refresh on every
    // stream request. Nil for static api-key providers like Anthropic.
    if let apiKeyResolver {
        agent.apiKeyResolver = apiKeyResolver
    }

    // --- TUI (shared layout) --------------------------------------------
    // Inline render mode — the frame anchors at the current cursor and
    // preserves the user's shell scrollback above it (the Claude Code
    // behavior). Pass `useAlternateScreen: true` if you want a blank
    // fullscreen buffer instead.
    let runner = TUIRunner(useAlternateScreen: false, hideCursor: false)
    let layout = CodingLayout(statusRows: 2)
    let renderer = TranscriptRenderer()

    layout.header.lines = [
        Style.header("✻ kwwk coding agent"),
        Style.dimmed("  \(modelLabel)"),
        Style.dimmed("  \(shortenPath(cwd, to: max(20, runner.terminal.width - 4)))"),
    ]
    layout.install(into: runner.tui)
    layout.fitViewport(height: runner.terminal.height)
    runner.focus(layout.promptRow)
    _ = runner.terminal.onResize { _, h in
        Task { @MainActor in
            layout.fitViewport(height: h)
            runner.tui.requestRender()
        }
    }

    let statusBar = CodingStatusBar(
        layout: layout,
        runner: runner,
        agent: agent,
        bgManager: bgManager,
        sessionId: sessionId
    )
    await statusBar.render()

    _ = agent.subscribe { event, _ in
        await MainActor.run {
            renderer.apply(event)
            layout.setTranscript(renderer.lines.all)
            switch event {
            case .agentStart:
                statusBar.setMode(.streaming)
            case .agentEnd:
                statusBar.setMode(.idle)
            default: break
            }
            layout.fitViewport(height: runner.terminal.height)
            runner.tui.requestRender()
        }
        await statusBar.render()
    }

    runner.bind(.init("enter")) { _ in
        let text = layout.input.value
        guard !text.isEmpty else { return }
        layout.input.value = ""
        runner.tui.requestRender()
        Task.detached {
            do {
                try await agent.prompt(text)
            } catch {
                await MainActor.run {
                    layout.status.lines = [
                        Style.error("error: \(error)"),
                        Style.dimmed("  Esc: cancel / stop bg tasks · Ctrl-C: quit"),
                    ]
                    runner.tui.requestRender()
                }
            }
        }
    }

    // Ctrl-C: always exits (single tap). Keep it as the hard-stop key so
    // there's always a predictable way out.
    runner.bind(.ctrl("c")) { _ in
        Task { @MainActor in
            await agent.abortAndKillBackgroundTasks()
            runner.exit()
        }
    }

    // Esc: the primary "stop" key. Never exits — Ctrl-C is the only
    // way out of the app.
    //   1. While the agent is streaming → abort the current generation.
    //   2. While idle AND background tasks are running → kill them all.
    //   3. Otherwise → no-op.
    runner.bind(.init("escape")) { _ in
        if agent.state.isStreaming {
            agent.abort()
            Task { @MainActor in
                statusBar.setMode(.aborting)
                await statusBar.render()
            }
            return
        }
        Task { @MainActor in
            let running = await bgManager.list(sessionId: sessionId)
                .filter { $0.status == .running }.count
            if running > 0 {
                await bgManager.killAll(sessionId: sessionId)
                statusBar.flashKilled(count: running)
                await statusBar.render()
            }
            // No bg tasks, nothing streaming → Esc does nothing. The
            // user exits via Ctrl-C.
        }
    }

    // Periodic refresh so the background-task count stays live even when
    // there aren't any agent events firing. 500ms is invisibly slow for
    // a human but cheap (just an actor dict count).
    let pollTask = Task.detached {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await statusBar.render()
        }
    }
    defer { pollTask.cancel() }

    try await runner.run()

    // Shutdown cleanup: kill any still-running background tasks and
    // tear down the isolated tmux socket so we don't leak processes
    // after the user exits.
    pollTask.cancel()
    await agent.abortAndKillBackgroundTasks()
    await TmuxSessionManager.shared.teardown()
}

// MARK: - Helpers

private func shortenPath(_ path: String, to maxLen: Int) -> String {
    if path.count <= maxLen { return path }
    let head = path.prefix(maxLen / 2 - 1)
    let tail = path.suffix(maxLen / 2 - 2)
    return "\(head)…\(tail)"
}
