//
//  SelectionHighlightDetectorTests.swift
//  CaptureNativeLogicTests
//
//  Regression coverage for the pixel-highlight selection detector. The bug it
//  guards: the detector sampled the cursor's colour with a 5x5 MEDIAN, which —
//  because the analysis image is downsampled and that smears dark glyph strokes
//  toward grey — returned the glyph ink whenever the cursor sat on a word. That
//  read as a colour "distinct from the page", so ordinary text registered as a
//  selection highlight and the reconstructor sliced the captured word down to the
//  letters under the bogus rect (point at "study", capture "tud"). The fix takes
//  the window's DOMINANT colour (the paper behind the glyphs) instead, so plain
//  text no longer false-fires while a real coloured highlight still does.
//
//  Plain-text cases use images at / below the detector's working dimension (no
//  downsampling), so glyph bars stay crisp and the median-vs-mode distinction is
//  exercised deterministically: the cursor sits on a solid dark bar (a point /
//  median sample would fire) surrounded by enough paper that the window mode is
//  the paper (the fix returns nil). With `localBackgroundRadius = 0` (the old
//  point-sampling behaviour) these tests fail; with the window mode they pass.
//  Features are centred vertically, so a Vision-normalized cursor y = 0.5 hits
//  them without origin-flip arithmetic.
//

import CoreGraphics
import XCTest

@testable import CaptureNativeLogic

final class SelectionHighlightDetectorTests: XCTestCase {

    // MARK: image builders

    private func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    private func fill(_ ctx: CGContext, _ rect: CGRect, _ rgb: (CGFloat, CGFloat, CGFloat)) {
        ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        ctx.fill(rect)
    }

    /// A horizontal line of vertical "glyph" bars, centred on the image's vertical
    /// middle, over [x0, x1).
    private func textBars(
        _ ctx: CGContext, imageHeight h: Int, x0: Int, x1: Int,
        barWidth: Int, spacing: Int, bandHeight: Int, ink: (CGFloat, CGFloat, CGFloat)
    ) {
        let y = h / 2 - bandHeight / 2
        var x = x0
        while x < x1 {
            fill(ctx, CGRect(x: x, y: y, width: barWidth, height: bandHeight), ink)
            x += spacing
        }
    }

    // MARK: plain text must NOT register as a selection (the bug)

    func testPlainBlackOnWhiteTextIsNotASelection() {
        // <= 900px long edge → no downsampling → crisp bars.
        let w = 400, h = 300
        let img = image(width: w, height: h) { ctx in
            fill(ctx, CGRect(x: 0, y: 0, width: w, height: h), (1, 1, 1))  // white page
            textBars(
                ctx, imageHeight: h, x0: 40, x1: 360,
                barWidth: 3, spacing: 8, bandHeight: 40, ink: (0, 0, 0))  // a line of glyphs
        }
        // Cursor squarely on the centre of a black bar (40..42) — a point / median
        // sample sees ink here; the window mode must still see the surrounding paper.
        let cursor = CGPoint(x: 41.0 / Double(w), y: 0.5)
        XCTAssertNil(
            SelectionHighlightDetector.detectHighlightRect(in: img, cursorVision: cursor),
            "plain black-on-white text under the cursor must not register as a selection")
    }

    func testWhiteOnDarkTextIsNotASelection() {
        let w = 400, h = 300
        let img = image(width: w, height: h) { ctx in
            fill(ctx, CGRect(x: 0, y: 0, width: w, height: h), (0.12, 0.12, 0.12))  // dark page
            textBars(
                ctx, imageHeight: h, x0: 40, x1: 360,
                barWidth: 3, spacing: 8, bandHeight: 40, ink: (0.86, 0.86, 0.86))
        }
        let cursor = CGPoint(x: 41.0 / Double(w), y: 0.5)
        XCTAssertNil(
            SelectionHighlightDetector.detectHighlightRect(in: img, cursorVision: cursor),
            "dark-mode text under the cursor must not register as a selection")
    }

    // MARK: a real coloured selection must STILL be detected

    func testSolidColouredSelectionIsDetected() {
        let w = 1600, h = 1000
        let selX0 = 400, selW = 500, bandH = 64
        let img = image(width: w, height: h) { ctx in
            fill(ctx, CGRect(x: 0, y: 0, width: w, height: h), (1, 1, 1))
            fill(
                ctx, CGRect(x: selX0, y: h / 2 - bandH / 2, width: selW, height: bandH),
                (0.30, 0.55, 0.95))  // system-accent-like highlight
        }
        let cursor = CGPoint(x: Double(selX0 + selW / 2) / Double(w), y: 0.5)
        let rect = SelectionHighlightDetector.detectHighlightRect(in: img, cursorVision: cursor)
        XCTAssertNotNil(rect, "a distinct coloured selection under the cursor must be detected")
        if let rect {
            // Roughly the highlight's horizontal extent (selW / w ≈ 0.31).
            XCTAssertGreaterThan(rect.width, 0.15)
            XCTAssertLessThan(rect.width, 0.6)
        }
    }

    func testHighlightedTextStillDetectedThroughTheBlurBridge() {
        let w = 1600, h = 1000
        let selX0 = 400, selW = 500, bandH = 64
        let img = image(width: w, height: h) { ctx in
            fill(ctx, CGRect(x: 0, y: 0, width: w, height: h), (1, 1, 1))
            fill(
                ctx, CGRect(x: selX0, y: h / 2 - bandH / 2, width: selW, height: bandH),
                (0.30, 0.55, 0.95))
            // Thin dark glyphs over the highlight — downsampling blurs them into the
            // highlight so the flood fill bridges them (the detector's design).
            textBars(
                ctx, imageHeight: h, x0: selX0 + 20, x1: selX0 + selW - 20,
                barWidth: 3, spacing: 22, bandHeight: bandH - 16, ink: (0, 0, 0))
        }
        let cursor = CGPoint(x: Double(selX0 + selW / 2) / Double(w), y: 0.5)
        XCTAssertNotNil(
            SelectionHighlightDetector.detectHighlightRect(in: img, cursorVision: cursor),
            "a coloured selection with text over it must still be detected")
    }
}
