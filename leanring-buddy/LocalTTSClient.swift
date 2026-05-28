//
//  LocalTTSClient.swift
//  leanring-buddy
//
//  On-device TTS via Apple's AVSpeechSynthesizer. No network calls,
//  free, private, and offline. The sole BuddyTTSClient conformer
//  today — install a Premium English voice (System Settings →
//  Accessibility → Spoken Content → System Voice → Manage Voices) for
//  the best quality.
//

import AVFoundation
import Foundation

@MainActor
final class LocalTTSClient: NSObject, BuddyTTSClient {
    private let speechSynthesizer = AVSpeechSynthesizer()

    // Tracks whether we have an utterance currently being spoken. We can't
    // rely solely on AVSpeechSynthesizer.isSpeaking because there's a brief
    // window between calling speak() and the audio actually starting where
    // isSpeaking returns false but playback is imminent. Without our own flag,
    // CompanionManager's `while ttsClient.isPlaying` poll would exit early.
    private var isCurrentlySpeakingOrPending = false

    /// The voice identifier to use. Defaults to the system "enhanced" or
    /// "premium" English voice when available, which is markedly better
    /// than the legacy compact voice.
    private let preferredVoiceIdentifier: String?
    private let speechRate: Float

    /// Cached `bestAvailableVoice()` result. `AVSpeechSynthesisVoice
    /// .speechVoices()` does a synchronous metadata scan that can take
    /// 50-200ms — calling it on every `speakText()` invocation (which
    /// happens once per sentence-chunk while streaming) shows up as
    /// the "Potential Structural Swift Concurrency Issue: unsafeForcedSync
    /// called from Swift Concurrent context" warning AND as visible
    /// per-chunk jank. Computed once on first use.
    private var memoizedBestVoice: AVSpeechSynthesisVoice?
    private var hasResolvedBestVoice: Bool = false

    /// The shared delegate that flips `isCurrentlySpeakingOrPending`
    /// back to false when AVSpeechSynthesizer finishes its queue. One
    /// observer for the synthesiser's whole lifetime (not per utterance)
    /// so completion callbacks aren't lost when streaming multiple
    /// utterances back to back.
    private var playbackCompletionObserver: LocalTTSPlaybackCompletionObserver?

