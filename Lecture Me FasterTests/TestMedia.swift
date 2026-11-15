import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import Testing

/// Media files generated for tests.
enum TestMedia {
    /// One slide of a generated deck: a title and bullet lines in the same template on every slide, like
    /// a real lecture deck, shown for `seconds`.
    struct Slide {
        var title: String
        var bullets: [String] = []
        var seconds: Double
    }

    /// A 1280×720 slide image: white, a blue header bar with the title, then the bullets.
    static func slideImage(_ slide: Slide) -> CGImage {
        let width = 1280, height = 720
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.25, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 110, width: width, height: 110))
        func draw(_ text: String, x: Double, y: Double, size: Double, white: Bool) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let color = CGColor(gray: white ? 1 : 0.1, alpha: 1)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        draw(slide.title, x: 60, y: Double(height) - 75, size: 46, white: true)
        for (index, bullet) in slide.bullets.enumerated() {
            draw("•  " + bullet, x: 80, y: Double(height) - 190 - Double(index) * 60, size: 32, white: false)
        }
        return context.makeImage()!
    }

    /// What makes a recording messier than a clean screen capture.
    struct Realism {
        /// Random sensor noise, in brightness levels (0...255) either way.
        var noise = 0
        /// A moving "speaker" overlay in the bottom-right corner.
        var webcam = false
        /// Blended frames between slides (a cross-fade), at 2 frames per second.
        var fadeFrames = 0
    }

    /// Writes a silent video showing each slide for its time, at 2 frames per second.
    static func makeDeckVideo(_ slides: [Slide], realism: Realism = Realism()) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        let width = 1280, height = 720, framesPerSecond = 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        var frame: Int64 = 0
        var random: UInt32 = 12345
        func write(_ draw: (CGContext) -> Void) async throws {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            let buffer = try #require(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let context = try #require(CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ))
            draw(context)
            if realism.webcam {
                // A "speaker" that moves every frame in the bottom-right corner, like a webcam overlay.
                context.setFillColor(CGColor(gray: 0.3, alpha: 1))
                context.fill(CGRect(x: width - 260, y: 20, width: 240, height: 180))
                let sway = sin(Double(frame) * 0.9) * 30
                context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.5, alpha: 1))
                context.fillEllipse(in: CGRect(x: Double(width - 190) + sway, y: 40, width: 100, height: 130))
            }
            if realism.noise > 0 {
                // Camera-like sensor noise: every pixel shifted a little at random.
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for index in 0..<(bytesPerRow * height) {
                    random = random &* 1_664_525 &+ 1_013_904_223
                    let shift = Int(random >> 24) % (2 * realism.noise + 1) - realism.noise
                    bytes[index] = UInt8(clamping: Int(bytes[index]) + shift)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: Int32(framesPerSecond)))
            frame += 1
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        var previousImage: CGImage?
        for slide in slides {
            let image = slideImage(slide)
            // A cross-fade from the previous slide, one blended frame per step.
            if let previousImage, realism.fadeFrames > 0 {
                for step in 1...realism.fadeFrames {
                    let alpha = Double(step) / Double(realism.fadeFrames + 1)
                    try await write { context in
                        context.draw(previousImage, in: rect)
                        context.setAlpha(alpha)
                        context.draw(image, in: rect)
                        context.setAlpha(1)
                    }
                }
            }
            for _ in 0..<Int(slide.seconds * Double(framesPerSecond)) {
                try await write { $0.draw(image, in: rect) }
            }
            previousImage = image
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// One camera shot: a "speaker" in front of a textured background, filmed handheld (the picture
    /// shakes), with captions that change every 2 seconds, like a talking-head video.
    struct Shot {
        var name: String
        /// Background brightness (0...1); shots differ so a cut changes the whole picture.
        var brightness: Double
        var seconds: Double
    }

    /// Writes a silent video of camera shots with cuts between them, at 4 frames per second.
    static func makeCameraVideo(_ shots: [Shot]) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        let width = 1280, height = 720, framesPerSecond = 4
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        var frame: Int64 = 0
        for shot in shots {
            for step in 0..<Int(shot.seconds * Double(framesPerSecond)) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                var created: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
                let buffer = try #require(created)
                CVPixelBufferLockBaseAddress(buffer, [])
                let context = try #require(CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                ))
                let t = Double(frame) / Double(framesPerSecond)
                // Handheld: the whole scene shifts a little every frame.
                context.translateBy(x: sin(t * 2.3) * 14, y: cos(t * 1.7) * 10)
                context.setFillColor(CGColor(gray: shot.brightness, alpha: 1))
                context.fill(CGRect(x: -40, y: -40, width: width + 80, height: height + 80))
                // A textured room: shelves and windows.
                for row in 0..<6 {
                    for column in 0..<10 {
                        let shade = shot.brightness + (Double((row * 7 + column * 3) % 5) - 2) * 0.08
                        context.setFillColor(CGColor(gray: min(max(shade, 0), 1), alpha: 1))
                        context.fill(CGRect(x: column * 130 + 10, y: row * 120 + 10, width: 100, height: 90))
                    }
                }
                // The speaker sways and nods.
                context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.5, alpha: 1))
                context.fillEllipse(in: CGRect(x: 500 + sin(t * 1.3) * 60, y: 160 + sin(t * 2.9) * 20, width: 280, height: 360))
                context.setFillColor(CGColor(gray: 0.15, alpha: 1))
                context.fill(CGRect(x: 420 + sin(t * 1.3) * 60, y: 0, width: 440, height: 170))
                context.translateBy(x: -sin(t * 2.3) * 14, y: -cos(t * 1.7) * 10)
                // The name and changing captions are burned in and don't shake.
                func draw(_ text: String, y: Double, size: Double) {
                    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
                    let attributed = NSAttributedString(string: text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
                    ])
                    context.textPosition = CGPoint(x: 60, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                }
                draw(shot.name, y: Double(height) - 90, size: 48)
                draw("Caption line number \(step / (2 * framesPerSecond) + 1) for \(shot.name)", y: 40, size: 36)
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: Int32(framesPerSecond)))
                frame += 1
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// Writes a silent video where each "slide" is a white frame with a dark band in a different place.
    static func makeSlideVideo(slides: Int, secondsPerSlide: Int) async throws -> URL {
        // Each slide is a dark band 100 px lower than the last, so only 3 fit in the 360 px frame.
        try #require(slides <= 3, "makeSlideVideo draws at most 3 slides; use makeDeckVideo for more")
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mov")
        let width = 640, height = 360, framesPerSecond = 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<(slides * secondsPerSlide * framesPerSecond) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            let buffer = try #require(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let slide = frame / (secondsPerSlide * framesPerSecond)
            memset(base, 255, bytesPerRow * height)
            memset(base + bytesPerRow * (40 + slide * 100), 20, bytesPerRow * 60)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(framesPerSecond)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
}
