//
//  PaceCompanionWakeGate.swift
//  leanring-buddy
//
//  Companion-mode wake detection that never invokes Speech.framework. A
//  bundled Core ML wake classifier runs directly over bounded microphone buffers;
//  accepted detections hand microphone ownership to the existing bounded PTT
//  conversation path. Missing or malformed model assets fail closed.
//

@preconcurrency import AVFoundation
import CoreML
import Foundation

nonisolated struct PaceLocalWakeDetection: Equatable, Sendable {
    let confidence: Double
    let detectedAt: Date
}

nonisolated enum PaceLocalWakeGateError: Error, Equatable {
    case permissionDenied
    case modelUnavailable
    case invalidModelLabels
    case audioInputUnavailable
    case analysisFailed
    case alreadyRunning
}

nonisolated struct PaceWakePCMChunk: Equatable, Sendable {
    let samples: [Float]
    let inputSampleRate: Double
}

/// One-slot ingress used between the real-time audio callback and serial Core
/// ML inference. New audio replaces older unprocessed audio, bounding capture
/// regardless of inference latency; clear releases it synchronously.
nonisolated struct PaceWakePCMIngressBuffer: Equatable, Sendable {
    private(set) var pendingChunk: PaceWakePCMChunk?

    mutating func offer(_ chunk: PaceWakePCMChunk) {
        pendingChunk = chunk
    }

    mutating func takeLatest() -> PaceWakePCMChunk? {
        defer { pendingChunk = nil }
        return pendingChunk
    }

    mutating func clear() {
        pendingChunk = nil
    }
}

/// Rejects isolated classifier spikes. An accepted wake requires consecutive
/// positive windows close enough to represent one utterance; any background,
/// low-confidence, or stale window resets the sequence.
nonisolated struct PaceWakeClassificationHysteresis: Equatable, Sendable {
    let wakeLabel: String
    let minimumConfidence: Double
    let requiredConsecutiveClassifications: Int
    let maximumConsecutiveGap: TimeInterval

    private(set) var consecutiveClassificationCount = 0
    private var lastPositiveAt: Date?

    init(
        wakeLabel: String = "hey_pace",
        minimumConfidence: Double = 0.8,
        requiredConsecutiveClassifications: Int = 2,
        maximumConsecutiveGap: TimeInterval = 1.5
    ) {
        self.wakeLabel = wakeLabel
        self.minimumConfidence = min(max(minimumConfidence, 0), 1)
        self.requiredConsecutiveClassifications = max(2, requiredConsecutiveClassifications)
        self.maximumConsecutiveGap = max(0.1, maximumConsecutiveGap)
    }

    mutating func accepts(label: String, confidence: Double, at date: Date) -> Bool {
        guard label == wakeLabel, confidence >= minimumConfidence else {
            reset()
            return false
        }
        if let lastPositiveAt,
           date.timeIntervalSince(lastPositiveAt) > maximumConsecutiveGap {
            consecutiveClassificationCount = 0
        }
        lastPositiveAt = date
        consecutiveClassificationCount += 1
        guard consecutiveClassificationCount >= requiredConsecutiveClassifications else {
            return false
        }
        reset()
        return true
    }

    mutating func reset() {
        consecutiveClassificationCount = 0
        lastPositiveAt = nil
    }
}

@MainActor
protocol PaceLocalWakeGate: AnyObject {
    func prepare() async throws
    func detections() async throws -> AsyncThrowingStream<PaceLocalWakeDetection, Error>
    func stop()
}

/// Production pre-STT wake gate. The classifier's class labels are part of the
/// privacy boundary: Pace starts capture only when both the accepted wake label
/// and the negative/background label are present in the bundled model.
@MainActor
final class PaceCoreMLWakeGate: PaceLocalWakeGate {
    struct Configuration: Equatable, Sendable {
        let modelResourceName: String
        let wakeLabel: String
        let backgroundLabel: String
        let minimumConfidence: Double
        let requiredConsecutiveClassifications: Int
        let maximumConsecutiveGap: TimeInterval

