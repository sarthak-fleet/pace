//
//  PaceCalendarPreMeetingNudgeGenerator.swift
//  leanring-buddy
//
//  Subscribes to `Timer.publish(every: 60)` (cheap, OS-supplied timer
//  source) and asks the existing `PaceCalendarRetrievalConnector` for
//  events starting within the next five minutes. Each event runs
//  through `PaceCalendarPreMeetingNudgeDecision.evaluate(...)` which
//  folds the restraint gate inline. The generator never speaks
//  directly; it routes through the orchestrator's emit/queueForLater
//  closures.
//
//  RAM discipline: per-generator state is the timer + a small set of
//  already-nudged event identifiers (bounded — cleared every 12 hours
//  so a long-running session can't grow the set unboundedly).
//

import Combine
import EventKit
import Foundation

@MainActor
final class PaceCalendarPreMeetingNudgeGenerator: PaceProactiveNudgeGenerator {
    let identifier = "calendar-pre-meeting"

    /// 60-second poll matches the PRD evaluation cadence.
    static let evaluationIntervalSeconds: TimeInterval = 60

    /// Pre-meeting lead time the gate considers "imminent". Matches
    /// the pure decision helper's threshold; pulled out for clarity.
    static let leadTimeLookaheadSeconds: TimeInterval = 5 * 60

    /// Bound on the dedup set's age. After 12 hours we drop entries
    /// so a long uptime can't grow the set forever. Calendar event
    /// identifiers are stable across the lifetime of an event, so
    /// 12 hours is plenty to cover the same meeting starting once.
    static let dedupSetMaximumAgeSeconds: TimeInterval = 12 * 60 * 60

    private let restraintContextProvider: () -> PaceRestraintContext
    private let upcomingEventSnapshotsProvider: (TimeInterval) -> [PaceCalendarRetrievalEventSnapshot]
    private let nowProvider: () -> Date

    private var evaluationTimer: Timer?
    private var alreadyNudgedByEventIdentifier: [String: Date] = [:]

    init(
        restraintContextProvider: @escaping () -> PaceRestraintContext,
        upcomingEventSnapshotsProvider: @escaping (TimeInterval) -> [PaceCalendarRetrievalEventSnapshot],
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.restraintContextProvider = restraintContextProvider
        self.upcomingEventSnapshotsProvider = upcomingEventSnapshotsProvider
        self.nowProvider = nowProvider
    }

    /// Convenience initializer that binds directly to a live
    /// `PaceCalendarRetrievalConnector`. CompanionManager uses this
    /// path; tests use the designated initializer with an injected
    /// snapshot provider so EventKit doesn't need to be mocked.
    convenience init(
        restraintContextProvider: @escaping () -> PaceRestraintContext,
        calendarConnector: PaceCalendarRetrievalConnector,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.init(
            restraintContextProvider: restraintContextProvider,
            upcomingEventSnapshotsProvider: { lookaheadSeconds in
                calendarConnector.upcomingEventSnapshots(lookaheadSeconds: lookaheadSeconds)
            },
            nowProvider: nowProvider
        )
    }

    func start(
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        guard evaluationTimer == nil else { return }

        let timer = Timer(
            timeInterval: Self.evaluationIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateNow(emit: emit, queueForLater: queueForLater)
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        evaluationTimer = timer
    }

    func stop() {
        evaluationTimer?.invalidate()
        evaluationTimer = nil
        alreadyNudgedByEventIdentifier.removeAll()
    }

    /// Test seam: drives one evaluation pass synchronously. Used
    /// by unit tests with an injected `upcomingEventSnapshotsProvider`.
    func evaluateNow(
        emit: (PaceProactiveUtterance) -> Void,
        queueForLater: (PaceProactiveUtterance) -> Void
    ) {
        let now = nowProvider()
        pruneStaleDedupEntries(now: now)

        let upcomingEvents = upcomingEventSnapshotsProvider(Self.leadTimeLookaheadSeconds)
        guard let nextEventSnapshot = upcomingEvents.first(where: { eventSnapshot in
            alreadyNudgedByEventIdentifier[eventSnapshot.stableIdentifier] == nil
        }) else { return }

        let startsInSeconds = nextEventSnapshot.startDate.timeIntervalSince(now)
        let restraintContext = restraintContextProvider()
        let evaluation = PaceCalendarPreMeetingNudgeDecision.evaluate(
            eventTitle: nextEventSnapshot.title,
            startsInSeconds: startsInSeconds,
            restraintContext: restraintContext
        )

        guard evaluation.utterance != nil else { return }
        alreadyNudgedByEventIdentifier[nextEventSnapshot.stableIdentifier] = now
        PaceProactiveNudgeFrameworkRouting.route(
            evaluation: evaluation,
            emit: emit,
            queueForLater: queueForLater
        )
    }

    private func pruneStaleDedupEntries(now: Date) {
        guard !alreadyNudgedByEventIdentifier.isEmpty else { return }
        let cutoffDate = now.addingTimeInterval(-Self.dedupSetMaximumAgeSeconds)
        alreadyNudgedByEventIdentifier = alreadyNudgedByEventIdentifier.filter { _, recordedAt in
            recordedAt >= cutoffDate
        }
    }
}
