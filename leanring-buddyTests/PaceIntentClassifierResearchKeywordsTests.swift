//
//  PaceIntentClassifierResearchKeywordsTests.swift
//  leanring-buddyTests
//
//  Pins the `.research` intent route — both positive keyword hits
//  (so saying "research X" / "compare A vs B" reliably escalates)
//  and the false-positive guard (so past-tense "I researched HTML"
//  does NOT trip the heavyweight planner).
//

import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceIntentClassifierResearchKeywordsTests {

    @Test func researchKeywordsRouteToResearchIntent() async throws {
        let classifier = PaceIntentClassifier()
        let researchTranscripts = [
            "research the difference between MCP and ACP",
            "do research on the new Claude Opus pricing",
            "look into the latest Tailwind v4 changes for me",
            "dig into how SwiftUI handles MainActor isolation",
            "investigate the cause of this build failure",
            "compare Anthropic Opus vs OpenAI GPT-5",
            "find sources on the Apple Foundation Models release",
            "give me a writeup on the M5 Pro launch",
            "what's the latest on the EU AI Act",
            "deep research the history of MCP",
        ]
        for transcript in researchTranscripts {
            let prediction = await classifier.classify(transcript)
            #expect(
                prediction.intent == .research,
                "expected \(transcript) to route to .research, got \(prediction.intent.rawValue)"
            )
        }
    }

    @Test func pastTenseResearchDoesNotTrip() async throws {
        let classifier = PaceIntentClassifier()
        // "researched" doesn't match because the keyword list uses
        // trailing-space anchors ("research ") to avoid matching
        // suffixed forms.
        let nonResearchTranscript = "I researched HTML yesterday."
        let prediction = await classifier.classify(nonResearchTranscript)
        #expect(prediction.intent != .research)
    }

    @Test func researchRouteEnumValueIsStable() async throws {
        // Stable rawValue so on-disk preferences referencing the route
        // string (none today, but a future hook might) don't silently
        // break.
        #expect(PaceIntentRoute.research.rawValue == "research")
    }
}
