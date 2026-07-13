//
//  PaceCompanionRuntime.swift
//  leanring-buddy
//
//  Observe-only app lifecycle wiring for Always-On Companion Mode. Existing
//  ambient/watch, production low-rate camera, and the local pre-STT wake gate
//  run now. Accepted wakes hand off to the existing bounded PTT conversation.
//  Optional cards and speech remain separately opt-in and pass through the
//  companion intervention and live restraint policies before presentation.
//

import AppKit
import Combine
import Foundation

@MainActor
final class PaceCompanionRuntime {
    private final class CoordinatorShutdownOperation {
        let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }
    }

    typealias StatusConsumer = (
        PaceCompanionRuntimeState,
        Set<PacePerceptionSourceKind>,
        Date?
    ) -> Void
    typealias PresentationLiveContextProvider = () -> PaceCompanionPresentationLiveContext
    typealias PresentationConsumer = (PaceCompanionObservationPresentation) -> Void

    private let modeController = PaceCompanionModeController()
    private let ambientContextStore: PaceAmbientContextStore
    private let watchModeController: PaceScreenWatchModeController
    private let localRetriever: PaceLocalRetriever
    private let cameraCaptureClient: any PaceCameraCaptureClient
    private let ambientWakeGate: any PaceLocalWakeGate
    private let ambientWakeHandler: PaceCompanionAmbientWakeSource.WakeHandler
    private let ambientWakeCancellationHandler: PaceCompanionAmbientWakeSource.CancellationHandler
    private let presentationLiveContextProvider: PresentationLiveContextProvider
    private let presentationConsumer: PresentationConsumer
    private let statusConsumer: StatusConsumer
    private let frameStore = PaceCompanionEphemeralScreenFrameStore()
    private let memoryCoordinator: PaceCompanionMemoryCoordinator
    private var observationPresenter = PaceCompanionObservationPresenter()
    private var perceptionCoordinator: PacePerceptionCoordinator?
    private var coordinatorShutdownOperation: CoordinatorShutdownOperation?
    private var activeSources: Set<PacePerceptionSourceKind> = []
    private var latestPreferences = PaceCompanionPreferences.disabled
    private var lifecycleGeneration = 0
    private var isSuspendedForSystemSleep = false
    private var systemLifecycleCancellables: Set<AnyCancellable> = []

    init(
        ambientContextStore: PaceAmbientContextStore,
        watchModeController: PaceScreenWatchModeController,
        localRetriever: PaceLocalRetriever,
        cameraCaptureClient: any PaceCameraCaptureClient = PaceAVFoundationCameraCaptureClient(),
        ambientWakeGate: any PaceLocalWakeGate = PaceCoreMLWakeGate(),
        ambientWakeHandler: @escaping PaceCompanionAmbientWakeSource.WakeHandler = { _ in false },
        ambientWakeCancellationHandler: @escaping PaceCompanionAmbientWakeSource.CancellationHandler = {},
        presentationLiveContextProvider: @escaping PresentationLiveContextProvider = {
            PaceCompanionPresentationLiveContext(
                now: Date(),
                profile: .reserved,
                isOnActiveCall: true,
                isInFocusMode: true,
                hasRecentUserInput: true
            )
        },
        presentationConsumer: @escaping PresentationConsumer = { _ in },
        statusConsumer: @escaping StatusConsumer
    ) {
        self.ambientContextStore = ambientContextStore
        self.watchModeController = watchModeController
        self.localRetriever = localRetriever
        self.cameraCaptureClient = cameraCaptureClient
        self.ambientWakeGate = ambientWakeGate
        self.ambientWakeHandler = ambientWakeHandler
        self.ambientWakeCancellationHandler = ambientWakeCancellationHandler
        self.presentationLiveContextProvider = presentationLiveContextProvider
        self.presentationConsumer = presentationConsumer
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
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        latestPreferences = preferences
        isSuspendedForSystemSleep = false
        await stopCoordinatorOnly(for: generation)
        guard generation == lifecycleGeneration, Task.isCancelled == false else { return }
        activeSources.removeAll()
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
                zones: Self.defaultCameraZones,
                isEnabled: true
            ))
        }

        var ambientVoicePreparationFailure: PacePerceptionSourceFailure?
        if preferences.enabledSources.contains(.ambientVoice) {
            let ambientVoiceSource = PaceCompanionAmbientWakeSource(
                wakeGate: ambientWakeGate,
                wakeHandler: ambientWakeHandler,
                cancellationHandler: ambientWakeCancellationHandler
            )
            do {
                try await ambientVoiceSource.prepare()
                guard generation == lifecycleGeneration, Task.isCancelled == false else { return }
                adapters.append(ambientVoiceSource)
            } catch PaceLocalWakeGateError.permissionDenied {
                ambientVoicePreparationFailure = .permissionDenied
            } catch {
                // A missing asset, invalid label contract, or unusable audio
                // input leaves companion microphone capture inactive.
                ambientVoicePreparationFailure = .deviceUnavailable
            }
            guard generation == lifecycleGeneration, Task.isCancelled == false else { return }
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
                    guard runtime.lifecycleGeneration == generation else { return }
                    runtime.acceptObservation(observation)
                }
            },
            sourceFailureConsumer: { source, failure in
                Task { @MainActor in
                    guard runtime.lifecycleGeneration == generation else { return }
                    runtime.handleSourceFailure(source: source, failure: failure)
                }
            }
        )
        perceptionCoordinator = coordinator
        activeSources = Set(adapters.map(\.sourceKind))
        await coordinator.start(enabledSources: activeSources)
        guard generation == lifecycleGeneration, Task.isCancelled == false else {
            await coordinator.stop()
            if perceptionCoordinator === coordinator {
                perceptionCoordinator = nil
            }
            return
        }
        do { try modeController.markReady() } catch { }

        if let ambientVoicePreparationFailure {
            handleSourceFailure(
                source: .ambientVoice,
                failure: ambientVoicePreparationFailure
            )
        }
        publishStatus()
    }

    func pause() async {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        isSuspendedForSystemSleep = false
        await stopCoordinatorOnly(for: generation)
        guard generation == lifecycleGeneration else { return }
        modeController.pause()
        activeSources.removeAll()
        publishStatus()
    }

    func stop() async {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        isSuspendedForSystemSleep = false
        await stopCoordinatorOnly(for: generation)
        guard generation == lifecycleGeneration else { return }
        modeController.stop()
        activeSources.removeAll()
        publishStatus()
    }

    func clear(source: PacePerceptionSourceKind) {
        try? memoryCoordinator.clear(source: source)
        observationPresenter = PaceCompanionObservationPresenter()
        publishStatus()
    }

    func clearAll() {
        try? memoryCoordinator.clearAll()
        observationPresenter = PaceCompanionObservationPresenter()
        publishStatus()
    }

    func teachObject(label: String) async throws -> [String] {
        guard activeSources.contains(.camera) else {
            throw PaceTaughtObjectError.cameraNotActive
        }
        try await cameraCaptureClient.teachObject(label: label)
        return await cameraCaptureClient.taughtObjectLabels()
    }

    func removeTaughtObject(label: String) async throws -> [String] {
        try await cameraCaptureClient.removeTaughtObject(label: label)
        return await cameraCaptureClient.taughtObjectLabels()
    }

    func taughtObjectLabels() async -> [String] {
        await cameraCaptureClient.taughtObjectLabels()
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
        do {
            try memoryCoordinator.accept(
                enrichedObservation,
                applicationBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )
            let presentation = observationPresenter.presentation(
                for: enrichedObservation,
                preferences: latestPreferences,
                liveContext: presentationLiveContextProvider()
            )
            presentationConsumer(presentation)
        } catch {
            // Duplicate, expired, or invalid observations remain silent.
        }
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

    private func stopCoordinatorOnly(for generation: Int) async {
        if let existingOperation = coordinatorShutdownOperation {
            await existingOperation.task.value
            if coordinatorShutdownOperation === existingOperation {
                coordinatorShutdownOperation = nil
            }
            guard generation == lifecycleGeneration else { return }
        }
        guard generation == lifecycleGeneration else { return }
        let coordinator = perceptionCoordinator
        perceptionCoordinator = nil
        let frameStore = frameStore
        let shutdownTask = Task { @MainActor in
            if let coordinator {
                await coordinator.stop()
            }
            await frameStore.removeAll()
        }
        let operation = CoordinatorShutdownOperation(task: shutdownTask)
        coordinatorShutdownOperation = operation
        await shutdownTask.value
        if coordinatorShutdownOperation === operation {
            coordinatorShutdownOperation = nil
        }
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
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        isSuspendedForSystemSleep = true
        await stopCoordinatorOnly(for: generation)
        guard generation == lifecycleGeneration else { return }
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

    private nonisolated static let defaultCameraZones = [
        PaceCameraZone(
            name: "left side",
            minimumX: 0,
            maximumX: 0.34,
            minimumY: 0,
            maximumY: 1
        ),
        PaceCameraZone(
            name: "center",
            minimumX: 0.34,
            maximumX: 0.66,
            minimumY: 0,
            maximumY: 1
        ),
        PaceCameraZone(
            name: "right side",
            minimumX: 0.66,
            maximumX: 1,
            minimumY: 0,
            maximumY: 1
        ),
    ]
}

@MainActor
extension CompanionManager {
    func companionPreferencesChanged(_ preferences: PaceCompanionPreferences) {
        companionRuntimeTransitionTask?.cancel()
        // Any preference/source transition invalidates pending output created
        // under the old consent snapshot.
        suspendCompanionPresentations()
        if preferences.isCompanionModeEnabled,
           preferences.enabledSources.contains(.ambientVoice) {
            // Release the legacy Speech.framework spotter before the local
            // companion gate begins preparing microphone ownership.
            wakeWordSpotter.pauseForExternalAudioConsumer()
        }
        companionRuntimeTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await companionRuntime.start(preferences: preferences)
        }
    }

    func startCompanionRuntimeIfEnabled() {
        let preferences = companionControlCenter.preferences
        companionControlCenter.updateLocalModelReadiness(isLMStudioReachable)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let labels = await companionRuntime.taughtObjectLabels()
            companionControlCenter.updateTaughtObjectLabels(labels)
        }
        guard preferences.isCompanionModeEnabled else { return }
        companionPreferencesChanged(preferences)
    }

    func stopCompanionRuntime() {
        suspendCompanionPresentations()
        companionRuntimeTransitionTask?.cancel()
        companionRuntimeTransitionTask = Task { @MainActor [weak self] in
            await self?.companionRuntime.stop()
        }
    }

    func pauseCompanionRuntime() {
        suspendCompanionPresentations()
        companionRuntimeTransitionTask?.cancel()
        companionRuntimeTransitionTask = Task { @MainActor [weak self] in
            await self?.companionRuntime.pause()
        }
    }

    func handleCompanionObservationPresentation(
        _ presentation: PaceCompanionObservationPresentation
    ) {
        switch presentation.action {
        case .none:
            break
        case .card(let content):
            pendingCompanionCardPresentationTask?.cancel()
            pendingCompanionCardPresentationTask = nil
            presentCompanionObservationCard(content)
        case .spoken(let content), .clarification(let content):
            routeCompanionObservationSpeech(content, expiresAt: presentation.candidate.expiresAt)
        case .queued(let queued):
            switch queued.delivery {
            case .card:
                queueCompanionObservationCard(
                    queued.content,
                    expiresAt: presentation.candidate.expiresAt
                )
            case .spoken, .clarification:
                // The proactive pipeline independently re-checks the live
                // call, Focus, input, voice-state, and cooldown restraints.
                routeCompanionObservationSpeech(
                    queued.content,
                    expiresAt: presentation.candidate.expiresAt
                )
            }
        }
    }

    func suspendCompanionPresentations() {
        pendingCompanionCardPresentationTask?.cancel()
        pendingCompanionCardPresentationTask = nil
        dismissCompanionObservationCard()
        proactivityPipeline.removeQueuedProactiveUtterances(from: .companionEvent)
    }

    private func routeCompanionObservationSpeech(
        _ content: PaceCompanionPresentationContent,
        expiresAt: Date
    ) {
        proactivityPipeline.routeCompanionUtterance(
            spokenText: content.text,
            confidence: content.provenance.confidence,
            expiresAt: expiresAt
        )
    }

    private func queueCompanionObservationCard(
        _ content: PaceCompanionPresentationContent,
        expiresAt: Date
    ) {
        pendingCompanionCardPresentationTask?.cancel()
        pendingCompanionCardPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while Task.isCancelled == false && Date() < expiresAt {
                let now = Date()
                let hasRecentInput = userInputActivityMonitor.lastUserInputAt.map {
                    now.timeIntervalSince($0) < PaceRestraintGate.activeInputWindowSeconds
                } ?? false
                if activeCallDetector.isOnActiveCall == false,
                   focusModeMonitor.isCurrentlyInUserFocus == false,
                   hasRecentInput == false,
                   voiceState == .idle {
                    presentCompanionObservationCard(content)
                    pendingCompanionCardPresentationTask = nil
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            pendingCompanionCardPresentationTask = nil
        }
    }
}
