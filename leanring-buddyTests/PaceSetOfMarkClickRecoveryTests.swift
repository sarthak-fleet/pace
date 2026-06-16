//
//  PaceSetOfMarkClickRecoveryTests.swift
//  leanring-buddyTests
//
//  Tests for the pure Set-of-Mark click-recovery coordinator. Rendering and the
//  VLM round-trip are injected, so these cover only the decision logic: build
//  marks, ground a mark, map it back to a bbox-center click point.
//

import Foundation
import Testing

@testable import Pace

struct PaceSetOfMarkClickRecoveryTests {

    private func element(_ bbox: [Int], label: String = "e") -> LocalVLMScreenElement {
        LocalVLMScreenElement(label: label, role: "button", bbox: bbox, text: nil)
    }

    private func inputs(_ elements: [LocalVLMScreenElement], screen: Int? = 1) -> PaceSetOfMarkClickRecovery.Inputs {
        PaceSetOfMarkClickRecovery.Inputs(
            screenshotImageData: Data([0xFF, 0xD8]),
            elements: elements,
            targetDescription: "Send button",
            screenNumber: screen
        )
    }

    private let renderSucceeds: (Data, [PaceSetOfMarkBox]) -> Data? = { _, _ in Data([0x1]) }
    private let renderFails: (Data, [PaceSetOfMarkBox]) -> Data? = { _, _ in nil }

    @Test func inRangeMarkResolvesToBboxCenter() async {
        let elements = [element([0, 0, 10, 10]), element([10, 20, 40, 60])]
        let resolved = await PaceSetOfMarkClickRecovery.resolve(
            inputs: inputs(elements, screen: 2),
            renderMarks: renderSucceeds,
            groundMark: { _, _, _ in 1 }
        )
        #expect(resolved?.xInScreenshotPixels == 30) // 10 + 40/2
        #expect(resolved?.yInScreenshotPixels == 50) // 20 + 60/2
        #expect(resolved?.screenNumber == 2)
    }

    @Test func outOfRangeMarkReturnsNil() async {
        let elements = [element([0, 0, 10, 10])]
        let resolved = await PaceSetOfMarkClickRecovery.resolve(
            inputs: inputs(elements),
            renderMarks: renderSucceeds,
            groundMark: { _, _, _ in 5 }
        )
        #expect(resolved == nil)
    }

    @Test func negativeMarkReturnsNil() async {
        let elements = [element([0, 0, 10, 10])]
        let resolved = await PaceSetOfMarkClickRecovery.resolve(
            inputs: inputs(elements),
            renderMarks: renderSucceeds,
            groundMark: { _, _, _ in -1 }
        )
        #expect(resolved == nil)
    }

    @Test func nilGroundReturnsNil() async {
        let elements = [element([0, 0, 10, 10])]
        let resolved = await PaceSetOfMarkClickRecovery.resolve(
            inputs: inputs(elements),
            renderMarks: renderSucceeds,
            groundMark: { _, _, _ in nil }
        )
        #expect(resolved == nil)
    }

    @Test func emptyElementsReturnsNil() async {
        let resolved = await PaceSetOfMarkClickRecovery.resolve(
            inputs: inputs([]),
            renderMarks: renderSucceeds,
            groundMark: { _, _, _ in 0 }
        )
        #expect(resolved == nil)
    }

    @Test func renderFailureReturnsNil() async {
        let elements = [element([0, 0, 10, 10])]
        let resolved = await PaceSetOfMarkClickRecovery.resolve(
            inputs: inputs(elements),
            renderMarks: renderFails,
            groundMark: { _, _, _ in 0 }
        )
        #expect(resolved == nil)
    }

    @Test func malformedBboxOnChosenElementReturnsNil() async {
        // index 0 has a good bbox (gets a mark); index 1 is malformed (no mark).
        // If the model nonetheless returns index 1, the final bbox guard rejects.
        let elements = [element([0, 0, 10, 10]), element([1, 2, 3])]
        let resolved = await PaceSetOfMarkClickRecovery.resolve(
            inputs: inputs(elements),
            renderMarks: renderSucceeds,
            groundMark: { _, _, _ in 1 }
        )
        #expect(resolved == nil)
    }

    @Test func allMalformedBboxesSkipRenderAndReturnNil() async {
        let elements = [element([1, 2]), element([3])]
        let resolved = await PaceSetOfMarkClickRecovery.resolve(
            inputs: inputs(elements),
            renderMarks: renderSucceeds,
            groundMark: { _, _, _ in 0 }
        )
        #expect(resolved == nil)
    }
}
