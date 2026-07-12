//
//  PaceVisualFindService.swift
//  leanring-buddy
//
//  Deterministic, OCR-grounded "find text on screen" — no LLM in the
//  loop. Capture the screen(s) → run Vision OCR (which returns verbatim
//  text + pixel bounding boxes) → case-insensitive substring match the
//  user's query against every recognized box → draw a red rectangle over
//  each match through the existing annotation overlay. Because the coords
//  come straight from OCR (not a model's guess), the rectangles land
//  pixel-accurately, in ~1 second.
//
//  Reuses, verbatim:
//    * `CompanionScreenCaptureUtility.captureAllScreensAsJPEG()` for capture
//    * `PaceVisionOCRClient.recognizeText(...)` for OCR (same call the
//       screen-context service makes — screenshot pixel-dimensions in,
//       `RecognizedTextBox` list out, top-left-origin pixel bboxes)
//    * `PaceAnnotationCoordinateMapper` + `PaceRenderedAnnotation` +
//      `PaceAnnotationOverlayController.setAnnotations(...)` for rendering
//       (identical conversion pattern to
//       `PaceAnnotationActionDrainer.applyDrawAnnotation`)
//
//  The pure geometry/match helpers are `nonisolated` and unit-testable
//  without any screenshot or TCC-gated capture.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
enum PaceVisualFindService {

    /// Hard ceiling on rendered rectangles. A query that matches 400
    /// boxes (e.g. "e" against a wall of text) should not blanket the
    /// screen; we mark the first `maximumRenderedMatches` and say so.
    static let maximumRenderedMatches = 20

    /// Padding (in screenshot pixels) added around each OCR box so the
    /// annotation stroke frames the text instead of covering it.
    static let matchBoxPixelPadding = 4

