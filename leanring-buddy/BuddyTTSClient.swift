//
//  BuddyTTSClient.swift
//  leanring-buddy
//
//  Shared protocol surface for text-to-speech backends. Two conformers:
//  LocalTTSClient (AVSpeechSynthesizer, always available) and
//  LocalServerTTSClient (loopback OpenAI-compatible /v1/audio/speech —
//  Kokoro by default — which itself falls back to LocalTTSClient
//  whenever the sidecar is unavailable).
//

import Foundation

/// Why TTS playback ended. Read by `CompanionManager` to include in the
/// paceHistory log line for an interrupted turn — barge-in flips
/// `lastStopReason` to `.userBargeIn`, manual stop (the overlay's stop
/// button) flips it to `.manualStop`, normal completion is
/// `.naturalCompletion`. Wave 1c only differentiates barge-in vs
/// natural completion at the call site; the third case keeps the API
/// honest for the existing manual-stop path.
enum PaceTTSStopReason: Equatable {
    case naturalCompletion
    case userBargeIn
    case manualStop
}

@MainActor
protocol BuddyTTSClient: AnyObject {
    /// Speaks `text` and returns when audio playback has started (not
    /// when it has finished). The caller polls `isPlaying` to detect
    /// completion.
    func speakText(_ text: String) async throws

    /// Whether speech audio is currently being played out of the device.
    var isPlaying: Bool { get }

    /// Stops any in-progress speech immediately. Safe to call when
    /// nothing is playing.
    func stopPlayback()

    /// Why playback last ended. Set by the client on every stop path —
    /// natural delegate callback, `stopPlayback()`, or the barge-in
    /// drain path. Defaults to `.naturalCompletion` before any
    /// playback has happened. Read by `CompanionManager` when
    /// journaling an interrupted turn.
    var lastStopReason: PaceTTSStopReason { get }

    /// Sets the next stop reason. Called by the streaming pipeline's
    /// barge-in drain just before `stopPlayback()` so the manager's
    /// post-stop read sees `.userBargeIn` instead of `.manualStop`.
    /// Implementations store the value and propagate it on the next
    /// stop event.
    func recordExpectedStopReason(_ reason: PaceTTSStopReason)
}

enum BuddyTTSClientFactory {
    @MainActor
    static func makeDefault() -> any BuddyTTSClient {
        // Bundled Qwen3 TTS trumps the configured Kokoro-sidecar
        // path when the user has opted in AND TTSKit is linked. This
        // drops the Python sidecar dependency from the setup story.
        if PaceBundledModelsSettings.isUsingQwen3TTSInProcess() {
            print("🔊 TTS: using bundled Qwen3 TTS (TTSKit in-process)")
            return PaceQwen3TTSClient()
        }

        let configuredProvider = AppBundleConfiguration
            .stringValue(forKey: "TTSProvider")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // `localServer` is the default: when no sidecar is running it
        // degrades to the Apple voice within milliseconds per turn, so the
        // upgrade is free to opt out of and automatic to opt into.
        if configuredProvider == "apple" {
            print("🔊 TTS: using local AVSpeechSynthesizer")
            return LocalTTSClient()
        }
        return LocalServerTTSClient()
    }
}
