import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Lecture_Me_Faster

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Models that can't see images get each slide as the text read from it plus a short description.
@MainActor
@Suite(.serialized)
struct SlidesAsTextTests {
    private func texts(_ parts: [FileToAI.Part]) -> [String] {
        parts.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    private func imageCount(_ parts: [FileToAI.Part]) -> Int {
        parts.count { if case .image = $0 { true } else { false } }
    }

    private let transcript = [TranscriptSegment(seconds: 0, text: "Today, sorting.")]
    private let fakeFrames = [LectureFrame(seconds: 0, jpeg: Data([1])), LectureFrame(seconds: 75, jpeg: Data([2]))]

    // MARK: Prompt

    @Test func textSlidesReplaceTheImages() {
        let parts = FileToAI.promptParts(
            title: "T", transcript: transcript, frames: fakeFrames, slideTexts: ["Text on the slide:\nMerge sort", "Text on the slide: (none found)"]
        )
        let all = texts(parts)
        #expect(imageCount(parts) == 0)
        #expect(all.contains { $0.contains("You cannot see them") })
        #expect(all.contains("[0:00]\nText on the slide:\nMerge sort"))
        #expect(all.contains("[1:15]\nText on the slide: (none found)"))
        #expect(!all.contains("No slides are included."))
    }

    @Test func mixedSlidesSendPicturesAsImagesAndTheRestAsText() {
        let parts = FileToAI.promptParts(
            title: "T", transcript: transcript, frames: fakeFrames, slideTexts: [nil, "Text on the slide:\nMerge sort"]
        )
        let all = texts(parts)
        #expect(imageCount(parts) == 1)
        #expect(all.contains { $0.contains("The 1 with the most diagrams and pictures are images. The other 1 are mostly text") })
        #expect(all.contains("[0:00]"), "An image slide keeps its timestamp line")
        #expect(all.contains("[1:15]\nText on the slide:\nMerge sort"))
    }

    @Test func planningCountsTextSlidesByTheirOwnSize() {
        let plan = LongLectures.plan(
            transcript: [], frameTimes: [0, 10, 20], documents: [], budget: 1_000_000, overhead: 0,
            imageTokens: 1_000, frameTokens: [1_000, 30, 30]
        )
        #expect(plan.estimatedTokens == 1_060)
        let mismatched = LongLectures.plan(transcript: [], frameTimes: [0, 10], documents: [], budget: 1_000_000, overhead: 0, imageTokens: 500, frameTokens: [1])
        #expect(mismatched.estimatedTokens == 1_000, "A list of the wrong length is ignored")
    }

    @Test func slidesTabExplainsHowSlidesAreSent() {
        #expect(LectureResultView.slidesNote(kept: 20, distinct: 20, imageLimit: 30) == nil)
        #expect(LectureResultView.slidesNote(kept: 45, distinct: 45, imageLimit: 30)?.contains("In each request to the model, the 30 with the most diagrams") == true)
        #expect(LectureResultView.slidesNote(kept: 300, distinct: 340, imageLimit: 30)?.contains("340 distinct slides") == true)
    }

    @Test func mismatchedTextsFallBackToImages() {
        let parts = FileToAI.promptParts(title: "T", transcript: transcript, frames: fakeFrames, slideTexts: ["only one"])
        #expect(imageCount(parts) == 2)
    }

    @Test func slideTextCombinesWordsAndDescription() {
        #expect(FileToAI.slideAsText(recognized: " Merge sort\nO(n log n) ", description: " A tree diagram. ")
            == "Text on the slide:\nMerge sort\nO(n log n)\nWhat the slide shows: A tree diagram.")
        #expect(FileToAI.slideAsText(recognized: "", description: nil) == "Text on the slide: (none found)")
        #expect(FileToAI.slideAsText(recognized: "Hi", description: "") == "Text on the slide:\nHi")
    }