    /// Capture every screen, OCR each capture, mark all substring matches
    /// of `query`, and push the rectangles onto the annotation overlay.
    ///
    /// Returns the match counts so the caller can speak a deterministic
    /// confirmation. Throws only if screen capture itself fails; an empty
    /// screen or a no-match query returns a zero count (not an error).
    static func findAndMark(
        query: String,
        overlayController: PaceAnnotationOverlayController,
        visionOCRClient: PaceVisionOCRClient
    ) async throws -> (totalMatches: Int, renderedMatches: Int) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return (0, 0) }

        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

        // Order captures cursor-screen-first so, when we hit the render
        // cap, the "first 20" are on the screen the user is looking at.
        let orderedCaptures = orderCapturesCursorScreenFirst(screenCaptures)

        // OCR each capture and collect matching boxes together with the
        // 1-based screen index they belong to (so the overlay maps each
        // rectangle to the right monitor).
        var matchesAcrossScreens: [(screenIndex: Int, capture: CompanionScreenCapture, box: RecognizedTextBox)] = []
        for (captureIndex, capture) in orderedCaptures.enumerated() {
            // Same OCR call the screen-context service makes: screenshot
            // bytes + the capture's screenshot pixel dimensions in,
            // top-left-origin pixel bboxes out.
            let recognizedBoxes = (try? await visionOCRClient.recognizeText(
                in: capture.imageData,
                screenshotWidthInPixels: capture.screenshotWidthInPixels,
                screenshotHeightInPixels: capture.screenshotHeightInPixels
            )) ?? []

            let matchingBoxes = matchBoxes(query: trimmedQuery, in: recognizedBoxes)
            let oneBasedScreenIndex = captureIndex + 1
            for matchingBox in matchingBoxes {
                matchesAcrossScreens.append((oneBasedScreenIndex, capture, matchingBox))
            }
        }

        let totalMatchCount = matchesAcrossScreens.count
        guard totalMatchCount > 0 else {
            // No matches — make sure any stale annotation layer is gone so
            // the user isn't confused by leftover rectangles.
            overlayController.clear(reason: "visual-find: no matches")
            return (0, 0)
        }

        // Cap the rendered rectangles so a runaway match count can't paint
        // the whole screen. The first N are cursor-screen-first, top-of-
        // screen-first (OCR returns roughly reading order).
        let cappedMatches = Array(matchesAcrossScreens.prefix(maximumRenderedMatches))

        // Only the FIRST rendered rectangle carries a text label — labeling
        // every box turns a dense match set into unreadable clutter.
        let renderedAnnotations: [PaceRenderedAnnotation] = cappedMatches.enumerated().map {
            renderIndex, match in
            let shouldLabel = renderIndex == 0
            let labelText = shouldLabel ? truncatedMatchLabel(for: match.box.text) : nil
            let paddedPixelBox = paddedPixelBoundingBox(
                match.box.pixelBoundingBox,
                paddingPixels: matchBoxPixelPadding
            )
            let appKitRect = PaceVisualFindService.convertPixelBoxToAppKitGlobalRect(
                paddedPixelBox,
                on: match.capture
            )
            return PaceRenderedAnnotation(
                geometry: .rect(appKitRect),
                style: PaceAnnotationStyle(
                    color: .red,
                    label: labelText,
                    strokeWidth: PaceAnnotationStyle.default.strokeWidth,
                    filled: false
                ),
                screenIndex: match.screenIndex
            )
        }

        overlayController.setAnnotations(renderedAnnotations)
        return (totalMatchCount, renderedAnnotations.count)
    }

    // MARK: - Pure, testable helpers

    /// Compose the plain-language spoken confirmation for a completed
    /// visual-find run. Deterministic (no LLM): zero matches, one match,
    /// N matches, and the capped "first 20 of N" case each get their own
    /// wording. Pure so it is unit-testable without capture or TTS.
    nonisolated static func spokenConfirmation(
        query: String,
        totalMatches: Int,
        renderedMatches: Int
    ) -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard totalMatches > 0 else {
            return "i couldn't find '\(trimmedQuery)' on your screen."
        }
        if totalMatches == 1 {
            return "marked 1 match for '\(trimmedQuery)'."
        }
        if renderedMatches < totalMatches {
            return "found \(totalMatches) matches for '\(trimmedQuery)' — marked the first \(renderedMatches)."
        }
        return "marked \(totalMatches) matches for '\(trimmedQuery)'."
    }

    /// Case-insensitive substring match of `query` against each box's
    /// text. Unicode-normalized on both sides so a composed "é" in the
    /// query matches a decomposed "é" in the OCR output (the OCR client
    /// already NFC-normalizes its boxes; we normalize the query to the
    /// same form). Pure — no capture, no OCR, no actor state.
    nonisolated static func matchBoxes(
        query: String,
        in recognizedBoxes: [RecognizedTextBox]
    ) -> [RecognizedTextBox] {
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        guard !normalizedQuery.isEmpty else { return [] }

        return recognizedBoxes.filter { recognizedBox in
            let normalizedBoxText = recognizedBox.text
                .precomposedStringWithCanonicalMapping
                .lowercased()
            return normalizedBoxText.contains(normalizedQuery)
        }
    }

    /// Grow a `[x, y, width, height]` pixel box outward by `paddingPixels`
    /// on every side so the drawn stroke frames the text rather than
    /// covering it. Origin is clamped at 0 so a box at the very top-left
    /// of the screenshot doesn't get a negative origin. Pure.
    nonisolated static func paddedPixelBoundingBox(
        _ pixelBoundingBox: [Int],
        paddingPixels: Int
    ) -> [Int] {
        guard pixelBoundingBox.count == 4 else { return pixelBoundingBox }
        let originX = pixelBoundingBox[0]
        let originY = pixelBoundingBox[1]
        let width = pixelBoundingBox[2]
        let height = pixelBoundingBox[3]
        let paddedOriginX = max(0, originX - paddingPixels)
        let paddedOriginY = max(0, originY - paddingPixels)
        // Width/height grow by twice the padding, but only add back the
        // padding we actually applied on the origin side so the box stays
        // centered on the text when we clamped the origin at 0.
        let appliedLeftPadding = originX - paddedOriginX
        let appliedTopPadding = originY - paddedOriginY
        let paddedWidth = width + appliedLeftPadding + paddingPixels
        let paddedHeight = height + appliedTopPadding + paddingPixels
        return [paddedOriginX, paddedOriginY, paddedWidth, paddedHeight]
    }

    /// Truncate the matched text to a readable label (≤60 chars, matching
    /// `PaceAnnotationStyle.sanitizedLabel`'s cap). Adds an ellipsis when
    /// clipped. Pure.
    nonisolated static func truncatedMatchLabel(for matchedText: String) -> String {
        let trimmedText = matchedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumLabelCharacters = 60
        guard trimmedText.count > maximumLabelCharacters else { return trimmedText }
        return String(trimmedText.prefix(maximumLabelCharacters)) + "…"
    }

    // MARK: - Coordinate conversion (mirrors PaceAnnotationActionDrainer)

    /// Convert an OCR `[x, y, width, height]` pixel box (top-left origin,
    /// +y down) into an AppKit-global `CGRect` (bottom-left origin) using
    /// the SAME two-corner-map pattern as
    /// `PaceAnnotationActionDrainer.convertScreenshotPixelRectToAppKit`:
    /// map the pixel top-left and pixel bottom-right independently through
    /// `PaceAnnotationCoordinateMapper`, then rebuild a positive-size rect.
    nonisolated static func convertPixelBoxToAppKitGlobalRect(
        _ pixelBoundingBox: [Int],
        on screenCapture: CompanionScreenCapture
    ) -> CGRect {
        guard pixelBoundingBox.count == 4 else { return .zero }
        let pixelX = Double(pixelBoundingBox[0])
        let pixelY = Double(pixelBoundingBox[1])
        let pixelWidth = Double(pixelBoundingBox[2])
        let pixelHeight = Double(pixelBoundingBox[3])

        let pixelTopLeft = CGPoint(x: pixelX, y: pixelY)
        let pixelBottomRight = CGPoint(x: pixelX + pixelWidth, y: pixelY + pixelHeight)
        let appKitTopLeft = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
            screenshotPixelPoint: pixelTopLeft,
            on: screenCapture
        )
        let appKitBottomRight = PaceAnnotationCoordinateMapper.convertScreenshotPixelToAppKitGlobal(
            screenshotPixelPoint: pixelBottomRight,
            on: screenCapture
        )
        let rectOriginX = min(appKitTopLeft.x, appKitBottomRight.x)
        let rectOriginY = min(appKitTopLeft.y, appKitBottomRight.y)
        let rectWidth = abs(appKitBottomRight.x - appKitTopLeft.x)
        let rectHeight = abs(appKitTopLeft.y - appKitBottomRight.y)
        return CGRect(x: rectOriginX, y: rectOriginY, width: rectWidth, height: rectHeight)
    }

    // MARK: - Capture ordering

    /// Put the cursor screen first so, when the render cap trims the
    /// match list, the surviving rectangles are on the screen the user is
    /// looking at. Non-cursor screens keep their capture order after it.
    nonisolated static func orderCapturesCursorScreenFirst(
        _ screenCaptures: [CompanionScreenCapture]
    ) -> [CompanionScreenCapture] {
        let cursorScreenCaptures = screenCaptures.filter { $0.isCursorScreen }
        let otherScreenCaptures = screenCaptures.filter { !$0.isCursorScreen }
        return cursorScreenCaptures + otherScreenCaptures
    }
}
