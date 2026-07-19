//
//  PaceQueryComplexityEstimatorTests.swift
//  leanring-buddyTests
//
//  Tests for the rule-based complexity estimator and its integration
//  with PaceIntentPrediction.route — verifies that complex queries
//  on local-answer intents escalate to the large model while simple
//  queries and screen actions stay local.
//

import Foundation
import Testing
@testable import Pace

struct PaceQueryComplexityEstimatorTests {

    // MARK: - Simple queries

    @Test
    func shortFactualQuestion_isSimple() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "what is HTML") == .simple)
    }

    @Test
    func greeting_isSimple() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "hi pace") == .simple)
    }

    @Test
    func shortAction_isSimple() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "click the save button") == .simple)
    }

    @Test
    func shortScreenDescription_isSimple() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "what's on the screen") == .simple)
    }

    // MARK: - Complex via strong indicators

    @Test
    func essayRequest_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "write an essay about the French Revolution") == .complex)
    }

    @Test
    func writeReport_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "write a report on Q3 revenue") == .complex)
    }

    @Test
    func writeFunction_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "write a function that sorts a binary tree") == .complex)
    }

    @Test
    func inDetail_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "explain quantum computing in detail") == .complex)
    }

    @Test
    func compareAndContrast_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "compare and contrast REST and GraphQL") == .complex)
    }

    @Test
    func prosAndCons_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "what are the pros and cons of microservices") == .complex)
    }

    @Test
    func comprehensive_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "give me a comprehensive overview of Kubernetes") == .complex)
    }

    @Test
    func stepByStep_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "walk me through step by step how to set up CI") == .complex)
    }

    @Test
    func thousandWords_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "write 1000 words on climate change") == .complex)
    }

    @Test
    func createPlan_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "create a plan for the product launch") == .complex)
    }

    @Test
    func deepDive_isComplex() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "do a deep dive on the competitor landscape") == .complex)
    }

    // MARK: - Moderate indicators

    @Test
    func summarizeShort_isModerate() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "summarize this") == .moderate)
    }

    @Test
    func summarizeLong_isComplex() {
        let longQuery = "summarize the meeting notes from yesterday's standup where we discussed the roadmap priorities for Q4 and the hiring plan for the engineering team"
        #expect(PaceQueryComplexityEstimator.estimate(transcript: longQuery) == .complex)
    }

    @Test
    func analyzeShort_isModerate() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "analyze this data") == .moderate)
    }

    @Test
    func draftShort_isModerate() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "draft a response") == .moderate)
    }

    // MARK: - Length-based

    @Test
    func veryLongQuery_isComplex() {
        // 40+ words without any complexity keywords
        let longQuery = "so I was thinking about the project that we have been working on for the last few weeks and I wanted to get your thoughts on whether we should continue with the current approach or maybe pivot to something different given the constraints we are facing"
        #expect(PaceQueryComplexityEstimator.estimate(transcript: longQuery) == .complex)
    }

    @Test
    func mediumQuery_isModerate() {
        // 20-39 words without any complexity keywords
        let mediumQuery = "I was thinking about the project we have been working on and wanted to get your thoughts on whether we should continue"
        #expect(PaceQueryComplexityEstimator.estimate(transcript: mediumQuery) == .moderate)
    }

    // MARK: - Edge cases

    @Test
    func emptyQuery_isSimple() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "") == .simple)
    }

    @Test
    func singleWord_isSimple() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "hello") == .simple)
    }

    @Test
    func caseInsensitive() {
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "WRITE AN ESSAY about history") == .complex)
        #expect(PaceQueryComplexityEstimator.estimate(transcript: "Write A Report on sales") == .complex)
    }
}

// MARK: - Route integration tests

struct PaceIntentPredictionComplexityRoutingTests {

    @Test
    func simplePureKnowledge_routesToAnswerDirectly() {
        let prediction = PaceIntentPrediction(
            intent: .pureKnowledge,
            confidence: 0.95,
            complexity: .simple
        )
        #expect(prediction.route == .answerDirectly)
    }

    @Test
    func complexPureKnowledge_routesToEscalation() {
        let prediction = PaceIntentPrediction(
            intent: .pureKnowledge,
            confidence: 0.95,
            complexity: .complex
        )
        #expect(prediction.route == .escalateToLargeModel)
    }

    @Test
    func simpleChitchat_routesToFastPath() {
        let prediction = PaceIntentPrediction(
            intent: .chitchat,
            confidence: 0.95,
            complexity: .simple
        )
        #expect(prediction.route == .chitchatFastPath)
    }

    @Test
    func complexChitchat_routesToEscalation() {
        let prediction = PaceIntentPrediction(
            intent: .chitchat,
            confidence: 0.95,
            complexity: .complex
        )
        #expect(prediction.route == .escalateToLargeModel)
    }

    @Test
    func simpleScreenDescription_routesToReadScreen() {
        let prediction = PaceIntentPrediction(
            intent: .screenDescription,
            confidence: 0.95,
            complexity: .simple
        )
        #expect(prediction.route == .readScreen)
    }

    @Test
    func complexScreenDescription_routesToEscalation() {
        let prediction = PaceIntentPrediction(
            intent: .screenDescription,
            confidence: 0.95,
            complexity: .complex
        )
        #expect(prediction.route == .escalateToLargeModel)
    }

    @Test
    func complexScreenAction_staysLocal() {
        // screenAction is excluded from complexity escalation because
        // the action layer needs local model action-tag generation
        let prediction = PaceIntentPrediction(
            intent: .screenAction,
            confidence: 0.95,
            complexity: .complex
        )
        #expect(prediction.route == .executeTool)
    }

    @Test
    func lowConfidence_alwaysEscalates_regardlessOfComplexity() {
        let prediction = PaceIntentPrediction(
            intent: .pureKnowledge,
            confidence: 0.50,
            complexity: .simple
        )
        #expect(prediction.route == .escalateToLargeModel)
    }

    @Test
    func lowConfidenceAndComplex_escalatesOnce() {
        // Both gates trigger but route should be a single .escalateToLargeModel
        let prediction = PaceIntentPrediction(
            intent: .pureKnowledge,
            confidence: 0.50,
            complexity: .complex
        )
        #expect(prediction.route == .escalateToLargeModel)
    }

    @Test
    func researchIntent_ignoresComplexity() {
        let prediction = PaceIntentPrediction(
            intent: .research,
            confidence: 0.95,
            complexity: .complex
        )
        #expect(prediction.route == .research)
    }

    @Test
    func phoneLargeModel_ignoresComplexity() {
        let prediction = PaceIntentPrediction(
            intent: .phoneLargeModel,
            confidence: 0.95,
            complexity: .complex
        )
        #expect(prediction.route == .phoneLargeModel)
    }

    @Test
    func unknownIntent_ignoresComplexity() {
        let prediction = PaceIntentPrediction(
            intent: .unknown,
            confidence: 0.95,
            complexity: .complex
        )
        #expect(prediction.route == .fullPipeline)
    }

    @Test
    func moderateComplexity_doesNotEscalate() {
        let prediction = PaceIntentPrediction(
            intent: .pureKnowledge,
            confidence: 0.95,
            complexity: .moderate
        )
        #expect(prediction.route == .answerDirectly)
    }
}
