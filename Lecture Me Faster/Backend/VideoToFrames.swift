import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated struct LectureFrame: Identifiable, Sendable {
    let id = UUID()
    let seconds: Double
    let jpeg: Data
}

/// What was read from one frame: its text and how much of it is pictures rather than text.
nonisolated struct FrameAnalysis: Sendable, Equatable {
    var text: String
    /// The share of the frame (0...1) that is drawn content outside any text: diagrams, plots, photos.
    /// Used to decide which slides are worth sending as images when not all of them can be.
    var visualScore: Double
}

/// Finds every distinct slide in a lecture video, so none is lost:
///
/// 1. **Sample** a small grayscale picture (320×180) every second.
/// 2. **Compare region by region.** The picture is split into 16×9 blocks; a slide changed when any block
///    has a few clearly changed pixels. A new word, a changed formula, or one new bullet changes a block even when the
///    rest of the slide (same template) doesn't. Comparing the whole picture at once missed these.
/// 3. **Live footage is different.** Where most of the picture changes every second (a camera on a
///    person or a board), only a cut to a new shot starts a new frame, captured mid-shot, away from fades.
///    Flat frames (a fade to black) are dropped.
/// 4. **Ignore constant motion.** Blocks that change in more than 60% of all seconds (a webcam in
///    the corner, a clock) don't count. If most of the picture moves (a camera on the professor), only
///    large changes count.
/// 5. **Keep each slide once it has settled**: the last second before the next change, so a slide that
///    builds up (bullets appearing) is kept complete, and frames caught mid-fade are dropped.
/// 6. **Drop repeats** (going back to an earlier slide) and **merge builds**: a slide whose words are all
///    on the next slide is an earlier step of the same build.
///
/// Every distinct slide is kept, up to a safety cap that grows with the video's length
/// (`storedFrameCap(duration:)`). How many go to the model as images is decided later, when the notes
/// are written.
nonisolated enum VideoToFrames {
    struct Options: Sendable {
        var sampleInterval: Double = 1
        /// Safety cap on stored slides; above it they are thinned evenly. Not the limit on images sent.
        /// nil: `storedFrameCap(duration:)` for the video's length.
        var maxFrames: Int? = nil
        var maxDimension: CGFloat = 1280
        /// Pass 1 decodes up to this many one-minute blocks at once (capped by `maxScanPieces`). The result
        /// is the same for any value; only the speed changes.
        var scanPieces = 1
    }


    /// The fewest slides any recording may keep.
    static let maxStoredFrames = 1000
    /// Above that, one slide per this many seconds of video. Nobody changes slides faster than this for
    /// hours, so every real slide is kept, while a video the slide finder misreads (frames kept every
    /// second) can't grow without end. About 65 KB a slide.
    static let secondsPerStoredFrame = 5.0

    /// Where each stage ends on the progress bar, from timing an 89-minute lecture (2026-11-13, Release
    /// build, after the speed-ups): scanning 24 s, capturing 15 s, reading text 25 s. Matching the
    /// bar to the time keeps it moving at a steady rate instead of crawling at the end.
    enum Stage {
        static let scanEnd = 0.4
        static let captureEnd = 0.65
        static let readEnd = 0.97
    }

    /// How many slides are read at once. Measured on 200 real slides (14-core Mac): 1 at a time 0.119 s a
    /// slide, 2: 0.057, 4: 0.030, 8: 0.022, with identical text. More than 8 gains little.
    static var readingConcurrency: Int { min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    /// Runs one tiny text recognition so Vision loads its model (about 27 s the first time) before the
    /// slides need it.
    static func warmUpTextRecognition() async {
        let size = 64
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { return }
        _ = try? await DocumentToText.recognizeLines(in: image, languageCorrection: false)
    }

    /// How many of the most recently kept slides a new one is checked against for being a repeat.
    static let repeatWindow = 200

    /// The safety cap for one recording: 1,000 up to 83 minutes, then one per 5 seconds (8,640 for 12 hours).
    static func storedFrameCap(duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return maxStoredFrames }
        return max(maxStoredFrames, Int(duration / secondsPerStoredFrame))
    }

    struct Output: Sendable {
        var frames: [LectureFrame] = []
        /// The text and picture content of each frame, in the same order.
        var analyses: [FrameAnalysis] = []
        /// How many distinct slides were found before the safety cap.
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

        // Text recognition takes about 27 s to load its model the first time; load it now, while the video
        // is scanned, instead of when the slides are read.
        let warmUp = Task.detached(priority: .utility) { await warmUpTextRecognition() }

        // Pass 1: a small picture every second, which is cheap to decode and compare. Long videos are
        // decoded in several blocks at once, but compared in time order (see `scanTimeline`), so the
        // result is the same as one sample after another. Only the change counts are kept, not the
        // pictures, so memory stays small for long lectures.
        let timeline = try await scanTimeline(
            asset, duration: duration, interval: options.sampleInterval, pieces: options.scanPieces
        ) { progress($0 * Stage.scanEnd) }
        let found = scenes(in: timeline)
        let motion = timeline.motion

        // Pass 2: the chosen moments at full size, asked for all at once so the decoder can work ahead.
        let full = AVAssetImageGenerator(asset: asset)
        full.appliesPreferredTrackTransform = true
        full.maximumSize = CGSize(width: options.maxDimension, height: options.maxDimension)
        let exact = CMTime(seconds: 0.1, preferredTimescale: 600)
        full.requestedTimeToleranceBefore = exact
        full.requestedTimeToleranceAfter = exact
        var frames: [LectureFrame] = []
        var kept: [(pixels: [UInt8], means: [Double])] = []
        var framePixels: [[UInt8]?] = []
        let pickTimes = found.map { CMTime(seconds: $0.pickSeconds, preferredTimescale: 600) }
        // Which scenes asked for each time (two scenes never should, but a map of lists can't lose one).
        var scenesAt: [CMTimeValue: [Int]] = [:]
        for (index, time) in pickTimes.enumerated() { scenesAt[time.value, default: []].append(index) }
        var done = 0
        for await result in full.images(for: pickTimes) {
            try Task.checkCancellation()
            done += 1
            progress(Stage.scanEnd + Double(done) / Double(max(found.count, 1)) * (Stage.captureEnd - Stage.scanEnd))
            guard let index = scenesAt[result.requestedTime.value]?.first else { continue }
            scenesAt[result.requestedTime.value]?.removeFirst()
            let scene = found[index]
            guard let image = try? result.image else { continue }
            let pixels = Signature.pixels(of: image)
            // A flat picture (a fade to black, a blank screen) has nothing on it to keep.
            if let pixels, Signature.isBlank(pixels) { continue }
            // Keep each slide once: a slide shown again later (going back) is a repeat. The block averages
            // rule most kept slides out at once, and only the most recent `repeatWindow` kept slides are
            // checked, so the work grows in step with the lecture, not with its square. Going back further
            // than that keeps the slide twice, which costs space but never loses a slide.
            if let pixels {
                let means = Signature.blockMeans(pixels)
                let isRepeat = kept.suffix(repeatWindow).contains {
                    !motion.isSurelyChange(blockMeans: $0.means, means)
                        && !motion.isChange($0.pixels, pixels, blockMeans: $0.means, means)
                }
                if isRepeat { continue }
                kept.append((pixels, means))
            }
            // Compressed only once it is kept: blanks and repeats are never encoded.
            guard let jpeg = jpegData(from: image) else { continue }
            frames.append(LectureFrame(seconds: scene.startSeconds, jpeg: jpeg))
            framePixels.append(pixels)
        }
        // The decoder returns pictures in the order asked for, but keep the timeline in order regardless.
        if !zip(frames, frames.dropFirst()).allSatisfy({ $0.seconds <= $1.seconds }) {
            let order = frames.indices.sorted { frames[$0].seconds < frames[$1].seconds }
            frames = order.map { frames[$0] }
            framePixels = order.map { framePixels[$0] }
        }

        // Read each slide once: the text merges builds here and is reused when the notes are written.
        await warmUp.value
        var analyses = await analyze(frames) { progress(Stage.captureEnd + $0 * (Stage.readEnd - Stage.captureEnd)) }
        progress(Stage.readEnd)
        // A frame whose drawing is all still there on the next frame, plus more (a bullet, a typed line,
        // a pen stroke), is an earlier step of it: keep only the fullest one.
        (frames, analyses, framePixels) = mergingAdditions(frames, analyses, pixels: framePixels, motion: motion)
        (frames, analyses) = mergingDuplicates(frames, analyses, pixels: framePixels, motion: motion)
        (frames, analyses) = mergingBuilds(frames, analyses)
        let distinct = frames.count
        let cap = options.maxFrames ?? storedFrameCap(duration: duration)
        if frames.count > cap {
            let kept = thinnedIndices(count: frames.count, to: cap)
            frames = kept.map { frames[$0] }
            analyses = kept.map { analyses[$0] }
        }
        return Output(frames: frames, analyses: analyses, distinctCount: distinct)
    }

    // MARK: Finding slides

    /// Pass 1, one sample at a time, keeping only what's needed (not every picture), so memory stays
    /// small for long lectures.
    struct Timeline: Sendable {
        /// When each sample was asked for, and the frame time actually decoded.
        var seconds: [Double] = []
        var actualSeconds: [Double] = []
        /// Whether a new slide starts at sample i by the slide rule (any clear change vs the slide's start).
        var isSlideStart: [Bool] = []
        /// Whether sample i is a cut from sample i - 1 (the whole picture changed: a new shot).
        var isCut: [Bool] = []
        /// How many of the 144 blocks changed from sample i - 1 to i. Live footage changes many every second.
        var changedBlockCount: [Int] = []
        /// Whether sample i lies pixel by pixel between its neighbours: a frame caught mid-fade.
        var isFade: [Bool] = []
        /// How often each block changed from one sample to the next, to find motion.
        var blockChanges = [Int](repeating: 0, count: Signature.blockCount)
        var stepCount = 0
        /// The first sample of the current slide. Comparing against it, not just the previous sample,
        /// catches a slow change (a fade) that is too small to see from one second to the next.
        private var anchor: [UInt8]?
        private var previous: [UInt8]?
        private var beforePrevious: [UInt8]?
        private var previousHistogram: [Double]?

        /// What counts as motion so far: learned as the video goes, settled after ten seconds.
        var motion: Motion {
            let share = blockChanges.map { stepCount >= 10 ? Double($0) / Double(stepCount) : 0 }
            let isDynamic = share.map { $0 > motionShare }
            return Motion(
                isDynamic: isDynamic, isBusy: share.map { $0 > busyShare },
                isCamera: isDynamic.count { $0 } > Signature.blockCount / 2
            )
        }

        mutating func append(seconds: Double, actualSeconds: Double, pixels: [UInt8]) {
            let index = self.seconds.count
            self.seconds.append(seconds)
            self.actualSeconds.append(actualSeconds)
            isFade.append(false)
            let histogram = Signature.histogram(pixels)
            var cut = false, changedBlocks = 0
            if let previous {
                let step = Signature.changedPixels(previous, pixels)
                for (block, count) in step.enumerated() where count >= changedPixelsPerBlock { blockChanges[block] += 1 }
                changedBlocks = step.count { $0 >= changedPixelsPerBlock }
                let meanDifference = Signature.blockDifferences(previous, pixels).reduce(0, +) / Double(Signature.blockCount)
                let histogramDistance = previousHistogram.map { Signature.distance($0, histogram) } ?? 0
                cut = histogramDistance > cutHistogramDistance || meanDifference > cutMeanDifference
                stepCount += 1
                if let beforePrevious {
                    isFade[index - 1] = VideoToFrames.isBetween(beforePrevious, previous, pixels, ignoring: motion.isDynamic)
                }
            }
            isCut.append(cut)
            changedBlockCount.append(changedBlocks)
            if let anchor, !motion.isChange(Signature.changedPixels(anchor, pixels)) {
                isSlideStart.append(false)  // Same slide.
            } else {
                isSlideStart.append(true)
                anchor = pixels
            }
            beforePrevious = previous
            previous = pixels
            previousHistogram = histogram
        }

    }

    /// Pass 1 decodes this many blocks of samples at once, at most. The comparisons still run strictly in
    /// time order on one timeline, so the result is the same as decoding one sample after another.
    static let maxScanPieces = 4
    /// Seconds of samples in one block. Decoded blocks wait in memory until the timeline reaches them;
    /// at most `2 × pieces` blocks of 320×180 grey pictures (about 3.5 MB a block) are held at once.
    static let scanBlockSeconds = 60.0

    /// One decoded sample of pass 1: when it was asked for, the frame time decoded, and its small picture.
    struct ScanSample: Sendable {
        var seconds: Double
        var actualSeconds: Double
        var pixels: [UInt8]?
    }

    /// Decodes one block of pass 1's samples with a generator of its own.
    private static func decodeBlock(_ asset: AVURLAsset, times: [Double], interval: Double) async throws -> [ScanSample] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: Signature.width, height: Signature.width)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var samples: [ScanSample] = []
        for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            try Task.checkCancellation()
            let image = try? result.image
            samples.append(ScanSample(
                seconds: result.requestedTime.seconds,
                actualSeconds: (try? result.actualTime.seconds) ?? result.requestedTime.seconds,
                pixels: image.flatMap(Signature.pixels(of:))
            ))
        }
        return samples
    }

    /// Pass 1: blocks are decoded `pieces` at a time, and their samples are added to the timeline in
    /// time order as soon as every earlier block is in.
    static func scanTimeline(
        _ asset: AVURLAsset, duration: Double, interval: Double, pieces: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Timeline {
        let times = Array(stride(from: 0, to: duration, by: interval))
        let perBlock = max(1, Int(scanBlockSeconds / interval))
        let blocks = stride(from: 0, to: times.count, by: perBlock).map { Array(times[$0..<min($0 + perBlock, times.count)]) }
        let parallel = max(1, min(pieces, maxScanPieces))
        var timeline = Timeline()
        try await withThrowingTaskGroup(of: (Int, [ScanSample]).self) { group in
            var nextToStart = 0, nextToAdd = 0
            var waiting: [Int: [ScanSample]] = [:]
            func startMore() {
                // At most `parallel` decoding, and never more than twice that many waiting to be added.
                while nextToStart < blocks.count, nextToStart - nextToAdd < parallel * 2,
                      nextToStart - nextToAdd - waiting.count < parallel {
                    let index = nextToStart, block = blocks[index]
                    nextToStart += 1
                    group.addTask { (index, try await decodeBlock(asset, times: block, interval: interval)) }
                }
            }
            startMore()
            while let (index, samples) = try await group.next() {
                waiting[index] = samples
                while let ready = waiting.removeValue(forKey: nextToAdd) {
                    for sample in ready {
                        guard let pixels = sample.pixels else { continue }
                        timeline.append(seconds: sample.seconds, actualSeconds: sample.actualSeconds, pixels: pixels)
                    }
                    nextToAdd += 1
                    progress(Double(nextToAdd) / Double(max(blocks.count, 1)))
                }
                startMore()
            }
        }
        return timeline
    }

    /// A block that changes in more than this share of seconds is motion. A webcam measured 95%; the
    /// title area of 6-second slides with fades measured about 40%, so the line sits well between.
    static let motionShare = 0.6
    /// See `Motion.isBusy`.
    static let busyShare = 0.2

    // Live footage (a camera on a person or a board): the picture changes all over every second, so
    // only a cut to a new shot starts a new frame. Measured on a real 4K team-intro video: within a
    // shot, 11–103 blocks changed per second, the mean difference stayed under 14 and the histogram
    // distance under 0.09; its three cuts measured 0.52–0.78 and 78–116. Generated slide decks change
    // 0–40 blocks only when a slide changes, a few seconds apart.

    /// A second is busy when at least this many blocks changed (about a seventh of the picture). The
    /// steadiest real speaker measured 11–75 per second; a webcam overlay covers about 12 blocks.
    static let liveBlocks = 20
    /// A sample is in live footage when this share of the seconds around it (±`liveWindow`) are busy.
    static let liveShare = 0.75
    static let liveWindow = 5
    /// A cut: the brightness histogram moved this far (0...1), or the average pixel this far (0...255).
    static let cutHistogramDistance = 0.3
    static let cutMeanDifference = 40.0

    /// Which changes are motion rather than a new slide.
    struct Motion: Sendable {
        /// Blocks that change most of the time (a webcam, a clock): ignored.
        var isDynamic: [Bool]
        /// Blocks that change often, though not enough to be ignored: the edges of a webcam, a slide
        /// title. Two frames with the same text that differ only here are the same slide.
        var isBusy: [Bool]
        /// Most of the picture moves (a camera on the professor): only large changes count.
        var isCamera: Bool

        func isChange(_ counts: [Int]) -> Bool {
            if isCamera {
                // A cut or a slide filling the screen: a third of the blocks change a lot.
                let large = Signature.block * Signature.block / 4
                return Double(counts.count { $0 >= large }) >= Double(Signature.blockCount) * 0.3
            }
            return counts.indices.contains { !isDynamic[$0] && counts[$0] >= changedPixelsPerBlock }
        }

        /// A cheap check from block averages that gives the same answer as `isChange` whenever it says yes,
        /// so the full pixel comparison is only needed when it says no.
        /// A block of 400 pixels whose average moved by d has at least (400·d − 400·24) / 231 pixels that
        /// changed by more than 24, so d ≥ 26 means at least 3 of them, which is a change.
        func isSurelyChange(blockMeans a: [Double], _ b: [Double]) -> Bool {
            guard !isCamera else { return false }
            return a.indices.contains { !isDynamic[$0] && abs(a[$0] - b[$0]) >= Self.surelyChangedMean }
        }

        static let surelyChangedMean = 26.0

        /// The same answer as `isChange(Signature.changedPixels(a, b))`, found faster: blocks are checked
        /// in order of how much their averages moved, and it stops at the first changed one. Slides that
        /// differ usually do so in the first block checked, so a few hundred pixels are read, not 57,600.
        func isChange(_ a: [UInt8], _ b: [UInt8], blockMeans meansA: [Double], _ meansB: [Double]) -> Bool {
            if isCamera { return isChange(Signature.changedPixels(a, b)) }
            let order = meansA.indices.filter { !isDynamic[$0] }
                .sorted { abs(meansA[$0] - meansB[$0]) > abs(meansA[$1] - meansB[$1]) }
            return a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    order.contains { Signature.changedPixels(a, b, inBlock: $0, atLeast: changedPixelsPerBlock) }
                }
            }
        }
    }

    struct Scene: Equatable, Sendable {
        /// When the slide first appeared.
        var startSeconds: Double
        /// The moment to capture: the last sample before the next change, when the slide is complete.
        var pickSeconds: Double
    }

    /// A small grayscale picture split into blocks for comparison.
    enum Signature {
        static let width = 320, height = 180, block = 20
        static let columns = width / block, rows = height / block
        static var blockCount: Int { columns * rows }

        static func pixels(of image: CGImage) -> [UInt8]? {
            var pixels = [UInt8](repeating: 0, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return drawn ? pixels : nil
        }

        // The three loops below run on every sample of a long lecture, several times each. They read memory
        // through raw pointers and are written out separately (not one loop taking a closure), because a
        // Debug build checks bounds on every array access and calls a closure for every pixel, which made
        // pass 1 of an 89-minute lecture take several times longer than in Release.

        /// The average brightness of each block.
        static func blockMeans(_ pixels: [UInt8]) -> [Double] {
            var sums = [Int](repeating: 0, count: blockCount)
            pixels.withUnsafeBufferPointer { pixels in
                sums.withUnsafeMutableBufferPointer { sums in
                    guard let p = pixels.baseAddress, let sums = sums.baseAddress else { return }
                    for y in 0..<height {
                        let rowStart = y * width, blockRow = (y / block) * columns
                        for column in 0..<columns {
                            var total = 0, offset = rowStart + column * block
                            let end = offset + block
                            while offset < end { total += Int(p[offset]); offset += 1 }
                            sums[blockRow + column] += total
                        }
                    }
                }
            }
            let area = Double(block * block)
            return sums.map { Double($0) / area }
        }

        /// The mean absolute difference (0...255) of each block between two pictures.
        static func blockDifferences(_ a: [UInt8], _ b: [UInt8]) -> [Double] {
            var sums = [Int](repeating: 0, count: blockCount)
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    sums.withUnsafeMutableBufferPointer { sums in
                        guard let a = a.baseAddress, let b = b.baseAddress, let sums = sums.baseAddress else { return }
                        for y in 0..<height {
                            let rowStart = y * width, blockRow = (y / block) * columns
                            for column in 0..<columns {
                                var total = 0, offset = rowStart + column * block
                                let end = offset + block
                                while offset < end {
                                    let difference = Int(a[offset]) - Int(b[offset])
                                    total += difference < 0 ? -difference : difference
                                    offset += 1
                                }
                                sums[blockRow + column] += total
                            }
                        }
                    }
                }
            }
            let area = Double(block * block)
            return sums.map { Double($0) / area }
        }

        /// How many pixels in each block changed clearly (by more than `pixelThreshold` of 255). A changed
        /// character alters a few pixels a lot; compression noise and lighting drift alter many a little.
        static func changedPixels(_ a: [UInt8], _ b: [UInt8]) -> [Int] {
            var counts = [Int](repeating: 0, count: blockCount)
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    counts.withUnsafeMutableBufferPointer { counts in
                        guard let a = a.baseAddress, let b = b.baseAddress, let counts = counts.baseAddress else { return }
                        for y in 0..<height {
                            let rowStart = y * width, blockRow = (y / block) * columns
                            for column in 0..<columns {
                                var total = 0, offset = rowStart + column * block
                                let end = offset + block
                                while offset < end {
                                    let difference = Int(a[offset]) - Int(b[offset])
                                    if difference > pixelThreshold || difference < -pixelThreshold { total += 1 }
                                    offset += 1
                                }
                                counts[blockRow + column] += total
                            }
                        }
                    }
                }
            }
            return counts
        }

        /// Whether at least `limit` pixels of one block changed by more than `pixelThreshold`; stops early.
        static func changedPixels(
            _ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, inBlock index: Int, atLeast limit: Int
        ) -> Bool {
            let top = (index / columns) * block, left = (index % columns) * block
            var count = 0
            for y in top..<(top + block) {
                var offset = y * width + left
                for _ in 0..<block {
                    let difference = Int(a[offset]) - Int(b[offset])
                    if difference > pixelThreshold || difference < -pixelThreshold {
                        count += 1
                        if count >= limit { return true }
                    }
                    offset += 1
                }
            }
            return false
        }

        static let pixelThreshold = 24

        /// The share of pixels in each of 32 brightness bands. Movement within a shot barely changes it; a
        /// cut to a different shot does.
        static func histogram(_ pixels: [UInt8]) -> [Double] {
            var counts = [Int](repeating: 0, count: 32)
            pixels.withUnsafeBufferPointer { pixels in
                counts.withUnsafeMutableBufferPointer { counts in
                    for pixel in pixels { counts[Int(pixel) >> 3] += 1 }
                }
            }
            return counts.map { Double($0) / Double(max(pixels.count, 1)) }
        }

        /// How different two histograms are, 0 (same) to 1 (no overlap).
        static func distance(_ a: [Double], _ b: [Double]) -> Double {
            zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / 2
        }

        /// Nearly one flat colour (a black or white fade, a blank screen).
        static func isBlank(_ pixels: [UInt8]) -> Bool {
            guard !pixels.isEmpty else { return true }
            let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
            let variance = pixels.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(pixels.count)
            return variance.squareRoot() < 8
        }
    }

    /// A block changed when at least this many of its 400 pixels changed clearly. Measured on generated
    /// slides: one changed character changes several; a still slide changes none.
    static let changedPixelsPerBlock = 3

    /// The slides found in pass 1: for each, when it appeared and the moment to capture it.
    ///
    /// Slides: a new one starts at any clear change, and the capture is the last settled sample (not
    /// mid-fade) before the next one, so builds are complete. Live footage: a new frame starts only at a
    /// cut, and the capture is the middle of the shot, away from fades in and out.
    static func scenes(in timeline: Timeline) -> [Scene] {
        let count = timeline.seconds.count
        guard count > 0 else { return [] }
        let live = isLive(changedBlockCount: timeline.changedBlockCount)
        var starts = [0]
        for index in 1..<count where live[index] ? timeline.isCut[index] : timeline.isSlideStart[index] {
            starts.append(index)
        }
        return starts.indices.compactMap { position in
            let run = starts[position]..<(position + 1 < starts.count ? starts[position + 1] : count)
            let settled = run.filter { !timeline.isFade[$0] }
            guard !settled.isEmpty else { return nil }  // only a fade
            let isLiveShot = run.count { live[$0] } * 2 > run.count
            let pick = isLiveShot ? settled[settled.count / 2] : settled[settled.count - 1]
            return Scene(
                startSeconds: run.lowerBound == 0 ? 0 : timeline.seconds[run.lowerBound],
                pickSeconds: timeline.actualSeconds[pick]
            )
        }
    }

    /// Whether each sample is in live footage: most seconds around it changed widely.
    static func isLive(changedBlockCount: [Int]) -> [Bool] {
        let count = changedBlockCount.count
        return (0..<count).map { index in
            let window = max(1, index - liveWindow)...max(1, min(count - 1, index + liveWindow))
            guard window.upperBound < count, window.count >= 3 else { return false }
            let busy = window.count { changedBlockCount[$0] >= liveBlocks }
            return Double(busy) >= Double(window.count) * liveShare
        }
    }

    /// Whether `middle` is a blend of `before` and `after` (a cross-fade) in every block that changed,
    /// leaving out moving blocks. A real slide shown briefly is far from both. The slack allows for noise.
    static func isBetween(_ before: [UInt8], _ middle: [UInt8], _ after: [UInt8], ignoring isDynamic: [Bool]) -> Bool {
        let toMiddle = Signature.blockDifferences(before, middle), fromMiddle = Signature.blockDifferences(middle, after)
        let across = Signature.blockDifferences(before, after)
        // Only blocks where the slide really changed from before to after count; on a still (if noisy)
        // picture nothing is fading.
        var anyChange = false
        for block in toMiddle.indices where !isDynamic[block] && across[block] > 6 {
            // A blend differs from both ends; a frame equal to one end is just that slide.
            guard min(toMiddle[block], fromMiddle[block]) > across[block] * 0.15 else { return false }
            anyChange = true
            if toMiddle[block] + fromMiddle[block] > across[block] * 1.2 + 3 { return false }
        }
        return anyChange
    }

    /// Merges neighbouring frames of the same slide that motion split apart: the same words, and
    /// differences only in busy blocks (a webcam edge). A diagram that changes under the same text
    /// changes quiet blocks, so it is kept. The merged frame is the later one, at the earlier time.
    // MARK: Builds, by picture

    /// Brightness away from the background that counts as drawn content ("ink") on the earlier frame.
    static let inkThreshold = 48
    /// On the later frame, a pixel this far from the background still counts as ink (half the above, so a
    /// stroke that faded a little in compression is not taken for erased).
    static let stillInkThreshold = 24
    /// ...and within this much of its earlier brightness (ink drifts with noise and light; a shirt or hand
    /// in front of the writing does not stay this close).
    static let sameInkTolerance = 72

    /// The size the pictures are compared at: text about 12 px tall, so one letter can't pass for another.
    /// (At the 320×180 of pass 1, text is 6 px tall and almost any letter overlapped a neighbouring one,
    /// so slides of one template merged.)
    static let additionWidth = 640, additionHeight = 360
    /// How many of the earlier frame's ink pixels may be missing: a blinking cursor or a pointer, not a
    /// letter. Fixed, not a share of the ink, so a template with lots of ink doesn't hide a changed word.
    static let allowedMissingInk = 6

    /// How many of the following kept frames a frame's drawing may be spread over.
    static let coverageWindow = 4

    /// Drops frames whose drawing is all still visible later: every ink pixel of the frame is still there,
    /// in the same place, in at least one of the next `coverageWindow` kept frames. That covers:
    /// - a slide that builds up, code typed line by line, a pen drawing in progress (the next frame has it
    ///   all, plus more);
    /// - a whiteboard with the lecturer walking in front: writing hidden in one frame counts when a later
    ///   kept frame shows it.
    /// Anything erased, scrolled away or changed is in none of the later frames, so its frame is kept.
    /// Only real frames are kept, nothing is pieced together. The kept frame takes the dropped frame's
    /// (earlier) time. It runs from the end backwards, so frames are only ever checked against frames that
    /// stay. Unlike `mergingBuilds` this needs no readable text, so handwriting and misread code work too.
    /// The pictures are compared at `additionWidth`, decoded from the frames' JPEGs.
    static func mergingAdditions(
        _ frames: [LectureFrame], _ analyses: [FrameAnalysis], pixels: [[UInt8]?], motion: Motion
    ) -> ([LectureFrame], [FrameAnalysis], [[UInt8]?]) {
        var seconds = frames.map(\.seconds)
        var kept: [Int] = []  // indices of kept frames, nearest first
        var details: [Int: [UInt8]] = [:]
        for index in frames.indices.reversed() {
            let detail = detailPixels(frames[index].jpeg)
            let following = Array(kept.prefix(coverageWindow))
            if let detail, !following.isEmpty,
               isCovered(
                   detail, by: following.compactMap { details[$0] }, width: additionWidth, height: additionHeight,
                   ignoring: motion, earlierText: analyses[index].text, nextText: analyses[following[0]].text
               ) {
                // Its content lives on in the frames after it; the next one now starts when this one did.
                seconds[following[0]] = seconds[index]
                continue
            }
            kept.insert(index, at: 0)
            if let detail { details[index] = detail }
            // Only the nearest few kept frames are ever compared against.
            if kept.count > coverageWindow { details[kept[coverageWindow]] = nil }
        }
        return (
            kept.map { LectureFrame(seconds: seconds[$0], jpeg: frames[$0].jpeg) },
            kept.map { analyses[$0] },
            kept.map { pixels[$0] }
        )
    }

    /// A frame's JPEG as grey pixels at `additionWidth` × `additionHeight`.
    static func detailPixels(_ jpeg: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: additionWidth * additionHeight)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: additionWidth, height: additionHeight, bitsPerComponent: 8,
                bytesPerRow: additionWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: additionWidth, height: additionHeight))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Whether `later` keeps all of `earlier`'s drawing, so `earlier` is an earlier step of it:
    /// - Each ink pixel of `earlier` must still be ink (not background) at the same place on `later`; up to
    ///   `allowedMissingInk` may not be, which is noise. Compared exactly: with one pixel of slack, a 5
    ///   changed to a 6 left nothing missing.
    /// - Or the missing ink fits in a pointer-sized patch (`pointerPatch`) and every word read on
    ///   `earlier` is still on `later`: a mouse pointer or text cursor that moved over the same text. (A
    ///   changed digit is also a small patch, but changes a word, so it is kept.)
    /// Areas in constant motion (a webcam inset; `motion` is per 16×9 block) are left out, and live
    /// camera footage never counts.
    static func isAddition(
        _ earlier: [UInt8], to later: [UInt8], width: Int = Signature.width, height: Int = Signature.height,
        ignoring motion: Motion, earlierText: String? = nil, laterText: String? = nil
    ) -> Bool {
        isCovered(earlier, by: [later], width: width, height: height, ignoring: motion, earlierText: earlierText, nextText: laterText)
    }

    /// The same test against several later frames: each ink pixel may be found in any of them.
    /// `nextText` is the words on the first of them, for the pointer-sized patch rule.
    static func isCovered(
        _ earlier: [UInt8], by laters: [[UInt8]], width: Int = Signature.width, height: Int = Signature.height,
        ignoring motion: Motion, earlierText: String? = nil, nextText: String? = nil
    ) -> Bool {
        guard !motion.isCamera, earlier.count == width * height, !laters.isEmpty,
              laters.allSatisfy({ $0.count == earlier.count }) else { return false }
        let patch = pointerPatch * width / additionWidth
        guard let counts = missingInk(earlier, in: laters, width: width, height: height, ignoring: motion, stopAfter: patch * patch),
              counts.ink > 0 else { return false }
        if counts.missing <= allowedMissingInk { return true }
        guard counts.box.width <= patch, counts.box.height <= patch, let earlierText, let nextText else { return false }
        let before = Set(FileToAI.words(in: earlierText).map { $0.lowercased() })
        let after = Set(FileToAI.words(in: nextText).map { $0.lowercased() })
        return before.count >= 3 && before.isSubset(of: after)
    }

    /// The largest patch (in pixels at `additionWidth`) of missing ink taken for a moved pointer or cursor.
    static let pointerPatch = 40

    /// How much ink `earlier` has, and how much of it `later` lacks; nil when the backgrounds differ.
    static func missingInk(
        _ earlier: [UInt8], in later: [UInt8], width: Int, height: Int, ignoring motion: Motion, stopAfter: Int = .max,
        reach: Int = 0
    ) -> (ink: Int, missing: Int, box: (width: Int, height: Int))? {
        missingInk(earlier, in: [later], width: width, height: height, ignoring: motion, stopAfter: stopAfter, reach: reach)
    }

    /// Ink of `earlier` found in none of `laters` (only those on the same background count; nil if none is).
    static func missingInk(
        _ earlier: [UInt8], in allLaters: [[UInt8]], width: Int, height: Int, ignoring motion: Motion,
        stopAfter: Int = .max, reach: Int = 0
    ) -> (ink: Int, missing: Int, box: (width: Int, height: Int))? {
        let background = dominantBrightness(earlier)
        let laters = allLaters.filter { abs(background - dominantBrightness($0)) <= 16 }
        guard !laters.isEmpty else { return nil }
        // Only areas that change almost every second (a webcam inset) are left out. Areas that are merely
        // busy (a lecturer walking in front of a board) are checked: content hidden or erased there counts
        // as removed, so both frames are kept. Skipping busy areas let an erased whiteboard pass as a build.
        let skip = motion.isDynamic
        let blockWidth = max(1, width / Signature.columns), blockHeight = max(1, height / Signature.rows)
        var ink = 0, missing = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        // The later frames one after another in one buffer, so each can be read through one pointer.
        let stacked = laters.flatMap { $0 }
        let frameSize = width * height
        earlier.withUnsafeBufferPointer { a in
            stacked.withUnsafeBufferPointer { b in
                guard let a = a.baseAddress, let b = b.baseAddress else { return }
                for y in 0..<height where missing <= stopAfter {
                    let blockRow = min(y / blockHeight, Signature.rows - 1) * Signature.columns
                    for x in 0..<width {
                        if skip[blockRow + min(x / blockWidth, Signature.columns - 1)] { continue }
                        let value = Int(a[y * width + x])
                        let distance = value - background
                        guard distance > inkThreshold || distance < -inkThreshold else { continue }
                        ink += 1
                        var found = false
                        for frame in 0..<laters.count where !found {
                        for dy in max(0, y - reach)...min(height - 1, y + reach) where !found {
                            for dx in max(0, x - reach)...min(width - 1, x + reach) {
                                // Still ink: not background, and about as dark (or light) as before. Camera noise
                                // and lighting shift ink a little; erased strokes turn to background, and a person
                                // standing in front is far from the ink's brightness.
                                let later = Int(b[frame * frameSize + dy * width + dx])
                                let fromBackground = later - background, fromInk = later - value
                                if (fromBackground > stillInkThreshold || fromBackground < -stillInkThreshold)
                                    && fromInk <= sameInkTolerance && fromInk >= -sameInkTolerance { found = true; break }
                            }
                        }
                        }
                        if !found {
                            missing += 1
                            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        }
                    }
                }
            }
        }
        return (ink, missing, missing == 0 ? (0, 0) : (maxX - minX + 1, maxY - minY + 1))
    }

    /// The most common brightness (to the nearest 8): the background of a slide or screen.
    static func dominantBrightness(_ pixels: [UInt8]) -> Int {
        var counts = [Int](repeating: 0, count: 32)
        pixels.withUnsafeBufferPointer { pixels in
            for pixel in pixels { counts[Int(pixel) >> 3] += 1 }
        }
        return (counts.indices.max { counts[$0] < counts[$1] } ?? 0) * 8 + 4
    }

    static func mergingDuplicates(
        _ frames: [LectureFrame], _ analyses: [FrameAnalysis], pixels: [[UInt8]?], motion: Motion
    ) -> ([LectureFrame], [FrameAnalysis]) {
        var keptFrames: [LectureFrame] = []
        var keptAnalyses: [FrameAnalysis] = []
        var keptPixels: [[UInt8]?] = []
        for index in frames.indices {
            var frame = frames[index]
            if let previous = keptPixels.last ?? nil, let current = pixels[index],
               sameWords(keptAnalyses[keptAnalyses.count - 1].text, analyses[index].text) {
                let counts = Signature.changedPixels(previous, current)
                let quietChange = counts.indices.contains {
                    !motion.isBusy[$0] && !motion.isDynamic[$0] && counts[$0] >= changedPixelsPerBlock
                }
                if !quietChange {
                    frame = LectureFrame(seconds: keptFrames.removeLast().seconds, jpeg: frame.jpeg)
                    keptAnalyses.removeLast()
                    keptPixels.removeLast()
                }
            }
            keptFrames.append(frame)
            keptAnalyses.append(analyses[index])
            keptPixels.append(pixels[index])
        }
        return (keptFrames, keptAnalyses)
    }

    static func sameWords(_ a: String, _ b: String) -> Bool {
        Set(FileToAI.words(in: a).map { $0.lowercased() }) == Set(FileToAI.words(in: b).map { $0.lowercased() })
    }

    /// Drops earlier steps of a slide that builds up: when the words on a slide are also on the next one,
    /// and the next one has more, the next one is the same slide with more revealed (a bullet appearing,
    /// a line typed into a code editor). The kept slide takes the earlier time, when the build began.
    /// On a slide with 10 or more words, up to a tenth may be missing from the next one, because text
    /// recognition misreads a word or two between frames (a cursor over a letter); what is lost is at most
    /// those few words, while the rest of the slide lives on in the next frame.
    static func mergingBuilds(_ frames: [LectureFrame], _ analyses: [FrameAnalysis]) -> ([LectureFrame], [FrameAnalysis]) {
        var keptFrames: [LectureFrame] = []
        var keptAnalyses: [FrameAnalysis] = []
        for (frame, analysis) in zip(frames, analyses) {
            var frame = frame
            if let previous = keptAnalyses.last, isEarlierStep(previous.text, of: analysis.text) {
                frame = LectureFrame(seconds: keptFrames.removeLast().seconds, jpeg: frame.jpeg)
                keptAnalyses.removeLast()
            }
            keptFrames.append(frame)
            keptAnalyses.append(analysis)
        }
        return (keptFrames, keptAnalyses)
    }

    static func isEarlierStep(_ earlier: String, of later: String) -> Bool {
        let before = Set(FileToAI.words(in: earlier).map { $0.lowercased() })
        let after = Set(FileToAI.words(in: later).map { $0.lowercased() })
        // Three words at least, so a title card isn't swallowed by any slide that repeats its words.
        guard before.count >= 3, !after.subtracting(before).isEmpty else { return false }
        let allowedMissing = before.count >= 10 ? before.count / 10 : 0
        return before.subtracting(after).count <= allowedMissing
    }

    // MARK: Reading slides

    /// Reads each frame's text and measures how much of it is pictures, on device. A frame that can't be
    /// read gives empty text, so one bad frame never stops the lecture.
    @concurrent
    static func analyze(
        _ frames: [LectureFrame], progress: @Sendable (Double) -> Void = { _ in }
    ) async -> [FrameAnalysis] {
        // Several slides are read at once (see `readingConcurrency`); results go back in slide order.
        var texts = [String](repeating: "", count: frames.count)
        var thumbnails = [[UInt8]?](repeating: nil, count: frames.count)
        var boxes = [[CGRect]](repeating: [], count: frames.count)
        await withTaskGroup(of: (Int, String, [UInt8]?, [CGRect]).self) { group in
            var next = 0
            func addNext() {
                guard next < frames.count, !Task.isCancelled else { return }
                let index = next, jpeg = frames[next].jpeg
                next += 1
                group.addTask {
                    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    else { return (index, "", nil, []) }
                    let lines = (try? await DocumentToText.recognizeLines(in: image, languageCorrection: false)) ?? []
                    return (index, lines.map(\.text).joined(separator: "\n"), Thumbnail.pixels(of: image), lines.map(\.box))
                }
            }
            for _ in 0..<readingConcurrency { addNext() }
            var finished = 0
            while let (index, text, thumbnail, frameBoxes) = await group.next() {
                texts[index] = text
                thumbnails[index] = thumbnail
                boxes[index] = frameBoxes
                finished += 1
                progress(Double(finished) / Double(max(frames.count, 1)))
                addNext()
            }
        }
        let scores = visualScores(thumbnails: thumbnails, textBoxes: boxes)
        return zip(texts, scores).map { FrameAnalysis(text: $0, visualScore: $1) }
    }

    /// Reads the text on each frame, in frame order.
    @concurrent
    static func readText(in frames: [LectureFrame]) async -> [String] {
        await analyze(frames).map(\.text)
    }

    /// A tiny grayscale picture for measuring picture content.
    enum Thumbnail {
        static let width = 64, height = 36

        static func pixels(of image: CGImage) -> [UInt8]? {
            var pixels = [UInt8](repeating: 0, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return drawn ? pixels : nil
        }
    }

    /// For each frame, the share of the picture that is drawn content outside any text: pixels that differ
    /// clearly from the deck's template and aren't inside a text box. The template is the median of all
    /// frames, so decoration repeated on every slide (a header bar, a logo) cancels out. With fewer than
    /// three frames there is no template to learn, so each frame's most common brightness stands in.
    /// `textBoxes` are Vision's normalized boxes (origin at the bottom left).
    static func visualScores(thumbnails: [[UInt8]?], textBoxes: [[CGRect]]) -> [Double] {
        let count = Thumbnail.width * Thumbnail.height
        let available = thumbnails.compactMap { $0 }
        var template: [Double]?
        if available.count >= 3 {
            template = (0..<count).map { index in
                let values = available.map { $0[index] }.sorted()
                return Double(values[values.count / 2])
            }
        }
        return zip(thumbnails, textBoxes).map { thumbnail, boxes in
            guard let pixels = thumbnail else { return 0 }
            let reference = template ?? {
                var histogram = [Int](repeating: 0, count: 32)
                for pixel in pixels { histogram[Int(pixel) / 8] += 1 }
                let background = Double((histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0) * 8 + 4)
                return [Double](repeating: background, count: count)
            }()
            let padded = boxes.map { $0.insetBy(dx: -0.01, dy: -0.01) }
            var drawn = 0
            for row in 0..<Thumbnail.height {
                // Memory row 0 is the top of the picture; Vision's y grows upward.
                let y = 1 - (Double(row) + 0.5) / Double(Thumbnail.height)
                for column in 0..<Thumbnail.width where abs(Double(pixels[row * Thumbnail.width + column]) - reference[row * Thumbnail.width + column]) > 40 {
                    let x = (Double(column) + 0.5) / Double(Thumbnail.width)
                    if !padded.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { drawn += 1 }
                }
            }
            return Double(drawn) / Double(count)
        }
    }

    // MARK: Choosing images

    /// Which slides to send as images when the model can see them but not all fit the limit: the ones
    /// with the most pictures, since a slide of text loses nothing when sent as its text. Returns a
    /// flag per slide, in order.
    static func imageChoice(visualScores: [Double], limit: Int) -> [Bool] {
        guard visualScores.count > limit else { return visualScores.map { _ in true } }
        guard limit > 0 else { return visualScores.map { _ in false } }
        // Most pictures first; on a tie the earlier slide.
        let ranked = visualScores.indices.sorted { visualScores[$0] != visualScores[$1] ? visualScores[$0] > visualScores[$1] : $0 < $1 }
        let chosen = Set(ranked.prefix(limit))
        return visualScores.indices.map { chosen.contains($0) }
    }

    // MARK: Helpers

    private static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func thinnedIndices(count: Int, to limit: Int) -> [Int] {
        guard count > limit, limit > 0 else { return Array(0..<count) }
        let step = Double(count) / Double(limit)
        return (0..<limit).map { Int(Double($0) * step) }
    }

    static func thinned(_ frames: [LectureFrame], to limit: Int) -> [LectureFrame] {
        thinnedIndices(count: frames.count, to: limit).map { frames[$0] }
    }
}
