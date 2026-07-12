//
//  PacePerceptionCoordinator.swift
//  leanring-buddy
//
//  Event-driven adapter boundary and per-source backpressure coordinator for
//  Always-On Companion Mode. Adapters own capture; this actor owns work policy.
//

import Foundation

nonisolated struct PaceObservationCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: PacePerceptionSourceKind
    let capturedAt: Date
    let equivalenceKey: String
    let priority: Int
    let structuredPayload: String
    let evidenceReference: PaceEvidenceReference?

    init(
        id: UUID = UUID(),
        source: PacePerceptionSourceKind,
        capturedAt: Date,
        equivalenceKey: String,
        priority: Int = 0,
        structuredPayload: String,
        evidenceReference: PaceEvidenceReference? = nil
    ) {
        self.id = id
        self.source = source
        self.capturedAt = capturedAt
        self.equivalenceKey = equivalenceKey
        self.priority = priority
        self.structuredPayload = structuredPayload
        self.evidenceReference = evidenceReference
    }
}

@MainActor
protocol PacePerceptionSourceAdapter: AnyObject, Sendable {
    nonisolated var sourceKind: PacePerceptionSourceKind { get }
    func start(emit: @escaping @Sendable (PaceObservationCandidate) -> Void) async throws
    func stop() async
}

