//
//  PaceResponseQualityHeuristicsTests.swift
//  leanring-buddyTests
//
//  Tests for the heuristic response quality checker. Verifies that
//  obvious failure modes (hedging, repetition, too-short, echo) are
//  caught and that good responses pass through.
//

import Foundation
import Testing
@testable import Pace

struct PaceResponseQualityHeuristicsTests {

    // MARK: - Adequate responses

    @Test
    func goodKnowledgeResponse_passes() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "what is HTML",
            response: "HTML stands for HyperText Markup Language. It's the standard markup language for creating web pages. You use it to structure content on the web with elements like headings, paragraphs, and links."
        )
        #expect(verdict == .adequate)
    }

    @Test
    func goodDetailedResponse_passes() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "explain how DNS works",
            response: "DNS, or Domain Name System, translates human-readable domain names into IP addresses. When you type a URL, your computer queries a DNS resolver, which works through a hierarchy of servers: root, TLD, and authoritative. The process involves recursive and iterative queries until the final IP address is returned."
        )
        #expect(verdict == .adequate)
    }

    @Test
    func shortChitchatResponse_passes() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "hi pace",
            response: "Hey! What can I help you with?"
        )
        #expect(verdict == .adequate)
    }

    @Test
    func shortDefinitionResponse_passes() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "what is CSS",
            response: "CSS is a stylesheet language used for describing the presentation of a document written in HTML."
        )
        #expect(verdict == .adequate)
    }

    // MARK: - Hedging / failure markers

    @Test
    func hedgingResponse_fails() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "explain quantum computing",
            response: "I'm not sure about quantum computing. It's a complex topic that I don't fully understand."
        )
        if case .inadequate(let reason) = verdict {
            #expect(reason.contains("failure marker"))
        } else {
            Issue.record("Expected inadequate, got \(verdict)")
        }
    }

    @Test
    func dontKnowResponse_fails() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "what's the capital of France",
            response: "I don't know the answer to that question."
        )
        if case .inadequate = verdict {
            // pass
        } else {
            Issue.record("Expected inadequate for 'I don't know' response")
        }
    }

    @Test
    func asAnAIResponse_fails() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "write a poem about rain",
            response: "As an AI language model, I can help you write a poem about rain. Let me think about this for you."
        )
        if case .inadequate = verdict {
            // pass
        } else {
            Issue.record("Expected inadequate for 'as an AI' response")
        }
    }

    // MARK: - Too short

    @Test
    func tooShortForKnowledgeQuery_fails() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "what is machine learning",
            response: "It's a field."
        )
        if case .inadequate(let reason) = verdict {
            #expect(reason.contains("too short"))
        } else {
            Issue.record("Expected inadequate for too-short response")
        }
    }

    // MARK: - Repetition

    @Test
    func repetitiveResponse_fails() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "explain recursion",
            response: "Recursion is when a function calls itself. Recursion is when a function calls itself. Recursion is when a function calls itself. Recursion is when a function calls itself. That's basically it."
        )
        if case .inadequate(let reason) = verdict {
            #expect(reason.contains("repetitive"))
        } else {
            Issue.record("Expected inadequate for repetitive response")
        }
    }

    // MARK: - Echo

    @Test
    func echoResponse_fails() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "what is javascript",
            response: "what is javascript what is javascript what is javascript"
        )
        if case .inadequate(let reason) = verdict {
            #expect(reason.contains("echo"))
        } else {
            Issue.record("Expected inadequate for echo response")
        }
    }

    // MARK: - Edge cases

    @Test
    func emptyResponse_fails() {
        let verdict = PaceResponseQualityHeuristics.check(
            query: "what is python",
            response: ""
        )
        if case .inadequate = verdict {
            // pass — too short
        } else {
            Issue.record("Expected inadequate for empty response")
        }
    }

    @Test
    func goodResponseWithSomeQueryWords_passes() {
        // A good response naturally contains some words from the query
        let verdict = PaceResponseQualityHeuristics.check(
            query: "what is REST API",
            response: "REST stands for Representational State Transfer. It's an architectural style for designing APIs. A REST API uses HTTP methods like GET, POST, PUT, and DELETE to operate on resources identified by URLs."
        )
        #expect(verdict == .adequate)
    }
}

