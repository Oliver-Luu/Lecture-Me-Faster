import Foundation
import Testing
@testable import Lecture_Me_Faster

/// A model per level of detail (e.g. Haiku for Key points, Opus for Complete).
@MainActor
@Suite(.serialized)
struct LevelModelTests {
    private static let host = "level-models.lecture-me-faster.test"

    private func settings() -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIURL = "http://\(Self.host)/v1"
        stored.openAIModel = "default-model"
        stored.openAIContextTokens = 128_000
        return AppSettings(unsaved: stored)
    }

    @Test func aLevelUsesItsOwnModelAndOthersTheDefault() throws {
        let settings = settings()
        settings.claudeKey = "test-key"
        settings.setModelChoice(.init(provider: .claude, model: "claude-haiku-5-5"), for: .keyPoints)
        settings.setModelChoice(.init(provider: .openAICompatible, service: OpenAIService.custom.id, model: "big-model"), for: .complete)

        let brief = try settings.configuration(for: .keyPoints)
        #expect(brief.provider == .claude)
        #expect(brief.model == "claude-haiku-5-5")
        #expect(brief.apiKey == "test-key")
        let complete = try settings.configuration(for: .complete)
        #expect(complete.provider == .openAICompatible)
        #expect(complete.model == "big-model")
        #expect(complete.baseURL.host() == Self.host)
        #expect(try settings.configuration(for: .detailed).model == "default-model")
        #expect(try settings.configuration(for: nil).model == "default-model")

        #expect(settings.chosenModelName(for: .keyPoints) == "Claude: claude-haiku-5-5")
        #expect(settings.chosenModelName(for: .detailed) == settings.chosenModelName)

        settings.setModelChoice(nil, for: .keyPoints)
        #expect(try settings.configuration(for: .keyPoints).model == "default-model", "Back to the default")
    }

    @Test func aLevelModelWithoutItsKeySaysWhichLevelNeedsIt() {
        let settings = settings()
        settings.setModelChoice(.init(provider: .claude, model: "claude-haiku-5-5"), for: .keyPoints)
        #expect(throws: AppSettings.Problem.self) { try settings.configuration(for: .keyPoints) }
        let message = (try? settings.configuration(for: .keyPoints)) == nil
            ? (Result { try settings.configuration(for: .keyPoints) }.failure?.localizedDescription ?? "") : ""
        #expect(message.contains("Key points"))
    }

    @Test func levelModelsAreSavedAndOlderSettingsLoad() throws {
        var stored = AppSettings.Stored()
        stored.levelModels["0"] = .init(provider: .claude, model: "claude-haiku-5-5")
        let decoded = try JSONDecoder().decode(AppSettings.Stored.self, from: JSONEncoder().encode(stored))
        #expect(decoded.levelModels["0"]?.model == "claude-haiku-5-5")
        let old = try JSONDecoder().decode(AppSettings.Stored.self, from: Data(#"{"maxFrames":30}"#.utf8))
        #expect(old.levelModels.isEmpty)
    }

    @Test func notesAreWrittenWithTheLevelsModel() async throws {
        let log = MockModelServer.start(host: Self.host)
        defer { MockModelServer.stop(host: Self.host) }
        let root = FileManager.default.temporaryDirectory.appending(path: "LevelModels-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = LectureHistory(root: root)
        let saved = try history.save(
            title: "Short", transcript: [TranscriptSegment(seconds: 0, text: "Today, sorting.")], frames: [], distinctFrameCount: 0
        )
        let session = LectureSession(history: history)
        session.open(saved)
        let settings = settings()
        settings.setModelChoice(.init(provider: .openAICompatible, service: OpenAIService.custom.id, model: "fast-model"), for: .keyPoints)

        for detail in [NoteDetail.keyPoints, .detailed] {
            session.resummarize(settings: settings, detail: detail)
            for _ in 0..<400 where session.isBusy { try await Task.sleep(for: .milliseconds(25)) }
            #expect(session.phase == .done)
        }
        let chats = zip(log.requestURLs, log.requests).filter { $0.0.path().hasSuffix("chat/completions") }.map(\.1)
        #expect(chats.count == 2)
        #expect(chats.first?.contains(#""model":"fast-model""#) == true, "Key points with its own model")
        #expect(chats.last?.contains(#""model":"default-model""#) == true, "Detailed with the default")
        #expect(session.versions.first { $0.detail == .keyPoints }?.model == "fast-model", "Recorded with the notes")
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}
