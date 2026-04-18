import Foundation
import KWWKAgent

/// Public entry points for the `kwwk` binary. Everything else in KWWKCli is
/// internal — external consumers drive the CLI through these two functions.
public enum KWWK {

    /// Launch the interactive coding-agent TUI in `cwd` (defaults to the
    /// current working directory).
    ///
    /// Credentials are resolved automatically, in priority order:
    ///   1. OAuth store contains `openai-codex` → ChatGPT Codex (gpt-5.4).
    ///   2. `ANTHROPIC_API_KEY` env var is set → Anthropic Claude.
    ///   3. Throw `AuthResolveError.noCredentials` with a message pointing
    ///      at `kwwk login`.
    ///
    /// `tools` controls which coding tools the agent is given. Default is
    /// `.all` (read/write/edit/bash/grep/find/ls/bg_status + optional tmux).
    /// Pass `.readOnly` for a sandboxed reviewer-style agent.
    public static func runCodingTUI(
        cwd: String? = nil,
        tools: CodingTools = .all
    ) async throws {
        let resolved = try await resolveAgentAuth()
        let workDir = cwd ?? FileManager.default.currentDirectoryPath
        try await runCodingTUIInternal(
            model: resolved.model,
            modelLabel: resolved.modelLabel,
            cwd: workDir,
            tools: tools,
            apiKeyResolver: resolved.apiKeyResolver
        )
    }

    /// Launch the interactive `kwwk login` flow: TUI selector over the
    /// supported OAuth providers → browser-based OAuth dance → persist
    /// credentials to `~/.kw/oauth.json`.
    public static func runLogin() async throws {
        try await runLoginInternal()
    }
}
