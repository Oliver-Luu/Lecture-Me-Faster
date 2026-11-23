import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Lecture_Me_Faster

/// Words read from the slides that the transcript never contains go to the model as exact spellings,
/// so it can fix terms the speech recognizer misheard.
struct SlideTermsTests {
    private func segments(_ texts: String...) -> [TranscriptSegment] {
        texts.enumerated().map { TranscriptSegment(seconds: Double($0.offset * 10), text: $0.element) }
    }

    // MARK: Picking terms

    @Test func keepsOnlySlideWordsTheTranscriptNeverSays() {
        // Real output from SpeechTranscriber on a `say` recording (measured 2026-11-12).
        let transcript = segments(
            "Today we continue with the Kol Megorov complexity of strings.",
            "Recall that Dyke's trasalgorithm fails with negative edges, so we use Bellman Ford instead."
        )
        let slide = "Kolmogorov Complexity of Strings\nDijkstra's algorithm fails with negative edges\nUse Bellman-Ford"
        let terms = FileToAI.slideTerms(slideText: [slide], transcript: transcript)
        // "algorithm" stays: the recognizer fused it into "trasalgorithm", so it was never heard on its own.
        #expect(terms == ["Kolmogorov", "Dijkstra's", "algorithm"])
    }

    @Test func ignoresCaseShortWordsNumbersAndRepeats() {
        let transcript = segments("the eigenvalues are real")
        let slides = ["EIGENVALUES are REAL", "Hermitian x2 2026 Hermitian", "hermitian matrix"]
        let terms = FileToAI.slideTerms(slideText: slides, transcript: transcript)
        #expect(terms == ["Hermitian", "matrix"])
    }

    @Test func possessivesAndHyphensMatchTheirSpokenParts() {
        let transcript = segments("Bezout said hi to Cauchy. Schwarz too.")
        let terms = FileToAI.slideTerms(
            slideText: ["Bezout's identity and Cauchy-Schwarz and Ornstein-Uhlenbeck"], transcript: transcript
        )
        #expect(terms == ["identity", "Ornstein-Uhlenbeck"])
    }

    @Test func listIsCappedAtTheLimit() {
        let slide = (1...20).map { "term\(String(repeating: "x", count: $0))" }.joined(separator: " ")
        let terms = FileToAI.slideTerms(slideText: [slide], transcript: segments("nothing"), limit: 5)
        #expect(terms.count == 5)
        #expect(terms.first == "termx")
    }

    @Test func wordsKeepInnerHyphensAndApostrophesButNotTrailingOnes() {
        #expect(FileToAI.words(in: "Bellman-Ford, Bézout's — end- 'quoted' x²") == ["Bellman-Ford", "Bézout's", "end", "quoted", "x²"])
    }

    // MARK: Prompt

