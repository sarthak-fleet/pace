//
//  PaceCompanionPerceptionSources.swift
//  leanring-buddy
//
//  Concrete, dependency-injected camera and ambient-voice adapters. Raw frame
//  and audio values stay inside their source loop and are never persisted.
//

import Foundation

nonisolated enum PacePerceptionPermissionState: Equatable, Sendable {
    case authorized
    case denied
    case unavailable
}

nonisolated enum PacePerceptionSourceError: Error, Equatable {
    case sourceDisabled
    case permissionDenied
    case deviceUnavailable
}

nonisolated struct PaceCameraZone: Hashable, Codable, Sendable {
    let name: String
    let minimumX: Double
    let maximumX: Double
    let minimumY: Double
    let maximumY: Double

    init(name: String, minimumX: Double, maximumX: Double, minimumY: Double, maximumY: Double) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minimumX = min(max(minimumX, 0), 1)
        self.maximumX = min(max(maximumX, self.minimumX), 1)
        self.minimumY = min(max(minimumY, 0), 1)
        self.maximumY = min(max(maximumY, self.minimumY), 1)
    }

    func contains(normalizedX: Double, normalizedY: Double) -> Bool {
        (minimumX...maximumX).contains(normalizedX) && (minimumY...maximumY).contains(normalizedY)
    }
}

nonisolated enum PaceCameraDetectionKind: Hashable, Codable, Sendable {
    case person
    case object(label: String, isUserTaught: Bool)
}

nonisolated struct PaceCameraDetection: Hashable, Codable, Sendable {
    let kind: PaceCameraDetectionKind
    let ephemeralTrackIdentifier: String
    let normalizedCenterX: Double
    let normalizedCenterY: Double
    let confidence: Double
}

nonisolated struct PaceCameraFrame: Equatable, Sendable {
    let capturedAt: Date
    let motionScore: Double
    let detections: [PaceCameraDetection]
    let rawFrame: Data
}

nonisolated protocol PaceCameraCaptureClient: Sendable {
    func permissionState() async -> PacePerceptionPermissionState
    func frames(maximumFramesPerSecond: Double) async throws -> AsyncStream<PaceCameraFrame>
    func stop() async
    func teachObject(label: String) async throws
    func removeTaughtObject(label: String) async throws
    func taughtObjectLabels() async -> [String]
}

nonisolated extension PaceCameraCaptureClient {
    func teachObject(label: String) async throws { throw PaceTaughtObjectError.cameraNotActive }
    func removeTaughtObject(label: String) async throws { }
    func taughtObjectLabels() async -> [String] { [] }
}

@MainActor
final class PaceCameraPerceptionSource: PacePerceptionSourceAdapter {
    nonisolated let sourceKind: PacePerceptionSourceKind = .camera
    private let captureClient: any PaceCameraCaptureClient
    private let zones: [PaceCameraZone]
    private let maximumFramesPerSecond: Double
    private let meaningfulMotionThreshold: Double
    private var isEnabled: Bool
    private var isStopped = false
    private var lastAcceptedDetectionSignatures: Set<String>?
    private var rawFrameBuffer = PaceBoundedRawDataBuffer(
        maximumValueCount: 1,
        maximumTotalByteCount: 16 * 1_024 * 1_024
    )

    init(
        captureClient: any PaceCameraCaptureClient,
        zones: [PaceCameraZone],
        isEnabled: Bool,
        maximumFramesPerSecond: Double = 1,
        meaningfulMotionThreshold: Double = 0.08
    ) {
        self.captureClient = captureClient
        self.zones = zones.filter { $0.name.isEmpty == false }
        self.isEnabled = isEnabled
        self.maximumFramesPerSecond = min(max(maximumFramesPerSecond, 0.1), 2)
        self.meaningfulMotionThreshold = min(max(meaningfulMotionThreshold, 0), 1)
    }

    func start(emit: @escaping @Sendable (PaceObservationCandidate) -> Void) async throws {
        guard isEnabled else { throw PacePerceptionSourceError.sourceDisabled }
        switch await captureClient.permissionState() {
        case .authorized: break
        case .denied: throw PacePerceptionSourceError.permissionDenied
        case .unavailable: throw PacePerceptionSourceError.deviceUnavailable
        }
        isStopped = false
        let frameStream = try await captureClient.frames(maximumFramesPerSecond: maximumFramesPerSecond)
        for await frame in frameStream {
            guard Task.isCancelled == false, isStopped == false else { break }
            rawFrameBuffer.append(frame.rawFrame)
            let acceptedCandidates = acceptedCandidates(for: frame)
            for candidate in acceptedCandidates {
                emit(candidate)
            }
            rawFrameBuffer.removeAll()
            // `frame.rawFrame` falls out of scope here. Neither candidates nor
            // observations carry it across the source boundary.
        }
    }

