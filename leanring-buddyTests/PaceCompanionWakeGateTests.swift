import AVFoundation
import CoreML
import Foundation
import Testing

@testable import Pace

@Suite(.serialized)
@MainActor
struct PaceCompanionWakeGateTests {
    @Test func pcmIngressCoalescesToLatestChunkAndClearsSynchronously() throws {
        var ingress = PaceWakePCMIngressBuffer()
        ingress.offer(PaceWakePCMChunk(samples: [0.1, 0.2], inputSampleRate: 48_000))
        ingress.offer(PaceWakePCMChunk(samples: [0.7], inputSampleRate: 44_100))

        #expect(ingress.takeLatest() == PaceWakePCMChunk(
            samples: [0.7],
            inputSampleRate: 44_100
        ))
        #expect(ingress.pendingChunk == nil)

        ingress.offer(PaceWakePCMChunk(samples: [0.9], inputSampleRate: 48_000))
        ingress.clear()
        #expect(ingress.pendingChunk == nil)
    }

    @Test func bundledWakeModelHasExactContractAndRunsLocally() throws {
        let modelURL = try #require(Bundle.main.url(
            forResource: "PaceWakeWordClassifier",
            withExtension: "mlmodelc"
        ))
        let model = try MLModel(contentsOf: modelURL)
        let labels = Set((model.modelDescription.classLabels ?? []).compactMap { $0 as? String })
        #expect(labels == ["background", "hey_pace"])

        let samples = try MLMultiArray(shape: [1, 32_000], dataType: .float32)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_samples": MLFeatureValue(multiArray: samples),
        ])
        let prediction = try model.prediction(from: input)
        let probabilities = try #require(
            prediction.featureValue(for: "classLabel_probs")?.dictionaryValue
        )
        #expect(probabilities["background"] != nil)
        #expect(probabilities["hey_pace"] != nil)
    }

    @Test func wakeClassifierRequiresConsecutivePositiveWindowsWithinGap() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var hysteresis = PaceWakeClassificationHysteresis(
            requiredConsecutiveClassifications: 2,
            maximumConsecutiveGap: 1
        )

        #expect(hysteresis.accepts(label: "hey_pace", confidence: 0.95, at: now) == false)
        #expect(hysteresis.accepts(
            label: "background",
            confidence: 0.99,
            at: now.addingTimeInterval(0.2)
        ) == false)
        #expect(hysteresis.accepts(
            label: "hey_pace",
            confidence: 0.95,
            at: now.addingTimeInterval(0.4)
        ) == false)
        #expect(hysteresis.accepts(
            label: "hey_pace",
            confidence: 0.95,
            at: now.addingTimeInterval(1.6)
        ) == false)
        let didAccept = hysteresis.accepts(
            label: "hey_pace",
            confidence: 0.95,
            at: now.addingTimeInterval(1.9)
        )
        #expect(didAccept)
        #expect(hysteresis.consecutiveClassificationCount == 0)
    }

    @Test func preWakeAudioCannotReachConversationOrPersistence() async throws {
        let gate = TestLocalWakeGate()
        let handler = TestWakeHandlerRecorder()
        let emittedCandidates = CandidateCount()
        let source = PaceCompanionAmbientWakeSource(
            wakeGate: gate,
            wakeHandler: { detection in
                await handler.append(detection)
                return true
            }
        )

        let sourceTask = Task {
            try await source.start { _ in
                Task { await emittedCandidates.increment() }
            }
        }
        await waitUntil { gate.detectionStreamRequestCount == 1 }

        // The production adapter has no transcriber and receives no raw audio;
        // without an accepted local-classifier event, it has no output path.
        for _ in 0..<20 { await Task.yield() }
        #expect(await handler.count == 0)
        #expect(await emittedCandidates.value == 0)

        gate.accept(confidence: 0.91)
        await waitUntil { await handler.count == 1 }
        #expect(await emittedCandidates.value == 0)

        sourceTask.cancel()
        await source.stop()
        _ = try? await sourceTask.value
    }

    @Test func acceptedWakeResumesFreshGateOnlyAfterConversationReturns() async throws {
        let gate = TestLocalWakeGate()
        let conversation = TestBoundedConversation()
        let source = PaceCompanionAmbientWakeSource(
            wakeGate: gate,
            wakeHandler: { detection in
                await conversation.run(detection)
                return true
            }
        )
        let sourceTask = Task { try await source.start { _ in } }
        await waitUntil { gate.detectionStreamRequestCount == 1 }

        gate.accept(confidence: 0.88)
        await waitUntil { conversation.didStart }
        #expect(gate.detectionStreamRequestCount == 1)

        conversation.finish()
        await waitUntil { gate.detectionStreamRequestCount == 2 }

        sourceTask.cancel()
        await source.stop()
        _ = try? await sourceTask.value
    }

    @Test func stopCancelsGateAndWakeConversationImmediately() async throws {
        let gate = TestLocalWakeGate()
        let cancellation = CancellationCount()
        let conversation = TestBoundedConversation()
        let source = PaceCompanionAmbientWakeSource(
            wakeGate: gate,
            wakeHandler: { detection in
                await conversation.run(detection)
                return true
            },
            cancellationHandler: {
                cancellation.increment()
            }
        )
        let sourceTask = Task { try await source.start { _ in } }
        await waitUntil { gate.detectionStreamRequestCount == 1 }
        gate.accept(confidence: 0.93)
        await waitUntil { conversation.didStart }

        sourceTask.cancel()
        await source.stop()
        #expect(gate.stopCallCount == 1)
        #expect(cancellation.value == 1)
        conversation.finish()
        _ = try? await sourceTask.value
    }

    @Test func wakeGateFailsClosedWhenConversationDoesNotReturnToIdle() async {
        let gate = TestLocalWakeGate()
        let source = PaceCompanionAmbientWakeSource(
            wakeGate: gate,
            wakeHandler: { _ in false }
        )
        let sourceTask = Task { try await source.start { _ in } }
        await waitUntil { gate.detectionStreamRequestCount == 1 }

        gate.accept(confidence: 0.9)
        do {
            try await sourceTask.value
            Issue.record("Expected ambient wake source to fail closed")
        } catch let error as PacePerceptionSourceError {
            #expect(error == .deviceUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(gate.detectionStreamRequestCount == 1)
    }

    @Test func missingOrInvalidGateFailsClosedBeforeCapture() async {
        let gate = TestLocalWakeGate(preparationError: .invalidModelLabels)
        let source = PaceCompanionAmbientWakeSource(
            wakeGate: gate,
            wakeHandler: { _ in true }
        )

        await #expect(throws: PaceLocalWakeGateError.invalidModelLabels) {
            try await source.prepare()
        }
        #expect(gate.detectionStreamRequestCount == 0)
    }

    @Test func firstEnableRequestsMicrophoneAuthorizationBeforeLoadingModel() async {
        var authorizationRequestCount = 0
        var modelLoadCount = 0
        let gate = PaceCoreMLWakeGate(
            permissionProvider: { .notDetermined },
            authorizationRequester: {
                authorizationRequestCount += 1
                return true
            },
            modelLoader: {
                modelLoadCount += 1
                throw PaceLocalWakeGateError.modelUnavailable
            }
        )

        await #expect(throws: PaceLocalWakeGateError.modelUnavailable) {
            try await gate.prepare()
        }
        #expect(authorizationRequestCount == 1)
        #expect(modelLoadCount == 1)
    }

    @Test func deniedMicrophoneAuthorizationFailsBeforeModelLoad() async {
        var authorizationRequestCount = 0
        var modelLoadCount = 0
        let gate = PaceCoreMLWakeGate(
            permissionProvider: { .denied },
            authorizationRequester: {
                authorizationRequestCount += 1
                return true
            },
            modelLoader: {
                modelLoadCount += 1
                throw PaceLocalWakeGateError.modelUnavailable
            }
        )

        await #expect(throws: PaceLocalWakeGateError.permissionDenied) {
            try await gate.prepare()
        }
        #expect(authorizationRequestCount == 0)
        #expect(modelLoadCount == 0)
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

