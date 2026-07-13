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

private nonisolated enum PaceVisionTaughtObjectMatcher {
    struct RegionFeaturePrint {
        let observation: VNFeaturePrintObservation
        let normalizedCenterX: Double
        let normalizedCenterY: Double
    }

    private static let teachingRegion = CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.7)
    private static let searchRegions = [
        CGRect(x: 0, y: 0.15, width: 0.45, height: 0.7),
        CGRect(x: 0.275, y: 0.15, width: 0.45, height: 0.7),
        CGRect(x: 0.55, y: 0.15, width: 0.45, height: 0.7),
    ]

    static func archiveTeachingFeaturePrint(from pixelBuffer: CVPixelBuffer) throws -> Data {
        guard let featurePrint = try featurePrints(
            from: pixelBuffer,
            regions: [teachingRegion]
        ).first?.observation else {
            throw PaceTaughtObjectError.featurePrintUnavailable
        }
        return try NSKeyedArchiver.archivedData(
            withRootObject: featurePrint,
            requiringSecureCoding: true
        )
    }

    static func detections(
        in pixelBuffer: CVPixelBuffer,
        templates: [PaceTaughtObjectTemplate]
    ) -> [PaceCameraDetection] {
        guard templates.isEmpty == false,
              let regionFeaturePrints = try? featurePrints(
                from: pixelBuffer,
                regions: searchRegions
              ) else { return [] }

        return templates.compactMap { template in
            guard let taughtFeaturePrint = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: VNFeaturePrintObservation.self,
                from: template.featurePrintArchive
            ) else { return nil }

            let matches = regionFeaturePrints.compactMap { region -> PaceTaughtObjectRegionMatch? in
                var distance: Float = .greatestFiniteMagnitude
                do {
                    try region.observation.computeDistance(
                        &distance,
                        to: taughtFeaturePrint
                    )
                } catch {
                    return nil
                }
                return PaceTaughtObjectRegionMatch(
                    normalizedCenterX: region.normalizedCenterX,
                    normalizedCenterY: region.normalizedCenterY,
                    distance: distance
                )
            }
            guard let match = PaceTaughtObjectMatchPolicy.bestAcceptedMatch(matches) else {
                return nil
            }
            return PaceCameraDetection(
                kind: .object(label: template.label, isUserTaught: true),
                ephemeralTrackIdentifier: template.trackIdentifier,
                normalizedCenterX: match.normalizedCenterX,
                normalizedCenterY: match.normalizedCenterY,
                confidence: PaceTaughtObjectMatchPolicy.confidence(forDistance: match.distance)
            )
        }
    }

    private static func featurePrints(
        from pixelBuffer: CVPixelBuffer,
        regions: [CGRect]
    ) throws -> [RegionFeaturePrint] {
        let requests = regions.map { region -> VNGenerateImageFeaturePrintRequest in
            let request = VNGenerateImageFeaturePrintRequest()
            request.regionOfInterest = region
            return request
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform(requests)
        return zip(regions, requests).compactMap { region, request in
            guard let observation = request.results?.first else { return nil }
            return RegionFeaturePrint(
                observation: observation,
                normalizedCenterX: Double(region.midX),
                normalizedCenterY: Double(region.midY)
            )
        }
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
    private var pendingTeaching: (
        label: String,
        continuation: CheckedContinuation<Void, Error>
    )?

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
        let teachingContinuation = pendingTeaching?.continuation
        self.continuation = nil
        pendingTeaching = nil
        previousSampledLuma = nil
        personTracker.reset()
        isActive = false
        lock.unlock()
        continuation?.finish()
        teachingContinuation?.resume(throwing: PaceTaughtObjectError.cameraNotActive)
    }

    func teachObject(label: String) async throws {
        let normalizedLabel = PaceTaughtObjectTemplate.normalizedLabel(label)
        guard normalizedLabel.isEmpty == false else { throw PaceTaughtObjectError.emptyLabel }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard isActive, pendingTeaching == nil else {
                lock.unlock()
                continuation.resume(throwing: isActive
                    ? PaceTaughtObjectError.featurePrintUnavailable
                    : PaceTaughtObjectError.cameraNotActive)
                return
            }
            pendingTeaching = (normalizedLabel, continuation)
            lock.unlock()
        }
    }

    func pendingTeachingLabel() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pendingTeaching?.label
    }

    func completeTeaching(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = pendingTeaching?.continuation
        pendingTeaching = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func shouldAnalyzeFrame(capturedAt: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isActive,
              capturedAt.timeIntervalSince(lastAcceptedFrameAt) >= minimumFrameInterval else {
            return false
        }
        lastAcceptedFrameAt = capturedAt
        return true
    }

    func process(
        sampledLuma: [UInt8],
        people: [(boundingBox: CGRect, confidence: Double)],
        objectDetections: [PaceCameraDetection],
        capturedAt: Date
    ) -> PaceCameraFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return nil }
        let motionScore = PaceCameraMotionEstimator.normalizedDifference(
            previous: previousSampledLuma,
            current: sampledLuma
        )
        previousSampledLuma = sampledLuma
        let centers = people.map { person in
            (x: Double(person.boundingBox.midX), y: Double(person.boundingBox.midY))
        }
        let trackIdentifiers = personTracker.identifiers(for: centers)
        let personDetections = zip(people, trackIdentifiers).map { person, identifier in
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
            detections: personDetections + objectDetections,
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
    private let taughtObjectStore: PaceTaughtObjectStore

    init(state: PaceCameraCaptureState, taughtObjectStore: PaceTaughtObjectStore) {
        self.state = state
        self.taughtObjectStore = taughtObjectStore
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let sampledLuma = sampledLuma(from: pixelBuffer) else { return }
        let capturedAt = Date()
        guard state.shouldAnalyzeFrame(capturedAt: capturedAt) else { return }

        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
        let people = (request.results ?? []).map {
            (boundingBox: $0.boundingBox, confidence: Double($0.confidence))
        }
        if let pendingTeachingLabel = state.pendingTeachingLabel() {
            do {
                let archive = try PaceVisionTaughtObjectMatcher.archiveTeachingFeaturePrint(
                    from: pixelBuffer
                )
                try taughtObjectStore.upsert(PaceTaughtObjectTemplate(
                    label: pendingTeachingLabel,
                    featurePrintArchive: archive
                ))
                state.completeTeaching(.success(()))
            } catch {
                state.completeTeaching(.failure(error))
            }
        }
        let objectDetections = PaceVisionTaughtObjectMatcher.detections(
            in: pixelBuffer,
            templates: taughtObjectStore.templates()
        )
        guard let frame = state.process(
            sampledLuma: sampledLuma,
            people: people,
            objectDetections: objectDetections,
            capturedAt: capturedAt
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
    private let state: PaceCameraCaptureState
    private let outputDelegate: PaceCameraCaptureOutputDelegate
    private let taughtObjectStore: PaceTaughtObjectStore
    private var runtimeErrorObserver: NSObjectProtocol?

    init(taughtObjectStore: PaceTaughtObjectStore = PaceTaughtObjectStore()) {
        let state = PaceCameraCaptureState()
        self.state = state
        self.taughtObjectStore = taughtObjectStore
        self.outputDelegate = PaceCameraCaptureOutputDelegate(
            state: state,
            taughtObjectStore: taughtObjectStore
        )
        super.init()
    }

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

    func teachObject(label: String) async throws {
        try await state.teachObject(label: label)
    }

    func removeTaughtObject(label: String) async throws {
        try taughtObjectStore.remove(label: label)
    }

    func taughtObjectLabels() async -> [String] {
        taughtObjectStore.templates().map(\.label)
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
