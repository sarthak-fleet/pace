//
//  PaceCompanionRuntime.swift
//  leanring-buddy
//
//  Observe-only app lifecycle wiring for Always-On Companion Mode. Existing
//  ambient/watch and the production low-rate camera source run now. Ambient
//  voice remains visibly unavailable until a true pre-STT wake gate exists.
//  No unsolicited output is produced.
//

import AppKit
import Combine
import Foundation

@MainActor
final class PaceCompanionRuntime {
    typealias StatusConsumer = (
        PaceCompanionRuntimeState,
        Set<PacePerceptionSourceKind>,
        Date?
    ) -> Void

    private let modeController = PaceCompanionModeController()
    private let ambientContextStore: PaceAmbientContextStore
    private let watchModeController: PaceScreenWatchModeController
    private let localRetriever: PaceLocalRetriever
    private let cameraCaptureClient: any PaceCameraCaptureClient
    private let statusConsumer: StatusConsumer
    private let frameStore = PaceCompanionEphemeralScreenFrameStore()
    private let memoryCoordinator: PaceCompanionMemoryCoordinator
    private var perceptionCoordinator: PacePerceptionCoordinator?
    private var activeSources: Set<PacePerceptionSourceKind> = []
    private var latestPreferences = PaceCompanionPreferences.disabled
    private var isSuspendedForSystemSleep = false
    private var systemLifecycleCancellables: Set<AnyCancellable> = []

    init(
        ambientContextStore: PaceAmbientContextStore,
        watchModeController: PaceScreenWatchModeController,
        localRetriever: PaceLocalRetriever,
        cameraCaptureClient: any PaceCameraCaptureClient = PaceAVFoundationCameraCaptureClient(),
        statusConsumer: @escaping StatusConsumer
    ) {
        self.ambientContextStore = ambientContextStore
        self.watchModeController = watchModeController
        self.localRetriever = localRetriever
        self.cameraCaptureClient = cameraCaptureClient
        self.statusConsumer = statusConsumer
        let observationStore = PaceWorldObservationStore(
            fileURL: PaceWorldObservationStore.defaultPersistenceURL()
        )
        self.memoryCoordinator = PaceCompanionMemoryCoordinator(
            observationStore: observationStore,
            memoryPolicy: PaceCompanionMemoryPolicy(),
            replaceRetrievalDocuments: { documents in
                localRetriever.replaceDocuments(documents, forSource: .companionMemory)
            }
        )
        self.memoryCoordinator.refreshRetrievalDocuments()
        bindSystemLifecycle()
    }

    func start(preferences: PaceCompanionPreferences) async {
        latestPreferences = preferences
        isSuspendedForSystemSleep = false
        await stopCoordinatorOnly()
        modeController.stop()
        guard preferences.isCompanionModeEnabled else {
            publishStatus()
            return
        }
        do {
            try modeController.start(isEnabled: true)
        } catch {
            publishStatus()
            return
        }

        var adapters: [any PacePerceptionSourceAdapter] = []
        if preferences.enabledSources.contains(.macOSContext) {
            adapters.append(PaceAmbientContextPerceptionAdapter(
                ambientContextStore: ambientContextStore
            ))
        }

        if preferences.enabledSources.contains(.camera) {
            adapters.append(PaceCameraPerceptionSource(
                captureClient: cameraCaptureClient,
                zones: [PaceCameraZone(
                    name: "room",
                    minimumX: 0,
                    maximumX: 1,
                    minimumY: 0,
                    maximumY: 1
                )],
                isEnabled: true
            ))
        }

        var screenInterpreter: PaceTargetedCompanionScreenInterpreter?
        if preferences.enabledSources.contains(.screen) {
            do {
                let screenClient = try PaceCompanionScreenAnalysisClientFactory
                    .makePrivacyPinnedLocalClient()
                screenInterpreter = PaceTargetedCompanionScreenInterpreter(
                    analysisClient: screenClient,
                    frameStore: frameStore,
                    applicationBundleIdentifierProvider: {
                        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    }
                )
                adapters.append(PaceScreenWatchPerceptionAdapter(
                    watchModeController: watchModeController,
                    frameStore: frameStore
                ))
            } catch {
                modeController.blockForPrivacy(.invalidLocalEndpoint)
                publishStatus()
                return
            }
        }

        let runtime = self
        let resolvedScreenInterpreter = screenInterpreter
        let coordinator = PacePerceptionCoordinator(
            sourceAdapters: adapters,
            candidateAnalyzer: { candidate in
                try await Self.interpretCandidate(
                    candidate,
                    screenInterpreter: resolvedScreenInterpreter
                )
            },
            observationConsumer: { observation in
                Task { @MainActor in
                    runtime.acceptObservation(observation)
                }
            },
            sourceFailureConsumer: { source, failure in
                Task { @MainActor in
                    runtime.handleSourceFailure(source: source, failure: failure)
                }
            }
        )
        perceptionCoordinator = coordinator
        activeSources = Set(adapters.map(\.sourceKind))
        await coordinator.start(enabledSources: activeSources)
        do { try modeController.markReady() } catch { }

        if preferences.enabledSources.contains(.ambientVoice) {
            modeController.degrade(.microphoneUnavailable)
        }
        publishStatus()
    }

    func pause() async {
        isSuspendedForSystemSleep = false
        await stopCoordinatorOnly()
        modeController.pause()
        activeSources.removeAll()
        publishStatus()
    }

    func stop() async {
        isSuspendedForSystemSleep = false
        await stopCoordinatorOnly()
        modeController.stop()
        activeSources.removeAll()
        publishStatus()
    }

