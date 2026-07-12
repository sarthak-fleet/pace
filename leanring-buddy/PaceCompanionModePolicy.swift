//
//  PaceCompanionModePolicy.swift
//  leanring-buddy
//
//  Deterministic lifecycle, preferences, and intervention taste for the
//  default-off Always-On Companion Mode. Sensor adapters remain separate.
//

import Foundation

nonisolated enum PaceCompanionDegradedReason: String, Codable, Equatable, Sendable {
    case cameraUnavailable
    case microphoneUnavailable
    case localModelUnavailable
    case batteryBudget
    case memoryBudget
    case analysisBudget
    case thermalPressure
}

nonisolated enum PaceCompanionPrivacyBlockedReason: String, Codable, Equatable, Sendable {
    case cameraPermissionDenied
    case microphonePermissionDenied
    case screenPermissionDenied
    case invalidLocalEndpoint
}

nonisolated enum PaceCompanionRuntimeState: Equatable, Sendable {
    case off
    case starting
    case observing
    case interpreting
    case paused
    case degraded(PaceCompanionDegradedReason)
    case privacyBlocked(PaceCompanionPrivacyBlockedReason)
}

nonisolated enum PaceCompanionModeTransitionError: Error, Equatable {
    case modeIsDisabled
    case invalidTransition(from: PaceCompanionRuntimeState, to: PaceCompanionRuntimeState)
}

nonisolated final class PaceCompanionModeController {
    private(set) var state: PaceCompanionRuntimeState = .off
    private(set) var lastObservationAt: Date?
    private let cancelAllSourceWork: () -> Void
    private let discardQueuedInterventions: () -> Void

    init(
        cancelAllSourceWork: @escaping () -> Void = {},
        discardQueuedInterventions: @escaping () -> Void = {}
    ) {
        self.cancelAllSourceWork = cancelAllSourceWork
        self.discardQueuedInterventions = discardQueuedInterventions
    }

    func start(isEnabled: Bool) throws {
        guard isEnabled else {
            state = .off
            throw PaceCompanionModeTransitionError.modeIsDisabled
        }
        guard state == .off || state == .paused else {
            throw PaceCompanionModeTransitionError.invalidTransition(from: state, to: .starting)
        }
        state = .starting
    }

    func markReady() throws {
        guard state == .starting else {
            throw PaceCompanionModeTransitionError.invalidTransition(from: state, to: .observing)
        }
        state = .observing
    }

    func beginInterpretation() throws {
        guard state == .observing else {
            throw PaceCompanionModeTransitionError.invalidTransition(from: state, to: .interpreting)
        }
        state = .interpreting
    }

    func completeInterpretation(observedAt: Date) throws {
        guard state == .interpreting else {
            throw PaceCompanionModeTransitionError.invalidTransition(from: state, to: .observing)
        }
        lastObservationAt = observedAt
        state = .observing
    }

    func pause() {
        cancelAllSourceWork()
        discardQueuedInterventions()
        state = .paused
    }

    func degrade(_ reason: PaceCompanionDegradedReason) {
        cancelAllSourceWork()
        state = .degraded(reason)
    }

    func blockForPrivacy(_ reason: PaceCompanionPrivacyBlockedReason) {
        cancelAllSourceWork()
        discardQueuedInterventions()
        state = .privacyBlocked(reason)
    }

    func stop() {
        cancelAllSourceWork()
        discardQueuedInterventions()
        state = .off
    }
}

nonisolated struct PaceCompanionPreferences: Equatable, Sendable {
    var isCompanionModeEnabled: Bool
    var enabledSources: Set<PacePerceptionSourceKind>
    var areSilentCardsEnabled: Bool
    var areSpokenInterventionsEnabled: Bool
    var structuredObservationRetentionDays: Int

    static let disabled = PaceCompanionPreferences(
        isCompanionModeEnabled: false,
        enabledSources: [],
        areSilentCardsEnabled: false,
        areSpokenInterventionsEnabled: false,
        structuredObservationRetentionDays: 30
    )
}

