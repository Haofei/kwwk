import Foundation
import Testing
@testable import KWWKAI
@testable import KWWKAgent
@testable import KWWKCli

@Suite("AutoCompactController usage reading")
struct AutoCompactUsageTests {

    @MainActor
    @Test("currentUsage sums input + output + cacheRead + cacheWrite")
    func readsLastAssistantUsage() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 90_000, output: 10_000, cacheRead: 0, cacheWrite: 0, totalTokens: 100_000)
        )
        let messages: [Message] = [
            .user(UserMessage(text: "hi")),
            .assistant(assistant),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: messages
        ))

        let controller = makeController(agent: agent, threshold: 0.5)
        let usage = controller.currentUsage()
        #expect(usage.tokens == 100_000)
        #expect(usage.window == 200_000)
        #expect(usage.ratio == 0.5)
    }

    @MainActor
    @Test("currentUsage includes cached prompt tokens (prompt-caching providers)")
    func includesCachedTokens() async {
        // Providers with prompt caching (Anthropic, OpenAI Responses/Codex)
        // report the cached portion of the prompt under `cacheRead`, not
        // `input`. The ratio must stay stable regardless of cache-hit
        // behavior, so the reader has to sum all four components.
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            // 80K cached prompt + 3K uncached delta + 1K output + 1K new cache write.
            usage: Usage(input: 3_000, output: 1_000, cacheRead: 80_000, cacheWrite: 1_000, totalTokens: 85_000)
        )
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: [
                .user(UserMessage(text: "hi")),
                .assistant(assistant),
            ]
        ))
        let controller = makeController(agent: agent, threshold: 0.5)
        #expect(controller.currentUsage().tokens == 85_000)
    }

    @MainActor
    @Test("currentUsage returns zero when there are no assistant messages")
    func zeroUsageWhenEmpty() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: []
        ))
        let controller = makeController(agent: agent, threshold: 0.5)
        #expect(controller.currentUsage().tokens == 0)
        #expect(controller.currentUsage().ratio == 0)
    }

    @MainActor
    @Test("usage ignores messages after the most recent assistant turn")
    func usesMostRecentAssistant() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let early = AssistantMessage(
            content: [.text(TextContent(text: "early"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 1_000, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 1_000)
        )
        let late = AssistantMessage(
            content: [.text(TextContent(text: "late"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 50_000, output: 2_000, cacheRead: 0, cacheWrite: 0, totalTokens: 52_000)
        )
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: [
                .user(UserMessage(text: "a")),
                .assistant(early),
                .user(UserMessage(text: "b")),
                .assistant(late),
            ]
        ))
        let controller = makeController(agent: agent, threshold: 0.5)
        // Should read `late`, not the sum of both.
        #expect(controller.currentUsage().tokens == 52_000)
    }
}

@Suite("AutoCompactController threshold gating")
struct AutoCompactGatingTests {

    @MainActor
    @Test("agentEnd above threshold triggers a compact")
    func firesAboveThreshold() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        // Queue the summarizer response that `performCompact` will
        // consume. Anything non-empty is fine.
        faux.setResponses([.message(fauxAssistantMessage("compressed recap"))])

