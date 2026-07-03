//
//  PaceSystemAudioCapture.swift
//  leanring-buddy
//
//  Meeting mode: captures system audio via ScreenCaptureKit's SCStream
//  with audio enabled. Inspired by Shiro's meeting mode and Samuel's
//  system-audio listening with PID-level filtering.
//
//  The captured audio is routed to an AVAudioEngine tap for:
//    - Voice activity detection (is someone speaking?)
//    - Action item extraction (via the planner, on demand)
//    - Live transcription (via the existing STT pipeline)
//
//  Permission: covered by the existing Screen Recording permission
//  (hasScreenRecordingPermission). No additional permission needed
//  for system audio capture — it's part of SCStream.
//

import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit
import Foundation

/// Published state for meeting mode.
enum PaceMeetingModeState: Equatable {
    case inactive
    case starting
    case active
    case transcribing
    case synthesizing
    case failed(String)
}

/// Meeting mode controller. Manages an SCStream that captures system
/// audio (excluding Pace's own process audio to avoid echo). The
/// audio is published as normalized RMS levels for VAD-style detection
/// and can be routed to the STT pipeline for transcription.
@MainActor
final class PaceMeetingModeController: ObservableObject {
    static let shared = PaceMeetingModeController()

    @Published private(set) var state: PaceMeetingModeState = .inactive
    @Published private(set) var detectedSpeechLevel: Float = 0.0
    @Published private(set) var captureDurationSeconds: TimeInterval = 0.0

    /// The most recently synthesized meeting notes, published so the
    /// panel card can render them after stop. Cleared on the next start.
    @Published private(set) var lastMeetingNotes: PaceMeetingNotes?

    /// True when the SCStream died mid-meeting (didStopWithError). The
    /// mic track keeps recording, but the "them" side is truncated —
    /// the notes summary carries a caveat so the user isn't handed
    /// silently one-sided notes. Reset on the next start.
    @Published private(set) var systemAudioDroppedMidMeeting = false

    /// Publisher for normalized audio levels (0.0...1.0). Consumers
    /// can subscribe to detect speech activity in system audio.
    let audioLevelPublisher = PassthroughSubject<Float, Never>()

    /// Whether meeting mode is enabled (persisted preference).
    @Published var isEnabled: Bool = PaceUserPreferencesStore
        .bool(.isMeetingModeEnabled, default: false)

    /// Injected retriever for journaling meeting notes. Set from
    /// `CompanionManager` before `start()` to avoid a singleton init
    /// cycle. When nil at stop time, the recording files are still
    /// saved but notes synthesis + journaling are skipped (graceful
    /// degradation — the user still gets their audio files).
    var localRetriever: PaceLocalRetriever?

    /// Injected planner client for notes synthesis. Same setter pattern
    /// as `localRetriever`. When nil at stop time, notes synthesis is
    /// skipped but the transcript + recording are still saved.
    var plannerClient: (any BuddyPlannerClient)?

    private var stream: SCStream?
    private var streamDelegate: PaceSystemAudioStreamDelegate?
    private var captureStartedAt: Date?
    private var recorder: PaceMeetingAudioRecorder?
    /// Monotonic token bumped by every start()/stop(). Both methods
    /// suspend at awaits on the MainActor, so a stop() (or a second
    /// start()) can interleave mid-lifecycle; each await in start()
    /// re-checks this token and aborts if another lifecycle call has
    /// superseded it, instead of clobbering the newer session's state.
    private var lifecycleGeneration: Int = 0

    private init() {}

    // MARK: - Lifecycle