        init(
            modelResourceName: String = "PaceWakeWordClassifier",
            wakeLabel: String = "hey_pace",
            backgroundLabel: String = "background",
            minimumConfidence: Double = 0.986,
            requiredConsecutiveClassifications: Int = 2,
            maximumConsecutiveGap: TimeInterval = 1.5
        ) {
            self.modelResourceName = modelResourceName
            self.wakeLabel = wakeLabel
            self.backgroundLabel = backgroundLabel
            self.minimumConfidence = min(max(minimumConfidence, 0), 1)
            self.requiredConsecutiveClassifications = max(2, requiredConsecutiveClassifications)
            self.maximumConsecutiveGap = max(0.1, maximumConsecutiveGap)
        }
    }

    typealias ModelLoader = @MainActor () throws -> MLModel
    typealias AuthorizationRequester = @MainActor () async -> Bool

    private let configuration: Configuration
    private let permissionProvider: @MainActor () -> AVAuthorizationStatus
    private let authorizationRequester: AuthorizationRequester
    private let modelLoader: ModelLoader

    private var model: MLModel?
    private var audioEngine: AVAudioEngine?
    private var audioProcessor: PaceCoreMLWakeAudioProcessor?
    private var continuation: AsyncThrowingStream<PaceLocalWakeDetection, Error>.Continuation?
    private var classificationHysteresis: PaceWakeClassificationHysteresis

    init(
        configuration: Configuration? = nil,
        bundle: Bundle = .main,
        permissionProvider: @escaping @MainActor () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        authorizationRequester: @escaping AuthorizationRequester = {
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
        }
    ) {
        let configuration = configuration ?? Configuration()
        self.configuration = configuration
        self.permissionProvider = permissionProvider
        self.authorizationRequester = authorizationRequester
        self.classificationHysteresis = PaceWakeClassificationHysteresis(
            wakeLabel: configuration.wakeLabel,
            minimumConfidence: configuration.minimumConfidence,
            requiredConsecutiveClassifications: configuration.requiredConsecutiveClassifications,
            maximumConsecutiveGap: configuration.maximumConsecutiveGap
        )
        self.modelLoader = {
            guard let modelURL = bundle.url(
                forResource: configuration.modelResourceName,
                withExtension: "mlmodelc"
            ) else {
                throw PaceLocalWakeGateError.modelUnavailable
            }
            return try MLModel(contentsOf: modelURL)
        }
    }

    init(
        configuration: Configuration? = nil,
        permissionProvider: @escaping @MainActor () -> AVAuthorizationStatus,
        authorizationRequester: @escaping AuthorizationRequester = { false },
        modelLoader: @escaping ModelLoader
    ) {
        let configuration = configuration ?? Configuration()
        self.configuration = configuration
        self.permissionProvider = permissionProvider
        self.authorizationRequester = authorizationRequester
        self.classificationHysteresis = PaceWakeClassificationHysteresis(
            wakeLabel: configuration.wakeLabel,
            minimumConfidence: configuration.minimumConfidence,
            requiredConsecutiveClassifications: configuration.requiredConsecutiveClassifications,
            maximumConsecutiveGap: configuration.maximumConsecutiveGap
        )
        self.modelLoader = modelLoader
    }

    func prepare() async throws {
        switch permissionProvider() {
        case .authorized:
            break
        case .notDetermined:
            guard await authorizationRequester() else {
                throw PaceLocalWakeGateError.permissionDenied
            }
        case .denied, .restricted:
            throw PaceLocalWakeGateError.permissionDenied
        @unknown default:
            throw PaceLocalWakeGateError.permissionDenied
        }
        if model != nil { return }

        let loadedModel: MLModel
        do {
            loadedModel = try modelLoader()
        } catch let error as PaceLocalWakeGateError {
            throw error
        } catch {
            throw PaceLocalWakeGateError.modelUnavailable
        }

        let labels = Set((loadedModel.modelDescription.classLabels ?? []).compactMap {
            $0 as? String
        })
        guard labels.contains(configuration.wakeLabel),
              labels.contains(configuration.backgroundLabel) else {
            throw PaceLocalWakeGateError.invalidModelLabels
        }
        guard let input = loadedModel.modelDescription.inputDescriptionsByName["audio_samples"],
              input.type == .multiArray,
              input.multiArrayConstraint?.shape.map(\.intValue) == [1, 32_000],
              loadedModel.modelDescription.outputDescriptionsByName["classLabel_probs"] != nil else {
            throw PaceLocalWakeGateError.modelUnavailable
        }
        model = loadedModel
    }

