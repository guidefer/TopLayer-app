import Testing
@testable import TopLayer

struct MarkdownTests {
    @Test func paragraphsAreSplitOnBlankLines() {
        #expect(Markdown.blocks("One.\nStill one.\n\nTwo.") == [.paragraph("One.\nStill one."), .paragraph("Two.")])
    }

    @Test func headingsNeedASpaceAfterTheHashes() {
        #expect(Markdown.blocks("## Title") == [.heading("Title", level: 2)])
        #expect(Markdown.blocks("#hashtag") == [.paragraph("#hashtag")])
    }

    @Test func fencedCodeKeepsItsLinesAndIgnoresMarkdownInside() {
        let text = "Before\n```swift\nlet x = 1\n- not a list\n```\nAfter"
        #expect(Markdown.blocks(text) == [.paragraph("Before"), .code("let x = 1\n- not a list"), .paragraph("After")])
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        #expect(Markdown.blocks("```\nstill code") == [.code("still code")])
    }

    @Test func listsKeepMarkersNestingAndContinuationLines() {
        let text = "- First\n  continued\n  - Nested\n1. Numbered"
        #expect(Markdown.blocks(text) == [.list([
            Markdown.ListItem(marker: "•", indent: 0, text: "First continued"),
            Markdown.ListItem(marker: "•", indent: 1, text: "Nested"),
            Markdown.ListItem(marker: "1.", indent: 0, text: "Numbered"),
        ])])
    }

    @Test func tablesNeedADividerRow() {
        let table = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
        #expect(Markdown.blocks(table) == [.table(header: ["A", "B"], rows: [["1", "2"], ["3", "4"]])])
        #expect(Markdown.blocks("| just | pipes |") == [.paragraph("| just | pipes |")])
    }

    @Test func threeDashesAreARule() {
        #expect(Markdown.blocks("Above\n\n---\n\nBelow") == [.paragraph("Above"), .rule, .paragraph("Below")])
    }
}
