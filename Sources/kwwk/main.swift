import Foundation
import KWWKCli

/// `kwwk` — coding-agent CLI. Dispatches on argv:
///
///   kwwk           → interactive coding TUI (auto-detects Codex / Anthropic creds)
///   kwwk login     → TUI-driven OAuth login
///   kwwk --help    → usage
@main
struct KwwkCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let subcommand = args.first

        switch subcommand {
        case nil:
            await runOrExit { try await KWWK.runCodingTUI() }
        case "login":
            await runOrExit { try await KWWK.runLogin() }
        case "-h", "--help":
            printUsage()
        default:
            FileHandle.standardError.write(Data("kwwk: unknown subcommand '\(subcommand!)'\n\n".utf8))
            printUsage()
            Foundation.exit(2)
        }
    }

    static func printUsage() {
        print("""
        kwwk — coding-agent CLI

        usage:
          kwwk              launch the interactive coding TUI
          kwwk login        log in to an OAuth provider
          kwwk --help       show this message

        Credentials are resolved in this order on launch:
          1. OAuth store (~/.kw/oauth.json) has openai-codex  → ChatGPT Codex
          2. ANTHROPIC_API_KEY env var is set                 → Anthropic

        Run `kwwk login` once to register your ChatGPT subscription.
        """)
    }

    /// Run the async body and surface any thrown error on stderr before
    /// exiting with a non-zero code. Swift async `@main` has no throwing
    /// overload, so this is the workaround.
    static func runOrExit(_ body: @Sendable () async throws -> Void) async {
        do {
            try await body()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data("kwwk: \(msg)\n".utf8))
            Foundation.exit(1)
        }
    }
}
