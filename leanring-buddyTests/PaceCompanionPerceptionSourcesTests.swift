import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceCompanionPerceptionSourcesTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func productionCameraMotionEstimatorIsBoundedAndDetectsChange() {
        #expect(PaceCameraMotionEstimator.normalizedDifference(previous: nil, current: []) == 0)
        #expect(PaceCameraMotionEstimator.normalizedDifference(
            previous: nil,
            current: [0, 0]
        ) == 1)
        #expect(PaceCameraMotionEstimator.normalizedDifference(
            previous: [0, 255],
            current: [0, 255]
        ) == 0)
        #expect(PaceCameraMotionEstimator.normalizedDifference(
            previous: [0, 0],
            current: [255, 255]
        ) == 1)
    }

    @Test func productionCameraPersonTrackerKeepsOnlyEphemeralSessionLocalContinuity() {
        var tracker = PaceEphemeralPersonTracker(maximumCenterDistance: 0.2)
        let first = tracker.identifiers(for: [(x: 0.2, y: 0.4), (x: 0.8, y: 0.4)])
        let second = tracker.identifiers(for: [(x: 0.23, y: 0.42), (x: 0.79, y: 0.42)])
        #expect(first == ["person-1", "person-2"])
        #expect(second == first)

        let farAway = tracker.identifiers(for: [(x: 0.5, y: 0.9)])
        #expect(farAway == ["person-3"])
        tracker.reset()
        #expect(tracker.identifiers(for: [(x: 0.5, y: 0.9)]) == ["person-1"])
    }

    @Test func cameraRequiresIndependentPermissionAndStopsCaptureImmediately() async throws {
        let deniedCapture = TestCameraCaptureClient(permission: .denied)
        let deniedSource = PaceCameraPerceptionSource(
            captureClient: deniedCapture,
            zones: [],
            isEnabled: true
        )
        await #expect(throws: PacePerceptionSourceError.self) {
            try await deniedSource.start { _ in }
        }

        let capture = TestCameraCaptureClient(permission: .authorized)
        let source = PaceCameraPerceptionSource(captureClient: capture, zones: [], isEnabled: true)
        let sourceTask = Task { try await source.start { _ in } }
        await waitUntil { await capture.didRequestFrames() }
        await source.stop()
        _ = try await sourceTask.value
        #expect(await capture.stopCallCount() == 1)

        let unavailableCapture = TestCameraCaptureClient(permission: .unavailable)
        let unavailableSource = PaceCameraPerceptionSource(
            captureClient: unavailableCapture,
            zones: [],
            isEnabled: true
        )
        await #expect(throws: PacePerceptionSourceError.self) {
            try await unavailableSource.start { _ in }
        }
    }

    @Test func cameraDeviceRemovalEndsSourceWithoutEmittingAfterRemoval() async throws {
        let capture = TestCameraCaptureClient(permission: .authorized)
        let collector = CandidateCollector()
        let source = PaceCameraPerceptionSource(captureClient: capture, zones: [], isEnabled: true)
        let sourceTask = Task { try await source.start { candidate in
            Task { await collector.append(candidate) }
        } }
        await waitUntil { await capture.didRequestFrames() }
        await capture.finishForDeviceRemoval()
        _ = try await sourceTask.value
        #expect(await collector.snapshot().isEmpty)
    }

    @Test func cameraMotionAndObjectGateSkipsUnchangedFramesAndDropsRawPixels() async throws {
        let capture = TestCameraCaptureClient(permission: .authorized)
        let collector = CandidateCollector()
        let source = PaceCameraPerceptionSource(
            captureClient: capture,
            zones: [.init(name: "desk", minimumX: 0, maximumX: 0.5, minimumY: 0, maximumY: 1)],
            isEnabled: true,
            meaningfulMotionThreshold: 0.1
        )
        let sourceTask = Task { try await source.start { candidate in
            Task { await collector.append(candidate) }
        } }
        await waitUntil { await capture.didRequestFrames() }
        let detection = PaceCameraDetection(
            kind: .object(label: "keys", isUserTaught: true),
            ephemeralTrackIdentifier: "object-1",
            normalizedCenterX: 0.2,
            normalizedCenterY: 0.5,
            confidence: 0.9
        )
        await capture.yield(.init(
            capturedAt: now,
            motionScore: 0.2,
            detections: [detection],
            rawFrame: Data(repeating: 0xAB, count: 8_000)
        ))
        await capture.yield(.init(
            capturedAt: now.addingTimeInterval(1),
            motionScore: 0.01,
            detections: [detection],
            rawFrame: Data(repeating: 0xCD, count: 8_000)
        ))
        await waitUntil { await collector.snapshot().count == 1 }
        let candidate = try #require(await collector.snapshot().first)
        #expect(candidate.structuredPayload.contains("desk"))
        #expect(candidate.structuredPayload.utf8.count < 1_000)
        #expect(candidate.structuredPayload.contains("ABAB") == false)
        await source.stop()
        _ = try await sourceTask.value
    }

    @Test func cameraInterpreterUsesNonIdentifyingTracksAndUserTaughtObjectsOnly() throws {
        let personCandidate = try cameraCandidate(detection: .init(
            kind: .person,
            ephemeralTrackIdentifier: "person-7",
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.5,
            confidence: 0.8
        ))
        let personObservation = try PaceCameraObservationInterpreter.observation(from: personCandidate)
        let person = try #require(personObservation)
        #expect(person.subject.kind == .personPresence)
        #expect(person.subject.identifier.hasPrefix("ephemeral-track-"))
        #expect(person.expiresAt == now.addingTimeInterval(60))
        #expect(PaceWorldModelStore().currentState(
            for: person.subject,
            predicate: .entered,
            observations: [person],
            now: now.addingTimeInterval(61)
        ) == .unknown(reason: "no unexpired evidence"))

        let untaughtObject = try cameraCandidate(detection: .init(
            kind: .object(label: "mystery item", isUserTaught: false),
            ephemeralTrackIdentifier: "object-2",
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.5,
            confidence: 0.8
        ))
        #expect(try PaceCameraObservationInterpreter.observation(from: untaughtObject) == nil)

        let taughtObject = try cameraCandidate(detection: .init(
            kind: .object(label: "keys", isUserTaught: true),
            ephemeralTrackIdentifier: "object-3",
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.5,
            confidence: 0.65
        ))
        let objectObservation = try PaceCameraObservationInterpreter.observation(from: taughtObject)
        let object = try #require(objectObservation)
        #expect(object.subject.identifier == "keys")
        #expect(object.location?.zone == "desk")
        #expect(object.confidence == 0.65)
    }

    @Test func ambientSpeechNeverReachesSTTBeforeWakeAndSessionIsBounded() async throws {
        let capture = TestAmbientAudioCaptureClient(permission: .authorized)
        let transcriber = TestAmbientTranscriber(transcripts: ["where are my keys?"])
        let collector = CandidateCollector()
        let source = PaceAmbientVoiceSource(
            captureClient: capture,
            transcriber: transcriber,
            isEnabled: true,
            sessionDuration: 5,
            isDiarizationEnabled: true
        )
        let sourceTask = Task { try await source.start { candidate in
            Task { await collector.append(candidate) }
        } }
        await waitUntil { await capture.didRequestChunks() }

        await capture.yield(audioChunk(at: now, vad: 0.9, wake: 0.2))
        await Task.yield()
        #expect(await transcriber.callCount() == 0)
        await capture.yield(audioChunk(at: now.addingTimeInterval(1), vad: 0.9, wake: 0.95))
        await Task.yield()
        #expect(await transcriber.callCount() == 0)
        await capture.yield(audioChunk(
            at: now.addingTimeInterval(2),
            vad: 0.9,
            wake: 0,
            isEnd: true,
            signature: "voice-vector-a"
        ))
        await waitUntil { await collector.snapshot().count == 1 }

        let payloadText = try #require(await collector.snapshot().first?.structuredPayload)
        let payload = try JSONDecoder().decode(
            PaceAmbientVoiceCandidatePayload.self,
            from: try #require(payloadText.data(using: .utf8))
        )
        #expect(payload.transcript == "where are my keys?")
        #expect(payload.ephemeralSpeakerLabel == "speaker-1")
        #expect(await source.activeEphemeralSpeakerLabelCount() == 0)
        #expect(await transcriber.callCount() == 1)

        // The ended session requires a new wake; this speech is pre-wake again.
        await capture.yield(audioChunk(at: now.addingTimeInterval(3), vad: 0.9, wake: 0.1))
        await Task.yield()
        #expect(await transcriber.callCount() == 1)
        await source.stop()
        _ = try await sourceTask.value
    }

    @Test func ambientVoicePermissionDenialNeverStartsCaptureOrTranscription() async {
        let capture = TestAmbientAudioCaptureClient(permission: .denied)
        let transcriber = TestAmbientTranscriber(transcripts: [])
        let source = PaceAmbientVoiceSource(
            captureClient: capture,
            transcriber: transcriber,
            isEnabled: true
        )
        await #expect(throws: PacePerceptionSourceError.self) {
            try await source.start { _ in }
        }
        #expect(await capture.didRequestChunks() == false)
        #expect(await transcriber.callCount() == 0)
    }

    private func cameraCandidate(detection: PaceCameraDetection) throws -> PaceObservationCandidate {
        let payload = PaceCameraCandidatePayload(detection: detection, zoneName: "desk")
        return PaceObservationCandidate(
            source: .camera,
            capturedAt: now,
            equivalenceKey: "camera-track",
            structuredPayload: String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        )
    }

    private func audioChunk(
        at date: Date,
        vad: Double,
        wake: Double,
        isEnd: Bool = false,
        signature: String? = nil
    ) -> PaceAmbientAudioChunk {
        PaceAmbientAudioChunk(
            capturedAt: date,
            voiceActivityConfidence: vad,
            wakePhraseConfidence: wake,
            isEndOfUtterance: isEnd,
            speakerSignature: signature,
            rawAudio: Data(repeating: 0xEF, count: 4_096)
        )
    }

    private func waitUntil(
        maximumYields: Int = 1_000,
        condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<maximumYields {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for asynchronous condition")
    }
}

