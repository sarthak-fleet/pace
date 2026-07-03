//
//  PaceMeetingNotesBuilderTests.swift
//  leanring-buddyTests
//
//  Tests for the meeting-notes builder. Uses a mock planner client
//  that returns canned JSON so we can pin the builder's parsing +
//  failure behavior without spinning up LM Studio or Apple FM.
//
//  Coverage:
//    - well-formed planner JSON → populated notes
//    - malformed JSON → synthesisFailed: true with transcript preserved
//    - planner-throws → synthesisFailed: true with transcript preserved
//    - empty transcript → empty notes (no planner call)
//    - markdown-fenced JSON → still parsed correctly
//    - missing actionItems field → empty array (not a crash)
//    - unknown extra fields → ignored
//

import Foundation
import Testing

@testable import Pace

// MARK: - Mock planner client

/// A mock `BuddyPlannerClient` that returns a fixed canned response or
/// throws, and records whether it was called so tests can assert the
/// empty-transcript short-circuit.
@MainActor
final class MockMeetingNotesPlannerClient: BuddyPlannerClient {
    let displayName: String = "Mock meeting-notes planner"
    let supportsImageInput: Bool = false

    private let cannedResponse: String?
    private let shouldThrow: Bool
    private(set) var callCount: Int = 0

    init(cannedResponse: String?, shouldThrow: Bool = false) {
        self.cannedResponse = cannedResponse
        self.shouldThrow = shouldThrow
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        callCount += 1
        if shouldThrow {
            throw MockPlannerError.intentionalFailure
        }
        let response = cannedResponse ?? ""
        return (text: response, duration: 0)
    }
}

private enum MockPlannerError: LocalizedError {
    case intentionalFailure

    var errorDescription: String? {
        "Mock planner intentional failure"
    }
}

// MARK: - Tests

@MainActor
struct PaceMeetingNotesBuilderTests {
    private let meetingID: UUID = UUID()
    private let startedAt: Date = Date()
    private let endedAt: Date = Date().addingTimeInterval(600)

    private func makeTurns() -> [PaceMeetingTurnRecord] {
        [
            PaceMeetingTurnRecord(
                start: startedAt,
                end: startedAt.addingTimeInterval(5),
                speaker: "you",
                text: "Let's ship the feature by Friday."
            ),
            PaceMeetingTurnRecord(
                start: startedAt.addingTimeInterval(6),
                end: startedAt.addingTimeInterval(12),
                speaker: "them",
                text: "Agreed. I'll review the PR tomorrow."
            )
        ]
    }

    private let sampleTranscript: String = """
    you: Let's ship the feature by Friday.
    them: Agreed. I'll review the PR tomorrow.
    you: We decided to use the new API design.
    """

    @Test func wellFormedJSONProducesPopulatedNotes() async throws {
        let cannedJSON = """
        {
            "summary": "Discussed shipping the feature by Friday and reviewing the PR.",
            "actionItems": [
                {"text": "Review the PR", "owner": "them", "due": "tomorrow"},
                {"text": "Ship the feature", "owner": "you", "due": "Friday"}
            ],
            "decisions": ["Use the new API design"]
        }
        """
        let planner = MockMeetingNotesPlannerClient(cannedResponse: cannedJSON)
        let notes = await PaceMeetingNotesBuilder.build(
            transcript: sampleTranscript,
            turns: makeTurns(),
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: "Standup",
            planner: planner
        )

        #expect(notes.synthesisFailed == false)
        #expect(notes.meetingID == meetingID)
        #expect(notes.title == "Standup")
        #expect(notes.transcript == sampleTranscript)
        #expect(notes.turns.count == 2)
        #expect(notes.summary == "Discussed shipping the feature by Friday and reviewing the PR.")
        #expect(notes.actionItems.count == 2)
        #expect(notes.actionItems[0].text == "Review the PR")
        #expect(notes.actionItems[0].owner == "them")
        #expect(notes.actionItems[0].due == "tomorrow")
        #expect(notes.actionItems[1].text == "Ship the feature")
        #expect(notes.decisions == ["Use the new API design"])
        #expect(planner.callCount == 1)
    }

    @Test func malformedJSONSetsSynthesisFailedAndPreservesTranscript() async throws {
        let planner = MockMeetingNotesPlannerClient(cannedResponse: "this is not valid JSON at all {{{")
        let notes = await PaceMeetingNotesBuilder.build(
            transcript: sampleTranscript,
            turns: makeTurns(),
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: "Standup",
            planner: planner
        )

        #expect(notes.synthesisFailed == true)
        #expect(notes.transcript == sampleTranscript)
        #expect(notes.summary == sampleTranscript)
        #expect(notes.actionItems.isEmpty == true)
        #expect(notes.decisions.isEmpty == true)
        #expect(planner.callCount == 1)
    }

