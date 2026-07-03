//
//  PaceChatTranscriptModel.swift
//  leanring-buddy
//
//  Pure, isolation-free mapping layer for the premium chat panel
//  (PRD: docs/prds/premium-chat-panel.md, phase 1). Maps the existing
//  conversation state (`PaceChatMessage` rows owned by `PaceChatSession`)
//  into transcript row models, and the existing tool-execution flow
//  (`PaceActionExecutionObservation` produced by `PaceActionExecutor`,
//  `PaceActionRunRecord` published on `CompanionManager.recentActionResults`)
//  into inline tool-activity row models.
//
//  Every rendering decision that does not require SwiftUI lives here —
//  bubble alignment, accent tinting, running/done/failed derivation,
//  SF Symbol names, one-line summaries, chronological merging, and the
//  empty-state decision — so it is all unit-testable without a view,
//  a `CompanionManager`, or the main actor. Nothing in this file holds
//  state, touches UserDefaults, or imports SwiftUI/AppKit.
//

import Foundation

// MARK: - Row models

/// Who authored a transcript row. Drives bubble alignment and tint
/// (PRD design language: user right-aligned tinted, assistant
/// left-aligned neutral).
nonisolated enum PaceChatTranscriptRowAuthor: Equatable {
    case user
    case assistant
}

/// One rendered chat bubble in the transcript column.
nonisolated struct PaceChatTranscriptMessageRowModel: Identifiable, Equatable {
    let id: String
    let author: PaceChatTranscriptRowAuthor
    let bodyText: String
    let createdAt: Date

    /// User rows dock to the trailing (right) edge; assistant rows dock
    /// to the leading (left) edge.
    var isAlignedToTrailingEdge: Bool {
        author == .user
    }

    /// User bubbles get the accent tint; assistant bubbles stay neutral.
    var usesAccentTintedBubble: Bool {
        author == .user
    }
}

