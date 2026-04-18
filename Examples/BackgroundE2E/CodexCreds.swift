import Foundation

/// Thin loader for `~/.codex/auth.json` (the ChatGPT subscription Codex CLI
/// credentials file). Returns the fields the `chatgptCodex` provider needs:
/// a fresh OAuth access token + the chatgpt account id.
///
/// Schema (as of Codex CLI April 2026):
/// ```json
/// {
///   "auth_mode": "chatgpt",
///   "OPENAI_API_KEY": null,
///   "tokens": {
///     "id_token": "<JWT>",
///     "access_token": "<JWT>",
///     "refresh_token": "rt_...",
///     "account_id": "<uuid>"
///   },
///   "last_refresh": "2026-04-18T06:35:17.267807Z"
/// }
/// ```
enum CodexCreds {
    struct Credentials {
        let accessToken: String
        let accountId: String
        let refreshToken: String
        /// JWT exp in seconds (from access_token). nil if decoding failed.
        let expiresAt: Int64?
    }

    enum LoadError: Error, LocalizedError {
        case fileNotFound(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path):
                return "Codex credentials not found at \(path). Run `codex login` first."
            case .malformed(let msg):
                return "Codex credentials file is malformed: \(msg)"
            }
        }
    }

    static func load(from url: URL? = nil) throws -> Credentials {
        let path = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LoadError.fileNotFound(path.path)
        }
        let data = try Data(contentsOf: path)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError.malformed("top level is not an object")
        }
        guard let tokens = root["tokens"] as? [String: Any] else {
            throw LoadError.malformed("missing `tokens` object")
        }
        guard let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw LoadError.malformed("missing `tokens.access_token`")
        }
        guard let accountId = tokens["account_id"] as? String, !accountId.isEmpty else {
            throw LoadError.malformed("missing `tokens.account_id`")
        }
        let refresh = (tokens["refresh_token"] as? String) ?? ""
        return Credentials(
            accessToken: access,
            accountId: accountId,
            refreshToken: refresh,
            expiresAt: Self.decodeExp(fromJWT: access)
        )
    }

    /// Decode the `exp` claim of a JWT (seconds since epoch). Returns nil on
    /// failure — caller can then assume the token might be stale and refresh.
    static func decodeExp(fromJWT token: String) -> Int64? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        while payload.count % 4 != 0 { payload.append("=") }
        let urlSafe = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: urlSafe),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Int
        else { return nil }
        return Int64(exp)
    }
}