nonisolated enum PaceCompanionPreferenceStore {
    private static let modeEnabledKey = "pace.companion.mode.enabled"
    private static let sourceKeyPrefix = "pace.companion.source.enabled."
    private static let silentCardsEnabledKey = "pace.companion.silentCards.enabled"
    private static let spokenInterventionsEnabledKey = "pace.companion.spokenInterventions.enabled"
    private static let retentionDaysKey = "pace.companion.retention.days"

    static func load(userDefaults: UserDefaults = .standard) -> PaceCompanionPreferences {
        let enabledSources = Set(PacePerceptionSourceKind.allCases.filter {
            userDefaults.bool(forKey: sourceKeyPrefix + $0.rawValue)
        })
        let storedRetentionDays = userDefaults.integer(forKey: retentionDaysKey)
        return PaceCompanionPreferences(
            isCompanionModeEnabled: userDefaults.bool(forKey: modeEnabledKey),
            enabledSources: enabledSources,
            areSilentCardsEnabled: userDefaults.bool(forKey: silentCardsEnabledKey),
            areSpokenInterventionsEnabled: userDefaults.bool(forKey: spokenInterventionsEnabledKey),
            structuredObservationRetentionDays: storedRetentionDays > 0 ? storedRetentionDays : 30
        )
    }

    static func save(_ preferences: PaceCompanionPreferences, userDefaults: UserDefaults = .standard) {
        userDefaults.set(preferences.isCompanionModeEnabled, forKey: modeEnabledKey)
        for source in PacePerceptionSourceKind.allCases {
            userDefaults.set(preferences.enabledSources.contains(source), forKey: sourceKeyPrefix + source.rawValue)
        }
        userDefaults.set(preferences.areSilentCardsEnabled, forKey: silentCardsEnabledKey)
        userDefaults.set(preferences.areSpokenInterventionsEnabled, forKey: spokenInterventionsEnabledKey)
        userDefaults.set(max(1, preferences.structuredObservationRetentionDays), forKey: retentionDaysKey)
    }
}

nonisolated enum PaceCompanionInterventionCategory: String, Codable, Equatable, Sendable {
    case personEntry
    case objectLastSeen
    case environmentChange
    case routine
}

nonisolated struct PaceCompanionInterventionCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let category: PaceCompanionInterventionCategory
    let deduplicationKey: String
    let createdAt: Date
    let expiresAt: Date
    let novelty: Double
    let usefulness: Double
    let urgency: Double
    let confidence: Double
    let reversibility: Double
    let interruptionCost: Double
    let observationIDs: [UUID]

    init(
        id: UUID = UUID(),
        category: PaceCompanionInterventionCategory,
        deduplicationKey: String,
        createdAt: Date,
        expiresAt: Date,
        novelty: Double,
        usefulness: Double,
        urgency: Double,
        confidence: Double,
        reversibility: Double,
        interruptionCost: Double,
        observationIDs: [UUID]
    ) {
        self.id = id
        self.category = category
        self.deduplicationKey = deduplicationKey
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.novelty = Self.unitClamped(novelty)
        self.usefulness = Self.unitClamped(usefulness)
        self.urgency = Self.unitClamped(urgency)
        self.confidence = Self.unitClamped(confidence)
        self.reversibility = Self.unitClamped(reversibility)
        self.interruptionCost = Self.unitClamped(interruptionCost)
        self.observationIDs = observationIDs
    }

    var informationValueScore: Double {
        (novelty * 0.20) + (usefulness * 0.25) + (urgency * 0.15)
            + (confidence * 0.25) + (reversibility * 0.05) - (interruptionCost * 0.20)
    }

    private static func unitClamped(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}

nonisolated enum PaceCompanionInterventionDecision: Equatable, Sendable {
    case rememberSilently
    case showSilently
    case queueUntilIdle
    case askClarifyingQuestion
    case speakNow
    case discard(reason: String)
}

nonisolated struct PaceCompanionInterventionContext: Equatable {
    let now: Date
    let profile: PaceProactivityProfile
    let isOnActiveCall: Bool
    let isInFocusMode: Bool
    let hasRecentUserInput: Bool
    let areSilentCardsEnabled: Bool
    let areSpokenInterventionsEnabled: Bool
}