    func detections() async throws -> AsyncThrowingStream<PaceLocalWakeDetection, Error> {
        guard continuation == nil else { throw PaceLocalWakeGateError.alreadyRunning }
        try await prepare()
        guard let model else { throw PaceLocalWakeGateError.modelUnavailable }

        var streamContinuation: AsyncThrowingStream<PaceLocalWakeDetection, Error>.Continuation?
        let stream = AsyncThrowingStream<PaceLocalWakeDetection, Error> { continuation in
            streamContinuation = continuation
        }
        guard let streamContinuation else { throw PaceLocalWakeGateError.analysisFailed }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PaceLocalWakeGateError.audioInputUnavailable
        }

        do {
            let processor = PaceCoreMLWakeAudioProcessor(
                model: model,
                wakeLabel: configuration.wakeLabel,
                backgroundLabel: configuration.backgroundLabel,
                onClassification: { [weak self] label, confidence in
                    Task { @MainActor [weak self] in
                        self?.accept(label: label, confidence: confidence)
                    }
                },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.finishCurrentSession(throwing: PaceLocalWakeGateError.analysisFailed)
                    }
                }
            )
            self.audioEngine = audioEngine
            self.audioProcessor = processor
            classificationHysteresis.reset()
            continuation = streamContinuation

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
                buffer, _ in
                processor.append(buffer: buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            tearDownAudioSession()
            streamContinuation.finish(throwing: PaceLocalWakeGateError.audioInputUnavailable)
            throw PaceLocalWakeGateError.audioInputUnavailable
        }

        return stream
    }

    func stop() {
        let continuation = continuation
        tearDownAudioSession()
        continuation?.finish()
    }

    private func accept(label: String, confidence: Double) {
        guard let continuation,
              classificationHysteresis.accepts(
                label: label,
                confidence: confidence,
                at: Date()
              ) else { return }

        // Release the microphone before notifying the conversation path. The
        // PTT engine therefore never races the always-on analysis tap.
        tearDownAudioSession()
        continuation.yield(PaceLocalWakeDetection(
            confidence: confidence,
            detectedAt: Date()
        ))
        continuation.finish()
    }

    private func finishCurrentSession(throwing error: Error) {
        let continuation = continuation
        tearDownAudioSession()
        continuation?.finish(throwing: error)
    }

    private func tearDownAudioSession() {
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioProcessor?.stop()
        audioEngine = nil
        audioProcessor = nil
        continuation = nil
        classificationHysteresis.reset()
    }
}

/// Serial, bounded PCM preprocessing and Core ML inference. Audio buffers are
/// copied out of the real-time callback immediately, downmixed/resampled to
/// 16 kHz off the callback thread, and retained only in a 2-second ring.
private final class PaceCoreMLWakeAudioProcessor: @unchecked Sendable {
    private static let sampleRate = 16_000.0
    private static let windowSampleCount = 32_000
    private static let hopSampleCount = 4_000

    private let model: MLModel
    private let wakeLabel: String
    private let backgroundLabel: String
    private let onClassification: @Sendable (String, Double) -> Void
    private let onFailure: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.pace.companion-wake-coreml", qos: .userInitiated)
    private let ingressLock = NSLock()
    private var ingressBuffer = PaceWakePCMIngressBuffer()
    private var isDrainScheduled = false
    private var isStopped = false
    private var rollingSamples: [Float] = []
    private var samplesSinceInference = 0
    private var resampleCarrySample: Float?
    private var resamplePosition = 0.0
    private var resampleInputSampleRate = 0.0