/// Result state of one tool run, per the PRD's three-state contract
/// (running / done / failed). Anything that did not complete
/// successfully — including a user denial or a skip — renders as the
/// attention state, with the summary line carrying the real reason.
nonisolated enum PaceChatToolActivityResultState: Equatable {
    case running
    case done
    case failed

    var displayLabel: String {
        switch self {
        case .running:
            return "Running"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }

    /// SF Symbol for the row's leading icon. Kept here (as a string)
    /// rather than in the view so the icon choice is unit-testable.
    var systemSymbolName: String {
        switch self {
        case .running:
            return "circle.dotted"
        case .done:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

/// One compact inline tool-activity row rendered under the assistant
/// bubble it belongs to: tool name + one-line result state.
nonisolated struct PaceChatToolActivityRowModel: Identifiable, Equatable {
    let id: String
    let toolDisplayName: String
    let resultState: PaceChatToolActivityResultState
    let resultSummaryLine: String
    let occurredAt: Date
}

/// A single row in the merged conversation timeline — either a chat
/// bubble or a tool-activity row — so tool use renders inline, in
/// chronological order, inside the same transcript column.
nonisolated enum PaceChatThreadRowModel: Identifiable, Equatable {
    case message(PaceChatTranscriptMessageRowModel)
    case toolActivity(PaceChatToolActivityRowModel)

    var id: String {
        switch self {
        case .message(let messageRowModel):
            return "thread-message-\(messageRowModel.id)"
        case .toolActivity(let toolActivityRowModel):
            return "thread-tool-\(toolActivityRowModel.id)"
        }
    }

    var occurredAt: Date {
        switch self {
        case .message(let messageRowModel):
            return messageRowModel.createdAt
        case .toolActivity(let toolActivityRowModel):
            return toolActivityRowModel.occurredAt
        }
    }
}

// MARK: - Mapping functions

/// Namespace for the pure mapping functions. All functions are `static`
/// and side-effect free; no instance state.
nonisolated enum PaceChatTranscriptModel {

    // MARK: Conversation turns → message rows

    static func messageRowModel(
        fromChatMessage chatMessage: PaceChatMessage
    ) -> PaceChatTranscriptMessageRowModel {
        PaceChatTranscriptMessageRowModel(
            id: "message-\(chatMessage.id)",
            author: chatMessage.role == .user ? .user : .assistant,
            bodyText: chatMessage.body,
            createdAt: chatMessage.createdAt
        )
    }

    static func messageRowModels(
        fromChatMessages chatMessages: [PaceChatMessage]
    ) -> [PaceChatTranscriptMessageRowModel] {
        chatMessages.map { chatMessage in
            messageRowModel(fromChatMessage: chatMessage)
        }
    }

    // MARK: Tool observations → activity rows

    /// Planner tool names are snake_case identifiers (`open_url`,
    /// `create_reminder`); underscores read badly in UI, so they become
    /// spaces. An empty/blank tool name falls back to the generic word
    /// "tool" rather than rendering an empty label.
    static func toolDisplayName(fromRawToolName rawToolName: String) -> String {
        let trimmedToolName = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToolName.isEmpty else { return "tool" }
        return trimmedToolName.replacingOccurrences(of: "_", with: " ")
    }

    /// Failure detection for an executed observation's summary text.
    /// Observations don't carry a typed success/failure flag, so this
    /// mirrors the keyword set `PaceActionRunRecord.completed(observations:)`
    /// already uses — keep the two in sync if either changes.
    static func observationSummaryIndicatesFailure(_ observationSummary: String) -> Bool {
        let lowercasedSummary = observationSummary.lowercased()
        return lowercasedSummary.contains("failed")
            || lowercasedSummary.contains("could not")
            || lowercasedSummary.contains("not granted")
            || lowercasedSummary.contains("does not exist")
    }

    /// Collapses a (possibly multi-line) tool summary into the single
    /// line the compact activity row shows: first non-empty line,
    /// trimmed, truncated with an ellipsis past the character cap.
    static func oneLineSummary(
        fromRawSummary rawSummary: String,
        maximumCharacterCount: Int = 160
    ) -> String {
        let firstNonEmptyLine = rawSummary
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in line.trimmingCharacters(in: .whitespaces) }
            .first { line in !line.isEmpty } ?? ""
        guard firstNonEmptyLine.count > maximumCharacterCount else {
            return firstNonEmptyLine
        }
        let truncatedLine = String(firstNonEmptyLine.prefix(maximumCharacterCount))
            .trimmingCharacters(in: .whitespaces)
        return truncatedLine + "…"
    }

    /// Maps one executor observation to an activity row. Observations
    /// only exist AFTER execution, so the state is never `.running` —
    /// it is `.failed` when the summary reads as a failure, `.done`
    /// otherwise. `turnIdentifier` + `observationIndex` make the row id
    /// stable across re-renders without the observation carrying an id.
    static func toolActivityRowModel(
        fromObservation observation: PaceActionExecutionObservation,
        turnIdentifier: String,
        observationIndex: Int,
        observedAt: Date
    ) -> PaceChatToolActivityRowModel {
        PaceChatToolActivityRowModel(
            id: "observation-\(turnIdentifier)-\(observationIndex)",
            toolDisplayName: toolDisplayName(fromRawToolName: observation.toolName),
            resultState: observationSummaryIndicatesFailure(observation.summary) ? .failed : .done,
            resultSummaryLine: oneLineSummary(fromRawSummary: observation.summary),
            occurredAt: observedAt
        )
    }

    static func toolActivityRowModels(
        fromObservations observations: [PaceActionExecutionObservation],
        turnIdentifier: String,
        observedAt: Date
    ) -> [PaceChatToolActivityRowModel] {
        observations.enumerated().map { observationIndex, observation in
            toolActivityRowModel(
                fromObservation: observation,
                turnIdentifier: turnIdentifier,
                observationIndex: observationIndex,
                observedAt: observedAt
            )
        }
    }

    // MARK: Action run records → activity rows

    /// Collapses the five run-record statuses into the PRD's three-state
    /// contract: `.planned` is a run still in flight, `.completed` is a
    /// success, and everything else (failed / denied / skipped) renders
    /// as the attention state with the summary line carrying the reason.
    static func resultState(
        fromActionRunStatus actionRunStatus: PaceActionRunStatus
    ) -> PaceChatToolActivityResultState {
        switch actionRunStatus {
        case .planned:
            return .running
        case .completed:
            return .done
        case .failed, .denied, .skipped:
            return .failed
        }
    }

    /// Maps one published run record to an activity row. Records carry a
    /// human title ("Action complete", "2 tools planned") rather than a
    /// raw tool name, so the title becomes the display name and the
    /// detail becomes the summary line (falling back to the title when
    /// the detail is blank).
    static func toolActivityRowModel(
        fromActionRunRecord actionRunRecord: PaceActionRunRecord
    ) -> PaceChatToolActivityRowModel {
        let trimmedDetail = actionRunRecord.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return PaceChatToolActivityRowModel(
            id: "record-\(actionRunRecord.id.uuidString)",
            toolDisplayName: actionRunRecord.title,
            resultState: resultState(fromActionRunStatus: actionRunRecord.status),
            resultSummaryLine: oneLineSummary(
                fromRawSummary: trimmedDetail.isEmpty ? actionRunRecord.title : trimmedDetail
            ),
            occurredAt: actionRunRecord.createdAt
        )
    }

    /// Maps `CompanionManager.recentActionResults` (stored NEWEST-first,
    /// capped at 8) into activity rows ordered OLDEST-first for the
    /// top-down transcript. A `.planned` record is a run that has not
    /// reported a result yet; each run later appends a completed/failed
    /// twin, so a planned record with ANY newer record after it has been
    /// superseded and is dropped — otherwise the same tool run would
    /// render twice. Only the newest record can still be in flight.
    static func toolActivityRowModels(
        fromNewestFirstActionRunRecords newestFirstActionRunRecords: [PaceActionRunRecord]
    ) -> [PaceChatToolActivityRowModel] {
        let oldestFirstRowModels: [PaceChatToolActivityRowModel] = newestFirstActionRunRecords
            .enumerated()
            .compactMap { indexFromNewest, actionRunRecord in
                if actionRunRecord.status == .planned && indexFromNewest != 0 {
                    return nil
                }
                return toolActivityRowModel(fromActionRunRecord: actionRunRecord)
            }
            .reversed()
        return Array(oldestFirstRowModels)
    }

    // MARK: Merged conversation timeline

    /// Merges chat bubbles and tool-activity rows into one chronological
    /// timeline. The sort is total and deterministic: chronological
    /// first; on an exact timestamp tie the message wins (the tool ran
    /// FOR that turn, so it reads better under the bubble); same-kind
    /// ties keep input order (Swift's `sorted` is not guaranteed stable,
    /// so the original index is part of the sort key).
    static func threadRows(
        messageRowModels: [PaceChatTranscriptMessageRowModel],
        toolActivityRowModels: [PaceChatToolActivityRowModel]
    ) -> [PaceChatThreadRowModel] {
        struct SortableThreadRow {
            let threadRow: PaceChatThreadRowModel
            let occurredAt: Date
            let kindRank: Int
            let inputIndex: Int
        }

        let messageCandidates = messageRowModels.enumerated().map { inputIndex, messageRowModel in
            SortableThreadRow(
                threadRow: .message(messageRowModel),
                occurredAt: messageRowModel.createdAt,
                kindRank: 0,
                inputIndex: inputIndex
            )
        }
        let toolActivityCandidates = toolActivityRowModels.enumerated().map { inputIndex, toolActivityRowModel in
            SortableThreadRow(
                threadRow: .toolActivity(toolActivityRowModel),
                occurredAt: toolActivityRowModel.occurredAt,
                kindRank: 1,
                inputIndex: inputIndex
            )
        }

        return (messageCandidates + toolActivityCandidates)
            .sorted { leftCandidate, rightCandidate in
                if leftCandidate.occurredAt != rightCandidate.occurredAt {
                    return leftCandidate.occurredAt < rightCandidate.occurredAt
                }
                if leftCandidate.kindRank != rightCandidate.kindRank {
                    return leftCandidate.kindRank < rightCandidate.kindRank
                }
                return leftCandidate.inputIndex < rightCandidate.inputIndex
            }
            .map { sortableCandidate in sortableCandidate.threadRow }
    }

    // MARK: Empty-state decision

    /// The "Hold ⌃⌥ to talk" empty state shows only when there is truly
    /// nothing to render: no committed rows, no in-progress speech
    /// draft, and no streaming reply.
    static func shouldShowEmptyTranscriptState(
        threadRowCount: Int,
        liveSpeechDraftText: String,
        inFlightStreamedReplyText: String
    ) -> Bool {
        threadRowCount == 0
            && liveSpeechDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inFlightStreamedReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
