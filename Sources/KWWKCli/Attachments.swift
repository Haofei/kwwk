import Foundation
import KWWKAI

/// In-process store of paste-time attachments. The input line carries
/// short placeholder tokens (`[pasted-text #1]`, `@/path/...`) that
/// refer back to entries here; the actual payload (a multi-line code
/// snippet, a file handle, an image's bytes) stays out of the narrow
/// single-line editor.
///
/// Scope: per-send. Cleared every time the user submits or the input
/// is otherwise reset. The store is `@MainActor` because the UI is,
/// and every mutation is driven by paste / submit handlers that run
/// there.
@MainActor
final class AttachmentStore {
    /// A large pasted text block that we don't want to shove into a
    /// single-line editor. Shown in the input as `[pasted-text #id]`
    /// and expanded to a `<pasted-text>` block at submit time.
    struct PastedText: Identifiable {
        let id: Int
        let body: String
        /// Line count of the body, used for the placeholder label so
        /// the user gets a sense of size without expanding it.
        var lineCount: Int {
            // `components(separatedBy:)` counts "a\nb" as 2, matching
            // what a user would intuitively read off the paste.
            body.components(separatedBy: "\n").count
        }
    }

    private var nextPastedTextId = 1
    private(set) var pastedTexts: [PastedText] = []

    /// Reset. Called after a send so the next prompt starts clean.
    func clear() {
        pastedTexts.removeAll()
        nextPastedTextId = 1
    }

    /// Register a pasted-text chunk and return the placeholder token
    /// the input should display in its place.
    func addPastedText(_ body: String) -> String {
        let id = nextPastedTextId
        nextPastedTextId += 1
        pastedTexts.append(PastedText(id: id, body: body))
        return "[pasted-text #\(id)]"
    }

    func pastedText(id: Int) -> PastedText? {
        pastedTexts.first(where: { $0.id == id })
    }
}

// MARK: - Path detection

/// Quick structural check: does the body look like a single filesystem
/// path? Used to decide paste semantics (path → attach, text → insert
/// inline). We only accept:
///   - absolute paths (`/…`)
///   - home-relative paths (`~/…`)
///   - the well-known leading-dot forms (`./…`, `../…`)
/// and reject anything with embedded whitespace or newlines. This keeps
/// accidental matches low — a pasted sentence that starts with `/` is
/// possible but rare, and even then the follow-up `FileManager.fileExists`
/// gate filters it out.
func looksLikeSinglePath(_ body: String) -> Bool {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    if trimmed.contains("\n") { return false }
    if trimmed.contains(" ") || trimmed.contains("\t") {
        // A quoted path like `"/Users/foo/has spaces.png"` is common
        // when Finder drags a file with whitespace. Strip surrounding
        // quotes before the whitespace check.
        return isQuotedPath(trimmed)
    }
    return trimmed.hasPrefix("/")
        || trimmed.hasPrefix("~/")
        || trimmed.hasPrefix("./")
        || trimmed.hasPrefix("../")
}

/// Return true if `trimmed` is surrounded by matching quotes and the
/// content between looks like a path.
private func isQuotedPath(_ trimmed: String) -> Bool {
    guard trimmed.count >= 2 else { return false }
    let first = trimmed.first!
    let last = trimmed.last!
    guard (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return false }
    let inner = String(trimmed.dropFirst().dropLast())
    return inner.hasPrefix("/") || inner.hasPrefix("~/") || inner.hasPrefix("./") || inner.hasPrefix("../")
}

/// Normalize a pasted path token: strip surrounding quotes + whitespace,
/// expand `~`, resolve relative-to-cwd. Returns the absolute filesystem
/// path string if the input looks syntactically valid — existence is
/// checked separately by `resolveAttachments`.
func normalizePastePath(_ body: String, cwd: String) -> String {
    var t = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count >= 2 {
        let first = t.first!
        let last = t.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            t = String(t.dropFirst().dropLast())
        }
    }
    if t.hasPrefix("~/") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        t = home + String(t.dropFirst(1))
    }
    if !t.hasPrefix("/") {
        // Resolve relative to cwd without calling realpath — the user
        // might reference a symlink on purpose; we preserve their view.
        t = (cwd as NSString).appendingPathComponent(t)
    }
    return t
}

// MARK: - Resolution (pre-submit)

