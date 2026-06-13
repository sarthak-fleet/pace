//
//  PaceProactiveNudgeFramework.swift
//  leanring-buddy
//
//  Generator + orchestrator scaffolding for the three proactive
//  nudge surfaces (focus fatigue, calendar pre-meeting, watch-mode
//  observation). Each generator subscribes to an ALREADY-running
//  source (PaceAppUsageTracker, PaceCalendarRetrievalConnector, or
//  PaceScreenWatchModeController) and emits gate-aware decisions.
//
//  The orchestrator wires the generators together, supplies the
//  live restraint-context snapshot, and routes results through the
//  emit / queueForLater closures the CompanionManager owns.
//
//  RAM discipline: per-generator state is the source's `Cancellable`
//  plus a `Date` (last-emit timestamp). No caches, no timers we own
//  beyond the cooldown bookkeeping.
//

import Combine
import Foundation

/// Generic generator surface. Each generator owns one source-side
/// subscription, calls into the matching `Pace*NudgeDecision.evaluate`
/// pure helper, and routes the resulting decision through the
/// closures the orchestrator provides.
@MainActor
protocol PaceProactiveNudgeGenerator: AnyObject {
    var identifier: String { get }
    /// Begins listening to the underlying source. Calls `emit` for
    /// `.speak` decisions and `queueForLater` for `.queueUntilIdle`
    /// decisions. `.stayQuiet` results are dropped silently.
    func start(
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    )
    func stop()
}

/// Owns a set of generators, hands each a live restraint-context
/// snapshot, and exposes the same start/stop contract individual
/// generators do so CompanionManager can toggle them per preference.
@MainActor
final class PaceProactiveNudgeOrchestrator {
    private let restraintContextProvider: () -> PaceRestraintContext
    private let generators: [PaceProactiveNudgeGenerator]
    private(set) var isRunning = false

    /// Designated initializer. `restraintContextProvider` is captured
    /// (not snapshotted) so every gate decision sees the latest
    /// values for `lastUserInputAt`, `isOnActiveCall`, profile, etc.
    init(
        restraintContextProvider: @escaping () -> PaceRestraintContext,
        generators: [PaceProactiveNudgeGenerator]
    ) {
        self.restraintContextProvider = restraintContextProvider
        self.generators = generators
    }

    func start(
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        guard !isRunning else { return }
        isRunning = true
        for generator in generators {
            generator.start(emit: emit, queueForLater: queueForLater)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for generator in generators {
            generator.stop()
        }
    }

    /// Toggles a single generator without tearing down the rest.
    /// Used by CompanionManager when the user flips an individual
    /// per-source nudge toggle in Settings → Proactive.
    func setGeneratorEnabled(
        identifier: String,
        enabled: Bool,
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        guard let generator = generators.first(where: { $0.identifier == identifier }) else {
            return
        }
        if enabled {
            generator.start(emit: emit, queueForLater: queueForLater)
        } else {
            generator.stop()
        }
    }

    /// Live snapshot used in tests + diagnostics. Pure helper —
    /// reads the captured provider once and returns its result.
    func currentRestraintContext() -> PaceRestraintContext {
        return restraintContextProvider()
    }

    /// Test seam: drives the routing path used by live generators
    /// without spinning up subscriptions. Verifies the
    /// emit / queueForLater wiring against an injected gate-aware
    /// evaluation result.
    func routeEvaluationForTesting(
        _ evaluation: PaceProactiveNudgeEvaluation,
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        PaceProactiveNudgeFrameworkRouting.route(
            evaluation: evaluation,
            emit: emit,
            queueForLater: queueForLater
        )
    }
}

/// Shared routing helper used by every generator. Lives at the
/// type level so a future generator can adopt the same emit /
/// queue contract without re-implementing the switch.
enum PaceProactiveNudgeFrameworkRouting {
    static func route(
        evaluation: PaceProactiveNudgeEvaluation,
        emit: (PaceProactiveUtterance) -> Void,
        queueForLater: (PaceProactiveUtterance) -> Void
    ) {
        guard let utterance = evaluation.utterance else { return }
        switch evaluation.decision {
        case .speak:
            emit(utterance)
        case .queueUntilIdle:
            queueForLater(utterance)
        case .stayQuiet:
            return
        }
    }
}

// MARK: - Cooldown bookkeeping

/// Per-generator cooldown gate that the generators apply BEFORE
/// asking the restraint gate. Keeps a single `Date` in memory so the
/// RAM budget stays effectively zero.
@MainActor
struct PaceProactiveNudgeCooldown {
    private(set) var lastEmittedAt: Date?
    let minimumIntervalSeconds: TimeInterval

    init(minimumIntervalSeconds: TimeInterval) {
        self.minimumIntervalSeconds = minimumIntervalSeconds
    }

    func isCoolingDown(now: Date) -> Bool {
        guard let lastEmittedAt else { return false }
        return now.timeIntervalSince(lastEmittedAt) < minimumIntervalSeconds
    }

    mutating func markEmitted(at now: Date) {
        lastEmittedAt = now
    }
}
