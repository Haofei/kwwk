import Foundation
import KWAI
import KWAgent
import KWCoding

/// End-to-end harness: drives a real Codex-backed agent through the coding
/// agent's background-task features. Uses the ChatGPT subscription via
/// `~/.codex/auth.json`.
///
/// Scenarios (auto-detected; skipped when infra isn't available):
///   1. Explicit run_in_background=true
///   2. Foreground soft timeout → auto-background flip
///   3. bg_status list / status flow
///   4. tmux TUI interaction (gated on `tmux` being on PATH)
///
/// Exit code: 0 on all-green, 1 on any failure.
@main
struct BackgroundE2E {
    static func main() async {
        let runner = E2ERunner()
        await runner.run()
        Foundation.exit(runner.exitCode)
    }
}

// MARK: - Runner

@MainActor
final class E2ERunner {
    var results: [(name: String, passed: Bool, detail: String)] = []
    var exitCode: Int32 { results.allSatisfy { $0.passed } ? 0 : 1 }

    func run() async {
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("kw-e2e-bg — end-to-end coding agent harness")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        let creds: CodexCreds.Credentials
        do {
            creds = try CodexCreds.load()
        } catch {
            print("✖ failed to load Codex credentials: \(error.localizedDescription)")
            results.append(("setup", false, "\(error)"))
            return
        }
        print("✓ loaded Codex credentials")
        if let exp = creds.expiresAt {
            let now = Int64(Date().timeIntervalSince1970)
            let remainDays = Double(exp - now) / 86400
            print(String(format: "  access_token expires in %.1f days", remainDays))
        }
        print("  account_id: \(creds.accountId)")

        // Register the Codex-routed Responses provider.
        await APIRegistry.shared.register(
            ProviderVariants.chatgptCodex(
                accessToken: creds.accessToken,
                accountId: creds.accountId,
                originator: "kw-e2e-bg"
            )
        )

        // Run scenarios sequentially. Each one builds its own agent + manager
        // so they don't cross-contaminate.
        await runScenario("explicit run_in_background=true", runExplicitBackground)
        await runScenario("auto-background on soft timeout", runAutoBackground)
        await runScenario("bg_status list + status", runBgStatus)
        await runScenario("tmux TUI interaction (optional)", runTmux)

        // Summary
        print("")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("summary")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        let width = max(40, (results.map { $0.name.count }.max() ?? 40) + 4)
        for r in results {
            let mark = r.passed ? "✓" : "✖"
            let padded = r.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(mark) \(padded) \(r.detail)")
        }
        let passed = results.filter { $0.passed }.count
        let total = results.count
        print("")
        print("\(passed)/\(total) scenarios passed")
    }

    func runScenario(_ name: String, _ body: () async -> (Bool, String)) async {
        print("")
        print("▶ \(name)")
        let (ok, detail) = await body()
        let mark = ok ? "✓" : "✖"
        print("\(mark) \(name) — \(detail)")
        results.append((name, ok, detail))
    }

    // MARK: - Scenario: explicit background

    func runExplicitBackground() async -> (Bool, String) {
        let outputDir = tempDir("explicit-bg")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwd = tempDir("cwd-explicit-bg")
        defer { try? FileManager.default.removeItem(at: cwd) }

        let bgManager = BackgroundTaskManager(outputDir: outputDir)
        let sessionId = "explicit-bg-\(UUID().uuidString.prefix(6))"

        let (agent, recorder, detach) = await buildAgent(
            bgManager: bgManager,
            sessionId: sessionId,
            cwd: cwd.path
        )
        defer { Task { await detach() } }

        let prompt = """
        Please run this shell command in the background: `sleep 2 && echo completed-scenario-1`.
        Use the bash tool with run_in_background=true since the command is long-running.
        After it's started, just confirm to me briefly that you kicked off the task — don't wait for it to finish in this turn.
        """
        let runErr = await safeRun(agent: agent, prompt: prompt, timeout: 60)
        if let runErr {
            return (false, "agent run failed: \(runErr)")
        }

        let bashCalls = await recorder.toolCallsByName("bash")
        let ranInBg = bashCalls.contains { tc in
            if case .object(let obj) = tc.arguments,
               case .bool(let v) = obj["run_in_background"] ?? .null {
                return v == true
            }
            return false
        }
        if !ranInBg {
            return (false, "no bash tool call with run_in_background=true (bash calls: \(bashCalls.count))")
        }

        // Wait up to 10s for the completion notification to flow back.
        _ = await waitFor(seconds: 15) {
            await bgManager.list(sessionId: sessionId).contains { $0.status == .completed }
        }
        let tasks = await bgManager.list(sessionId: sessionId)
        let completed = tasks.filter { $0.status == .completed }
        if completed.isEmpty {
            return (false, "no task reached completed state (found \(tasks.count) total: \(tasks.map { $0.status.rawValue }))")
        }
        return (true, "\(completed.count) task(s) completed; notification delivered")
    }

