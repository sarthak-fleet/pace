//
//  PaceMeetingTurnSegmenter.swift
//  leanring-buddy
//
//  Pure energy-based turn segmentation over two meeting audio tracks
//  (mic + system). Uses Accelerate RMS over fixed-size windows with a
//  hysteresis state machine (speech / silence / speech) and echo
//  trimming: when both tracks exceed the speech threshold in the same
//  window, the louder track owns the turn and the other is suppressed
//  for that window. No I/O, no async — unit-testable in isolation.
//
//  See docs/prds/on-device-meeting-notes.md for the full spec.
//

import Accelerate
import Foundation

/// Which track a turn belongs to. `.mic` is "you", `.system` is "them"
/// for v1 attribution.
nonisolated enum PaceMeetingAudioTrackKind: Equatable, Sendable {
    case mic
    case system
}

/// A captured audio track: mono Float32 samples + sample rate. The
/// recorder owns two of these (mic + system); the segmenter consumes
/// them as pure values.
nonisolated struct PaceMeetingAudioTrack: Equatable, Sendable {
    let samples: [Float]
    let sampleRate: Double
    let channelCount: Int
    /// How long after the meeting's earliest captured sample THIS
    /// track's first sample arrived. The mic starts recording before
    /// the SCStream finishes spinning up (0.5–2 s), so without this
    /// offset the segmenter would align window 0 of both tracks and
    /// echo trimming would compare different moments in time.
    let startOffsetSeconds: TimeInterval

    init(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int = 1,
        startOffsetSeconds: TimeInterval = 0
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.startOffsetSeconds = max(0, startOffsetSeconds)
    }
}

/// A timestamped turn attributed to one track.
nonisolated struct PaceMeetingTurn: Equatable, Sendable {
    let start: Date
    let end: Date
    let track: PaceMeetingAudioTrackKind
    let attributedSpeaker: String
    let sampleRange: Range<Int>
}

