import Foundation

/// Multi-line text editor. Content is stored as a flat `[Character]`
/// buffer; newlines (`\n`) inside the buffer force hard breaks in the
/// rendered output, and anything that would overflow `width` at render
/// time soft-wraps onto the next visual row. The cursor is tracked as a
/// linear index into the buffer but placed on the correct visual
/// (row, col) at render time.
///
/// Keyboard map mirrors readline/emacs basics (left/right, home/end,
/// Ctrl-A/E/B/F/U/K, backspace, delete). Newline-insert triggers:
///
///   - Shift+Enter (Kitty/Ghostty keyboard protocol)
///   - Ctrl+Enter  (terminals that send a modifier-tagged Enter)
///   - Ctrl+J      (raw LF — 0x0A; always works)
///
/// Plain Enter is left alone so the owning view (CodingTUI) can bind
/// it to "submit".
final class InputComponent: Component, Focusable, @unchecked Sendable {
    private var chars: [Character]
    private(set) var cursor: Int  // cursor position in chars (0...count)
    var focused: Bool = false
    var wantsKeyRelease: Bool { false }

    /// Invoked with the body of a bracketed-paste sequence (wrapper
    /// stripped, body as-is — may contain newlines). When nil the
    /// component inserts the body inline as plain text. Callers use
    /// this to peel off paths / images / multi-line blocks before they
    /// reach the editor.
    var onPaste: ((String) -> Void)?

    private var cachedOutput: [String]?
    private var cachedWidth: Int?
    private var cachedState: [Character]?
    private var cachedFocused: Bool?

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
        if let cachedOutput,
           cachedWidth == width,
           cachedState == chars,
           cachedFocused == focused {
            return cachedOutput
        }
        let rows = layoutRows(width: max(1, width))
        cachedOutput = rows
        cachedWidth = width
        cachedState = chars
        cachedFocused = focused
        return rows
    }

    /// Core wrap pass: walk the buffer once, laying each character out
    /// on (row, col) with `\n` forcing a new row and width overflow
    /// soft-wrapping. Returns the visual rows plus — when focused — a
    /// zero-width cursor marker inserted at the cursor's visual column.
    private func layoutRows(width: Int) -> [String] {
        var rows: [[Character]] = [[]]
        var cols: [Int] = [0]     // visible column width of each row so far
        var cursorRow = 0
        var cursorCol = 0

        for i in 0..<chars.count {
            if i == cursor {
                cursorRow = rows.count - 1
                cursorCol = cols.last!
            }
            let ch = chars[i]
            if ch == "\n" {
                rows.append([])
                cols.append(0)
                continue
            }
            let w = charColumnWidth(ch)
            // Soft-wrap: this char wouldn't fit on the current row.
            if cols.last! + w > width {
                rows.append([])
                cols.append(0)
            }
            rows[rows.count - 1].append(ch)
            cols[cols.count - 1] += w
        }
        if cursor == chars.count {
            cursorRow = rows.count - 1
            cursorCol = cols.last!
        }

        var out: [String] = rows.map { String($0) }
        if focused {
            out[cursorRow] = insertCursorMarker(in: out[cursorRow], atCol: cursorCol)
        }
        return out
    }

    /// Visible column width of a single `Character` — sums the per-scalar
    /// widths (a precomposed `Character` like "é" normally has width 1;
    /// CJK ideographs width 2).
    private func charColumnWidth(_ ch: Character) -> Int {
        var w = 0
        for scalar in ch.unicodeScalars {
            w += ANSI.columnWidth(of: scalar.value)
        }
        return max(1, w)
    }

    /// Insert a zero-width cursor marker into `line` at the given
    /// visible column (counting scalar widths ANSI-style). If the
    /// column is at or past the visible end, the marker goes at the
    /// end — the TUI's cursor positioner handles "just past last col"
    /// naturally.
    private func insertCursorMarker(in line: String, atCol col: Int) -> String {
        var out = ""
        var visible = 0
        var inserted = false
        for scalar in line.unicodeScalars {
            if !inserted && visible >= col {
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

    func invalidate() {
        cachedOutput = nil
        cachedWidth = nil
        cachedState = nil
        cachedFocused = nil
    }

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
                // No handler configured — insert verbatim. The editor is
                // multi-line, so newlines survive.
                insert(pasteBody)
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
            // Newline-insert triggers. Ctrl+J is the raw LF byte
            // (0x0A); terminals emit it even without any keyboard
            // protocol support. Shift+Enter and Ctrl+Enter require
            // a terminal that tags Enter with modifiers (for example
            // Kitty/Ghostty keyboard protocol support).
            case ("j", true, false): insert("\n")
            case ("enter", true, false): insert("\n")
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
        case "enter":
            if event.shift {
                insert("\n")
            }
            break
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
