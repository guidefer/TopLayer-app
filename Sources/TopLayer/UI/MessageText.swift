import AppKit
import SwiftUI

// A message drawn as one piece of text.
//
// SwiftUI can only select inside a single `Text`, and a message laid out block by block
// is many of them, so a selection stopped at the end of each paragraph. Here the whole
// message is one attributed string in one AppKit text view: you can drag across
// paragraphs, lists, code and tables, and copy what you selected.

extension NSAttributedString.Key {
    /// Marks a block the layout manager draws something behind: a code block's panel or
    /// a rule's line. The value is a `MessageBlock`.
    static let messageBlock = NSAttributedString.Key("toplayer.messageBlock")
}

/// What to draw behind a run of text. Each block gets its own instance, so two blocks
/// of the same kind next to each other are not drawn as one.
final class MessageBlock: NSObject {
    enum Kind { case code, rule }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

extension Markdown {
    private static let attributedCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 600
        return cache
    }()

    static let textColor = NSColor.white.withAlphaComponent(0.92)

    /// The whole message as one attributed string. Blocks are separated by an empty line,
    /// so text copied out of it reads as plain paragraphs.
    static func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
        let key = "\(size)|\(text)" as NSString
        if let hit = attributedCache.object(forKey: key) { return hit }
        let out = NSMutableAttributedString()
        let all = blocks(text)
        for (index, block) in all.enumerated() {
            if index > 0 {
                out.append(NSAttributedString(string: "\n"))        // ends the block before
                out.append(gap(8))
            }
            out.append(render(block, size: size))
        }
        attributedCache.setObject(out, forKey: key)
        return out
    }

    /// An empty line of an exact height: the space between two blocks.
    private static func gap(_ height: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style])
    }

    private static func prose(lineSpacing: CGFloat = 3) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }

    private static func render(_ block: Block, size: CGFloat) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: size)
        switch block {
        case .paragraph(let text):
            return styled(text, font: body, style: prose())

        case .heading(let title, let level):
            let font = NSFont.systemFont(ofSize: level <= 2 ? size + 2 : size + 0.5, weight: .semibold)
            return styled(title, font: font, style: prose())

        case .code(let code):
            // Each line of code is its own paragraph; the last carries the padding below.
            let lines = code.components(separatedBy: "\n")
            let out = NSMutableAttributedString()
            let panel = MessageBlock(.code)
            // The padding above the code is an empty line that belongs to the panel.
            // Spacing before a paragraph is ignored at the very top of a text view, which
            // is where a message that opens with code puts it.
            let top = NSMutableAttributedString(attributedString: gap(8))
            top.addAttribute(.messageBlock, value: panel, range: NSRange(location: 0, length: top.length))
            out.append(top)
            for (index, line) in lines.enumerated() {
                let style = prose(lineSpacing: 2)
                style.firstLineHeadIndent = 9
                style.headIndent = 9
                style.tailIndent = -9
                if index == lines.count - 1 { style.paragraphSpacing = 8 }
                out.append(NSAttributedString(string: line + (index == lines.count - 1 ? "" : "\n"), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular),
                    .foregroundColor: textColor, .paragraphStyle: style, .messageBlock: panel,
                ]))
            }
            return out

        case .list(let items):
            let out = NSMutableAttributedString()
            for (index, item) in items.enumerated() {
                let indent = CGFloat(item.indent) * 16
                let style = prose()
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 20
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]
                if index < items.count - 1 { style.paragraphSpacing = 4 }
                let marker = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                out.append(NSAttributedString(string: item.marker + "\t", attributes: [
                    .font: marker, .foregroundColor: textColor.withAlphaComponent(0.65), .paragraphStyle: style,
                ]))
                out.append(styled(item.text, font: body, style: style))
                if index < items.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: style])) }
            }
            return out

        case .table(let header, let rows):
            return table(header: header, rows: rows, size: size)

        case .rule:
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = 5
            style.maximumLineHeight = 5
            return NSAttributedString(string: "\u{00A0}", attributes: [
                .font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style, .messageBlock: MessageBlock(.rule),
            ])
        }
    }

    /// A real text table, so cells wrap inside their columns and a selection runs through them.
    private static func table(header: [String], rows: [[String]], size: CGFloat) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let out = NSMutableAttributedString()
        let all = [header] + rows
        for (rowIndex, row) in all.enumerated() {
            for column in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.backgroundColor = NSColor.white.withAlphaComponent(0.06)
                cell.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(7, type: .absoluteValueType, for: .padding, edge: .maxX)
                cell.setWidth(rowIndex == 0 ? 6 : 3, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(rowIndex == all.count - 1 ? 6 : 3, type: .absoluteValueType, for: .padding, edge: .maxY)
                if rowIndex == 0 {
                    // The line under the header row.
                    cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    cell.setBorderColor(NSColor.white.withAlphaComponent(0.22), for: .maxY)
                }
                let style = prose(lineSpacing: 2)
                style.textBlocks = [cell]
                let font = NSFont.systemFont(ofSize: size - 1, weight: rowIndex == 0 ? .semibold : .regular)
                let text = column < row.count ? row[column] : ""
                let content = NSMutableAttributedString(attributedString: styled(text, font: font, style: style))
                let last = rowIndex == all.count - 1 && column == columns - 1
                if !last { content.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style])) }
                out.append(content)
            }
        }
        return out
    }

    /// Text with its bold, italics, inline code and links applied as real fonts.
    private static func styled(_ text: String, font: NSFont, style: NSParagraphStyle) -> NSAttributedString {
        let parsed = inline(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = font
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: font.pointSize - 0.5,
                                                weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            } else {
                var traits = font.fontDescriptor.symbolicTraits
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if traits != font.fontDescriptor.symbolicTraits {
                    runFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: textColor, .paragraphStyle: style]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }
}

