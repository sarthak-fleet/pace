//
//  PaceCompanionObservationPresenter.swift
//  leanring-buddy
//
//  Pure observation-to-presentation mapping for Always-On Companion Mode.
//  The runtime remains responsible for rendering cards, queueing, and routing
//  spoken output through the existing proactive restraint pipeline.
//

import Foundation

nonisolated struct PaceCompanionPresentationLiveContext: Equatable, Sendable {
    let now: Date
    let profile: PaceProactivityProfile
    let isOnActiveCall: Bool
    let isInFocusMode: Bool
    let hasRecentUserInput: Bool
}

nonisolated enum PaceCompanionPresentationIdentityScope: Equatable, Sendable {
    case notApplicable
    /// Person evidence is presence-only. No identity or ephemeral track label
    /// may be exposed by the presentation layer.
    case nonIdentifyingPerson
}

nonisolated struct PaceCompanionPresentationProvenance: Equatable, Sendable {
    let observationIDs: [UUID]
    let source: PacePerceptionSourceKind
    let observedAt: Date
    let confidence: Double
    let evidenceReference: PaceEvidenceReference?
}

nonisolated struct PaceCompanionPresentationContent: Equatable, Sendable {
    let text: String
    let provenance: PaceCompanionPresentationProvenance
    let identityScope: PaceCompanionPresentationIdentityScope
}

nonisolated enum PaceCompanionPresentationSuppressionReason: Equatable, Sendable {
    case companionModeDisabled
    case sourceDisabled
    case rememberSilently
    case policyDiscarded(String)
}

nonisolated enum PaceCompanionPresentationAction: Equatable, Sendable {
    case none(PaceCompanionPresentationSuppressionReason)
    case card(PaceCompanionPresentationContent)
    case spoken(PaceCompanionPresentationContent)
    case queued(PaceCompanionQueuedPresentation)
    case clarification(PaceCompanionPresentationContent)
}

nonisolated enum PaceCompanionQueuedDelivery: Equatable, Sendable {
    case card
    case spoken
    case clarification
}

nonisolated struct PaceCompanionQueuedPresentation: Equatable, Sendable {
    let delivery: PaceCompanionQueuedDelivery
    let content: PaceCompanionPresentationContent
}

nonisolated struct PaceCompanionObservationPresentation: Equatable, Sendable {
    let candidate: PaceCompanionInterventionCandidate
    let action: PaceCompanionPresentationAction
}

