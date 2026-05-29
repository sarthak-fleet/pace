//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession

    /// Optional: pre-load any heavy models so the first push-to-talk
    /// doesn't pay the cold-load cost. `onReady` is invoked on the
    /// MainActor exactly once when the model is fully loaded and the
    /// next session start won't block. Default no-op for backends with
    /// nothing to warm (e.g. Apple Speech).
    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void)
}

extension BuddyTranscriptionProvider {
    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void) {
        // Default: nothing to warm. Fire ready immediately so callers
        // gating PTT on this flag don't get stuck.
        Task { @MainActor in onReady() }
    }
}

enum BuddyTranscriptionProviderFactory {
    /// Apple Speech (`SFSpeechRecognizer`, on-device) is the only
    /// shipped provider. The protocol stays generic so a future
    /// alternate backend (e.g. WhisperKit, MLX-Whisper) can drop in
    /// as a sibling conformer.
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = AppleSpeechTranscriptionProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }
}
