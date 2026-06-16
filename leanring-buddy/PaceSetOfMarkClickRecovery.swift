//
//  PaceSetOfMarkClickRecovery.swift
//  leanring-buddy
//
//  Pure coordinator for Set-of-Mark click recovery: when a planner-chosen
//  click misses, draw numbered marks on the screenshot, ask the VLM which mark
//  is on the intended element, and turn the chosen mark back into a click point.
//  All I/O (rendering, the VLM round-trip) is injected so the decision logic is
//  unit-testable without AppKit or a live model.
//
//  See PRD docs/prds/set-of-mark-click-recovery.md.
//

import Foundation

nonisolated enum PaceSetOfMarkClickRecovery {

    /// Everything the recovery needs about the failed click, gathered by the
    /// agent loop from the same screenshot + element map used for the click.
    struct Inputs {
        /// The exact screenshot the failed click targeted (marks are drawn on this).
        let screenshotImageData: Data
        /// The element map for that screenshot. Mark numbers are array indices.
        let elements: [LocalVLMScreenElement]
        /// What the planner tried to click — the VLM grounding instruction.
        let targetDescription: String
        /// 1-based screen index the click aimed at (nil = cursor screen).
        let screenNumber: Int?
    }

    /// Resolve the failed click into a new click location, or nil when recovery
    /// can't help (no elements, render failure, no matching mark, bad index).
    ///
    /// - Parameters:
    ///   - renderMarks: draws numbered boxes onto the JPEG (the renderer).
    ///   - groundMark: asks the VLM for the mark number on the target element.
    static func resolve(
        inputs: Inputs,
        renderMarks: (Data, [PaceSetOfMarkBox]) -> Data?,
        groundMark: (Data, String, Int) async -> Int?
    ) async -> ScreenshotPixelLocation? {
        let elements = inputs.elements
        guard !elements.isEmpty else { return nil }

        // Mark numbers ARE element array indices, so the VLM's answer maps back
        // with no off-by-one. Only elements with a well-formed bbox get a mark.
        let boxes: [PaceSetOfMarkBox] = elements.enumerated().compactMap { index, element in
            guard element.bbox.count == 4 else { return nil }
            return PaceSetOfMarkBox(index: index, bbox: element.bbox)
        }
        guard !boxes.isEmpty,
              let markedImageData = renderMarks(inputs.screenshotImageData, boxes) else {
            return nil
        }

        guard let markIndex = await groundMark(markedImageData, inputs.targetDescription, elements.count),
              markIndex >= 0, markIndex < elements.count else {
            return nil
        }

        let bbox = elements[markIndex].bbox
        guard bbox.count == 4 else { return nil }
        return ScreenshotPixelLocation(
            xInScreenshotPixels: bbox[0] + bbox[2] / 2,
            yInScreenshotPixels: bbox[1] + bbox[3] / 2,
            screenNumber: inputs.screenNumber
        )
    }
}
