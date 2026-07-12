//
//  PaceCompanionCameraCaptureClient.swift
//  leanring-buddy
//
//  Production AVFoundation camera capture for observe-only companion mode.
//  The capture queue performs a cheap luma-delta motion gate and Vision human
//  detection. Only a tiny sampled-luma buffer and structured, non-identifying
//  detections cross the capture boundary; full frames are never persisted.
//

@preconcurrency import AVFoundation
import Foundation
import Vision

nonisolated enum PaceCameraMotionEstimator {
    static func normalizedDifference(previous: [UInt8]?, current: [UInt8]) -> Double {
        guard let previous, previous.count == current.count, current.isEmpty == false else {
            return current.isEmpty ? 0 : 1
        }
        let totalDifference = zip(previous, current).reduce(into: 0) { total, pair in
            total += abs(Int(pair.0) - Int(pair.1))
        }
        return Double(totalDifference) / (Double(current.count) * 255)
    }
}

nonisolated struct PaceEphemeralPersonTracker: Sendable {
    private struct Track: Sendable {
        let identifier: String
        let centerX: Double
        let centerY: Double
    }

    private var priorTracks: [Track] = []
    private var nextIdentifier = 1
    private let maximumCenterDistance: Double

    init(maximumCenterDistance: Double = 0.22) {
        self.maximumCenterDistance = max(0.01, maximumCenterDistance)
    }

    mutating func identifiers(for centers: [(x: Double, y: Double)]) -> [String] {
        var unmatchedPriorTracks = priorTracks
        var updatedTracks: [Track] = []
        let identifiers = centers.map { center -> String in
            let closestIndex = unmatchedPriorTracks.indices.min { lhs, rhs in
                distance(from: unmatchedPriorTracks[lhs], to: center)
                    < distance(from: unmatchedPriorTracks[rhs], to: center)
            }
            let identifier: String
            if let closestIndex,
               distance(from: unmatchedPriorTracks[closestIndex], to: center) <= maximumCenterDistance {
                identifier = unmatchedPriorTracks.remove(at: closestIndex).identifier
            } else {
                identifier = "person-\(nextIdentifier)"
                nextIdentifier += 1
            }
            updatedTracks.append(Track(identifier: identifier, centerX: center.x, centerY: center.y))
            return identifier
        }
        priorTracks = updatedTracks
        return identifiers
    }

    mutating func reset() {
        priorTracks.removeAll()
        nextIdentifier = 1
    }

    private func distance(from track: Track, to center: (x: Double, y: Double)) -> Double {
        hypot(track.centerX - center.x, track.centerY - center.y)
    }
}

private nonisolated final class PaceCameraCaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<PaceCameraFrame>.Continuation?
    private var previousSampledLuma: [UInt8]?
    private var personTracker = PaceEphemeralPersonTracker()
    private var lastAcceptedFrameAt = Date.distantPast
    private var minimumFrameInterval: TimeInterval = 1
    private var isActive = false

    func begin(
        continuation: AsyncStream<PaceCameraFrame>.Continuation,
        maximumFramesPerSecond: Double
    ) {
        lock.lock()
        self.continuation = continuation
        minimumFrameInterval = 1 / min(max(maximumFramesPerSecond, 0.1), 2)
        previousSampledLuma = nil
        personTracker.reset()
        lastAcceptedFrameAt = .distantPast
        isActive = true
        lock.unlock()
    }

    func end() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        previousSampledLuma = nil
        personTracker.reset()
        isActive = false
        lock.unlock()
        continuation?.finish()
    }

    func process(
        sampledLuma: [UInt8],
        people: [(boundingBox: CGRect, confidence: Double)],
        capturedAt: Date
    ) -> PaceCameraFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive,
              capturedAt.timeIntervalSince(lastAcceptedFrameAt) >= minimumFrameInterval else {
            return nil
        }
        lastAcceptedFrameAt = capturedAt
        let motionScore = PaceCameraMotionEstimator.normalizedDifference(
            previous: previousSampledLuma,
            current: sampledLuma
        )
        previousSampledLuma = sampledLuma
        let centers = people.map { person in
            (x: Double(person.boundingBox.midX), y: Double(person.boundingBox.midY))
        }
        let trackIdentifiers = personTracker.identifiers(for: centers)
        let detections = zip(people, trackIdentifiers).map { person, identifier in
            PaceCameraDetection(
                kind: .person,
                ephemeralTrackIdentifier: identifier,
                normalizedCenterX: Double(person.boundingBox.midX),
                normalizedCenterY: Double(person.boundingBox.midY),
                confidence: person.confidence
            )
        }
        return PaceCameraFrame(
            capturedAt: capturedAt,
            motionScore: motionScore,
            detections: detections,
            rawFrame: Data(sampledLuma)
        )
    }

    func yield(_ frame: PaceCameraFrame) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(frame)
    }
}

