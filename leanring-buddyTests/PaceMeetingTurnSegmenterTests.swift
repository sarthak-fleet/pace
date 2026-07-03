//
//  PaceMeetingTurnSegmenterTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Pace

struct PaceMeetingTurnSegmenterTests {
    private let sampleRate: Double = 16_000

    /// Sine wave at the given amplitude, for `durationSeconds`.
    private func sineWave(amplitude: Float, durationSeconds: TimeInterval, frequency: Float = 440) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let twoPi: Float = 2 * .pi
        let radiansPerSample = twoPi * frequency / Float(sampleRate)
        for i in 0..<count {
            samples[i] = amplitude * sinf(Float(i) * radiansPerSample)
        }
        return samples
    }

    private func silence(durationSeconds: TimeInterval) -> [Float] {
        [Float](repeating: 0, count: Int(durationSeconds * sampleRate))
    }

    private func makeTrack(_ samples: [Float]) -> PaceMeetingAudioTrack {
        PaceMeetingAudioTrack(samples: samples, sampleRate: sampleRate)
    }

    // MARK: - Pure silence

    @Test func pureSilenceProducesZeroTurns() async throws {
        let mic = makeTrack(silence(durationSeconds: 5))
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: nil, now: Date())
        #expect(turns.isEmpty)
    }

    @Test func bothTracksSilentProducesZeroTurns() async throws {
        let mic = makeTrack(silence(durationSeconds: 5))
        let system = makeTrack(silence(durationSeconds: 5))
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: system, now: Date())
        #expect(turns.isEmpty)
    }

    // MARK: - Mic-only (solo dictation)

    @Test func micOnlyAttributesAllTurnsToYou() async throws {
        let micSamples = sineWave(amplitude: 0.2, durationSeconds: 2)
        let mic = makeTrack(micSamples)
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: nil, now: Date())
        #expect(!turns.isEmpty)
        #expect(turns.allSatisfy { $0.track == .mic })
        #expect(turns.allSatisfy { $0.attributedSpeaker == "you" })
    }

    // MARK: - System-only

    @Test func systemOnlyAttributesAllTurnsToThem() async throws {
        let systemSamples = sineWave(amplitude: 0.2, durationSeconds: 2)
        let system = makeTrack(systemSamples)
        let turns = PaceMeetingTurnSegmenter.segment(mic: nil, system: system, now: Date())
        #expect(!turns.isEmpty)
        #expect(turns.allSatisfy { $0.track == .system })
        #expect(turns.allSatisfy { $0.attributedSpeaker == "them" })
    }

    // MARK: - Single long utterance

    @Test func singleLongUtteranceProducesOneTurn() async throws {
        let micSamples = sineWave(amplitude: 0.2, durationSeconds: 3)
        let mic = makeTrack(micSamples)
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: nil, now: Date())
        #expect(turns.count == 1)
        let turn = try #require(turns.first)
        #expect(turn.track == .mic)
        let duration = turn.end.timeIntervalSince(turn.start)
        #expect(duration >= 2.9)
    }

    // MARK: - Echo trimming

    @Test func echoTrimmingPicksLouderTrackWhenBothExceedSpeechThreshold() async throws {
        // Both tracks have overlapping speech; mic is louder.
        let micSamples = sineWave(amplitude: 0.3, durationSeconds: 2)
        let systemSamples = sineWave(amplitude: 0.1, durationSeconds: 2)
        let mic = makeTrack(micSamples)
        let system = makeTrack(systemSamples)
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: system, now: Date())
        #expect(!turns.isEmpty)
        // The louder (mic) track should win every overlapping window.
        #expect(turns.allSatisfy { $0.track == .mic })
    }

    @Test func echoTrimmingPicksSystemWhenSystemIsLouder() async throws {
        let micSamples = sineWave(amplitude: 0.08, durationSeconds: 2)
        let systemSamples = sineWave(amplitude: 0.3, durationSeconds: 2)
        let mic = makeTrack(micSamples)
        let system = makeTrack(systemSamples)
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: system, now: Date())
        #expect(!turns.isEmpty)
        #expect(turns.allSatisfy { $0.track == .system })
    }

    // MARK: - Hysteresis merge

    @Test func hysteresisMergesShortSilenceGapInsideSpeech() async throws {
        // 1s speech + 200ms silence (below silence threshold) + 1s speech.
        // 200ms < 400ms max gap → should merge into one turn.
        var samples = sineWave(amplitude: 0.2, durationSeconds: 1)
        samples.append(contentsOf: silence(durationSeconds: 0.2))
        samples.append(contentsOf: sineWave(amplitude: 0.2, durationSeconds: 1))
        let mic = makeTrack(samples)
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: nil, now: Date())
        #expect(turns.count == 1)
        let turn = try #require(turns.first)
        let duration = turn.end.timeIntervalSince(turn.start)
        #expect(duration >= 2.0)
    }

    @Test func hysteresisSplitsOnSilenceGapExceedingMax() async throws {
        // 1s speech + 600ms silence + 1s speech.
        // 600ms > 400ms max gap → should split into two turns.
        var samples = sineWave(amplitude: 0.2, durationSeconds: 1)
        samples.append(contentsOf: silence(durationSeconds: 0.6))
        samples.append(contentsOf: sineWave(amplitude: 0.2, durationSeconds: 1))
        let mic = makeTrack(samples)
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: nil, now: Date())
        #expect(turns.count == 2)
        #expect(turns.allSatisfy { $0.track == .mic })
    }

    // MARK: - Minimum turn duration

    @Test func shortSpeechRunBelowMinimumTurnDurationIsDropped() async throws {
        // 200ms of speech — below the 600ms minimum.
        let samples = sineWave(amplitude: 0.2, durationSeconds: 0.2)
        let mic = makeTrack(samples)
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: nil, now: Date())
        #expect(turns.isEmpty)
    }

    // MARK: - Nil tracks

    @Test func bothTracksNilProducesZeroTurns() async throws {
        let turns = PaceMeetingTurnSegmenter.segment(mic: nil, system: nil, now: Date())
        #expect(turns.isEmpty)
    }

    // MARK: - Timestamps

    @Test func turnStartAndEndAreOffsetFromNow() async throws {
        let now = Date()
        let micSamples = sineWave(amplitude: 0.2, durationSeconds: 1)
        let mic = makeTrack(micSamples)
        let turns = PaceMeetingTurnSegmenter.segment(mic: mic, system: nil, now: now)
        #expect(turns.count == 1)
        let turn = try #require(turns.first)
        #expect(turn.start.timeIntervalSince(now) < 0.05)
        #expect(turn.end.timeIntervalSince(now) >= 0.9)
    }
}