    func stop() async {
        isStopped = true
        lastAcceptedDetectionSignatures = nil
        rawFrameBuffer.removeAll()
        await captureClient.stop()
    }

    private func acceptedCandidates(for frame: PaceCameraFrame) -> [PaceObservationCandidate] {
        let detectionSignatures = Set(frame.detections.map(detectionSignature))
        let detectionsChanged = detectionSignatures != lastAcceptedDetectionSignatures
        guard frame.motionScore >= meaningfulMotionThreshold || detectionsChanged else { return [] }
        let previousDetectionSignatures = lastAcceptedDetectionSignatures ?? []
        lastAcceptedDetectionSignatures = detectionSignatures

        return frame.detections.compactMap { detection in
            // A motion-heavy frame can contain a person who was already in
            // view. Re-emitting that stable track as `.entered` would turn
            // ordinary movement into false person-entry evidence. Object
            // locations likewise need a new track/zone signature, not every
            // accepted motion frame.
            guard previousDetectionSignatures.contains(detectionSignature(detection)) == false else {
                return nil
            }
            guard let payload = try? JSONEncoder().encode(PaceCameraCandidatePayload(
                detection: detection,
                zoneName: zone(for: detection)?.name
            )), let payloadText = String(data: payload, encoding: .utf8) else {
                return nil
            }
            return PaceObservationCandidate(
                source: .camera,
                capturedAt: frame.capturedAt,
                equivalenceKey: "camera:\(detection.ephemeralTrackIdentifier)",
                priority: detection.kind == .person ? 2 : 1,
                structuredPayload: payloadText,
                evidenceReference: try? PaceEvidenceReference(
                    type: "camera-structured-detection",
                    identifier: UUID().uuidString
                )
            )
        }
    }

    private func detectionSignature(_ detection: PaceCameraDetection) -> String {
        "\(detection.ephemeralTrackIdentifier):\(detection.kind):\(zone(for: detection)?.name ?? "unknown")"
    }

    private func zone(for detection: PaceCameraDetection) -> PaceCameraZone? {
        zones.first { $0.contains(
            normalizedX: detection.normalizedCenterX,
            normalizedY: detection.normalizedCenterY
        ) }
    }
}

nonisolated struct PaceCameraCandidatePayload: Codable, Equatable, Sendable {
    let detection: PaceCameraDetection
    let zoneName: String?
}

nonisolated enum PaceCameraObservationInterpreter {
    static func observation(
        from candidate: PaceObservationCandidate,
        trackLifetime: TimeInterval = 60
    ) throws -> PaceWorldObservation? {
        guard candidate.source == .camera,
              let payloadData = candidate.structuredPayload.data(using: .utf8) else { return nil }
        let payload = try JSONDecoder().decode(PaceCameraCandidatePayload.self, from: payloadData)
        let location = try payload.zoneName.map { try PaceWorldLocation(source: .camera, zone: $0) }
        switch payload.detection.kind {
        case .person:
            return try PaceWorldObservation(
                observedAt: candidate.capturedAt,
                source: .camera,
                subject: PaceWorldSubject(
                    kind: .personPresence,
                    identifier: normalizedEphemeralTrackIdentifier(payload.detection.ephemeralTrackIdentifier)
                ),
                predicate: .entered,
                value: .presence,
                location: location,
                confidence: payload.detection.confidence,
                evidenceReference: candidate.evidenceReference,
                expiresAt: candidate.capturedAt.addingTimeInterval(max(1, trackLifetime))
            )
        case .object(let label, let isUserTaught):
            guard isUserTaught else { return nil }
            return try PaceWorldObservation(
                observedAt: candidate.capturedAt,
                source: .camera,
                subject: PaceWorldSubject(kind: .object, identifier: label),
                predicate: .isLocatedAt,
                value: .text(label),
                location: location,
                confidence: payload.detection.confidence,
                evidenceReference: candidate.evidenceReference,
                expiresAt: candidate.capturedAt.addingTimeInterval(max(1, trackLifetime))
            )
        }
    }

    private static func normalizedEphemeralTrackIdentifier(_ identifier: String) -> String {
        let suffix = identifier
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "ephemeral-track-\(suffix.isEmpty ? UUID().uuidString.lowercased() : suffix)"
    }
}

nonisolated struct PaceAmbientAudioChunk: Equatable, Sendable {
    let capturedAt: Date
    let voiceActivityConfidence: Double
    let wakePhraseConfidence: Double
    let isEndOfUtterance: Bool
    let speakerSignature: String?
    let rawAudio: Data
}

nonisolated protocol PaceAmbientAudioCaptureClient: Sendable {
    func permissionState() async -> PacePerceptionPermissionState
    func audioChunks() async throws -> AsyncStream<PaceAmbientAudioChunk>
    func stop() async
}

nonisolated protocol PaceAmbientOnDeviceTranscriber: Sendable {
    func transcribeOnDevice(_ chunk: PaceAmbientAudioChunk) async throws -> String?
}

