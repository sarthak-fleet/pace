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

/// Errors thrown by the meeting audio recorder's mic capture setup.
nonisolated enum PaceMeetingAudioRecorderError: Error {
    case cannotCreateTargetAudioFormat
    case cannotCreateSampleRateConverter
}

/// The result of a clean recording stop: final URLs for both tracks.
nonisolated struct PaceMeetingRecording: Equatable, Sendable {
    let meetingID: UUID
    let startedAt: Date
    let endedAt: Date
    let micFileURL: URL?
    let systemFileURL: URL?
    let micTrack: PaceMeetingAudioTrack?
    let systemTrack: PaceMeetingAudioTrack?
    /// Wall-clock time of the earliest captured sample across both
    /// tracks. The segmenter's global timeline anchor — turn
    /// timestamps are offsets from this, and each track's
    /// `startOffsetSeconds` is relative to it. Nil when neither track
    /// received any samples.
    let earliestSampleAnchor: Date?
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
    /// Converts the mic tap's hardware format (typically 44.1/48 kHz,
    /// possibly multi-channel) down to the recorder's target format.
    /// One converter instance for the whole meeting so the resampler's
    /// internal filter state stays continuous across buffers. Without
    /// this conversion the WAV header would claim 16 kHz for 48 kHz
    /// samples and every downstream consumer (playback, WhisperKit,
    /// turn timestamps) would run ~3× slow.
    private var micFormatConverter: AVAudioConverter?
    private var micConverterOutputFormat: AVAudioFormat?
    /// Off-main-actor, order-preserving disk writers — one per track.
    /// These replace the old per-buffer `Task { @MainActor in append(...) }`
    /// hops, which had two flaws: independently-scheduled tasks carry no
    /// FIFO guarantee (buffers could land in the WAV out of order), and
    /// PCM conversion + `FileHandle` writes ran on the main thread. Each
    /// writer drains its samples on a single serial consumer, off the main
    /// actor, in exactly the order they were produced. See
    /// `MeetingTrackWriter` at the bottom of this file. Created lazily on
    /// first sample so a track that never receives audio (e.g. a one-sided
    /// meeting) leaves no `.part` file behind.
    private var micWriter: MeetingTrackWriter?
    private var systemWriter: MeetingTrackWriter?

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
    /// engine start failure or missing input node. The tap delivers
    /// buffers in the hardware format; they are resampled to the
    /// recorder's target sample rate (16 kHz mono) before writing so
    /// the WAV header and the actual PCM data agree.
    func startMicCapture() async throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw PaceMeetingAudioRecorderError.cannotCreateTargetAudioFormat
        }
        if inputFormat.sampleRate == targetFormat.sampleRate,
           inputFormat.channelCount == targetFormat.channelCount {
            // Hardware already matches the target — no conversion needed.
            micFormatConverter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw PaceMeetingAudioRecorderError.cannotCreateSampleRateConverter
            }
            micFormatConverter = converter
        }
        micConverterOutputFormat = targetFormat

        // Box the converter so the tap block — which runs on AVAudioEngine's
        // own render thread — can convert samples there without touching the
        // main actor. `MicSampleConverter` is `@unchecked Sendable` because
        // the tap block is the ONLY caller and it is invoked serially by the
        // engine, so the converter's internal filter state stays continuous.
        let micConverter = MicSampleConverter(
            converter: micFormatConverter,
            outputFormat: micConverterOutputFormat
        )
        let writer = ensureMicWriter()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [micConverter, writer] buffer, _ in
            // Convert + downmix on the tap thread, then hand the samples to
            // the off-main serial writer. No hop through the main actor, and
            // the writer preserves FIFO order across buffers.
            let samples = micConverter.monoFloat(from: buffer)
            guard !samples.isEmpty else { return }
            writer.append(samples)
        }

        audioEngine = engine
        try engine.start()
    }

    /// Lazily build the mic-track writer, capturing the current recording
    /// directory + format. Called on the main actor before the tap is
    /// installed and by `appendMicSamples` (the test/internal hook).
    private func ensureMicWriter() -> MeetingTrackWriter {
        if let micWriter { return micWriter }
        let writer = MeetingTrackWriter(
            directoryURL: recordingDirectoryURL,
            partFileName: "mic.wav.part",
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        micWriter = writer
        return writer
    }

    /// Lazily build the system-track writer. See `makeSystemSampleSink()`.
    private func ensureSystemWriter() -> MeetingTrackWriter {
        if let systemWriter { return systemWriter }
        let writer = MeetingTrackWriter(
            directoryURL: recordingDirectoryURL,
            partFileName: "system.wav.part",
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        systemWriter = writer
        return writer
    }

    /// Returns a `Sendable` sink the SCStream delegate captures to push
    /// system-track samples straight to the off-main writer, in FIFO order,
    /// without hopping through the main actor for each buffer. Call this on
    /// the main actor at capture start; invoke the returned closure from the
    /// delegate's serial sample-handler queue. Creating the writer here does
    /// NOT create a file — the `.part` file is written lazily on the first
    /// sample, so a one-sided meeting (no system audio) leaves no file and
    /// `stop()` reports a nil system track, exactly as before.
    func makeSystemSampleSink() -> @Sendable ([Float]) -> Void {
        let writer = ensureSystemWriter()
        return { samples in
            guard !samples.isEmpty else { return }
            writer.append(samples)
        }
    }

    /// Append mic samples directly (test hook + internal path). Samples are
    /// handed to the off-main serial writer; nothing accumulates on the main
    /// actor, so an hour-long meeting costs disk, not RAM. The tracks are
    /// read back from the finalized WAVs at `stop()`.
    func appendMicSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        ensureMicWriter().append(samples)
    }

    /// Append system samples. In the live capture path the SCStream delegate
    /// uses `makeSystemSampleSink()` instead; this remains for the test hook.
    func appendSystemSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        ensureSystemWriter().append(samples)
    }

    // MARK: - Stop

    /// Flush both tracks, finalize RIFF headers, and atomically rename
    /// `.part` files to their final paths. Returns the recording
    /// descriptor with final URLs and tracks read back from the
    /// finalized files (recording keeps nothing in RAM; the read-back
    /// is a transient allocation for segmentation/transcription).
    func stop() async -> PaceMeetingRecording {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micFormatConverter = nil
        micConverterOutputFormat = nil

        // Finish both writers and wait for their consumer tasks to drain
        // every buffered sample to disk, then read back the finalized state
        // (part URL, byte count, first-sample time). This await is what lets
        // stop() see a complete file even though the writes ran async.
        let micState = await micWriter?.finishAndDrain()
        let systemState = await systemWriter?.finishAndDrain()
        micWriter = nil
        systemWriter = nil

        let micFinalURL = finalizeTrack(state: micState, finalName: "mic.wav")
        let systemFinalURL = finalizeTrack(state: systemState, finalName: "system.wav")

        let micSamplesFromDisk = micFinalURL.flatMap { Self.readMonoFloatSamplesFromPCM16WAV(at: $0) } ?? []
        let systemSamplesFromDisk = systemFinalURL.flatMap { Self.readMonoFloatSamplesFromPCM16WAV(at: $0) } ?? []

        // Per-track start offsets relative to the earliest captured
        // sample, so the segmenter can align both tracks on one
        // timeline (the SCStream starts after the mic).
        let micFirstSampleAt = micState?.firstSampleAt
        let systemFirstSampleAt = systemState?.firstSampleAt
        let earliestSampleAnchor = [micFirstSampleAt, systemFirstSampleAt].compactMap { $0 }.min()
        var micStartOffsetSeconds: TimeInterval = 0
        if let micFirstSampleAt, let earliestSampleAnchor {
            micStartOffsetSeconds = micFirstSampleAt.timeIntervalSince(earliestSampleAnchor)
        }
        var systemStartOffsetSeconds: TimeInterval = 0
        if let systemFirstSampleAt, let earliestSampleAnchor {
            systemStartOffsetSeconds = systemFirstSampleAt.timeIntervalSince(earliestSampleAnchor)
        }

        micTrack = PaceMeetingAudioTrack(
            samples: micSamplesFromDisk,
            sampleRate: sampleRate,
            channelCount: channelCount,
            startOffsetSeconds: micStartOffsetSeconds
        )
        systemTrack = systemSamplesFromDisk.isEmpty
            ? nil
            : PaceMeetingAudioTrack(
                samples: systemSamplesFromDisk,
                sampleRate: sampleRate,
                channelCount: channelCount,
                startOffsetSeconds: systemStartOffsetSeconds
            )

        return PaceMeetingRecording(
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: Date(),
            micFileURL: micFinalURL,
            systemFileURL: systemFinalURL,
            micTrack: micTrack,
            systemTrack: systemTrack,
            earliestSampleAnchor: earliestSampleAnchor
        )
    }

    private func finalizeTrack(state: MeetingTrackFinalState?, finalName: String) -> URL? {
        guard let state, let partURL = state.partURL else { return nil }
        // The writer's consumer already closed its write handle when the
        // stream finished. Patch the RIFF header with the real chunk sizes.
        let header = Self.riffHeaderPlaceholder(
            dataByteCount: UInt32(state.dataByteCount),
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

    /// Repair `.part` files in THIS recorder's directory. Test hook /
    /// convenience — the launch path uses the static all-directories
    /// sweep below, because after a force-quit the crashed meeting's
    /// UUID is unknowable to a freshly constructed recorder.
    func crashRepairIfNeeded() {
        Self.crashRepairPartFiles(inDirectory: recordingDirectoryURL)
    }

    /// Sweep EVERY meeting directory under the meetings root and patch
    /// any `.part` file left behind by a crash. Called from
    /// `CompanionManager.start()` at launch and from the Settings
    /// repair button. Safe no-op when nothing needs repair.
    nonisolated static func crashRepairAllMeetingRecordings() {
        let fm = FileManager.default
        guard let meetingDirectories = try? fm.contentsOfDirectory(
            at: meetingsRootDirectoryURL(),
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for meetingDirectory in meetingDirectories {
            crashRepairPartFiles(inDirectory: meetingDirectory)
        }
    }

    /// Delete meeting recording directories older than the retention
    /// window (matched against the directory's content-modification
    /// date). Recordings are continuous room audio — retaining them
    /// forever contradicts the privacy posture, so the same retention
    /// preference that prunes the notes journal prunes the audio.
    nonisolated static func pruneMeetingRecordings(olderThanDays retentionDays: Int, now: Date = Date()) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        guard let meetingDirectories = try? fm.contentsOfDirectory(
            at: meetingsRootDirectoryURL(),
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for meetingDirectory in meetingDirectories {
            guard let modificationDate = (try? meetingDirectory.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate else { continue }
            if modificationDate < cutoff {
                try? fm.removeItem(at: meetingDirectory)
            }
        }
    }

    nonisolated private static func crashRepairPartFiles(inDirectory directory: URL) {
        let fm = FileManager.default
        guard let candidates = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for partURL in candidates where partURL.pathExtension == "part" {
            repairRIFFPartFile(at: partURL, inDirectory: directory)
        }
    }

    /// Patch a `.part` file's RIFF chunk sizes from the actual file
    /// length, then rename it to its final `.wav` name. Only the two
    /// size fields are rewritten — the sample rate and channel count
    /// already in the placeholder header are the truth about how the
    /// PCM data was recorded and must be preserved.
    nonisolated private static func repairRIFFPartFile(at partURL: URL, inDirectory directory: URL) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: partURL.path),
              let fileSize = attributes[.size] as? Int else { return }
        guard fileSize >= 44 else { return }
        let dataByteCount = UInt32(fileSize - 44)
        let chunkSize = UInt32(fileSize - 8)
        let finalName: String
        if partURL.lastPathComponent.hasPrefix("mic") {
            finalName = "mic.wav"
        } else if partURL.lastPathComponent.hasPrefix("system") {
            finalName = "system.wav"
        } else {
            finalName = partURL.deletingPathExtension().lastPathComponent + ".wav"
        }
        if let handle = try? FileHandle(forUpdating: partURL) {
            var chunkSizeBytes = [UInt8](repeating: 0, count: 4)
            writeUInt32LE(into: &chunkSizeBytes, at: 0, value: chunkSize)
            var dataByteCountBytes = [UInt8](repeating: 0, count: 4)
            writeUInt32LE(into: &dataByteCountBytes, at: 0, value: dataByteCount)
            _ = try? handle.seek(toOffset: 4)
            try? handle.write(contentsOf: Data(chunkSizeBytes))
            _ = try? handle.seek(toOffset: 40)
            try? handle.write(contentsOf: Data(dataByteCountBytes))
            try? handle.synchronize()
            try? handle.close()
        }
        let finalURL = directory.appendingPathComponent(finalName)
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

    nonisolated static func writePCMSamples(_ samples: [Float], to fileHandle: FileHandle?, byteCount: inout Int) {
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
        do {
            try fileHandle.write(contentsOf: Data(pcmBytes))
            // Only count bytes that actually landed — a silently failed
            // write must not drift the RIFF header from the file contents.
            byteCount += pcmBytes.count
        } catch {
            // Dropped buffer; the header stays consistent with the file.
        }
    }

    // MARK: - PCM reading

    /// Read a 16-bit PCM mono WAV written by this recorder back into
    /// Float samples. Used at `stop()` so recording never holds the
    /// meeting's audio in RAM. Returns nil when the file is missing or
    /// shorter than a RIFF header.
    nonisolated static func readMonoFloatSamplesFromPCM16WAV(at fileURL: URL) -> [Float]? {
        guard let fileData = try? Data(contentsOf: fileURL), fileData.count > 44 else { return nil }
        let pcmData = fileData.dropFirst(44)
        let sampleCount = pcmData.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        let scale = 1.0 / Float(Int16.max)
        pcmData.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.baseAddress!
            for sampleIndex in 0..<sampleCount {
                let low = base.load(fromByteOffset: sampleIndex * 2, as: UInt8.self)
                let high = base.load(fromByteOffset: sampleIndex * 2 + 1, as: UInt8.self)
                let intValue = Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))
                samples[sampleIndex] = Float(intValue) * scale
            }
        }
        return samples
    }

    // MARK: - Directory

    nonisolated static func meetingsRootDirectoryURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pace/meetings")
    }

    nonisolated static func defaultRecordingDirectoryURL(for meetingID: UUID) -> URL {
        meetingsRootDirectoryURL().appendingPathComponent(meetingID.uuidString)
    }
}