// MARK: - Conversation complexity tracker tests

struct PaceConversationComplexityTrackerTests {

    // MARK: - No history

    @Test
    func noHistory_doesNotEscalate() {
        let result = PaceConversationComplexityTracker.shouldEscalateBasedOnContext(
            transcript: "what about edge cases",
            conversationHistory: []
        )
        #expect(result == false)
    }

    // MARK: - Shallow conversation

    @Test
    func fewTurnsSameTopic_doesNotEscalate() {
        let history: [(String, String)] = [
            ("tell me about react", "React is a JavaScript library..."),
            ("how does state work", "State in React is managed through..."),
        ]
        let result = PaceConversationComplexityTracker.shouldEscalateBasedOnContext(
            transcript: "what about hooks",
            conversationHistory: history.map { (userTranscript: $0.0, assistantResponse: $0.1) }
        )
        #expect(result == false)
    }

    // MARK: - Deep conversation (total turn count)

    @Test
    func manyTurns_escalates() {
        let history: [(String, String)] = (0..<8).map { i in
            ("question about topic \(i)", "answer about topic \(i)")
        }
        let result = PaceConversationComplexityTracker.shouldEscalateBasedOnContext(
            transcript: "so what about edge cases",
            conversationHistory: history.map { (userTranscript: $0.0, assistantResponse: $0.1) }
        )
        #expect(result == true)
    }

    // MARK: - Same-topic streak

    @Test
    func sameTopicStreak_escalates() {
        let history: [(String, String)] = [
            ("tell me about kubernetes pods", "Kubernetes pods are..."),
            ("how do pods communicate", "Pods communicate via..."),
            ("what about pods scaling", "Pods scaling uses..."),
            ("how do pods handle networking", "Pods networking works by..."),
        ]
        let result = PaceConversationComplexityTracker.shouldEscalateBasedOnContext(
            transcript: "what about edge cases with pods",
            conversationHistory: history.map { (userTranscript: $0.0, assistantResponse: $0.1) }
        )
        #expect(result == true)
    }

    @Test
    func topicChange_doesNotEscalate() {
        let history: [(String, String)] = [
            ("tell me about kubernetes", "Kubernetes is..."),
            ("what's the weather like", "I can't check weather..."),
            ("tell me a joke", "Why did the chicken..."),
            ("open safari", "Opening Safari..."),
        ]
        let result = PaceConversationComplexityTracker.shouldEscalateBasedOnContext(
            transcript: "what about edge cases",
            conversationHistory: history.map { (userTranscript: $0.0, assistantResponse: $0.1) }
        )
        #expect(result == false)
    }

    // MARK: - Classifier integration

    @MainActor
    @Test
    func classifier_upgradesComplexityInDeepConversation() {
        let classifier = PaceIntentClassifier()
        let history: [(String, String)] = (0..<8).map { i in
            ("question about topic \(i)", "answer about topic \(i)")
        }
        // "so what about that" is simple by keyword/length but should
        // be upgraded to .complex in a deep conversation.
        let prediction = classifier.classify(
            "so what about that",
            conversationHistory: history.map { (userTranscript: $0.0, assistantResponse: $0.1) }
        )
        #expect(prediction.complexity == .complex)
    }

    @MainActor
    @Test
    func classifier_doesNotUpgradeInShallowConversation() {
        let classifier = PaceIntentClassifier()
        let prediction = classifier.classify(
            "so what about that",
            conversationHistory: []
        )
        #expect(prediction.complexity != .complex)
    }

    @MainActor
    @Test
    func classifier_neverDowngrades() {
        let classifier = PaceIntentClassifier()
        // "write an essay" is already .complex — conversation context
        // should never downgrade it, even with no history.
        let prediction = classifier.classify(
            "write an essay about history",
            conversationHistory: []
        )
        #expect(prediction.complexity == .complex)
    }
}
