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

    /// One `Text` for the whole document, so a selection can run across headings, bullets and paragraphs
    /// (separate `Text` views each had their own selection, so only one line could be copied at a time).
    var body: some View {
        Text(Self.document(from: Self.blocks(from: text)))
            .textSelection(.enabled)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                heading.font = level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .headline
                document += heading
            case .listItem(let indent, let marker, let text):
                var prefix = AttributedString(String(repeating: "    ", count: indent) + marker + "  ")
                prefix.foregroundColor = .secondary
                document += prefix + inline(text)
            case .code(let code):
                var block = AttributedString(code)
                block.font = .callout.monospaced()
                block.backgroundColor = Color.secondary.opacity(0.15)
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
