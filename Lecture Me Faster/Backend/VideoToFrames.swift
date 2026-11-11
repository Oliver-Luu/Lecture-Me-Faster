import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated struct LectureFrame: Identifiable, Sendable {
    let id = UUID()
    let seconds: Double
    let jpeg: Data
}

/// Samples a lecture video and keeps one frame each time the picture changes (new slide, new board content).
nonisolated enum VideoToFrames {
    struct Options: Sendable {
        var sampleInterval: Double = 2
        var maxFrames = 30
        var maxDimension: CGFloat = 1280
    }

    struct Output: Sendable {
        var frames: [LectureFrame] = []
        /// How many distinct frames were found before thinning down to `maxFrames`.
        var distinctCount = 0
    }

    /// Returns no frames for audio-only files.
    @concurrent
    static func extract(
        from url: URL,
        options: Options = Options(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Output {
        defer { progress(1) }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return Output() }
        let duration = try await asset.load(.duration).seconds

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maxDimension, height: options.maxDimension)
        // A loose tolerance lets the decoder snap to nearby keyframes, which is far faster than exact seeking.
        let tolerance = CMTime(seconds: options.sampleInterval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let times = stride(from: 0, to: duration, by: options.sampleInterval)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        var kept: [LectureFrame] = []
        var lastKeptSignature: [UInt8]?
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            let seconds = result.requestedTime.seconds
            progress(seconds / duration)
            guard let image = try? result.image, let signature = signature(of: image) else { continue }
            if let last = lastKeptSignature, changedFraction(last, signature) < 0.03 { continue }
            guard let jpeg = jpegData(from: image) else { continue }
            lastKeptSignature = signature
            kept.append(LectureFrame(seconds: seconds, jpeg: jpeg))
        }

        return Output(frames: thinned(kept, to: options.maxFrames), distinctCount: kept.count)
    }

    private static let signatureSide = 48

    /// A tiny grayscale thumbnail used to compare frames cheaply.
    private static func signature(of image: CGImage) -> [UInt8]? {
        let side = signatureSide
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }

    static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let changed = zip(a, b).count { abs(Int($0) - Int($1)) > 24 }
        return Double(changed) / Double(a.count)
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func thinned(_ frames: [LectureFrame], to limit: Int) -> [LectureFrame] {
        guard frames.count > limit, limit > 0 else { return frames }
        let step = Double(frames.count) / Double(limit)
        return (0..<limit).map { frames[Int(Double($0) * step)] }
    }
}
