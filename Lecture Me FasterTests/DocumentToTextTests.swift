import Foundation
import Testing
@testable import Lecture_Me_Faster

struct DocumentToTextTests {
    private func read(_ data: Data, as ext: String) async throws -> LectureDocument {
        let url = try TestDocuments.write(data, extension: ext)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await DocumentToText.read(url)
    }

    // MARK: File types

    @Test func recognizesSupportedFileTypes() {
        let cases: [(String, LectureDocument.Kind?)] = [
            ("a.pdf", .pdf), ("a.PDF", .pdf), ("a.docx", .word), ("a.pptx", .powerPoint),
            ("a.txt", .text), ("a.md", .text), ("a.png", .image), ("a.jpg", .image), ("a.heic", .image),
            ("a.doc", nil), ("a.ppt", nil), ("a.key", nil), ("a.pages", nil), ("a.mp4", nil), ("a.zip", nil),
        ]
        for (name, kind) in cases {
            #expect(DocumentToText.kind(of: URL(filePath: "/tmp/\(name)")) == kind, "\(name)")
        }
    }

    // MARK: Word and PowerPoint

    @Test func readsAWordDocument() async throws {
        let document = try await read(TestDocuments.docx, as: "docx")
        #expect(document.kind == .word)
        #expect(document.name.hasSuffix(".docx"))
        #expect(document.text == "Entropy and the Second Law\nThe entropy of an isolated system never decreases.")
    }

    @Test func readsPowerPointSlidesInSlideOrder() async throws {
        let document = try await read(TestDocuments.pptx, as: "pptx")
        #expect(document.kind == .powerPoint)
        #expect(document.text == """
            [Slide 1]
            Slide 1 title
            Point & detail 1

            [Slide 2]
            Slide 2 title
            Point & detail 2

            [Slide 10]
            Slide 10 title
            Point & detail 10
            """)
    }

    @Test func zipReaderHandlesStoredAndCompressedEntries() throws {
        let zip = try ZipArchive(data: TestDocuments.pptx)
        #expect(Set(zip.names) == ["[Content_Types].xml", "ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/slide10.xml"])
        let stored = try #require(try zip.contents(of: "[Content_Types].xml"))
        #expect(String(decoding: stored, as: UTF8.self).contains("<Types"))
        let deflated = try #require(try zip.contents(of: "ppt/slides/slide2.xml"))
        #expect(String(decoding: deflated, as: UTF8.self).contains("Slide 2 title"))
        #expect(try zip.contents(of: "missing.xml") == nil)
    }

    @Test func aFileThatIsNotAZipIsRejected() async throws {
        #expect(throws: ZipArchive.Failure.self) { try ZipArchive(data: Data("not a zip".utf8)) }
        await #expect(throws: (any Error).self) { _ = try await read(Data("not a zip".utf8), as: "docx") }
    }

    // MARK: PDF and images

    @Test func readsTextPDFsPageByPage() async throws {
        let url = try TestDocuments.pdf(pages: [
            (["The first law conserves energy."], false),
            (["The second law: entropy increases."], false),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentToText.read(url)
        #expect(document.kind == .pdf)
        #expect(document.recognizedPages == 0)
        #expect(document.text.contains("[Page 1]\nThe first law conserves energy."))
        #expect(document.text.contains("[Page 2]\nThe second law: entropy increases."))
    }

    @Test func manyScannedPagesReadAtOnceStayInPageOrder() async throws {
        // More scanned pages than are read at once, mixed with typed ones.
        let pages = (1...20).map { number in
            (lines: ["PAGE \(number) HEADING"], scanned: number % 4 != 0)
        }
        let url = try TestDocuments.pdf(pages: pages)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentToText.read(url)
        #expect(document.recognizedPages == 15)
        let positions = try (1...20).map { number in
            try #require(document.text.range(of: "[Page \(number)]\n"), "Page \(number) is missing").lowerBound
        }
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }, "Pages in order")
        for number in 1...20 { #expect(document.text.contains("PAGE \(number) HEADING")) }
    }

    @Test func scannedPDFPagesAreReadWithTextRecognition() async throws {
        let url = try TestDocuments.pdf(pages: [
            (["Typed page about heat engines."], false),
            (["SCANNED HANDOUT", "Carnot efficiency"], true),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentToText.read(url)
        #expect(document.recognizedPages == 1, "Only the picture-only page needs recognition")
        #expect(document.text.contains("Typed page about heat engines."))
        #expect(document.text.contains("SCANNED HANDOUT"))
        #expect(document.text.contains("Carnot efficiency"))
        let handout = try #require(document.text.range(of: "SCANNED HANDOUT"))
        let carnot = try #require(document.text.range(of: "Carnot efficiency"))
        #expect(handout.lowerBound < carnot.lowerBound, "Recognized lines come back top to bottom")
    }

    @Test func readsTextInImages() async throws {
        let url = try TestDocuments.png(of: ["WHITEBOARD PHOTO", "Delta S equals Q over T"])
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentToText.read(url)
        #expect(document.kind == .image)
        #expect(document.recognizedPages == 1)
        #expect(document.text.contains("WHITEBOARD PHOTO"))
        #expect(document.text.contains("Delta S equals Q over T"))
    }

    // MARK: Text and limits

    @Test func longFilesAreTrimmedAndMarked() async throws {
        let long = String(repeating: "word ", count: DocumentToText.maxCharacters / 4)
        let document = try await read(Data(long.utf8), as: "txt")
        #expect(document.wasTrimmed)
        #expect(document.text.count == DocumentToText.maxCharacters)

        let short = try await read(Data("# Reading\nShort notes.".utf8), as: "md")
        #expect(!short.wasTrimmed)
        #expect(short.text == "# Reading\nShort notes.")
    }
}
