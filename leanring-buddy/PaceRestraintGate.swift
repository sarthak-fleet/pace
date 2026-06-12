//
//  PaceRestraintGate.swift
//  leanring-buddy
//
//  Pure policy gate for proactive speech. Callers pass the current
//  context; the gate returns speak, stay quiet, or queue without doing
//  any I/O.
//

import Foundation

nonisolated enum PaceProactiveSource: String, Codable, Equatable, CaseIterable {
    case userPushToTalk
    case wakeWord
    case watchNudge
    case episodicRecall
    case timerFire
    case backgroundReminder
    /// The daily morning brief fired by `PaceMorningTriageScheduler`.
    /// Goes through the full gate (active-call check, proactive
    /// cooldown, intent confidence) so it stays silent during Zoom
    /// or while the user is mid-input.
    case morningTriage
}

nonisolated struct PaceRestraintContext: Equatable {
    let now: Date
    let lastProactiveUtteranceAt: Date?
    let lastEpisodicRecallAt: Date?
    let lastUserInputAt: Date?
    let frontmostAppBundleIdentifier: String?
    let isOnActiveCall: Bool
    let wakeWordConfidence: Double?
    let intent: PaceIntent
    let proactiveSource: PaceProactiveSource
}

nonisolated enum PaceRestraintDecision: Equatable {
    case speak
    case stayQuiet(reason: String)
    case queueUntilIdle(reason: String)
}

nonisolated enum PaceRestraintGate {
    static let activeInputWindowSeconds: TimeInterval = 3
    static let proactiveCooldownSeconds: TimeInterval = 10 * 60
    static let episodicRecallCooldownSeconds: TimeInterval = 30
    static let minimumWakeWordConfidence = 0.7

    private static let activeCallBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.apple.facetime",
        "com.tinyspeck.slackmacgap",
        "com.google.chrome",
        "com.apple.Safari",
    ]

    static func decide(_ context: PaceRestraintContext) -> PaceRestraintDecision {
        switch context.proactiveSource {
        case .userPushToTalk, .timerFire:
            return .speak
        case .wakeWord, .watchNudge, .episodicRecall, .backgroundReminder, .morningTriage:
            break
        }

        if let wakeWordConfidence = context.wakeWordConfidence,
           wakeWordConfidence < minimumWakeWordConfidence {
            return .stayQuiet(reason: "wake word confidence below threshold")
        }

        if context.isOnActiveCall || frontmostAppLooksLikeActiveCall(context.frontmostAppBundleIdentifier) {
            return .stayQuiet(reason: "active call")
        }

        if let lastUserInputAt = context.lastUserInputAt,
           context.now.timeIntervalSince(lastUserInputAt) < activeInputWindowSeconds {
            return .queueUntilIdle(reason: "recent user input")
        }

        if context.proactiveSource == .episodicRecall,
           let lastEpisodicRecallAt = context.lastEpisodicRecallAt,
           context.now.timeIntervalSince(lastEpisodicRecallAt) < episodicRecallCooldownSeconds {
            return .stayQuiet(reason: "episodic recall cooldown")
        }

        if context.proactiveSource != .episodicRecall,
           let lastProactiveUtteranceAt = context.lastProactiveUtteranceAt,
           context.now.timeIntervalSince(lastProactiveUtteranceAt) < proactiveCooldownSeconds {
            return .stayQuiet(reason: "proactive cooldown")
        }

        if context.intent == .unknown {
            return .stayQuiet(reason: "low confidence intent")
        }

        return .speak
    }

    private static func frontmostAppLooksLikeActiveCall(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let normalizedIdentifier = bundleIdentifier.lowercased()
        if activeCallBundleIdentifiers.contains(normalizedIdentifier) {
            return true
        }
        return normalizedIdentifier.contains("zoom")
            || normalizedIdentifier.contains("teams")
            || normalizedIdentifier.contains("facetime")
            || normalizedIdentifier.contains("meet")
            || normalizedIdentifier.contains("huddle")
    }
}
