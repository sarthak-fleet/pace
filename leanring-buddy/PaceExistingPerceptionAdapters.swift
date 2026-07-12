//
//  PaceExistingPerceptionAdapters.swift
//  leanring-buddy
//
//  Adapts Pace's existing ambient-context and explicit Watch Mode event
//  streams into companion candidates. It never starts a second polling loop.
//

import Combine
import Foundation

@MainActor
final class PaceAmbientContextPerceptionAdapter: PacePerceptionSourceAdapter {
    nonisolated let sourceKind: PacePerceptionSourceKind = .macOSContext
    private let ambientContextStore: PaceAmbientContextStore
    private var isStopped = false

    init(ambientContextStore: PaceAmbientContextStore = .shared) {
        self.ambientContextStore = ambientContextStore
    }

    func start(emit: @escaping @Sendable (PaceObservationCandidate) -> Void) async throws {
        isStopped = false
        var previousSnapshot: PaceAmbientContextSnapshot?
        for await snapshot in ambientContextStore.$currentSnapshot.values {
            guard Task.isCancelled == false, isStopped == false else { break }
            guard let snapshot, snapshot != previousSnapshot else { continue }
            previousSnapshot = snapshot
            emit(Self.candidate(from: snapshot))
        }
    }

    func stop() {
        isStopped = true
    }

    static func candidate(
        from snapshot: PaceAmbientContextSnapshot
    ) -> PaceObservationCandidate {
        PaceObservationCandidate(
            source: .macOSContext,
            capturedAt: snapshot.timestamp,
            equivalenceKey: "macos-context",
            structuredPayload: snapshot.promptFragment
        )
    }
}

actor PaceCompanionEphemeralScreenFrameStore {
    private let maximumFrameCount: Int
    private let maximumTotalByteCount: Int
    private var framesByIdentifier: [String: Data] = [:]
    private var insertionOrder: [String] = []

    init(maximumFrameCount: Int = 2, maximumTotalByteCount: Int = 20 * 1_024 * 1_024) {
        self.maximumFrameCount = max(1, maximumFrameCount)
        self.maximumTotalByteCount = max(1, maximumTotalByteCount)
    }

    func insert(_ frame: Data, identifier: String) {
        guard frame.count <= maximumTotalByteCount else { return }
        framesByIdentifier[identifier] = frame
        insertionOrder.removeAll { $0 == identifier }
        insertionOrder.append(identifier)
        pruneToBounds()
    }

    func take(identifier: String) -> Data? {
        insertionOrder.removeAll { $0 == identifier }
        return framesByIdentifier.removeValue(forKey: identifier)
    }

    func removeAll() {
        framesByIdentifier.removeAll()
        insertionOrder.removeAll()
    }

    func storedFrameCount() -> Int { framesByIdentifier.count }
    func storedByteCount() -> Int { framesByIdentifier.values.reduce(0) { $0 + $1.count } }

    private func pruneToBounds() {
        while insertionOrder.count > maximumFrameCount || storedByteCount() > maximumTotalByteCount {
            guard insertionOrder.isEmpty == false else { break }
            framesByIdentifier.removeValue(forKey: insertionOrder.removeFirst())
        }
    }
}

@MainActor
final class PaceScreenWatchPerceptionAdapter: PacePerceptionSourceAdapter {
    nonisolated let sourceKind: PacePerceptionSourceKind = .screen
    private let watchModeController: PaceScreenWatchModeController
    private let frameStore: PaceCompanionEphemeralScreenFrameStore
    private var isStopped = false

    init(
        watchModeController: PaceScreenWatchModeController,
        frameStore: PaceCompanionEphemeralScreenFrameStore
    ) {
        self.watchModeController = watchModeController
        self.frameStore = frameStore
    }

    func start(emit: @escaping @Sendable (PaceObservationCandidate) -> Void) async throws {
        isStopped = false
        for await event in watchModeController.eventPublisher.values {
            guard Task.isCancelled == false, isStopped == false else { break }
            let evidenceIdentifier = UUID().uuidString
            await frameStore.insert(event.capture.imageData, identifier: evidenceIdentifier)
            emit(Self.candidate(from: event, evidenceIdentifier: evidenceIdentifier))
        }
    }