    private func texts(_ parts: [FileToAI.Part]) -> [String] {
        parts.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    @Test func termsGoJustBeforeTheTranscript() {
        let parts = FileToAI.promptParts(
            title: "T", transcript: segments("hello"), frames: [], slideTerms: ["Kolmogorov", "Dijkstra"]
        )
        let all = texts(parts)
        #expect(all.count >= 2)
        #expect(all[all.count - 2].hasSuffix("\nKolmogorov, Dijkstra"))
        #expect(all.last?.hasPrefix("Transcript:") == true)
    }

    @Test func noTermsMeansNoTermsBlock() {
        let all = texts(FileToAI.promptParts(title: "T", transcript: segments("hello"), frames: []))
        #expect(!all.contains { $0.hasPrefix("Words read from the slides") })
        // With no transcript there is nothing to correct.
        let noTranscript = texts(FileToAI.promptParts(title: "T", transcript: [], frames: [], slideTerms: ["Kolmogorov"]))
        #expect(!noTranscript.contains { $0.hasPrefix("Words read from the slides") })
    }

    @Test func systemPromptPointsAtTheTermList() {
        #expect(FileToAI.systemPrompt(detail: .detailed).contains("the list of terms read from the slides"))
    }

    // MARK: Reading slides

    private func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func readsTheTextOnEachFrameInOrder() async throws {
        let frames = [
            LectureFrame(seconds: 0, jpeg: try jpeg(TestDocuments.image(of: ["Kolmogorov Complexity"]))),
            LectureFrame(seconds: 10, jpeg: Data([0, 1, 2])),  // not an image: read as empty, not a failure
            LectureFrame(seconds: 20, jpeg: try jpeg(TestDocuments.image(of: ["Ornstein-Uhlenbeck Process"]))),
        ]
        let texts = await VideoToFrames.analyze(frames).map(\.text)
        #expect(texts.count == 3)
        #expect(texts[0].contains("Kolmogorov"))
        #expect(texts[1].isEmpty)
        #expect(texts[2].contains("Ornstein-Uhlenbeck"))
    }
}

/// Does the term list make the real on-device model spell misheard terms correctly? Runs only when
/// asked: `TEST_RUNNER_LMF_LIVE_APPLE=1 xcodebuild test ...`. Prints the counts for both runs.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LMF_LIVE_APPLE"] == "1" && AppleIntelligence.isAvailable))
struct LiveSlideTermsTests {
    @Test func termListFixesMisheardTermsInNotes() async throws {
        // SpeechTranscriber's real output for a `say` recording of the slide text below (2026-11-12).
        let heard = """
            Today we continue with the Kol Megorov complexity of strings.  Recall that Dyke's trasalgorithm \
            fails with negative edges, so we use Bellman Ford instead.  Next, the Nyquist rate tells us to \
            sample it twice the bandwidth.  In linear algebra, the eigen values of a hermission matrix are \
            real.  Finally, Bayzout's identity gives us the extended Euclidean algorithm, and the Koshi \
            Schwartz inequality bounds the inner product.  Professor Zipansky will cover the Lagrangian and \
            the Hamiltonian next week, along with the Ornstein Lenbeck process.
            """
        let slides = [
            "Kolmogorov Complexity\nDijkstra's algorithm vs. Bellman-Ford",
            "Nyquist rate\nEigenvalues of a Hermitian matrix",
            "Bézout's identity\nCauchy-Schwarz inequality",
            "Next week (Prof. Szczepański): Lagrangian, Hamiltonian, Ornstein-Uhlenbeck process",
        ]
        let transcript = [TranscriptSegment(seconds: 0, text: heard)]
        let terms = FileToAI.slideTerms(slideText: slides, transcript: transcript)
        let targets = ["Kolmogorov", "Dijkstra", "Hermitian", "Bézout", "Cauchy", "Schwarz", "Szczepański", "Uhlenbeck"]

        func notes(with terms: [String]) async throws -> String {
            let parts = FileToAI.promptParts(title: "Algorithms review", transcript: transcript, frames: [], slideTerms: terms)
            var text = ""
            for try await chunk in AppleIntelligence.stream(parts, system: FileToAI.systemPrompt(detail: .detailed), maximumTokens: 1_500) {
                text += chunk
            }
            return text
        }
        // The on-device model sometimes declines; say which request did, so a refusal caused by the
        // term list would show up.
        let without: String, with: String
        do { without = try await notes(with: []) } catch { print("SLIDE-TERMS without list failed: \(error)"); throw error }
        do { with = try await notes(with: terms) } catch { print("SLIDE-TERMS with list failed: \(error)"); throw error }
        let hitsWithout = targets.filter { without.contains($0) }
        let hitsWith = targets.filter { with.contains($0) }
        print("SLIDE-TERMS terms sent: \(terms)")
        print("SLIDE-TERMS without list \(hitsWithout.count)/\(targets.count): \(hitsWithout)")
        print("SLIDE-TERMS with list \(hitsWith.count)/\(targets.count): \(hitsWith)")
        print("SLIDE-TERMS notes with list:\n\(with)")
        #expect(hitsWith.count > hitsWithout.count)
    }
}