@MainActor
private final class TestLocalWakeGate: PaceLocalWakeGate {
    private let preparationError: PaceLocalWakeGateError?
    private var continuation: AsyncThrowingStream<PaceLocalWakeDetection, Error>.Continuation?
    private(set) var detectionStreamRequestCount = 0
    private(set) var stopCallCount = 0

    init(preparationError: PaceLocalWakeGateError? = nil) {
        self.preparationError = preparationError
    }

    func prepare() async throws {
        if let preparationError { throw preparationError }
    }

    func detections() async throws -> AsyncThrowingStream<PaceLocalWakeDetection, Error> {
        try await prepare()
        detectionStreamRequestCount += 1
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func accept(confidence: Double, at date: Date = Date()) {
        let continuation = continuation
        self.continuation = nil
        continuation?.yield(PaceLocalWakeDetection(confidence: confidence, detectedAt: date))
        continuation?.finish()
    }

    func stop() {
        stopCallCount += 1
        let continuation = continuation
        self.continuation = nil
        continuation?.finish()
    }
}

private actor TestWakeHandlerRecorder {
    private(set) var detections: [PaceLocalWakeDetection] = []
    var count: Int { detections.count }
    func append(_ detection: PaceLocalWakeDetection) { detections.append(detection) }
}

private actor CandidateCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

@MainActor
private final class TestBoundedConversation {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var didStart = false

    func run(_ detection: PaceLocalWakeDetection) async {
        didStart = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class CancellationCount {
    private(set) var value = 0
    func increment() { value += 1 }
}
