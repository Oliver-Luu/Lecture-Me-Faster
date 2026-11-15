import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Supporting-file fixtures for tests.
enum TestDocuments {
    /// A real Word file made by macOS `textutil -convert docx` from:
    /// "Entropy and the Second Law" / (blank) / "The entropy of an isolated system never decreases."
    /// Its entries are deflate-compressed.
    static let docx = Data(base64Encoded: """
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
CAACAgAAuQsAAAAA
""", options: .ignoreUnknownCharacters)!

    /// A minimal PowerPoint file built with `zip`: slides 1, 2 and 10 (stored in the order 1, 10, 2), each
    /// with a title paragraph and a "Point & detail N" paragraph split across two text runs. The content
    /// types entry is stored uncompressed; the slides are deflated.
    static let pptx = Data(base64Encoded: """
UEsDBAoAAAAAABqBa126A1IKdAAAAHQAAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rp
bmc9IlVURi04Ij8+PFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2Nv
bnRlbnQtdHlwZXMiLz4KUEsDBBQAAAAIABqBa11SfAfL0QAAAHwBAAAVAAAAcHB0L3NsaWRlcy9zbGlkZTEueG1sjZC7agMxEEX7
fIVQkS6eXRcmbHbXkMJ1wM4HDKuJLdBjkAbH/ntL6yTGIUWag6S5czmoX5+8U0dK2cYw6HbRaEVhisaG/aDfd5unZ70ee+6yM6pE
Q+5w0AcR7gDydCCPeRGZQpl9xORRyjXtwST8LBXewbJpVuDRBv21z//Z50SZgqAUrbuS6jJtnZmdeJeIrqdKOb1Gcx577LgiVci4
ddaQapVYcdRDfapMM/l3+i3aIOou9jN7RM8vypCgdar9owpuDnCVgpslfIvD/JvjwwVQSwMEFAAAAAgAGoFrXZXbUMXSAAAAfgEA
ABYAAABwcHQvc2xpZGVzL3NsaWRlMTAueG1sjZBNawIxEIbv/oqQQ2911h5KWXdX6KHngvYHDJtRA/kYkqG1/77JqhXFg5eHJPPO
y0O61cE79U0p2xh6vZg3WlEYo7Fh1+uvzcfzm14NHbfZGVWiIbfY670ItwB53JPHPI9Mocy2MXmUck07MAl/SoV38NI0r+DRBn3a
50f2OVGmIChF66qkuoxrZyYn3iSi46lSDu/R/A4dtlyRKmRYO2tILRolVhx1UN8q00S+jX9GG0Rdxf5nT+h5qQwJWlca73TBxQKO
WnDxhLM6TP85zP4AUEsDBBQAAAAIABqBa114rUm10QAAAHwBAAAVAAAAcHB0L3NsaWRlcy9zbGlkZTIueG1sjZC7agMxEEX7fIVQ
kc6ezRYhbHbXkMK1wfYHDKuJLdBjkIbY/vtI6yTGIUWag6S5czmoX529Ux+Uso1h0E/LRisKUzQ2HAa9360XL3o19txlZ1SJhtzh
oI8i3AHk6Uge8zIyhTJ7j8mjlGs6gEl4KhXeQds0z+DRBv21z//Z50SZgqAUrbuS6jJtnZmdeJeIrqdKOb9Fcxl77LgiVci4ddaQ
apVYcdRDfapMM/l3ehNtEHUX+5k9oudXZUjQOtX+UQU3B7hKwc0SvsVh/s3x4RNQSwECHgMKAAAAAAAagWtdugNSCnQAAAB0AAAA
EwAAAAAAAAAAAAAApIEAAAAAW0NvbnRlbnRfVHlwZXNdLnhtbFBLAQIeAxQAAAAIABqBa11SfAfL0QAAAHwBAAAVAAAAAAAAAAEA
AACkgaUAAABwcHQvc2xpZGVzL3NsaWRlMS54bWxQSwECHgMUAAAACAAagWtdldtQxdIAAAB+AQAAFgAAAAAAAAABAAAApIGpAQAA
cHB0L3NsaWRlcy9zbGlkZTEwLnhtbFBLAQIeAxQAAAAIABqBa114rUm10QAAAHwBAAAVAAAAAAAAAAEAAACkga8CAABwcHQvc2xp
ZGVzL3NsaWRlMi54bWxQSwUGAAAAAAQABAALAQAAswMAAAAA
""", options: .ignoreUnknownCharacters)!

    /// Writes `data` to a temporary file with the given extension.
    static func write(_ data: Data, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + ext)
        try data.write(to: url)
        return url
    }

    /// Draws large black text on white.
    static func image(of lines: [String], width: Int = 1600, height: Int = 900) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(lines, in: context, height: Double(height), fontSize: 64)
        return context.makeImage()!
    }

    static func png(of lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image(of: lines), nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    /// A PDF where each page is either real text or (for `scanned` pages) only a picture of text.
    static func pdf(pages: [(lines: [String], scanned: Bool)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in pages {
            context.beginPDFPage(nil)
            if page.scanned {
                context.draw(image(of: page.lines, width: 1224, height: 1584), in: box)
            } else {
                draw(page.lines, in: context, height: box.height, fontSize: 24)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func draw(_ lines: [String], in context: CGContext, height: Double, fontSize: Double) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: fontSize, y: height - fontSize * 2 * Double(index + 1))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
    }
}