        let big = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 160_000, output: 5_000, cacheRead: 0, cacheWrite: 0, totalTokens: 165_000)
        )
        let messages: [Message] = [
            .user(UserMessage(text: "u1")),
            .assistant(big),
            .user(UserMessage(text: "u2")),
            .assistant(big),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: messages
        ))

        let statuses = StatusLog()
        let outcomes = OutcomeLog()
        let controller = makeController(
            agent: agent,
            threshold: 0.75,
            onStatusChange: { s in statuses.append(s) },
            onCompactFinished: { o in outcomes.append(o) }
        )

        await controller.observe(.agentEnd(messages: messages, summary: AgentRunSummary()))
        // The compact is deferred onto a detached Task so it runs after
        // the agent lifecycle unwinds (see observe()). Await that here.
        await controller.pendingCompactTask?.value

        // 165_000 / 200_000 = 0.825 > 0.75 → should compact.
        #expect(agent.state.messages.count == 1, "should have replaced transcript with the recap")
        #expect(statuses.contains(.compacting) == true)
        #expect(statuses.contains(.idle) == true)
        #expect(outcomes.compactedCount == 1)
    }

    @MainActor
    @Test("agentEnd below threshold leaves the transcript alone")
    func skipsBelowThreshold() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let small = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 10_000, output: 500, cacheRead: 0, cacheWrite: 0, totalTokens: 10_500)
        )
        let messages: [Message] = [
            .user(UserMessage(text: "u1")),
            .assistant(small),
            .user(UserMessage(text: "u2")),
            .assistant(small),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: messages
        ))

        let outcomes = OutcomeLog()
        let controller = makeController(
            agent: agent,
            threshold: 0.75,
            onCompactFinished: { o in outcomes.append(o) }
        )
        await controller.observe(.agentEnd(messages: messages, summary: AgentRunSummary()))

        #expect(agent.state.messages.count == messages.count, "no compact should fire at 5% utilization")
        #expect(outcomes.count == 0)
    }

    @MainActor
    @Test("nil threshold disables the controller completely")
    func disabled() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let big = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 180_000, output: 1_000, cacheRead: 0, cacheWrite: 0, totalTokens: 181_000)
        )
        let messages: [Message] = [
            .user(UserMessage(text: "u")),
            .assistant(big),
            .user(UserMessage(text: "u")),
            .assistant(big),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: messages
        ))

        let outcomes = OutcomeLog()
        let controller = makeController(
            agent: agent,
            threshold: nil,
            onCompactFinished: { o in outcomes.append(o) }
        )
        await controller.observe(.agentEnd(messages: messages, summary: AgentRunSummary()))

        #expect(agent.state.messages.count == messages.count, "nil threshold must not compact, even at 90% utilization")
        #expect(outcomes.count == 0)
    }

    @MainActor
    @Test("non-agentEnd events refresh usage but never compact")
    func nonAgentEndDoesNotCompact() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let big = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 180_000, output: 1_000, cacheRead: 0, cacheWrite: 0, totalTokens: 181_000)
        )
        let messages: [Message] = [
            .user(UserMessage(text: "u")),
            .assistant(big),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: messages
        ))

        let outcomes = OutcomeLog()
        let usages = UsageLog()
        let controller = makeController(
            agent: agent,
            threshold: 0.5,
            onUsageChange: { u in usages.append(u) },
            onCompactFinished: { o in outcomes.append(o) }
        )
        await controller.observe(.turnEnd(message: .assistant(big), toolResults: []))

        // Usage did get pushed through…
        #expect(usages.count == 1)
        // …but no compact: we're reserving compacts for agentEnd so the
        // loop can't be mid-tool when state.messages gets rewritten.
        #expect(agent.state.messages.count == messages.count)
        #expect(outcomes.count == 0)
    }
}

@Suite("AutoCompactController between-turns inline compact")
struct AutoCompactInlineTests {

    @MainActor
    @Test("maybeCompactInline returns a replacement context when above threshold")
    func inlineReplacesContext() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        // The summarizer call that performCompact makes under the hood
        // hits this faux response.
        faux.setResponses([.message(fauxAssistantMessage("recap"))])

        let assistant = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 160_000, output: 5_000, cacheRead: 0, cacheWrite: 0, totalTokens: 165_000)
        )
        let messages: [Message] = [
            .user(UserMessage(text: "u1")),
            .assistant(assistant),
            .user(UserMessage(text: "u2")),
            .assistant(assistant),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: messages
        ))
        let controller = makeController(agent: agent, threshold: 0.75)

        // The hook must see `isStreaming == true` in prod — simulate
        // that so we know `performCompact` isn't refusing on the
        // busy guard.
        agent.state.setStreaming(true)
        defer { agent.state.setStreaming(false) }

        let context = AgentContext(
            systemPrompt: "",
            messages: messages,
            tools: []
        )
        let replacement = await controller.maybeCompactInline(context: context)

        #expect(replacement != nil, "should replace context when 82.5% > 75%")
        #expect(replacement?.messages.count == 1, "replacement should carry the single recap message")
        #expect(agent.state.messages.count == 1, "state.messages should also hold the recap")
    }

    @MainActor
    @Test("maybeCompactInline returns nil when under threshold")
    func inlineSkipsUnderThreshold() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }

        let small = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 10_000, output: 500, cacheRead: 0, cacheWrite: 0, totalTokens: 10_500)
        )
        let messages: [Message] = [
            .user(UserMessage(text: "u")),
            .assistant(small),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: messages
        ))
        let controller = makeController(agent: agent, threshold: 0.75)
        agent.state.setStreaming(true)
        defer { agent.state.setStreaming(false) }

        let context = AgentContext(systemPrompt: "", messages: messages, tools: [])
        let replacement = await controller.maybeCompactInline(context: context)
        #expect(replacement == nil, "5% should not trigger compact")
        #expect(agent.state.messages.count == messages.count)
    }

    @MainActor
    @Test("maybeCompactInline ignores the isStreaming guard that performCompact normally enforces")
    func inlineBypassesBusyGuard() async {
        // Regression for the "auto-compact: agent is busy" bug.
        // performCompact refuses when isStreaming == true unless the
        // caller opts out — which the inline path does.
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("recap"))])

        let big = AssistantMessage(
            content: [.text(TextContent(text: "ok"))],
            api: faux.getModel().api,
            provider: faux.getModel().provider,
            model: faux.getModel().id,
            usage: Usage(input: 160_000, output: 5_000, cacheRead: 0, cacheWrite: 0, totalTokens: 165_000)
        )
        let messages: [Message] = [
            .user(UserMessage(text: "u1")),
            .assistant(big),
            .user(UserMessage(text: "u2")),
            .assistant(big),
        ]
        let agent = Agent(initialState: AgentInitialState(
            model: fauxModelWithWindow(200_000, faux: faux),
            messages: messages
        ))
        let outcomes = OutcomeLog()
        let controller = makeController(
            agent: agent,
            threshold: 0.75,
            onCompactFinished: { o in outcomes.append(o) }
        )
        // Simulate a live agent loop: isStreaming is true in prod when
        // the betweenTurns hook fires.
        agent.state.setStreaming(true)
        defer { agent.state.setStreaming(false) }

        _ = await controller.maybeCompactInline(context: AgentContext(
            systemPrompt: "",
            messages: messages,
            tools: []
        ))
        #expect(outcomes.compactedCount == 1, "should succeed despite isStreaming == true")
    }
}

