//
//  PaceEpisodicFactExtractorTests.swift
//  leanring-buddyTests
//
//  Tests for the LLM-backed episodic-fact-extractor layer (protocol
//  + Apple FM + LM Studio implementations) plus the
//  `PaceEpisodicFactStore` dedup / tombstone / LRU policy and the
//  sensitive-topic injection filter.
//
//  The Apple FM conformer can't run in unit-test contexts (needs
//  Apple Intelligence enabled on the test host), so we exercise:
//    1. The pure prompt-assembly helpers — shared by both runtimes.
//    2. The LM Studio response-decoder static methods.
//    3. A FakeEpisodicFactExtractor that proves the integration
//       contract `CompanionManager.recordExtractedEpisodicFacts`
//       expects.
//    4. The store policy (dedup, tombstone, LRU cap) directly.
//    5. Sensitive-topic exclusion via `PaceEpisodicSensitiveTopics`.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceEpisodicFactExtractorTests {
    // MARK: - Prompt assembly

    @Test func renderedUserPromptIncludesTurnIdTranscriptAndAssistantReply() async throws {
        let renderedUserPrompt = PaceEpisodicFactExtractorPrompt.renderUserPrompt(
            userTranscript: "my mom is in the hospital with pneumonia",
            assistantSpokenText: "i hear you. that sounds hard.",
            frontmostAppName: "Safari",
            turnId: "turn-42"
        )
        #expect(renderedUserPrompt.contains("TURN_ID: turn-42"))
        #expect(renderedUserPrompt.contains("FRONTMOST_APP: Safari"))
        #expect(renderedUserPrompt.contains("USER_TRANSCRIPT:"))
        #expect(renderedUserPrompt.contains("my mom is in the hospital with pneumonia"))
        #expect(renderedUserPrompt.contains("ASSISTANT_REPLY:"))
        #expect(renderedUserPrompt.contains("i hear you"))
    }

    @Test func renderedUserPromptOmitsAssistantReplyAndFrontmostAppWhenEmpty() async throws {
        let renderedUserPrompt = PaceEpisodicFactExtractorPrompt.renderUserPrompt(
            userTranscript: "i prefer dark mode",
            assistantSpokenText: "",
            frontmostAppName: nil,
            turnId: "turn-7"
        )
        #expect(renderedUserPrompt.contains("USER_TRANSCRIPT:"))
        #expect(!renderedUserPrompt.contains("ASSISTANT_REPLY:"))
        #expect(!renderedUserPrompt.contains("FRONTMOST_APP:"))
    }

    // MARK: - LM Studio response decoder

    @Test func lmStudioDecoderParsesWellFormedFactsArray() async throws {
        let openAIShapedJSON = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "{\\"facts\\": [{\\"subject\\": \\"user\\", \\"predicate\\": \\"prefers\\", \\"value\\": \\"dark mode\\", \\"confidence\\": 0.92, \\"expiresAt\\": null, \\"topicHashtags\\": [\\"#preference\\"]}]}"
              }
            }
          ]
        }
        """
        let responseData = Data(openAIShapedJSON.utf8)
        let parsedFacts = PaceEpisodicLMStudioFactExtractor.parseFacts(
            fromOpenAIResponseData: responseData,
            sourceTurnId: "turn-1",
            extractedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(parsedFacts.count == 1)
        #expect(parsedFacts.first?.subject == "user")
        #expect(parsedFacts.first?.predicate == "prefers")
        #expect(parsedFacts.first?.value == "dark mode")
        #expect((parsedFacts.first?.confidence ?? 0) > 0.9)
        #expect(parsedFacts.first?.topicHashtags == ["#preference"])
    }

    @Test func lmStudioDecoderReturnsEmptyArrayForNonFactPayload() async throws {
        let emptyArrayJSON = "{\"facts\": []}"
        let parsedFacts = PaceEpisodicLMStudioFactExtractor.parseFacts(
            fromContentString: emptyArrayJSON,
            sourceTurnId: "turn-1",
            extractedAt: Date()
        )
        #expect(parsedFacts.isEmpty)
    }

    @Test func lmStudioDecoderTolerantOfStrayProseAroundJSON() async throws {
        let promptedResponse = """
        Sure — here are the durable facts:
        {"facts": [{"subject": "user", "predicate": "lives in", "value": "Dubai", "confidence": 0.88, "expiresAt": null, "topicHashtags": ["#preference"]}]}
        Hope that helps.
        """
        let parsedFacts = PaceEpisodicLMStudioFactExtractor.parseFacts(
            fromContentString: promptedResponse,
            sourceTurnId: "turn-2",
            extractedAt: Date()
        )
        #expect(parsedFacts.count == 1)
        #expect(parsedFacts.first?.value == "Dubai")
    }

    // MARK: - Fake extractor + recording integration

    /// Test-only conformer of `PaceEpisodicFactExtractor`. Lets us
    /// drive the same async API `CompanionManager` consumes without
    /// depending on FM or LM Studio.
    private final class FakeEpisodicFactExtractor: PaceEpisodicFactExtractor, @unchecked Sendable {
        var nextFactsToReturn: [PaceEpisodicFact] = []
        private(set) var capturedUserTranscript: String = ""
        private(set) var invocationCount: Int = 0

        func extract(
            userTranscript: String,
            assistantSpokenText: String,
            frontmostAppName: String?,
            turnId: String
        ) async -> [PaceEpisodicFact] {
            invocationCount += 1
            capturedUserTranscript = userTranscript
            return nextFactsToReturn
        }
    }

    private func makeFact(
        subject: String,
        predicate: String,
        value: String,
        confidence: Double,
        topicHashtags: [String] = ["#preference"],
        extractedAtSecondsSinceEpoch: TimeInterval = 1_700_000_000,
        identifierSuffix: String = "1"
    ) -> PaceEpisodicFact {
        PaceEpisodicFact(
            identifier: "episodic-test-\(subject)-\(predicate)-\(identifierSuffix)",
            extractedAt: Date(timeIntervalSince1970: extractedAtSecondsSinceEpoch),
            subject: subject,
            predicate: predicate,
            value: value,
            confidence: confidence,
            expiresAt: nil,
            topicHashtags: topicHashtags,
            sourceTurnId: "turn-test-\(identifierSuffix)"
        )
    }

    @Test func fakeExtractorReturnsCannedHealthFact() async throws {
        // Mirrors the PRD case: "my mom is in the hospital with
        // pneumonia" → one durable fact tagged #family + #health.
        let fakeExtractor = FakeEpisodicFactExtractor()
        fakeExtractor.nextFactsToReturn = [
            makeFact(
                subject: "user's mom",
                predicate: "is in",
                value: "the hospital",
                confidence: 0.85,
                topicHashtags: ["#family", "#health"]
            )
        ]
        let extractedFacts = await fakeExtractor.extract(
            userTranscript: "my mom is in the hospital with pneumonia",
            assistantSpokenText: "i hear you.",
            frontmostAppName: nil,
            turnId: "turn-test"
        )
        #expect(extractedFacts.count == 1)
        #expect(extractedFacts.first?.subject == "user's mom")
        #expect((extractedFacts.first?.confidence ?? 0) >= 0.7)
        #expect(fakeExtractor.invocationCount == 1)
        #expect(fakeExtractor.capturedUserTranscript == "my mom is in the hospital with pneumonia")
    }

    @Test func ephemeralPhrasesReturnEmptyArray() async throws {
        // The LLM extractor's behavior contract: ephemeral ("I'm
        // hungry") and action ("open Safari") turns return nothing.
        // We model that contract via the canned fake — the real FM
        // conformer is unreachable in unit tests.
        let fakeExtractor = FakeEpisodicFactExtractor()
        fakeExtractor.nextFactsToReturn = []

        let extractedFactsForHungry = await fakeExtractor.extract(
            userTranscript: "I'm hungry",
            assistantSpokenText: "",
            frontmostAppName: nil,
            turnId: "turn-test-a"
        )
        let extractedFactsForOpenSafari = await fakeExtractor.extract(
            userTranscript: "open Safari",
            assistantSpokenText: "",
            frontmostAppName: nil,
            turnId: "turn-test-b"
        )
        #expect(extractedFactsForHungry.isEmpty)
        #expect(extractedFactsForOpenSafari.isEmpty)
    }

    // MARK: - Dedup policy

    @Test func dedupReplacesWhenSameSubjectPredicateAndCloseConfidence() async throws {
        let initialFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            extractedAtSecondsSinceEpoch: 1_000,
            identifierSuffix: "a"
        )
        let refreshedFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode at night",
            confidence: 0.86,
            extractedAtSecondsSinceEpoch: 2_000,
            identifierSuffix: "b"
        )
        let outcome = PaceEpisodicFactDedupPolicy.decision(
            for: refreshedFact,
            existingFacts: [initialFact]
        )
        guard case .replaced(let previousFactId) = outcome else {
            Issue.record("expected .replaced, got \(outcome)")
            return
        }
        #expect(previousFactId == initialFact.identifier)
    }

    @Test func dedupAppendsWhenConfidenceGapIsLarge() async throws {
        let initialFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            extractedAtSecondsSinceEpoch: 1_000,
            identifierSuffix: "a"
        )
        let differentBeliefFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "light mode after dinner",
            confidence: 0.71,
            extractedAtSecondsSinceEpoch: 2_000,
            identifierSuffix: "b"
        )
        let outcome = PaceEpisodicFactDedupPolicy.decision(
            for: differentBeliefFact,
            existingFacts: [initialFact]
        )
        #expect(outcome == .appended)
    }

    @Test func dedupInsertsForNewSubjectPredicateRow() async throws {
        let priorFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            extractedAtSecondsSinceEpoch: 1_000,
            identifierSuffix: "a"
        )
        let newPredicateFact = makeFact(
            subject: "user",
            predicate: "lives in",
            value: "Dubai",
            confidence: 0.85,
            extractedAtSecondsSinceEpoch: 2_000,
            identifierSuffix: "b"
        )
        let outcome = PaceEpisodicFactDedupPolicy.decision(
            for: newPredicateFact,
            existingFacts: [priorFact]
        )
        #expect(outcome == .inserted)
    }

    // MARK: - Tombstones

    @Test func tombstoneBlocksReinsertionWithin30Days() async throws {
        // Build a store anchored to a known clock so we can step it
        // by ~29 days and confirm the tombstone still blocks.
        let clockBox = TestClockBox(initialTime: Date(timeIntervalSince1970: 1_700_000_000))
        let store = PaceEpisodicFactStore(now: { clockBox.currentTime })
        let originalFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            extractedAtSecondsSinceEpoch: 1_700_000_000,
            identifierSuffix: "a"
        )
        _ = store.apply(originalFact)
        _ = store.deleteFact(withIdentifier: originalFact.identifier)

        // Step the clock forward 29 days — tombstone still active.
        clockBox.currentTime = clockBox.currentTime.addingTimeInterval(29 * 24 * 60 * 60)
        let reExtractedFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            extractedAtSecondsSinceEpoch: clockBox.currentTime.timeIntervalSince1970,
            identifierSuffix: "b"
        )
        let outcomeBeforeExpiry = store.apply(reExtractedFact)
        #expect(outcomeBeforeExpiry == .skippedBecauseOfTombstone)
        #expect(store.allFacts.isEmpty)
    }

    @Test func tombstoneAllowsReinsertionAfter30Days() async throws {
        let clockBox = TestClockBox(initialTime: Date(timeIntervalSince1970: 1_700_000_000))
        let store = PaceEpisodicFactStore(now: { clockBox.currentTime })
        let originalFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            extractedAtSecondsSinceEpoch: 1_700_000_000,
            identifierSuffix: "a"
        )
        _ = store.apply(originalFact)
        _ = store.deleteFact(withIdentifier: originalFact.identifier)

        // Step clock forward 31 days — tombstone expired.
        clockBox.currentTime = clockBox.currentTime.addingTimeInterval(31 * 24 * 60 * 60)
        let reExtractedFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            extractedAtSecondsSinceEpoch: clockBox.currentTime.timeIntervalSince1970,
            identifierSuffix: "b"
        )
        let outcomeAfterExpiry = store.apply(reExtractedFact)
        #expect(outcomeAfterExpiry == .inserted)
        #expect(store.allFacts.count == 1)
    }

    // MARK: - LRU cap

    @Test func storeEvictsOldestFactsBeyond200() async throws {
        let store = PaceEpisodicFactStore()
        // Insert 205 facts with monotonically-increasing extracted-at
        // timestamps so eviction picks the oldest by extractedAt.
        for index in 0..<205 {
            let extractedAtSeconds = TimeInterval(1_700_000_000 + index)
            _ = store.apply(makeFact(
                subject: "subject-\(index)",
                predicate: "predicate-\(index)",
                value: "value-\(index)",
                confidence: 0.8,
                extractedAtSecondsSinceEpoch: extractedAtSeconds,
                identifierSuffix: "\(index)"
            ))
        }
        let allRemainingFacts = store.allFacts
        #expect(allRemainingFacts.count == PaceEpisodicMemoryLimits.maximumStoredFactCount)
        // The five oldest by extractedAt should have been evicted.
        let remainingSubjects = Set(allRemainingFacts.map(\.subject))
        for evictedIndex in 0..<5 {
            #expect(!remainingSubjects.contains("subject-\(evictedIndex)"))
        }
        #expect(remainingSubjects.contains("subject-204"))
    }

    // MARK: - Sensitive topic policy

    @Test func sensitiveTopicHashtagsAreRecognized() async throws {
        let healthFact = makeFact(
            subject: "user's mom",
            predicate: "is in",
            value: "the hospital",
            confidence: 0.85,
            topicHashtags: ["#family", "#health"]
        )
        let preferenceFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            topicHashtags: ["#preference"]
        )
        #expect(PaceEpisodicSensitiveTopics.isFactSensitive(healthFact))
        #expect(!PaceEpisodicSensitiveTopics.isFactSensitive(preferenceFact))
    }

    @Test func sensitiveFactRetrievalDocumentCarriesDistinctScope() async throws {
        let healthFact = makeFact(
            subject: "user's mom",
            predicate: "is in",
            value: "the hospital",
            confidence: 0.85,
            topicHashtags: ["#family", "#health"]
        )
        let preferenceFact = makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            topicHashtags: ["#preference"]
        )
        let sensitiveDoc = PaceEpisodicPatternFactExtractor.retrievalDocument(for: healthFact)
        let nonSensitiveDoc = PaceEpisodicPatternFactExtractor.retrievalDocument(for: preferenceFact)
        #expect(sensitiveDoc.permissionScope == PaceEpisodicSensitiveTopics.sensitivePermissionScope)
        #expect(nonSensitiveDoc.permissionScope == PaceEpisodicSensitiveTopics.standardPermissionScope)
    }

    @Test func storeReturnsOnlyNonSensitiveFactsForInjectionByDefault() async throws {
        let store = PaceEpisodicFactStore()
        _ = store.apply(makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            topicHashtags: ["#preference"],
            extractedAtSecondsSinceEpoch: 1_000,
            identifierSuffix: "pref"
        ))
        _ = store.apply(makeFact(
            subject: "user's mom",
            predicate: "is in",
            value: "the hospital",
            confidence: 0.85,
            topicHashtags: ["#family", "#health"],
            extractedAtSecondsSinceEpoch: 2_000,
            identifierSuffix: "health"
        ))
        let factsForDefaultInjection = store.factsForInjection(includeSensitiveTopics: false)
        let factsForOptIn = store.factsForInjection(includeSensitiveTopics: true)
        #expect(factsForDefaultInjection.count == 1)
        #expect(factsForDefaultInjection.first?.subject == "user")
        #expect(factsForOptIn.count == 2)
    }

    // MARK: - Reset behavior

    @Test func resetAllTombstonesEveryCurrentFact() async throws {
        let store = PaceEpisodicFactStore()
        _ = store.apply(makeFact(
            subject: "user",
            predicate: "prefers",
            value: "dark mode",
            confidence: 0.85,
            identifierSuffix: "a"
        ))
        _ = store.apply(makeFact(
            subject: "user",
            predicate: "lives in",
            value: "Dubai",
            confidence: 0.85,
            identifierSuffix: "b"
        ))
        store.resetAll()
        #expect(store.allFacts.isEmpty)
        #expect(store.allTombstones.count == 2)
    }
}

// MARK: - Helpers

/// Tiny mutable clock for tests that need to advance time (tombstone
/// expiry). Kept reference-typed so closures over `currentTime` see
/// updates.
private final class TestClockBox: @unchecked Sendable {
    var currentTime: Date

    init(initialTime: Date) {
        self.currentTime = initialTime
    }
}