@MainActor
final class PaceAmbientVoiceSource: PacePerceptionSourceAdapter {
    nonisolated let sourceKind: PacePerceptionSourceKind = .ambientVoice
    private let captureClient: any PaceAmbientAudioCaptureClient
    private let transcriber: any PaceAmbientOnDeviceTranscriber
    private let sessionDuration: TimeInterval
    private let voiceActivityThreshold: Double
    private let wakePhraseThreshold: Double
    private let isDiarizationEnabled: Bool
    private var isEnabled: Bool
    private var isStopped = false
    private var sessionExpiresAt: Date?
    private var speakerLabelsBySignature: [String: String] = [:]
    private var rawAudioBuffer = PaceBoundedRawDataBuffer(
        maximumValueCount: 4,
        maximumTotalByteCount: 2 * 1_024 * 1_024
    )

    init(
        captureClient: any PaceAmbientAudioCaptureClient,
        transcriber: any PaceAmbientOnDeviceTranscriber,
        isEnabled: Bool,
        sessionDuration: TimeInterval = 45,
        voiceActivityThreshold: Double = 0.6,
        wakePhraseThreshold: Double = 0.8,
        isDiarizationEnabled: Bool = false
    ) {
        self.captureClient = captureClient
        self.transcriber = transcriber
        self.isEnabled = isEnabled
        self.sessionDuration = max(1, sessionDuration)
        self.voiceActivityThreshold = min(max(voiceActivityThreshold, 0), 1)
        self.wakePhraseThreshold = min(max(wakePhraseThreshold, 0), 1)
        self.isDiarizationEnabled = isDiarizationEnabled
    }

    func start(emit: @escaping @Sendable (PaceObservationCandidate) -> Void) async throws {
        guard isEnabled else { throw PacePerceptionSourceError.sourceDisabled }
        switch await captureClient.permissionState() {
        case .authorized: break
        case .denied: throw PacePerceptionSourceError.permissionDenied
        case .unavailable: throw PacePerceptionSourceError.deviceUnavailable
        }
        isStopped = false
        let chunks = try await captureClient.audioChunks()
        for await chunk in chunks {
            guard Task.isCancelled == false, isStopped == false else { break }
            rawAudioBuffer.append(chunk.rawAudio)
            expireSessionIfNeeded(at: chunk.capturedAt)
            guard chunk.voiceActivityConfidence >= voiceActivityThreshold else {
                rawAudioBuffer.removeAll()
                continue
            }

            if sessionExpiresAt == nil {
                guard chunk.wakePhraseConfidence >= wakePhraseThreshold else {
                    // Pre-wake raw audio is deliberately dropped without STT.
                    rawAudioBuffer.removeAll()
                    continue
                }
                sessionExpiresAt = chunk.capturedAt.addingTimeInterval(sessionDuration)
                rawAudioBuffer.removeAll()
                continue
            }

            guard let transcript = try await transcriber.transcribeOnDevice(chunk),
                  transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                if chunk.isEndOfUtterance { endSession() }
                rawAudioBuffer.removeAll()
                continue
            }
            let speakerLabel = ephemeralSpeakerLabel(for: chunk.speakerSignature)
            let payload = PaceAmbientVoiceCandidatePayload(
                transcript: transcript,
                ephemeralSpeakerLabel: speakerLabel
            )
            if let payloadData = try? JSONEncoder().encode(payload),
               let payloadText = String(data: payloadData, encoding: .utf8) {
                emit(PaceObservationCandidate(
                    source: .ambientVoice,
                    capturedAt: chunk.capturedAt,
                    equivalenceKey: "ambient-voice-session",
                    priority: 2,
                    structuredPayload: payloadText
                ))
            }
            if chunk.isEndOfUtterance { endSession() }
            rawAudioBuffer.removeAll()
        }
    }

    func stop() async {
        isStopped = true
        endSession()
        rawAudioBuffer.removeAll()
        await captureClient.stop()
    }

    func activeEphemeralSpeakerLabelCount() -> Int {
        speakerLabelsBySignature.count
    }

    private func expireSessionIfNeeded(at date: Date) {
        if let sessionExpiresAt, date >= sessionExpiresAt {
            endSession()
        }
    }

    private func endSession() {
        sessionExpiresAt = nil
        speakerLabelsBySignature.removeAll()
    }

    private func ephemeralSpeakerLabel(for signature: String?) -> String? {
        guard isDiarizationEnabled, let signature, signature.isEmpty == false else { return nil }
        if let existingLabel = speakerLabelsBySignature[signature] { return existingLabel }
        let label = "speaker-\(speakerLabelsBySignature.count + 1)"
        speakerLabelsBySignature[signature] = label
        return label
    }
}

nonisolated struct PaceAmbientVoiceCandidatePayload: Codable, Equatable, Sendable {
    let transcript: String
    let ephemeralSpeakerLabel: String?
}