/// Pure turn segmenter. No state, no I/O.
nonisolated enum PaceMeetingTurnSegmenter {
    /// Silence threshold: RMS below this is always silence.
    static let silenceThreshold: Float = 0.01
    /// Speech threshold: RMS above this is always speech. Between the
    /// two thresholds the hysteresis state holds (keeps a turn alive).
    static let speechThreshold: Float = 0.04
    /// Minimum turn duration; shorter runs are dropped as noise.
    static let minimumTurnDurationSeconds: TimeInterval = 0.6
    /// Maximum silence gap inside a turn that still merges adjacent
    /// speech runs into one turn.
    static let maximumSilenceGapSeconds: TimeInterval = 0.4
    /// RMS window size in milliseconds.
    static let windowMilliseconds = 20

    /// Segment two tracks into attributed turns. Either track may be
    /// nil (solo dictation → mic-only; silent system → mic-only).
    static func segment(
        mic: PaceMeetingAudioTrack?,
        system: PaceMeetingAudioTrack?,
        now: Date
    ) -> [PaceMeetingTurn] {
        guard mic != nil || system != nil else { return [] }

        let sampleRate = (mic?.sampleRate ?? system?.sampleRate) ?? 0
        guard sampleRate > 0 else { return [] }
        let windowSize = windowSampleCount(sampleRate: sampleRate)
        let windowDuration = TimeInterval(windowSize) / sampleRate

        // Shift each track's windows right by its start offset so window
        // index N means the same wall-clock moment on both tracks (the
        // SCStream starts 0.5–2 s after the mic). The pad counts are
        // remembered per track so turn sample ranges can be mapped back
        // into per-track sample indices.
        let micPadWindows = leadingPadWindowCount(for: mic, windowDuration: windowDuration)
        let systemPadWindows = leadingPadWindowCount(for: system, windowDuration: windowDuration)
        let micWindows = paddedWindows(mic.map { rmsWindows(for: $0) } ?? [], leadingZeroCount: micPadWindows)
        let systemWindows = paddedWindows(system.map { rmsWindows(for: $0) } ?? [], leadingZeroCount: systemPadWindows)
        let windowCount = max(micWindows.count, systemWindows.count)
        guard windowCount > 0 else { return [] }

        let micTrackWindowContext = TrackWindowContext(
            padWindows: micPadWindows,
            sampleCount: mic?.samples.count ?? 0
        )
        let systemTrackWindowContext = TrackWindowContext(
            padWindows: systemPadWindows,
            sampleCount: system?.samples.count ?? 0
        )

        // Per-window active track after echo trimming. When both
        // tracks exceed the speech threshold in the same window, the
        // louder track wins; the other is marked silent for that
        // window.
        var activeTrackPerWindow: [PaceMeetingAudioTrackKind?] = []
        activeTrackPerWindow.reserveCapacity(windowCount)
        for windowIndex in 0..<windowCount {
            let micRMS = windowIndex < micWindows.count ? micWindows[windowIndex] : 0
            let systemRMS = windowIndex < systemWindows.count ? systemWindows[windowIndex] : 0
            let micIsSpeech = micRMS >= speechThreshold
            let systemIsSpeech = systemRMS >= speechThreshold

            if micIsSpeech && systemIsSpeech {
                // Echo trim: louder track wins.
                activeTrackPerWindow.append(micRMS >= systemRMS ? .mic : .system)
            } else if micIsSpeech {
                activeTrackPerWindow.append(.mic)
            } else if systemIsSpeech {
                activeTrackPerWindow.append(.system)
            } else {
                // Hysteresis: between thresholds, hold the current
                // state. We resolve this during turn building below by
                // looking at the previous active track; mark nil here
                // and let the state machine decide.
                activeTrackPerWindow.append(nil)
            }
        }

        // Build turns with hysteresis. Walk windows, group consecutive
        // active windows of the same track into runs. A nil window
        // (between thresholds) extends the current run if the gap so
        // far is under the max silence gap; otherwise it closes the
        // run. A window whose RMS is below the silence threshold
        // always closes (can't hold speech below silence).
        var turns: [PaceMeetingTurn] = []
        var currentTrack: PaceMeetingAudioTrackKind?
        var runStartWindow = 0
        var silenceGapWindows = 0

        for windowIndex in 0..<windowCount {
            let resolved = activeTrackPerWindow[windowIndex]

            if let track = resolved {
                // Definite speech window.
                if let existing = currentTrack {
                    if existing == track {
                        silenceGapWindows = 0
                    } else {
                        // Track switch: close the current run and start
                        // a new one (the gap/merge logic doesn't bridge
                        // across different tracks).
                        appendTurn(
                            &turns,
                            track: existing,
                            startWindow: runStartWindow,
                            endWindow: windowIndex,
                            windowSize: windowSize,
                            windowDuration: windowDuration,
                            micContext: micTrackWindowContext,
                            systemContext: systemTrackWindowContext,
                            now: now
                        )
                        currentTrack = track
                        runStartWindow = windowIndex
                        silenceGapWindows = 0
                    }
                } else {
                    currentTrack = track
                    runStartWindow = windowIndex
                    silenceGapWindows = 0
                }
            } else {
                // Between thresholds or below speech. Decide whether to
                // hold (hysteresis) or close. A silence gap up to the
                // max merges adjacent speech runs into one turn; only
                // close once the gap exceeds the merge window.
                if currentTrack != nil {
                    silenceGapWindows += 1
                    let gapDuration = TimeInterval(silenceGapWindows) * windowDuration
                    if gapDuration >= maximumSilenceGapSeconds {
                        appendTurn(
                            &turns,
                            track: currentTrack!,
                            startWindow: runStartWindow,
                            endWindow: windowIndex - silenceGapWindows + 1,
                            windowSize: windowSize,
                            windowDuration: windowDuration,
                            micContext: micTrackWindowContext,
                            systemContext: systemTrackWindowContext,
                            now: now
                        )
                        currentTrack = nil
                        silenceGapWindows = 0
                    }
                }
            }
        }

        // Close a trailing run.
        if let track = currentTrack {
            appendTurn(
                &turns,
                track: track,
                startWindow: runStartWindow,
                endWindow: windowCount,
                windowSize: windowSize,
                windowDuration: windowDuration,
                micContext: micTrackWindowContext,
                systemContext: systemTrackWindowContext,
                now: now
            )
        }

        // Drop turns shorter than the minimum duration.
        let minimumSamples = Int(minimumTurnDurationSeconds * sampleRate)
        return turns.filter { turn in
            turn.sampleRange.count >= minimumSamples
        }
    }

    // MARK: - RMS windowing

    /// Number of samples in one RMS window for the given sample rate.
    static func windowSampleCount(sampleRate: Double) -> Int {
        let count = Int((sampleRate * Double(windowMilliseconds) / 1000.0).rounded())
        return max(count, 1)
    }

    /// Per-window RMS via Accelerate `vDSP_rmsqv`. The last window is
    /// zero-padded if the buffer doesn't divide evenly.
    static func rmsWindows(for track: PaceMeetingAudioTrack) -> [Float] {
        let windowSize = windowSampleCount(sampleRate: track.sampleRate)
        let sampleCount = track.samples.count
        guard sampleCount > 0, windowSize > 0 else { return [] }

        let fullWindowCount = sampleCount / windowSize
        let remainder = sampleCount % windowSize
        var windows: [Float] = []
        windows.reserveCapacity(fullWindowCount + (remainder > 0 ? 1 : 0))

        track.samples.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            for windowIndex in 0..<fullWindowCount {
                let windowBase = base.advanced(by: windowIndex * windowSize)
                var rms: Float = 0
                vDSP_rmsqv(windowBase, 1, &rms, vDSP_Length(windowSize))
                windows.append(rms)
            }
            if remainder > 0 {
                // Zero-pad the final partial window.
                var padded = [Float](repeating: 0, count: windowSize)
                let windowBase = base.advanced(by: fullWindowCount * windowSize)
                for i in 0..<remainder {
                    padded[i] = windowBase[i]
                }
                var rms: Float = 0
                padded.withUnsafeBufferPointer { paddedBuffer in
                    vDSP_rmsqv(paddedBuffer.baseAddress!, 1, &rms, vDSP_Length(windowSize))
                }
                windows.append(rms)
            }
        }

        return windows
    }

    // MARK: - Turn building

    /// Per-track mapping info from global (padded) window indices back
    /// to the track's own sample space.
    private struct TrackWindowContext {
        let padWindows: Int
        let sampleCount: Int
    }

    private static func appendTurn(
        _ turns: inout [PaceMeetingTurn],
        track: PaceMeetingAudioTrackKind,
        startWindow: Int,
        endWindow: Int,
        windowSize: Int,
        windowDuration: TimeInterval,
        micContext: TrackWindowContext,
        systemContext: TrackWindowContext,
        now: Date
    ) {
        let context = track == .mic ? micContext : systemContext
        // Map global window indices into this track's sample space and
        // clamp to the actual sample count. Clamping matters twice: the
        // final RMS window is zero-padded past the buffer's end, and
        // `windowCount` is the max across both tracks — either way an
        // unclamped range can exceed the buffer and crash at slice time.
        let startSample = min(max((startWindow - context.padWindows) * windowSize, 0), context.sampleCount)
        let endSample = min(max((endWindow - context.padWindows) * windowSize, 0), context.sampleCount)
        guard endSample > startSample else { return }

        // Timestamps stay on the global (aligned) timeline: `now` is the
        // meeting's earliest captured sample across both tracks.
        let startOffset = TimeInterval(startWindow) * windowDuration
        let endOffset = TimeInterval(endWindow) * windowDuration
        turns.append(PaceMeetingTurn(
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(endOffset),
            track: track,
            attributedSpeaker: track == .mic ? "you" : "them",
            sampleRange: startSample..<endSample
        ))
    }

    // MARK: - Cross-track alignment

    /// Number of leading zero windows that shift a track so its window
    /// indices line up with the meeting's global timeline.
    private static func leadingPadWindowCount(
        for track: PaceMeetingAudioTrack?,
        windowDuration: TimeInterval
    ) -> Int {
        guard let track, windowDuration > 0 else { return 0 }
        return Int((track.startOffsetSeconds / windowDuration).rounded())
    }

    private static func paddedWindows(_ windows: [Float], leadingZeroCount: Int) -> [Float] {
        guard leadingZeroCount > 0, !windows.isEmpty else { return windows }
        return [Float](repeating: 0, count: leadingZeroCount) + windows
    }
}
