//
//  PaceThreadSummarizerTests.swift
//  leanring-buddyTests
//
//  Tests for the rolling-summary FM-call layer. The Apple Foundation
//  Models conformer can't run in unit-test contexts (the framework
//  needs Apple Intelligence to be enabled on the test host), so we
//  exercise:
//    1. The pure prompt-assembly helpers — same shape as the LM
//       Studio fallback uses.
//    2. The OpenAI-response decoder in the LM Studio fallback path.
//    3. A fake `PaceThreadSummarizerClient` proves the integration
//       contract `PaceThreadMemory` expects.
//

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceThreadSummarizerTests {
    // MARK: - Helpers

    private func makeTurnPair(
        userText: String = "i'm debugging an actor isolation warning",
        assistantText: String = "let's look at the closure capture",
        recordedAtSecondsSinceEpoch: TimeInterval = 1_000
    ) -> PaceThreadTurnPair {
        PaceThreadTurnPair(
            turnId: "turn-test",
            userText: userText,
            assistantText: assistantText,
            recordedAt: Date(timeIntervalSince1970: recordedAtSecondsSinceEpoch)
        )
    }

    // MARK: - Prompt assembly

    @Test func renderedUserPromptIncludesPriorSummaryAndNewTurn() async throws {
        let summarizerInput = PaceThreadSummarizerInput(
            priorSummary: "user is investigating a swift 6 warning",
            displacedTurnPair: makeTurnPair(),
            sessionStartedAt: Date(timeIntervalSince1970: 900),
            frontmostApplicationName: "Xcode"
        )
        let renderedUserPrompt = PaceThreadSummarizerPrompt.renderUserPrompt(for: summarizerInput)
        #expect(renderedUserPrompt.contains("PRIOR_SUMMARY:"))
        #expect(renderedUserPrompt.contains("user is investigating a swift 6 warning"))
        #expect(renderedUserPrompt.contains("NEW_TURN:"))
        #expect(renderedUserPrompt.contains("i'm debugging an actor isolation warning"))
        #expect(renderedUserPrompt.contains("CONTEXT:"))
        #expect(renderedUserPrompt.contains("Xcode"))
    }

    @Test func renderedUserPromptMarksEmptyPriorSummaryExplicitly() async throws {
        let summarizerInput = PaceThreadSummarizerInput(
            priorSummary: nil,
            displacedTurnPair: makeTurnPair(),
            sessionStartedAt: Date(timeIntervalSince1970: 900),
            frontmostApplicationName: nil
        )
        let renderedUserPrompt = PaceThreadSummarizerPrompt.renderUserPrompt(for: summarizerInput)
        #expect(renderedUserPrompt.contains("(empty — first compaction)"))
        // CONTEXT block is omitted when no frontmost app is provided.
        #expect(!renderedUserPrompt.contains("CONTEXT:"))
    }

    // MARK: - LM Studio fallback decoder

    @Test func openAIResponseDecoderExtractsContentField() async throws {
        let openAIShapedJSONString = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "user is debugging an isolation warning and considering closure ownership."
              }
            }
          ]
        }
        """
        let responseData = Data(openAIShapedJSONString.utf8)
        let extractedText = try PaceThreadLMStudioSummarizer
            .extractSummaryText(fromOpenAIResponseData: responseData)
        #expect(extractedText == "user is debugging an isolation warning and considering closure ownership.")
    }

    @Test func openAIResponseDecoderThrowsOnMalformedJSON() async throws {
        let malformedJSONString = "{ \"unexpected\": true }"
        let responseData = Data(malformedJSONString.utf8)
        do {
            _ = try PaceThreadLMStudioSummarizer
                .extractSummaryText(fromOpenAIResponseData: responseData)
            Issue.record("expected PaceThreadSummarizerError.malformedResponseJSON")
        } catch let error as PaceThreadSummarizerError {
            #expect(error == .malformedResponseJSON)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Fake client contract

    /// Drives the same async API `PaceThreadMemory` consumes, so the
    /// race-spec contract is testable without depending on FM.
    private final class FakeThreadSummarizer: PaceThreadSummarizerClient, @unchecked Sendable {
        var nextResultTextToReturn: String = "fake summary"
        var nextErrorToThrow: Error? = nil
        private(set) var invocationCount: Int = 0
        private(set) var capturedPriorSummary: String? = nil
        private(set) var capturedDisplacedUserText: String? = nil

        func updatedSummary(
            for input: PaceThreadSummarizerInput
        ) async throws -> String {
            invocationCount += 1
            capturedPriorSummary = input.priorSummary
            capturedDisplacedUserText = input.displacedTurnPair.userText
            if let nextErrorToThrow {
                throw nextErrorToThrow
            }
            return nextResultTextToReturn
        }
    }

    @Test func fakeClientReceivesPriorSummaryAndDisplacedPair() async throws {
        let fakeSummarizer = FakeThreadSummarizer()
        fakeSummarizer.nextResultTextToReturn = "compressed paragraph"
        let summarizerInput = PaceThreadSummarizerInput(
            priorSummary: "older facts",
            displacedTurnPair: makeTurnPair(userText: "i'm shipping on friday"),
            sessionStartedAt: Date(),
            frontmostApplicationName: nil
        )
        let summaryText = try await fakeSummarizer.updatedSummary(for: summarizerInput)
        #expect(summaryText == "compressed paragraph")
        #expect(fakeSummarizer.invocationCount == 1)
        #expect(fakeSummarizer.capturedPriorSummary == "older facts")
        #expect(fakeSummarizer.capturedDisplacedUserText == "i'm shipping on friday")
    }

    @Test func fakeClientErrorPropagatesToCaller() async throws {
        let fakeSummarizer = FakeThreadSummarizer()
        fakeSummarizer.nextErrorToThrow = PaceThreadSummarizerError.upstreamHTTPFailure
        let summarizerInput = PaceThreadSummarizerInput(
            priorSummary: nil,
            displacedTurnPair: makeTurnPair(),
            sessionStartedAt: Date(),
            frontmostApplicationName: nil
        )
        do {
            _ = try await fakeSummarizer.updatedSummary(for: summarizerInput)
            Issue.record("expected upstreamHTTPFailure")
        } catch let error as PaceThreadSummarizerError {
            #expect(error == .upstreamHTTPFailure)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