/// Converts accepted structured evidence into a grounded intervention and
/// delegates taste/cooldown decisions to `PaceCompanionInterventionPolicy`.
/// No planner or sensor payload is consulted, so equal inputs produce equal
/// presentation text, scores, and policy outcomes.
nonisolated struct PaceCompanionObservationPresenter {
    private var policy: PaceCompanionInterventionPolicy

    init(policy: PaceCompanionInterventionPolicy = PaceCompanionInterventionPolicy()) {
        self.policy = policy
    }

    mutating func presentation(
        for observation: PaceWorldObservation,
        preferences: PaceCompanionPreferences,
        liveContext: PaceCompanionPresentationLiveContext
    ) -> PaceCompanionObservationPresentation {
        let category = Self.category(for: observation)
        let candidate = Self.candidate(for: observation, category: category)

        guard preferences.isCompanionModeEnabled else {
            return PaceCompanionObservationPresentation(
                candidate: candidate,
                action: .none(.companionModeDisabled)
            )
        }
        guard preferences.enabledSources.contains(observation.source) else {
            return PaceCompanionObservationPresentation(
                candidate: candidate,
                action: .none(.sourceDisabled)
            )
        }

        let decision = policy.decide(
            candidate: candidate,
            context: PaceCompanionInterventionContext(
                now: liveContext.now,
                profile: liveContext.profile,
                isOnActiveCall: liveContext.isOnActiveCall,
                isInFocusMode: liveContext.isInFocusMode,
                hasRecentUserInput: liveContext.hasRecentUserInput,
                areSilentCardsEnabled: preferences.areSilentCardsEnabled,
                areSpokenInterventionsEnabled: preferences.areSpokenInterventionsEnabled
            )
        )
        let groundedContent = Self.content(for: observation, category: category)

        let action: PaceCompanionPresentationAction
        switch decision {
        case .rememberSilently:
            action = .none(.rememberSilently)
        case .showSilently:
            action = .card(groundedContent)
        case .queueUntilIdle:
            action = queuedAction(
                candidate: candidate,
                preferences: preferences,
                liveContext: liveContext,
                groundedContent: groundedContent,
                observation: observation,
                category: category
            )
        case .askClarifyingQuestion:
            action = preferences.areSpokenInterventionsEnabled
                ? .clarification(Self.clarificationContent(
                    for: observation,
                    category: category,
                    provenance: groundedContent.provenance,
                    identityScope: groundedContent.identityScope
                ))
                : .none(.rememberSilently)
        case .speakNow:
            action = .spoken(groundedContent)
        case .discard(let reason):
            action = .none(.policyDiscarded(reason))
        }

        return PaceCompanionObservationPresentation(candidate: candidate, action: action)
    }

    /// The existing policy intentionally queues early when the user is busy,
    /// before it consults output opt-ins. Re-evaluate with only the
    /// transient interruption signals cleared to preserve the delivery the
    /// policy would have chosen once idle. A queued presentation records the
    /// same deduplication/cooldown state as an immediate presentation.
    private mutating func queuedAction(
        candidate: PaceCompanionInterventionCandidate,
        preferences: PaceCompanionPreferences,
        liveContext: PaceCompanionPresentationLiveContext,
        groundedContent: PaceCompanionPresentationContent,
        observation: PaceWorldObservation,
        category: PaceCompanionInterventionCategory
    ) -> PaceCompanionPresentationAction {
        let idleDecision = policy.decide(
            candidate: candidate,
            context: PaceCompanionInterventionContext(
                now: liveContext.now,
                profile: liveContext.profile,
                isOnActiveCall: false,
                isInFocusMode: false,
                hasRecentUserInput: false,
                areSilentCardsEnabled: preferences.areSilentCardsEnabled,
                areSpokenInterventionsEnabled: preferences.areSpokenInterventionsEnabled
            )
        )

        switch idleDecision {
        case .showSilently:
            return .queued(PaceCompanionQueuedPresentation(
                delivery: .card,
                content: groundedContent
            ))
        case .speakNow:
            return .queued(PaceCompanionQueuedPresentation(
                delivery: .spoken,
                content: groundedContent
            ))
        case .askClarifyingQuestion where preferences.areSpokenInterventionsEnabled:
            return .queued(PaceCompanionQueuedPresentation(
                delivery: .clarification,
                content: Self.clarificationContent(
                    for: observation,
                    category: category,
                    provenance: groundedContent.provenance,
                    identityScope: groundedContent.identityScope
                )
            ))
        case .rememberSilently, .discard, .queueUntilIdle, .askClarifyingQuestion:
            return .none(.rememberSilently)
        }
    }

    private static func category(
        for observation: PaceWorldObservation
    ) -> PaceCompanionInterventionCategory {
        switch observation.subject.kind {
        case .personPresence:
            return .personEntry
        case .object where observation.predicate == .isLocatedAt:
            return .objectLastSeen
        case .application, .window, .topic, .environment, .object:
            return .environmentChange
        }
    }

    private static func candidate(
        for observation: PaceWorldObservation,
        category: PaceCompanionInterventionCategory
    ) -> PaceCompanionInterventionCandidate {
        let scores: (
            novelty: Double,
            usefulness: Double,
            urgency: Double,
            reversibility: Double,
            interruptionCost: Double,
            lifetime: TimeInterval
        )
        switch category {
        case .personEntry:
            scores = (0.85, 0.55, 0.35, 1, 0.55, 10 * 60)
        case .objectLastSeen:
            scores = (0.75, 0.85, 0.25, 1, 0.40, 30 * 60)
        case .environmentChange:
            scores = (0.55, 0.45, 0.15, 0.90, 0.65, 15 * 60)
        case .routine:
            scores = (0.65, 0.70, 0.20, 0.90, 0.45, 30 * 60)
        }

        return PaceCompanionInterventionCandidate(
            id: observation.id,
            category: category,
            deduplicationKey: deduplicationKey(for: observation, category: category),
            createdAt: observation.observedAt,
            expiresAt: observation.expiresAt
                ?? observation.observedAt.addingTimeInterval(scores.lifetime),
            novelty: scores.novelty,
            usefulness: scores.usefulness,
            urgency: scores.urgency,
            confidence: observation.confidence,
            reversibility: scores.reversibility,
            interruptionCost: scores.interruptionCost,
            observationIDs: [observation.id]
        )
    }

    private static func content(
        for observation: PaceWorldObservation,
        category: PaceCompanionInterventionCategory
    ) -> PaceCompanionPresentationContent {
        PaceCompanionPresentationContent(
            text: groundedText(for: observation, category: category),
            provenance: provenance(for: observation),
            identityScope: observation.subject.kind == .personPresence
                ? .nonIdentifyingPerson : .notApplicable
        )
    }

    private static func clarificationContent(
        for observation: PaceWorldObservation,
        category: PaceCompanionInterventionCategory,
        provenance: PaceCompanionPresentationProvenance,
        identityScope: PaceCompanionPresentationIdentityScope
    ) -> PaceCompanionPresentationContent {
        let location = observation.location.map { "\(boundedLabel($0.zone))" }
        let text: String
        switch category {
        case .personEntry:
            let locationPhrase = location.map { " near \($0)" } ?? ""
            text = "Did a person \(personAction(for: observation.predicate))\(locationPhrase)? The observation was uncertain."
        case .objectLastSeen:
            let subject = boundedLabel(observation.subject.identifier)
            text = location.map {
                "Is \($0) the last-seen location for \(subject)? The observation was uncertain."
            } ?? "Was \(subject) observed recently? The observation was uncertain."
        case .environmentChange, .routine:
            let locationPhrase = location.map { " in \($0)" } ?? ""
            text = "Did something change\(locationPhrase)? The observation was uncertain."
        }
        return PaceCompanionPresentationContent(
            text: text,
            provenance: provenance,
            identityScope: identityScope
        )
    }

    private static func groundedText(
        for observation: PaceWorldObservation,
        category: PaceCompanionInterventionCategory
    ) -> String {
        let location = observation.location.map { " in \(boundedLabel($0.zone))" } ?? ""
        let time = utcTime(observation.observedAt)
        let isUncertain = observation.confidence < 0.75

        switch category {
        case .personEntry:
            let prefix = isUncertain ? "A camera observation suggests a person" : "A person"
            let personLocation = observation.location.map { " near \(boundedLabel($0.zone))" } ?? ""
            return "\(prefix) \(personAction(for: observation.predicate))\(personLocation) at \(time)."
        case .objectLastSeen:
            let subject = boundedLabel(observation.subject.identifier)
            if isUncertain {
                return "A \(sourceLabel(observation.source)) observation tentatively placed \(subject)\(location) at \(time)."
            }
            return "Last seen: \(subject)\(location) at \(time)."
        case .environmentChange, .routine:
            let context = boundedContextLabel(observation.context)
            return "A change was observed\(location)\(context) at \(time)."
        }
    }

    private static func provenance(
        for observation: PaceWorldObservation
    ) -> PaceCompanionPresentationProvenance {
        PaceCompanionPresentationProvenance(
            observationIDs: [observation.id],
            source: observation.source,
            observedAt: observation.observedAt,
            confidence: observation.confidence,
            evidenceReference: observation.evidenceReference
        )
    }

    private static func deduplicationKey(
        for observation: PaceWorldObservation,
        category: PaceCompanionInterventionCategory
    ) -> String {
        [
            category.rawValue,
            observation.source.rawValue,
            observation.subject.kind.rawValue,
            observation.subject.identifier.lowercased(),
            observation.predicate.rawValue,
            observation.location?.zone.lowercased() ?? "unknown-zone",
        ].joined(separator: ":")
    }

    private static func personAction(for predicate: PaceWorldPredicate) -> String {
        predicate == .exited ? "left" : "entered"
    }

    private static func sourceLabel(_ source: PacePerceptionSourceKind) -> String {
        switch source {
        case .camera: return "camera"
        case .ambientVoice: return "voice"
        case .screen: return "screen"
        case .macOSContext: return "Mac context"
        case .userCorrection: return "user correction"
        }
    }

    private static func boundedLabel(_ label: String) -> String {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(normalized.prefix(64))
    }

    private static func boundedContextLabel(_ context: PaceWorldObservationContext?) -> String {
        guard let applicationName = context?.applicationName,
              applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return ""
        }
        return " while \(boundedLabel(applicationName)) was active"
    }

    private static func utcTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d UTC", components.hour ?? 0, components.minute ?? 0)
    }
}
