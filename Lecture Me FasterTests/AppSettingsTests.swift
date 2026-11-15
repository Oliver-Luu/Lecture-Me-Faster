import Foundation
import Testing
@testable import Lecture_Me_Faster

@MainActor
struct AppSettingsTests {
    private func decode(_ json: String) throws -> AppSettings.Stored {
        try JSONDecoder().decode(AppSettings.Stored.self, from: Data(json.utf8))
    }

    @Test func settingsSavedBeforeNoteDetailExistedAreKept() throws {
        // What the first version of the app saved: no noteDetail key.
        let stored = try decode("""
            {"provider":"claude","claudeModel":"claude-sonnet-5-5","ollamaURL":"http://localhost:11434",
             "ollamaModel":"gemma3:12b","openAIURL":"http://localhost:1234/v1","openAIModel":"",
             "includeFrames":false,"maxFrames":45}
            """)
        #expect(stored.provider == .claude)
        #expect(stored.claudeModel == "claude-sonnet-5-5")
        #expect(stored.ollamaModel == "gemma3:12b")
        #expect(stored.includeFrames == false)
        #expect(stored.maxFrames == 45)
        #expect(stored.noteDetail == .detailed, "A missing setting takes its default")
    }

    @Test func noteDetailRoundTrips() throws {
        var stored = AppSettings.Stored()
        stored.noteDetail = .keyPoints
        let decoded = try JSONDecoder().decode(AppSettings.Stored.self, from: JSONEncoder().encode(stored))
        #expect(decoded.noteDetail == .keyPoints)
    }

    @Test func unknownValuesFallBackToDefaultsInsteadOfResettingEverything() throws {
        let stored = try decode(#"{"provider":"something-new","noteDetail":99,"maxFrames":10}"#)
        #expect(stored.provider == .apple)
        #expect(stored.noteDetail == .detailed)
        #expect(stored.maxFrames == 10)
    }

    @Test func transcribingInPiecesIsOnUnlessTurnedOff() throws {
        #expect(try decode(#"{"maxFrames":10}"#).transcribeInPieces, "Settings saved before the option existed")
        #expect(try decode(#"{"transcribeInPieces":false}"#).transcribeInPieces == false)
    }
}