    @Test func recognizesProvidersRejectingImages() {
        let rejections = [
            "The model server returned an error (HTTP 400): Invalid content type. image_url is only supported by certain models.",
            "The model server returned an error (HTTP 400): This model does not support Vision input",
            "The model server returned an error (HTTP 422): unknown variant `image_url`, expected `text`",
            "The model server returned an error (HTTP 400): Model is not multimodal",
        ]
        for message in rejections {
            #expect(FileToAI.isImageRejection(FileToAI.Failure.api(message)), "\(message)")
        }
        #expect(!FileToAI.isImageRejection(FileToAI.Failure.api("The model server returned an error (HTTP 401): Invalid API key")))
        #expect(!FileToAI.isImageRejection(FileToAI.Failure.refused))
        #expect(!FileToAI.isImageRejection(URLError(.timedOut)))
    }

    @Test func oldNotesWithoutTheFlagStillLoad() throws {
        let json = #"{"text":"n","model":"m","writtenAt":0}"#
        let version = try JSONDecoder().decode(NoteVersion.self, from: Data(json.utf8))
        #expect(version.slidesAsText == nil)
    }

    // MARK: The whole flow, against MockModelServer

    private static let host = "slides-as-text.lecture-me-faster.test"

    private func settings() -> AppSettings {
        var stored = AppSettings.Stored()
        stored.provider = .openAICompatible
        stored.openAIURL = "http://\(Self.host)/v1"
        stored.openAIModel = "text-only-model"
        stored.openAIContextTokens = 128_000
        return AppSettings(unsaved: stored)
    }

    private func jpeg(_ lines: [String]) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, TestDocuments.image(of: lines), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A saved lecture with two real slides, opened in a session whose slide describer is fake.
    private func session(root: URL) throws -> LectureSession {
        let history = LectureHistory(root: root)
        let frames = [
            LectureFrame(seconds: 0, jpeg: try jpeg(["Merge Sort"])),
            LectureFrame(seconds: 30, jpeg: try jpeg(["Quicksort Partition"])),
        ]
        let saved = try history.save(title: "Sorting", transcript: transcript, frames: frames, distinctFrameCount: 2)
        let session = LectureSession(history: history)
        session.describeSlide = { _ in "A diagram of an array being split." }
        session.open(saved)
        return session
    }

    private func waitUntilIdle(_ session: LectureSession) async throws {
        for _ in 0..<400 where session.isBusy { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!session.isBusy)
    }

    private func chatRequests(_ log: MockModelServer.Log) -> [String] {
        zip(log.requestURLs, log.requests).filter { $0.0.path().hasSuffix("chat/completions") }.map(\.1)
    }

    @Test func modelListSaysNoImagesSoSlidesGoAsTextFromTheStart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlidesAsText-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = MockModelServer.start(host: Self.host) { request in
            guard request.url?.path().hasSuffix("/models") == true else { return nil }
            return (200, #"{"data":[{"id":"text-only-model","architecture":{"input_modalities":["text"]}}]}"#)
        }
        defer { MockModelServer.stop(host: Self.host) }
        let session = try session(root: root)

        session.resummarize(settings: settings(), detail: .detailed)
        try await waitUntilIdle(session)
        #expect(session.phase == .done)
        let chats = chatRequests(log)
        #expect(chats.count == 1, "Known up front, so no wasted request with images")
        let body = try #require(chats.first)
        #expect(!body.contains("image_url"))
        #expect(body.contains("Merge Sort"))
        #expect(body.contains("Quicksort Partition"))
        #expect(body.contains("A diagram of an array being split."))
        let saved = try #require(LectureHistory(root: root).lectures.first?.noteVersions.first)
        #expect(saved.slidesAsText == true)
    }

