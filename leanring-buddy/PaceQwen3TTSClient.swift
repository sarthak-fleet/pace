//
//  PaceQwen3TTSClient.swift
//  leanring-buddy
//
//  Phase D: in-process TTS via WhisperKit's `TTSKit` module (Qwen3
//  TTS by default — fully Swift-native, ANE-accelerated, no Python
//  sidecar). Conforms to `BuddyTTSClient` so the existing
//  CompanionManager TTS pipeline consumes it unchanged.
//
//  When TTSKit is linked AND the user has opted into bundled TTS,
//  this client takes over speech synthesis. Otherwise the factory
//  falls back to `LocalServerTTSClient` (the Kokoro sidecar) →
//  `LocalTTSClient` (Apple AVSpeechSynthesizer) — pre-Phase-D
//  behaviour intact.
//
//  Why Qwen3 TTS over Kokoro: TTSKit is already shipped as a
//  product in the WhisperKit package Pace already depends on. No
//  3-week port of the Kokoro StyleTTS2 architecture is required —
//  Qwen3 TTS comes with a finished Swift implementation, voice
//  selection, ANE inference, and audio output.
//
//  Failure posture: any TTSKit load or generation failure flows
//  through `BuddyTTSClientFactory`'s normal fallback chain so the
//  user always hears SOMETHING (AVSpeechSynthesizer is the
//  universal floor).
//

import Foundation

#if canImport(TTSKit)
@preconcurrency import TTSKit
#endif

nonisolated enum PaceQwen3TTSError: LocalizedError {
    case runtimeNotLinked
    case modelLoadFailed(underlyingErrorDescription: String)
    case synthesisFailed(underlyingErrorDescription: String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotLinked:
            return "TTSKit not linked. Add the TTSKit product from the WhisperKit SPM package."
        case .modelLoadFailed(let underlyingErrorDescription):
            return "Qwen3 TTS model load failed: \(underlyingErrorDescription)"
        case .synthesisFailed(let underlyingErrorDescription):
            return "Qwen3 TTS synthesis failed: \(underlyingErrorDescription)"
        }
    }
}

@MainActor
final class PaceQwen3TTSClient: BuddyTTSClient {

    nonisolated static var isRuntimeAvailable: Bool {
        #if canImport(TTSKit)
        return true
        #else
        return false
        #endif
    }

    var isPlaying: Bool {
        #if canImport(TTSKit)
        return isCurrentlySpeakingOrPending
        #else
        return false
        #endif
    }

    private(set) var lastStopReason: PaceTTSStopReason = .naturalCompletion
    private var expectedNextStopReason: PaceTTSStopReason?

    /// Mirrors LocalTTSClient's `isCurrentlySpeakingOrPending` flag —
    /// flips true the instant `speakText` is invoked so the
    /// CompanionManager poll loop sees playback as active from t=0,
    /// before TTSKit has finished loading models or rendering the
    /// first audio chunk.
    private var isCurrentlySpeakingOrPending: Bool = false

    /// Per-turn current playback Task — cancelled on stopPlayback() so
    /// barge-in can interrupt mid-utterance.
    private var currentPlaybackTask: Task<Void, Never>?

    func speakText(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        #if canImport(TTSKit)
        // Mark active synchronously so the manager's poll loop sees
        // us as speaking from t=0 — same contract as LocalTTSClient.
        isCurrentlySpeakingOrPending = true
        // Cancel any prior utterance — TTSKit's play() blocks the
        // task, so we drop the previous one first.
        currentPlaybackTask?.cancel()

        let textCopy = trimmed
        let ttsSession: TTSKit
        do {
            ttsSession = try await Self.sharedTTSSession()
        } catch {
            isCurrentlySpeakingOrPending = false
            throw PaceQwen3TTSError.modelLoadFailed(
                underlyingErrorDescription: error.localizedDescription
            )
        }

        // Detach into a Task so this method returns when playback
        // has STARTED (matching the protocol) rather than when it
        // has finished. The Task drives the audio out on TTSKit's
        // internal output queue.
        currentPlaybackTask = Task { @MainActor [weak self] in
            do {
                _ = try await ttsSession.play(
                    text: textCopy,
                    voice: nil,
                    language: nil,
                    options: GenerationOptions(),
                    playbackStrategy: .auto,
                    callback: nil
                )
                // Natural completion — propagate the stop-reason
                // contract used by LocalTTSClient.
                if let self {
                    self.lastStopReason = self.expectedNextStopReason ?? .naturalCompletion
                    self.expectedNextStopReason = nil
                    self.isCurrentlySpeakingOrPending = false
                }
            } catch {
                // Task cancellation propagates as an error in some
                // TTSKit configurations — treat that as manual stop.
                if Task.isCancelled {
                    if let self {
                        self.lastStopReason = self.expectedNextStopReason ?? .manualStop
                        self.expectedNextStopReason = nil
                        self.isCurrentlySpeakingOrPending = false
                    }
                } else {
                    print("⚠️ Qwen3 TTS synthesis failed: \(error.localizedDescription)")
                    if let self {
                        self.lastStopReason = .naturalCompletion
                        self.expectedNextStopReason = nil
                        self.isCurrentlySpeakingOrPending = false
                    }
                }
            }
        }
        #else
        _ = trimmed
        throw PaceQwen3TTSError.runtimeNotLinked
        #endif
    }

    func stopPlayback() {
        #if canImport(TTSKit)
        currentPlaybackTask?.cancel()
        currentPlaybackTask = nil
        // Best-effort stop on the underlying audio output. TTSKit's
        // playback queue drains itself when the task is cancelled.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let session = await Self.peekSharedTTSSessionIfLoaded() {
                await session.audioOutput.stopPlayback(waitForCompletion: false)
            }
            if self.expectedNextStopReason == nil {
                self.expectedNextStopReason = .manualStop
            }
            self.isCurrentlySpeakingOrPending = false
        }
        #endif
    }

    func recordExpectedStopReason(_ reason: PaceTTSStopReason) {
        expectedNextStopReason = reason
    }

    #if canImport(TTSKit)
    /// One shared TTSKit instance per process. TTSKit's model assets
    /// (~250 MB) load once then stay resident; constructing it twice
    /// would double-pay the load cost.
    private static let sessionLock = NSLock()
    private static var cachedTTSSession: TTSKit?

    private static func sharedTTSSession() async throws -> TTSKit {
        sessionLock.lock()
        let cached = cachedTTSSession
        sessionLock.unlock()
        if let cached { return cached }

        let config = TTSKitConfig()
        let session = try await TTSKit(config)
        try await session.loadModels()

        sessionLock.lock()
        cachedTTSSession = session
        sessionLock.unlock()
        return session
    }

    private static func peekSharedTTSSessionIfLoaded() async -> TTSKit? {
        sessionLock.lock()
        let cached = cachedTTSSession
        sessionLock.unlock()
        return cached
    }
    #endif
}