    func stop() async {
        isStopped = true
        await frameStore.removeAll()
    }

    static func candidate(
        from event: PaceScreenWatchEvent,
        evidenceIdentifier: String
    ) -> PaceObservationCandidate {
        PaceObservationCandidate(
            source: .screen,
            capturedAt: event.detectedAt,
            equivalenceKey: "screen:\(event.screenLabel)",
            priority: event.category == .majorScreenChange ? 2 : 1,
            structuredPayload: "\(event.screenLabel)|\(event.category.displayName)",
            evidenceReference: try? PaceEvidenceReference(
                type: "ephemeral-screen-frame",
                identifier: evidenceIdentifier
            )
        )
    }
}

nonisolated enum PaceCompanionScreenAnalysisClientFactory {
    @MainActor
    static func makePrivacyPinnedLocalClient() throws -> any PaceScreenAnalysisClient {
        if PaceBundledModelsSettings.isUsingMLXInProcessVLM() {
            return PaceScreenAnalysisClientFactory.makeDefaultClient()
        }
        let configuredURLString = AppBundleConfiguration.stringValue(forKey: "LocalVLMBaseURL")
            ?? PaceLocalEndpointGuard.defaultOpenAICompatibleBaseURL.absoluteString
        guard let configuredURL = URL(string: configuredURLString) else {
            throw PaceLocalEndpointGuardError(
                settingName: "LocalVLMBaseURL",
                rejectedValue: configuredURLString,
                reason: "URL is not parseable"
            )
        }
        try PaceLocalEndpointGuard.validateLocalHTTPURL(
            configuredURL,
            settingName: "LocalVLMBaseURL"
        )
        return PaceScreenAnalysisClientFactory.makeDefaultClient()
    }
}

actor PaceTargetedCompanionScreenInterpreter {
    private let analysisClient: any PaceScreenAnalysisClient
    private let frameStore: PaceCompanionEphemeralScreenFrameStore
    private let privacyPolicy: PaceCompanionPrivacyPolicy
    private let applicationBundleIdentifierProvider: @Sendable () -> String?

    init(
        analysisClient: any PaceScreenAnalysisClient,
        frameStore: PaceCompanionEphemeralScreenFrameStore,
        privacyPolicy: PaceCompanionPrivacyPolicy = PaceCompanionPrivacyPolicy(),
        applicationBundleIdentifierProvider: @escaping @Sendable () -> String? = { nil }
    ) {
        self.analysisClient = analysisClient
        self.frameStore = frameStore
        self.privacyPolicy = privacyPolicy
        self.applicationBundleIdentifierProvider = applicationBundleIdentifierProvider
    }

    func interpret(_ candidate: PaceObservationCandidate) async throws -> PaceWorldObservation? {
        guard candidate.source == .screen,
              let evidenceIdentifier = candidate.evidenceReference?.identifier,
              let frame = await frameStore.take(identifier: evidenceIdentifier) else {
            return nil
        }
        guard privacyPolicy.mayPersistContext(
            fromApplicationBundleIdentifier: applicationBundleIdentifierProvider()
        ) else {
            // `take` already removed the sensitive frame from bounded memory.
            return nil
        }
        let analysis = try await analysisClient.analyzeScreenshot(
            screenshotImageData: frame,
            userIntent: "Describe only the meaningful change represented by this accepted watch event."
        )
        let payloadParts = candidate.structuredPayload.split(separator: "|", maxSplits: 1).map(String.init)
        let screenLabel = payloadParts.first ?? "screen"
        return try PaceWorldObservation(
            observedAt: candidate.capturedAt,
            source: .screen,
            subject: PaceWorldSubject(kind: .environment, identifier: screenLabel),
            predicate: .changed,
            value: .text(privacyPolicy.redactedTextForPersistence(analysis.description)),
            location: PaceWorldLocation(source: .screen, zone: screenLabel),
            confidence: analysis.description.isEmpty ? 0.5 : 0.8,
            evidenceReference: candidate.evidenceReference
        )
    }
}
