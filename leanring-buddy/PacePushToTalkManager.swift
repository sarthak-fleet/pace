//
//  PacePushToTalkManager.swift
//  leanring-buddy
//
//  Push-to-talk dictation manager. Captures microphone audio with
//  `AVAudioEngine`, routes it into the active transcription provider,
//  and hands the final draft back to `CompanionManager`.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        fileprivate var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    /// Resolved once at app launch from Info.plist key `PushToTalkShortcut`.
    /// Accepted values (case-insensitive, hyphens/underscores ignored):
    ///   - `controlOption`  / `ctrl+option`  / `ctrl-option`   (DEFAULT)
    ///   - `shiftFunction`  / `shift+fn`     / `shift-fn`
    ///   - `shiftControl`   / `shift+ctrl`   / `shift-ctrl`
    ///   - `controlOptionSpace` / `ctrl+option+space`
    ///   - `shiftControlSpace`  / `shift+ctrl+space`
    /// Unknown or missing values fall back to `controlOption`.
    /// Set this to something Wispr Flow / other dictation tools don't
    /// claim, so the two apps coexist cleanly.
    static let currentShortcutOption: ShortcutOption = {
        let rawConfiguredValue = AppBundleConfiguration
            .stringValue(forKey: "PushToTalkShortcut")?
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        switch rawConfiguredValue {
        case "shiftfunction", "shift+fn", "shiftfn":
            return .shiftFunction
        case "shiftcontrol", "shift+ctrl", "shift+control", "shiftctrl":
            return .shiftControl
        case "controloptionspace", "ctrl+option+space", "ctrloptionspace":
            return .controlOptionSpace
        case "shiftcontrolspace", "shift+ctrl+space", "shift+control+space":
            return .shiftControlSpace
        case "controloption", "ctrl+option", "ctrloption", .none:
            return .controlOption
        default:
            print("⚠️ Unknown PushToTalkShortcut '\(rawConfiguredValue ?? "nil")', falling back to ctrl+option")
            return .controlOption
        }
    }()
    static let pushToTalkKeyCode: UInt16 = 49 // Space

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        if let modifierOnlyFlags = currentShortcutOption.modifierOnlyFlags {
            guard shortcutEventType == .flagsChanged else { return .none }

            let isShortcutCurrentlyPressed = modifierFlags.contains(modifierOnlyFlags)

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard let pushToTalkModifierFlags = currentShortcutOption.spaceShortcutModifierFlags else {
            return .none
        }

        let matchesModifierFlags = modifierFlags.isSuperset(of: pushToTalkModifierFlags)

        if shortcutEventType == .keyDown
            && keyCode == pushToTalkKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .keyUp
            && keyCode == pushToTalkKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

/// Reason a listening window was opened — used by `openListeningWindow(...)`
/// so the call site can record provenance (PTT vs wake-word vs barge-in
/// vs deeplink) without needing a separate state variable. Wave 1c only
/// uses `.bargeIn`; Wave 2 will populate `.wakeWord`. The plan deliberately
/// shapes the API ahead of the dependent wave so the wake-word work can
/// hand intent in without touching the manager.
enum PaceListeningTrigger {
    case userPushToTalk
    case wakeWord
    case bargeIn
    case deeplink
}

private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
}

private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (String) -> Void
    let submitDraftText: (String) -> Void
    /// Fired when a stable partial transcript matches a deterministic
    /// fast-action command (e.g. "open Music"). The action can start
    /// before PTT release, saving ~200-500ms of perceived latency.
    /// The final transcript is still checked — if it differs from the
    /// speculative partial, the normal path runs.
    let speculativeFastAction: ((String) -> Void)?
}