    @Test func plannerThrowsSetsSynthesisFailedAndPreservesTranscript() async throws {
        let planner = MockMeetingNotesPlannerClient(cannedResponse: nil, shouldThrow: true)
        let notes = await PaceMeetingNotesBuilder.build(
            transcript: sampleTranscript,
            turns: makeTurns(),
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: "Standup",
            planner: planner
        )

        #expect(notes.synthesisFailed == true)
        #expect(notes.transcript == sampleTranscript)
        #expect(notes.summary == sampleTranscript)
        #expect(notes.actionItems.isEmpty == true)
        #expect(notes.decisions.isEmpty == true)
        #expect(planner.callCount == 1)
    }

    @Test func emptyTranscriptProducesEmptyNotesWithoutPlannerCall() async throws {
        let planner = MockMeetingNotesPlannerClient(cannedResponse: "{}")
        let notes = await PaceMeetingNotesBuilder.build(
            transcript: "   \n  ",
            turns: [],
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: "Empty meeting",
            planner: planner
        )

        #expect(notes.synthesisFailed == false)
        #expect(notes.transcript == "")
        #expect(notes.summary == "")
        #expect(notes.actionItems.isEmpty == true)
        #expect(notes.decisions.isEmpty == true)
        #expect(notes.turns.isEmpty == true)
        #expect(planner.callCount == 0)
    }

    @Test func markdownFencedJSONIsParsedCorrectly() async throws {
        let cannedJSON = """
        ```json
        {
            "summary": "Quick sync.",
            "actionItems": [{"text": "Follow up", "owner": null, "due": null}],
            "decisions": ["Go with plan B"]
        }
        ```
        """
        let planner = MockMeetingNotesPlannerClient(cannedResponse: cannedJSON)
        let notes = await PaceMeetingNotesBuilder.build(
            transcript: sampleTranscript,
            turns: makeTurns(),
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: "Sync",
            planner: planner
        )

        #expect(notes.synthesisFailed == false)
        #expect(notes.summary == "Quick sync.")
        #expect(notes.actionItems.count == 1)
        #expect(notes.actionItems[0].text == "Follow up")
        #expect(notes.actionItems[0].owner == nil)
        #expect(notes.actionItems[0].due == nil)
        #expect(notes.decisions == ["Go with plan B"])
    }

    @Test func missingActionItemsFieldDefaultsToEmptyArray() async throws {
        let cannedJSON = """
        {
            "summary": "No tasks this time.",
            "decisions": ["Postpone launch"]
        }
        """
        let planner = MockMeetingNotesPlannerClient(cannedResponse: cannedJSON)
        let notes = await PaceMeetingNotesBuilder.build(
            transcript: sampleTranscript,
            turns: makeTurns(),
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: "Standup",
            planner: planner
        )

        #expect(notes.synthesisFailed == false)
        #expect(notes.actionItems.isEmpty == true)
        #expect(notes.decisions == ["Postpone launch"])
    }

    @Test func unknownExtraFieldsAreIgnored() async throws {
        let cannedJSON = """
        {
            "summary": "Discussed roadmap.",
            "actionItems": [{"text": "Draft spec", "owner": "you", "due": "next week"}],
            "decisions": ["Adopt the new framework"],
            "attendees": ["you", "them"],
            "sentiment": "positive",
            "duration": 600
        }
        """
        let planner = MockMeetingNotesPlannerClient(cannedResponse: cannedJSON)
        let notes = await PaceMeetingNotesBuilder.build(
            transcript: sampleTranscript,
            turns: makeTurns(),
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: "Roadmap",
            planner: planner
        )

        #expect(notes.synthesisFailed == false)
        #expect(notes.summary == "Discussed roadmap.")
        #expect(notes.actionItems.count == 1)
        #expect(notes.decisions == ["Adopt the new framework"])
    }

    @Test func emptyPlannerResponseSetsSynthesisFailed() async throws {
        let planner = MockMeetingNotesPlannerClient(cannedResponse: "")
        let notes = await PaceMeetingNotesBuilder.build(
            transcript: sampleTranscript,
            turns: makeTurns(),
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: "Standup",
            planner: planner
        )

        #expect(notes.synthesisFailed == true)
        #expect(notes.transcript == sampleTranscript)
        #expect(notes.summary == sampleTranscript)
    }

    @Test func emptySummaryFallsBackToTranscript() async throws {
        let cannedJSON = """
        {
            "summary": "",
            "actionItems": [{"text": "Do something"}],
            "decisions": []
        }
        """
        let planner = MockMeetingNotesPlannerClient(cannedResponse: cannedJSON)
        let notes = await PaceMeetingNotesBuilder.build(
            transcript: sampleTranscript,
            turns: makeTurns(),
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: endedAt,
            title: "Standup",
            planner: planner
        )

        #expect(notes.synthesisFailed == false)
        #expect(notes.summary == sampleTranscript)
        #expect(notes.actionItems.count == 1)
    }

    @Test func stripMarkdownFencesHandlesPlainAndFencedJSON() async throws {
        #expect(PaceMeetingNotesBuilder.stripMarkdownFences(from: "{}") == "{}")
        #expect(PaceMeetingNotesBuilder.stripMarkdownFences(from: "```json\n{}\n```") == "{}")
        #expect(PaceMeetingNotesBuilder.stripMarkdownFences(from: "```\n{\"a\":1}\n```") == "{\"a\":1}")
    }
}
