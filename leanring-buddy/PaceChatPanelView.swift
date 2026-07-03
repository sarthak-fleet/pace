//
//  PaceChatPanelView.swift
//  leanring-buddy
//
//  Phase 1 of the premium chat panel (PRD: docs/prds/premium-chat-panel.md):
//  a Claude-Desktop-style conversation column — header strip (voice state +
//  gear), transcript with inline tool-activity rows, morning-brief and
//  meeting cards as inline transcript cards, and a permanently docked input.
//
//  Flag-gated: `MenuBarPanelManager` renders this view ONLY when the
//  `useChatPanelAsPrimarySurface` preference is ON (default OFF in phase 1).
//  Flag OFF keeps the shipped `PacePanelChatView` surface byte-identical.
//
//  Backed entirely by EXISTING state — `PaceChatSession` (the shared
//  voice+chat transcript fed by `recordConversationTurn`),
//  `recentActionResults` (the published `PaceActionExecutionObservation`
//  flow), `liveSpeechDraft`, and `inFlightStreamedText`. Every rendering
//  decision that can be pure lives in `PaceChatTranscriptModel`; this file
//  only draws.
//

import SwiftUI

struct PaceChatPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    // Observed separately: these are their own ObservableObjects, and
    // changes to their @Published state do NOT flow through
    // `companionManager.objectWillChange` — observing only the manager
    // would miss new chat messages and streaming-reply ticks.
    @ObservedObject private var chatSession: PaceChatSession
    @ObservedObject private var streamingSentenceTTSPipeline: StreamingSentenceTTSPipeline
    @ObservedObject private var morningTriageScheduler: PaceMorningTriageScheduler
    @ObservedObject private var meetingController = PaceMeetingModeController.shared

    /// Auto-scroll is the panel's only recurring motion; when the user
    /// has macOS Reduce Motion on, the transcript still follows the
    /// conversation but snaps instead of animating.
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotionIsEnabled

    @State private var draftMessageText: String = ""
    @FocusState private var isChatInputFocused: Bool

    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 460

    init(companionManager: CompanionManager) {
        _companionManager = ObservedObject(wrappedValue: companionManager)
        _chatSession = ObservedObject(wrappedValue: companionManager.chatSession)
        _streamingSentenceTTSPipeline = ObservedObject(
            wrappedValue: companionManager.streamingSentenceTTSPipeline
        )
        _morningTriageScheduler = ObservedObject(
            wrappedValue: companionManager.morningTriageScheduler
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerStrip
            Divider().background(DS.Colors.borderSubtle)
            transcriptColumn
            Divider().background(DS.Colors.borderSubtle)
            dockedInputRow
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            // Re-pull persisted history so turns recorded before this
            // panel first opened (or while it was closed) are present.
            // `loadHistory()` is idempotent — it replaces the rendered
            // transcript wholesale from the same `paceHistory` store
            // `recordConversationTurn` writes to.
            chatSession.loadHistory()
            isChatInputFocused = true
        }
    }

    /// System material per the PRD design language, darkened with the
    /// existing background token so the DS text colors keep contrast on
    /// any desktop wallpaper behind the panel.
    private var panelBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            DS.Colors.background.opacity(0.72)
        }
    }

    // MARK: - Header strip
    //
    // PRD contract: mic/live state on the left (reuses `voiceState`),
    // gear on the right opening the existing settings window. Nothing
    // else — every dashboard section moved behind the gear.

    private var headerStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: voiceStateSymbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(voiceStateColor)
                .frame(width: 16)

            Text(voiceStateDisplayText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Button(action: {
                PaceSettingsWindowManager.shared.show(companionManager: companionManager)
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Settings — planner, voice, permissions, memory, activity")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var voiceStateSymbolName: String {
        switch companionManager.voiceState {
        case .idle:
            return "mic"
        case .listening:
            return "waveform"
        case .processing:
            return "hourglass"
        case .responding:
            return "speaker.wave.2.fill"
        }
    }

    private var voiceStateColor: Color {
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening, .responding:
            return DS.Colors.accent
        case .processing:
            return DS.Colors.warning
        }
    }

    private var voiceStateDisplayText: String {
        switch companionManager.voiceState {
        case .idle:
            return "Ready — hold ⌃⌥ to talk"
        case .listening:
            return "Listening"
        case .processing:
            return "Thinking"
        case .responding:
            return "Speaking"
        }
    }

    // MARK: - Transcript column

    /// Stable scroll target pinned after the last row so auto-scroll has
    /// one anchor across messages, tool rows, inline cards, the live
    /// speech bubble, and the streaming reply.
    private static let transcriptBottomAnchorId = "chat-panel-bottom-anchor"

    private var transcriptColumn: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if shouldShowEmptyTranscriptState {
                        emptyTranscriptState
                            .padding(.top, 48)
                    } else {
                        ForEach(threadRows) { threadRow in
                            switch threadRow {
                            case .message(let messageRowModel):
                                messageBubbleRow(messageRowModel)
                            case .toolActivity(let toolActivityRowModel):
                                toolActivityRow(toolActivityRowModel)
                            }
                        }
                    }
                    morningBriefInlineCard
                    meetingInlineCard
                    liveSpeechDraftBubbleRow
                    streamingReplyBubbleRow
                    Color.clear
                        .frame(height: 1)
                        .id(Self.transcriptBottomAnchorId)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: chatSession.messages.count) {
                scrollTranscriptToBottom(scrollProxy)
            }
            .onChange(of: streamingSentenceTTSPipeline.inFlightStreamedText) {
                scrollTranscriptToBottom(scrollProxy)
            }
            .onChange(of: companionManager.liveSpeechDraft) {
                scrollTranscriptToBottom(scrollProxy)
            }
            .onChange(of: companionManager.recentActionResults.count) {
                scrollTranscriptToBottom(scrollProxy)
            }
            .onAppear {
                scrollTranscriptToBottom(scrollProxy, isAnimated: false)
            }
        }
    }

    /// Merged conversation timeline. All merge/sort/state decisions live
    /// in the pure `PaceChatTranscriptModel` layer (unit-tested there).
    private var threadRows: [PaceChatThreadRowModel] {
        PaceChatTranscriptModel.threadRows(
            messageRowModels: PaceChatTranscriptModel.messageRowModels(
                fromChatMessages: chatSession.messages
            ),
            toolActivityRowModels: PaceChatTranscriptModel.toolActivityRowModels(
                fromNewestFirstActionRunRecords: companionManager.recentActionResults
            )
        )
    }

    private var shouldShowEmptyTranscriptState: Bool {
        PaceChatTranscriptModel.shouldShowEmptyTranscriptState(
            threadRowCount: threadRows.count,
            liveSpeechDraftText: companionManager.liveSpeechDraft,
            inFlightStreamedReplyText: streamingSentenceTTSPipeline.inFlightStreamedText
        ) && !hasInlineEventCards
    }

    /// Inline event cards (morning brief / meeting) render even when the
    /// chat thread itself is empty, so the empty state must yield to them.
    private var hasInlineEventCards: Bool {
        morningTriageScheduler.pendingMorningBriefCard != nil
            || meetingController.state != .inactive
            || meetingController.lastMeetingNotes != nil
    }

    private func scrollTranscriptToBottom(
        _ scrollProxy: ScrollViewProxy,
        isAnimated: Bool = true
    ) {
        if isAnimated && !accessibilityReduceMotionIsEnabled {
            withAnimation(.easeOut(duration: 0.18)) {
                scrollProxy.scrollTo(Self.transcriptBottomAnchorId, anchor: .bottom)
            }
        } else {
            scrollProxy.scrollTo(Self.transcriptBottomAnchorId, anchor: .bottom)
        }
    }

    private var emptyTranscriptState: some View {
        VStack(spacing: 6) {
            Text("Hold ⌃⌥ to talk")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("…or type below.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Message bubbles

    private func messageBubbleRow(
        _ messageRowModel: PaceChatTranscriptMessageRowModel
    ) -> some View {
        HStack {
            if messageRowModel.isAlignedToTrailingEdge {
                Spacer(minLength: 32)
            }
            Text(messageRowModel.bodyText)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            messageRowModel.usesAccentTintedBubble
                                ? DS.Colors.accent.opacity(0.22)
                                : Color.white.opacity(0.05)
                        )
                )
                .frame(
                    maxWidth: .infinity,
                    alignment: messageRowModel.isAlignedToTrailingEdge ? .trailing : .leading
                )
            if !messageRowModel.isAlignedToTrailingEdge {
                Spacer(minLength: 32)
            }
        }
    }

    // MARK: - Inline tool activity

    /// Compact row under the assistant bubble it belongs to: state icon,
    /// tool name, one-line result. Per PRD: tool name + one-line result
    /// state (running / done / failed).
    private func toolActivityRow(
        _ toolActivityRowModel: PaceChatToolActivityRowModel
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: toolActivityRowModel.resultState.systemSymbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(toolActivityResultStateColor(toolActivityRowModel.resultState))

            Text(toolActivityRowModel.toolDisplayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(toolActivityRowModel.resultSummaryLine)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous).fill(Color.white.opacity(0.05))
        )
    }

    private func toolActivityResultStateColor(
        _ resultState: PaceChatToolActivityResultState
    ) -> Color {
        switch resultState {
        case .running:
            return DS.Colors.accent
        case .done:
            return DS.Colors.success
        case .failed:
            return DS.Colors.warning
        }
    }

    // MARK: - Live speech + streaming reply

    /// The user's words as they speak — a right-aligned in-progress
    /// bubble, slightly more saturated than a committed user bubble so
    /// it reads as "in progress". Replaced by the committed message when
    /// `recordConversationTurn` lands the turn.
    @ViewBuilder
    private var liveSpeechDraftBubbleRow: some View {
        if !companionManager.liveSpeechDraft
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Spacer(minLength: 32)
                Text(companionManager.liveSpeechDraft)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DS.Colors.accent.opacity(0.30))
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Pace's reply as it streams — the same `inFlightStreamedText` the
    /// TTS pipeline publishes, so a spoken turn appears in the transcript
    /// exactly like a typed one. Retired by `recordConversationTurn` when
    /// the committed assistant message lands.
    @ViewBuilder
    private var streamingReplyBubbleRow: some View {
        if !streamingSentenceTTSPipeline.inFlightStreamedText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Text(streamingSentenceTTSPipeline.inFlightStreamedText)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 32)
            }
        }
    }

    // MARK: - Morning brief inline card
    //
    // PRD item 5: the morning brief is an event in the conversation, not
    // a permanent dashboard fixture — it renders as an inline transcript
    // card only while a brief is parked and waiting.

    @ViewBuilder
    private var morningBriefInlineCard: some View {
        if let pendingMorningBriefCard = morningTriageScheduler.pendingMorningBriefCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Morning brief")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer(minLength: 0)

                    Button(action: {
                        companionManager.playPendingMorningBrief()
                    }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Speak the brief now")

                    Button(action: {
                        morningTriageScheduler.dismissPendingCard()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Dismiss")
                }

                Text(pendingMorningBriefCard)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
        }
    }

    // MARK: - Meeting inline card
    //
    // PRD item 5: meeting capture/notes render as inline transcript
    // cards when they occur. Reuses the same `PaceMeetingModeController`
    // state the dashboard card read — no new execution paths.

    @ViewBuilder
    private var meetingInlineCard: some View {
        if case .failed(let failureMessage) = meetingController.state {
            meetingFailedInlineCard(failureMessage: failureMessage)
        } else if meetingController.state != .inactive {
            meetingActiveInlineCard
        } else if let meetingNotes = meetingController.lastMeetingNotes {
            meetingNotesResultInlineCard(meetingNotes: meetingNotes)
        }
    }

    private var meetingActiveInlineCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(meetingStateLabel(for: meetingController.state))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer(minLength: 0)

                Text(elapsedTimeString(meetingController.captureDurationSeconds))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .monospacedDigit()
            }

            // RMS meter — reuses the live detectedSpeechLevel.
            ProgressView(value: Double(meetingController.detectedSpeechLevel), total: 1.0)
                .progressViewStyle(.linear)
                .tint(DS.Colors.accent)
                .frame(height: 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func meetingNotesResultInlineCard(meetingNotes: PaceMeetingNotes) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(meetingNotes.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meetingNotes.transcript, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Copy transcript")
            }

            if meetingNotes.synthesisFailed {
                Text("Notes synthesis failed — transcript saved.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !meetingNotes.summary.isEmpty {
                Text(meetingNotes.summary)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !meetingNotes.actionItems.isEmpty {
                Text("Action items:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.top, 4)
                ForEach(Array(meetingNotes.actionItems.enumerated()), id: \.offset) { _, actionItem in
                    Text("• \(actionItem.text)\(actionItem.owner.map { " — \($0)" } ?? "")")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !meetingNotes.decisions.isEmpty {
                Text("Decisions:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.top, 4)
                ForEach(Array(meetingNotes.decisions.enumerated()), id: \.offset) { _, decision in
                    Text("• \(decision)")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func meetingFailedInlineCard(failureMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Meeting failed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text(failureMessage)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func meetingStateLabel(for meetingModeState: PaceMeetingModeState) -> String {
        switch meetingModeState {
        case .inactive:
            return "Meeting"
        case .starting:
            return "Starting meeting…"
        case .active:
            return "Recording meeting"
        case .transcribing:
            return "Transcribing…"
        case .synthesizing:
            return "Writing notes…"
        case .failed:
            return "Meeting failed"
        }
    }

    private func elapsedTimeString(_ elapsedSeconds: TimeInterval) -> String {
        let minutes = Int(elapsedSeconds) / 60
        let seconds = Int(elapsedSeconds) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Docked input

    private var dockedInputRow: some View {
        HStack(spacing: 8) {
            TextField("Message Pace…", text: $draftMessageText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .focused($isChatInputFocused)
                .onSubmit(submitDraftMessageText)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
                        )
                )

            Button(action: submitDraftMessageText) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(
                        isDraftMessageTextEmpty ? DS.Colors.textTertiary : DS.Colors.accent
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isDraftMessageTextEmpty)
            .help("Send to Pace")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var isDraftMessageTextEmpty: Bool {
        draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Submits through `PaceChatSession.submitUserMessage`, which appends
    /// the optimistic user row and forwards into the SAME pipeline as
    /// voice (`CompanionManager.submitChatTranscriptFromChatSession`) —
    /// same intent classification, approval policy, and memory writes.
    private func submitDraftMessageText() {
        let trimmedDraftMessageText = draftMessageText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraftMessageText.isEmpty else { return }
        chatSession.submitUserMessage(trimmedDraftMessageText)
        draftMessageText = ""
        isChatInputFocused = true
    }
}
