//
//  PaceSetOfMarkRendererTests.swift
//  leanring-buddyTests
//
//  Unit tests for PaceSetOfMarkRenderer. Synthesizes small in-process
//  JPEGs so tests run without bundled fixtures and verify pixel-level
//  correctness, dimension preservation, and the Y-coordinate convention.
//

import Foundation
import Testing
import AppKit

@testable import Pace

// MARK: - Helpers shared across all test cases

/// Build a solid-color JPEG of the requested pixel dimensions.
/// Using NSBitmapImageRep directly avoids screen-scale factor ambiguity —
/// we always get exactly `width × height` pixels.
private func makeSolidColorJPEG(
    pixelWidth: Int,
    pixelHeight: Int,
    color: NSColor = .blue
) -> Data? {
    guard
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep)
    NSGraphicsContext.current = graphicsContext
    color.setFill()
    NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
    NSGraphicsContext.restoreGraphicsState()

    return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
}

/// Decode JPEG bytes back into an NSBitmapImageRep. Returns nil if the data
/// is not a recognisable image.
private func decodeJPEG(_ data: Data) -> NSBitmapImageRep? {
    guard
        let image = NSImage(data: data),
        let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
    else { return nil }
    return rep
}

// MARK: - Tests

@MainActor
struct PaceSetOfMarkRendererTests {

    // MARK: - Basic output validity

    @Test func drawMarksWithValidBoxesReturnsNonNilDataThatDecodesToSameDimensions() throws {
        let inputPixelWidth = 200
        let inputPixelHeight = 150
        let inputJPEG = try #require(makeSolidColorJPEG(pixelWidth: inputPixelWidth, pixelHeight: inputPixelHeight))

        let boxes = [
            PaceSetOfMarkBox(index: 0, bbox: [10, 10, 40, 30]),
            PaceSetOfMarkBox(index: 1, bbox: [80, 60, 50, 40]),
        ]

        let outputData = PaceSetOfMarkRenderer.drawMarks(onJPEG: inputJPEG, boxes: boxes)
        let decodedOutput = try #require(outputData.flatMap { decodeJPEG($0) })

        #expect(decodedOutput.pixelsWide == inputPixelWidth)
        #expect(decodedOutput.pixelsHigh == inputPixelHeight)
    }

    // MARK: - Edge case: empty box list

    @Test func drawMarksWithEmptyBoxListReturnsValidImageWithSameDimensions() throws {
        let inputPixelWidth = 100
        let inputPixelHeight = 80
        let inputJPEG = try #require(makeSolidColorJPEG(pixelWidth: inputPixelWidth, pixelHeight: inputPixelHeight))

        let outputData = PaceSetOfMarkRenderer.drawMarks(onJPEG: inputJPEG, boxes: [])
        let decodedOutput = try #require(outputData.flatMap { decodeJPEG($0) })

        #expect(decodedOutput.pixelsWide == inputPixelWidth)
        #expect(decodedOutput.pixelsHigh == inputPixelHeight)
    }

    // MARK: - Edge case: partially or fully out-of-bounds boxes

    @Test func drawMarksWithBoxPartiallyOutsideImageBoundsDoesNotCrash() throws {
        let inputPixelWidth = 80
        let inputPixelHeight = 60
        let inputJPEG = try #require(makeSolidColorJPEG(pixelWidth: inputPixelWidth, pixelHeight: inputPixelHeight))

        let boxes = [
            // Starts in-bounds, extends well beyond the right/bottom edge.
            PaceSetOfMarkBox(index: 0, bbox: [60, 40, 200, 200]),
            // Entirely off to the right.
            PaceSetOfMarkBox(index: 1, bbox: [500, 10, 50, 50]),
            // Negative origin — partially off the left/top edge.
            PaceSetOfMarkBox(index: 2, bbox: [-10, -10, 30, 30]),
        ]

        // Must not crash or return nil; dimension preservation is the signal.
        let outputData = PaceSetOfMarkRenderer.drawMarks(onJPEG: inputJPEG, boxes: boxes)
        let decodedOutput = try #require(outputData.flatMap { decodeJPEG($0) })

        #expect(decodedOutput.pixelsWide == inputPixelWidth)
        #expect(decodedOutput.pixelsHigh == inputPixelHeight)
    }

    // MARK: - Edge case: malformed input data

    @Test func drawMarksWithNonImageDataReturnsNil() {
        let garbage = Data("this is not a jpeg".utf8)
        let result = PaceSetOfMarkRenderer.drawMarks(onJPEG: garbage, boxes: [])
        #expect(result == nil)
    }

    // MARK: - Edge case: boxes with invalid bbox arrays

