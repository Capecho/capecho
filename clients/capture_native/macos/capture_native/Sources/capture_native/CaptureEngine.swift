//
//  CaptureEngine.swift
//  capture_native
//
//  Thin native adapter: does ONLY platform work — screen capture, OCR,
//  highlight-pixel detection — and returns a platform-neutral "OCR snapshot"
//  dictionary. It may attach system word-boundary hints, but it does NOT target
//  the cursor token, reconstruct paragraphs, or segment sentences; all
//  reconstruction lives in the shared Dart core.
//
//  Output dictionary (the cross-platform contract):
//    [
//      "lines": [
//        [
//          "text": String,
//          "confidence": Double,                       // Vision top-candidate [0,1]
//          "box": ["x","y","width","height": Double],   // the whole line
//          "fontRuns": [
//            [
//              "lineIndex": Int,
//              "runIndex": Int,
//              "range": ["start","end": Int],            // UTF-16 range in text
//              "text": String,
//              "box": ["x","y","width","height": Double],
//              "fontSize": ["px","pt": Double]
//            ], ...
//          ],
//          "wordRuns": [
//            [
//              "range": ["start","end": Int],            // UTF-16 range in text
//              "text": String,                           // system word token
//              "box": ["x","y","width","height": Double]
//            ], ...
//          ],
//          "charBoxes": [["x","y","width","height": Double], ...]  // OPTIONAL — one
//            // per UTF-16 code unit of `text`, present only for line(s) under the
//            // cursor; helps selection sub-line extraction keep whole characters.
//        ], ...
//      ],
//      "cursor": ["x": Double, "y": Double],
//      "cursorVisualSpan": [
//        "schemaVersion": 1,
//        "text": String,                                  // visual span text
//        "lineIndices": [Int],
//        "anchor": ["lineIndex","runIndex","utf16Offset": Int, ...],
//        "segments": [fontRun, ...],
//        "detectedLanguage": String,                      // OPTIONAL — NLLanguageRecognizer
//        "detectedLanguageConfidence": Double             // dominant language of `text` [0,1]
//      ],
//      "selectionRect": ["x","y","width","height": Double]  // omitted if no selection
//      "screenName": String,
//      "sourceApp": String,    // OPTIONAL — owning app of the captured window
//      "sourceTitle": String,  // OPTIONAL — captured window's title
//      "recognitionLanguages": [String]
//    ]
//  All boxes/points are Vision-normalized: range [0,1], ORIGIN BOTTOM-LEFT, y up
//  (Vision's native boundingBox). On failure, returns ["error": "<reason>"].
//

import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import Vision

final class CaptureEngine {
    private let visualSpanFontToleranceRatio = 0.10
    private let visualSpanLineCadenceToleranceRatio = 0.35
    private let visualSpanMinimumFontTolerancePt = 2.0
    private let visualSpanMinimumLineCadenceTolerancePx = 8.0
    private let visualSpanHorizontalGapToGlyphWidthRatio = 4.0
    private let visualSpanHorizontalGapToLineHeightRatio = 1.5
    private let visualSpanAnchorHorizontalGapToLineHeightRatio = 0.5
    private let visualSpanMinimumRowSeparationRatio = 0.5
    private let visualSpanColumnOverlapRatio = 0.15
    private let visualSpanMaxLineCadenceToLineHeightRatio = 1.8
    // A first-hop candidate is rejected when its nearest same-column neighbour
    // FURTHER along the walk sits this much tighter than the candidate sits to
    // us — it belongs to that other block (see expandVisualSpan first-hop guard).
    private let visualSpanBoundElsewhereRatio = 0.75
    // A continuation candidate must be within this height ratio of the anchor —
    // lenient enough to tolerate within-headline Vision noise, tight enough to cut
    // a title off from the smaller sub-head / metadata below it (nextVisualSpanSegment).
    private let visualSpanAnchorFontToleranceRatio = 0.35

    // MARK: - Public API (called by CaptureNativePlugin)

    /// Performs capture + OCR + highlight detection on the topmost normal window
    /// under the cursor and returns the OCR-snapshot dictionary described above.
    /// On any failure, returns a dictionary `["error": "<reason>"]`.
    ///
    /// [onScreenshotSecured] is invoked ONCE, off-main, the instant the screenshot is
    /// captured — AFTER the shot, BEFORE the (slow) Vision OCR pass. The host uses it to
    /// show the capturing-loader: shown here it cannot land in the shot (the shot is
    /// already a static image), and it covers the OCR. The callback must marshal its own
    /// UI work to the main thread.
    func capture(
        onScreenshotSecured: (() -> Void)? = nil
    ) async -> [String: Any] {
        // NSEvent / NSScreen are main-thread-only AppKit APIs, so resolve the
        // cursor + display geometry ON THE MAIN ACTOR first, then run the capture,
        // OCR, and pixel work off-main with plain Sendable value types. (Reading
        // them from the background `Task` that invokes capture() would give stale
        // geometry or trap under the main-thread checker.)
        let resolution: InputResolution = await MainActor.run {
            let mouseLocation = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
                return .failure("screenUnavailable")
            }
            guard let displayID = screen.displayID else {
                return .failure("displayIdentifierUnavailable")
            }
            let displayBounds = CGDisplayBounds(displayID)
            let mouseInDisplayX = mouseLocation.x - screen.frame.minX
            let mouseInDisplayYFromTop = screen.frame.maxY - mouseLocation.y
            return .ok(CaptureInputs(
                cgMouseLocation: CGPoint(
                    x: displayBounds.minX + mouseInDisplayX,
                    y: displayBounds.minY + mouseInDisplayYFromTop
                ),
                displayID: displayID,
                backingScaleFactor: screen.backingScaleFactor,
                screenName: screen.localizedName
            ))
        }

        let inputs: CaptureInputs
        switch resolution {
        case .failure(let reason): return ["error": reason]
        case .ok(let value): inputs = value
        }

        let target: CaptureTarget
        do {
            target = try await captureWindowUnderCursor(inputs)
        } catch let error as CaptureError {
            return ["error": error.reason]
        } catch {
            return ["error": "captureFailed"]
        }

        // The screenshot is now a static CGImage; everything after this (OCR, layout)
        // reads it, so showing the loader here keeps it out of the shot while covering
        // the slow Vision pass that follows.
        onScreenshotSecured?()