    /// Start capturing system + mic audio. Requires Screen Recording
    /// permission (system track) and microphone permission (mic track).
    /// Excludes Pace's own process audio to avoid echo. Creates a
    /// `PaceMeetingAudioRecorder` that owns the mic track and the
    /// two-track disk writer; the SCStream delegate appends system
    /// samples to the recorder as they arrive.
    func start() async {
        // Reject while a previous meeting is anywhere in its lifecycle —
        // including .transcribing/.synthesizing, where a new capture
        // would race the old stop() pipeline for `state` and
        // `lastMeetingNotes`. Retry from .failed is allowed.
        switch state {
        case .inactive, .failed:
            break
        case .starting, .active, .transcribing, .synthesizing:
            return
        }
        lifecycleGeneration += 1
        let thisStartGeneration = lifecycleGeneration
        state = .starting
        lastMeetingNotes = nil
        systemAudioDroppedMidMeeting = false

        // Create the recorder + meeting ID up front so both tracks
        // share one identifier even if the SCStream fails to start.
        let meetingID = UUID()
        let newRecorder = PaceMeetingAudioRecorder(meetingID: meetingID)
        recorder = newRecorder

        do {
            // Start mic capture first — a failure here is recoverable
            // (the system track can still record).
            try await newRecorder.startMicCapture()
        } catch {
            // Mic permission denied or engine failure — continue with
            // system-only capture. The recorder's mic track will be
            // empty/nil at stop, which the segmenter handles.
        }
        // A stop() (or newer start) interleaved during the mic await —
        // it already owns the recorder teardown; abort quietly.
        guard lifecycleGeneration == thisStartGeneration else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard lifecycleGeneration == thisStartGeneration else { return }

            // Capture the primary display's audio. We use the display
            // filter (not per-app) because meeting audio may come from
            // any app (Zoom, Teams, Chrome, etc.).
            guard let display = content.displays.first else {
                state = .failed("No display found for audio capture")
                return
            }

            // Exclude Pace's own windows to avoid capturing TTS output.
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownWindows = content.windows.filter { window in
                window.owningApplication?.processID == ownPID
            }

            let filter = SCContentFilter(
                display: display,
                excludingWindows: ownWindows
            )

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            // Ask SCStream for 16 kHz mono directly so the delegate's
            // samples match the recorder's WAV header. Without this,
            // SCStream delivers 48 kHz and every downstream consumer
            // (playback, ASR, turn timestamps) runs ~3× slow.
            configuration.sampleRate = 16_000
            configuration.channelCount = 1
            // Low-latency audio capture for real-time VAD.
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)

            let delegate = PaceSystemAudioStreamDelegate(
                onAudioSample: { [weak self] level, samples in
                    Task { @MainActor [weak self] in
                        self?.handleAudioSample(level: level, samples: samples)
                    }
                },
                onStreamStopped: { [weak self] errorDescription in
                    Task { @MainActor [weak self] in
                        self?.handleSystemAudioStreamStopped(errorDescription: errorDescription)
                    }
                }
            )
            streamDelegate = delegate