@Suite("formatCapacityHint")
struct CapacityHintTests {

    @Test("empty when we have no usage or no window")
    func emptyCases() {
        #expect(formatCapacityHint(
            usage: .init(tokens: 0, window: 200_000),
            threshold: 0.75
        ) == "")
        #expect(formatCapacityHint(
            usage: .init(tokens: 1000, window: 0),
            threshold: 0.75
        ) == "")
    }

    @Test("dimmed ratio under threshold")
    func underThreshold() {
        let hint = formatCapacityHint(
            usage: .init(tokens: 60_000, window: 200_000),
            threshold: 0.75
        )
        #expect(hint.contains("30% ctx"))
        #expect(!hint.contains("auto-compact"))
    }

    @Test("highlighted + threshold hint at/above threshold")
    func aboveThresholdMentionsAutoCompact() {
        let hint = formatCapacityHint(
            usage: .init(tokens: 160_000, window: 200_000),
            threshold: 0.75
        )
        #expect(hint.contains("80% ctx"))
        #expect(hint.contains("auto-compact at 75%"))
    }
}

// MARK: - Helpers

/// Returns a variant of the faux registration's model with `contextWindow`
/// overridden so the threshold tests can pin utilization ratios precisely.
/// Crucially preserves the api + provider fields so `stream(...)` (which
/// `performCompact` calls) actually hits the registered FauxProvider
/// instead of throwing `ProviderNotFoundError`.
@MainActor
private func fauxModelWithWindow(
    _ contextWindow: Int,
    faux: FauxProviderRegistration
) -> Model {
    var m = faux.getModel()
    m.contextWindow = contextWindow
    return m
}

@MainActor
private func makeController(
    agent: Agent,
    threshold: Double?,
    onStatusChange: @MainActor @escaping (AutoCompactController.Status) -> Void = { _ in },
    onUsageChange: @MainActor @escaping (AutoCompactController.Usage) -> Void = { _ in },
    onCompactFinished: @MainActor @escaping (CompactOutcome) -> Void = { _ in }
) -> AutoCompactController {
    let outputDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kwwk-autocompact-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    return AutoCompactController(
        agent: agent,
        backgroundManager: BackgroundTaskManager(outputDir: outputDir),
        sessionId: "test-session",
        threshold: threshold,
        onStatusChange: onStatusChange,
        onUsageChange: onUsageChange,
        onCompactFinished: onCompactFinished
    )
}

@MainActor
private final class StatusLog {
    private(set) var events: [AutoCompactController.Status] = []
    func append(_ s: AutoCompactController.Status) { events.append(s) }
    func contains(_ match: MatchKind) -> Bool {
        events.contains { event in
            switch (event, match) {
            case (.idle, .idle): return true
            case (.compacting, .compacting): return true
            default: return false
            }
        }
    }
    enum MatchKind { case idle, compacting }
}

@MainActor
private final class UsageLog {
    private(set) var readings: [AutoCompactController.Usage] = []
    func append(_ u: AutoCompactController.Usage) { readings.append(u) }
    var count: Int { readings.count }
}

@MainActor
private final class OutcomeLog {
    private(set) var outcomes: [CompactOutcome] = []
    func append(_ o: CompactOutcome) { outcomes.append(o) }
    var count: Int { outcomes.count }
    var compactedCount: Int {
        outcomes.filter {
            if case .compacted = $0 { return true } else { return false }
        }.count
    }
}
