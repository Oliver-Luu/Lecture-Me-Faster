import Foundation
import SwiftUI
import Testing
@testable import Lecture_Me_Faster

/// Notes can be selected and copied as a whole (2026-11-13: each line was its own Text, so only one
/// line could be selected at a time).
struct NotesCopyTests {
    private let notes = """
        # Pointers

        A *pointer* holds an **address**.

        - `&x` gives the address of x
        - `*p` follows the pointer
          - nested point
        1. First step
        2. Second step

        ```
        int *p = &x;
        ```

        ---
        Keep snake_case_name and 2 * 3 * 4 as they are.
        """

    @Test func theWholeNoteIsOneSelectableText() {
        let document = MarkdownView.document(from: MarkdownView.blocks(from: notes))
        let text = String(document.characters)
        // Every block is there, in order, in one string.
        for piece in ["Pointers", "A pointer holds an address.", "•  &x gives the address of x", "    •  nested point",
                      "1.  First step", "int *p = &x;", "snake_case_name"] {
            #expect(text.contains(piece), "\(piece)")
        }
        #expect(text.range(of: "Pointers")!.lowerBound < text.range(of: "Second step")!.lowerBound)
        #expect(text.contains("follows the pointer\n    •  nested point"), "List items one line apart")
        #expect(text.contains("Pointers\n\nA pointer"), "Other blocks a paragraph apart")
    }

    @Test func copiedNotesKeepTheirFormatting() {
        let html = MarkdownView.html(from: notes)
        #expect(html.contains("<h1>Pointers</h1>"))
        #expect(html.contains("<p>A <em>pointer</em> holds an <strong>address</strong>.</p>"))
        #expect(html.contains("<ul>\n<li><code>&amp;x</code> gives the address of x</li>"))
        #expect(html.contains("<ol>\n<li>First step</li>\n<li>Second step</li>\n</ol>"))
        #expect(html.contains("<pre><code>int *p = &amp;x;</code></pre>"))
        #expect(html.contains("<hr>"))
        #expect(html.contains("snake_case_name"), "Underscores inside a word aren't italics")
        #expect(html.contains("2 * 3 * 4"), "Spaced asterisks aren't italics")
    }
}