    @Test func withDescriptionsOffSlidesGoAsTextOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlidesAsText-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = MockModelServer.start(host: Self.host) { request in
            guard request.url?.path().hasSuffix("/models") == true else { return nil }
            return (200, #"{"data":[{"id":"text-only-model","architecture":{"input_modalities":["text"]}}]}"#)
        }
        defer { MockModelServer.stop(host: Self.host) }
        let session = try session(root: root)
        let described = Counter()
        session.describeSlide = { _ in _ = described.next(); return "A diagram of an array being split." }
        let faster = settings()
        faster.apply(.faster)

        session.resummarize(settings: faster, detail: .detailed)
        try await waitUntilIdle(session)
        #expect(session.phase == .done)
        let body = try #require(chatRequests(log).first)
        #expect(body.contains("Merge Sort"), "The slide's text still goes")
        #expect(!body.contains("A diagram of an array being split."))
        #expect(described.next() == 1, "No description was written")
    }

    @Test func rejectedImagesAreSentAgainAsText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlidesAsText-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // The server has already read the body, so reject the first chat request (which has the images;
        // checked below) the way OpenAI rejects images for a text-only model.
        let chatCount = Counter()
        let log = MockModelServer.start(host: Self.host) { request in
            // The list doesn't say what the model accepts, like OpenAI's own list.
            if request.url?.path().hasSuffix("/models") == true { return (200, #"{"data":[{"id":"text-only-model"}]}"#) }
            if chatCount.next() == 1 {
                return (400, #"{"error":{"message":"Invalid content type. image_url is only supported by certain models."}}"#)
            }
            return nil
        }
        defer { MockModelServer.stop(host: Self.host) }
        let session = try session(root: root)

        session.resummarize(settings: settings(), detail: .detailed)
        try await waitUntilIdle(session)
        #expect(session.phase == .done)
        let chats = chatRequests(log)
        #expect(chats.count == 2, "Images first, then text after the rejection")
        #expect(chats.first?.contains("image_url") == true)
        #expect(chats.last?.contains("image_url") == false)
        #expect(chats.last?.contains("Merge Sort") == true)
        #expect(session.notes(for: .detailed).hasPrefix("Reply"))
        let saved = try #require(LectureHistory(root: root).lectures.first?.noteVersions.first)
        #expect(saved.slidesAsText == true)
    }

    @Test func otherErrorsAreNotRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlidesAsText-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = MockModelServer.start(host: Self.host) { request in
            if request.url?.path().hasSuffix("/models") == true { return (200, #"{"data":[{"id":"text-only-model"}]}"#) }
            return (401, #"{"error":{"message":"Invalid API key"}}"#)
        }
        defer { MockModelServer.stop(host: Self.host) }
        let session = try session(root: root)

        session.resummarize(settings: settings(), detail: .detailed)
        try await waitUntilIdle(session)
        guard case .failed = session.phase else { Issue.record("Expected a failure, got \(session.phase)"); return }
        #expect(chatRequests(log).count == 1)
    }

    @Test func slidesOverTheLimitGoAsTextInsteadOfBeingDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlidesAsText-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = MockModelServer.start(host: Self.host) { request in
            guard request.url?.path().hasSuffix("/models") == true else { return nil }
            return (200, #"{"data":[{"id":"text-only-model","architecture":{"input_modalities":["text","image"]}}]}"#)
        }
        defer { MockModelServer.stop(host: Self.host) }
        let session = try session(root: root)
        var limited = settings()
        limited.stored.maxFrames = 1

        session.resummarize(settings: limited, detail: .detailed)
        try await waitUntilIdle(session)
        #expect(session.phase == .done)
        let body = try #require(chatRequests(log).first)
        // OpenAI's format names "image_url" twice per image: as the part's type and as its key.
        #expect(body.components(separatedBy: "image_url").count - 1 == 2, "One slide as an image")
        #expect(body.contains("Merge Sort") || body.contains("Quicksort Partition"), "The other as its text")
        let saved = try #require(LectureHistory(root: root).lectures.first?.noteVersions.first)
        #expect(saved.slidesAsText == nil, "Not the can't-see-images warning")
    }

    @Test func aLectureWrittenInPartsNeverGoesOverTheImageLimitInARequest() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlidesAsText-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = MockModelServer.start(host: Self.host) { request in
            guard request.url?.path().hasSuffix("/models") == true else { return nil }
            return (200, #"{"data":[{"id":"text-only-model","architecture":{"input_modalities":["text","image"]}}]}"#)
        }
        defer { MockModelServer.stop(host: Self.host) }
        // A long transcript, so the lecture needs several requests; one slide early and one late.
        let history = LectureHistory(root: root)
        let long = (0..<120).map {
            TranscriptSegment(seconds: Double($0), text: "Sentence \($0) about sorting algorithms and how partitions are chosen in practice for large inputs.")
        }
        let frames = [
            LectureFrame(seconds: 0, jpeg: try jpeg(["Merge Sort"])),
            LectureFrame(seconds: 110, jpeg: try jpeg(["Quicksort Partition"])),
        ]
        let saved = try history.save(title: "Sorting", transcript: long, frames: frames, distinctFrameCount: 2)
        let session = LectureSession(history: history)
        session.open(saved)
        var limited = settings()
        limited.stored.maxFrames = 1
        limited.stored.openAIContextTokens = 9_000
        limited.stored.splitWithoutAsking = true

        session.resummarize(settings: limited, detail: .detailed)
        try await waitUntilIdle(session)
        #expect(session.phase == .done)
        let chats = chatRequests(log)
        #expect(chats.count > 2, "Written in parts")
        // OpenAI's format names "image_url" twice per image.
        let imagesPerRequest = chats.map { ($0.components(separatedBy: "image_url").count - 1) / 2 }
        #expect(imagesPerRequest.allSatisfy { $0 <= 1 }, "No request over the limit: \(imagesPerRequest)")
        #expect(imagesPerRequest.reduce(0, +) >= 1, "At least the lecture-wide limit: \(imagesPerRequest)")
    }

    @Test func modelsThatSeeImagesStillGetImages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SlidesAsText-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = MockModelServer.start(host: Self.host) { request in
            guard request.url?.path().hasSuffix("/models") == true else { return nil }
            return (200, #"{"data":[{"id":"text-only-model","architecture":{"input_modalities":["text","image"]}}]}"#)
        }
        defer { MockModelServer.stop(host: Self.host) }
        let session = try session(root: root)

        session.resummarize(settings: settings(), detail: .detailed)
        try await waitUntilIdle(session)
        #expect(session.phase == .done)
        #expect(chatRequests(log).first?.contains("image_url") == true)
        let saved = try #require(LectureHistory(root: root).lectures.first?.noteVersions.first)
        #expect(saved.slidesAsText == nil)
    }
}

/// What the real on-device model says about a slide with a diagram. Runs only when asked:
/// `TEST_RUNNER_LMF_LIVE_APPLE=1 xcodebuild test ...`. Prints the description for a person to judge.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LMF_LIVE_APPLE"] == "1" && AppleIntelligence.isAvailable))
struct LiveSlideDescriptionTests {
    /// A white slide with a title and a bar chart of three labelled bars (heights 1, 2, 3).
    private func barChartSlide() throws -> Data {
        let width = 1280, height = 720
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        for (index, value) in [1.0, 2.0, 3.0].enumerated() {
            context.fill(CGRect(x: 300 + index * 250, y: 100, width: 150, height: Int(value * 150)))
        }
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(4)
        context.stroke(CGRect(x: 250, y: 100, width: 800, height: 0))
        context.move(to: CGPoint(x: 250, y: 100)); context.addLine(to: CGPoint(x: 250, y: 600)); context.strokePath()
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func describesABarChart() async throws {
        let description = try await AppleIntelligence.describeSlide(try barChartSlide())
        print("SLIDE-DESCRIPTION: \(description)")
        #expect(!description.isEmpty)
    }
}
