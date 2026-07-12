//
//  PaceAppleSpeechWakeWordSpotterTests.swift
//  leanring-buddyTests
//
//  Wave 2b — unit tests for `PaceAppleSpeechWakeWordSpotter`. The
//  real `SFSpeechRecognizer` cannot be unit-tested with audio
//  (no mic in CI), so we exercise the spotter through its internal
//  test seam `didReceiveTranscriptionForTesting(_:averageSegmentConfidence:)`.
//  That method funnels into the same `evaluateTranscription(...)` path
//  the real recognizer callback uses, so any assertion we make here
//  about confidence + phrase-match + rolling-buffer-nil behaviour
//  applies in production too.
//

import Combine
import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceAppleSpeechWakeWordSpotterTests {

    // MARK: - Confidence gate

    /// Confidence below 0.7 → no detection event. The spotter still
    /// processes the transcript (rolling buffer is touched + nil'd)
    /// but the publisher never fires.
    @Test
    func confidenceBelowThresholdDoesNotFireDetection() {
        let spotter = PaceAppleSpeechWakeWordSpotter()
        var receivedDetections: [PaceWakeWordDetection] = []
        let subscription = spotter.wakeWordDetectedPublisher.sink { detection in
            receivedDetections.append(detection)
        }

        spotter.didReceiveTranscriptionForTesting(
            "hey pace",
            averageSegmentConfidence: 0.6
        )

        #expect(receivedDetections.isEmpty)
        #expect(spotter.currentAudioBufferForTesting == nil)
        subscription.cancel()
    }

    /// Confidence above 0.7 with the canonical "hey pace" phrase
    /// fires exactly once with the matched phrase + confidence
    /// preserved in the emitted event.
    @Test
    func confidenceAboveThresholdWithTriggerPhraseFiresDetection() {
        let spotter = PaceAppleSpeechWakeWordSpotter()
        var receivedDetections: [PaceWakeWordDetection] = []
        let subscription = spotter.wakeWordDetectedPublisher.sink { detection in
            receivedDetections.append(detection)
        }

        spotter.didReceiveTranscriptionForTesting(
            "hey pace can you hear me",
            averageSegmentConfidence: 0.9
        )

        #expect(receivedDetections.count == 1)
        #expect(receivedDetections.first?.phraseMatched == "hey pace")
        #expect(receivedDetections.first?.confidence == 0.9)
        subscription.cancel()
    }

    /// High confidence but no trigger phrase → no detection. Guards
    /// against the spotter firing on every loud syllable.
    @Test
    func highConfidenceWithoutTriggerPhraseDoesNotFireDetection() {
        let spotter = PaceAppleSpeechWakeWordSpotter()
        var receivedDetections: [PaceWakeWordDetection] = []
        let subscription = spotter.wakeWordDetectedPublisher.sink { detection in
            receivedDetections.append(detection)
        }

        spotter.didReceiveTranscriptionForTesting(
            "the weather forecast looks great today",
            averageSegmentConfidence: 0.95
        )

        #expect(receivedDetections.isEmpty)
        subscription.cancel()
    }

    // MARK: - Phrase whole-word semantics

    /// "spacebar" must NOT trigger the bare "pace" phrase. The
    /// matcher uses word-boundary rules so substring-only hits don't
    /// accidentally arm the assistant.
    @Test
    func substringMatchDoesNotTriggerForBarePacePhrase() {
        let spotter = PaceAppleSpeechWakeWordSpotter()
        var receivedDetections: [PaceWakeWordDetection] = []
        let subscription = spotter.wakeWordDetectedPublisher.sink { detection in
            receivedDetections.append(detection)
        }

        spotter.didReceiveTranscriptionForTesting(
            "spacebar pressed twice",
            averageSegmentConfidence: 0.9
        )

        #expect(receivedDetections.isEmpty)
        subscription.cancel()
    }

    /// Bare "pace" surrounded by punctuation still fires. Matches the
    /// realistic recognizer output for "Pace, what's on my screen?"
    @Test
    func barePacePhraseFiresWhenSurroundedByPunctuation() {
        let spotter = PaceAppleSpeechWakeWordSpotter()
        var receivedDetections: [PaceWakeWordDetection] = []
        let subscription = spotter.wakeWordDetectedPublisher.sink { detection in
            receivedDetections.append(detection)
        }

        spotter.didReceiveTranscriptionForTesting(
            "pace, what's on my screen",
            averageSegmentConfidence: 0.85
        )

        #expect(receivedDetections.count == 1)
        #expect(receivedDetections.first?.phraseMatched == "pace")
        subscription.cancel()
    }

    // MARK: - Rolling buffer RAM contract

    /// The rolling audio buffer must be nil between recognition
    /// cycles. The plan explicitly requires this so long
    /// always-listening sessions stay flat on RAM.
    @Test
    func rollingAudioBufferIsNilledAfterEachEvaluationCycle() {
        let spotter = PaceAppleSpeechWakeWordSpotter()

        // Before any evaluation, the buffer starts nil.
        #expect(spotter.currentAudioBufferForTesting == nil)

        // After an evaluation cycle that fires a detection, buffer
        // must be nil (defer { currentRollingAudioBuffer = nil }).
        spotter.didReceiveTranscriptionForTesting(
            "hey pace",
            averageSegmentConfidence: 0.9
        )
        #expect(spotter.currentAudioBufferForTesting == nil)

        // After an evaluation cycle that does NOT fire a detection
        // (below threshold), the buffer must ALSO be nil.
        spotter.didReceiveTranscriptionForTesting(
            "hey pace",
            averageSegmentConfidence: 0.4
        )
        #expect(spotter.currentAudioBufferForTesting == nil)
    }

    // MARK: - Lifecycle

    /// `stop()` halts publication AND clears the rolling buffer. Tests
    /// the spotter's hard-stop semantics — after stop, any further
    /// transcription deliveries should still process safely (don't
    /// crash) but the buffer must remain nil.
    ///
    /// Skipped in CI: `start()` brings up a real `AVAudioEngine` +
    /// `SFSpeechRecognizer`, which blocks on the CoreAudio HAL for the
    /// full CI time budget on the headless (no-microphone) runner. Runs
    /// normally on every developer machine and in `scripts/test-pace.sh`.
    @Test(.disabled(if: PaceTestEnvironment.isRunningInCI, "AVAudioEngine.start() blocks on the audio HAL on the headless CI runner"))
    func stopHaltsPublicationAndNilsRollingBuffer() {
        let spotter = PaceAppleSpeechWakeWordSpotter()
        spotter.start()
        spotter.stop()

        var receivedDetectionsAfterStop: [PaceWakeWordDetection] = []
        let subscription = spotter.wakeWordDetectedPublisher.sink { detection in
            receivedDetectionsAfterStop.append(detection)
        }

        // Even if some lagging recognizer callback fired after stop,
        // the spotter's evaluation path itself must not produce a
        // dangling buffer. We don't try to suppress the publisher
        // post-stop because the SFSpeechRecognitionTask is cancelled
        // first and the publisher won't be fed.
        #expect(spotter.currentAudioBufferForTesting == nil)
        #expect(spotter.isRunning == false)
        subscription.cancel()
    }

    /// Calling `pauseForExternalAudioConsumer()` (PTT engaging) must
    /// not crash and must report `isRunning == false`. Resume restores
    /// nothing because the spotter was never `start()`-ed — the
    /// reconcile gate stays closed.
    @Test
    func pauseAndResumeWithoutStartIsSafe() {
        let spotter = PaceAppleSpeechWakeWordSpotter()
        spotter.pauseForExternalAudioConsumer()
        #expect(spotter.isRunning == false)
        spotter.resumeIfPausedForExternalAudioConsumer()
        #expect(spotter.isRunning == false)
    }

    /// After `start()` + `pauseForExternalAudioConsumer()`, the
    /// recognition task is cancelled and `isRunning` reports false.
    /// This mirrors the PTT-bridge bind in CompanionManager — when
    /// PTT starts recording, we tell the spotter to back off.
    ///
    /// Skipped in CI: `start()` brings up a real `AVAudioEngine` +
    /// `SFSpeechRecognizer`, which blocks on the CoreAudio HAL for the
    /// full CI time budget on the headless (no-microphone) runner. Runs
    /// normally on every developer machine and in `scripts/test-pace.sh`.
    @Test(.disabled(if: PaceTestEnvironment.isRunningInCI, "AVAudioEngine.start() blocks on the audio HAL on the headless CI runner"))
    func pauseAfterStartCancelsRecognitionTask() {
        let spotter = PaceAppleSpeechWakeWordSpotter()
        spotter.start()
        spotter.pauseForExternalAudioConsumer()
        #expect(spotter.recognitionTaskWasCancelledForTesting == true)
        #expect(spotter.isRunning == false)
    }

    // MARK: - Multiple detections

    /// Two successive trigger phrases each emit their own detection
    /// event. The spotter does not deduplicate — that's CompanionManager's
    /// job (it drops detections when a turn is already in flight).
    @Test
    func twoSuccessiveTriggerPhrasesProduceTwoDetections() {
        let spotter = PaceAppleSpeechWakeWordSpotter()
        var receivedDetections: [PaceWakeWordDetection] = []
        let subscription = spotter.wakeWordDetectedPublisher.sink { detection in
            receivedDetections.append(detection)
        }

        spotter.didReceiveTranscriptionForTesting(
            "hey pace first time",
            averageSegmentConfidence: 0.85
        )
        spotter.didReceiveTranscriptionForTesting(
            "hey pace again",
            averageSegmentConfidence: 0.85
        )

        #expect(receivedDetections.count == 2)
        subscription.cancel()
    }

    // MARK: - Configuration

    /// A custom configuration with a higher confidence threshold
    /// rejects transcripts that pass the default 0.7 gate. Verifies
    /// the configuration plumbing actually drives the threshold —
    /// future Settings → Proactive customization can rely on it.
    @Test
    func customConfidenceThresholdGatesDetection() {
        let strictConfiguration = PaceWakeWordConfiguration(
            triggerPhrases: ["hey pace", "pace"],
            minimumConfidence: 0.95,
            bufferDurationSeconds: 5.0
        )
        let spotter = PaceAppleSpeechWakeWordSpotter(configuration: strictConfiguration)
        var receivedDetections: [PaceWakeWordDetection] = []
        let subscription = spotter.wakeWordDetectedPublisher.sink { detection in
            receivedDetections.append(detection)
        }

        // 0.8 passes the default 0.7 gate but NOT the custom 0.95.
        spotter.didReceiveTranscriptionForTesting(
            "hey pace",
            averageSegmentConfidence: 0.8
        )
        #expect(receivedDetections.isEmpty)

        spotter.didReceiveTranscriptionForTesting(
            "hey pace",
            averageSegmentConfidence: 0.96
        )
        #expect(receivedDetections.count == 1)
        subscription.cancel()
    }

    /// Custom trigger phrases drive matching. If a user reconfigures
    /// the wake word to "computer", "hey pace" must no longer fire.
    @Test
    func customTriggerPhrasesReplaceDefaults() {
        let customConfiguration = PaceWakeWordConfiguration(
            triggerPhrases: ["computer"],
            minimumConfidence: 0.7,
            bufferDurationSeconds: 5.0
        )
        let spotter = PaceAppleSpeechWakeWordSpotter(configuration: customConfiguration)
        var receivedDetections: [PaceWakeWordDetection] = []
        let subscription = spotter.wakeWordDetectedPublisher.sink { detection in
            receivedDetections.append(detection)
        }

        spotter.didReceiveTranscriptionForTesting(
            "hey pace",
            averageSegmentConfidence: 0.9
        )
        #expect(receivedDetections.isEmpty)

        spotter.didReceiveTranscriptionForTesting(
            "computer open the door",
            averageSegmentConfidence: 0.9
        )
        #expect(receivedDetections.count == 1)
        #expect(receivedDetections.first?.phraseMatched == "computer")
        subscription.cancel()
    }
}