// MARK: - Off-main-actor track writer

/// The finalized state of one meeting audio track after its writer drains.
/// `partURL` is nil when the track never received any samples, so `stop()`
/// reports a nil track (e.g. a one-sided meeting with no system audio).
nonisolated struct MeetingTrackFinalState: Sendable {
    let partURL: URL?
    let dataByteCount: Int
    let firstSampleAt: Date?
}

/// Serial, off-main-actor disk writer for ONE meeting audio track.
///
/// The previous capture path hopped every incoming buffer to the main actor
/// with `Task { @MainActor in append(...) }`. That had two problems this
/// writer fixes:
///   1. **No FIFO guarantee.** Independently-scheduled tasks can run in any
///      order, so buffers could be written to the WAV out of sequence and
///      garble the audio.
///   2. **Main-thread I/O.** Float32 → PCM16 conversion and `FileHandle`
///      writes ran on the main thread, competing with UI work.
///
/// Samples enter through an `AsyncStream` continuation — `yield` is
/// thread-safe and preserves call order — and are drained on a single
/// detached consumer task. Because ONE task owns the file handle and byte
/// counter, and the stream preserves order, samples always land in the file
/// in exactly the order they were produced, and never on the main actor.
/// The `.part` file is created lazily on the first sample, matching the old
/// lazy behaviour (a track that gets no audio leaves no file behind).
final class MeetingTrackWriter: Sendable {
    private let continuation: AsyncStream<[Float]>.Continuation
    private let consumerTask: Task<MeetingTrackFinalState, Never>