/// What an `@path` token resolved to at submit time. `missing` exists
/// so we can report a helpful note back to the user instead of silently
/// dropping the reference.
enum ResolvedAttachment {
    case image(path: String, data: Data, mimeType: String)
    case textFile(path: String, content: String, byteSize: Int)
    case binaryFile(path: String, byteSize: Int)
    case folder(path: String, listing: String)
    case missing(path: String)
}

/// Soft ceilings so a single paste can't flood the LLM's context. Text
/// files over `textFileMaxBytes` fall through to `binaryFile` (we only
/// surface the metadata). Folder listings stop after
/// `folderListingMaxEntries` so `@/` doesn't shove the whole root tree
/// at the model.
let textFileMaxBytes = 256 * 1024
let folderListingMaxEntries = 200

/// Scan `text` for `@<path>` tokens and resolve each one (or report
/// `.missing`). Path syntax accepted matches `looksLikeSinglePath`:
/// absolute, `~/…`, `./…`, `../…`. A trailing punctuation char (`.`,
/// `,`, `:`, `;`, `)`, `]`) is peeled off so sentences like
/// "see @/foo.png." don't mis-resolve.
func resolveAtTokens(in text: String, cwd: String) -> [ResolvedAttachment] {
    var results: [ResolvedAttachment] = []
    for rawToken in extractAtTokens(from: text) {
        let resolved = resolveSinglePath(rawToken, cwd: cwd)
        results.append(resolved)
    }
    return results
}

/// Pull the path portion out of each `@...` reference in order, with
/// duplicates removed so the same path referenced twice only resolves
/// once. Trailing punctuation stripped.
func extractAtTokens(from text: String) -> [String] {
    var tokens: [String] = []
    var seen: Set<String> = []
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        if scalars[i] == "@" {
            // Token body starts at i+1, runs until the next whitespace.
            var j = i + 1
            while j < scalars.count, !scalars[j].properties.isWhitespace {
                j += 1
            }
            if j > i + 1 {
                var token = String(String.UnicodeScalarView(scalars[(i + 1)..<j]))
                // Trim a trailing punctuation character.
                let trailers: Set<Character> = [".", ",", ":", ";", ")", "]", "}"]
                while let last = token.last, trailers.contains(last) {
                    token.removeLast()
                }
                if !token.isEmpty, !seen.contains(token) {
                    seen.insert(token)
                    tokens.append(token)
                }
            }
            i = j
        } else {
            i += 1
        }
    }
    return tokens
}

private func resolveSinglePath(_ raw: String, cwd: String) -> ResolvedAttachment {
    // We deliberately don't reject tokens that don't pass
    // `looksLikeSinglePath` — the user pasted them with an explicit `@`,
    // and a bare `@name` might be a relative file in the current dir.
    let path = normalizePastePath(raw, cwd: cwd)
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
        return .missing(path: path)
    }
    if isDir.boolValue {
        return .folder(path: path, listing: renderFolderListing(path))
    }
    let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    if let (data, mime) = loadImageIfSupported(path: path, maxBytes: 10 * 1024 * 1024) {
        return .image(path: path, data: data, mimeType: mime)
    }
    if size > textFileMaxBytes {
        return .binaryFile(path: path, byteSize: size)
    }
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let text = String(data: data, encoding: .utf8) {
        return .textFile(path: path, content: text, byteSize: size)
    }
    return .binaryFile(path: path, byteSize: size)
}

private func loadImageIfSupported(path: String, maxBytes: Int) -> (Data, String)? {
    let mime = imageMimeType(forPath: path)
    guard let mime else { return nil }
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else { return nil }
    if data.count > maxBytes {
        return nil  // drops through to binaryFile which surfaces as metadata
    }
    return (data, mime)
}

private func imageMimeType(forPath path: String) -> String? {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    default: return nil
    }
}

private func renderFolderListing(_ path: String) -> String {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: path)
    guard let entries = try? fm.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else {
        return "(could not list directory)"
    }
    let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let truncated = sorted.prefix(folderListingMaxEntries)
    var out: [String] = []
    for url in truncated {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDir = values?.isDirectory ?? false
        let size = values?.fileSize ?? 0
        if isDir {
            out.append("\(url.lastPathComponent)/")
        } else {
            out.append("\(url.lastPathComponent)  \(size)B")
        }
    }
    if sorted.count > truncated.count {
        out.append("… \(sorted.count - truncated.count) more entries")
    }
    return out.joined(separator: "\n")
}

