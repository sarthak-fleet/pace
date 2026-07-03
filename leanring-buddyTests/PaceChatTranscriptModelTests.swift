//
//  PaceChatTranscriptModelTests.swift
//  leanring-buddyTests
//
//  Covers the pure mapping layer behind the premium chat panel
//  (docs/prds/premium-chat-panel.md, phase 1): conversation turns →
//  message row models, tool observations / action run records →
//  activity row models, the chronological thread merge, and the
//  empty-state decision. The suite is intentionally NOT @MainActor —
//  the whole point of `PaceChatTranscriptModel` is that it is pure and
//  isolation-free, so these tests exercising it off the main actor is
//  itself part of the contract.
//

import Foundation
import Testing
@testable import Pace

struct PaceChatTranscriptModelTests {

    // MARK: - Fixtures

    private func makeChatMessage(
        id: String = "turn-1:user",
        role: PaceChatRole = .user,
        body: String = "open my calendar",
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> PaceChatMessage {
        PaceChatMessage(id: id, role: role, body: body, createdAt: createdAt)
    }

    private func makeActionRunRecord(
        status: PaceActionRunStatus,
        title: String = "Action complete",
        detail: String = "Opened Calendar.",
        createdAt: Date = Date(timeIntervalSince1970: 2_000)
    ) -> PaceActionRunRecord {
        PaceActionRunRecord(
            createdAt: createdAt,
            status: status,
            title: title,
            detail: detail
        )
    }

    // MARK: - Conversation turns → message rows

    @Test func userChatMessageMapsToTrailingAccentTintedRow() {
        let userChatMessage = makeChatMessage(id: "turn-9:user", role: .user, body: "hello")
        let messageRowModel = PaceChatTranscriptModel.messageRowModel(fromChatMessage: userChatMessage)

        #expect(messageRowModel.id == "message-turn-9:user")
        #expect(messageRowModel.author == .user)
        #expect(messageRowModel.bodyText == "hello")
        #expect(messageRowModel.createdAt == userChatMessage.createdAt)
        #expect(messageRowModel.isAlignedToTrailingEdge)
        #expect(messageRowModel.usesAccentTintedBubble)
    }

    @Test func assistantChatMessageMapsToLeadingNeutralRow() {
        let assistantChatMessage = makeChatMessage(id: "turn-9:pace", role: .pace, body: "Hi there.")
        let messageRowModel = PaceChatTranscriptModel.messageRowModel(fromChatMessage: assistantChatMessage)

        #expect(messageRowModel.author == .assistant)
        #expect(!messageRowModel.isAlignedToTrailingEdge)
        #expect(!messageRowModel.usesAccentTintedBubble)
    }

    @Test func messageRowModelsPreserveInputOrder() {
        let chatMessages = [
            makeChatMessage(id: "a", role: .user, body: "first"),
            makeChatMessage(id: "b", role: .pace, body: "second"),
            makeChatMessage(id: "c", role: .user, body: "third")
        ]
        let messageRowModels = PaceChatTranscriptModel.messageRowModels(fromChatMessages: chatMessages)

        #expect(messageRowModels.map(\.bodyText) == ["first", "second", "third"])
        #expect(messageRowModels.map(\.id) == ["message-a", "message-b", "message-c"])
    }

    // MARK: - Tool display name

    @Test func toolDisplayNameReplacesUnderscoresWithSpaces() {
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "open_url") == "open url")
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "create_calendar_event") == "create calendar event")
    }

    @Test func toolDisplayNameTrimsWhitespaceAndFallsBackWhenBlank() {
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "  click  ") == "click")
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "") == "tool")
        #expect(PaceChatTranscriptModel.toolDisplayName(fromRawToolName: "   \n ") == "tool")
    }

    // MARK: - Observation failure detection

    @Test func observationSummaryFailureKeywordsAreDetectedCaseInsensitively() {
        #expect(PaceChatTranscriptModel.observationSummaryIndicatesFailure("Click FAILED after 3 candidates"))
        #expect(PaceChatTranscriptModel.observationSummaryIndicatesFailure("Could not open the app"))
        #expect(PaceChatTranscriptModel.observationSummaryIndicatesFailure("Calendar access not granted"))
        #expect(PaceChatTranscriptModel.observationSummaryIndicatesFailure("The note does not exist"))
    }

    @Test func observationSummaryWithoutFailureKeywordsIsNotAFailure() {
        #expect(!PaceChatTranscriptModel.observationSummaryIndicatesFailure("Opened Safari."))
        #expect(!PaceChatTranscriptModel.observationSummaryIndicatesFailure("Created reminder \"send invoice\"."))
        #expect(!PaceChatTranscriptModel.observationSummaryIndicatesFailure(""))
    }

    // MARK: - One-line summary

    @Test func oneLineSummaryTakesFirstNonEmptyLineTrimmed() {
        let multiLineSummary = "\n\n  Opened Calendar.  \nSecond line detail."
        #expect(PaceChatTranscriptModel.oneLineSummary(fromRawSummary: multiLineSummary) == "Opened Calendar.")
    }

    @Test func oneLineSummaryTruncatesPastTheCharacterCapWithEllipsis() {
        let longSummary = String(repeating: "a", count: 300)
        let oneLineSummary = PaceChatTranscriptModel.oneLineSummary(
            fromRawSummary: longSummary,
            maximumCharacterCount: 10
        )
        #expect(oneLineSummary == String(repeating: "a", count: 10) + "…")
    }

    @Test func oneLineSummaryOfBlankInputIsEmpty() {
        #expect(PaceChatTranscriptModel.oneLineSummary(fromRawSummary: "") == "")
        #expect(PaceChatTranscriptModel.oneLineSummary(fromRawSummary: "\n  \n") == "")
    }

    // MARK: - Observations → activity rows

    @Test func successfulObservationMapsToDoneActivityRow() {
        let observation = PaceActionExecutionObservation(
            toolName: "open_app",
            summary: "Opened Safari."
        )
        let observedAt = Date(timeIntervalSince1970: 3_000)
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromObservation: observation,
            turnIdentifier: "turn-42",
            observationIndex: 0,
            observedAt: observedAt
        )

        #expect(toolActivityRowModel.id == "observation-turn-42-0")
        #expect(toolActivityRowModel.toolDisplayName == "open app")
        #expect(toolActivityRowModel.resultState == .done)
        #expect(toolActivityRowModel.resultSummaryLine == "Opened Safari.")
        #expect(toolActivityRowModel.occurredAt == observedAt)
    }

    @Test func failedObservationMapsToFailedActivityRow() {
        let observation = PaceActionExecutionObservation(
            toolName: "click",
            summary: "Click failed after trying 3 of 3 candidates."
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromObservation: observation,
            turnIdentifier: "turn-42",
            observationIndex: 1,
            observedAt: Date(timeIntervalSince1970: 3_000)
        )

        #expect(toolActivityRowModel.resultState == .failed)
    }

    @Test func observationBatchGetsIndexStableIdsInInputOrder() {
        let observations = [
            PaceActionExecutionObservation(toolName: "open_app", summary: "Opened Safari."),
            PaceActionExecutionObservation(toolName: "open_url", summary: "Opened https://example.com.")
        ]
        let toolActivityRowModels = PaceChatTranscriptModel.toolActivityRowModels(
            fromObservations: observations,
            turnIdentifier: "turn-7",
            observedAt: Date(timeIntervalSince1970: 4_000)
        )

        #expect(toolActivityRowModels.map(\.id) == ["observation-turn-7-0", "observation-turn-7-1"])
        #expect(toolActivityRowModels.map(\.toolDisplayName) == ["open app", "open url"])
    }

    // MARK: - Run-record status → result state

    @Test func runRecordStatusCollapsesToTheThreeStateContract() {
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .planned) == .running)
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .completed) == .done)
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .failed) == .failed)
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .denied) == .failed)
        #expect(PaceChatTranscriptModel.resultState(fromActionRunStatus: .skipped) == .failed)
    }

    @Test func runRecordMapsTitleDetailAndTimestampIntoTheActivityRow() {
        let actionRunRecord = makeActionRunRecord(
            status: .completed,
            title: "Action complete",
            detail: "Opened Calendar.\nExtra detail line."
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromActionRunRecord: actionRunRecord
        )

        #expect(toolActivityRowModel.id == "record-\(actionRunRecord.id.uuidString)")
        #expect(toolActivityRowModel.toolDisplayName == "Action complete")
        #expect(toolActivityRowModel.resultState == .done)
        #expect(toolActivityRowModel.resultSummaryLine == "Opened Calendar.")
        #expect(toolActivityRowModel.occurredAt == actionRunRecord.createdAt)
    }

    @Test func runRecordWithBlankDetailFallsBackToTitleForTheSummaryLine() {
        let actionRunRecord = makeActionRunRecord(
            status: .denied,
            title: "Action denied",
            detail: "   "
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromActionRunRecord: actionRunRecord
        )

        #expect(toolActivityRowModel.resultState == .failed)
        #expect(toolActivityRowModel.resultSummaryLine == "Action denied")
    }

    // MARK: - Newest-first record list → oldest-first rows

    @Test func newestFirstRecordsComeBackOldestFirst() {
        let olderRecord = makeActionRunRecord(
            status: .completed,
            detail: "older",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newerRecord = makeActionRunRecord(
            status: .failed,
            detail: "newer",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        // CompanionManager.recentActionResults stores newest-first.
        let toolActivityRowModels = PaceChatTranscriptModel.toolActivityRowModels(
            fromNewestFirstActionRunRecords: [newerRecord, olderRecord]
        )

        #expect(toolActivityRowModels.map(\.resultSummaryLine) == ["older", "newer"])
    }

    @Test func supersededPlannedRecordIsDroppedButNewestPlannedRecordSurvivesAsRunning() {
        let supersededPlannedRecord = makeActionRunRecord(
            status: .planned,
            title: "1 tool planned",
            detail: "superseded",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let completedRecord = makeActionRunRecord(
            status: .completed,
            detail: "completed twin",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let inFlightPlannedRecord = makeActionRunRecord(
            status: .planned,
            title: "1 tool planned",
            detail: "in flight",
            createdAt: Date(timeIntervalSince1970: 300)
        )
        // Newest-first, matching CompanionManager.appendActionResult.
        let toolActivityRowModels = PaceChatTranscriptModel.toolActivityRowModels(
            fromNewestFirstActionRunRecords: [inFlightPlannedRecord, completedRecord, supersededPlannedRecord]
        )

        #expect(toolActivityRowModels.count == 2)
        #expect(toolActivityRowModels.map(\.resultSummaryLine) == ["completed twin", "in flight"])
        #expect(toolActivityRowModels.last?.resultState == .running)
    }

    // MARK: - Result-state rendering decisions

    @Test func resultStatesCarryTheirDisplayLabelsAndSymbols() {
        #expect(PaceChatToolActivityResultState.running.displayLabel == "Running")
        #expect(PaceChatToolActivityResultState.done.displayLabel == "Done")
        #expect(PaceChatToolActivityResultState.failed.displayLabel == "Failed")
        #expect(PaceChatToolActivityResultState.running.systemSymbolName == "circle.dotted")
        #expect(PaceChatToolActivityResultState.done.systemSymbolName == "checkmark.circle.fill")
        #expect(PaceChatToolActivityResultState.failed.systemSymbolName == "exclamationmark.triangle.fill")
    }

    // MARK: - Thread merge

    @Test func threadRowsMergeMessagesAndToolActivityChronologically() {
        let userMessageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(
                id: "t:user",
                role: .user,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        let assistantMessageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(
                id: "t:pace",
                role: .pace,
                body: "Done — Calendar is open.",
                createdAt: Date(timeIntervalSince1970: 300)
            )
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromActionRunRecord: makeActionRunRecord(
                status: .completed,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )

        let threadRows = PaceChatTranscriptModel.threadRows(
            messageRowModels: [userMessageRowModel, assistantMessageRowModel],
            toolActivityRowModels: [toolActivityRowModel]
        )

        #expect(threadRows.count == 3)
        #expect(threadRows[0].id == "thread-message-message-t:user")
        #expect(threadRows[1].id == "thread-tool-\(toolActivityRowModel.id)")
        #expect(threadRows[2].id == "thread-message-message-t:pace")
    }

    @Test func exactTimestampTiePutsTheMessageBeforeTheToolActivityRow() {
        let sharedTimestamp = Date(timeIntervalSince1970: 500)
        let messageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(id: "tie:pace", role: .pace, createdAt: sharedTimestamp)
        )
        let toolActivityRowModel = PaceChatTranscriptModel.toolActivityRowModel(
            fromActionRunRecord: makeActionRunRecord(status: .completed, createdAt: sharedTimestamp)
        )

        let threadRows = PaceChatTranscriptModel.threadRows(
            messageRowModels: [messageRowModel],
            toolActivityRowModels: [toolActivityRowModel]
        )

        #expect(threadRows.first?.id == "thread-message-message-tie:pace")
        #expect(threadRows.last?.id == "thread-tool-\(toolActivityRowModel.id)")
    }

    @Test func sameKindTimestampTiesKeepInputOrder() {
        let sharedTimestamp = Date(timeIntervalSince1970: 500)
        let firstMessageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(id: "first", role: .user, createdAt: sharedTimestamp)
        )
        let secondMessageRowModel = PaceChatTranscriptModel.messageRowModel(
            fromChatMessage: makeChatMessage(id: "second", role: .pace, createdAt: sharedTimestamp)
        )

        let threadRows = PaceChatTranscriptModel.threadRows(
            messageRowModels: [firstMessageRowModel, secondMessageRowModel],
            toolActivityRowModels: []
        )

        #expect(threadRows.map(\.id) == [
            "thread-message-message-first",
            "thread-message-message-second"
        ])
    }

    @Test func threadRowOccurredAtMirrorsTheUnderlyingRowModel() {
        let messageTimestamp = Date(timeIntervalSince1970: 111)
        let toolTimestamp = Date(timeIntervalSince1970: 222)
        let messageThreadRow = PaceChatThreadRowModel.message(
            PaceChatTranscriptModel.messageRowModel(
                fromChatMessage: makeChatMessage(createdAt: messageTimestamp)
            )
        )
        let toolThreadRow = PaceChatThreadRowModel.toolActivity(
            PaceChatTranscriptModel.toolActivityRowModel(
                fromActionRunRecord: makeActionRunRecord(status: .completed, createdAt: toolTimestamp)
            )
        )

        #expect(messageThreadRow.occurredAt == messageTimestamp)
        #expect(toolThreadRow.occurredAt == toolTimestamp)
    }

    // MARK: - Empty-state decision

    @Test func emptyStateShowsOnlyWhenThereIsTrulyNothingToRender() {
        #expect(PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 0,
            liveSpeechDraftText: "",
            inFlightStreamedReplyText: ""
        ))
        #expect(PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 0,
            liveSpeechDraftText: "   \n",
            inFlightStreamedReplyText: "  "
        ))
    }

    @Test func emptyStateHidesWhenAnySurfaceHasContent() {
        #expect(!PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 1,
            liveSpeechDraftText: "",
            inFlightStreamedReplyText: ""
        ))
        #expect(!PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 0,
            liveSpeechDraftText: "open my cal",
            inFlightStreamedReplyText: ""
        ))
        #expect(!PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: 0,
            liveSpeechDraftText: "",
            inFlightStreamedReplyText: "Sure — opening"
        ))
    }
}
