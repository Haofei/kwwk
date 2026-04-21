import Foundation
import KWWKAI

extension Agent {
    /// One-shot, stateless convenience over `Agent.prompt`. Mirrors the
    /// `query()` entrypoint in claude-agent-sdk-python: a fresh Agent is
    /// created, run against `prompt`, and disposed — the caller consumes
    /// every event as an async stream and receives the final
    /// `AgentRunSummary` attached to the terminal `agentEnd` event.
    ///
    /// Cancellation of the returned stream's iterator aborts the
    /// underlying agent. Use `Agent` directly if you need to reuse
    /// state across prompts, inject steering messages, or subscribe
    /// multiple listeners.
    public static func runOnce(
        prompt text: String,
        options: AgentOptions,
        images: [ImageContent] = []
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let agent = Agent(options: options)
            let unsubscribe = agent.subscribe { event, _ in
                continuation.yield(event)
            }

            let task = Task {
                do {
                    try await agent.prompt(text, images: images)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                unsubscribe()
            }

            // Abort the run if the consumer drops the stream.
            continuation.onTermination = { _ in
                agent.abort()
                task.cancel()
            }
        }
    }
}