private nonisolated final class PaceCameraCaptureOutputDelegate:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let state: PaceCameraCaptureState

    init(state: PaceCameraCaptureState) {
        self.state = state
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let sampledLuma = sampledLuma(from: pixelBuffer) else { return }

        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
        let people = (request.results ?? []).map {
            (boundingBox: $0.boundingBox, confidence: Double($0.confidence))
        }
        guard let frame = state.process(
            sampledLuma: sampledLuma,
            people: people,
            capturedAt: Date()
        ) else { return }
        state.yield(frame)
    }

    private func sampledLuma(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

        let targetWidth = 32
        let targetHeight = 24
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var result: [UInt8] = []
        result.reserveCapacity(targetWidth * targetHeight)
        for targetY in 0..<targetHeight {
            let sourceY = min(height - 1, targetY * height / targetHeight)
            for targetX in 0..<targetWidth {
                let sourceX = min(width - 1, targetX * width / targetWidth)
                let offset = sourceY * bytesPerRow + sourceX * 4
                let blue = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let red = Int(bytes[offset + 2])
                result.append(UInt8((red * 77 + green * 150 + blue * 29) >> 8))
            }
        }
        return result
    }
}

nonisolated final class PaceAVFoundationCameraCaptureClient:
    NSObject,
    PaceCameraCaptureClient,
    @unchecked Sendable
{
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.pace.companion-camera")
    private let state = PaceCameraCaptureState()
    private lazy var outputDelegate = PaceCameraCaptureOutputDelegate(state: state)
    private var runtimeErrorObserver: NSObjectProtocol?

    func permissionState() async -> PacePerceptionPermissionState {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
            return granted ? .authorized : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .unavailable
        }
    }

    func frames(maximumFramesPerSecond: Double) async throws -> AsyncStream<PaceCameraFrame> {
        guard let cameraDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) ?? AVCaptureDevice.default(for: .video) else {
            throw PacePerceptionSourceError.deviceUnavailable
        }

        let stream = AsyncStream<PaceCameraFrame> { continuation in
            state.begin(
                continuation: continuation,
                maximumFramesPerSecond: maximumFramesPerSecond
            )
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async { [self] in
                do {
                    try configureSessionIfNeeded(cameraDevice: cameraDevice)
                    installRuntimeErrorObserverIfNeeded()
                    captureSession.startRunning()
                    continuation.resume()
                } catch {
                    state.end()
                    continuation.resume(throwing: error)
                }
            }
        }
        return stream
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [self] in
                if captureSession.isRunning { captureSession.stopRunning() }
                removeRuntimeErrorObserver()
                state.end()
                continuation.resume()
            }
        }
    }

    private func configureSessionIfNeeded(cameraDevice: AVCaptureDevice) throws {
        guard captureSession.inputs.isEmpty else { return }
        let input = try AVCaptureDeviceInput(device: cameraDevice)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(outputDelegate, queue: captureQueue)

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .vga640x480
        guard captureSession.canAddInput(input), captureSession.canAddOutput(output) else {
            throw PacePerceptionSourceError.deviceUnavailable
        }
        captureSession.addInput(input)
        captureSession.addOutput(output)
    }

    private func installRuntimeErrorObserverIfNeeded() {
        guard runtimeErrorObserver == nil else { return }
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession,
            queue: nil
        ) { [state] _ in
            state.end()
        }
    }

    private func removeRuntimeErrorObserver() {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
            self.runtimeErrorObserver = nil
        }
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
        state.end()
    }
}