// MARK: - Prompt augmentation

/// Augment the user's raw prompt with resolved attachments. Returns the
/// expanded text (text + `<attachments>` XML block when non-empty) plus
/// the image blocks to attach to the `UserMessage`.
///
/// Pasted-text placeholders (`[pasted-text #N]`) are expanded inline by
/// substring replacement; `@path` references are kept in the text
/// verbatim (so the LLM can see that the user pointed at something) and
/// the resolved content is appended in a single `<attachments>` block.
struct BuiltPrompt {
    let text: String
    let images: [ImageContent]
    /// Short human-readable summary ("attached: 1 image, 2 files") —
    /// rendered as a dimmed notification in the transcript so the user
    /// sees what the model is about to receive.
    let summary: String?
}

@MainActor
func buildPromptWithAttachments(
    text inputText: String,
    store: AttachmentStore,
    cwd: String,
    modelSupportsImages: Bool
) -> BuiltPrompt {
    // 1. Expand pasted-text placeholders.
    var expanded = inputText
    for pasted in store.pastedTexts {
        let placeholder = "[pasted-text #\(pasted.id)]"
        let block = "<pasted-text id=\"\(pasted.id)\" lines=\"\(pasted.lineCount)\">\n\(pasted.body)\n</pasted-text>"
        expanded = expanded.replacingOccurrences(of: placeholder, with: block)
    }

    // 2. Resolve @path tokens.
    let resolved = resolveAtTokens(in: expanded, cwd: cwd)

    var images: [ImageContent] = []
    var attachBlocks: [String] = []
    var counts = (image: 0, file: 0, folder: 0, missing: 0, skippedImage: 0)

    for r in resolved {
        switch r {
        case .image(let path, let data, let mime):
            if modelSupportsImages {
                images.append(ImageContent(
                    data: data.base64EncodedString(),
                    mimeType: mime
                ))
                attachBlocks.append("<image path=\"\(xmlEscape(path))\" mime=\"\(mime)\" />")
                counts.image += 1
            } else {
                // Model can't see images. Preserve the reference + size
                // so the LLM still knows something was attached, but
                // skip the bytes to avoid the provider rejecting the
                // request.
                attachBlocks.append("<image path=\"\(xmlEscape(path))\" mime=\"\(mime)\" note=\"skipped: this model does not accept image input\" />")
                counts.skippedImage += 1
            }
        case .textFile(let path, let content, let size):
            attachBlocks.append("""
            <file path="\(xmlEscape(path))" size="\(size)">
            \(content)
            </file>
            """)
            counts.file += 1
        case .binaryFile(let path, let size):
            attachBlocks.append("<file path=\"\(xmlEscape(path))\" size=\"\(size)\" note=\"binary / too large to inline\" />")
            counts.file += 1
        case .folder(let path, let listing):
            attachBlocks.append("""
            <folder path="\(xmlEscape(path))">
            \(listing)
            </folder>
            """)
            counts.folder += 1
        case .missing(let path):
            attachBlocks.append("<missing path=\"\(xmlEscape(path))\" />")
            counts.missing += 1
        }
    }

    var out = expanded
    if !attachBlocks.isEmpty {
        out += "\n\n<attachments>\n"
        out += attachBlocks.joined(separator: "\n")
        out += "\n</attachments>"
    }

    // 3. Summary line (only if we actually attached something).
    var parts: [String] = []
    if counts.image > 0 { parts.append("\(counts.image) image\(counts.image == 1 ? "" : "s")") }
    if counts.file > 0 { parts.append("\(counts.file) file\(counts.file == 1 ? "" : "s")") }
    if counts.folder > 0 { parts.append("\(counts.folder) folder\(counts.folder == 1 ? "" : "s")") }
    if counts.missing > 0 { parts.append("\(counts.missing) missing") }
    if counts.skippedImage > 0 { parts.append("\(counts.skippedImage) image skipped (text-only model)") }
    if store.pastedTexts.count > 0 {
        parts.append("\(store.pastedTexts.count) pasted text\(store.pastedTexts.count == 1 ? "" : "s")")
    }
    let summary = parts.isEmpty ? nil : "attached: " + parts.joined(separator: ", ")

    return BuiltPrompt(text: out, images: images, summary: summary)
}

private func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