    // MARK: - Scenario: auto-background on soft timeout

    func runAutoBackground() async -> (Bool, String) {
        let outputDir = tempDir("auto-bg")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwd = tempDir("cwd-auto-bg")
        defer { try? FileManager.default.removeItem(at: cwd) }

        let bgManager = BackgroundTaskManager(outputDir: outputDir)
        let sessionId = "auto-bg-\(UUID().uuidString.prefix(6))"

        // Soft timeout = 2s so `sleep 5` reliably trips the auto-background flip.
        let (agent, recorder, detach) = await buildAgent(
            bgManager: bgManager,
            sessionId: sessionId,
            cwd: cwd.path,
            defaultTimeoutSeconds: 2,
            maxTimeoutSeconds: 3
        )
        defer { Task { await detach() } }

        let prompt = """
        Please run this shell command as a plain foreground command: `sleep 5 && echo scenario-2-done`.
        Use the bash tool WITHOUT run_in_background=true; treat it as a short command.
        After it runs, briefly report what happened.
        """
        let runErr = await safeRun(agent: agent, prompt: prompt, timeout: 60)
        if let runErr {
            return (false, "agent run failed: \(runErr)")
        }

        // We expect the tool result to contain status=auto_backgrounded.
        let bashResults = await recorder.toolResultsByName("bash")
        let flipped = bashResults.contains { res in
            if case .object(let obj) = res.details ?? .null,
               case .string(let status) = obj["status"] ?? .null {
                return status == "auto_backgrounded"
            }
            return false
        }
        if !flipped {
            return (false, "no bash tool result with status=auto_backgrounded (results: \(bashResults.count))")
        }

        _ = await waitFor(seconds: 15) {
            await bgManager.list(sessionId: sessionId).contains { $0.status == .completed }
        }
        let completed = await bgManager.list(sessionId: sessionId).filter { $0.status == .completed }.count
        return (true, "soft-timeout flipped to background; \(completed) task(s) completed")
    }

    // MARK: - Scenario: bg_status

    func runBgStatus() async -> (Bool, String) {
        let outputDir = tempDir("bgstatus")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwd = tempDir("cwd-bgstatus")
        defer { try? FileManager.default.removeItem(at: cwd) }

        let bgManager = BackgroundTaskManager(outputDir: outputDir)
        let sessionId = "bgstatus-\(UUID().uuidString.prefix(6))"

        let (agent, recorder, detach) = await buildAgent(
            bgManager: bgManager,
            sessionId: sessionId,
            cwd: cwd.path
        )
        defer { Task { await detach() } }

        // Prime with a long-running bg task directly via the manager (bypass
        // LLM; saves a turn).
        let primed = await bgManager.spawn(
            runner: BashBackgroundRunner(command: "sleep 10 && echo primed-done"),
            sessionId: sessionId
        )
        let primedTaskId = primed.taskId

        let prompt = """
        I already started a background task with id `\(primedTaskId)`. Please use the bg_status tool with action=list to show me everything currently running in this session.
        """
        let runErr = await safeRun(agent: agent, prompt: prompt, timeout: 60)
        if let runErr {
            try? await bgManager.kill(primedTaskId)
            return (false, "agent run failed: \(runErr)")
        }

        let statusCalls = await recorder.toolCallsByName("bg_status")
        if statusCalls.isEmpty {
            try? await bgManager.kill(primedTaskId)
            return (false, "agent did not call bg_status")
        }
        try? await bgManager.kill(primedTaskId)
        return (true, "bg_status called \(statusCalls.count) time(s); seeded task id \(primedTaskId)")
    }