            let scStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: delegate
            )
            self.stream = scStream

            try await scStream.startCapture()
            guard lifecycleGeneration == thisStartGeneration else {
                // A stop() superseded this start while the capture was
                // spinning up — shut the stream back down and bail
                // without touching the newer lifecycle's state.
                try? await scStream.stopCapture()
                return
            }
            state = .active
            captureStartedAt = Date()
        } catch {
            guard lifecycleGeneration == thisStartGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Stop capturing system + mic audio, then run the full pipeline:
    /// segment → transcribe → build notes → journal. The recording
    /// files are always saved; notes synthesis + journaling are
    /// skipped only when the injected retriever or planner is nil
    /// (graceful degradation — the user still gets their audio files).
    func stop() async {
        // Only one stop pipeline may run — a second stop() (voice
        // command + settings toggle racing) or a stop while a previous
        // meeting is still transcribing/synthesizing must not tear the
        // in-flight pipeline's state down. Claiming the lifecycle
        // generation also aborts any suspended start().
        switch state {
        case .active, .starting:
            break
        case .inactive, .transcribing, .synthesizing, .failed:
            return
        }
        lifecycleGeneration += 1
        state = .transcribing

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        streamDelegate = nil
        captureStartedAt = nil
        detectedSpeechLevel = 0.0

        guard let recorder else {
            state = .inactive
            return
        }

        let recording = await recorder.stop()
        self.recorder = nil

        // No tracks at all → nothing to transcribe.
        guard recording.micTrack != nil || recording.systemTrack != nil else {
            state = .inactive
            return
        }

        // Segment the two tracks into attributed turns. The timeline
        // anchor is the earliest captured sample, not the start() call —
        // each track's startOffsetSeconds is relative to it.
        let turns = PaceMeetingTurnSegmenter.segment(
            mic: recording.micTrack,
            system: recording.systemTrack,
            now: recording.earliestSampleAnchor ?? recording.startedAt
        )

        // Transcribe each turn's audio slice. When segmentation yields
        // zero turns (pure silence), skip transcription entirely.
        // The transcription backend follows the Settings preference;
        // "apple" skips WhisperKit entirely.
        let preferWhisperKitBackend = PaceUserPreferencesStore.meetingNotesTranscriptionBackend() == "whisperkit"
        var turnRecords: [PaceMeetingTurnRecord] = []
        var transcriptParts: [String] = []
        for turn in turns {
            let trackSamples: [Float]
            let sampleRate: Double
            switch turn.track {
            case .mic:
                guard let mic = recording.micTrack else { continue }
                trackSamples = mic.samples
                sampleRate = mic.sampleRate
            case .system:
                guard let system = recording.systemTrack else { continue }
                trackSamples = system.samples
                sampleRate = system.sampleRate
            }
            // Defense in depth: the segmenter clamps ranges to the
            // track, but an out-of-range slice here is an unrecoverable
            // crash at the end of a long meeting — never trust it blindly.
            let clampedRange = turn.sampleRange.clamped(to: 0..<trackSamples.count)
            let slice = Array(trackSamples[clampedRange])
            guard !slice.isEmpty else { continue }
            let sliceURL = Self.sliceToTempWAV(samples: slice, sampleRate: sampleRate)
            do {
                let segments = try await PaceAudioFileTranscriber.transcribeAudioFileSegmented(
                    at: sliceURL,
                    preferWhisperKit: preferWhisperKitBackend
                )
                let turnText = segments.map { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !turnText.isEmpty {
                    transcriptParts.append(turnText)
                    turnRecords.append(PaceMeetingTurnRecord(
                        start: turn.start,
                        end: turn.end,
                        speaker: turn.attributedSpeaker,
                        text: turnText
                    ))
                }
            } catch {
                // A single turn's transcription failure shouldn't kill
                // the whole meeting — skip it and continue.
            }
            try? FileManager.default.removeItem(at: sliceURL)
        }

        let rawTranscript = transcriptParts.joined(separator: " ")
        let transcript = PaceDictationPostProcessor.process(rawText: rawTranscript)

        // Build notes via the planner.
        state = .synthesizing
        let title = "Meeting \(PaceMeetingModeController.timeFormatter.string(from: recording.startedAt))"
        let notes: PaceMeetingNotes
        if let planner = plannerClient {
            notes = await PaceMeetingNotesBuilder.build(
                transcript: transcript,
                turns: turnRecords,
                meetingID: recording.meetingID,
                startedAt: recording.startedAt,
                endedAt: recording.endedAt,
                title: title,
                planner: planner
            )
        } else {
            // No planner injected — save the transcript as the notes
            // with synthesisFailed so the user still gets the artifact.
            notes = PaceMeetingNotes(
                meetingID: recording.meetingID,
                startedAt: recording.startedAt,
                endedAt: recording.endedAt,
                title: title,
                transcript: transcript,
                turns: turnRecords,
                summary: transcript.isEmpty ? "" : transcript,
                actionItems: [],
                decisions: [],
                synthesisFailed: true
            )
        }
        // If the system-audio stream died mid-meeting, say so in the
        // summary itself — the notes otherwise read as a meeting where
        // only the user spoke.
        let finalNotes: PaceMeetingNotes
        if systemAudioDroppedMidMeeting {
            finalNotes = PaceMeetingNotes(
                meetingID: notes.meetingID,
                startedAt: notes.startedAt,
                endedAt: notes.endedAt,
                title: notes.title,
                transcript: notes.transcript,
                turns: notes.turns,
                summary: "(System audio dropped partway through — notes may only cover your side.) " + notes.summary,
                actionItems: notes.actionItems,
                decisions: notes.decisions,
                synthesisFailed: notes.synthesisFailed
            )
        } else {
            finalNotes = notes
        }
        lastMeetingNotes = finalNotes

        // Journal into the retrieval index.
        if let retriever = localRetriever {
            retriever.recordMeetingNotes(finalNotes)
        }

        state = .inactive
    }

    /// Toggle meeting mode on/off. A toggle during `.starting` stops
    /// the spinning-up capture rather than being ignored.
    func toggle() async {
        if state == .active || state == .starting {
            await stop()
        } else {
            await start()
        }
    }

    // MARK: - Audio handling

    /// SCStream died mid-meeting. The mic keeps recording (better half
    /// a meeting than none), the panel state reflects the drop, and the
    /// eventual notes carry a caveat instead of silently reading as a
    /// one-sided meeting.
    private func handleSystemAudioStreamStopped(errorDescription: String) {
        guard state == .active || state == .starting else { return }
        systemAudioDroppedMidMeeting = true
        detectedSpeechLevel = 0.0
        print("⚠️ Meeting mode: system audio stream stopped mid-meeting — \(errorDescription). Mic track continues.")
    }

    private func handleAudioSample(level: Float, samples: [Float]) {
        detectedSpeechLevel = level
        audioLevelPublisher.send(level)

        if let startedAt = captureStartedAt {
            captureDurationSeconds = Date().timeIntervalSince(startedAt)
        }

        // Forward raw system samples to the recorder for the two-track
        // disk writer. The recorder lazily creates its system track file.
        recorder?.appendSystemSamples(samples)
    }

    /// Write a slice of Float32 samples to a temp RIFF WAV file for
    /// per-turn transcription. Returns the temp file URL; the caller
    /// is responsible for deleting it after transcription.
    private nonisolated static func sliceToTempWAV(samples: [Float], sampleRate: Double) -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-meeting-turn-\(UUID().uuidString).wav")
        let header = PaceMeetingAudioRecorder.riffHeaderPlaceholder(
            dataByteCount: UInt32(samples.count * 2),
            sampleRate: sampleRate,
            channels: 1
        )
        var pcmBytes = [UInt8](repeating: 0, count: samples.count * 2)
        for (index, sample) in samples.enumerated() {
            let clamped = max(-1.0, min(1.0, sample))
            let intValue = Int16(clamped * Float(Int16.max))
            let byteOffset = index * 2
            pcmBytes[byteOffset] = UInt8(intValue & 0xFF)
            pcmBytes[byteOffset + 1] = UInt8((intValue >> 8) & 0xFF)
        }
        var fileData = Data(header)
        fileData.append(contentsOf: pcmBytes)
        try? fileData.write(to: tempURL, options: .atomic)
        return tempURL
    }

    nonisolated static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    /// Whether system audio currently has speech-like energy.
    var isSystemAudioActive: Bool {
        detectedSpeechLevel > 0.08
    }
}

