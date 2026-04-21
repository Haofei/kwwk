import Foundation
import Testing
@testable import KWWKCli

// Regression: pressing ↑/↓ in the login API-key form was breaking the
// layout. Root cause was a focus-dependent cursor marker / caret that
// changed a row's visible width, so wrapping behavior on narrow terminals
// flipped between frames and left stale wrapped rows on screen.
//
// These tests pin the current invariant: re-rendering at the same width
// with focus on any field produces the same line count and the same
// per-row visible widths (the input rows only swap their 4-col prefix,
// which is width-parallel between focused and unfocused).

@Suite("APIKeyFormComponent layout")
struct APIKeyFormLayoutTests {

    @MainActor
    private func form() -> APIKeyFormComponent {
        APIKeyFormComponent(
            title: "test",
            fields: [
                APIKeyFormField(key: "apiKey", label: "API key",
                                hint: "sk-…", placeholder: "sk-proj-…", required: true),
                APIKeyFormField(key: "baseUrl", label: "Base URL",
                                hint: "(optional)",
                                placeholder: "https://api.openai.com",
                                default: "https://api.openai.com",
                                required: false),
            ]
        )
    }

    @MainActor
    @Test("line count is stable across focus changes")
    func stableLineCount() {
        let f = form()
        let before = f.render(width: 80).count
        f.moveFocus(+1)
        let after = f.render(width: 80).count
        #expect(before == after, "moving focus must not grow/shrink the frame")
    }

    @MainActor
    @Test("focus prefix swaps between rows without changing row count")
    func prefixSwap() {
        let f = form()
        let first = f.render(width: 80)
        // Find the two input rows (start with prompt `❯` when focused).
        let focusedLinesA = first.filter { $0.contains("❯") }
        #expect(focusedLinesA.count == 1, "exactly one focused row on initial render")

        f.moveFocus(+1)
        let second = f.render(width: 80)
        let focusedLinesB = second.filter { $0.contains("❯") }
        #expect(focusedLinesB.count == 1, "exactly one focused row after moveFocus")
        #expect(focusedLinesA.first != focusedLinesB.first, "focus arrow moved to a different row")
    }

    @MainActor
    @Test("input rows are width-parallel on focus toggle")
    func widthParallelInputs() {
        let f = form()
        let a = f.render(width: 80)
        f.moveFocus(+1)
        let b = f.render(width: 80)
        // Same count — check per-index visible width matches where layout
        // matters most (label + blank rows are text-stable; input rows
        // swap prefixes of equal visible length).
        #expect(a.count == b.count)
        for (la, lb) in zip(a, b) {
            #expect(ANSI.visibleWidth(la) == ANSI.visibleWidth(lb),
                    "row widths must match across focus so soft-wrap behavior is identical")
        }
    }
}