@MainActor
final class PacePushToTalkManager: NSObject, ObservableObject {
    private static let defaultFinalTranscriptFallbackDelaySeconds: TimeInterval = 2.4
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.07

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: PacePushToTalkManager.recordedAudioPowerHistoryBaselineLevel,
        count: PacePushToTalkManager.recordedAudioPowerHistoryLength
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    @Published private(set) var latestStablePartialTranscript = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecordingFromMicrophoneButton || isRecordingFromKeyboardShortcut || isFinalizingTranscript
    }

    var needsInitialPermissionPrompt: Bool {
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    let transcriptionProvider: any BuddyTranscriptionProvider
    private let audioEngine = AVAudioEngine()
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?

    /// Per-callback normalized RMS publisher for the active audio tap.
    /// Subscribers (e.g. the barge-in VAD wired through CompanionManager)
    /// receive the SAME computed values the waveform UI sees — there is
    /// only ONE AVAudioEngine tap, and we route the existing per-buffer
    /// RMS into this publisher. Holding zero buffered audio is deliberate:
    /// the VAD computes its decision per-sample and the buffer is
    /// discarded on the next tap callback.
    ///
    /// `PassthroughSubject` (not `CurrentValueSubject`) because the
    /// subscriber should ONLY observe energy while the tap is live —
    /// stale "last RMS" values from a finished recording must not
    /// retroactively fire the VAD on a fresh subscription.
    let audioLevelPublisher = PassthroughSubject<Float, Never>()

    /// Tracks an open "listening window" requested by an external trigger
    /// (wake word, barge-in, deeplink) so the manager can guarantee at-
    /// most-one window is active and prefer push-to-talk over everything
    /// else. The window doesn't actually start audio capture — that work
    /// lives in `startPushToTalkFromKeyboardShortcut` / future wake-word
    /// path. The window exists as a contract: while it's open, callers
    /// know the manager is "expecting voice input" and will treat the
    /// next transcript as a turn.
    private var activeListeningWindowTrigger: PaceListeningTrigger?
    private var activeListeningWindowAutoCloseWorkItem: DispatchWorkItem?

    // Per-session diagnostics for the "No speech detected" failure
    // mode. If the recogniser reports no speech but we appended N
    // buffers with non-trivial peak RMS, the audio path is fine and
    // the problem is the recogniser. If buffer count is 0 or peak is
    // ~0, the mic / tap isn't delivering audio at all.
    private var sessionBufferAppendedCount: Int = 0
    private var sessionPeakAudioRMS: Float = 0
    private var sessionAudioStartedAt: Date?
    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    private var localAgreementStabilizer = PaceLocalAgreementStabilizer()
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    private var pendingStartRequestIdentifier = UUID()
    private var lastRecordedAudioPowerSampleDate = Date.distantPast
    private var activePermissionRequestTask: Task<Bool, Never>?
    /// Timestamp of the last completed permission request, used to debounce
    /// rapid follow-up requests that arrive before macOS updates its cache.
    private var lastPermissionRequestCompletedAt: Date?

    /// Lazy stream close: after PTT release, the AVAudioEngine is kept
    /// running (tap removed, session cancelled) for this many seconds so
    /// the next PTT press skips engine.prepare()+start(). Saves ~100-200ms
    /// on back-to-back commands. Generation counter cancels pending
    /// closes if a new session starts before the timeout fires.
    private let lazyCloseDelaySeconds: TimeInterval = 30.0
    private var lazyCloseWorkItem: DispatchWorkItem?
    private var lazyCloseGeneration: Int = 0
    private var isAudioEngineKeptWarm: Bool = false

    /// Speculative fast-action: tracks the stable partial that was
    /// speculatively executed so the final transcript can be checked
    /// against it. If they match, the normal path is skipped.
    private var speculativeExecutedTranscript: String?
    /// Minimum word count in a stable partial before we trust it
    /// enough to speculatively execute. 2 words catches "open Music",
    /// "volume up", "undo that" while avoiding false triggers on
    /// single-word partials like "open".
    private let speculativeMinWordCount = 2

    override init() {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        super.init()
    }

    func startPushToTalkFromKeyboardShortcut(
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        speculativeFastAction: ((String) -> Void)? = nil
    ) async {
        await startPushToTalk(
            startSource: .keyboardShortcut,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldAutomaticallySubmitFinalDraftOnStop: currentDraftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
            speculativeFastAction: speculativeFastAction
        )
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    /// Opens a listening window of the given duration on behalf of an
    /// external trigger (wake word, barge-in, deeplink). PTT always wins:
    /// if a window is already open and a non-PTT trigger arrives, the
    /// existing window stays as-is. The window auto-closes after
    /// `durationInSeconds` or sooner when a transcript is finalized
    /// (signalled today by resetSessionState() clearing
    /// `activeListeningWindowTrigger`). In Wave 1c this method is the
    /// barge-in handoff point — it doesn't itself start audio capture;
    /// the actual restart path (wake-word or PTT) is responsible for
    /// engine setup. Wave 2 wires the wake-word path through this same
    /// method.
    func openListeningWindow(durationInSeconds: Double, trigger: PaceListeningTrigger) {
        // Push-to-talk wins. If the user is already holding the key,
        // any non-PTT trigger is a redundant signal — ignore it so we
        // don't reset the existing window's auto-close clock.
        if let activeListeningWindowTrigger,
           activeListeningWindowTrigger == .userPushToTalk,
           trigger != .userPushToTalk {
            return
        }

        activeListeningWindowAutoCloseWorkItem?.cancel()
        activeListeningWindowTrigger = trigger

        let autoCloseWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.closeListeningWindowIfActive(trigger: trigger)
            }
        }
        activeListeningWindowAutoCloseWorkItem = autoCloseWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + durationInSeconds,
            execute: autoCloseWorkItem
        )
    }

    /// Test-only read of which trigger (if any) currently owns the
    /// listening window. Exposed `internal` because the integration
    /// tests verify that PTT can't be displaced by barge-in.
    var currentListeningWindowTrigger: PaceListeningTrigger? {
        activeListeningWindowTrigger
    }

    private func closeListeningWindowIfActive(trigger: PaceListeningTrigger) {
        // Only close if this trigger is still the active one — a
        // newer trigger may have arrived and replaced it.
        guard activeListeningWindowTrigger == trigger else { return }
        activeListeningWindowTrigger = nil
        activeListeningWindowAutoCloseWorkItem = nil
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        pendingStartRequestIdentifier = UUID()

        guard isDictationInProgress else { return }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if preserveDraftText {
            let currentDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
            draftCallbacks?.updateDraftText(currentDraftText)
        }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.cancel()
        logSessionAudioDiagnostics(reason: "cancel")
        cancelLazyEngineClose()
        isAudioEngineKeptWarm = false

        resetSessionState()
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        currentDraftText: String,
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool,
        speculativeFastAction: ((String) -> Void)? = nil
    ) async {
        guard !isDictationInProgress else { return }

        print("🎙️ PacePushToTalkManager: start requested (\(startSource))")

        if needsInitialPermissionPrompt {
            print("🎙️ PacePushToTalkManager: requesting initial permissions")
            NSApplication.shared.activate(ignoringOtherApps: true)

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // If the task is cancelled while the app is being activated,
                // we can safely continue into the permission request.
            }
        }

        let startRequestIdentifier = UUID()
        pendingStartRequestIdentifier = startRequestIdentifier

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() else {
            print("🎙️ PacePushToTalkManager: permissions missing or denied")
            isPreparingToRecord = false
            return
        }
        guard !Task.isCancelled else {
            print("🎙️ PacePushToTalkManager: start cancelled (shortcut released during permission check)")
            isPreparingToRecord = false
            return
        }
        guard pendingStartRequestIdentifier == startRequestIdentifier else {
            print("🎙️ PacePushToTalkManager: start request superseded")
            isPreparingToRecord = false
            return
        }

        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        latestStablePartialTranscript = ""
        localAgreementStabilizer.reset()
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            speculativeFastAction: speculativeFastAction
        )
        activeStartSource = startSource
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast

        guard !Task.isCancelled else {
            print("🎙️ PacePushToTalkManager: start cancelled (shortcut released before recording began)")
            resetSessionState()
            return
        }

        do {
            try await startRecognitionSession()
            guard !Task.isCancelled else {
                print("🎙️ PacePushToTalkManager: start cancelled (shortcut released during session start)")
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
                activeTranscriptionSession?.cancel()
                cancelLazyEngineClose()
                isAudioEngineKeptWarm = false
                resetSessionState()
                return
            }
            if startSource == .microphoneButton {
                microphoneButtonRecordingStartedAt = Date()
            }
            isPreparingToRecord = false
            print("🎙️ PacePushToTalkManager: recognition session started")
        } catch {
            isPreparingToRecord = false
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't start voice input. try again."
            )
            print("❌ PacePushToTalkManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")
            resetSessionState()
        }
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard activeStartSource == expectedStartSource else {
            isPreparingToRecord = false
            return
        }
        guard !isFinalizingTranscript else { return }

        print("🎙️ PacePushToTalkManager: stop requested (\(expectedStartSource))")

        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = true

        let finalTranscriptFallbackDelaySeconds = activeTranscriptionSession?.finalTranscriptFallbackDelaySeconds
            ?? Self.defaultFinalTranscriptFallbackDelaySeconds

        // Lazy stream close: remove the tap and request the final
        // transcript, but DON'T stop the engine — schedule a delayed
        // stop so the next PTT press within 30s skips engine init.
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.requestFinalTranscript()
        logSessionAudioDiagnostics(reason: "PTT-release")
        scheduleLazyEngineClose()

        finalizeFallbackWorkItem?.cancel()
        let shouldSubmitFinalDraftWhenFallbackTriggers = shouldAutomaticallySubmitFinalDraft
        let fallbackWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.finishCurrentDictationSessionIfNeeded(
                    shouldSubmitFinalDraft: shouldSubmitFinalDraftWhenFallbackTriggers
                )
            }
        }
        finalizeFallbackWorkItem = fallbackWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + finalTranscriptFallbackDelaySeconds,
            execute: fallbackWorkItem
        )
    }

    private func startRecognitionSession() async throws {
        // Cancel any pending lazy engine close — the engine is about
        // to be reused for this new session.
        cancelLazyEngineClose()
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        print("🎙️ PacePushToTalkManager: opening transcription provider \(transcriptionProvider.displayName)")
        let contextualPhrases = PaceTranscriptionContextualPhraseBuilder.phrasesForCurrentTurn()
        if !contextualPhrases.isEmpty {
            print("🎙️ PacePushToTalkManager: biasing transcription with \(contextualPhrases.count) local phrases")
        }

        let activeTranscriptionSession = try await transcriptionProvider.startStreamingSession(
            contextualPhrases: contextualPhrases,
            onTranscriptUpdate: { [weak self] transcriptText in
                Task { @MainActor in
                    self?.handlePartialTranscriptUpdate(transcriptText)
                }
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                Task { @MainActor in
                    guard let self else { return }
                    self.latestRecognizedText = transcriptText

                    if self.isFinalizingTranscript {
                        self.finishCurrentDictationSessionIfNeeded(
                            shouldSubmitFinalDraft: self.shouldAutomaticallySubmitFinalDraft
                        )
                    }
                }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.handleRecognitionError(error)
                }
            }
        )

        self.activeTranscriptionSession = activeTranscriptionSession
        print("🎙️ PacePushToTalkManager: provider ready, starting audio engine")

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("🎙️ PacePushToTalkManager: input format \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        sessionBufferAppendedCount = 0
        sessionPeakAudioRMS = 0
        sessionAudioStartedAt = Date()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.activeTranscriptionSession?.appendAudioBuffer(buffer)
            self.updateAudioPowerLevel(from: buffer)
            self.recordSessionAudioBufferDiagnostics(from: buffer)
        }

        // Lazy stream close: if the engine is still running from a
        // previous turn (within the 30s lazy-close window), skip the
        // prepare+start cycle — saves ~100-200ms on back-to-back PTT.
        if isAudioEngineKeptWarm && audioEngine.isRunning {
            print("🎙️ PacePushToTalkManager: engine already warm — skipping prepare+start")
        } else {
            audioEngine.prepare()
            try audioEngine.start()
            isAudioEngineKeptWarm = true
        }
    }

    private func handlePartialTranscriptUpdate(_ transcriptText: String) {
        latestRecognizedText = transcriptText

        let stablePartialTranscript = localAgreementStabilizer.acceptHypothesis(transcriptText)
        guard stablePartialTranscript != latestStablePartialTranscript else { return }

        latestStablePartialTranscript = stablePartialTranscript
        guard !stablePartialTranscript.isEmpty else { return }

        let stableDraftText = composeDraftText(withTranscribedText: stablePartialTranscript)
        draftCallbacks?.updateDraftText(stableDraftText)

        // Speculative fast-action: if the stable partial is long enough
        // and matches a deterministic fast-action command, fire it
        // immediately — before PTT release. This saves ~200-500ms of
        // perceived latency for common commands like "open Music" or
        // "volume up". Only fires once per session.
        checkSpeculativeFastAction(stablePartialTranscript)
    }

    /// Check if a stable partial transcript matches a deterministic
    /// fast-action command. If so, fire the speculative callback so
    /// the action starts before PTT release.
    private func checkSpeculativeFastAction(_ stablePartial: String) {
        // Only fire once per session.
        guard speculativeExecutedTranscript == nil else { return }
        guard let callbacks = draftCallbacks, callbacks.speculativeFastAction != nil else { return }

        // Require at least N words to avoid false triggers on partials
        // like "open" or "volume" that could be the start of a longer
        // command.
        let wordCount = stablePartial.split(separator: " ").count
        guard wordCount >= speculativeMinWordCount else { return }

        // Run the same deterministic parser the normal path uses.
        // If it matches, the command is safe to execute speculatively
        // because fast-action commands are all reversible.
        guard PaceFastActionCommandParser.parse(transcript: stablePartial) != nil else { return }

        speculativeExecutedTranscript = stablePartial
        print("⚡️ Speculative fast-action on stable partial: \"\(stablePartial)\"")
        callbacks.speculativeFastAction?(stablePartial)
    }

    /// Track how much real audio we delivered to the recogniser this
    /// session. Surfaced when the session ends so "No speech detected"
    /// failures have a number to look at: zero buffers = mic / tap
    /// broken; many buffers but ~0 peak = mic muted or in wrong route.
    private func recordSessionAudioBufferDiagnostics(from buffer: AVAudioPCMBuffer) {
        sessionBufferAppendedCount += 1
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        var sumOfSquares: Float = 0
        for sampleIndex in 0..<frameLength {
            let sampleValue = channelData[sampleIndex]
            sumOfSquares += sampleValue * sampleValue
        }
        let rootMeanSquare = (sumOfSquares / Float(frameLength)).squareRoot()
        if rootMeanSquare > sessionPeakAudioRMS {
            sessionPeakAudioRMS = rootMeanSquare
        }
    }

    /// Print a one-line summary of the audio that flowed during this
    /// session. Called from `finishCurrentDictationSessionIfNeeded`
    /// and `cancelCurrentDictation` so every session end produces a
    /// diagnostic row.
    private func logSessionAudioDiagnostics(reason: String) {
        guard let startedAt = sessionAudioStartedAt else { return }
        let elapsedSeconds = Date().timeIntervalSince(startedAt)
        let elapsedMs = Int(elapsedSeconds * 1000)
        print("📊 Audio session \(reason): \(sessionBufferAppendedCount) buffers / peak RMS \(String(format: "%.4f", sessionPeakAudioRMS)) / elapsed \(elapsedMs)ms")
        sessionAudioStartedAt = nil
    }

    private func handleRecognitionError(_ error: Error) {
        if hasFinishedCurrentDictationSession {
            return
        }

        if isFinalizingTranscript && !latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft
            )
        } else {
            print("❌ Buddy dictation error (\(transcriptionProvider.displayName)): \(error)")
            lastErrorMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't transcribe that. try again."
            )
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func finishCurrentDictationSessionIfNeeded(shouldSubmitFinalDraft: Bool) {
        guard !hasFinishedCurrentDictationSession else { return }
        hasFinishedCurrentDictationSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let finalDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
        let finalTranscriptText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDraftCallbacks = draftCallbacks

        if !shouldSubmitFinalDraft && !finalDraftText.isEmpty {
            currentDraftCallbacks?.updateDraftText(finalDraftText)
        }

        // Lazy stream close: remove tap + cancel session, but defer
        // the engine stop so a quick follow-up PTT is faster.
        audioEngine.inputNode.removeTap(onBus: 0)
        activeTranscriptionSession?.cancel()
        scheduleLazyEngineClose()

        resetSessionState()

        guard shouldSubmitFinalDraft else { return }
        guard !finalTranscriptText.isEmpty else { return }

        // Speculative fast-action: if the final transcript matches
        // the speculative partial, the action already executed via
        // the speculativeFastAction callback — skip submitDraftText
        // entirely to avoid double-execution. The CompanionManager
        // already spoke the confirmation and updated UI.
        if let speculative = speculativeExecutedTranscript,
           finalTranscriptText.lowercased() == speculative.lowercased() {
            print("⚡️ Speculative fast-action confirmed — skipping normal submit (action already executed)")
            return
        }

        // If a speculative action fired but the final transcript
        // differs, the speculative action was a subset (e.g., "open
        // Music" when the full command was "open Music and play next
        // song"). The normal path runs — the planner sees the action
        // was already partially done and handles the rest.
        currentDraftCallbacks?.submitDraftText(finalDraftText)
    }

    private func composeDraftText(withTranscribedText transcribedText: String) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return draftTextBeforeCurrentDictation
        }

        let trimmedExistingDraftText = draftTextBeforeCurrentDictation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if draftTextBeforeCurrentDictation.hasSuffix(" ") || draftTextBeforeCurrentDictation.hasSuffix("\n") {
            return draftTextBeforeCurrentDictation + trimmedTranscriptText
        }

        return draftTextBeforeCurrentDictation + " " + trimmedTranscriptText
    }

    /// Schedule a delayed engine stop. If the user presses PTT again
    /// before the timeout fires, `cancelLazyEngineClose` (called from
    /// `startRecognitionSession`) cancels the pending stop and the
    /// engine stays warm. Generation counter prevents a stale close
    /// from stopping the engine after a new session has started.
    private func scheduleLazyEngineClose() {
        cancelLazyEngineClose()
        lazyCloseGeneration += 1
        let generation = lazyCloseGeneration
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Only stop if no new session has started since we
                // scheduled this close.
                guard self.lazyCloseGeneration == generation else { return }
                if self.audioEngine.isRunning {
                    self.audioEngine.stop()
                    print("🎙️ PacePushToTalkManager: lazy engine close after \(self.lazyCloseDelaySeconds)s idle")
                }
                self.isAudioEngineKeptWarm = false
            }
        }
        lazyCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + lazyCloseDelaySeconds, execute: workItem)
    }

    /// Cancel a pending lazy engine close. Called when a new PTT
    /// session starts so the engine stays warm.
    private func cancelLazyEngineClose() {
        lazyCloseWorkItem?.cancel()
        lazyCloseWorkItem = nil
        // Bump generation so any in-flight close work item is invalidated.
        lazyCloseGeneration += 1
    }

    private func resetSessionState() {
        pendingStartRequestIdentifier = UUID()
        // A transcript finalize closes any open listening window per the
        // Wave 1c contract — "auto-closes after durationInSeconds OR when
        // transcript is finalized, whichever first."
        activeListeningWindowAutoCloseWorkItem?.cancel()
        activeListeningWindowAutoCloseWorkItem = nil
        activeListeningWindowTrigger = nil
        activeTranscriptionSession = nil
        draftCallbacks = nil
        activeStartSource = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        latestStablePartialTranscript = ""
        localAgreementStabilizer.reset()
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false
        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast
        speculativeExecutedTranscript = nil
    }

    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        // Wave 1c barge-in: emit the per-callback raw RMS so the
        // CompanionManager-owned VAD can decide on speech onset while
        // TTS is playing. We publish on the audio thread (the tap
        // callback runs there); subscribers in CompanionManager hop
        // back to the MainActor inside their sink. This avoids holding
        // a second buffer copy in memory or spinning up a second tap.
        audioLevelPublisher.send(rootMeanSquare)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let smoothedAudioPowerLevel = max(
                CGFloat(boostedLevel),
                self.currentAudioPowerLevel * 0.72
            )
            self.currentAudioPowerLevel = smoothedAudioPowerLevel

            let now = Date()
            if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                self.lastRecordedAudioPowerSampleDate = now
                self.appendRecordedAudioPowerSample(
                    max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                )
            }
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }

        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return true
        }

        let hasSpeechRecognitionPermission = await requestSpeechRecognitionPermissionIfNeeded()
        guard hasSpeechRecognitionPermission else {
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }

        return true
    }

    /// macOS can show the microphone/speech sheet again if we accidentally fan out
    /// multiple permission requests before the first one finishes. We keep exactly
    /// one in-flight request task so rapid repeat presses all await the same result.
    ///
    /// After the task completes, we skip re-requesting for a short cooldown period
    /// so macOS has time to update its authorization cache. This prevents the
    /// permission dialog from popping up again on rapid follow-up presses.
    private func requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() async -> Bool {
        // If a permission request is already in-flight, reuse it.
        if let activePermissionRequestTask {
            return await activePermissionRequestTask.value
        }

        // If we just finished a permission request very recently, skip re-requesting.
        // macOS can briefly report .notDetermined even after the user tapped Allow,
        // so we trust the cached result for a short window.
        if let lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(lastPermissionRequestCompletedAt) < 1.0 {
            return AVCaptureDevice.authorizationStatus(for: .audio) != .denied
                && AVCaptureDevice.authorizationStatus(for: .audio) != .restricted
        }

        let permissionRequestTask = Task { @MainActor in
            await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }

        activePermissionRequestTask = permissionRequestTask

        let hasPermissions = await permissionRequestTask.value
        activePermissionRequestTask = nil
        lastPermissionRequestCompletedAt = Date()
        return hasPermissions
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus == .authorized)
                }
            }
            currentPermissionProblem = isGranted ? nil : .speechRecognitionDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        @unknown default:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        }
    }

    private func userFacingErrorMessage(from error: Error, fallback: String) -> String {
        if let localizedError = error as? LocalizedError,
           let errorDescription = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !errorDescription.isEmpty {
            return errorDescription
        }

        let errorDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorDescription.isEmpty,
           errorDescription != "The operation couldn’t be completed." {
            return errorDescription
        }

        return fallback
    }
}