    // MARK: - Scenario: tmux

    func runTmux() async -> (Bool, String) {
        let tmuxMgr = TmuxSessionManager()
        guard await tmuxMgr.isAvailable else {
            return (true, "skipped — tmux not on PATH")
        }

        let outputDir = tempDir("tmux")
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let cwd = tempDir("cwd-tmux")
        defer { try? FileManager.default.removeItem(at: cwd) }

        let bgManager = BackgroundTaskManager(outputDir: outputDir)
        let sessionId = "tmux-\(UUID().uuidString.prefix(6))"
        let (agent, recorder, detach) = await buildAgent(
            bgManager: bgManager,
            sessionId: sessionId,
            cwd: cwd.path,
            includeTmux: true
        )
        defer {
            Task {
                await detach()
                await tmuxMgr.teardown()
            }
        }

        let prompt = """
        Using the tmux tool, do three things:
          1. action=start with command `cat` (cat will echo lines back)
          2. action=send_keys with literal=true and keys=`tmux-scenario-hello`, then action=send_keys with keys=`Enter`
          3. action=capture on the same pane_id, then tell me the last line of the pane
          4. action=kill to close it
        Stop after the kill; report what you saw.
        """
        let runErr = await safeRun(agent: agent, prompt: prompt, timeout: 120)
        if let runErr {
            return (false, "agent run failed: \(runErr)")
        }

        let tmuxCalls = await recorder.toolCallsByName("tmux")
        let actions = tmuxCalls.compactMap { tc -> String? in
            if case .object(let obj) = tc.arguments,
               case .string(let a) = obj["action"] ?? .null { return a }
            return nil
        }
        let expected: Set<String> = ["start", "send_keys", "capture", "kill"]
        let missing = expected.subtracting(Set(actions))
        if !missing.isEmpty {
            return (false, "tmux tool usage incomplete — actions \(actions) missing \(missing)")
        }
        return (true, "tmux actions \(actions.joined(separator: ", "))")
    }

    // MARK: - Agent setup

    private func buildAgent(
        bgManager: BackgroundTaskManager,
        sessionId: String,
        cwd: String,
        defaultTimeoutSeconds: Int = 120,
        maxTimeoutSeconds: Int = 600,
        includeTmux: Bool = false
    ) async -> (Agent, ToolRecorder, @Sendable () async -> Void) {
        // ChatGPT subscription's Codex backend routes to `gpt-5.4` (per
        // ~/.codex/config.toml). Other names like `gpt-5-codex` return 400
        // "model is not supported when using Codex with a ChatGPT account".
        //
        // Note: `maxTokens: 0` deliberately — the Codex endpoint rejects
        // `max_output_tokens` as "Unsupported parameter". Must leave the
        // model to pick its own limit.
        let model = Model(
            id: "gpt-5.4",
            name: "gpt-5.4",
            api: "chatgpt-codex",
            provider: "chatgpt-codex",
            baseUrl: "https://chatgpt.com",
            reasoning: true,
            input: [.text],
            contextWindow: 200_000,
            maxTokens: 0
        )

        var tools: [AgentTool] = [
            createBashTool(cwd: cwd, options: BashToolOptions(
                defaultTimeoutSeconds: defaultTimeoutSeconds,
                maxTimeoutSeconds: maxTimeoutSeconds,
                manager: bgManager,
                sessionId: sessionId,
                autoBackgroundOnTimeout: true
            )),
            createBgStatusTool(manager: bgManager, sessionId: sessionId),
        ]
        if includeTmux, let tmux = await createTmuxTool() {
            tools.append(tmux)
        }

        let systemPrompt = """
        You are a coding agent under test. Follow the user's instructions literally and succinctly; don't second-guess them. When they ask you to use a specific tool with specific arguments, do exactly that.
        Available tools: \(tools.map { $0.name }.joined(separator: ", ")).
        Working directory: \(cwd)
        """
        let agent = Agent(initialState: AgentInitialState(
            systemPrompt: systemPrompt,
            model: model,
            tools: tools
        ))

        let recorder = ToolRecorder()
        _ = agent.subscribe { event, _ in
            await recorder.ingest(event)
            await logEvent(event)
        }
        let detach = await agent.attachBackgroundManager(bgManager, sessionId: sessionId)
        return (agent, recorder, detach)
    }