        let request = makeTextRequest()
        let languages = request.recognitionLanguages
        do {
            let handler = VNImageRequestHandler(cgImage: target.image, orientation: .up)
            try handler.perform([request])
        } catch {
            return ["error": "ocrFailed"]
        }

        guard let observations = request.results, !observations.isEmpty else {
            return ["error": "noTextFound"]
        }

        // The cursor in Vision-normalized space — resolved BEFORE the line loop
        // so per-character boxing can be gated to the line(s) under the cursor.
        let cursorPoint = target.cursorPoint

        // Build the platform-neutral line list: top candidate string + Vision's
        // native bounding box (normalized, origin bottom-left). Native may add
        // platform word-boundary hints, but reading-order sort and reconstruction
        // stay in Dart.
        var lines: [[String: Any]] = []
        var visualLines: [VisualLineInfo] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            let lineIndex = lines.count
            let estimatedTextHeightPx = Double(box.height) * Double(target.image.height)
            let estimatedTextHeightPt =
                target.pointPixelScale > 0
                ? estimatedTextHeightPx / target.pointPixelScale
                : estimatedTextHeightPx
            let glyphs = glyphMetrics(for: candidate)
            let runs = visualRuns(
                for: candidate,
                lineIndex: lineIndex,
                lineBox: box,
                lineHeightPx: estimatedTextHeightPx,
                imageWidth: target.image.width,
                imageHeight: target.image.height,
                pointPixelScale: target.pointPixelScale,
                glyphs: glyphs
            )
            var line: [String: Any] = [
                "text": candidate.string,
                // Vision's top-candidate confidence [0,1] — the cascade uses the
                // max line confidence to decide whether OCR is trustworthy enough
                // to win over a fresh clipboard (US-4.1, issue #12).
                "confidence": Double(candidate.confidence),
                // Vision gives text boxes, not real font metadata, so estimate visible
                // text height from the OCR line box.
                "estimatedTextHeight": [
                    "px": estimatedTextHeightPx,
                    "pt": estimatedTextHeightPt,
                ],
                "box": [
                    "x": Double(box.origin.x),
                    "y": Double(box.origin.y),
                    "width": Double(box.size.width),
                    "height": Double(box.size.height),
                ],
            ]
            if !runs.isEmpty {
                line["fontRuns"] = runs.map { $0.snapshotMap }
            }
            let words = wordRuns(
                for: candidate,
                lineIndex: lineIndex,
                glyphs: refinedGlyphMetricsForWordRuns(glyphs)
            )
            if !words.isEmpty {
                line["wordRuns"] = words.map { $0.snapshotMap }
            }
            // Attach Vision's per-character geometry for the line(s) under the
            // cursor so selection sub-line extraction can keep whole characters.
            // Hover token boxes now come from native `wordRuns`; char boxes stay
            // cursor-gated to keep the method-channel payload bounded.
            if lineIsNearCursor(box, cursorPoint),
                let charBoxes = characterBoxes(from: glyphs, utf16Count: candidate.string.utf16.count) {
                line["charBoxes"] = charBoxes
            }
            visualLines.append(VisualLineInfo(
                index: lineIndex,
                text: candidate.string,
                box: box,
                estimatedTextHeightPx: estimatedTextHeightPx,
                estimatedTextHeightPt: estimatedTextHeightPt,
                runs: runs,
                glyphs: glyphs
            ))
            lines.append(line)
        }

        guard !lines.isEmpty else {
            return ["error": "noTextFound"]
        }

        var snapshot: [String: Any] = [
            "lines": lines,
            "cursor": [
                "x": Double(cursorPoint.x),
                "y": Double(cursorPoint.y),
            ],
            "screenName": inputs.screenName,
            "recognitionLanguages": languages,
        ]
        // Capture-source provenance ("where I met this word") — the app + window title of the captured
        // window. Omit-when-nil so the snapshot map only carries what was actually resolved.
        if let sourceApp = target.sourceApp { snapshot["sourceApp"] = sourceApp }
        if let sourceTitle = target.sourceTitle { snapshot["sourceTitle"] = sourceTitle }
        if let visualSpan = cursorVisualSpan(
            in: visualLines,
            cursor: cursorPoint,
            imageWidth: target.image.width,
            imageHeight: target.image.height
        ) {
            snapshot["cursorVisualSpan"] = visualSpan
        }

        // Selection comes ONLY from the pixel highlight detector (sandbox-safe,
        // no Accessibility). If a distinct highlight is found under the cursor,
        // attach its normalized rect; otherwise omit the key entirely.
        if let highlight = SelectionHighlightDetector.detectHighlightRect(in: target.image, cursorVision: cursorPoint) {
            snapshot["selectionRect"] = [
                "x": Double(highlight.origin.x),
                "y": Double(highlight.origin.y),
                "width": Double(highlight.size.width),
                "height": Double(highlight.size.height),
            ]
        }

        return snapshot
    }

    /// Whether the app currently holds Screen Recording permission.
    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts for Screen Recording permission. Returns whether access is granted
    /// (the system prompt only appears on first request; thereafter the user must
    /// grant it in System Settings and relaunch).
    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Capture

    /// Captures only the frontmost normal window rendered under the cursor.
    private func captureWindowUnderCursor(_ inputs: CaptureInputs) async throws -> CaptureTarget {
        let shareableContent = try await SCShareableContent.current
        guard shareableContent.displays.contains(where: { $0.displayID == inputs.displayID }) else {
            throw CaptureError.shareableDisplayUnavailable
        }

        guard let target = topmostWindowUnderCursor(in: shareableContent, inputs: inputs) else {
            throw CaptureError.windowUnavailable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(target.bounds.width * inputs.backingScaleFactor))
        configuration.height = max(1, Int(target.bounds.height * inputs.backingScaleFactor))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = false
        configuration.queueDepth = 1

        let filter = SCContentFilter(desktopIndependentWindow: target.window)
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CaptureError.captureFailed)
                }
            }
        }

        return CaptureTarget(
            image: image,
            cursorPoint: normalizedVisionPoint(forCGPoint: inputs.cgMouseLocation, inCGBounds: target.bounds),
            description: target.description,
            sourceApp: target.sourceApp,
            sourceTitle: target.sourceTitle,
            pointPixelScale: target.bounds.width > 0
                ? Double(image.width) / Double(target.bounds.width)
                : Double(inputs.backingScaleFactor)
        )
    }

    /// Finds the topmost ScreenCaptureKit window whose CoreGraphics bounds
    /// contain the cursor. CGWindowListCopyWindowInfo provides the actual z-order.
    private func topmostWindowUnderCursor(
        in shareableContent: SCShareableContent,
        inputs: CaptureInputs
    ) -> (window: SCWindow, bounds: CGRect, description: String, sourceApp: String?, sourceTitle: String?)? {
        let windowsByID = Dictionary(uniqueKeysWithValues: shareableContent.windows.map { ($0.windowID, $0) })
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in raw {
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = CGWindowID(number.uint32Value)
            guard let window = windowsByID[windowID], window.isOnScreen else { continue }
            // No self-exclusion: Capecho's own normal content windows (Review / Word Book /
            // Settings) are a valid capture target — the user can hover-capture text inside
            // Capecho itself, "what you see is what gets recognized". The capture overlay and
            // OCR loader never land in the shot — both are .floating panels (windowLayer != 0,
            // excluded just below), and they are shown only AFTER the screenshot anyway.
            if window.windowLayer != 0 { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha <= 0.01 { continue }

            guard
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.width > 1,
                bounds.height > 1,
                bounds.contains(inputs.cgMouseLocation)
            else {
                continue
            }

            // The owning app's name + the window title: the human "where I met this word" provenance.
            // `description` keeps the combined "App · Title" form (diagnostics); sourceApp/sourceTitle
            // are the separate, persisted fields. A blank app name degrades to nil (never the
            // "unknown app" placeholder — that's display-only noise we don't want stored).
            let appName = window.owningApplication?.applicationName
            let windowTitle = (window.title?.isEmpty == false) ? window.title : nil
            let app = appName ?? "unknown app"
            let titleSuffix = windowTitle != nil ? " · \(windowTitle!)" : ""
            return (
                window, bounds, "\(app)\(titleSuffix)",
                (appName?.isEmpty == false) ? appName : nil,
                windowTitle
            )
        }

        return nil
    }

    // MARK: - OCR

    private func makeTextRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.01
        // Vision auto-detects the languages: it handles arbitrary mixed scripts far better
        // than a forced target-led set, so recognition is no longer driven by the user's
        // configured languages. The captured unit's language is decided downstream (the
        // shared core's effectiveTargetLanguage + the overlay's target-switch suggestion).
        request.automaticallyDetectsLanguage = true
        return request
    }

    // MARK: - Cursor mapping

    /// Maps a CoreGraphics top-left-origin screen point into Vision-normalized
    /// coordinates for a CoreGraphics top-left-origin window bounds rect.
    private func normalizedVisionPoint(forCGPoint point: CGPoint, inCGBounds bounds: CGRect) -> CGPoint {
        let x = bounds.width > 0 ? (point.x - bounds.minX) / bounds.width : 0
        let yFromTop = bounds.height > 0 ? (point.y - bounds.minY) / bounds.height : 0

        return CGPoint(
            x: min(max(x, 0), 1),
            y: min(max(1 - yFromTop, 0), 1)
        )
    }

    private static func cgRect(_ dict: [String: Double]) -> CGRect {
        CGRect(
            x: dict["x"] ?? 0,
            y: dict["y"] ?? 0,
            width: dict["width"] ?? 0,
            height: dict["height"] ?? 0
        )
    }

    // MARK: - Cursor visual span debug

    private func cursorVisualSpan(
        in lines: [VisualLineInfo],
        cursor: CGPoint,
        imageWidth: Int,
        imageHeight: Int
    ) -> [String: Any]? {
        guard let anchor = anchorRun(in: lines, cursor: cursor, imageWidth: imageWidth, imageHeight: imageHeight) else {
            return nil
        }

        let position = anchorPosition(in: anchor.line, run: anchor.run)
        let utf16Offset = cursorUtf16Offset(
            in: anchor.line,
            run: anchor.run,
            cursor: cursor,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let lineCadenceReferencePx = anchorLineCadenceReferencePx(
            anchorLine: anchor.line,
            allLines: lines,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let up = (position == .whole || position == .left)
            ? expandVisualSpan(
                direction: .up,
                fromLine: anchor.line,
                fromRun: anchor.run,
                allLines: lines,
                initialExpectedCadencePx: lineCadenceReferencePx,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
            : []
        let down = (position == .whole || position == .right)
            ? expandVisualSpan(
                direction: .down,
                fromLine: anchor.line,
                fromRun: anchor.run,
                allLines: lines,
                initialExpectedCadencePx: lineCadenceReferencePx,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
            : []
        let segments = up.reversed() + [anchor.run] + down

        var tuning: [String: Any] = [
            "fontToleranceRatio": visualSpanFontToleranceRatio,
            "lineCadenceToleranceRatio": visualSpanLineCadenceToleranceRatio,
            "minimumLineCadenceTolerancePx": visualSpanMinimumLineCadenceTolerancePx,
            "horizontalGapToGlyphWidthRatio": visualSpanHorizontalGapToGlyphWidthRatio,
            "horizontalGapToLineHeightRatio": visualSpanHorizontalGapToLineHeightRatio,
            "anchorHorizontalGapToLineHeightRatio": visualSpanAnchorHorizontalGapToLineHeightRatio,
        ]
        if let lineCadenceReferencePx {
            tuning["lineCadenceReferencePx"] = lineCadenceReferencePx
        }

        let spanText = segments.map(\.text).joined(separator: "\n")
        var span: [String: Any] = [
            "schemaVersion": 1,
            "text": spanText,
            "lineIndices": segments.map(\.lineIndex),
            "anchor": [
                "lineIndex": anchor.line.index,
                "runIndex": anchor.run.runIndex,
                "utf16Offset": utf16Offset,
                "position": position.rawValue,
                "fontSizePx": anchor.run.fontHeightPx,
                "fontSizePt": anchor.run.fontHeightPt,
                "lineHeightPx": anchor.line.estimatedTextHeightPx,
                "lineHeightPt": anchor.line.estimatedTextHeightPt,
            ],
            "tuning": tuning,
            "segments": segments.map { $0.snapshotMap },
        ]
        // Phase 2 (unit-language confirm): the span's dominant language, so the shared
        // core can suggest switching the capture target when the user is reading a
        // passage in a language other than their learning target — the SAME-script
        // case an auto-switch can't decide (script-disjoint is handled upstream by
        // effectiveTargetLanguage). NaturalLanguage-only; best-effort, omitted when
        // undetected. This is a recognition HINT — it never sets target attribution.
        if let detected = LanguageDetector.detect(spanText) {
            span["detectedLanguage"] = detected.language
            span["detectedLanguageConfidence"] = detected.confidence
        }
        return span
    }

    private func anchorRun(
        in lines: [VisualLineInfo],
        cursor: CGPoint,
        imageWidth: Int,
        imageHeight: Int
    ) -> (line: VisualLineInfo, run: VisualTextRun)? {
        guard let line = lines.min(by: { lhs, rhs in
            pointDistancePx(cursor, lhs.box, imageWidth: imageWidth, imageHeight: imageHeight)
                < pointDistancePx(cursor, rhs.box, imageWidth: imageWidth, imageHeight: imageHeight)
        }) else {
            return nil
        }
        guard let run = bestRun(in: line, cursor: cursor, imageWidth: imageWidth, imageHeight: imageHeight) else {
            return nil
        }
        return (line, run)
    }

    private func bestRun(
        in line: VisualLineInfo,
        cursor: CGPoint,
        imageWidth: Int,
        imageHeight: Int
    ) -> VisualTextRun? {
        guard !line.runs.isEmpty else { return nil }
        if line.runs.count == 1 { return line.runs[0] }
        return line.runs.min { lhs, rhs in
            pointDistancePx(cursor, lhs.box, imageWidth: imageWidth, imageHeight: imageHeight)
                < pointDistancePx(cursor, rhs.box, imageWidth: imageWidth, imageHeight: imageHeight)
        }
    }

    private func anchorPosition(in line: VisualLineInfo, run: VisualTextRun) -> VisualAnchorPosition {
        if line.runs.count <= 1 { return .whole }
        if run.runIndex == line.runs.first?.runIndex { return .left }
        if run.runIndex == line.runs.last?.runIndex { return .right }
        return .middle
    }

    private func cursorUtf16Offset(
        in line: VisualLineInfo,
        run: VisualTextRun,
        cursor: CGPoint,
        imageWidth: Int,
        imageHeight: Int
    ) -> Int {
        let candidates = line.glyphs.filter {
            !$0.isWhitespace
                && !$0.box.isEmpty
                && $0.utf16Start >= run.utf16Start
                && $0.utf16Start < run.utf16End
        }
        guard let best = candidates.min(by: { lhs, rhs in
            glyphCursorScore(lhs, cursor: cursor, imageWidth: imageWidth, imageHeight: imageHeight)
                < glyphCursorScore(rhs, cursor: cursor, imageWidth: imageWidth, imageHeight: imageHeight)
        }) else {
            return run.utf16Start
        }
        return best.utf16Start
    }

    private func glyphCursorScore(
        _ glyph: GlyphMetric,
        cursor: CGPoint,
        imageWidth: Int,
        imageHeight: Int
    ) -> Double {
        let outside = pointDistancePx(cursor, glyph.box, imageWidth: imageWidth, imageHeight: imageHeight)
        let center = hypot(
            Double(cursor.x - glyph.box.midX) * Double(imageWidth),
            Double(cursor.y - glyph.box.midY) * Double(imageHeight)
        )
        return outside * 10 + center
    }

    private func anchorLineCadenceReferencePx(
        anchorLine: VisualLineInfo,
        allLines: [VisualLineInfo],
        imageWidth: Int,
        imageHeight: Int
    ) -> Double? {
        var cadences: [Double] = []

        for candidateLine in allLines where candidateLine.index != anchorLine.index {
            guard sameTextColumn(
                anchorLine.box,
                candidateLine.box,
                lineHeightPx: anchorLine.estimatedTextHeightPx,
                imageWidth: imageWidth,
                horizontalGapToLineHeightRatio: visualSpanAnchorHorizontalGapToLineHeightRatio
            ) else {
                continue
            }

            let rowSeparationPx = abs(Double(candidateLine.box.midY - anchorLine.box.midY)) * Double(imageHeight)
            let minimumRowSeparationPx =
                min(candidateLine.estimatedTextHeightPx, anchorLine.estimatedTextHeightPx)
                * visualSpanMinimumRowSeparationRatio
            if rowSeparationPx < minimumRowSeparationPx {
                continue
            }
            if rowSeparationPx > maxAllowedLineCadencePx(
                currentLine: anchorLine,
                candidateLine: candidateLine,
                anchorLine: anchorLine
            ) {
                continue
            }
            cadences.append(rowSeparationPx)
        }

        return cadences.min()
    }

    private func expandVisualSpan(
        direction: VisualSpanDirection,
        fromLine anchorLine: VisualLineInfo,
        fromRun anchorRun: VisualTextRun,
        allLines: [VisualLineInfo],
        initialExpectedCadencePx: Double?,
        imageWidth: Int,
        imageHeight: Int
    ) -> [VisualTextRun] {
        var selected: [VisualTextRun] = []
        var selectedLineIndices: Set<Int> = [anchorLine.index]
        var currentLine = anchorLine
        var currentRun = anchorRun
        var expectedCadencePx = initialExpectedCadencePx

        while let next = nextVisualSpanSegment(
            direction: direction,
            currentLine: currentLine,
            currentRun: currentRun,
            anchorLine: anchorLine,
            allLines: allLines,
            selectedLineIndices: selectedLineIndices,
            expectedCadencePx: expectedCadencePx,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        ) {
            selected.append(next.run)
            selectedLineIndices.insert(next.line.index)
            if expectedCadencePx == nil {
                expectedCadencePx = next.cadencePx
            }
            currentLine = next.line
            currentRun = next.run
        }

        return selected
    }

    private func nextVisualSpanSegment(
        direction: VisualSpanDirection,
        currentLine: VisualLineInfo,
        currentRun: VisualTextRun,
        anchorLine: VisualLineInfo,
        allLines: [VisualLineInfo],
        selectedLineIndices: Set<Int>,
        expectedCadencePx: Double?,
        imageWidth: Int,
        imageHeight: Int
    ) -> (line: VisualLineInfo, run: VisualTextRun, cadencePx: Double)? {
        var best: (line: VisualLineInfo, run: VisualTextRun, cadencePx: Double, score: Double)?

        for candidateLine in allLines where !selectedLineIndices.contains(candidateLine.index) {
            switch direction {
            case .up where candidateLine.box.midY <= currentLine.box.midY:
                continue
            case .down where candidateLine.box.midY >= currentLine.box.midY:
                continue
            default:
                break
            }

            let rowSeparationPx = abs(Double(candidateLine.box.midY - currentLine.box.midY)) * Double(imageHeight)
            let minimumRowSeparationPx =
                min(candidateLine.estimatedTextHeightPx, currentLine.estimatedTextHeightPx)
                * visualSpanMinimumRowSeparationRatio
            if rowSeparationPx < minimumRowSeparationPx {
                continue
            }
            if rowSeparationPx > maxAllowedLineCadencePx(
                currentLine: currentLine,
                candidateLine: candidateLine,
                anchorLine: anchorLine
            ) {
                continue
            }
            if let expectedCadencePx,
               !lineCadenceMatches(
                rowSeparationPx,
                expectedCadencePx,
                anchorLineHeightPx: anchorLine.estimatedTextHeightPx
               ) {
                continue
            }
            guard sameVisualBlockColumn(
                anchorLine: anchorLine,
                currentLine: currentLine,
                candidateLine: candidateLine,
                lineHeightPx: anchorLine.estimatedTextHeightPx,
                imageWidth: imageWidth
            ) else {
                continue
            }
            // A wrapped continuation shares the anchor's text size. Reject a
            // candidate whose estimated text height is too far from the anchor's —
            // a smaller sub-head / metadata row under a large title (e.g. a 32pt PR
            // title pulling in the 15pt "wants to merge…" line and 18pt tab labels
            // below it). Deliberately LENIENT (~1.5x): Vision's per-line height
            // estimate is noisy WITHIN one headline (a 42pt line beside its 32pt
            // wrap), so a tight match would re-introduce the headline truncation the
            // cadence rewrite removed. Anchor-relative so size can't drift across a
            // long run into an unrelated block.
            if !ratioMatches(
                candidateLine.estimatedTextHeightPt,
                anchorLine.estimatedTextHeightPt,
                ratio: visualSpanAnchorFontToleranceRatio,
                minimum: visualSpanMinimumFontTolerancePt
            ) {
                continue
            }
            // On the FIRST hop out of the anchor only — the one seeded by the
            // (possibly unreliable) min-cadence reference — reject a candidate
            // that is bound MUCH tighter to its own further same-column neighbour
            // than to us. That candidate is the tail of a SEPARATE block (e.g. a
            // standalone headline's cursor pulling in the last line of the
            // headline above it), not a wrap continuation of the anchor. Compares
            // cadence RATIOS, so it is independent of image scale. Restricting to
            // the first hop leaves an established paragraph's continuation — which
            // the cadence-match already governs — untouched.
            if selectedLineIndices.count == 1,
               isBoundBeyondCurrentBlock(
                candidateLine: candidateLine,
                currentCadencePx: rowSeparationPx,
                direction: direction,
                allLines: allLines,
                selectedLineIndices: selectedLineIndices,
                imageWidth: imageWidth,
                imageHeight: imageHeight
               ) {
                continue
            }
            guard let candidateRun = continuationRun(
                in: candidateLine,
                currentRun: currentRun,
                imageWidth: imageWidth
            ) else {
                continue
            }

            let centerDistancePx =
                abs(Double(candidateRun.box.midX - currentRun.box.midX)) * Double(imageWidth)
            let cadenceScore = expectedCadencePx.map { abs(rowSeparationPx - $0) } ?? rowSeparationPx
            let score = cadenceScore + centerDistancePx * 0.05
            if best == nil || score < best!.score {
                best = (candidateLine, candidateRun, rowSeparationPx, score)
            }
        }

        guard let best else { return nil }
        return (best.line, best.run, best.cadencePx)
    }

    /// Whether [candidateLine] is more tightly bound to its OWN nearest
    /// same-column neighbour further along [direction] than it is to the current
    /// line (cadence `currentCadencePx`). When so, the candidate is the boundary
    /// row of a separate visual block — e.g. the wrapped tail of the headline
    /// above a standalone one-line headline — and merging it would swallow that
    /// other block. The comparison is a ratio of two cadences in the same image,
    /// so it carries no pixel/scale assumption.
    private func isBoundBeyondCurrentBlock(
        candidateLine: VisualLineInfo,
        currentCadencePx: Double,
        direction: VisualSpanDirection,
        allLines: [VisualLineInfo],
        selectedLineIndices: Set<Int>,
        imageWidth: Int,
        imageHeight: Int
    ) -> Bool {
        var nearestBeyondPx: Double?
        for other in allLines
        where other.index != candidateLine.index && !selectedLineIndices.contains(other.index) {
            switch direction {
            case .up where other.box.midY <= candidateLine.box.midY:
                continue
            case .down where other.box.midY >= candidateLine.box.midY:
                continue
            default:
                break
            }
            guard sameTextColumn(
                candidateLine.box,
                other.box,
                lineHeightPx: candidateLine.estimatedTextHeightPx,
                imageWidth: imageWidth
            ) else {
                continue
            }
            let cadencePx = abs(Double(other.box.midY - candidateLine.box.midY)) * Double(imageHeight)
            if nearestBeyondPx == nil || cadencePx < nearestBeyondPx! {
                nearestBeyondPx = cadencePx
            }
        }
        guard let nearestBeyondPx else { return false }
        return nearestBeyondPx < currentCadencePx * visualSpanBoundElsewhereRatio
    }

    private func continuationRun(
        in line: VisualLineInfo,
        currentRun: VisualTextRun,
        imageWidth: Int
    ) -> VisualTextRun? {
        line.runs
            .min { lhs, rhs in
                let lhsDistance = abs(Double(lhs.box.midX - currentRun.box.midX)) * Double(imageWidth)
                let rhsDistance = abs(Double(rhs.box.midX - currentRun.box.midX)) * Double(imageWidth)
                return lhsDistance < rhsDistance
            }
    }

    private func maxAllowedLineCadencePx(
        currentLine: VisualLineInfo,
        candidateLine: VisualLineInfo,
        anchorLine: VisualLineInfo
    ) -> Double {
        max(
            max(currentLine.estimatedTextHeightPx, candidateLine.estimatedTextHeightPx),
            anchorLine.estimatedTextHeightPx
        ) * visualSpanMaxLineCadenceToLineHeightRatio
    }

    private func lineCadenceMatches(
        _ cadencePx: Double,
        _ expectedCadencePx: Double,
        anchorLineHeightPx: Double
    ) -> Bool {
        let tolerance = max(
            max(expectedCadencePx, anchorLineHeightPx) * visualSpanLineCadenceToleranceRatio,
            visualSpanMinimumLineCadenceTolerancePx
        )
        return abs(cadencePx - expectedCadencePx) <= tolerance
    }

    private func sameTextColumn(
        _ lhs: CGRect,
        _ rhs: CGRect,
        lineHeightPx: Double,
        imageWidth: Int,
        horizontalGapToLineHeightRatio: Double? = nil
    ) -> Bool {
        let overlapPx = horizontalOverlap(lhs, rhs) * Double(imageWidth)
        let minWidthPx = min(lhs.width, rhs.width) * Double(imageWidth)
        if minWidthPx > 0, overlapPx / minWidthPx >= visualSpanColumnOverlapRatio {
            return true
        }

        let gapPx = horizontalGap(lhs, rhs) * Double(imageWidth)
        let gapThresholdPx = lineHeightPx * (horizontalGapToLineHeightRatio ?? visualSpanHorizontalGapToLineHeightRatio)
        return gapPx <= gapThresholdPx
    }

    private func sameVisualBlockColumn(
        anchorLine: VisualLineInfo,
        currentLine: VisualLineInfo,
        candidateLine: VisualLineInfo,
        lineHeightPx: Double,
        imageWidth: Int
    ) -> Bool {
        guard sameTextColumn(
            currentLine.box,
            candidateLine.box,
            lineHeightPx: lineHeightPx,
            imageWidth: imageWidth
        ) else {
            return false
        }

        return sameTextColumn(
            anchorLine.box,
            candidateLine.box,
            lineHeightPx: lineHeightPx,
            imageWidth: imageWidth,
            horizontalGapToLineHeightRatio: visualSpanAnchorHorizontalGapToLineHeightRatio
        )
    }

    private func wordRuns(
        for candidate: VNRecognizedText,
        lineIndex: Int,
        glyphs: [GlyphMetric]
    ) -> [NativeWordRun] {
        let text = candidate.string
        return WordSegmenter.segments(in: text).compactMap { segment in
            guard
                segment.utf16Start >= 0,
                segment.utf16End > segment.utf16Start,
                segment.utf16End <= text.utf16.count
            else {
                return nil
            }

            let matchingGlyphs = glyphs.filter {
                !$0.box.isEmpty
                    && $0.utf16Start < segment.utf16End
                    && $0.utf16End > segment.utf16Start
            }
            let glyphBox = unionRect(matchingGlyphs.map(\.box))
            let tokenRange = stringRange(text, utf16Start: segment.utf16Start, utf16End: segment.utf16End)
            let visionBox = tokenRange.flatMap { (try? candidate.boundingBox(for: $0))?.boundingBox }
            guard let box = glyphBox ?? visionBox, !box.isEmpty else {
                return nil
            }

            return NativeWordRun(
                lineIndex: lineIndex,
                utf16Start: segment.utf16Start,
                utf16End: segment.utf16End,
                text: segment.text,
                box: box
            )
        }
    }

    private func visualRuns(
        for candidate: VNRecognizedText,
        lineIndex: Int,
        lineBox: CGRect,
        lineHeightPx: Double,
        imageWidth: Int,
        imageHeight: Int,
        pointPixelScale: Double,
        glyphs: [GlyphMetric]
    ) -> [VisualTextRun] {
        let atoms = visualAtoms(
            for: candidate,
            glyphs: glyphs,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            pointPixelScale: pointPixelScale
        )
        if atoms.isEmpty {
            let lineHeightPt = pointPixelScale > 0 ? lineHeightPx / pointPixelScale : lineHeightPx
            return [VisualTextRun(
                lineIndex: lineIndex,
                runIndex: 0,
                utf16Start: 0,
                utf16End: candidate.string.utf16.count,
                text: candidate.string,
                box: lineBox,
                fontHeightPx: lineHeightPx,
                fontHeightPt: lineHeightPt
            )]
        }

        let typicalGlyphWidthPx = median(
            glyphs
                .filter { !$0.isWhitespace && !$0.box.isEmpty }
                .map { Double($0.box.width) * Double(imageWidth) }
                .filter { $0 > 0 }
        ) ?? max(1, lineHeightPx * 0.5)
        let horizontalBreakThresholdPx = max(
            typicalGlyphWidthPx * visualSpanHorizontalGapToGlyphWidthRatio,
            lineHeightPx * visualSpanHorizontalGapToLineHeightRatio
        )

        var runs: [VisualTextRun] = []
        var currentAtoms: [VisualAtom] = [atoms[0]]
        var previousAtom = atoms[0]

        for atom in atoms.dropFirst() {
            let gapPx = max(0, Double(atom.box.minX - previousAtom.box.maxX) * Double(imageWidth))
            let currentFontPt = median(currentAtoms.map(\.fontHeightPt)) ?? previousAtom.fontHeightPt
            let shouldBreak =
                gapPx > horizontalBreakThresholdPx
                || !ratioMatches(
                    atom.fontHeightPt,
                    currentFontPt,
                    ratio: visualSpanFontToleranceRatio,
                    minimum: visualSpanMinimumFontTolerancePt
                )

            if shouldBreak {
                runs.append(makeVisualRun(
                    from: currentAtoms,
                    sourceText: candidate.string,
                    lineIndex: lineIndex,
                    runIndex: runs.count
                ))
                currentAtoms = [atom]
            } else {
                currentAtoms.append(atom)
            }
            previousAtom = atom
        }

        runs.append(makeVisualRun(
            from: currentAtoms,
            sourceText: candidate.string,
            lineIndex: lineIndex,
            runIndex: runs.count
        ))
        return runs
    }

    private func visualAtoms(
        for candidate: VNRecognizedText,
        glyphs: [GlyphMetric],
        imageWidth _: Int,
        imageHeight: Int,
        pointPixelScale: Double
    ) -> [VisualAtom] {
        let text = candidate.string
        var atoms: [VisualAtom] = []
        var tokenStartIndex: String.Index?
        var tokenGlyphStart: Int?
        var index = text.startIndex
        var glyphIndex = 0

        func appendToken(endIndex: String.Index, endGlyphIndex: Int) {
            guard
                let tokenStartIndex,
                let tokenGlyphStart,
                tokenGlyphStart < endGlyphIndex
            else {
                return
            }

            let tokenGlyphs = Array(glyphs[tokenGlyphStart..<endGlyphIndex])
            let fallbackBox = unionRect(tokenGlyphs.map(\.box).filter { !$0.isEmpty })
            let visionBox = (try? candidate.boundingBox(for: tokenStartIndex..<endIndex)) ?? nil
            guard let box = visionBox?.boundingBox ?? fallbackBox, !box.isEmpty else {
                return
            }

            let utf16Start = tokenGlyphs.first?.utf16Start ?? 0
            let utf16End = tokenGlyphs.last?.utf16End ?? utf16Start
            let heightPx = Double(box.height) * Double(imageHeight)
            atoms.append(VisualAtom(
                utf16Start: utf16Start,
                utf16End: utf16End,
                text: substring(text, utf16Start: utf16Start, utf16End: utf16End),
                box: box,
                fontHeightPx: heightPx,
                fontHeightPt: pointPixelScale > 0 ? heightPx / pointPixelScale : heightPx
            ))
        }

        while index < text.endIndex, glyphIndex < glyphs.count {
            let next = text.index(after: index)
            let glyph = glyphs[glyphIndex]
            if glyph.isWhitespace {
                appendToken(endIndex: index, endGlyphIndex: glyphIndex)
                tokenStartIndex = nil
                tokenGlyphStart = nil
            } else if tokenStartIndex == nil {
                tokenStartIndex = index
                tokenGlyphStart = glyphIndex
            }
            index = next
            glyphIndex += 1
        }
        appendToken(endIndex: text.endIndex, endGlyphIndex: glyphs.count)
        return atoms
    }

    private func makeVisualRun(
        from atoms: [VisualAtom],
        sourceText: String,
        lineIndex: Int,
        runIndex: Int
    ) -> VisualTextRun {
        let utf16Start = atoms.first?.utf16Start ?? 0
        let utf16End = atoms.last?.utf16End ?? utf16Start
        let box = unionRect(atoms.map(\.box)) ?? .zero
        let fontHeightPx = median(atoms.map(\.fontHeightPx)) ?? 0
        let fontHeightPt = median(atoms.map(\.fontHeightPt)) ?? 0
        return VisualTextRun(
            lineIndex: lineIndex,
            runIndex: runIndex,
            utf16Start: utf16Start,
            utf16End: utf16End,
            text: substring(sourceText, utf16Start: utf16Start, utf16End: utf16End),
            box: box,
            fontHeightPx: fontHeightPx,
            fontHeightPt: fontHeightPt
        )
    }

    private func glyphMetrics(for candidate: VNRecognizedText) -> [GlyphMetric] {
        let string = candidate.string
        var metrics: [GlyphMetric] = []
        metrics.reserveCapacity(string.count)

        var index = string.startIndex
        var utf16Offset = 0
        while index < string.endIndex {
            let next = string.index(after: index)
            let slice = string[index..<next]
            let utf16Length = slice.utf16.count
            let observation = (try? candidate.boundingBox(for: index..<next)) ?? nil
            let isWhitespace = slice.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
            metrics.append(GlyphMetric(
                utf16Start: utf16Offset,
                utf16End: utf16Offset + utf16Length,
                box: observation?.boundingBox ?? .zero,
                isWhitespace: isWhitespace,
                widthWeight: glyphWidthWeight(slice)
            ))
            utf16Offset += utf16Length
            index = next
        }

        return metrics
    }

    private func refinedGlyphMetricsForWordRuns(_ glyphs: [GlyphMetric]) -> [GlyphMetric] {
        var refined = glyphs
        var index = 0
        while index < glyphs.count {
            let box = glyphs[index].box
            if box.isEmpty || glyphs[index].isWhitespace {
                index += 1
                continue
            }

            var end = index + 1
            while end < glyphs.count,
                !glyphs[end].isWhitespace,
                sameHorizontalBox(glyphs[end].box, box) {
                end += 1
            }

            if end - index > 1 {
                let totalWeight = glyphs[index..<end].reduce(0.0) { $0 + $1.widthWeight }
                if totalWeight > 0 {
                    var offset = 0.0
                    for i in index..<end {
                        let startX = box.minX + box.width * (offset / totalWeight)
                        offset += glyphs[i].widthWeight
                        let endX = box.minX + box.width * (offset / totalWeight)
                        refined[i] = GlyphMetric(
                            utf16Start: glyphs[i].utf16Start,
                            utf16End: glyphs[i].utf16End,
                            box: CGRect(
                                x: startX,
                                y: box.minY,
                                width: endX - startX,
                                height: box.height
                            ),
                            isWhitespace: glyphs[i].isWhitespace,
                            widthWeight: glyphs[i].widthWeight
                        )
                    }
                }
            }
            index = end
        }
        return refined
    }

    private func sameHorizontalBox(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let epsilon = 0.000001
        return abs(lhs.minX - rhs.minX) < epsilon && abs(lhs.maxX - rhs.maxX) < epsilon
    }

    private func glyphWidthWeight(_ text: Substring) -> Double {
        guard let scalar = text.unicodeScalars.first else { return 1.0 }
        return isWideCodePoint(Int(scalar.value)) ? 2.0 : 1.0
    }

    private func isWideCodePoint(_ value: Int) -> Bool {
        (value >= 0x1100 && value <= 0x115F)
            || (value >= 0x2E80 && value <= 0x303E)
            || (value >= 0x3041 && value <= 0x33FF)
            || (value >= 0x3400 && value <= 0x4DBF)
            || (value >= 0x4E00 && value <= 0x9FFF)
            || (value >= 0xA000 && value <= 0xA4CF)
            || (value >= 0xAC00 && value <= 0xD7A3)
            || (value >= 0xF900 && value <= 0xFAFF)
            || (value >= 0xFE30 && value <= 0xFE4F)
            || (value >= 0xFF00 && value <= 0xFF60)
            || (value >= 0xFFE0 && value <= 0xFFE6)
    }

    private func characterBoxes(from glyphs: [GlyphMetric], utf16Count: Int) -> [[String: Double]]? {
        if utf16Count == 0 { return nil }
        var boxes: [[String: Double]] = []
        boxes.reserveCapacity(utf16Count)
        for glyph in glyphs {
            for _ in glyph.utf16Start..<glyph.utf16End {
                boxes.append(Self.rectDictionary(glyph.box))
            }
        }
        while boxes.count < utf16Count {
            boxes.append(Self.rectDictionary(.zero))
        }
        return boxes
    }

    private func ratioMatches(_ lhs: Double, _ rhs: Double, ratio: Double, minimum: Double) -> Bool {
        abs(lhs - rhs) <= max(max(abs(lhs), abs(rhs)) * ratio, minimum)
    }

    private func pointDistancePx(_ point: CGPoint, _ rect: CGRect, imageWidth: Int, imageHeight: Int) -> Double {
        let outsideX = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let outsideY = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(Double(outsideX) * Double(imageWidth), Double(outsideY) * Double(imageHeight))
    }

    private func horizontalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        max(0, Double(min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)))
    }

    private func horizontalGap(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        if lhs.maxX < rhs.minX { return Double(rhs.minX - lhs.maxX) }
        if rhs.maxX < lhs.minX { return Double(lhs.minX - rhs.maxX) }
        return 0
    }

    private func unionRect(_ rects: [CGRect]) -> CGRect? {
        var result: CGRect?
        for rect in rects where !rect.isEmpty {
            result = result.map { $0.union(rect) } ?? rect
        }
        return result
    }

    private func median(_ values: [Double]) -> Double? {
        if values.isEmpty { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func substring(_ text: String, utf16Start: Int, utf16End: Int) -> String {
        guard let range = stringRange(text, utf16Start: utf16Start, utf16End: utf16End) else {
            return ""
        }
        return String(text[range])
    }

    private func stringRange(_ text: String, utf16Start: Int, utf16End: Int) -> Range<String.Index>? {
        let count = text.utf16.count
        let startOffset = min(max(utf16Start, 0), count)
        let endOffset = min(max(utf16End, startOffset), count)
        let utf16 = text.utf16
        let start16 = utf16.index(utf16.startIndex, offsetBy: startOffset)
        let end16 = utf16.index(utf16.startIndex, offsetBy: endOffset)
        guard
            let start = String.Index(start16, within: text),
            let end = String.Index(end16, within: text)
        else {
            return nil
        }
        return start..<end
    }

    private static func rectDictionary(_ rect: CGRect) -> [String: Double] {
        [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.size.width),
            "height": Double(rect.size.height),
        ]
    }

    // MARK: - Cursor line geometry

    /// Whether [lineBox] is close enough (vertically) to [cursor] to be the line
    /// whose word the user is targeting — the only line whose per-character boxes
    /// change the captured word. The margin matches the reconstructor's
    /// nearest-line cutoff (0.06 normalized) so a line the cursor sits just above
    /// or below is covered too. Bounds the per-glyph `boundingBox(for:)` work to a
    /// handful of lines instead of the whole screen (each call adds capture
    /// latency, and only the cursor's line affects targeting).
    private func lineIsNearCursor(_ lineBox: CGRect, _ cursor: CGPoint) -> Bool {
        let margin: CGFloat = 0.06
        return cursor.y >= lineBox.minY - margin && cursor.y <= lineBox.maxY + margin
    }
}

// Main-thread-resolved capture inputs, passed as plain Sendable value types into
// the off-main capture/OCR work so no NSScreen/NSEvent is ever touched off-main.
private struct CaptureInputs: Sendable {
    let cgMouseLocation: CGPoint
    let displayID: CGDirectDisplayID
    let backingScaleFactor: CGFloat
    let screenName: String
}

private struct CaptureTarget {
    let image: CGImage
    let cursorPoint: CGPoint
    let description: String
    /// The owning application's name and the window's title for the captured window — capture
    /// provenance ("where I met this word"), surfaced separately (not just folded into
    /// `description`) so the snapshot can carry them as distinct fields. nil when unavailable.
    let sourceApp: String?
    let sourceTitle: String?
    let pointPixelScale: Double
}

private struct VisualLineInfo {
    let index: Int
    let text: String
    let box: CGRect
    let estimatedTextHeightPx: Double
    let estimatedTextHeightPt: Double
    let runs: [VisualTextRun]
    let glyphs: [GlyphMetric]
}

private struct VisualTextRun {
    let lineIndex: Int
    let runIndex: Int
    let utf16Start: Int
    let utf16End: Int
    let text: String
    let box: CGRect
    let fontHeightPx: Double
    let fontHeightPt: Double

    var snapshotMap: [String: Any] {
        [
            "lineIndex": lineIndex,
            "runIndex": runIndex,
            "range": [
                "start": utf16Start,
                "end": utf16End,
            ],
            "text": text,
            "fontSize": [
                "px": fontHeightPx,
                "pt": fontHeightPt,
            ],
            "box": [
                "x": Double(box.origin.x),
                "y": Double(box.origin.y),
                "width": Double(box.size.width),
                "height": Double(box.size.height),
            ],
        ]
    }
}

private struct NativeWordRun {
    let lineIndex: Int
    let utf16Start: Int
    let utf16End: Int
    let text: String
    let box: CGRect

    var snapshotMap: [String: Any] {
        [
            "lineIndex": lineIndex,
            "range": [
                "start": utf16Start,
                "end": utf16End,
            ],
            "text": text,
            "box": [
                "x": Double(box.origin.x),
                "y": Double(box.origin.y),
                "width": Double(box.size.width),
                "height": Double(box.size.height),
            ],
        ]
    }
}

private struct VisualAtom {
    let utf16Start: Int
    let utf16End: Int
    let text: String
    let box: CGRect
    let fontHeightPx: Double
    let fontHeightPt: Double
}

private struct GlyphMetric {
    let utf16Start: Int
    let utf16End: Int
    let box: CGRect
    let isWhitespace: Bool
    let widthWeight: Double
}

private enum VisualAnchorPosition: String {
    case whole
    case left
    case middle
    case right
}

private enum VisualSpanDirection {
    case up
    case down
}

private enum InputResolution {
    case ok(CaptureInputs)
    case failure(String)
}

// Capture failures; the `reason` strings are returned to Dart.
private enum CaptureError: Error {
    case shareableDisplayUnavailable
    case windowUnavailable
    case captureFailed

    var reason: String {
        switch self {
        case .shareableDisplayUnavailable: return "shareableDisplayUnavailable"
        case .windowUnavailable: return "windowUnavailable"
        case .captureFailed: return "captureFailed"
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
