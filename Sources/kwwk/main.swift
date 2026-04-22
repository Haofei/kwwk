import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import KWWKCli

/// `kwwk` — coding-agent CLI. Dispatches on argv:
///
///   kwwk                    → interactive coding TUI (uses creds from `kwwk login`)
///   kwwk login              → TUI-driven OAuth / API-key login
///   kwwk -p <prompt>        → one-shot, non-interactive run (stdout = reply)
///   kwwk --help             → usage
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
        case "-p", "--print":
            await runPrint(rest: Array(args.dropFirst()))
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
          kwwk                      launch the interactive coding TUI
          kwwk login                log in to an OAuth provider
          kwwk -p <prompt>          run a one-shot prompt and print the reply
          kwwk -p                   read the prompt from stdin
          kwwk --help               show this message

        Credentials are read from the OAuth store at ~/.kwwk/oauth.json.
        Run `kwwk login` once to register a provider (OAuth subscription
        or API key).
        """)
    }

    /// Handle `-p` / `--print`. Everything after the flag is joined into
    /// the prompt; if nothing is supplied (or the token is a bare `-`),
    /// the prompt is read from stdin until EOF.
    ///
    /// `-p` is quiet by design: on a successful run stdout carries only
    /// the assistant reply and stderr stays empty. Failures (no prompt,
    /// missing credentials, stream error) still print a one-line message
    /// to stderr so a non-zero exit isn't mysterious. Exit codes: 2 = bad
    /// invocation, 1 = runtime/auth failure, 0 = success.
    static func runPrint(rest: [String]) async {
        let prompt: String
        if rest.isEmpty || rest == ["-"] {
            // Use fd 0 directly instead of `fileno(stdin)` — on Linux
            // Glibc exposes `stdin` as a non-Sendable mutable var that
            // Swift 6 strict concurrency rejects. stdin's fd is always 0.
            if isatty(0) != 0 {
                FileHandle.standardError.write(Data(
                    "kwwk: -p requires a prompt argument when stdin is a terminal\n".utf8
                ))
                Foundation.exit(2)
            }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            prompt = String(data: data, encoding: .utf8) ?? ""
        } else {
            prompt = rest.joined(separator: " ")
        }

        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            FileHandle.standardError.write(Data(
                "kwwk: -p requires a non-empty prompt (as argument or via stdin)\n".utf8
            ))
            Foundation.exit(2)
        }

        do {
            let code = try await KWWK.runHeadless(prompt: prompt)
            Foundation.exit(code)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data("kwwk: \(msg)\n".utf8))
            Foundation.exit(1)
        }
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
