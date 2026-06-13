//
//  PaceWatchModeObservationNudgeGenerator.swift
//  leanring-buddy
//
//  Subscribes to `PaceScreenWatchModeController`'s Combine publisher
//  (an ALREADY-running event source) and asks
//  `PaceWatchModeObservationNudgeDecision.evaluate(...)` whether each
//  major screen change deserves a proactive nudge. NEVER re-screenshots
//  and NEVER re-invokes the VLM — reads the per-screen cached
//  description CompanionManager already maintains.
//
//  Per-generator RAM cost: one Combine cancellable + per-source
//  cooldown bookkeeping. No image buffers held.
//

import Combine
import Foundation

@MainActor
final class PaceWatchModeObservationNudgeGenerator: PaceProactiveNudgeGenerator {
    let identifier = "watch-mode-observation"

    /// One nudge per category-level burst — without a floor, a single
    /// build failure that flickers between sub-screens could fire
    /// every other watch tick. 90 seconds matches the watch journal's
    /// own dedup window so the felt cadence is consistent.
    static let perGeneratorCooldownSeconds: TimeInterval = 90

    private let restraintContextProvider: () -> PaceRestraintContext
    private let watchEventPublisher: AnyPublisher<PaceScreenWatchEvent, Never>
    private let screenDescriptionProvider: (String) -> String?
    private let ocrTextProvider: (String) -> String?
    private let nowProvider: () -> Date

    private var watchEventSubscription: AnyCancellable?
    private var cooldown = PaceProactiveNudgeCooldown(
        minimumIntervalSeconds: PaceWatchModeObservationNudgeGenerator.perGeneratorCooldownSeconds
    )

    init(
        restraintContextProvider: @escaping () -> PaceRestraintContext,
        watchEventPublisher: AnyPublisher<PaceScreenWatchEvent, Never>,
        screenDescriptionProvider: @escaping (String) -> String?,
        ocrTextProvider: @escaping (String) -> String? = { _ in nil },
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.restraintContextProvider = restraintContextProvider
        self.watchEventPublisher = watchEventPublisher
        self.screenDescriptionProvider = screenDescriptionProvider
        self.ocrTextProvider = ocrTextProvider
        self.nowProvider = nowProvider
    }

    func start(
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        guard watchEventSubscription == nil else { return }
        watchEventSubscription = watchEventPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] watchEvent in
                Task { @MainActor [weak self] in
                    self?.handleWatchEvent(
                        watchEvent,
                        emit: emit,
                        queueForLater: queueForLater
                    )
                }
            }
    }

    func stop() {
        watchEventSubscription?.cancel()
        watchEventSubscription = nil
    }

    /// Test seam: drives the same handling path the live subscription
    /// uses. Unit tests inject synthetic watch events without setting
    /// up a real Combine subscription.
    func handleWatchEvent(
        _ watchEvent: PaceScreenWatchEvent,
        emit: (PaceProactiveUtterance) -> Void,
        queueForLater: (PaceProactiveUtterance) -> Void
    ) {
        guard watchEvent.category == .majorScreenChange else { return }

        let now = nowProvider()
        if cooldown.isCoolingDown(now: now) { return }

        let cachedScreenDescription = screenDescriptionProvider(watchEvent.screenLabel) ?? ""
        let cachedOCRText = ocrTextProvider(watchEvent.screenLabel) ?? ""

        let restraintContext = restraintContextProvider()
        let evaluation = PaceWatchModeObservationNudgeDecision.evaluate(
            screenDescription: cachedScreenDescription,
            ocrText: cachedOCRText,
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
}