    init(
        model: MLModel,
        wakeLabel: String,
        backgroundLabel: String,
        onClassification: @escaping @Sendable (String, Double) -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.model = model
        self.wakeLabel = wakeLabel
        self.backgroundLabel = backgroundLabel
        self.onClassification = onClassification
        self.onFailure = onFailure
    }

    func append(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }
        var monoSamples = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for index in 0..<frameCount {
                monoSamples[index] += samples[index] / Float(channelCount)
            }
        }
        let inputSampleRate = buffer.format.sampleRate
        let capturedSamples = monoSamples
        ingressLock.lock()
        guard isStopped == false else {
            ingressLock.unlock()
            return
        }
        // Coalesce to one latest native-rate chunk while inference is busy.
        // Only one drain block can be queued, so pre-wake PCM cannot build an
        // unbounded DispatchQueue backlog.
        ingressBuffer.offer(PaceWakePCMChunk(
            samples: capturedSamples,
            inputSampleRate: inputSampleRate
        ))
        let shouldScheduleDrain = isDrainScheduled == false
        if shouldScheduleDrain { isDrainScheduled = true }
        ingressLock.unlock()
        if shouldScheduleDrain {
            queue.async { [weak self] in
                self?.drainPendingChunks()
            }
        }
    }

    func stop() {
        ingressLock.lock()
        isStopped = true
        ingressBuffer.clear()
        ingressLock.unlock()
        queue.async { [weak self] in
            self?.rollingSamples.removeAll(keepingCapacity: false)
            self?.samplesSinceInference = 0
            self?.resampleCarrySample = nil
            self?.resamplePosition = 0
            self?.resampleInputSampleRate = 0
        }
    }

    private func drainPendingChunks() {
        while true {
            ingressLock.lock()
            if isStopped {
                ingressBuffer.clear()
                isDrainScheduled = false
                ingressLock.unlock()
                rollingSamples.removeAll(keepingCapacity: false)
                return
            }
            guard let chunk = ingressBuffer.takeLatest() else {
                isDrainScheduled = false
                ingressLock.unlock()
                return
            }
            ingressLock.unlock()
            consume(chunk.samples, inputSampleRate: chunk.inputSampleRate)
        }
    }

    private func consume(_ input: [Float], inputSampleRate: Double) {
        guard stoppedSnapshot() == false else { return }
        let samples = streamingLinearResample(input, inputSampleRate: inputSampleRate)
        rollingSamples.append(contentsOf: samples)
        if rollingSamples.count > Self.windowSampleCount {
            rollingSamples.removeFirst(rollingSamples.count - Self.windowSampleCount)
        }
        samplesSinceInference += samples.count
        guard rollingSamples.count == Self.windowSampleCount,
              samplesSinceInference >= Self.hopSampleCount else { return }
        samplesSinceInference %= Self.hopSampleCount
        guard stoppedSnapshot() == false else { return }

        do {
            let inputArray = try MLMultiArray(
                shape: [1, NSNumber(value: Self.windowSampleCount)],
                dataType: .float32
            )
            for (index, sample) in rollingSamples.enumerated() {
                inputArray[index] = NSNumber(value: sample)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "audio_samples": MLFeatureValue(multiArray: inputArray),
            ])
            let prediction = try model.prediction(from: provider)
            guard let probabilities = prediction
                .featureValue(for: "classLabel_probs")?
                .dictionaryValue else {
                throw PaceLocalWakeGateError.analysisFailed
            }
            let wakeConfidence = probabilities[wakeLabel]?.doubleValue ?? 0
            let backgroundConfidence = probabilities[backgroundLabel]?.doubleValue ?? 0
            guard stoppedSnapshot() == false else { return }
            if wakeConfidence >= backgroundConfidence {
                onClassification(wakeLabel, wakeConfidence)
            } else {
                onClassification(backgroundLabel, backgroundConfidence)
            }
        } catch {
            ingressLock.lock()
            isStopped = true
            ingressBuffer.clear()
            ingressLock.unlock()
            rollingSamples.removeAll(keepingCapacity: false)
            onFailure()
        }
    }

    private func stoppedSnapshot() -> Bool {
        ingressLock.lock()
        defer { ingressLock.unlock() }
        return isStopped
    }

    private func streamingLinearResample(
        _ input: [Float],
        inputSampleRate: Double
    ) -> [Float] {
        guard input.isEmpty == false, inputSampleRate > 0 else { return [] }
        if abs(inputSampleRate - Self.sampleRate) < 0.5 {
            resampleCarrySample = input.last
            resamplePosition = 0
            resampleInputSampleRate = inputSampleRate
            return input
        }
        if abs(resampleInputSampleRate - inputSampleRate) >= 0.5 {
            resampleCarrySample = nil
            resamplePosition = 0
            resampleInputSampleRate = inputSampleRate
        }
        let source = resampleCarrySample.map { [$0] + input } ?? input
        guard source.count > 1 else {
            resampleCarrySample = source.last
            return []
        }
        let step = inputSampleRate / Self.sampleRate
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / step) + 1)
        var position = resamplePosition
        while position < Double(source.count - 1) {
            let lowerIndex = Int(position)
            let upperIndex = min(lowerIndex + 1, source.count - 1)
            let fraction = Float(position - Double(lowerIndex))
            output.append(
                source[lowerIndex] + (source[upperIndex] - source[lowerIndex]) * fraction
            )
            position += step
        }
        resamplePosition = position - Double(source.count - 1)
        resampleCarrySample = source.last
        return output
    }
}

