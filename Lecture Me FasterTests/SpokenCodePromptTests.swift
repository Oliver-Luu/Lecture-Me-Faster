import Foundation
import Testing
@testable import Lecture_Me_Faster

/// What was measured on Apple Intelligence (2026-11-13) and kept or turned off.
struct SpokenCodePromptTests {
    @Test func theUnprovenChangesAreOff() {
        #expect(!AppleIntelligence.usesGreedySampling, "Greedy made the small model loop")
        #expect(!FileToAI.includesSpokenCodeGuidance, "Its effect was smaller than run-to-run variation")
        #expect(!FileToAI.systemPrompt(detail: .keyPoints).contains(#""b sub k" is b[k]"#))
    }

    @Test func anEmptyMaterialsSectionIsRemoved() {
        let notes = """
            # Pointers
            - Array name means a pointer to element 0.

            ---

            ## From the materials
            There was nothing to write notes from.

            ## Key takeaways
            - Pointers move in elements, not bytes.
            """
        let cleaned = FileToAI.removingEmptyMaterialsSection(from: notes)
        #expect(!cleaned.contains("From the materials"))
        #expect(!cleaned.contains("nothing to write"))
        #expect(!cleaned.contains("---"), "Its rule goes with it")
        #expect(cleaned.contains("## Key takeaways\n- Pointers move in elements, not bytes."), "The next section stays")
        #expect(cleaned.hasPrefix("# Pointers\n- Array name means a pointer to element 0."))
        // A section at the end, and a top-level one.
        #expect(FileToAI.removingEmptyMaterialsSection(from: "# A\ntext\n# From the materials\n- x") == "# A\ntext")
        #expect(FileToAI.removingEmptyMaterialsSection(from: "# A\ntext") == "# A\ntext")
    }
}
