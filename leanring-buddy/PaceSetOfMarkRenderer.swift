//
//  PaceSetOfMarkRenderer.swift
//  leanring-buddy
//
//  Draws numbered bounding-box overlays onto a JPEG screenshot so the
//  vision model can visually correlate "element 7" in the text element list
//  with the matching region it sees in the image — the Set-of-Mark technique.
//

import AppKit

// MARK: - Box input type

/// One numbered bounding box to draw onto a screenshot image.
/// `bbox` is `[x, y, width, height]` in pixels measured from the TOP-LEFT
/// corner of the image (y grows DOWN), matching `LocalVLMScreenElement.bbox`.
nonisolated struct PaceSetOfMarkBox {
    let index: Int
    let bbox: [Int]
}

// MARK: - Renderer

/// Stateless pure renderer. Decodes a JPEG, draws numbered box overlays, and
/// re-encodes to JPEG. Returns `nil` on any decode/encode failure so the
/// caller can fall back to the unmarked image.
nonisolated enum PaceSetOfMarkRenderer {

    // MARK: - Public API

    /// Draw numbered bounding-box marks onto a JPEG image.
    ///
    /// - Parameters:
    ///   - imageData: Source JPEG bytes.
    ///   - boxes: Boxes to render. Each `bbox` must be `[x, y, width, height]`
    ///     in top-left-origin pixel coordinates (y grows DOWN).
    /// - Returns: A new JPEG with overlaid marks, or `nil` if decode/encode fails.
    static func drawMarks(onJPEG imageData: Data, boxes: [PaceSetOfMarkBox]) -> Data? {
        guard
            let bitmapRep = NSBitmapImageRep(data: imageData),
            bitmapRep.pixelsWide > 0,
            bitmapRep.pixelsHigh > 0
        else {
            return nil
        }

        let imagePixelWidth = bitmapRep.pixelsWide
        let imagePixelHeight = bitmapRep.pixelsHigh

        // --- Y-FLIP NOTE ---
        // `bbox` uses top-left-origin (y=0 at the top, y grows DOWN) to match
        // how the VLM returns element coordinates. NSBitmapImageRep's drawing
        // context uses bottom-left-origin (y=0 at the bottom, y grows UP).
        // We apply `scaleYBy: -1` + `translateYBy: -imagePixelHeight` to flip
        // the entire drawing context so (0,0) becomes the top-left corner and
        // all incoming y values are passed through unchanged.
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        let cgContext = graphicsContext.cgContext

        // Flip the coordinate system so y=0 is the image TOP, matching the
        // top-left-origin convention of the incoming bbox coordinates.
        cgContext.translateBy(x: 0, y: CGFloat(imagePixelHeight))
        cgContext.scaleBy(x: 1, y: -1)

        for box in boxes {
            drawSingleMark(
                box: box,
                inContext: cgContext,
                imagePixelWidth: imagePixelWidth,
                imagePixelHeight: imagePixelHeight
            )
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.85]
        ) else {
            return nil
        }

        return jpegData
    }

    // MARK: - Private drawing helpers

    private static func drawSingleMark(
        box: PaceSetOfMarkBox,
        inContext cgContext: CGContext,
        imagePixelWidth: Int,
        imagePixelHeight: Int
    ) {
        // Require a valid 4-element bbox with positive dimensions.
        guard box.bbox.count == 4 else { return }

        let bboxX = box.bbox[0]
        let bboxY = box.bbox[1]
        let bboxWidth = box.bbox[2]
        let bboxHeight = box.bbox[3]

        guard bboxWidth > 0, bboxHeight > 0 else { return }

        // Clamp the rectangle to image bounds so partially off-screen boxes
        // are drawn correctly and fully out-of-bounds boxes are skipped.
        let clampedX = max(0, min(bboxX, imagePixelWidth - 1))
        let clampedY = max(0, min(bboxY, imagePixelHeight - 1))
        let clampedRight = max(clampedX, min(bboxX + bboxWidth, imagePixelWidth))
        let clampedBottom = max(clampedY, min(bboxY + bboxHeight, imagePixelHeight))
        let clampedWidth = clampedRight - clampedX
        let clampedHeight = clampedBottom - clampedY

        guard clampedWidth > 0, clampedHeight > 0 else { return }

        let boxRect = CGRect(
            x: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )

        drawBoxOutline(boxRect: boxRect, inContext: cgContext)
        drawIndexLabel(
            index: box.index,
            nearTopLeftOf: boxRect,
            inContext: cgContext,
            imagePixelWidth: imagePixelWidth,
            imagePixelHeight: imagePixelHeight
        )
    }

    /// Draw a 2px magenta rectangle stroke around `boxRect`.
    private static func drawBoxOutline(boxRect: CGRect, inContext cgContext: CGContext) {
        cgContext.saveGState()
        cgContext.setStrokeColor(NSColor.systemPink.cgColor)
        cgContext.setLineWidth(2.0)
        cgContext.stroke(boxRect)
        cgContext.restoreGState()
    }

    /// Draw a small filled label chip at the top-left corner of `boxRect`
    /// showing `index` as white text on a magenta background.
    private static func drawIndexLabel(
        index: Int,
        nearTopLeftOf boxRect: CGRect,
        inContext cgContext: CGContext,
        imagePixelWidth: Int,
        imagePixelHeight: Int
    ) {
        let labelText = "\(index)" as NSString
        let labelFontSize: CGFloat = 11
        let labelFont = NSFont.boldSystemFont(ofSize: labelFontSize)

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white,
        ]

        // Measure the rendered text so the background chip fits snugly.
        let textSize = labelText.size(withAttributes: textAttributes)
        let labelPadding: CGFloat = 2
        let labelChipWidth = textSize.width + labelPadding * 2
        let labelChipHeight = textSize.height + labelPadding

        // Place the chip at the top-left corner of the box, clamped so it
        // stays within the image boundaries.
        let chipX = min(boxRect.minX, CGFloat(imagePixelWidth) - labelChipWidth)
        let chipY = min(boxRect.minY, CGFloat(imagePixelHeight) - labelChipHeight)
        let clampedChipX = max(0, chipX)
        let clampedChipY = max(0, chipY)

        let chipRect = CGRect(
            x: clampedChipX,
            y: clampedChipY,
            width: labelChipWidth,
            height: labelChipHeight
        )

        // Draw the filled background chip.
        cgContext.saveGState()
        cgContext.setFillColor(NSColor.systemPink.cgColor)
        cgContext.fill(chipRect)
        cgContext.restoreGState()

        // Draw the text inside the chip using the NSGraphicsContext that is
        // already set (drawMarks sets it before calling this function).
        let textOrigin = CGPoint(
            x: clampedChipX + labelPadding,
            y: clampedChipY + labelPadding / 2
        )
        labelText.draw(at: textOrigin, withAttributes: textAttributes)
    }
}