/// Perception adapter for the production gate. It emits no transcript and no
/// observation candidate: the only output is an accepted wake event handed to
/// the explicit post-wake conversation callback. After that bounded session
/// returns, local wake analysis resumes with a fresh audio engine.
@MainActor
final class PaceCompanionAmbientWakeSource: PacePerceptionSourceAdapter {
    nonisolated let sourceKind: PacePerceptionSourceKind = .ambientVoice

    /// Returns true only when the post-wake conversation has fully returned to
    /// idle and it is safe for the classifier to reacquire the microphone.
    typealias WakeHandler = @MainActor @Sendable (PaceLocalWakeDetection) async -> Bool
    typealias CancellationHandler = @MainActor @Sendable () -> Void

    private let wakeGate: any PaceLocalWakeGate
    private let wakeHandler: WakeHandler
    private let cancellationHandler: CancellationHandler
    private var isStopped = true

    init(
        wakeGate: any PaceLocalWakeGate,
        wakeHandler: @escaping WakeHandler,
        cancellationHandler: @escaping CancellationHandler = {}
    ) {
        self.wakeGate = wakeGate
        self.wakeHandler = wakeHandler
        self.cancellationHandler = cancellationHandler
    }

    func prepare() async throws {
        try await wakeGate.prepare()
    }

    func start(emit: @escaping @Sendable (PaceObservationCandidate) -> Void) async throws {
        isStopped = false
        while isStopped == false, Task.isCancelled == false {
            let detections: AsyncThrowingStream<PaceLocalWakeDetection, Error>
            do {
                detections = try await wakeGate.detections()
            } catch {
                throw Self.normalizedSourceError(error)
            }

            var acceptedWake = false
            do {
                for try await detection in detections {
                    guard isStopped == false, Task.isCancelled == false else { break }
                    acceptedWake = true
                    let mayResumeWakeGate = await wakeHandler(detection)
                    guard mayResumeWakeGate else {
                        throw PacePerceptionSourceError.deviceUnavailable
                    }
                    break
                }
            } catch {
                throw Self.normalizedSourceError(error)
            }

            guard isStopped == false, Task.isCancelled == false else { return }
            guard acceptedWake else { throw PacePerceptionSourceError.deviceUnavailable }
        }
    }

    func stop() async {
        isStopped = true
        wakeGate.stop()
        cancellationHandler()
    }

    private nonisolated static func normalizedSourceError(_ error: Error) -> PacePerceptionSourceError {
        switch error as? PaceLocalWakeGateError {
        case .permissionDenied:
            return .permissionDenied
        case .modelUnavailable, .invalidModelLabels, .audioInputUnavailable,
             .analysisFailed, .alreadyRunning, nil:
            return .deviceUnavailable
        }
    }
}