private actor CandidateCollector {
    private var candidates: [PaceObservationCandidate] = []
    func append(_ candidate: PaceObservationCandidate) { candidates.append(candidate) }
    func snapshot() -> [PaceObservationCandidate] { candidates }
}

private actor TestCameraCaptureClient: PaceCameraCaptureClient {
    private let permission: PacePerceptionPermissionState
    private var continuation: AsyncStream<PaceCameraFrame>.Continuation?
    private var requestedFrames = false
    private var stopCalls = 0

    init(permission: PacePerceptionPermissionState) { self.permission = permission }
    func permissionState() -> PacePerceptionPermissionState { permission }
    func frames(maximumFramesPerSecond: Double) -> AsyncStream<PaceCameraFrame> {
        requestedFrames = true
        return AsyncStream { continuation = $0 }
    }
    func stop() { stopCalls += 1; continuation?.finish() }
    func yield(_ frame: PaceCameraFrame) { continuation?.yield(frame) }
    func finishForDeviceRemoval() { continuation?.finish() }
    func didRequestFrames() -> Bool { requestedFrames }
    func stopCallCount() -> Int { stopCalls }
}

private actor TestAmbientAudioCaptureClient: PaceAmbientAudioCaptureClient {
    private let permission: PacePerceptionPermissionState
    private var continuation: AsyncStream<PaceAmbientAudioChunk>.Continuation?
    private var requestedChunks = false

    init(permission: PacePerceptionPermissionState) { self.permission = permission }
    func permissionState() -> PacePerceptionPermissionState { permission }
    func audioChunks() -> AsyncStream<PaceAmbientAudioChunk> {
        requestedChunks = true
        return AsyncStream { continuation = $0 }
    }
    func stop() { continuation?.finish() }
    func yield(_ chunk: PaceAmbientAudioChunk) { continuation?.yield(chunk) }
    func didRequestChunks() -> Bool { requestedChunks }
}

private actor TestAmbientTranscriber: PaceAmbientOnDeviceTranscriber {
    private var transcripts: [String]
    private var calls = 0
    init(transcripts: [String]) { self.transcripts = transcripts }
    func transcribeOnDevice(_ chunk: PaceAmbientAudioChunk) -> String? {
        calls += 1
        return transcripts.isEmpty ? nil : transcripts.removeFirst()
    }
    func callCount() -> Int { calls }
}
