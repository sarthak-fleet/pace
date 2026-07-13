import Foundation
import Testing

@testable import Pace

struct PaceCompanionObservationPresenterTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let observationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test func defaultOffAndDisabledSourceNeverPresent() throws {
        let observation = try objectObservation()
        var presenter = PaceCompanionObservationPresenter()

        let modeOff = presenter.presentation(
            for: observation,
            preferences: .disabled,
            liveContext: context()
        )
        #expect(modeOff.action == .none(.companionModeDisabled))

        let sourceOff = presenter.presentation(
            for: observation,
            preferences: preferences(enabledSources: []),
            liveContext: context()
        )
        #expect(sourceOff.action == .none(.sourceDisabled))
    }

    @Test func objectCardIsGroundedAndRetainsProvenance() throws {
        let evidence = try PaceEvidenceReference(type: "camera-track", identifier: "track-7")
        let observation = try objectObservation(evidenceReference: evidence)
        var presenter = PaceCompanionObservationPresenter()

        let result = presenter.presentation(
            for: observation,
            preferences: preferences(cards: true),
            liveContext: context(profile: .reserved)
        )

        let content = try #require(cardContent(from: result.action))
        #expect(content.text == "Last seen: keys in desk at 03:33 UTC.")
        #expect(content.provenance.observationIDs == [observationID])
        #expect(content.provenance.source == .camera)
        #expect(content.provenance.observedAt == now)
        #expect(content.provenance.confidence == 0.95)
        #expect(content.provenance.evidenceReference == evidence)
        #expect(content.identityScope == .notApplicable)
        #expect(result.candidate.observationIDs == [observationID])
        #expect(result.candidate.category == .objectLastSeen)
    }

    @Test func personPresentationNeverExposesTrackIdentity() throws {
        let observation = try PaceWorldObservation(
            id: observationID,
            observedAt: now,
            source: .camera,
            subject: PaceWorldSubject(kind: .personPresence, identifier: "ephemeral-track-secret-42"),
            predicate: .entered,
            value: .presence,
            location: PaceWorldLocation(source: .camera, zone: "door"),
            confidence: 0.95,
            expiresAt: now.addingTimeInterval(300)
        )
        var presenter = PaceCompanionObservationPresenter()

        let result = presenter.presentation(
            for: observation,
            preferences: preferences(spoken: true),
            liveContext: context(profile: .talkative)
        )

        let content = try #require(spokenContent(from: result.action))
        #expect(content.text == "A person entered near door at 03:33 UTC.")
        #expect(content.text.contains("secret") == false)
        #expect(content.text.contains("track") == false)
        #expect(content.identityScope == .nonIdentifyingPerson)
    }

    @Test func activeCallQueuesCardOnlyAsCard() throws {
        var presenter = PaceCompanionObservationPresenter()
        let result = presenter.presentation(
            for: try objectObservation(),
            preferences: preferences(cards: true),
            liveContext: context(profile: .reserved, isOnActiveCall: true)
        )

        let queued = try #require(queuedPresentation(from: result.action))
        #expect(queued.delivery == .card)
        #expect(queued.content.provenance.observationIDs == [observationID])
    }

    @Test func activeCallQueuesSpeechOnlyAsSpeech() throws {
        var presenter = PaceCompanionObservationPresenter()
        let result = presenter.presentation(
            for: try objectObservation(),
            preferences: preferences(spoken: true),
            liveContext: context(profile: .talkative, isOnActiveCall: true)
        )

        let queued = try #require(queuedPresentation(from: result.action))
        #expect(queued.delivery == .spoken)
    }

    @Test func queuedPresentationStillDeduplicatesRepeatedEvidence() throws {
        let observation = try objectObservation()
        var presenter = PaceCompanionObservationPresenter()
        let first = presenter.presentation(
            for: observation,
            preferences: preferences(cards: true),
            liveContext: context(profile: .reserved, isOnActiveCall: true)
        )
        #expect(queuedPresentation(from: first.action)?.delivery == .card)

        let repeated = presenter.presentation(
            for: observation,
            preferences: preferences(cards: true),
            liveContext: context(
                now: now.addingTimeInterval(1),
                profile: .reserved,
                isOnActiveCall: true
            )
        )
        #expect(repeated.action == .none(.rememberSilently))
    }

    @Test func activeCallWithNoOutputOptInRemainsSilent() throws {
        var presenter = PaceCompanionObservationPresenter()
        let result = presenter.presentation(
            for: try objectObservation(),
            preferences: preferences(),
            liveContext: context(isOnActiveCall: true)
        )

        #expect(result.action == .none(.rememberSilently))
    }

    @Test func uncertainUsefulObjectAsksGroundedClarification() throws {
        var presenter = PaceCompanionObservationPresenter()
        let result = presenter.presentation(
            for: try objectObservation(confidence: 0.6),
            preferences: preferences(spoken: true),
            liveContext: context()
        )

        let content = try #require(clarificationContent(from: result.action))
        #expect(content.text == "Is desk the last-seen location for keys? The observation was uncertain.")
        #expect(content.provenance.confidence == 0.6)
    }

    @Test func outputPreferencesRemainIndependentAndDeduplicateRepeatedEvidence() throws {
        let observation = try objectObservation()
        var presenter = PaceCompanionObservationPresenter()

        let noOutputs = presenter.presentation(
            for: observation,
            preferences: preferences(),
            liveContext: context()
        )
        #expect(noOutputs.action == .none(.rememberSilently))

        let firstCard = presenter.presentation(
            for: observation,
            preferences: preferences(cards: true),
            liveContext: context(now: now.addingTimeInterval(601), profile: .reserved)
        )
        #expect(cardContent(from: firstCard.action) != nil)

        let repeated = presenter.presentation(
            for: observation,
            preferences: preferences(cards: true),
            liveContext: context(now: now.addingTimeInterval(602), profile: .reserved)
        )
        #expect(repeated.action == .none(.rememberSilently))
    }

    private func objectObservation(
        confidence: Double = 0.95,
        evidenceReference: PaceEvidenceReference? = nil
    ) throws -> PaceWorldObservation {
        try PaceWorldObservation(
            id: observationID,
            observedAt: now,
            source: .camera,
            subject: PaceWorldSubject(kind: .object, identifier: "keys"),
            predicate: .isLocatedAt,
            value: .text("desk"),
            location: PaceWorldLocation(source: .camera, zone: "desk"),
            confidence: confidence,
            evidenceReference: evidenceReference,
            expiresAt: now.addingTimeInterval(1_800)
        )
    }

    private func preferences(
        enabledSources: Set<PacePerceptionSourceKind> = [.camera],
        cards: Bool = false,
        spoken: Bool = false
    ) -> PaceCompanionPreferences {
        PaceCompanionPreferences(
            isCompanionModeEnabled: true,
            enabledSources: enabledSources,
            areSilentCardsEnabled: cards,
            areSpokenInterventionsEnabled: spoken,
            structuredObservationRetentionDays: 30
        )
    }

    private func context(
        now: Date? = nil,
        profile: PaceProactivityProfile = .balanced,
        isOnActiveCall: Bool = false
    ) -> PaceCompanionPresentationLiveContext {
        PaceCompanionPresentationLiveContext(
            now: now ?? self.now,
            profile: profile,
            isOnActiveCall: isOnActiveCall,
            isInFocusMode: false,
            hasRecentUserInput: false
        )
    }

    private func cardContent(
        from action: PaceCompanionPresentationAction
    ) -> PaceCompanionPresentationContent? {
        guard case .card(let content) = action else { return nil }
        return content
    }

    private func spokenContent(
        from action: PaceCompanionPresentationAction
    ) -> PaceCompanionPresentationContent? {
        guard case .spoken(let content) = action else { return nil }
        return content
    }

    private func queuedPresentation(
        from action: PaceCompanionPresentationAction
    ) -> PaceCompanionQueuedPresentation? {
        guard case .queued(let presentation) = action else { return nil }
        return presentation
    }

    private func clarificationContent(
        from action: PaceCompanionPresentationAction
    ) -> PaceCompanionPresentationContent? {
        guard case .clarification(let content) = action else { return nil }
        return content
    }
}
