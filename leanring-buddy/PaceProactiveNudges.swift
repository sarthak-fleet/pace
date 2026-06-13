//
//  PaceProactiveNudges.swift
//  leanring-buddy
//
//  Pure nudge decision helpers. Each decision function now folds the
//  PaceRestraintGate inline so the generator layer cannot accidentally
//  emit a nudge without the gate's active-call / cooldown / recent-input
//  filters applying. Callers receive a `PaceRestraintDecision` plus the
//  optional utterance; on `.queueUntilIdle` the framework parks the
//  utterance for later instead of dropping it.
//

import Foundation

nonisolated struct PaceProactiveUtterance: Equatable {
    let spokenText: String
    let source: PaceProactiveSource
    let confidence: Double
    let relevanceWindowExpiresAt: Date?
}

/// Result of a nudge-decision evaluation. The framework treats this as:
///   - `.speak` + utterance → speak now (after one final gate snapshot)
///   - `.queueUntilIdle` + utterance → park in the proactive queue
///   - `.stayQuiet` (utterance nil) → drop the nudge silently
///   - any decision with `nil` utterance → no nudge to emit this tick
typealias PaceProactiveNudgeEvaluation = (
    decision: PaceRestraintDecision,
    utterance: PaceProactiveUtterance?
)

nonisolated enum PaceFocusFatigueNudgeDecision {
    static func utterance(
        appName: String,
        continuousForegroundSeconds: TimeInterval,
        lastUserInputAt: Date?,
        now: Date
    ) -> PaceProactiveUtterance? {
        guard continuousForegroundSeconds >= 45 * 60 else { return nil }
        guard let lastUserInputAt, now.timeIntervalSince(lastUserInputAt) <= 10 * 60 else { return nil }
        return PaceProactiveUtterance(
            spokenText: "you've been on \(appName) for a while. quick break?",
            source: .watchNudge,
            confidence: 0.74,
            relevanceWindowExpiresAt: now.addingTimeInterval(5 * 60)
        )
    }

    /// Gate-aware variant. Builds the utterance via `utterance(...)`
    /// then runs `PaceRestraintGate.decide(_:)`. Returns the gate's
    /// decision plus the utterance only when the gate permits speech
    /// or wants the utterance queued — `.stayQuiet` returns no
    /// utterance so the framework drops the nudge.
    static func evaluate(
        appName: String,
        continuousForegroundSeconds: TimeInterval,
        restraintContext: PaceRestraintContext
    ) -> PaceProactiveNudgeEvaluation {
        guard let candidateUtterance = utterance(
            appName: appName,
            continuousForegroundSeconds: continuousForegroundSeconds,
            lastUserInputAt: restraintContext.lastUserInputAt,
            now: restraintContext.now
        ) else {
            return (.stayQuiet(reason: "focus fatigue threshold not met"), nil)
        }
        return resolveDecision(
            for: candidateUtterance,
            restraintContext: restraintContext
        )
    }
}

nonisolated enum PaceCalendarPreMeetingNudgeDecision {
    private static let meetingKeywords = ["meeting", "call", "sync", "review", "1:1", "one on one"]

    static func utterance(eventTitle: String, startsInSeconds: TimeInterval, now: Date) -> PaceProactiveUtterance? {
        let normalizedTitle = eventTitle.lowercased()
        guard meetingKeywords.contains(where: normalizedTitle.contains) else { return nil }
        guard startsInSeconds >= 0, startsInSeconds <= 5 * 60 else { return nil }
        let minutes = max(1, Int((startsInSeconds / 60).rounded()))
        return PaceProactiveUtterance(
            spokenText: "\(eventTitle) is in \(minutes) minute\(minutes == 1 ? "" : "s").",
            source: .backgroundReminder,
            confidence: 0.86,
            relevanceWindowExpiresAt: now.addingTimeInterval(startsInSeconds)
        )
    }

    /// Gate-aware variant. See `PaceFocusFatigueNudgeDecision.evaluate`.
    static func evaluate(
        eventTitle: String,
        startsInSeconds: TimeInterval,
        restraintContext: PaceRestraintContext
    ) -> PaceProactiveNudgeEvaluation {
        guard let candidateUtterance = utterance(
            eventTitle: eventTitle,
            startsInSeconds: startsInSeconds,
            now: restraintContext.now
        ) else {
            return (.stayQuiet(reason: "calendar nudge filters did not match"), nil)
        }
        return resolveDecision(
            for: candidateUtterance,
            restraintContext: restraintContext
        )
    }
}

nonisolated enum PaceWatchModeObservationNudgeDecision {
    private static let triggerPhrases = [
        "build failed", "error dialog", "stack trace", "exception", "test failed",
    ]

    static func utterance(screenDescription: String, ocrText: String, now: Date) -> PaceProactiveUtterance? {
        let combinedText = "\(screenDescription) \(ocrText)".lowercased()
        guard triggerPhrases.contains(where: combinedText.contains) else { return nil }
        return PaceProactiveUtterance(
            spokenText: "looks like something failed over there. want me to look at the error?",
            source: .watchNudge,
            confidence: 0.78,
            relevanceWindowExpiresAt: now.addingTimeInterval(10 * 60)
        )
    }

    /// Gate-aware variant. See `PaceFocusFatigueNudgeDecision.evaluate`.
    static func evaluate(
        screenDescription: String,
        ocrText: String,
        restraintContext: PaceRestraintContext
    ) -> PaceProactiveNudgeEvaluation {
        guard let candidateUtterance = utterance(
            screenDescription: screenDescription,
            ocrText: ocrText,
            now: restraintContext.now
        ) else {
            return (.stayQuiet(reason: "watch-mode trigger phrase not present"), nil)
        }
        return resolveDecision(
            for: candidateUtterance,
            restraintContext: restraintContext
        )
    }
}

/// Routes a candidate utterance through `PaceRestraintGate.decide(_:)`
/// and packages the response. Lives at file scope so each decision
/// enum picks up the same gate semantics — a future tightening of the
/// gate cannot accidentally bypass one generator.
private nonisolated func resolveDecision(
    for utterance: PaceProactiveUtterance,
    restraintContext: PaceRestraintContext
) -> PaceProactiveNudgeEvaluation {
    let gateDecision = PaceRestraintGate.decide(restraintContext)
    switch gateDecision {
    case .speak:
        return (.speak, utterance)
    case .queueUntilIdle:
        return (gateDecision, utterance)
    case .stayQuiet:
        return (gateDecision, nil)
    }
}
