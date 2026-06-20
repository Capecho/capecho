//
//  SelectionHighlightDetector.swift
//  capture_native
//
//  Sandbox-safe text-selection detection: the selection highlight is a colored
//  background already present in the captured screenshot, so we find it by image
//  analysis (no Accessibility, no leaving the sandbox). Around the cursor we look
//  for a contiguous region whose background colour differs from the page, and
//  return its bounding box; the caller maps the lines inside it to a selection.
//

import CoreGraphics
import Foundation

enum SelectionHighlightDetector {
    /// Long edge the image is scaled down to for analysis. Downsampling with
    /// interpolation averages thin glyph strokes into the background, which lets a
    /// simple flood fill bridge the text inside a selection.
    private static let workingMaxDimension = 900
    /// RGB distance for a pixel to count as the same highlight colour.
    private static let fillTolerance = 50.0
    /// Minimum RGB distance between the cursor's local background and the page
    /// background for there to be a "selection" (otherwise the cursor is on plain text).
    private static let distinctThreshold = 26.0
    /// A region larger than this fraction of the image isn't a text selection.
    private static let maxAreaFraction = 0.6
    /// Half-size of the square window whose DOMINANT colour is taken as the
    /// cursor's local background. Taking the window MODE (not a point / median
    /// sample) is what stops ordinary text from registering as a selection:
    /// downsampling smears dark glyph strokes toward grey, so a sample taken right
    /// on a stroke reads as a colour distinct from the page and trips the gate.
    /// The most common colour in a small window is the paper behind the glyphs
    /// (or, inside a real selection, the highlight) regardless of the ink the
    /// cursor happens to sit on. Small enough to fit inside the smallest real
    /// highlight (a short word).
    private static let localBackgroundRadius = 3

    /// The selection-highlight bounding box around `cursorVision` (Vision
    /// normalized space, origin bottom-left), or nil when there's no distinct
    /// highlight under the cursor. The returned rect is in the same normalized space.
    static func detectHighlightRect(in image: CGImage, cursorVision: CGPoint) -> CGRect? {
        guard let pixels = Pixels(downsampling: image, maxDimension: workingMaxDimension) else { return nil }
        let width = pixels.width, height = pixels.height
        guard width > 4, height > 4 else { return nil }

        // Cursor pixel (buffer is top-left origin; Vision is bottom-left).
        let cx = clamp(Int(cursorVision.x * Double(width)), 0, width - 1)
        let cy = clamp(Int((1 - cursorVision.y) * Double(height)), 0, height - 1)

        // The cursor's LOCAL background = the most common colour in a small window
        // around it (the paper behind the glyphs, or a real highlight) — NOT a point
        // / median sample, which lands on a downsample-greyed glyph when the cursor
        // sits on a word and makes plain text read as a distinct "highlight".
        let localBackground = pixels.dominantColor(aroundX: cx, y: cy, radius: localBackgroundRadius)
        let pageBackground = pixels.dominantColor()
        guard distance(localBackground, pageBackground) > distinctThreshold else {
            return nil   // cursor's background matches the page → no selection highlight
        }

        guard let box = pixels.floodFillBounds(startX: cx, startY: cy, target: localBackground, tolerance: fillTolerance) else {
            return nil
        }
        let areaFraction = Double((box.maxX - box.minX + 1) * (box.maxY - box.minY + 1)) / Double(width * height)
        guard areaFraction < maxAreaFraction, (box.maxX - box.minX) >= 2, (box.maxY - box.minY) >= 1 else {
            return nil
        }

        // Pixel box (top-left) → Vision normalized (bottom-left).
        let minXn = Double(box.minX) / Double(width)
        let maxXn = Double(box.maxX + 1) / Double(width)
        let topYn = Double(box.minY) / Double(height)
        let bottomYn = Double(box.maxY + 1) / Double(height)
        return CGRect(x: minXn, y: 1 - bottomYn, width: maxXn - minXn, height: bottomYn - topYn)
    }

