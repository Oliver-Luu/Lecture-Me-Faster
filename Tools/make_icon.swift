// Draws the app icon and writes every size the asset catalogue needs.
//
//   swift Tools/make_icon.swift "Lecture Me Faster/Assets.xcassets/AppIcon.appiconset"
//
// The mark is six bars in two groups whose heights fall from left to right. They read as a sound wave
// and as a fast-forward sign: a lecture, faster. `LogoMark` in the app draws the same bars; keep
// `heights`, `barWidth` and `gap` the same in both.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let heights: [CGFloat] = [1, 0.62, 0.28, 1, 0.62, 0.28]
let barWidth: CGFloat = 0.12   // as a share of the mark's width
let gap: CGFloat = 0.056

let brand = CGColor(srgbRed: 0x27 / 255.0, green: 0x74 / 255.0, blue: 0xAE / 255.0, alpha: 1)   // #2774AE, the "Brand" colour
let chalk = CGColor(srgbRed: 0.957, green: 0.945, blue: 0.910, alpha: 1)

/// `rounded` draws the Mac shape (a rounded square with a margin and a soft shadow). Without it the
/// square is filled to the edges, which is what iPhone and iPad want (they round the corners themselves).
func icon(pixels: Int, rounded: Bool) -> CGImage {
    let size = CGFloat(pixels)
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let tile = rounded
        ? CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 100 / 1024, dy: size * 100 / 1024)
        : CGRect(x: 0, y: 0, width: size, height: size)

    context.saveGState()
    if rounded {
        context.setShadow(
            offset: CGSize(width: 0, height: -size * 10 / 1024), blur: size * 20 / 1024,
            color: CGColor(gray: 0, alpha: 0.3)
        )
        context.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.2237, cornerHeight: tile.width * 0.2237, transform: nil))
    } else {
        context.addRect(tile)
    }
    context.setFillColor(brand)
    context.fillPath()
    context.restoreGState()

    let mark = CGRect(x: 0, y: 0, width: tile.width * 0.56, height: tile.width * 0.46)
        .offsetBy(dx: tile.midX - tile.width * 0.28, dy: tile.midY - tile.width * 0.23)
    context.setFillColor(chalk)
    for (index, height) in heights.enumerated() {
        let width = mark.width * barWidth
        let barHeight = max(mark.height * height, width)
        let bar = CGRect(
            x: mark.minX + CGFloat(index) * mark.width * (barWidth + gap), y: mark.midY - barHeight / 2,
            width: width, height: barHeight
        )
        context.addPath(CGPath(roundedRect: bar, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
    }
    context.fillPath()
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else { fatalError("Give the path of AppIcon.appiconset") }
let folder = URL(fileURLWithPath: CommandLine.arguments[1])

var entries: [[String: String]] = [
    ["filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
]
write(icon(pixels: 1024, rounded: false), to: folder.appendingPathComponent("icon-ios-1024.png"))

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-mac-\(points)@\(scale)x.png"
        write(icon(pixels: points * scale, rounded: true), to: folder.appendingPathComponent(name))
        entries.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}

let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: folder.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icons to \(folder.path)")