    override init() {
        // Allow callers to override via Info.plist for experimentation.
        let configuredVoiceIdentifier = AppBundleConfiguration.stringValue(forKey: "LocalTTSVoiceIdentifier")
        self.preferredVoiceIdentifier = configuredVoiceIdentifier
        // 0.5 is AVSpeechUtteranceDefaultSpeechRate. Slightly faster reads
        // more naturally for conversational responses.
        self.speechRate = 0.52
        super.init()

        // Install the playback observer exactly once. AVSpeechSynthesizer
        // calls delegate methods on an arbitrary thread, so the observer
        // hops back to MainActor before touching this object's state.
        let observer = LocalTTSPlaybackCompletionObserver { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Only clear the pending flag if the synthesiser also
                // reports no more queued utterances — otherwise we'd
                // flip false between chunks of the same response.
                if !self.speechSynthesizer.isSpeaking {
                    self.isCurrentlySpeakingOrPending = false
                }
            }
        }
        self.playbackCompletionObserver = observer
        self.speechSynthesizer.delegate = observer
    }

    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Mark pending immediately so isPlaying returns true between this
        // call and the synthesizer actually starting audio output.
        isCurrentlySpeakingOrPending = true

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.rate = speechRate
        let pickedVoice = resolveCachedBestVoice()
        utterance.voice = pickedVoice
        printVoiceUpgradeHintOnceIfCompact(pickedVoice: pickedVoice)

        speechSynthesizer.speak(utterance)
        print("🔊 Local TTS: speaking \(trimmedText.count) chars")
    }

    /// Returns the best-available voice, computing it on first call and
    /// caching the result. The `AVSpeechSynthesisVoice.speechVoices()`
    /// scan inside `bestAvailableVoice()` is too expensive to do per
    /// utterance with sentence-level streaming.
    private func resolveCachedBestVoice() -> AVSpeechSynthesisVoice? {
        if hasResolvedBestVoice {
            return memoizedBestVoice
        }
        memoizedBestVoice = bestAvailableVoice()
        hasResolvedBestVoice = true
        return memoizedBestVoice
    }

    var isPlaying: Bool {
        isCurrentlySpeakingOrPending || speechSynthesizer.isSpeaking
    }

    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isCurrentlySpeakingOrPending = false
    }

    private func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        if let preferredVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier) {
            return voice
        }

        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }

        // Pace's curated picks, in order of preference. AVSpeechSynthesisVoice
        // .speechVoices() returns voices in registration order which can flip
        // across OS updates — that's how the voice got worse without anyone
        // touching the app. Pinning to a named voice keeps the pick stable.
        //
        // Ava and Evan are the Premium-quality neural voices Apple ships
        // separately (require a one-time download). Samantha is the
        // default en-US voice baked into macOS — Enhanced quality is also
        // downloadable, Premium is not available for Samantha. Including
        // her in the list lets us pick Samantha-Enhanced as a stopgap
        // when no premium-tier voice is installed yet.
        let preferredVoiceNamesInOrder = ["Ava", "Evan", "Samantha", "Zoe", "Nathan", "Joelle", "Noelle"]
        for preferredName in preferredVoiceNamesInOrder {
            if let namedPremiumVoice = englishVoices.first(where: {
                $0.name == preferredName && $0.quality == .premium
            }) {
                return namedPremiumVoice
            }
        }
        for preferredName in preferredVoiceNamesInOrder {
            if let namedEnhancedVoice = englishVoices.first(where: {
                $0.name == preferredName && $0.quality == .enhanced
            }) {
                return namedEnhancedVoice
            }
        }

        // Generic fallback: any premium > any enhanced > en-US default.
        if let premiumVoice = englishVoices.first(where: { $0.quality == .premium }) {
            return premiumVoice
        }
        if let enhancedVoice = englishVoices.first(where: { $0.quality == .enhanced }) {
            return enhancedVoice
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Prints a one-time, plain-language hint to the Xcode console when
    /// the system is falling back to a compact voice (the default
    /// "Samantha" tier that often sounds shrill / robotic). Users hear
    /// this and assume the app is broken; pointing them at Premium
    /// voices in System Settings fixes it without code change.
    private var hasPrintedVoiceUpgradeHint: Bool = false
    private func printVoiceUpgradeHintOnceIfCompact(pickedVoice: AVSpeechSynthesisVoice?) {
        guard !hasPrintedVoiceUpgradeHint else { return }
        guard let pickedVoice else { return }
        switch pickedVoice.quality {
        case .premium, .enhanced:
            print("🔊 Local TTS voice: \(pickedVoice.name) (\(pickedVoice.quality == .premium ? "Premium" : "Enhanced"))")
        default:
            print("🔊 Local TTS voice: \(pickedVoice.name) (Compact — sounds shrill)")
            print("    → To fix this, open System Settings → Accessibility → Spoken Content")
            print("      → System Voice → Manage Voices → English (US) and download EITHER:")
            print("        - \"Samantha\" at Enhanced quality (~150 MB, quick stopgap), OR")
            print("        - \"Ava\" at Premium quality (~500 MB, much better neural voice).")
            print("      Restart Pace after the download finishes.")
        }
        hasPrintedVoiceUpgradeHint = true
    }
}

private final class LocalTTSPlaybackCompletionObserver: NSObject, AVSpeechSynthesizerDelegate {
    private let onPlaybackFinishedOrCancelled: () -> Void

    init(onPlaybackFinishedOrCancelled: @escaping () -> Void) {
        self.onPlaybackFinishedOrCancelled = onPlaybackFinishedOrCancelled
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        onPlaybackFinishedOrCancelled()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        onPlaybackFinishedOrCancelled()
    }
}
