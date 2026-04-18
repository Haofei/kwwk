import Foundation

/// Claude-Code-style layout: header, transcript body (viewport-clipped),
/// divider, status line, input row with an `❯` prompt. CodingLayout holds the
/// components and knows how to fit them to a terminal height; the caller is
/// responsible for owning the `TUI` instance and adding the components in
/// order.
final class CodingLayout: @unchecked Sendable {
    let header: TextComponent
    let transcript: TextComponent
    let divider: HorizontalRule
    let status: TextComponent
    let input: InputComponent
    let promptRow: PromptRow

    /// Rows used by everything except the transcript body. The body's
    /// `maxLines` is set to `terminalHeight - reservedRows` each render cycle.
    let reservedRows: Int

    /// How many rows the status block occupies. Defaults to 1; pass 2 when
    /// rendering a two-row status (state line + keyboard hints) so the
    /// transcript viewport leaves room for both.
    let statusRows: Int

    init(statusRows: Int = 1) {
        self.header = TextComponent([])
        self.transcript = TextComponent([])
        self.divider = HorizontalRule("─")
        self.status = TextComponent([])
        self.input = InputComponent()
        self.promptRow = PromptRow(prompt: Style.prompt("❯ "), input: input)

        self.statusRows = statusRows

        //   header:     3
        //   blank:      1
        //   divider:    1
        //   status:     statusRows
        //   blank:      1
        //   prompt:     1
        self.reservedRows = 3 + 1 + 1 + statusRows + 1 + 1
    }

    /// Install layout components into `tui` in display order. Call once at
    /// setup time.
    func install(into tui: TUI) {
        tui.addChild(header)
        tui.addChild(TextComponent([""]))
        tui.addChild(transcript)
        tui.addChild(divider)
        tui.addChild(status)
        tui.addChild(TextComponent([""]))
        tui.addChild(promptRow)
    }

    /// Current transcript height budget; updated on every fitViewport call.
    private var transcriptBudget: Int = 20

    /// Last set of transcript lines (unpadded). Stored so `fitViewport` can
    /// repad the transcript when the terminal resizes.
    private var currentLines: [String] = []

    /// Recompute `transcript.maxLines` based on the terminal's current height
    /// and re-pad the content so the tail stays glued to the bottom of the
    /// transcript region.
    func fitViewport(height: Int) {
        transcriptBudget = max(1, height - reservedRows)
        transcript.maxLines = transcriptBudget
        applyPaddedLines()
    }

    /// Replace the whole transcript line list. Pads with empty rows at the
    /// top so the most recent content sits at the bottom of the viewport
    /// (classic chat layout).
    func setTranscript(_ lines: [String]) {
        currentLines = lines
        applyPaddedLines()
    }

    private func applyPaddedLines() {
        let tail = currentLines.suffix(transcriptBudget)
        let pad = max(0, transcriptBudget - tail.count)
        transcript.lines = Array(repeating: "", count: pad) + Array(tail)
        transcript.invalidate()
    }
}

/// Composes `prompt + input` on a single rendered row so we don't burn an
/// extra row on a standalone prompt character.
final class PromptRow: Component, Focusable, @unchecked Sendable {
    let prompt: String
    let input: InputComponent
    var wantsKeyRelease: Bool { input.wantsKeyRelease }

    init(prompt: String, input: InputComponent) {
        self.prompt = prompt
        self.input = input
    }

    func render(width: Int) -> [String] {
        let promptWidth = ANSI.visibleWidth(prompt)
        let inner = input.render(width: max(1, width - promptWidth))
        let body = inner.first ?? ""
        return [prompt + body]
    }

    func handleInput(_ data: String) { input.handleInput(data) }
    func invalidate() { input.invalidate() }

    var focused: Bool {
        get { input.focused }
        set { input.focused = newValue }
    }
}
