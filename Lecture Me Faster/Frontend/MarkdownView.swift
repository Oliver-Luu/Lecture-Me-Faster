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

    var body: some View {
        let blocks = Self.blocks(from: text)
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                view(for: blocks[index])
            }
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title.bold() : level == 2 ? .title2.bold() : .headline)
                .padding(.top, level <= 2 ? 10 : 4)
                .textSelection(.enabled)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary)
                Text(Self.inline(text)).textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .code(let code):
            Text(code)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 6))
        case .paragraph(let text):
            Text(Self.inline(text)).textSelection(.enabled)
        case .rule:
            Divider()
        }
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
