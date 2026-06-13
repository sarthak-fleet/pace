//
//  PaceFocusFatigueNudgeGenerator.swift
//  leanring-buddy
//
//  Subscribes to the OS-broadcast `NSWorkspace.didActivateApplication
//  Notification` (the same source `PaceAppUsageTracker` already uses
//  in-process) to track how long the user has been on the current
//  frontmost app. Polls a 60-second timer to ask the pure decision
//  helper whether the foreground stretch is long enough to nudge.
//
//  Per-generator RAM cost: one notification observer + one repeating
//  timer + two `Date`s (current-app activation start + last emit).
//  Zero unbounded caches — when the frontmost app changes, the
//  start time resets and the old value is dropped.
//
//  This generator NEVER speaks directly; it routes its evaluation
//  through the orchestrator's emit/queueForLater closures so the
//  gate's active-call / recent-input / cooldown semantics always
//  apply.
//

import AppKit
import Combine
import Foundation

@MainActor
final class PaceFocusFatigueNudgeGenerator: PaceProactiveNudgeGenerator {
    let identifier = "focus-fatigue"

    /// 60 seconds matches the PRD evaluation cadence. A faster tick
    /// burns CPU without gaining the user anything; a slower tick
    /// can miss the "between calls" sweet spot.
    static let evaluationIntervalSeconds: TimeInterval = 60

    /// Internal cooldown — the gate already enforces its own
    /// proactive cooldown, but a per-generator floor of 15 minutes
    /// stops one long stretch from rapid-firing every tick once the
    /// gate's profile cooldown elapses.
    static let perGeneratorCooldownSeconds: TimeInterval = 15 * 60

    private let restraintContextProvider: () -> PaceRestraintContext
    private let frontmostApplicationNameProvider: () -> String?
    private let nowProvider: () -> Date

    private var workspaceActivationObserver: NSObjectProtocol?
    private var evaluationTimer: Timer?
    private var currentFrontmostAppName: String?
    private var currentFrontmostAppActivatedAt: Date?
    private var cooldown = PaceProactiveNudgeCooldown(
        minimumIntervalSeconds: PaceFocusFatigueNudgeGenerator.perGeneratorCooldownSeconds
    )

    init(
        restraintContextProvider: @escaping () -> PaceRestraintContext,
        frontmostApplicationNameProvider: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.localizedName
        },
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.restraintContextProvider = restraintContextProvider
        self.frontmostApplicationNameProvider = frontmostApplicationNameProvider
        self.nowProvider = nowProvider
    }

    func start(
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        guard workspaceActivationObserver == nil else { return }

        if let initialFrontmostName = frontmostApplicationNameProvider() {
            currentFrontmostAppName = initialFrontmostName
            currentFrontmostAppActivatedAt = nowProvider()
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification
                .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedApplicationName = activatedApplication?.localizedName
            Task { @MainActor [weak self] in
                self?.recordFrontmostApplicationActivated(named: activatedApplicationName)
            }
        }

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
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
        evaluationTimer?.invalidate()
        evaluationTimer = nil
        currentFrontmostAppName = nil
        currentFrontmostAppActivatedAt = nil
    }

    /// Test seam: drives one evaluation pass synchronously against
    /// the injected providers. Avoids the timer-and-notification
    /// dance so unit tests can assert emit/queue routing directly.
    func evaluateNow(
        emit: (PaceProactiveUtterance) -> Void,
        queueForLater: (PaceProactiveUtterance) -> Void
    ) {
        let now = nowProvider()
        guard let frontmostAppName = currentFrontmostAppName,
              let activatedAt = currentFrontmostAppActivatedAt else { return }

        let continuousForegroundSeconds = now.timeIntervalSince(activatedAt)
        guard continuousForegroundSeconds >= 45 * 60 else { return }

        if cooldown.isCoolingDown(now: now) { return }

        let restraintContext = restraintContextProvider()
        let evaluation = PaceFocusFatigueNudgeDecision.evaluate(
            appName: frontmostAppName,
            continuousForegroundSeconds: continuousForegroundSeconds,
            restraintContext: restraintContext
        )

        guard evaluation.utterance != nil else { return }
        cooldown.markEmitted(at: now)
        PaceProactiveNudgeFrameworkRouting.route(
            evaluation: evaluation,
            emit: emit,
            queueForLater: queueForLater
        )
    }

    /// Test seam: pushes a synthetic frontmost-app activation so
    /// unit tests can deterministically set the elapsed time without
    /// relying on the real NSWorkspace notification.
    func injectFrontmostApplicationActivationForTesting(
        applicationName: String,
        activatedAt: Date
    ) {
        currentFrontmostAppName = applicationName
        currentFrontmostAppActivatedAt = activatedAt
    }

    private func recordFrontmostApplicationActivated(named applicationName: String?) {
        guard let applicationName, !applicationName.isEmpty else { return }
        if currentFrontmostAppName == applicationName { return }
        currentFrontmostAppName = applicationName
        currentFrontmostAppActivatedAt = nowProvider()
    }
}
