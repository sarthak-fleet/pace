import Foundation
import Testing

@testable import Pace

struct PaceCompanionModePolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func existingInstallWithoutKeysRemainsFullyOptedOut() throws {
        let suiteName = "PaceCompanionModePolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let preferences = PaceCompanionPreferenceStore.load(userDefaults: defaults)
        #expect(preferences == .disabled)
    }

    @Test func sourceAndOutputOptInsPersistIndependently() throws {
        let suiteName = "PaceCompanionModePolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let preferences = PaceCompanionPreferences(
            isCompanionModeEnabled: true,
            enabledSources: [.camera],
            areSilentCardsEnabled: true,
            areSpokenInterventionsEnabled: false,
            structuredObservationRetentionDays: 14
        )
        PaceCompanionPreferenceStore.save(preferences, userDefaults: defaults)
        #expect(PaceCompanionPreferenceStore.load(userDefaults: defaults) == preferences)
        #expect(PaceCompanionPreferenceStore.load(userDefaults: defaults).enabledSources.contains(.ambientVoice) == false)
    }

    @Test func lifecycleTransitionsAreDeterministicAndPauseCancelsEverything() throws {
        var cancelCount = 0
        var discardCount = 0
        let controller = PaceCompanionModeController(
            cancelAllSourceWork: { cancelCount += 1 },
            discardQueuedInterventions: { discardCount += 1 }
        )

        #expect(throws: PaceCompanionModeTransitionError.self) {
            try controller.start(isEnabled: false)
        }
        try controller.start(isEnabled: true)
        #expect(controller.state == .starting)
        try controller.markReady()
        try controller.beginInterpretation()
        try controller.completeInterpretation(observedAt: now)
        #expect(controller.state == .observing)
        #expect(controller.lastObservationAt == now)

        controller.pause()
        #expect(controller.state == .paused)
        #expect(cancelCount == 1)
        #expect(discardCount == 1)
    }

    @Test func privacyBlockAndDegradationExposeTypedReasons() {
        let controller = PaceCompanionModeController()
        controller.degrade(.thermalPressure)
        #expect(controller.state == .degraded(.thermalPressure))
        controller.blockForPrivacy(.cameraPermissionDenied)
        #expect(controller.state == .privacyBlocked(.cameraPermissionDenied))
    }

    @Test func lowValueDefaultsToRememberingSilently() {
        var policy = PaceCompanionInterventionPolicy()
        let decision = policy.decide(
            candidate: candidate(usefulness: 0.2, urgency: 0, confidence: 0.7),
            context: context()
        )
        #expect(decision == .rememberSilently)
    }

    @Test func activeCallFocusAndRecentInputQueueUsefulCandidate() {
        for blockingContext in [
            context(isOnActiveCall: true),
            context(isInFocusMode: true),
            context(hasRecentUserInput: true),
        ] {
            var policy = PaceCompanionInterventionPolicy()
            #expect(policy.decide(candidate: candidate(), context: blockingContext) == .queueUntilIdle)
        }
    }

    @Test func expiredAndLowConfidenceCandidatesAreDiscarded() {
        var policy = PaceCompanionInterventionPolicy()
        #expect(policy.decide(
            candidate: candidate(expiresAt: now.addingTimeInterval(-1)),
            context: context()
        ) == .discard(reason: "expired"))
        #expect(policy.decide(
            candidate: candidate(confidence: 0.2),
            context: context()
        ) == .discard(reason: "low confidence"))
    }

    @Test func profilesCardsSpeechCooldownsAndDuplicateCoalescingRemainSeparate() {
        var policy = PaceCompanionInterventionPolicy()
        let speakCandidate = candidate(deduplicationKey: "door-person")
        #expect(policy.decide(
            candidate: speakCandidate,
            context: context(profile: .talkative, areSpokenInterventionsEnabled: true)
        ) == .speakNow)

        let repeated = candidate(deduplicationKey: "door-person")
        #expect(policy.decide(
            candidate: repeated,
            context: context(now: now.addingTimeInterval(20), profile: .talkative, areSpokenInterventionsEnabled: true)
        ) == .rememberSilently)

        var cardPolicy = PaceCompanionInterventionPolicy()
        #expect(cardPolicy.decide(
            candidate: candidate(),
            context: context(profile: .reserved, areSilentCardsEnabled: true)
        ) == .showSilently)
    }

    @Test func negativeFeedbackRaisesCategoryConfidenceThreshold() {
        var policy = PaceCompanionInterventionPolicy()
        policy.recordNegativeFeedback(for: .personEntry)
        policy.recordNegativeFeedback(for: .personEntry)
        policy.recordNegativeFeedback(for: .personEntry)
        #expect(policy.decide(
            candidate: candidate(confidence: 0.7),
            context: context()
        ) == .discard(reason: "low confidence"))
    }

    @Test func companionProactiveSourceUsesActiveCallFocusInputAndCooldownRestraint() {
        func decision(
            isOnActiveCall: Bool = false,
            isInFocusMode: Bool = false,
            lastUserInputAt: Date? = nil,
            lastProactiveUtteranceAt: Date? = nil
        ) -> PaceRestraintDecision {
            PaceRestraintGate.decide(PaceRestraintContext(
                now: now,
                lastProactiveUtteranceAt: lastProactiveUtteranceAt,
                lastEpisodicRecallAt: nil,
                lastUserInputAt: lastUserInputAt,
                frontmostAppBundleIdentifier: nil,
                isOnActiveCall: isOnActiveCall,
                wakeWordConfidence: nil,
                intent: .pureKnowledge,
                proactiveSource: .companionEvent,
                profile: .balanced,
                isInUserFocusMode: isInFocusMode
            ))
        }

        #expect(decision(isOnActiveCall: true) == .queueUntilIdle(reason: "active call"))
        #expect(decision(isInFocusMode: true) == .queueUntilIdle(reason: "macOS Focus active"))
        #expect(decision(lastUserInputAt: now.addingTimeInterval(-1)) == .queueUntilIdle(reason: "recent user input"))
        #expect(decision(lastProactiveUtteranceAt: now.addingTimeInterval(-1)) == .stayQuiet(reason: "proactive cooldown"))
        #expect(decision() == .speak)
    }

    private func candidate(
        deduplicationKey: String = UUID().uuidString,
        expiresAt: Date? = nil,
        usefulness: Double = 1,
        urgency: Double = 0.8,
        confidence: Double = 0.95
    ) -> PaceCompanionInterventionCandidate {
        PaceCompanionInterventionCandidate(
            category: .personEntry,
            deduplicationKey: deduplicationKey,
            createdAt: now,
            expiresAt: expiresAt ?? now.addingTimeInterval(300),
            novelty: 1,
            usefulness: usefulness,
            urgency: urgency,
            confidence: confidence,
            reversibility: 1,
            interruptionCost: 0.1,
            observationIDs: [UUID()]
        )
    }

    private func context(
        now: Date? = nil,
        profile: PaceProactivityProfile = .balanced,
        isOnActiveCall: Bool = false,
        isInFocusMode: Bool = false,
        hasRecentUserInput: Bool = false,
        areSilentCardsEnabled: Bool = false,
        areSpokenInterventionsEnabled: Bool = false
    ) -> PaceCompanionInterventionContext {
        PaceCompanionInterventionContext(
            now: now ?? self.now,
            profile: profile,
            isOnActiveCall: isOnActiveCall,
            isInFocusMode: isInFocusMode,
            hasRecentUserInput: hasRecentUserInput,
            areSilentCardsEnabled: areSilentCardsEnabled,
            areSpokenInterventionsEnabled: areSpokenInterventionsEnabled
        )
    }
}
