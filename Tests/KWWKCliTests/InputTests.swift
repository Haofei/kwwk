import Foundation
import Testing
@testable import KWWKCli

@Suite("Input component")
struct InputComponentTests {
    @Test("insert advances cursor") func insert() {
        let input = InputComponent()
        input.handleInput("h")
        input.handleInput("i")
        #expect(input.value == "hi")
        #expect(input.cursor == 2)
    }

    @Test("backspace removes char before cursor") func backspace() {
        let input = InputComponent(initial: "hello")
        input.handleInput("\u{7F}")
        #expect(input.value == "hell")
    }

    @Test("home/end move cursor") func homeEnd() {
        let input = InputComponent(initial: "abc")
        input.handleInput("\u{1B}[H")  // home
        #expect(input.cursor == 0)
        input.handleInput("\u{1B}[F")  // end
        #expect(input.cursor == 3)
    }

    @Test("ctrl+a / ctrl+e jump to bounds") func ctrlJump() {
        let input = InputComponent(initial: "hello")
        input.handleInput("\u{01}")  // Ctrl-A
        #expect(input.cursor == 0)
        input.handleInput("\u{05}")  // Ctrl-E
        #expect(input.cursor == 5)
    }

    @Test("render keeps line at or under the requested width") func widthClamp() {
        let input = InputComponent(initial: String(repeating: "x", count: 200))
        let line = input.render(width: 40).first ?? ""
        // The focused cursor adds a zero-width marker; strip it for width checks.
        let stripped = line.replacingOccurrences(of: CURSOR_MARKER, with: "")
        #expect(stripped.count <= 40)
    }

    @Test("focused render embeds the cursor marker") func cursorMarker() {
        let input = InputComponent(initial: "ab")
        input.focused = true
        let line = input.render(width: 40).first ?? ""
        #expect(line.contains(CURSOR_MARKER))
    }

    @Test("soft-wraps content that exceeds the render width") func softWrap() {
        let input = InputComponent(initial: "abcdefghij")
        let rows = input.render(width: 3)
        // 10 chars / 3 cols = 4 visual rows (last is 1 char).
        #expect(rows.count == 4)
        #expect(rows[0] == "abc")
        #expect(rows[1] == "def")
        #expect(rows[2] == "ghi")
        #expect(rows[3] == "j")
    }

    @Test("literal \\n in buffer forces a hard break") func hardNewline() {
        let input = InputComponent(initial: "hi\nthere")
        let rows = input.render(width: 40)
        #expect(rows == ["hi", "there"])
    }

    @Test("Ctrl+J inserts a newline into the buffer") func ctrlJInsertsNewline() {
        let input = InputComponent(initial: "ab")
        // 0x0A is Ctrl+J (raw LF). Fires without any keyboard-protocol
        // support — works in every terminal.
        input.handleInput("\u{0A}")
        #expect(input.value == "ab\n")
        #expect(input.cursor == 3)
    }

    @Test("Alt+Enter does not insert a newline") func altEnterDoesNotInsertNewline() {
        let input = InputComponent(initial: "ab")
        // ESC + CR == alt+enter in the parser, but newline insertion is
        // bound to Shift+Enter now.
        input.handleInput("\u{1B}\r")
        #expect(input.value == "ab")
    }

    @Test("Shift+Enter inserts a newline") func shiftEnterInsertsNewline() {
        let input = InputComponent(initial: "ab")
        // Kitty keyboard protocol: CSI 13 ; 2 u == shift+enter.
        input.handleInput("\u{1B}[13;2u")
        #expect(input.value == "ab\n")
    }

    @Test("cursor placed on the correct visual row after a hard break") func cursorMultiRow() {
        let input = InputComponent(initial: "hi\nx")
        input.focused = true
        // cursor is at end (index 4 == after "hi\nx")
        let rows = input.render(width: 40)
        #expect(rows.count == 2)
        #expect(!rows[0].contains(CURSOR_MARKER), "cursor should be on row 1 (the 'x' row), not row 0")
        #expect(rows[1].contains(CURSOR_MARKER))
    }
}

@Suite("Keybinding matching")
struct KeybindingTests {
    @Test("plain Enter binding does not match Shift+Enter") func enterBindingRejectsShift() {
        let binding = KeyBinding("enter", shift: false)
        let plainEnter = KeyEvent(name: "enter")
        let shiftEnter = KeyEvent(name: "enter", shift: true)
        #expect(binding.matches(plainEnter) == true)
        #expect(binding.matches(shiftEnter) == false)
    }
}

@Suite("Markdown component")
struct MarkdownComponentTests {
    @Test("strips bold / italic / code markers in output") func inlineStripping() {
        let md = MarkdownComponent("**hi** and *there* with `code`")
        let lines = md.render(width: 40)
        #expect(lines.first == "hi and there with code")
    }

    @Test("formats bullet lists with bullets and indentation") func bullets() {
        let md = MarkdownComponent("- first\n- second")
        let lines = md.render(width: 40)
        #expect(lines.contains("• first"))
        #expect(lines.contains("• second"))
    }

    @Test("renders headings") func headings() {
        let md = MarkdownComponent("# Big\n## Medium")
        let lines = md.render(width: 40)
        #expect(lines[0].hasPrefix("# "))
        #expect(lines[0].contains("BIG"))
        #expect(lines[1] == "## Medium")
    }

    @Test("keeps fenced code verbatim") func codeFence() {
        let md = MarkdownComponent("```\nlet x = 1\n```")
        let lines = md.render(width: 40)
        #expect(lines == ["let x = 1"])
    }
}