    @Test func drawMarksSkipsBoxesWithWrongBboxElementCount() throws {
        let inputPixelWidth = 120
        let inputPixelHeight = 90
        let inputJPEG = try #require(makeSolidColorJPEG(pixelWidth: inputPixelWidth, pixelHeight: inputPixelHeight))

        let boxes = [
            // Only 3 elements — invalid, must be skipped without crashing.
            PaceSetOfMarkBox(index: 0, bbox: [10, 10, 40]),
            // Zero width — must be skipped.
            PaceSetOfMarkBox(index: 1, bbox: [20, 20, 0, 30]),
            // Zero height — must be skipped.
            PaceSetOfMarkBox(index: 2, bbox: [30, 30, 40, 0]),
            // Valid box so we confirm output is non-nil.
            PaceSetOfMarkBox(index: 3, bbox: [5, 5, 20, 20]),
        ]

        let outputData = PaceSetOfMarkRenderer.drawMarks(onJPEG: inputJPEG, boxes: boxes)
        #expect(outputData != nil)
    }

    // MARK: - Y-coordinate convention sanity check

    /// This is the critical correctness test. We draw a single mark in the
    /// TOP-LEFT quadrant of the image (small x, small y in top-left-origin
    /// coordinates) and verify:
    ///   1. Pixels in that TOP-LEFT quadrant CHANGED (the mark was drawn there).
    ///   2. Pixels in the BOTTOM-LEFT quadrant did NOT change (the mark was
    ///      NOT flipped to the bottom by a coordinate-system bug).
    ///
    /// We use a solid-green source image so any drawn pixel is trivially
    /// distinguishable — sampling the green channel is sufficient.
    @Test func drawMarksPlacesBoxAtTopOfImageNotBottomVerifyingTopLeftOriginConvention() throws {
        let imageWidth = 200
        let imageHeight = 200

        // Solid green fill — every pixel starts as pure green so a mark drawn
        // in any corner is immediately visible as a non-green pixel there.
        let inputJPEG = try #require(
            makeSolidColorJPEG(pixelWidth: imageWidth, pixelHeight: imageHeight, color: .green)
        )

        // Place the mark strictly in the top-left quadrant:
        // bbox y=10 means 10px from the TOP in top-left-origin coordinates.
        let topLeftBox = PaceSetOfMarkBox(index: 42, bbox: [10, 10, 60, 60])

        let outputData = try #require(
            PaceSetOfMarkRenderer.drawMarks(onJPEG: inputJPEG, boxes: [topLeftBox])
        )

        // Re-decode the result into a bitmap we can sample pixel-by-pixel.
        let outputBitmapRep = try #require(
            NSBitmapImageRep(data: outputData)
        )

        // We confirm output has the expected dimensions before pixel sampling.
        #expect(outputBitmapRep.pixelsWide == imageWidth)
        #expect(outputBitmapRep.pixelsHigh == imageHeight)

        // --- Sample pixels ---
        // The box spans approximately x:[10,70], y:[10,70] in TOP-LEFT coords.
        // NSBitmapImageRep.colorAt(x:y:) uses TOP-LEFT-origin pixel coordinates,
        // which matches the bbox convention we declared (and what we expect to
        // see modified).

        // TOP-LEFT region: should contain mark pixels (not pure green).
        let topLeftSamplePixel = try #require(
            outputBitmapRep.colorAt(x: 15, y: 15)?.usingColorSpace(.deviceRGB)
        )
        let topLeftIsUnchangedGreen = isApproximatelyPureGreen(topLeftSamplePixel)

        // BOTTOM-LEFT region: should be entirely untouched pure green because
        // the mark belongs at the top. A Y-flip bug would put the mark here.
        let bottomLeftSamplePixel = try #require(
            outputBitmapRep.colorAt(x: 15, y: imageHeight - 20)?.usingColorSpace(.deviceRGB)
        )
        let bottomLeftIsUnchangedGreen = isApproximatelyPureGreen(bottomLeftSamplePixel)

        // The mark must have changed at least the top-left sampling point.
        #expect(!topLeftIsUnchangedGreen, "Top-left region should contain mark pixels — the box was drawn there")
        // The bottom-left region must remain untouched (no Y-flip bug).
        #expect(bottomLeftIsUnchangedGreen, "Bottom-left region should be untouched pure green — the mark must NOT have been flipped to the bottom")
    }

    // MARK: - Pure-green pixel helper

    /// Returns true when all three visible channels look like pure green
    /// (green≈1, red≈0, blue≈0) after JPEG lossy compression.
    /// A tolerance of 0.15 accounts for JPEG chroma artifacts on solid fills.
    private func isApproximatelyPureGreen(_ color: NSColor) -> Bool {
        let tolerance: CGFloat = 0.15
        return color.redComponent < tolerance
            && color.greenComponent > (1.0 - tolerance)
            && color.blueComponent < tolerance
    }
}
