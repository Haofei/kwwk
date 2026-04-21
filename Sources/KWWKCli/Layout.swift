import Foundation

/// Claude-Code-style layout for the live zone — everything below the
/// committed scrollback. The header is printed once at startup (see
/// `CodingTUI`) and scrolls away like any other output, so it isn't part
/// of this component tree.
///
/// Components in render order:
///
///   liveTail   — streaming assistant text + running tool placeholders +
///                transient notifications. Height is bounded (rendered
///                content only, no viewport padding).
///   divider    — thin separator above the status bar.
///   status     — state line + contextual hints.
///   queue      — persistent list of queued steering messages. Zero rows
///                when empty so the layout collapses cleanly.
///   blank      — breathing room above the prompt.
///   prompt     — the `❯ …` input row.
final class CodingLayout: @unchecked Sendable {
    let liveTail: TextComponent
    let divider: HorizontalRule
    let status: TextComponent
    let queue: TextComponent
    let input: InputComponent
    let promptRow: PromptRow

    /// How many rows the status block occupies. Defaults to 1; pass 2 when
    /// rendering a two-row status (state line + keyboard hints) so the
    /// live-tail clip budget leaves room for both.
    let statusRows: Int

    init(statusRows: Int = 1) {
        self.liveTail = TextComponent([])
        self.divider = HorizontalRule("─")
        self.status = TextComponent([])
        self.queue = TextComponent([])
        self.input = InputComponent()
        self.promptRow = PromptRow(prompt: Style.prompt("❯ "), input: input)

        self.statusRows = statusRows
    }

    /// Install layout components into `tui` in display order. Call once at
    /// setup time.
    ///
    /// There's no dedicated blank row between `status` and `promptRow` —
    /// the divider above `status` already provides the visual break, and
    /// a second empty line above the prompt just reads as wasted real
    /// estate.
    func install(into tui: TUI) {
        tui.addChild(liveTail)
        tui.addChild(divider)
        tui.addChild(status)
        tui.addChild(queue)
        tui.addChild(promptRow)
    }

    /// Last terminal height seen. Tracked so callers can clip the live
    /// tail to a sensible size when the tail grows large (e.g. a wall
    /// of streaming assistant text mid-turn) — without it the live zone
    /// could push the prompt below the visible area.
    private(set) var lastTerminalHeight: Int = 20
    /// Last terminal width seen. Needed because `promptRow` can now
    /// wrap across several rows, and its visual height depends on the
    /// terminal's column count.
    private(set) var lastTerminalWidth: Int = 80

    /// Current tail lines (unclipped).
    private var tailLines: [String] = []

    /// Rows consumed by the non-tail parts of the live zone at the
    /// last-observed terminal size: divider(1) + status(statusRows) +
    /// queue.lines.count + promptRow.height.
    ///
    /// The prompt row is multi-line once the user soft-wraps the input
    /// or hits Ctrl+Enter, so its height varies per render.
    var nonTailRows: Int {
        1 + statusRows + queue.lines.count + promptHeight
    }

    /// Visual height of the prompt row at the current terminal width.
    /// Reads the rendered line count — the component is cached so
    /// repeated calls are cheap.
    private var promptHeight: Int {
        max(1, promptRow.render(width: lastTerminalWidth).count)
    }

    /// Current budget for the live tail — how many rows the tail can
    /// occupy before it overruns the fixed live-zone elements. Callers
    /// that want to spill overflow into scrollback use this to decide
    /// when to commit.
    var liveTailBudget: Int {
        max(0, lastTerminalHeight - nonTailRows)
    }

    /// Recompute the tail's height budget based on the terminal size and
    /// reapply the current tail content. Called on resize + whenever the
    /// queue area grows/shrinks. Pass the terminal's current width so
    /// the prompt-row height (which can wrap) stays in sync.
    func fitViewport(height: Int, width: Int? = nil) {
        lastTerminalHeight = height
        if let width { lastTerminalWidth = width }
        applyTail()
    }

    /// Replace the live tail's contents (streaming text, running tool
    /// markers, transient notifications). Clipped to whatever fits above
    /// the fixed rows; if the tail is shorter than the budget we just
    /// show all of it — no top-padding (committed scrollback sits above).
    func setLiveTail(_ lines: [String]) {
        tailLines = lines
        applyTail()
    }

    /// Replace the queue panel's contents. Automatically re-fits so the
    /// tail budget updates.
    func setQueueLines(_ lines: [String]) {
        queue.lines = lines
        queue.invalidate()
        applyTail()
    }

    private func applyTail() {
        let budget = max(0, lastTerminalHeight - nonTailRows)
        let clipped: [String]
        if tailLines.count > budget {
            // Keep the tail of the tail — most recent content.
            clipped = Array(tailLines.suffix(budget))
        } else {
            clipped = tailLines
        }
        liveTail.lines = clipped
        liveTail.invalidate()
    }
}

/// Composes `prompt + input` as a (possibly multi-row) block. The first
/// visual row carries the `❯ ` prefix; continuation rows (from soft-
/// wrapping or explicit `\n`s) are indented by the prompt's visible
/// width so the body reads as one aligned paragraph.
///
///   ❯ this line is long enough that it wraps
///     onto a second continuation row
///     with a literal newline in between
///     and keeps going
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
        guard !inner.isEmpty else { return [prompt] }
        let indent = String(repeating: " ", count: promptWidth)
        var out: [String] = []
        for (i, row) in inner.enumerated() {
            out.append(i == 0 ? prompt + row : indent + row)
        }
        return out
    }

    func handleInput(_ data: String) { input.handleInput(data) }
    func invalidate() { input.invalidate() }

    var focused: Bool {
        get { input.focused }
        set { input.focused = newValue }
    }
}