    private func safeRun(agent: Agent, prompt: String, timeout: Int) async -> String? {
        print("  > \(prompt.replacingOccurrences(of: "\n", with: " ").prefix(160))…")
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            agent.abort()
        }
        defer { deadline.cancel() }
        do {
            try await agent.prompt(prompt)
            await agent.waitForIdle()
            return nil
        } catch {
            return "\(error)"
        }
    }

    private func waitFor(seconds: Int, _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(seconds))
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}

// MARK: - Recorder

actor ToolRecorder {
    struct ResultRecord: Sendable {
        let name: String
        let details: JSONValue?
    }
    private var events: [AgentEvent] = []
    private var toolCalls: [ToolCall] = []
    private var toolResults: [ResultRecord] = []

    func ingest(_ event: AgentEvent) {
        events.append(event)
        switch event {
        case .messageEnd(let m):
            if case .assistant(let a) = m {
                for block in a.content {
                    if case .toolCall(let tc) = block {
                        toolCalls.append(tc)
                    }
                }
            }
        case .toolExecutionEnd(_, let name, let result, _):
            toolResults.append(ResultRecord(name: name, details: result.details))
        default:
            break
        }
    }

    func toolCallsByName(_ name: String) -> [ToolCall] {
        toolCalls.filter { $0.name == name }
    }

    func toolResultsByName(_ name: String) -> [ResultRecord] {
        toolResults.filter { $0.name == name }
    }

    func allToolCalls() -> [ToolCall] { toolCalls }
}

// MARK: - Event logging

@MainActor
private func logEvent(_ event: AgentEvent) {
    switch event {
    case .agentStart:
        print("    · agent start")
    case .agentEnd(let messages):
        print("    · agent end")
        if messages.count == 1, case .assistant(let a) = messages.first,
           a.stopReason == .error, let err = a.errorMessage {
            print("    · agentEnd ERROR: \(err.prefix(400))")
        }
    case .messageEnd(let m):
        if case .assistant(let a) = m {
            if a.stopReason == .error, let err = a.errorMessage {
                print("    · ERROR: \(err.prefix(400))")
            }
            if a.stopReason == .aborted {
                print("    · aborted: \(a.errorMessage ?? "(no reason)")")
            }
            for block in a.content {
                switch block {
                case .text(let t):
                    let one = t.text.replacingOccurrences(of: "\n", with: " ").prefix(200)
                    if !one.isEmpty { print("    · text: \(one)") }
                case .toolCall(let tc):
                    print("    · tool_call \(tc.name) args=\(shortJSON(tc.arguments))")
                case .thinking:
                    print("    · thinking…")
                }
            }
        }
    case .toolExecutionEnd(_, let name, let result, let isError):
        let tag = isError ? "ERROR" : "ok"
        let details = shortJSON(result.details ?? .null)
        print("    · tool_result [\(tag)] \(name) details=\(details)")
    default:
        break
    }
}

private func shortJSON(_ v: JSONValue, max: Int = 220) -> String {
    guard let data = try? JSONEncoder().encode(v),
          let s = String(data: data, encoding: .utf8) else { return "?" }
    if s.count <= max { return s }
    return String(s.prefix(max)) + "…"
}

// MARK: - Helpers

private func tempDir(_ prefix: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kw-e2e-\(prefix)-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
