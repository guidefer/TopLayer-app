import SwiftUI

/// The markdown agents actually write: paragraphs, headings, lists, fenced code and
/// tables, plus bold, italics, inline code and links inside any of them. It is
/// deliberately small; anything it doesn't recognise is shown as plain text.
/// This file is the parser; `MessageText.swift` turns the blocks into text on screen.
enum Markdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(String, level: Int)
        case code(String)
        case list([ListItem])
        case table(header: [String], rows: [[String]])
        case rule
    }

    struct ListItem: Equatable {
        var marker: String      // "•" or "1."
        var indent: Int
        var text: String
    }

    private final class Box<Value> { let value: Value; init(_ value: Value) { self.value = value } }
    private static let inlineCache: NSCache<NSString, Box<AttributedString>> = {
        let cache = NSCache<NSString, Box<AttributedString>>()
        cache.countLimit = 2000
        return cache
    }()
    private static let blockCache: NSCache<NSString, Box<[Block]>> = {
        let cache = NSCache<NSString, Box<[Block]>>()
        cache.countLimit = 400
        return cache
    }()

    /// Bold, italics, inline code and links. Parsed once per piece of text.
    static func inline(_ text: String) -> AttributedString {
        if let hit = inlineCache.object(forKey: text as NSString) { return hit.value }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        let result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        inlineCache.setObject(Box(result), forKey: text as NSString)
        return result
    }

    static func blocks(_ text: String) -> [Block] {
        if let hit = blockCache.object(forKey: text as NSString) { return hit.value }
        let result = parse(text)
        blockCache.setObject(Box(result), forKey: text as NSString)
        return result
    }

    private static func listMarker(_ line: Substring) -> (indent: Int, marker: String, rest: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)
        for bullet in ["- ", "* ", "• ", "+ "] where body.hasPrefix(bullet) {
            return (indent / 2, "•", String(body.dropFirst(bullet.count)))
        }
        let digits = body.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return (indent / 2, "\(digits).", String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func cells(_ line: Substring) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func isTableDivider(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func parse(_ text: String) -> [Block] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var blocks = [Block]()
        var paragraph = [Substring]()
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {                               // fenced code
                flush()
                var code = [Substring]()
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1                                              // the closing fence, if there was one
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }
            if trimmed.hasPrefix("#") {                                 // heading
                let level = trimmed.prefix { $0 == "#" }.count
                let title = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, !title.isEmpty, trimmed.dropFirst(level).hasPrefix(" ") {
                    flush()
                    blocks.append(.heading(title, level: level))
                    index += 1
                    continue
                }
            }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), Set(trimmed).count == 1 {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableDivider(lines[index + 1]) {   // table
                flush()
                let header = cells(line)
                var rows = [[String]]()
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if listMarker(line) != nil {                                // list
                flush()
                var items = [ListItem]()
                while index < lines.count {
                    let current = lines[index]
                    if let found = listMarker(current) {
                        items.append(ListItem(marker: found.marker, indent: found.indent, text: found.rest))
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty,
                              current.hasPrefix(" "), !items.isEmpty {
                        // An indented line continues the item above it.
                        items[items.count - 1].text += " " + current.trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flush()
        return blocks
    }
}

/// Message text. The whole message is one selectable piece of text (see `MessageText`),
/// so a selection can run across its paragraphs.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 13

    var body: some View {
        MessageText(text: text, size: size)
    }
}