nonisolated struct PaceCompanionInterventionPolicy {
    private(set) var lastGlobalInterventionAt: Date?
    private(set) var lastInterventionAtByCategory: [PaceCompanionInterventionCategory: Date] = [:]
    private(set) var recentDeduplicationKeys: [String: Date] = [:]
    private(set) var negativeFeedbackCountByCategory: [PaceCompanionInterventionCategory: Int] = [:]

    mutating func decide(
        candidate: PaceCompanionInterventionCandidate,
        context: PaceCompanionInterventionContext
    ) -> PaceCompanionInterventionDecision {
        guard candidate.expiresAt > context.now else { return .discard(reason: "expired") }
        guard candidate.confidence >= minimumConfidence(for: candidate.category) else {
            return .discard(reason: "low confidence")
        }
        if let duplicateDate = recentDeduplicationKeys[candidate.deduplicationKey],
           context.now.timeIntervalSince(duplicateDate) < 30 * 60 {
            return .rememberSilently
        }

        let decision: PaceCompanionInterventionDecision
        if candidate.confidence < 0.65, candidate.usefulness >= 0.7 {
            decision = context.isOnActiveCall || context.isInFocusMode || context.hasRecentUserInput
                ? .queueUntilIdle : .askClarifyingQuestion
        } else if candidate.informationValueScore < 0.45 {
            decision = .rememberSilently
        } else if context.isOnActiveCall || context.isInFocusMode || context.hasRecentUserInput {
            decision = .queueUntilIdle
        } else if isWithinCooldown(candidate: candidate, context: context) {
            decision = .rememberSilently
        } else if context.areSpokenInterventionsEnabled,
                  candidate.informationValueScore >= speechThreshold(for: context.profile) {
            decision = .speakNow
        } else if context.areSilentCardsEnabled, candidate.informationValueScore >= 0.5 {
            decision = .showSilently
        } else {
            decision = .rememberSilently
        }

        if decision == .showSilently || decision == .askClarifyingQuestion || decision == .speakNow {
            lastGlobalInterventionAt = context.now
            lastInterventionAtByCategory[candidate.category] = context.now
            recentDeduplicationKeys[candidate.deduplicationKey] = context.now
        }
        recentDeduplicationKeys = recentDeduplicationKeys.filter {
            context.now.timeIntervalSince($0.value) < 30 * 60
        }
        return decision
    }

    mutating func recordNegativeFeedback(for category: PaceCompanionInterventionCategory) {
        negativeFeedbackCountByCategory[category, default: 0] += 1
    }

    mutating func clearPendingState(for category: PaceCompanionInterventionCategory) {
        lastInterventionAtByCategory[category] = nil
        negativeFeedbackCountByCategory[category] = nil
    }

    private func minimumConfidence(for category: PaceCompanionInterventionCategory) -> Double {
        min(0.9, 0.45 + Double(negativeFeedbackCountByCategory[category, default: 0]) * 0.1)
    }

    private func speechThreshold(for profile: PaceProactivityProfile) -> Double {
        switch profile {
        case .talkative: return 0.5
        case .balanced: return 0.65
        case .reserved: return 0.8
        }
    }

    private func isWithinCooldown(
        candidate: PaceCompanionInterventionCandidate,
        context: PaceCompanionInterventionContext
    ) -> Bool {
        let globalCooldown: TimeInterval = context.profile == .talkative ? 5 * 60 : 10 * 60
        let categoryCooldown: TimeInterval = context.profile == .reserved ? 60 * 60 : 30 * 60
        if let lastGlobalInterventionAt,
           context.now.timeIntervalSince(lastGlobalInterventionAt) < globalCooldown {
            return true
        }
        if let lastCategoryInterventionAt = lastInterventionAtByCategory[candidate.category],
           context.now.timeIntervalSince(lastCategoryInterventionAt) < categoryCooldown {
            return true
        }
        return false
    }
}
