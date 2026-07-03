//
//  PaceMeetingAudioRecorderTests.swift
//  leanring-buddyTests
//

import AVFoundation
import Foundation
import Testing
@testable import Pace

@MainActor
struct PaceMeetingAudioRecorderTests {
    private let sampleRate: Double = 16_000

    /// Sine wave at the given amplitude for `durationSeconds`.
    private func sineWave(amplitude: Float, durationSeconds: TimeInterval, frequency: Float = 440) -> [Float] {
        let count = Int(durationSeconds * sampleRate)
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let radiansPerSample: Float = 2 * .pi * frequency / Float(sampleRate)
        for i in 0..<count {
            samples[i] = amplitude * sinf(Float(i) * radiansPerSample)
        }
        return samples
    }

    private func silence(durationSeconds: TimeInterval) -> [Float] {
        [Float](repeating: 0, count: Int(durationSeconds * sampleRate))
    }

    private func makeRecorder(in directory: URL) -> PaceMeetingAudioRecorder {
        let recorder = PaceMeetingAudioRecorder(
            meetingID: UUID(),
            now: Date(),
            sampleRate: sampleRate,
            channelCount: 1
        )
        // Override the recording directory to the temp directory.
        recorder.setRecordingDirectoryURL(directory)
        return recorder
    }

    // MARK: - Atomic rename on clean stop

    @Test func atomicRenameOnCleanStop() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-recorder-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recorder = makeRecorder(in: tempDir)
        // Use the test hook to avoid needing a real mic.
        recorder.appendMicSamples(sineWave(amplitude: 0.3, durationSeconds: 1))
        recorder.appendSystemSamples(sineWave(amplitude: 0.2, durationSeconds: 1))

        let recording = await recorder.stop()

        #expect(recording.micFileURL?.lastPathComponent == "mic.wav")
        #expect(recording.systemFileURL?.lastPathComponent == "system.wav")
        #expect(FileManager.default.fileExists(atPath: recording.micFileURL!.path))
        #expect(FileManager.default.fileExists(atPath: recording.systemFileURL!.path))
        // The `.part` files should be gone.
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        #expect(!remaining.contains("mic.wav.part"))
        #expect(!remaining.contains("system.wav.part"))
    }

    // MARK: - Silent mic track still written

    @Test func silentMicTrackIsStillWritten() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-recorder-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recorder = makeRecorder(in: tempDir)
        recorder.appendMicSamples(silence(durationSeconds: 1))
        recorder.appendSystemSamples(sineWave(amplitude: 0.2, durationSeconds: 1))

        let recording = await recorder.stop()

        // The mic file should still exist even though it's silent —
        // the user can verify their mic was muted.
        #expect(recording.micFileURL != nil)
        #expect(FileManager.default.fileExists(atPath: recording.micFileURL!.path))
        #expect(recording.micTrack != nil)
        #expect(recording.micTrack?.samples.allSatisfy { $0 == 0 } == true)
    }

    // MARK: - RIFF header is valid

    @Test func writtenWAVHasValidRIFFHeader() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-recorder-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recorder = makeRecorder(in: tempDir)
        recorder.appendMicSamples(sineWave(amplitude: 0.3, durationSeconds: 1))

        let recording = await recorder.stop()

        let data = try Data(contentsOf: recording.micFileURL!)
        #expect(data.count >= 44)
        // "RIFF"
        #expect(data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46)
        // "WAVE"
        #expect(data[8] == 0x57 && data[9] == 0x41 && data[10] == 0x56 && data[11] == 0x45)
        // "data"
        #expect(data[36] == 0x64 && data[37] == 0x61 && data[38] == 0x74 && data[39] == 0x61)
        // chunkSize = fileSize - 8
        let chunkSize = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        #expect(chunkSize == UInt32(data.count - 8))
        // dataByteCount = fileSize - 44
        let dataByteCount = UInt32(data[40]) | UInt32(data[41]) << 8 | UInt32(data[42]) << 16 | UInt32(data[43]) << 24
        #expect(dataByteCount == UInt32(data.count - 44))
    }

    // MARK: - Crash repair

    @Test func crashRepairPatchesTruncatedRIFFHeader() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-recorder-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recorder = makeRecorder(in: tempDir)
        recorder.appendMicSamples(sineWave(amplitude: 0.3, durationSeconds: 1))
        recorder.appendSystemSamples(sineWave(amplitude: 0.2, durationSeconds: 1))

        // Simulate a crash: stop the recorder WITHOUT finalizing, so
        // the `.part` files keep their placeholder (zero) header.
        // We do this by writing the part files manually with a stale
        // header and PCM data, then calling crashRepairIfNeeded.
        let micPartURL = tempDir.appendingPathComponent("mic.wav.part")
        let samples = sineWave(amplitude: 0.3, durationSeconds: 1)
        var pcmBytes = [UInt8](repeating: 0, count: samples.count * 2)
        for (i, s) in samples.enumerated() {
            let v = Int16(max(-1.0, min(1.0, s)) * Float(Int16.max))
            pcmBytes[i * 2] = UInt8(v & 0xFF)
            pcmBytes[i * 2 + 1] = UInt8((v >> 8) & 0xFF)
        }
        let staleHeader = PaceMeetingAudioRecorder.riffHeaderPlaceholder(
            dataByteCount: 0, sampleRate: sampleRate, channels: 1
        )
        var fileData = Data(staleHeader)
        fileData.append(contentsOf: pcmBytes)
        try fileData.write(to: micPartURL)

        recorder.crashRepairIfNeeded()

        let repairedURL = tempDir.appendingPathComponent("mic.wav")
        #expect(FileManager.default.fileExists(atPath: repairedURL.path))
        let repaired = try Data(contentsOf: repairedURL)
        let dataByteCount = UInt32(repaired[40]) | UInt32(repaired[41]) << 8 | UInt32(repaired[42]) << 16 | UInt32(repaired[43]) << 24
        #expect(dataByteCount == UInt32(repaired.count - 44))
        // The file should be readable by AVAudioFile (playable).
        let audioFile = try AVAudioFile(forReading: repairedURL)
        #expect(audioFile.length > 0)
    }

    // MARK: - System track nil when no samples

    @Test func systemTrackIsNilWhenNoSystemSamples() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pace-recorder-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recorder = makeRecorder(in: tempDir)
        recorder.appendMicSamples(sineWave(amplitude: 0.3, durationSeconds: 1))
        // No system samples appended.

        let recording = await recorder.stop()
        #expect(recording.systemTrack == nil)
        #expect(recording.systemFileURL == nil)
    }
}
