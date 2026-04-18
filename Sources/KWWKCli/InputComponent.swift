import Foundation

/// Minimal single-line text input with cursor navigation. Mirrors the
/// behavior exercised by pi-tui's `input.test.ts`: insertion, backspace,
/// delete, home/end, horizontal scroll, and CJK width safety.
final class InputComponent: Component, Focusable, @unchecked Sendable {
    private var chars: [Character]
    private(set) var cursor: Int  // cursor position in chars (0...count)
    var focused: Bool = false
    var wantsKeyRelease: Bool { false }

    /// Invoked with the body of a bracketed-paste sequence (wrapper
    /// stripped, body as-is — may contain newlines). When nil the
    /// component inserts the body inline as plain text. Callers use
    /// this to peel off paths / images / multi-line blocks before they
    /// reach the single-line editor.
    var onPaste: ((String) -> Void)?

    private var cachedOutput: [String]?
    private var cachedWidth: Int?
    private var cachedState: [Character]?

    init(initial: String = "") {
        self.chars = Array(initial)
        self.cursor = chars.count
    }

    // MARK: - Programmatic access

    var value: String {
        get { String(chars) }
        set {
            chars = Array(newValue)
            cursor = min(cursor, chars.count)
            invalidate()
        }
    }

    func moveCursor(_ delta: Int) {
        cursor = max(0, min(chars.count, cursor + delta))
        invalidate()
    }

    func moveHome() { cursor = 0; invalidate() }
    func moveEnd() { cursor = chars.count; invalidate() }

    func insert(_ text: String) {
        for ch in text {
            chars.insert(ch, at: cursor)
            cursor += 1
        }
        invalidate()
    }

    func backspace() {
        guard cursor > 0 else { return }
        chars.remove(at: cursor - 1)
        cursor -= 1
        invalidate()
    }

    func deleteForward() {
        guard cursor < chars.count else { return }
        chars.remove(at: cursor)
        invalidate()
    }

    // MARK: - Component

    func render(width: Int) -> [String] {
        if let cachedOutput, cachedWidth == width, cachedState == chars {
            return cachedOutput
        }
        let line = renderLine(width: width)
        cachedOutput = [line]
        cachedWidth = width
        cachedState = chars
        return [line]
    }

    private func renderLine(width: Int) -> String {
        guard width > 0 else { return "" }
        // Compute the visible column of each character up to cursor so we can
        // scroll by *visible columns* (CJK chars are width 2). Without this
        // the cursor drifts left whenever the user types Chinese.
        let widths: [Int] = chars.map { ch in
            var w = 0
            for scalar in ch.unicodeScalars {
                w += ANSI.columnWidth(of: scalar.value)
            }
            return max(1, w)
        }
        // Cumulative visible column after the first N characters.
        var cumulative: [Int] = [0]
        cumulative.reserveCapacity(widths.count + 1)
        for w in widths { cumulative.append(cumulative.last! + w) }
        let cursorCol = cumulative[cursor]

        // Horizontal scroll: slide the window so the cursor is on-screen.
        let startCol: Int
        if cursorCol < width {
            startCol = 0
        } else {
            startCol = cursorCol - width + 1
        }

        // Find the first character whose leading col >= startCol.
        var startIndex = 0
        while startIndex < cumulative.count - 1, cumulative[startIndex] < startCol {
            startIndex += 1
        }
        // Collect chars whose trailing col <= startCol + width.
        var slice = ""
        var col = cumulative[startIndex]
        var i = startIndex
        while i < chars.count {
            let w = widths[i]
            if col + w > startCol + width { break }
            slice.append(chars[i])
            col += w
            i += 1
        }

        if focused {
            // Cursor marker: position by visible column relative to slice start.
            let rel = cursorCol - cumulative[startIndex]
            // Walk the slice and insert the marker at the scalar offset that
            // matches the target visible column.
            var out = ""
            var visible = 0
            var inserted = false
            for scalar in slice.unicodeScalars {
                if !inserted && visible >= rel {
                    out += CURSOR_MARKER
                    inserted = true
                }
                out.unicodeScalars.append(scalar)
                visible += ANSI.columnWidth(of: scalar.value)
            }
            if !inserted {
                out += CURSOR_MARKER
            }
            return out
        }
        return slice
    }

    func invalidate() {
        cachedOutput = nil
        cachedWidth = nil
        cachedState = nil
    }

    // MARK: - Input

    // MARK: - Bracketed paste wrapper

    private static let pasteStart = "\u{1B}[200~"
    private static let pasteEnd = "\u{1B}[201~"

    /// If `data` is a complete bracketed-paste sequence, return the
    /// body; otherwise nil. `StdinBuffer` only emits completed paste
    /// events, so this is just a wrapper-stripping helper that also
    /// normalizes terminal line separators — macOS + most *nix shells
    /// convert Return → `\r` when the body is typed/keystroke-sent,
    /// but the pasted body is logically multi-line. Converting to
    /// `\n` up front means downstream path/attachment detection can
    /// treat newline uniformly.
    private func extractBracketedPasteBody(_ data: String) -> String? {
        guard data.hasPrefix(Self.pasteStart),
              data.hasSuffix(Self.pasteEnd)
        else { return nil }
        let startIdx = data.index(data.startIndex, offsetBy: Self.pasteStart.count)
        let endIdx = data.index(data.endIndex, offsetBy: -Self.pasteEnd.count)
        let raw = String(data[startIdx..<endIdx])
        return raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func handleInput(_ data: String) {
        // Bracketed paste wrapper `ESC[200~ … ESC[201~` arrives as a
        // single synthetic sequence from StdinBuffer. Unwrap and route
        // to `onPaste` (or insert the body as a fallback so the text
        // isn't silently swallowed).
        if let pasteBody = extractBracketedPasteBody(data) {
            if let handler = onPaste {
                handler(pasteBody)
            } else {
                // Flatten newlines — single-line editor — so a stray
                // multi-line paste doesn't desync the cursor math.
                insert(pasteBody.replacingOccurrences(of: "\n", with: " "))
            }
            return
        }
        guard let event = Keys.parse(data) else {
            // Not a key we recognize — treat printable text as insertion.
            if !data.isEmpty && !data.hasPrefix("\u{1B}") { insert(data) }
            return
        }
        if event.ctrl || event.alt {
            switch (event.name, event.ctrl, event.alt) {
            case ("a", true, false): moveHome()
            case ("e", true, false): moveEnd()
            case ("b", true, false): moveCursor(-1)
            case ("f", true, false): moveCursor(1)
            case ("u", true, false): chars.removeFirst(cursor); cursor = 0; invalidate()
            case ("k", true, false): chars.removeLast(chars.count - cursor); invalidate()
            default: break
            }
            return
        }
        switch event.name {
        case "left": moveCursor(-1)
        case "right": moveCursor(1)
        case "home": moveHome()
        case "end": moveEnd()
        case "backspace": backspace()
        case "delete": deleteForward()
        case "enter": break // owners respond via their own bindings
        case "escape": break
        case "space": insert(" ")
        case "tab": insert("\t")
        default:
            // Single-char names fall through here.
            if event.name.count == 1 {
                insert(event.shift ? event.name.uppercased() : event.name)
            }
        }
    }
}
