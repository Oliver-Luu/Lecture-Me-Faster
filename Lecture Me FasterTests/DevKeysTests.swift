import Testing
@testable import Lecture_Me_Faster

struct DevKeysTests {
    @Test func parsesKeysAndSkipsCommentsBlanksAndEmptyValues() {
        let text = """
            # Development keys
            ANTHROPIC_API_KEY=sk-ant-abc=123

              SPACED = value with spaces
            QUOTED="quoted value"
            EMPTY=
            not a key line
            """
        #expect(DevKeys.parse(text) == [
            "ANTHROPIC_API_KEY": "sk-ant-abc=123",
            "SPACED": "value with spaces",
            "QUOTED": "quoted value",
        ])
    }

    @Test func emptyFileHasNoKeys() {
        #expect(DevKeys.parse("").isEmpty)
    }
}