    init(directoryURL: URL, partFileName: String, sampleRate: Double, channelCount: Int) {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.consumerTask = Task.detached(priority: .userInitiated) {
            // ALL mutable write state is local to this single consumer, so
            // there is no data race and the drain order matches the yield
            // order (the AsyncStream buffers in FIFO).
            var fileHandle: FileHandle?
            var partURL: URL?
            var dataByteCount = 0
            var firstSampleAt: Date?

            for await samples in stream {
                guard !samples.isEmpty else { continue }
                if partURL == nil {
                    // Lazily create the `.part` file on the first real sample.
                    do {
                        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                        let url = directoryURL.appendingPathComponent(partFileName)
                        let header = PaceMeetingAudioRecorder.riffHeaderPlaceholder(
                            dataByteCount: 0,
                            sampleRate: sampleRate,
                            channels: UInt16(channelCount)
                        )
                        try Data(header).write(to: url, options: .atomic)
                        let handle = try FileHandle(forWritingTo: url)
                        try handle.seek(toOffset: 44)
                        partURL = url
                        fileHandle = handle
                    } catch {
                        // File creation failed — drop this buffer and retry
                        // on the next one, matching the old append path which
                        // silently returned on a create failure.
                        continue
                    }
                }
                if firstSampleAt == nil { firstSampleAt = Date() }
                PaceMeetingAudioRecorder.writePCMSamples(samples, to: fileHandle, byteCount: &dataByteCount)
            }

            // Stream finished (`finishAndDrain()` called). Close the write
            // handle; `finalizeTrack` reopens the file to patch the header.
            try? fileHandle?.synchronize()
            try? fileHandle?.close()
            return MeetingTrackFinalState(partURL: partURL, dataByteCount: dataByteCount, firstSampleAt: firstSampleAt)
        }
    }

