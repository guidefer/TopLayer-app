import AppKit
import Testing
@testable import TopLayer

/// The text view a message is drawn in: one piece of text, so a selection can run across
/// paragraphs, and what you copy out of it reads as plain text.
@MainActor
struct MessageTextTests {
    private func view(_ text: String) -> MessageTextView {
        let view = MessageTextView.make()
        view.show(text, size: 13)
        return view
    }

    private func everything(_ view: MessageTextView) -> String {
        view.plainText(in: NSRange(location: 0, length: (view.string as NSString).length))
    }

    @Test func aSelectionAcrossParagraphsCopiesThemApartByOneEmptyLine() {
        let text = view("First paragraph.\nSame paragraph.\n\nSecond paragraph.\n\n## Heading\n\nThird.")
        #expect(everything(text) == "First paragraph.\nSame paragraph.\n\nSecond paragraph.\n\nHeading\n\nThird.")
    }

    @Test func partOfAMessageCanBeCopied() {
        let text = view("One.\n\nTwo.\n\nThree.")
        let whole = text.string as NSString
        let range = NSRange(location: whole.range(of: "Two").location, length: whole.length - whole.range(of: "Two").location)
        #expect(text.plainText(in: range) == "Two.\n\nThree.")
    }

    @Test func listsCodeRulesAndTablesCopyAsReadableText() {
        let text = view("""
        ```
        let x = 1
        ```

        - First
        - Second

        | A | B |
        |---|---|
        | 1 | 2 |

        ---

        End **bold** and `code`.
        """)
        #expect(everything(text) == "let x = 1\n\n• First\n• Second\n\nA | B\n1 | 2\n\n---\n\nEnd bold and code.")
    }

    @Test func aShortMessageStaysNarrowHoweverOftenItIsMeasured() {
        let text = view("Push it")
        // Measuring at one width and then another used to report the full width.
        for width in [660.0, 588.0, 300.0, 660.0] {
            #expect(text.fit(width: width).width < 80)
        }
    }

    @Test func aLongMessageWrapsToTheWidthItIsGiven() {
        let text = view(String(repeating: "Several words that need to wrap. ", count: 12))
        let wide = text.fit(width: 600)
        let narrow = text.fit(width: 300)
        #expect(wide.width <= 600 && narrow.width <= 300)
        #expect(narrow.height > wide.height)
    }

    @Test func aTableUsesAllTheWidth() {
        let text = view("| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(text.fit(width: 500).width == 500)
    }
}
