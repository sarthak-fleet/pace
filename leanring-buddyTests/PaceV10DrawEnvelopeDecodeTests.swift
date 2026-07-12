//
//  PaceV10DrawEnvelopeDecodeTests.swift
//  leanring-buddyTests
//
//  Regression: the EXACT v10 envelope captured live on 2026-07-12 (tool-call
//  trace, qwen3-30b via LM Studio with the enriched schema) must decode into
//  a drawAnnotation action. Live behavior was "no actions parsed".
//

import XCTest
@testable import Pace

final class PaceV10DrawEnvelopeDecodeTests: XCTestCase {
    func testLiveCapturedDrawEnvelopeDecodesToDrawAnnotationAction() {
        let liveCapturedEnvelope = #"{"spokenText": "drawing a red circle around the apple menu", "intent": "action", "payload": {"name": "Draw.annotation", "args": {"shapes": [{"kind": "ellipse", "x": 51, "y": 11, "width": 80, "height": 40, "color": "red", "label": "apple menu"}]}}}"#
        let parseResult = PaceActionTagParser.parseActions(from: liveCapturedEnvelope)
        XCTAssertEqual(parseResult.actions.count, 1, "expected exactly one decoded action, got: \(parseResult.actions)")
        guard case .drawAnnotation(let annotationRequest)? = parseResult.actions.first else {
            return XCTFail("expected drawAnnotation, got: \(String(describing: parseResult.actions.first))")
        }
        XCTAssertEqual(annotationRequest.shapes.count, 1)
    }

    func testLiveCapturedMultiStepCallsEnvelopeDecodes() {
        let callsEnvelope = #"{"spokenText": "opening safari and searching.", "intent": "action", "payload": {"calls": [{"name": "App.launch", "args": {"app": "Safari"}}, {"name": "Key.press", "args": {"key": "cmd+t"}}]}}"#
        let parseResult = PaceActionTagParser.parseActions(from: callsEnvelope)
        XCTAssertEqual(parseResult.actions.count, 2, "expected two decoded actions, got: \(parseResult.actions)")
    }
}
