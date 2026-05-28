//
//  PaceScreenContextScaler.swift
//  leanring-buddy
//
//  Pure coordinate-scaling math for screen-context elements. Split
//  from `PaceAXScreenReader` so the scale calculation is testable in
//  isolation — no AXUIElement runtime, no NSScreen, just numbers in
//  and numbers out.
//
//  Why this exists
//  ---------------
//  CompanionScreenCaptureUtility downsamples every captured display
//  to maxDimension=1280 px. The original AX reader scaled AX points
//  by the display's native Retina factor (2.0 typically), producing
//  "pixel" coordinates relative to a hypothetical 3456-wide screenshot
//  — but the actual screenshot the planner is being asked to reason
//  about is 1280 wide. The mismatched scale caused every click to
//  land at the screen edge once horizontal coords exceeded 1728.
//
//  The fix: scale AX points by the ACTUAL screenshot:display ratio
//  (`screenshotPixels / displayPoints`), not Retina. The two paths
//  — AX → element list → planner, and planner → executor → CGEvent
//  — now share one consistent pixel space.
//

import CoreGraphics
import Foundation

enum PaceScreenContextScaler {
    /// Scale a single AX-point bounding box into screenshot-pixel
    /// coordinates for a given capture. The math mirrors the inverse
    /// done by `PaceActionExecutor.convertScreenshotPixelToDisplay-
    /// GlobalPoint` — keep these two functions consistent or clicks
    /// will land in the wrong place again.
    ///
    /// `axPointBoundingBox` — `[x, y, width, height]` in AX global
    /// points (top-left origin spanning all displays).
    /// `screenLocalOriginInAXPoints` — where the target screen's
    /// top-left corner lives in AX's global point space. For the
    /// primary screen this is (0, 0); for a secondary screen it's
    /// the offset of that screen's top-left in the global plane.
    ///
    /// Returns the bbox in screenshot-pixel coordinates, top-left
    /// origin within the target screen's screenshot.
    static func scaleAXBoundingBoxToScreenshotPixels(
        axPointBoundingBox: [Int],
        screenLocalOriginInAXPoints: CGPoint,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> [Int]? {
        guard axPointBoundingBox.count == 4,
              displayWidthInPoints > 0,
              displayHeightInPoints > 0 else {
            return nil
        }

        let pointsToPixelsScaleX = Double(screenshotWidthInPixels) / Double(displayWidthInPoints)
        let pointsToPixelsScaleY = Double(screenshotHeightInPixels) / Double(displayHeightInPoints)

        let globalAXOriginX = Double(axPointBoundingBox[0])
        let globalAXOriginY = Double(axPointBoundingBox[1])

        let localPointX = globalAXOriginX - Double(screenLocalOriginInAXPoints.x)
        let localPointY = globalAXOriginY - Double(screenLocalOriginInAXPoints.y)

        let pixelX = Int(localPointX * pointsToPixelsScaleX)
        let pixelY = Int(localPointY * pointsToPixelsScaleY)
        let pixelWidth = Int(Double(axPointBoundingBox[2]) * pointsToPixelsScaleX)
        let pixelHeight = Int(Double(axPointBoundingBox[3]) * pointsToPixelsScaleY)

        return [pixelX, pixelY, pixelWidth, pixelHeight]
    }

    /// True when a point in AX-global coords falls inside the target
    /// screen's bounds. Use to filter cross-screen AX elements before
    /// scaling — emitting elements that live on a screen we aren't
    /// capturing causes the executor to click at the wrong place
    /// because it has no capture-geometry for that screen.
    static func axPointFallsWithinScreen(
        axPointX: Int,
        axPointY: Int,
        screenLocalOriginInAXPoints: CGPoint,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int
    ) -> Bool {
        let localX = Double(axPointX) - Double(screenLocalOriginInAXPoints.x)
        let localY = Double(axPointY) - Double(screenLocalOriginInAXPoints.y)
        return localX >= 0
            && localY >= 0
            && localX < Double(displayWidthInPoints)
            && localY < Double(displayHeightInPoints)
    }
}
