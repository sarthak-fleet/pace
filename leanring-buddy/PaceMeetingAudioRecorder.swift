//
//  PaceMeetingAudioRecorder.swift
//  leanring-buddy
//
//  Owns the mic track via AVAudioEngine + input node tap, and the
//  two-track disk writer. Each track is written to a RIFF WAV (16-bit
//  PCM) under ~/Library/Application Support/Pace/meetings/<id>/ with a
//  `.part` suffix during recording; a clean stop atomically renames
//  to the final path. RIFF-header repair on crash-recovery scan
//  patches truncated headers by recomputing chunk sizes from the file
//  length so a force-quit mid-meeting still yields a playable file.
//
//  See docs/prds/on-device-meeting-notes.md for the full spec.
//

import AVFoundation
import Foundation

/// The result of a clean recording stop: final URLs for both tracks.
nonisolated struct PaceMeetingRecording: Equatable, Sendable {
    let meetingID: UUID
    let startedAt: Date
    let endedAt: Date
    let micFileURL: URL?
    let systemFileURL: URL?
    let micTrack: PaceMeetingAudioTrack?
    let systemTrack: PaceMeetingAudioTrack?
}

/// Two-track meeting audio recorder. `@MainActor` because AVAudioEngine
/// and its tap callbacks are main-actor-affine in Pace's usage.
@MainActor
final class PaceMeetingAudioRecorder {
    let meetingID: UUID
    private(set) var micTrack: PaceMeetingAudioTrack?
    private(set) var systemTrack: PaceMeetingAudioTrack?
    private(set) var recordingDirectoryURL: URL

    private let startedAt: Date
    private let sampleRate: Double
    private let channelCount: Int

    private var audioEngine: AVAudioEngine?
    private var micSamples: [Float] = []
    private var systemSamples: [Float] = []
    private var micPartURL: URL?
    private var systemPartURL: URL?
    private var micFileHandle: FileHandle?
    private var systemFileHandle: FileHandle?
    private var micDataByteCount: Int = 0
    private var systemDataByteCount: Int = 0

    init(meetingID: UUID, now: Date = Date(), sampleRate: Double = 16_000, channelCount: Int = 1) {
        self.meetingID = meetingID
        self.startedAt = now
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.recordingDirectoryURL = Self.defaultRecordingDirectoryURL(for: meetingID)
    }

    /// Override the recording directory. Used by tests to write into
    /// a temp directory instead of ~/Library/Application Support.
    func setRecordingDirectoryURL(_ url: URL) {
        recordingDirectoryURL = url
    }

    // MARK: - Mic capture

    /// Start mic capture via AVAudioEngine input node tap. Throws on
    /// engine start failure or missing input node.
    func startMicCapture() async throws {
        try ensureMicPartFile()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            Task { @MainActor [weak self] in
                self?.appendMicBuffer(buffer)
            }
        }

