import Foundation
import Testing

@testable import Pace

struct PacePerceptionCoordinatorTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func equivalentBurstsKeepOnlyNewestCandidateBehindOneInFlightAnalysis() async throws {
        let gate = PerceptionAnalysisGate()
        let coordinator = PacePerceptionCoordinator(
            sourceAdapters: [],
            now: { Date(timeIntervalSince1970: 2_000_000_000) },
            candidateAnalyzer: { candidate in
                await gate.analyze(candidate)
                return nil
            },
            observationConsumer: { _ in }
        )
        await coordinator.start(enabledSources: [.screen])
        let first = candidate(id: UUID(), capturedAt: now)
        let second = candidate(id: UUID(), capturedAt: now.addingTimeInterval(1))
        let newest = candidate(id: UUID(), capturedAt: now.addingTimeInterval(2))

        await coordinator.submit(first)
        await waitUntil { await gate.startedCandidateIDs().count == 1 }
        await coordinator.submit(second)
        await coordinator.submit(newest)

        #expect(await coordinator.hasInFlightAnalysis(for: .screen))
        #expect(await coordinator.pendingCandidate(for: .screen)?.id == newest.id)
        await gate.releaseNext()
        await waitUntil { await gate.startedCandidateIDs().count == 2 }
        #expect(await gate.startedCandidateIDs() == [first.id, newest.id])
        await gate.releaseNext()
        await coordinator.stop()
    }

    @Test func staleCandidatesAreDroppedBeforeAnalysis() async {
        let gate = PerceptionAnalysisGate()
        let coordinator = PacePerceptionCoordinator(
            sourceAdapters: [],
            maximumCandidateAge: 5,
            now: { Date(timeIntervalSince1970: 2_000_000_000) },
            candidateAnalyzer: { candidate in
                await gate.analyze(candidate)
                return nil
            },
            observationConsumer: { _ in }
        )
        await coordinator.start(enabledSources: [.screen])
        await coordinator.submit(candidate(capturedAt: now.addingTimeInterval(-6)))
        #expect(await coordinator.hasInFlightAnalysis(for: .screen) == false)
        #expect(await gate.startedCandidateIDs().isEmpty)
        await coordinator.stop()
    }

    @Test func stopCancelsInFlightWorkClearsPendingAndStopsInjectedSource() async {
        let source = TestPerceptionSource(sourceKind: .camera)
        let coordinator = PacePerceptionCoordinator(
            sourceAdapters: [source],
            now: { Date(timeIntervalSince1970: 2_000_000_000) },
            candidateAnalyzer: { _ in
                try await Task.sleep(for: .seconds(30))
                return nil
            },
            observationConsumer: { _ in }
        )
        await coordinator.start(enabledSources: [.camera])
        await coordinator.submit(candidate(source: .camera, capturedAt: now))
        await coordinator.submit(candidate(source: .camera, capturedAt: now.addingTimeInterval(1)))
        await coordinator.stop()

        #expect(await coordinator.hasInFlightAnalysis(for: .camera) == false)
        #expect(await coordinator.pendingCandidate(for: .camera) == nil)
        #expect(await source.stopCallCount() == 1)
    }

    @Test func resourceDegradationDropsCameraBeforeModelAnalysisAndRecordsMetrics() async {
        let gate = PerceptionAnalysisGate()
        let coordinator = PacePerceptionCoordinator(
            sourceAdapters: [],
            now: { Date(timeIntervalSince1970: 2_000_000_000) },
            resourceDecisionProvider: {
                PaceCompanionResourceDecision(
                    mayRunCheapEventSources: true,
                    mayRunCameraSampling: false,
                    mayRunVLMAnalysis: false,
                    degradedReason: .thermalPressure
                )
            },
            candidateAnalyzer: { candidate in
                await gate.analyze(candidate)
                return nil
            },
            observationConsumer: { _ in }
        )
        await coordinator.start(enabledSources: [.camera])
        await coordinator.submit(candidate(source: .camera, capturedAt: now))
        #expect(await gate.startedCandidateIDs().isEmpty)
        let metrics = await coordinator.resourceMetricsSnapshot()
        #expect(metrics.acceptedCandidateCount == 0)
        #expect(metrics.droppedCandidateCount == 1)
        #expect(metrics.modelCallCount == 0)
        await coordinator.stop()
    }

    private func candidate(
        id: UUID = UUID(),
        source: PacePerceptionSourceKind = .screen,
        capturedAt: Date
    ) -> PaceObservationCandidate {
        PaceObservationCandidate(
            id: id,
            source: source,
            capturedAt: capturedAt,
            equivalenceKey: "visual-change",
            structuredPayload: "changed"
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

private actor PerceptionAnalysisGate {
    private var startedIDs: [UUID] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func analyze(_ candidate: PaceObservationCandidate) async {
        startedIDs.append(candidate.id)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func startedCandidateIDs() -> [UUID] {
        startedIDs
    }

    func releaseNext() {
        guard continuations.isEmpty == false else { return }
        continuations.removeFirst().resume()
    }
}

private actor TestPerceptionSource: PacePerceptionSourceAdapter {
    nonisolated let sourceKind: PacePerceptionSourceKind
    private var stopCalls = 0

    init(sourceKind: PacePerceptionSourceKind) {
        self.sourceKind = sourceKind
    }

    func start(emit: @escaping @Sendable (PaceObservationCandidate) -> Void) async throws {
        try await Task.sleep(for: .seconds(30))
    }

    func stop() {
        stopCalls += 1
    }

    func stopCallCount() -> Int {
        stopCalls
    }
}