    func clear(source: PacePerceptionSourceKind) {
        try? memoryCoordinator.clear(source: source)
        publishStatus()
    }

    func clearAll() {
        try? memoryCoordinator.clearAll()
        publishStatus()
    }

    private func acceptObservation(_ observation: PaceWorldObservation) {
        let ambientSnapshot = ambientContextStore.currentSnapshot
        let context = PaceWorldObservationContext(
            applicationName: ambientSnapshot?.frontmostAppName,
            applicationBundleIdentifier: ambientSnapshot?.frontmostBundleID,
            windowTitle: ambientSnapshot?.focusedWindowTitle,
            screenLabel: observation.location?.source == .screen ? observation.location?.zone : nil
        )
        let enrichedObservation = (try? PaceWorldObservation(
            id: observation.id,
            observedAt: observation.observedAt,
            source: observation.source,
            subject: observation.subject,
            predicate: observation.predicate,
            value: observation.value,
            location: observation.location,
            confidence: observation.confidence,
            evidenceReference: observation.evidenceReference,
            expiresAt: observation.expiresAt,
            supersedesObservationIDs: observation.supersedesObservationIDs,
            context: context
        )) ?? observation
        try? memoryCoordinator.accept(
            enrichedObservation,
            applicationBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        if modeController.state == .observing {
            try? modeController.beginInterpretation()
            try? modeController.completeInterpretation(observedAt: enrichedObservation.observedAt)
        } else {
            modeController.recordObservation(at: enrichedObservation.observedAt)
        }
        publishStatus()
    }

    private func handleSourceFailure(
        source: PacePerceptionSourceKind,
        failure: PacePerceptionSourceFailure
    ) {
        activeSources.remove(source)
        switch (source, failure) {
        case (.camera, .permissionDenied):
            modeController.blockForPrivacy(.cameraPermissionDenied)
        case (.ambientVoice, .permissionDenied):
            modeController.blockForPrivacy(.microphonePermissionDenied)
        case (.screen, .permissionDenied):
            modeController.blockForPrivacy(.screenPermissionDenied)
        case (.camera, _):
            modeController.degrade(.cameraUnavailable)
        case (.ambientVoice, _):
            modeController.degrade(.microphoneUnavailable)
        case (.screen, _):
            modeController.degrade(.localModelUnavailable)
        case (.macOSContext, _), (.userCorrection, _):
            break
        }
        publishStatus()
    }

    private func stopCoordinatorOnly() async {
        if let perceptionCoordinator {
            await perceptionCoordinator.stop()
        }
        perceptionCoordinator = nil
        await frameStore.removeAll()
    }

    private func publishStatus() {
        statusConsumer(modeController.state, activeSources, modeController.lastObservationAt)
    }

    private func bindSystemLifecycle() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.suspendForSystemSleep()
                }
            }
            .store(in: &systemLifecycleCancellables)
        workspaceCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.resumeAfterSystemWake()
                }
            }
            .store(in: &systemLifecycleCancellables)
    }

    private func suspendForSystemSleep() async {
        guard latestPreferences.isCompanionModeEnabled else { return }
        isSuspendedForSystemSleep = true
        await stopCoordinatorOnly()
        activeSources.removeAll()
        modeController.pause()
        publishStatus()
    }

    private func resumeAfterSystemWake() async {
        guard isSuspendedForSystemSleep else { return }
        isSuspendedForSystemSleep = false
        await start(preferences: latestPreferences)
    }

    private nonisolated static func interpretCandidate(
        _ candidate: PaceObservationCandidate,
        screenInterpreter: PaceTargetedCompanionScreenInterpreter?
    ) async throws -> PaceWorldObservation? {
        switch candidate.source {
        case .camera:
            return try PaceCameraObservationInterpreter.observation(from: candidate)
        case .screen:
            return try await screenInterpreter?.interpret(candidate)
        case .ambientVoice:
            guard let data = candidate.structuredPayload.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(
                    PaceAmbientVoiceCandidatePayload.self,
                    from: data
                  ) else { return nil }
            return try PaceWorldObservation(
                observedAt: candidate.capturedAt,
                source: .ambientVoice,
                subject: PaceWorldSubject(kind: .environment, identifier: "active conversation"),
                predicate: .says,
                value: .text(payload.transcript),
                confidence: 1,
                expiresAt: candidate.capturedAt.addingTimeInterval(5 * 60)
            )
        case .macOSContext:
            return try PaceWorldObservation(
                observedAt: candidate.capturedAt,
                source: .macOSContext,
                subject: PaceWorldSubject(kind: .environment, identifier: "Mac context"),
                predicate: .changed,
                value: .text(candidate.structuredPayload),
                confidence: 1,
                expiresAt: candidate.capturedAt.addingTimeInterval(24 * 60 * 60)
            )
        case .userCorrection:
            return nil
        }
    }
}

@MainActor
extension CompanionManager {
    func companionPreferencesChanged(_ preferences: PaceCompanionPreferences) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await companionRuntime.start(preferences: preferences)
        }
    }

    func startCompanionRuntimeIfEnabled() {
        let preferences = companionControlCenter.preferences
        companionControlCenter.updateLocalModelReadiness(isLMStudioReachable)
        guard preferences.isCompanionModeEnabled else { return }
        companionPreferencesChanged(preferences)
    }

    func stopCompanionRuntime() {
        Task { @MainActor [weak self] in
            await self?.companionRuntime.stop()
        }
    }
}
