import Testing
@testable import Lecture_Me_Faster

@MainActor struct MarkdownViewTests {
    @Test func parsesHeadingsListsParagraphsAndRules() {
        let markdown = """
            # Entropy
            ## Definition
            Entropy measures
            uncertainty.

            - first
              - nested
            * star
            2. second
            ---
            #hashtag is not a heading
            """
        #expect(MarkdownView.blocks(from: markdown) == [
            .heading(level: 1, text: "Entropy"),
            .heading(level: 2, text: "Definition"),
            .paragraph("Entropy measures uncertainty."),
            .listItem(indent: 0, marker: "•", text: "first"),
            .listItem(indent: 1, marker: "•", text: "nested"),
            .listItem(indent: 0, marker: "•", text: "star"),
            .listItem(indent: 0, marker: "2.", text: "second"),
            .rule,
            .paragraph("#hashtag is not a heading"),
        ])
    }

    @Test func keepsCodeBlocksVerbatim() {
        let markdown = """
            Before
            ```swift
            let x = 1
              # not a heading
            ```
            After
            """
        #expect(MarkdownView.blocks(from: markdown) == [
            .paragraph("Before"),
            .code("let x = 1\n  # not a heading"),
            .paragraph("After"),
        ])
    }

    @Test func showsCodeBlockThatIsStillStreaming() {
        #expect(MarkdownView.blocks(from: "```\nhalf written") == [.code("half written")])
    }

    @Test func emptyTextHasNoBlocks() {
        #expect(MarkdownView.blocks(from: "").isEmpty)
    }
}
