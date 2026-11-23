import SwiftUI

/// Renders the block-level Markdown the notes use: headings, lists, code blocks, and paragraphs.
struct MarkdownView: View {
    let text: String

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case listItem(indent: Int, marker: String, text: String)
        case code(String)
        case paragraph(String)
        case rule
    }

    /// Short notes are one `Text`, so a selection can run across headings, bullets and paragraphs.
    /// Long notes are several, split at headings and stacked lazily, so only the sections on screen are
    /// laid out: one `Text` holding 120,000 characters took 300 ms to lay out each time a lecture was
    /// opened (measured 2026-11-16). A selection then stays inside one section; Copy Notes copies it all.
    var body: some View {
        LazyVStack(alignment: .leading, spacing: Self.sectionSpacing) {
            ForEach(Array(Self.sections(for: text).enumerated()), id: \.offset) { _, section in
                Text(section)
                    .textSelection(.enabled)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// About the height of the blank line that separates blocks inside a section.
    private static let sectionSpacing: CGFloat = 21

    /// A section is closed at the next heading once it holds this many characters.
    static let sectionCharacters = 6_000

    /// The notes most recently shown, already parsed, so switching back to a lecture or redrawing the
    /// screen doesn't parse them again. Emptied by the system when memory is short.
    private static let cache: NSCache<NSString, ParsedNotes> = {
        let cache = NSCache<NSString, ParsedNotes>()
        cache.countLimit = 12
        return cache
    }()

    private final class ParsedNotes {
        let sections: [AttributedString]
        init(_ sections: [AttributedString]) { self.sections = sections }
    }

    static func sections(for text: String) -> [AttributedString] {
        if let cached = cache.object(forKey: text as NSString) { return cached.sections }
        let sections = sections(of: blocks(from: text)).map(document(from:))
        cache.setObject(ParsedNotes(sections), forKey: text as NSString)
        return sections
    }

    /// The blocks in groups to show as separate pieces of text. A new group starts at a heading once the
    /// current one has `limit` characters, or anywhere outside a list once it has four times that (notes
    /// with no headings). Notes shorter than `limit` stay in one group.
    static func sections(of blocks: [Block], limit: Int = sectionCharacters) -> [[Block]] {
        var sections: [[Block]] = []
        var current: [Block] = []
        var count = 0
        for block in blocks {
            let isHeading = { if case .heading = block { true } else { false } }()
            let isItem = { if case .listItem = block { true } else { false } }()
            if !current.isEmpty, (isHeading && count >= limit) || (!isItem && count >= limit * 4) {
                sections.append(current)
                current = []
                count = 0
            }
            current.append(block)
            count += characters(in: block)
        }
        if !current.isEmpty { sections.append(current) }
        return sections
    }

    private static func characters(in block: Block) -> Int {
        switch block {
        case .heading(_, let text), .listItem(_, _, let text), .code(let text), .paragraph(let text): text.count
        case .rule: 0
        }
    }

    /// The blocks as one attributed string: headings in larger bold type, list items indented with their
    /// markers, code in a monospaced font on a tinted background, and a blank line between blocks.
    static func document(from blocks: [Block]) -> AttributedString {
        var document = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                // List items follow each other directly; everything else is a paragraph apart.
                let previousIsItem = { if case .listItem = blocks[index - 1] { true } else { false } }()
                let isItem = { if case .listItem = block { true } else { false } }()
                document += AttributedString(previousIsItem && isItem ? "\n" : "\n\n")
            }
            switch block {
            case .heading(let level, let text):
                var heading = inline(text)
                // Three steps of size, so the outline of the lecture shows at a glance.
                heading.font = level == 1 ? .title.bold() : level == 2 ? .title3.weight(.semibold) : .headline
                document += heading
            case .listItem(let indent, let marker, let text):
                var prefix = AttributedString(String(repeating: "    ", count: indent) + marker + "  ")
                prefix.foregroundColor = .secondary
                document += prefix + inline(text)
            case .code(let code):
                var block = AttributedString(code)
                block.font = .callout.monospaced()
                block.backgroundColor = Color.secondary.opacity(0.12)
                document += block
            case .paragraph(let text):
                document += inline(text)
            case .rule:
                var rule = AttributedString(String(repeating: "\u{2500}", count: 24))
                rule.foregroundColor = .secondary
                document += rule
            }
        }
        return document
    }

    /// The notes as HTML, for pasting with formatting into Google Docs, Word, Pages or Notes.
    static func html(from text: String) -> String {
        var html: [String] = []
        var openList: String?
        func closeList() { if let tag = openList { html.append("</\(tag)>"); openList = nil } }
        for block in blocks(from: text) {
            switch block {
            case .listItem(_, let marker, let text):
                let tag = marker == "•" ? "ul" : "ol"
                if openList != tag { closeList(); html.append("<\(tag)>"); openList = tag }
                html.append("<li>\(inlineHTML(text))</li>")
                continue
            default:
                closeList()
            }
            switch block {
            case .heading(let level, let text): html.append("<h\(min(level, 6))>\(inlineHTML(text))</h\(min(level, 6))>")
            case .code(let code): html.append("<pre><code>\(escaped(code))</code></pre>")
            case .paragraph(let text): html.append("<p>\(inlineHTML(text))</p>")
            case .rule: html.append("<hr>")
            case .listItem: break
            }
        }
        closeList()
        return "<meta charset=\"utf-8\">" + html.joined(separator: "\n")
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `**bold**`, `*italic*` / `_italic_` and `` `code` `` as HTML.
    private static func inlineHTML(_ text: String) -> String {
        var result = escaped(text)
        result = result.replacing(/`([^`]+)`/) { "<code>\($0.1)</code>" }
        result = result.replacing(/\*\*(.+?)\*\*/) { "<strong>\($0.1)</strong>" }
        // Emphasis only when the text inside touches the markers ("2 * 3 * 4" stays as it is).
        result = result.replacing(/(^|[^\w*])\*([^*\s](?:[^*\n]*[^*\s])?)\*(?![\w*])/) { "\($0.1)<em>\($0.2)</em>" }
        result = result.replacing(/(^|[^\w_])_([^_\s](?:[^_\n]*[^_\s])?)_(?![\w_])/) { "\($0.1)<em>\($0.2)</em>" }
        return result
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var codeLines: [String]?
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let lines = codeLines {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                continue
            }

            let indent = line.prefix { $0 == " " }.count / 2
            if trimmed.isEmpty {
                flushParagraph()
            } else if let match = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)/) {
                flushParagraph()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if let match = trimmed.firstMatch(of: /^[-*+]\s+(.*)/) {
                flushParagraph()
                blocks.append(.listItem(indent: indent, marker: "•", text: String(match.1)))
            } else if let match = trimmed.firstMatch(of: /^(\d+[.)])\s+(.*)/) {
                flushParagraph()
                blocks.append(.listItem(indent: indent, marker: String(match.1), text: String(match.2)))
            } else if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) {
                flushParagraph()
                blocks.append(.rule)
            } else {
                paragraph.append(trimmed)
            }
        }

        flushParagraph()
        // A code block still open at the end is one the model is midway through streaming.
        if let lines = codeLines {
            blocks.append(.code(lines.joined(separator: "\n")))
        }
        return blocks
    }
}