actor PacePerceptionCoordinator {
    typealias CandidateAnalyzer = @Sendable (PaceObservationCandidate) async throws -> PaceWorldObservation?
    typealias ObservationConsumer = @Sendable (PaceWorldObservation) -> Void
    typealias SourceFailureConsumer = @Sendable (
        PacePerceptionSourceKind,
        PacePerceptionSourceFailure
    ) -> Void

    private let sourceAdapters: [any PacePerceptionSourceAdapter]
    private let candidateAnalyzer: CandidateAnalyzer
    private let observationConsumer: ObservationConsumer
    private let sourceFailureConsumer: SourceFailureConsumer
    private let now: @Sendable () -> Date
    private let maximumCandidateAge: TimeInterval
    private let resourceDecisionProvider: @Sendable () -> PaceCompanionResourceDecision

    private var isRunning = false
    private var lifecycleGeneration = 0
    private var sourceTasks: [PacePerceptionSourceKind: Task<Void, Never>] = [:]
    private var analysisTasks: [PacePerceptionSourceKind: Task<Void, Never>] = [:]
    private var pendingCandidates: [PacePerceptionSourceKind: PaceObservationCandidate] = [:]
    private var resourceMetrics = PaceCompanionResourceMetrics()

    init(
        sourceAdapters: [any PacePerceptionSourceAdapter],
        maximumCandidateAge: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = { Date() },
        resourceDecisionProvider: @escaping @Sendable () -> PaceCompanionResourceDecision = {
            PaceCompanionResourceDecision(
                mayRunCheapEventSources: true,
                mayRunCameraSampling: true,
                mayRunVLMAnalysis: true,
                degradedReason: nil
            )
        },
        candidateAnalyzer: @escaping CandidateAnalyzer,
        observationConsumer: @escaping ObservationConsumer,
        sourceFailureConsumer: @escaping SourceFailureConsumer = { _, _ in }
    ) {
        self.sourceAdapters = sourceAdapters
        self.maximumCandidateAge = max(0, maximumCandidateAge)
        self.now = now
        self.resourceDecisionProvider = resourceDecisionProvider
        self.candidateAnalyzer = candidateAnalyzer
        self.observationConsumer = observationConsumer
        self.sourceFailureConsumer = sourceFailureConsumer
    }

    func start(enabledSources: Set<PacePerceptionSourceKind>) {
        guard isRunning == false else { return }
        isRunning = true
        lifecycleGeneration += 1
        let generationAtStart = lifecycleGeneration

        for sourceAdapter in sourceAdapters where enabledSources.contains(sourceAdapter.sourceKind) {
            let coordinator = self
            sourceTasks[sourceAdapter.sourceKind] = Task {
                do {
                    try await sourceAdapter.start { candidate in
                        Task { await coordinator.submit(candidate) }
                    }
                } catch {
                    await coordinator.sourceStoppedUnexpectedly(
                        sourceKind: sourceAdapter.sourceKind,
                        generation: generationAtStart,
                        failure: Self.normalizedFailure(error)
                    )
                }
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        lifecycleGeneration += 1
        sourceTasks.values.forEach { $0.cancel() }
        analysisTasks.values.forEach { $0.cancel() }
        sourceTasks.removeAll()
        analysisTasks.removeAll()
        pendingCandidates.removeAll()
        for sourceAdapter in sourceAdapters {
            await sourceAdapter.stop()
        }
    }

    func submit(_ candidate: PaceObservationCandidate) {
        guard isRunning else { return }
        guard now().timeIntervalSince(candidate.capturedAt) <= maximumCandidateAge else {
            resourceMetrics.recordCandidate(accepted: false)
            return
        }
        let resourceDecision = resourceDecisionProvider()
        if candidate.source == .camera, resourceDecision.mayRunCameraSampling == false {
            resourceMetrics.recordCandidate(accepted: false)
            return
        }
        if candidate.source == .camera || candidate.source == .screen,
           resourceDecision.mayRunVLMAnalysis == false {
            resourceMetrics.recordCandidate(accepted: false)
            return
        }
        resourceMetrics.recordCandidate(accepted: true)

        if analysisTasks[candidate.source] != nil {
            let existingPendingCandidate = pendingCandidates[candidate.source]
            if shouldReplace(existingPendingCandidate, with: candidate) {
                pendingCandidates[candidate.source] = candidate
            }
            return
        }
        launchAnalysis(for: candidate)
    }

    func hasInFlightAnalysis(for source: PacePerceptionSourceKind) -> Bool {
        analysisTasks[source] != nil
    }

    func pendingCandidate(for source: PacePerceptionSourceKind) -> PaceObservationCandidate? {
        pendingCandidates[source]
    }

    func resourceMetricsSnapshot() -> PaceCompanionResourceMetrics {
        resourceMetrics
    }

    private func launchAnalysis(for candidate: PaceObservationCandidate) {
        resourceMetrics.recordModelCall()
        let generationAtLaunch = lifecycleGeneration
        analysisTasks[candidate.source] = Task { [weak self, candidateAnalyzer, observationConsumer] in
            let observation: PaceWorldObservation?
            do {
                observation = try await candidateAnalyzer(candidate)
            } catch {
                observation = nil
            }
            guard Task.isCancelled == false else { return }
            await self?.completeAnalysis(
                source: candidate.source,
                generation: generationAtLaunch,
                observation: observation,
                observationConsumer: observationConsumer
            )
        }
    }

    private func completeAnalysis(
        source: PacePerceptionSourceKind,
        generation: Int,
        observation: PaceWorldObservation?,
        observationConsumer: ObservationConsumer
    ) {
        guard isRunning, lifecycleGeneration == generation else { return }
        analysisTasks[source] = nil
        if let observation {
            observationConsumer(observation)
        }
        if let nextCandidate = pendingCandidates.removeValue(forKey: source),
           now().timeIntervalSince(nextCandidate.capturedAt) <= maximumCandidateAge {
            launchAnalysis(for: nextCandidate)
        }
    }

    private func sourceStoppedUnexpectedly(
        sourceKind: PacePerceptionSourceKind,
        generation: Int,
        failure: PacePerceptionSourceFailure
    ) {
        guard generation == lifecycleGeneration else { return }
        sourceTasks[sourceKind] = nil
        sourceFailureConsumer(sourceKind, failure)
    }

    private nonisolated static func normalizedFailure(_ error: Error) -> PacePerceptionSourceFailure {
        switch error as? PacePerceptionSourceError {
        case .permissionDenied: return .permissionDenied
        case .deviceUnavailable: return .deviceUnavailable
        case .sourceDisabled: return .sourceDisabled
        case nil: return .stoppedUnexpectedly
        }
    }

    private func shouldReplace(
        _ existingCandidate: PaceObservationCandidate?,
        with newCandidate: PaceObservationCandidate
    ) -> Bool {
        guard let existingCandidate else { return true }
        if existingCandidate.equivalenceKey == newCandidate.equivalenceKey {
            return newCandidate.capturedAt >= existingCandidate.capturedAt
        }
        if newCandidate.priority != existingCandidate.priority {
            return newCandidate.priority > existingCandidate.priority
        }
        return newCandidate.capturedAt >= existingCandidate.capturedAt
    }
}

nonisolated enum PacePerceptionSourceFailure: Equatable, Sendable {
    case sourceDisabled
    case permissionDenied
    case deviceUnavailable
    case stoppedUnexpectedly
}