/// Draws what sits behind the text: the panel of a code block and the line of a rule.
final class MessageLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let whole = NSRange(location: 0, length: storage.length)
        var drawn = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.messageBlock, in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) { value, range, _ in
            guard let block = value as? MessageBlock, drawn.insert(ObjectIdentifier(block)).inserted else { return }
            // The whole block, not just the part being redrawn, or the panel would be cut.
            var full = NSRange()
            _ = storage.attribute(.messageBlock, at: range.location, longestEffectiveRange: &full, in: whole)
            var rect = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: full, actualCharacterRange: nil)) { line, _, _, _, _ in
                rect = rect.union(line)
            }
            guard !rect.isNull else { return }
            rect.origin.x = 0
            rect.size.width = container.size.width
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            switch block.kind {
            case .code:
                NSColor.black.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: rect, xRadius: Radius.control, yRadius: Radius.control).fill()
            case .rule:
                NSColor.white.withAlphaComponent(0.22).setFill()
                NSRect(x: rect.minX, y: rect.midY.rounded(), width: rect.width, height: 1).fill()
            }
        }
    }
}

final class MessageTextView: NSTextView {
    /// Widths already measured for the current text, so layout passes don't repeat the work.
    var measured: [Int: CGSize] = [:]
    /// A table lays its columns out across all the width it is given.
    private var fillsWidth = false
    /// Room for a code panel's padding to the right of its longest line.
    private var trailingPadding: CGFloat = 0

    /// Copies plain text that reads well when pasted: paragraphs apart by one empty line,
    /// list markers followed by a space, and a table row on one line.
    override func copy(_ sender: Any?) {
        let text = plainText(in: selectedRange())
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func plainText(in range: NSRange) -> String {
        guard range.length > 0, let storage = textStorage else { return "" }
        var lines = [String]()
        var lastCell: (table: NSTextTable, row: Int)?
        (string as NSString).enumerateSubstrings(in: range, options: .byParagraphs) { piece, pieceRange, _, _ in
            var line = (piece ?? "").replacingOccurrences(of: "\t", with: " ")
            var cell: NSTextTableBlock?
            if pieceRange.location < storage.length {
                let style = storage.attribute(.paragraphStyle, at: pieceRange.location, effectiveRange: nil) as? NSParagraphStyle
                cell = style?.textBlocks.first as? NSTextTableBlock
                if (storage.attribute(.messageBlock, at: pieceRange.location, effectiveRange: nil) as? MessageBlock)?.kind == .rule {
                    line = "---"
                }
            }
            if let cell, let last = lastCell, last.table === cell.table, last.row == cell.startingRow, !lines.isEmpty {
                lines[lines.count - 1] += " | " + line
            } else {
                lines.append(line)
            }
            lastCell = cell.map { ($0.table, $0.startingRow) }
        }
        // Spacing inside the bubble is made of empty lines; more than one in a row is one.
        var out = [String]()
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// One selection at a time: clicking somewhere else lets go of this one.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: 0, length: 0)) }
        return resigned
    }

    static func make() -> MessageTextView {
        // TextKit 1, built by hand: it has text tables, and a layout manager that can be
        // subclassed to draw behind the text.
        let storage = NSTextStorage()
        let manager = MessageLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let view = MessageTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.appearance = NSAppearance(named: .darkAqua)
        view.linkTextAttributes = [
            .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    /// Shows a message's text.
    func show(_ text: String, size: CGFloat) {
        let wanted = Markdown.attributed(text, size: size)
        guard textStorage?.isEqual(to: wanted) != true else { return }
        textStorage?.setAttributedString(wanted)
        measured = [:]
        fillsWidth = false
        trailingPadding = 0
        let whole = NSRange(location: 0, length: wanted.length)
        wanted.enumerateAttribute(.paragraphStyle, in: whole) { value, _, _ in
            if !((value as? NSParagraphStyle)?.textBlocks.isEmpty ?? true) { fillsWidth = true }
        }
        wanted.enumerateAttribute(.messageBlock, in: whole) { value, _, _ in
            if (value as? MessageBlock)?.kind == .code { trailingPadding = 9 }
        }
    }

    /// The size the text takes when it may be at most `width` wide.
    func fit(width: CGFloat) -> CGSize {
        guard let container = textContainer, let manager = layoutManager else { return .zero }
        let key = Int((width * 2).rounded())
        if let hit = measured[key] { return hit }
        let before = container.size
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        // The layout manager's own used rectangle reports the full container width once
        // the container has been resized, so the width is taken from the lines themselves.
        var right: CGFloat = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in
            right = max(right, used.maxX)
        }
        let wanted = fillsWidth ? width : ceil(right) + trailingPadding
        let size = CGSize(width: min(width, wanted), height: ceil(manager.usedRect(for: container).maxY))
        measured[key] = size
        // Measuring must not leave the text laid out for a width it is not shown at.
        if bounds.width > 0, before.width != width { container.size = NSSize(width: bounds.width, height: before.height) }
        return size
    }
}

/// Message text you can select across, with the markdown agents actually write.
struct MessageText: NSViewRepresentable {
    let text: String
    var size: CGFloat = 13

    func makeNSView(context: Context) -> MessageTextView { .make() }

    func updateNSView(_ view: MessageTextView, context: Context) {
        view.show(text, size: size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageTextView, context: Context) -> CGSize? {
        // No width, or an unbounded one, asks how wide the text would like to be.
        var width = proposal.width ?? 4000
        if !width.isFinite || width > 4000 { width = 4000 }
        // A zero width asks for the smallest it can be; one word per line is not an answer
        // worth laying out.
        return view.fit(width: max(width, 60))
    }
}