    /// Push samples for writing. Thread-safe and order-preserving; returns
    /// immediately (the write happens on the consumer task).
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        continuation.yield(samples)
    }

    /// Finish the stream and await the consumer draining every buffered
    /// sample to disk. Returns the finalized track state.
    func finishAndDrain() async -> MeetingTrackFinalState {
        continuation.finish()
        return await consumerTask.value
    }
}

// MARK: - Mic sample conversion

/// Resamples an `AVAudioPCMBuffer` from the mic tap's hardware format to the
/// recorder's target format and downmixes to mono. `@unchecked Sendable`
/// because the ONLY caller is the tap block, which AVAudioEngine invokes
/// serially on a single render thread — so the wrapped `AVAudioConverter`'s
/// internal filter state stays continuous and is never touched concurrently.
final class MicSampleConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat?

    init(converter: AVAudioConverter?, outputFormat: AVAudioFormat?) {
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// Convert + downmix the buffer to a mono `[Float]` at the target rate.
    func monoFloat(from buffer: AVAudioPCMBuffer) -> [Float] {
        // Resample the hardware-format buffer to the target format first, so
        // downmix and disk writes always operate on samples that match the
        // WAV header's declared rate.
        let convertedBuffer: AVAudioPCMBuffer
        if let converter, let outputFormat {
            let rateRatio = outputFormat.sampleRate / buffer.format.sampleRate
            let outputCapacity = AVAudioFrameCount((Double(buffer.frameLength) * rateRatio).rounded(.up) + 16)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                return []
            }
            var didProvideInputBuffer = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if didProvideInputBuffer {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInputBuffer = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil else { return [] }
            convertedBuffer = outputBuffer
        } else {
            convertedBuffer = buffer
        }

        guard let channelData = convertedBuffer.floatChannelData else { return [] }
        let frameCount = Int(convertedBuffer.frameLength)
        guard frameCount > 0 else { return [] }
        // Mono: take channel 0. Multi-channel: downmix to mono.
        if convertedBuffer.format.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        var mixed = [Float](repeating: 0, count: frameCount)
        for channelIndex in 0..<Int(convertedBuffer.format.channelCount) {
            let channel = channelData[channelIndex]
            for i in 0..<frameCount {
                mixed[i] += channel[i]
            }
        }
        let scale: Float = 1.0 / Float(convertedBuffer.format.channelCount)
        for i in 0..<frameCount {
            mixed[i] *= scale
        }
        return mixed
    }
}