/// SCStream delegate that receives audio sample buffers and computes
/// normalized RMS levels. The levels are forwarded to the controller
/// via a callback.
private final class PaceSystemAudioStreamDelegate: NSObject, SCStreamDelegate {
    private let onAudioSample: (Float, [Float]) -> Void
    private let onStreamStopped: (String) -> Void

    init(
        onAudioSample: @escaping (Float, [Float]) -> Void,
        onStreamStopped: @escaping (String) -> Void
    ) {
        self.onAudioSample = onAudioSample
        self.onStreamStopped = onStreamStopped
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let audioFormat = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        guard let format = audioFormat else { return }

        let sampleRate = format.pointee.mSampleRate
        let channels = Int(format.pointee.mChannelsPerFrame)
        guard channels > 0, sampleRate > 0 else { return }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        let accessStatus = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard accessStatus == kCMBlockBufferNoErr, let dataPtr = dataPointer else { return }

        let floatCount = totalLength / MemoryLayout<Float>.size
        let floatPtr = UnsafeMutableRawPointer(dataPtr).bindMemory(to: Float.self, capacity: floatCount)

        // Downmix to mono if multi-channel (SCStream may deliver stereo).
        var monoSamples: [Float] = []
        if channels == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
        } else {
            let frameCount = floatCount / channels
            monoSamples.reserveCapacity(frameCount)
            for frameIndex in 0..<frameCount {
                var sum: Float = 0
                for channelIndex in 0..<channels {
                    sum += floatPtr[frameIndex * channels + channelIndex]
                }
                monoSamples.append(sum / Float(channels))
            }
        }

        guard !monoSamples.isEmpty else { return }
        var totalSquares: Float = 0
        for sample in monoSamples {
            totalSquares += sample * sample
        }
        let rms = sqrt(totalSquares / Float(monoSamples.count))
        let normalized = min(rms / 0.3, 1.0)
        onAudioSample(normalized, monoSamples)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onAudioSample(0.0, [])
        onStreamStopped(error.localizedDescription)
    }
}