    private static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }
}

/// A small RGBA8 pixel buffer (top-left origin) for color analysis.
private struct Pixels {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init?(downsampling image: CGImage, maxDimension: Int) {
        let longest = max(image.width, image.height)
        let scale = longest > maxDimension ? Double(maxDimension) / Double(longest) : 1.0
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else {
            return nil
        }
        context.interpolationQuality = .high
        // Default (no flip): drawing a CGImage fills the rect upright, so buffer
        // row 0 is the image's top row (top-left origin).
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.width = w
        self.height = h
        self.data = buffer
    }

    func color(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * width + x) * 4
        return (Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
    }

    /// Most common (quantized) colour in a dense square window around (x,y): the
    /// paper behind the glyphs — or, inside a real selection, the highlight. Using
    /// the window MODE makes it robust to the ink the cursor sits on, where a point
    /// / median sample returns a downsample-greyed glyph and (compared to the page)
    /// trips the distinctness gate on plain text. A window fully off-image falls
    /// back to the exact cursor pixel.
    func dominantColor(aroundX x: Int, y: Int, radius: Int) -> (Double, Double, Double) {
        var histogram: [Int: Int] = [:]
        for dy in -radius...radius {
            for dx in -radius...radius {
                let sx = x + dx, sy = y + dy
                guard sx >= 0, sy >= 0, sx < width, sy < height else { continue }
                histogram[Self.quantize(color(sx, sy)), default: 0] += 1
            }
        }
        guard let key = histogram.max(by: { $0.value < $1.value })?.key else { return color(x, y) }
        return Self.dequantize(key)
    }

    /// Most common (quantized) colour across a sparse grid — the page background.
    func dominantColor() -> (Double, Double, Double) {
        var histogram: [Int: Int] = [:]
        let stepX = max(1, width / 60), stepY = max(1, height / 60)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                histogram[Self.quantize(color(x, y)), default: 0] += 1
                x += stepX
            }
            y += stepY
        }
        guard let key = histogram.max(by: { $0.value < $1.value })?.key else { return (255, 255, 255) }
        return Self.dequantize(key)
    }

    /// Pack a colour into a 12-bit bucket (4 bits/channel) — the histogram key
    /// shared by both dominant-colour passes.
    private static func quantize(_ c: (Double, Double, Double)) -> Int {
        (Int(c.0) >> 4) | ((Int(c.1) >> 4) << 4) | ((Int(c.2) >> 4) << 8)
    }

    /// Inverse of [quantize]: the bucket's representative colour (its centre).
    private static func dequantize(_ key: Int) -> (Double, Double, Double) {
        (Double((key & 0xF) << 4 | 8), Double(((key >> 4) & 0xF) << 4 | 8), Double(((key >> 8) & 0xF) << 4 | 8))
    }

    /// Bounding box of the contiguous region of `target`-coloured pixels containing
    /// the start point. Iterative stack flood fill, bounded by the buffer size.
    func floodFillBounds(startX: Int, startY: Int, target: (Double, Double, Double), tolerance: Double) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var visited = [Bool](repeating: false, count: width * height)
        var stack: [(Int, Int)] = [(startX, startY)]
        var minX = startX, maxX = startX, minY = startY, maxY = startY
        var filled = 0

        while let (x, y) = stack.popLast() {
            guard x >= 0, y >= 0, x < width, y < height else { continue }
            let index = y * width + x
            if visited[index] { continue }
            visited[index] = true

            let c = color(x, y)
            let dr = c.0 - target.0, dg = c.1 - target.1, db = c.2 - target.2
            if (dr * dr + dg * dg + db * db).squareRoot() > tolerance { continue }

            filled += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)

            stack.append((x + 1, y)); stack.append((x - 1, y))
            stack.append((x, y + 1)); stack.append((x, y - 1))
        }

        return filled >= 4 ? (minX, minY, maxX, maxY) : nil
    }
}