        audioEngine = engine
        try engine.start()
    }

    private func ensureMicPartFile() throws {
        let directory = recordingDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partURL = directory.appendingPathComponent("mic.wav.part")
        micPartURL = partURL
        micDataByteCount = 0
        try Data(Self.riffHeaderPlaceholder(dataByteCount: 0, sampleRate: sampleRate, channels: UInt16(channelCount)))
            .write(to: partURL, options: .atomic)
        micFileHandle = try FileHandle(forWritingTo: partURL)
        try micFileHandle?.seek(toOffset: 44)
    }

    private func appendMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        // Mono: take channel 0. Multi-channel: downmix to mono.
        let incoming: [Float]
        if buffer.format.channelCount == 1 {
            incoming = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            var mixed = [Float](repeating: 0, count: frameCount)
            for channelIndex in 0..<Int(buffer.format.channelCount) {
                let channel = channelData[channelIndex]
                for i in 0..<frameCount {
                    mixed[i] += channel[i]
                }
            }
            let scale: Float = 1.0 / Float(buffer.format.channelCount)
            for i in 0..<frameCount {
                mixed[i] *= scale
            }
            incoming = mixed
        }
        appendMicSamples(incoming)
    }

    /// Append mic samples directly (test hook + internal path).
    func appendMicSamples(_ samples: [Float]) {
        if micPartURL == nil {
            do {
                try ensureMicPartFile()
            } catch {
                return
            }
        }
        guard !samples.isEmpty else { return }
        micSamples.append(contentsOf: samples)
        writePCMSamples(samples, to: micFileHandle, byteCount: &micDataByteCount)
    }

    /// Append system samples, called by the SCStream delegate.
    func appendSystemSamples(_ samples: [Float]) {
        if systemPartURL == nil {
            // Lazily create the system track file on first sample.
            do {
                try ensureSystemPartFile()
            } catch {
                // Fail loud: a system-track write failure means the
                // meeting recording is incomplete. The caller decides
                // whether to abort.
                return
            }
        }
        guard !samples.isEmpty else { return }
        systemSamples.append(contentsOf: samples)
        writePCMSamples(samples, to: systemFileHandle, byteCount: &systemDataByteCount)
    }

    private func ensureSystemPartFile() throws {
        let directory = recordingDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partURL = directory.appendingPathComponent("system.wav.part")
        systemPartURL = partURL
        systemDataByteCount = 0
        try Data(Self.riffHeaderPlaceholder(dataByteCount: 0, sampleRate: sampleRate, channels: UInt16(channelCount)))
            .write(to: partURL, options: .atomic)
        systemFileHandle = try FileHandle(forWritingTo: partURL)
        try systemFileHandle?.seek(toOffset: 44)
    }

    // MARK: - Stop

    /// Flush both tracks, finalize RIFF headers, and atomically rename
    /// `.part` files to their final paths. Returns the recording
    /// descriptor with final URLs and in-memory tracks.
    func stop() async -> PaceMeetingRecording {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        micTrack = PaceMeetingAudioTrack(samples: micSamples, sampleRate: sampleRate, channelCount: channelCount)
        systemTrack = systemSamples.isEmpty
            ? nil
            : PaceMeetingAudioTrack(samples: systemSamples, sampleRate: sampleRate, channelCount: channelCount)

        let micFinalURL = finalizeTrack(partURL: micPartURL, fileHandle: micFileHandle, dataByteCount: micDataByteCount, finalName: "mic.wav")
        let systemFinalURL = finalizeTrack(partURL: systemPartURL, fileHandle: systemFileHandle, dataByteCount: systemDataByteCount, finalName: "system.wav")

        micPartURL = nil
        systemPartURL = nil
        micFileHandle = nil
        systemFileHandle = nil

        return PaceMeetingRecording(
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: Date(),
            micFileURL: micFinalURL,
            systemFileURL: systemFinalURL,
            micTrack: micTrack,
            systemTrack: systemTrack
        )
    }

    private func finalizeTrack(partURL: URL?, fileHandle: FileHandle?, dataByteCount: Int, finalName: String) -> URL? {
        guard let partURL else { return nil }
        // Patch the RIFF header with the real chunk sizes before close.
        if let fileHandle {
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }
        let header = Self.riffHeaderPlaceholder(
            dataByteCount: UInt32(dataByteCount),
            sampleRate: sampleRate,
            channels: UInt16(channelCount)
        )
        let headerData = Data(header)
        // Overwrite the header in place. The file is still named
        // `.part` so a crash here leaves the part file with a
        // stale header — `crashRepairIfNeeded` fixes that.
        if let handle = try? FileHandle(forUpdating: partURL) {
            _ = try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: headerData)
            try? handle.synchronize()
            try? handle.close()
        }
        let finalURL = recordingDirectoryURL.appendingPathComponent(finalName)
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partURL, to: finalURL)
            return finalURL
        } catch {
            // Atomic rename failed — leave the `.part` file in place so
            // `crashRepairIfNeeded` can recover it on next launch.
            return partURL
        }
    }

    // MARK: - Crash repair

    /// Scan the recording directory for `.part` files and patch
    /// truncated RIFF headers by recomputing chunk sizes from the
    /// actual file length. Called at launch. Safe to call when no
    /// recording is in progress (no-op).
    func crashRepairIfNeeded() {
        let fm = FileManager.default
        guard let candidates = try? fm.contentsOfDirectory(at: recordingDirectoryURL, includingPropertiesForKeys: nil) else {
            return
        }
        for partURL in candidates where partURL.pathExtension == "part" {
            repairRIFFPartFile(at: partURL)
        }
    }

    private func repairRIFFPartFile(at partURL: URL) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: partURL.path),
              let fileSize = attributes[.size] as? Int else { return }
        guard fileSize >= 44 else { return }
        let dataByteCount = UInt32(fileSize - 44)
        let finalName: String
        if partURL.lastPathComponent.hasPrefix("mic") {
            finalName = "mic.wav"
        } else if partURL.lastPathComponent.hasPrefix("system") {
            finalName = "system.wav"
        } else {
            finalName = partURL.deletingPathExtension().lastPathComponent + ".wav"
        }
        let header = Self.riffHeaderPlaceholder(
            dataByteCount: dataByteCount,
            sampleRate: sampleRate,
            channels: UInt16(channelCount)
        )
        let headerData = Data(header)
        if let handle = try? FileHandle(forUpdating: partURL) {
            _ = try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: headerData)
            try? handle.synchronize()
            try? handle.close()
        }
        let finalURL = recordingDirectoryURL.appendingPathComponent(finalName)
        do {
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: partURL, to: finalURL)
        } catch {
            // Leave the part file; it's at least playable now.
        }
    }

    // MARK: - RIFF WAV header

    /// 44-byte RIFF WAV header for 16-bit PCM. `dataByteCount` is the
    /// size of the PCM data payload (file length minus 44).
    nonisolated static func riffHeaderPlaceholder(dataByteCount: UInt32, sampleRate: Double, channels: UInt16) -> [UInt8] {
        let byteRate = UInt32(sampleRate) * UInt32(channels) * 2
        let blockAlign = UInt16(channels) * 2
        let chunkSize = 36 + dataByteCount
        var header = [UInt8](repeating: 0, count: 44)
        // "RIFF"
        header[0] = 0x52; header[1] = 0x49; header[2] = 0x46; header[3] = 0x46
        writeUInt32LE(into: &header, at: 4, value: chunkSize)
        // "WAVE"
        header[8] = 0x57; header[9] = 0x41; header[10] = 0x56; header[11] = 0x45
        // "fmt "
        header[12] = 0x66; header[13] = 0x6D; header[14] = 0x74; header[15] = 0x20
        writeUInt32LE(into: &header, at: 16, value: 16) // PCM fmt chunk size
        writeUInt16LE(into: &header, at: 20, value: 1)  // PCM format
        writeUInt16LE(into: &header, at: 22, value: channels)
        writeUInt32LE(into: &header, at: 24, value: UInt32(sampleRate))
        writeUInt32LE(into: &header, at: 28, value: byteRate)
        writeUInt16LE(into: &header, at: 32, value: blockAlign)
        writeUInt16LE(into: &header, at: 34, value: 16) // bits per sample
        // "data"
        header[36] = 0x64; header[37] = 0x61; header[38] = 0x74; header[39] = 0x61
        writeUInt32LE(into: &header, at: 40, value: dataByteCount)
        return header
    }

    private nonisolated static func writeUInt32LE(into buffer: inout [UInt8], at offset: Int, value: UInt32) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private nonisolated static func writeUInt16LE(into buffer: inout [UInt8], at offset: Int, value: UInt16) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    // MARK: - PCM writing

    private func writePCMSamples(_ samples: [Float], to fileHandle: FileHandle?, byteCount: inout Int) {
        guard let fileHandle else { return }
        // Convert Float32 [-1, 1] to 16-bit PCM little-endian.
        var pcmBytes = [UInt8](repeating: 0, count: samples.count * 2)
        for (index, sample) in samples.enumerated() {
            let clamped = max(-1.0, min(1.0, sample))
            let intValue = Int16(clamped * Float(Int16.max))
            let byteOffset = index * 2
            pcmBytes[byteOffset] = UInt8(intValue & 0xFF)
            pcmBytes[byteOffset + 1] = UInt8((intValue >> 8) & 0xFF)
        }
        try? fileHandle.write(contentsOf: Data(pcmBytes))
        byteCount += pcmBytes.count
    }

    // MARK: - Directory

    nonisolated static func defaultRecordingDirectoryURL(for meetingID: UUID) -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pace/meetings/\(meetingID.uuidString)")
    }
}
