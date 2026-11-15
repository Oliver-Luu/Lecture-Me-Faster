import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// A supporting file (slides, handout, reading) and the text read from it.
nonisolated struct LectureDocument: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case pdf, word, powerPoint, text, image

        var label: String {
            switch self {
            case .pdf: "PDF"
            case .word: "Word document"
            case .powerPoint: "PowerPoint"
            case .text: "Text"
            case .image: "Image"
            }
        }

        var symbol: String {
            switch self {
            case .pdf: "doc.richtext"
            case .word: "doc.text"
            case .powerPoint: "rectangle.on.rectangle"
            case .text: "text.alignleft"
            case .image: "photo"
            }
        }
    }

    var id = UUID()
    /// The file name, with its extension.
    var name: String
    var kind: Kind
    var text: String
    /// True when the text was cut to `DocumentToText.maxCharacters`.
    var wasTrimmed = false
    /// How many pages or images had to be read with text recognition (scans, photos).
    var recognizedPages = 0
    /// Why the file couldn't be read, if it couldn't. The lecture is made without it.
    var readError: String?
}

/// Reads the text out of supporting files, entirely on device: PDFKit for PDFs (with Vision text
/// recognition for scanned pages), a small zip reader for Word and PowerPoint, and Vision for images.
nonisolated enum DocumentToText {
    enum Failure: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "“\(name)” couldn't be opened."
            }
        }
    }

    /// The most text kept from one file, so one huge reading can't crowd the lecture out of the model's
    /// context window. Roughly 30,000 tokens.
    static let maxCharacters = 120_000

    /// A page with less text than this is treated as a scan and read with text recognition.
    static let scannedPageThreshold = 20

    /// The kind of supporting file at `url`, or nil if the app can't read it.
    static func kind(of url: URL) -> LectureDocument.Kind? {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "docx": return .word
        case "pptx": return .powerPoint
        case "txt", "text", "md", "markdown": return .text
        default:
            guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .plainText) { return .text }
            return nil
        }
    }

    /// File types to offer in the file picker, alongside video and audio.
    static let contentTypes: [UTType] = [
        .pdf, .plainText, .image,
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "pptx") ?? .data,
        UTType(filenameExtension: "md") ?? .plainText,
    ]

    @concurrent
    static func read(_ url: URL) async throws -> LectureDocument {
        let name = url.lastPathComponent
        guard let kind = kind(of: url) else { throw Failure.unreadable(name) }
        var document = LectureDocument(name: name, kind: kind, text: "")

        switch kind {
        case .pdf:
            guard let pdf = PDFDocument(url: url) else { throw Failure.unreadable(name) }
            // Each page's own text, or (for a scanned page) the text recognized on it. Pages are rendered
            // one at a time here; recognition runs on several at once (`VideoToFrames.readingConcurrency`),
            // so only that many rendered pages are in memory.
            var texts = [String](repeating: "", count: pdf.pageCount)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var index = 0, running = 0
                while index < pdf.pageCount || running > 0 {
                    while index < pdf.pageCount, running < VideoToFrames.readingConcurrency {
                        try Task.checkCancellation()
                        defer { index += 1 }
                        guard let page = pdf.page(at: index) else { continue }
                        let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        texts[index] = text
                        guard text.count < scannedPageThreshold, let image = render(page) else { continue }
                        let pageIndex = index
                        group.addTask { (pageIndex, try await recognizeText(in: image)) }
                        running += 1
                    }
                    guard running > 0, let (pageIndex, recognized) = try await group.next() else { continue }
                    running -= 1
                    if recognized.count > texts[pageIndex].count {
                        texts[pageIndex] = recognized
                        document.recognizedPages += 1
                    }
                }
            }
            document.text = texts.enumerated()
                .filter { !$0.element.isEmpty }
                .map { "[Page \($0.offset + 1)]\n\($0.element)" }
                .joined(separator: "\n\n")

        case .word:
            let zip = try ZipArchive(data: Data(contentsOf: url))
            guard let xml = try zip.contents(of: "word/document.xml") else { throw Failure.unreadable(name) }
            document.text = OfficeXMLText.extract(from: xml, textElement: "w:t", paragraphElement: "w:p")

        case .powerPoint:
            let zip = try ZipArchive(data: Data(contentsOf: url))
            var slides: [String] = []
            for (number, path) in slidePaths(in: zip.names) {
                guard let xml = try zip.contents(of: path) else { continue }
                let text = OfficeXMLText.extract(from: xml, textElement: "a:t", paragraphElement: "a:p")
                if !text.isEmpty { slides.append("[Slide \(number)]\n\(text)") }
            }
            document.text = slides.joined(separator: "\n\n")

        case .text:
            let data = try Data(contentsOf: url)
            document.text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw Failure.unreadable(name) }
            document.text = try await recognizeText(in: image)
            document.recognizedPages = 1
        }

        document.text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if document.text.count > maxCharacters {
            document.text = String(document.text.prefix(maxCharacters))
            document.wasTrimmed = true
        }
        return document
    }

    /// PowerPoint slide files in slide order: slide2.xml before slide10.xml.
    static func slidePaths(in names: [String]) -> [(number: Int, path: String)] {
        names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("ppt/slides/slide"), name.hasSuffix(".xml"),
                  let number = Int(name.dropFirst("ppt/slides/slide".count).dropLast(".xml".count))
            else { return nil }
            return (number, name)
        }
        .sorted { $0.0 < $1.0 }
    }

    // MARK: Text recognition

    /// Renders a PDF page at twice its size on white, for text recognition.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2.0
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Reads printed or handwritten text in an image with Apple's on-device text recognition.
    /// Lines come back top to bottom. Language correction helps with ordinary prose but can "fix" rare
    /// technical terms into common words, so slide reading turns it off.
    static func recognizeText(in image: CGImage, languageCorrection: Bool = true) async throws -> String {
        try await recognizeLines(in: image, languageCorrection: languageCorrection).map(\.text).joined(separator: "\n")
    }

    /// Each line of text with its normalized box (origin at the bottom left), top to bottom.
    static func recognizeLines(
        in image: CGImage, languageCorrection: Bool = true
    ) async throws -> [(text: String, box: CGRect)] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        let observations = try await request.perform(on: image)
        return observations
            // Vision's coordinates start at the bottom left, so higher y is nearer the top.
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { observation in
                observation.topCandidates(1).first.map { ($0.string, observation.boundingBox.cgRect) }
            }
    }
}

/// Pulls the visible text out of Word and PowerPoint XML: the contents of every text element, with a
/// line break after each paragraph.
nonisolated final class OfficeXMLText: NSObject, XMLParserDelegate {
    private let textElement: String
    private let paragraphElement: String
    private var paragraphs: [String] = []
    private var current = ""
    private var isInText = false

    private init(textElement: String, paragraphElement: String) {
        self.textElement = textElement
        self.paragraphElement = paragraphElement
    }

    static func extract(from xml: Data, textElement: String, paragraphElement: String) -> String {
        let collector = OfficeXMLText(textElement: textElement, paragraphElement: paragraphElement)
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        parser.parse()
        collector.endParagraph()
        return collector.paragraphs.joined(separator: "\n")
    }

    private func endParagraph() {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { paragraphs.append(trimmed) }
        current = ""
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        switch elementName {
        case textElement: isInText = true
        case "w:tab": current += "\t"
        case "w:br", "a:br": current += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == textElement { isInText = false }
        if elementName == paragraphElement { endParagraph() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInText { current += string }
    }
}
