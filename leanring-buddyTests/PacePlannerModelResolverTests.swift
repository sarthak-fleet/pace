//
//  PacePlannerModelResolverTests.swift
//  leanring-buddyTests
//
//  Pure-logic tests for the model picker. The HTTP path goes against
//  a real LM Studio at runtime — not exercised here. What we DO want
//  to lock down: the heuristics that decide "is this a chat model?"
//  and "which of these is smallest?". If the regex extraction or
//  filter misfires, the user lands on a VLM or embedding model and
//  every voice turn breaks.
//

import Testing
@testable import Pace

struct PacePlannerModelResolverTests {

    // MARK: - isLikelyChatModel

    @Test func qwenChatModelsAreLikelyChat() async throws {
        #expect(PacePlannerModelResolver.isLikelyChatModel("qwen/qwen3-14b"))
        #expect(PacePlannerModelResolver.isLikelyChatModel("qwen3-1.7b"))
        #expect(PacePlannerModelResolver.isLikelyChatModel("qwen/qwen3-30b-a3b"))
    }

    @Test func gemmaAndPhiChatModelsAreLikelyChat() async throws {
        #expect(PacePlannerModelResolver.isLikelyChatModel("google/gemma-3-12b"))
        #expect(PacePlannerModelResolver.isLikelyChatModel("microsoft/phi-4-mini-reasoning"))
    }

    @Test func visionLanguageModelsAreNotChat() async throws {
        #expect(!PacePlannerModelResolver.isLikelyChatModel("ui-venus-1.5-2b"))
        #expect(!PacePlannerModelResolver.isLikelyChatModel("ui-venus-1.5-8b"))
        #expect(!PacePlannerModelResolver.isLikelyChatModel("qwen3-vl-8b-instruct"))
        #expect(!PacePlannerModelResolver.isLikelyChatModel("moondream2"))
        #expect(!PacePlannerModelResolver.isLikelyChatModel("llava-v1.6"))
    }

    @Test func embeddingModelsAreNotChat() async throws {
        #expect(!PacePlannerModelResolver.isLikelyChatModel("text-embedding-nomic-embed-text-v1.5"))
        #expect(!PacePlannerModelResolver.isLikelyChatModel("bge-large-en-v1.5-embedding"))
    }

    // MARK: - approximateParameterBillions

    @Test func extractsBillionsFromCommonNamePatterns() async throws {
        let casesInBillions: [(String, Double)] = [
            ("qwen3-0.6b-instruct", 0.6),
            ("qwen3-1.7b", 1.7),
            ("qwen3-4b-instruct", 4),
            ("qwen/qwen3-14b", 14),
            ("google/gemma-3-12b", 12),
            ("qwen/qwen3-30b-a3b", 30)
        ]
        for (modelIdentifier, expectedBillions) in casesInBillions {
            let resolvedBillions = PacePlannerModelResolver.approximateParameterBillions(from: modelIdentifier)
            #expect(
                resolvedBillions == expectedBillions,
                "Expected \(modelIdentifier) to extract \(expectedBillions)B, got \(resolvedBillions)"
            )
        }
    }

    @Test func extractsMillionsFromCommonNamePatterns() async throws {
        let resolvedBillionsForSmoll = PacePlannerModelResolver.approximateParameterBillions(from: "smollm-360m")
        #expect(resolvedBillionsForSmoll == 0.36)
    }

    @Test func unknownSizeSortsLast() async throws {
        let resolvedBillions = PacePlannerModelResolver.approximateParameterBillions(from: "mystery-model-no-size")
        #expect(resolvedBillions == Double.greatestFiniteMagnitude)
    }

    // MARK: - pickSmallestChatModel

    @Test func picksSmallestQwenWhenMultiplePresent() async throws {
        let availableIdentifiers = [
            "qwen/qwen3-30b-a3b",
            "ui-venus-1.5-2b",
            "qwen/qwen3-14b",
            "qwen3-1.7b",
            "text-embedding-nomic-embed-text-v1.5"
        ]
        let picked = PacePlannerModelResolver.pickSmallestChatModel(from: availableIdentifiers)
        #expect(picked == "qwen3-1.7b")
    }

    @Test func returnsNilWhenOnlyVLMsAndEmbeddingsLoaded() async throws {
        let availableIdentifiers = [
            "ui-venus-1.5-2b",
            "ui-venus-1.5-8b",
            "text-embedding-nomic-embed-text-v1.5"
        ]
        let picked = PacePlannerModelResolver.pickSmallestChatModel(from: availableIdentifiers)
        #expect(picked == nil)
    }

    @Test func picksGemmaWhenItIsTheSmallest() async throws {
        let availableIdentifiers = [
            "qwen/qwen3-14b",
            "google/gemma-3-12b"
        ]
        let picked = PacePlannerModelResolver.pickSmallestChatModel(from: availableIdentifiers)
        #expect(picked == "google/gemma-3-12b")
    }
}
