//
//  LocalVLMScreenAnalysisDecoderTests.swift
//  leanring-buddyTests
//
//  Pace's Local VLM (ui-venus-1.5-2b) is documented as returning STRICT
//  JSON with both `elements` and `description` fields. In practice the
//  2B model occasionally drops the `description` field on dense screens
//  like Xcode, returning just `{"elements":[…]}`. Before, that hard-
//  failed the whole turn's screen analysis. We now decode the missing
//  description as an empty string so the element list (which is usually
//  fine on its own) still flows through to the planner.
//
//  These tests pin that behaviour down so a future "tighten the
//  decoder" PR doesn't silently regress the Xcode-screen case.
//

import Testing
import Foundation
@testable import Pace

struct LocalVLMScreenAnalysisDecoderTests {

    @Test func wellFormedJSONStillDecodes() throws {
        let wellFormedJSON = """
        {
          "elements": [
            {"label": "search", "role": "button", "bbox": [10, 20, 100, 30], "text": "Search"}
          ],
          "description": "a search bar at the top of the screen"
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: wellFormedJSON)

        #expect(analysis.elements.count == 1)
        #expect(analysis.elements.first?.label == "search")
        #expect(analysis.description == "a search bar at the top of the screen")
    }

    @Test func missingDescriptionDecodesAsEmptyString() throws {
        // Exact shape ui-venus-1.5-2b returns on dense Xcode screens.
        // Reproduced from user's PTT log on 2026-05-29.
        let elementsOnlyJSON = """
        {
          "elements": [
            {"label": "Xcode application window", "role": "window", "bbox": [107, 39, 865, 942]}
          ]
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: elementsOnlyJSON)

        #expect(analysis.elements.count == 1)
        #expect(analysis.description == "", "missing description must decode as empty, not throw")
    }

    @Test func nullDescriptionDecodesAsEmptyString() throws {
        let nullDescriptionJSON = """
        {
          "elements": [],
          "description": null
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: nullDescriptionJSON)

        #expect(analysis.description == "")
    }

    @Test func missingElementsStillThrows() throws {
        // Elements are load-bearing — without them the analysis is
        // genuinely useless and the caller should fall back to OCR-only.
        // Only `description` is soft-optional.
        let noElementsJSON = """
        {
          "description": "just a description, no elements at all"
        }
        """.data(using: .utf8)!

        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(LocalVLMScreenAnalysis.self, from: noElementsJSON)
        }
    }
}
