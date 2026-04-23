import Foundation
import KWWKAgent

/// Public entry points for the `kwwk` binary. Everything else in KWWKCli is
/// internal — external consumers drive the CLI through these three
/// functions. All three work on macOS and Linux; individual OAuth login
/// providers surface `OAuthError.transport` on Linux because the browser
/// callback loop depends on Apple's `Network.framework`.
public enum KWWK {

    /// Launch the interactive coding-agent TUI in `cwd` (defaults to the
    /// current working directory).
    ///
    /// Credentials are resolved automatically from the OAuth store
    /// (`~/.kwwk/oauth.json`). Throws `AuthResolveError.noCredentials`
    /// with a message pointing at `kwwk login` if none are configured.
    ///
    /// `tools` controls which coding tools the agent is given. Default is
    /// `.all` — read/write/edit/bash/grep/find/ls/task_status/wait_task +
    /// optional tmux. Pass `.readOnly` for a sandboxed reviewer-style agent.
    ///
    /// `autoCompactThreshold` fires a silent `/compact` (summarize the
    /// transcript → replace with a recap) once the turn's reported
    /// `usage.input + usage.output` crosses that ratio of the model's
    /// `contextWindow`. Pass `nil` to disable.
    public static func runCodingTUI(
        cwd: String? = nil,
        tools: CodingTools = .all,
        autoCompactThreshold: Double? = 0.75,
        thinkingLevel: ThinkingLevel = .medium
    ) async throws {
        let resolved = try await resolveAgentAuth()
        let workDir = cwd ?? FileManager.default.currentDirectoryPath
        try await runCodingTUIInternal(
            model: resolved.model,
            modelLabel: resolved.modelLabel,
            cwd: workDir,
            tools: tools,
            apiKeyResolver: resolved.apiKeyResolver,
            autoCompactThreshold: autoCompactThreshold,
            thinkingLevel: thinkingLevel
        )
    }

    /// Launch the interactive `kwwk login` flow: TUI selector over the
    /// supported providers → browser OAuth (macOS) or API-key form → persist
    /// credentials to `~/.kwwk/oauth.json`. On Linux the browser-OAuth
    /// providers throw at runtime (no `Network.framework`) — the API-key
    /// flow still works.
    public static func runLogin() async throws {
        try await runLoginInternal()
    }

    /// One-shot, non-interactive coding-agent run. Backs the `kwwk -p <prompt>`
    /// CLI mode — modeled on `claude -p`:
    ///
    ///   - `prompt` is handed to the agent verbatim;
    ///   - assistant text streams to stdout as it arrives;
    ///   - tool-call breadcrumbs and the final summary go to stderr;
    ///   - returns `0` on a clean stop, `1` on error / aborted / length-capped.
    ///
    /// Credentials are resolved the same way as `runCodingTUI` (from the
    /// OAuth store at `~/.kwwk/oauth.json`). Throws
    /// `AuthResolveError.noCredentials` with a hint pointing at `kwwk login`
    /// if none are configured.
    public static func runHeadless(
        prompt: String,
        cwd: String? = nil,
        tools: CodingTools = .all,
        thinkingLevel: ThinkingLevel = .medium
    ) async throws -> Int32 {
        let workDir = cwd ?? FileManager.default.currentDirectoryPath
        return try await runHeadlessInternal(
            prompt: prompt,
            cwd: workDir,
            tools: tools,
            thinkingLevel: thinkingLevel
        )
    }
}

