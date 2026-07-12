import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceCompanionMemoryPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func promotionIsDeterministicAndOneObservationDoesNotBecomeRoutine() throws {
        let policy = PaceCompanionMemoryPolicy()
        let change = try observation(predicate: .changed, value: .text("window changed"))
        let location = try observation(predicate: .isLocatedAt, zone: "desk")
        let confirmation = try observation(
            source: .userCorrection,
            predicate: .userConfirmed,
            value: .text("keys belong on desk")
        )

        _ = policy.promote(change, now: now)
        _ = policy.promote(location, now: now)
        _ = policy.promote(confirmation, now: now)

        #expect(policy.records.contains { $0.type == .episodic && $0.supportingObservationIDs == [change.id] })
        #expect(policy.records.contains { $0.type == .spatial && $0.supportingObservationIDs == [location.id] })
        #expect(policy.records.contains { $0.type == .semantic && $0.supportingObservationIDs == [confirmation.id] })
        #expect(policy.records.contains { $0.type == .routine } == false)
    }

    @Test func repeatedEvidenceReinforcesConfidenceAndPromotesRoutineAtThreshold() throws {
        let policy = PaceCompanionMemoryPolicy(configuration: .init(
            routineMinimumSupportCount: 3,
            isRoutineLearningEnabled: true
        ))
        let first = try observation(observedAt: now.addingTimeInterval(-200), predicate: .isLocatedAt, zone: "desk", confidence: 0.5)
        let second = try observation(observedAt: now.addingTimeInterval(-100), predicate: .isLocatedAt, zone: "desk", confidence: 0.6)
        let third = try observation(predicate: .isLocatedAt, zone: "desk", confidence: 0.7)
        _ = policy.promote(first, now: now)
        _ = policy.promote(second, now: now)
        _ = policy.promote(third, now: now)

        let spatial = try #require(policy.records.first { $0.type == .spatial })
        let routine = try #require(policy.records.first { $0.type == .routine })
        #expect(spatial.confidence > third.confidence)
        #expect(Set(routine.supportingObservationIDs) == Set([first.id, second.id, third.id]))
    }

    @Test func contradictionWeakensOldSpatialRecordAndLinksEvidence() throws {
        let policy = PaceCompanionMemoryPolicy()
        let desk = try observation(observedAt: now.addingTimeInterval(-10), predicate: .isLocatedAt, zone: "desk")
        let door = try observation(predicate: .isLocatedAt, zone: "door")
        _ = policy.promote(desk, now: now)
        _ = policy.promote(door, now: now)

        let deskRecord = try #require(policy.records.first { $0.type == .spatial && $0.location?.zone == "desk" })
        let doorRecord = try #require(policy.records.first { $0.type == .spatial && $0.location?.zone == "door" })
        #expect(deskRecord.confidence == desk.confidence * 0.5)
        #expect(deskRecord.contradictingObservationIDs == [door.id])
        #expect(doorRecord.contradictingObservationIDs == [desk.id])
    }

    @Test func staleSpatialConfidenceDecaysAndExpiredObservationIsNotPromoted() throws {
        let policy = PaceCompanionMemoryPolicy(configuration: .init(confidenceHalfLife: 10))
        let old = try observation(observedAt: now.addingTimeInterval(-10), predicate: .isLocatedAt, confidence: 0.8)
        let expired = try observation(
            observedAt: now.addingTimeInterval(-10),
            predicate: .changed,
            expiresAt: now.addingTimeInterval(-1)
        )
        _ = policy.promote(old, now: now)
        #expect(policy.promote(expired, now: now).isEmpty)

        let result = try #require(policy.query(.init(types: [.spatial]), now: now).first)
        #expect(abs(result.confidence - 0.4) < 0.001)
    }

    @Test func repetitiveEpisodesCompactWithinBoundWhileKeepingTimeAndProvenance() throws {
        let policy = PaceCompanionMemoryPolicy(configuration: .init(maximumEpisodicRecordCount: 3))
        var observationIDs: [UUID] = []
        for offset in 0..<5 {
            let event = try observation(
                observedAt: now.addingTimeInterval(TimeInterval(offset - 5)),
                predicate: .changed,
                value: .text("small change \(offset)")
            )
            observationIDs.append(event.id)
            _ = policy.promote(event, now: now)
        }
        let episodes = policy.records.filter { $0.type == .episodic }
        #expect(episodes.count <= 3)
        let summaries = episodes.filter(\.isCompactedSummary)
        #expect(summaries.isEmpty == false)
        #expect(Set(summaries.flatMap(\.supportingObservationIDs)).isSubset(of: Set(observationIDs)))
        #expect(summaries.allSatisfy { $0.firstObservedAt <= $0.lastObservedAt })
    }

    @Test func queryFiltersByTimeEntityPlaceAndMemoryType() throws {
        let policy = PaceCompanionMemoryPolicy()
        let desk = try observation(predicate: .isLocatedAt, zone: "desk")
        let otherSubject = try PaceWorldSubject(kind: .object, identifier: "wallet")
        let wallet = try observation(subject: otherSubject, predicate: .isLocatedAt, zone: "door")
        _ = policy.promote(desk, now: now)
        _ = policy.promote(wallet, now: now)

        let result = policy.query(.init(
            timeRange: now.addingTimeInterval(-1)...now.addingTimeInterval(1),
            subject: try PaceWorldSubject(kind: .object, identifier: "keys"),
            location: try PaceWorldLocation(source: .camera, zone: "desk"),
            types: [.spatial]
        ), now: now)
        #expect(result.count == 1)
        #expect(result[0].supportingObservationIDs == [desk.id])
    }

    @Test func documentsCarryCompanionSourceProvenanceAndRemainSearchable() throws {
        let policy = PaceCompanionMemoryPolicy()
        let change = try observation(predicate: .changed, value: .text("monitor turned on"))
        _ = policy.promote(change, now: now)
        let documents = PaceCompanionMemoryDocumentRenderer.documents(from: policy.records)
        let store = PaceInMemoryRetrievalStore()
        store.upsertDocuments(documents)

        #expect(documents.allSatisfy { $0.source == .companionMemory })
        #expect(documents[0].text.contains(change.id.uuidString))
        #expect(store.search(.init(text: "monitor turned on")).first?.source == .companionMemory)
    }

    @Test func clearSourceRemovesEvidenceMemoryDocumentsAndPendingCandidatesTogether() throws {
        let observationStore = PaceWorldObservationStore(fileURL: temporaryFileURL(), now: now)
        let policy = PaceCompanionMemoryPolicy()
        let retrievalStore = PaceInMemoryRetrievalStore()
        var clearedPendingSource: PacePerceptionSourceKind?
        let coordinator = PaceCompanionMemoryCoordinator(
            observationStore: observationStore,
            memoryPolicy: policy,
            retrievalStore: retrievalStore,
            discardPendingCandidates: { clearedPendingSource = $0 }
        )
        try coordinator.accept(try observation(predicate: .changed), now: now)
        #expect(retrievalStore.documents(withSource: .companionMemory).isEmpty == false)

        try coordinator.clear(source: .camera, disableFuturePromotion: true)
        #expect(observationStore.observations.isEmpty)
        #expect(policy.records.isEmpty)
        #expect(policy.disabledPromotionSources.contains(.camera))
        #expect(retrievalStore.documents(withSource: .companionMemory).isEmpty)
        #expect(clearedPendingSource == .camera)
    }

    @Test func coordinatorDeniesSensitiveAppContextAndRedactsTextBeforePersistence() throws {
        let observationStore = PaceWorldObservationStore(fileURL: temporaryFileURL(), now: now)
        let coordinator = PaceCompanionMemoryCoordinator(
            observationStore: observationStore,
            memoryPolicy: PaceCompanionMemoryPolicy(),
            retrievalStore: PaceInMemoryRetrievalStore()
        )
        let sensitive = try observation(
            predicate: .changed,
            value: .text("token=super-secret person@example.com")
        )
        try coordinator.accept(
            sensitive,
            applicationBundleIdentifier: "com.1password.1password",
            now: now
        )
        #expect(observationStore.observations.isEmpty)

        try coordinator.accept(sensitive, applicationBundleIdentifier: "com.apple.TextEdit", now: now)
        let persistedValue = try #require(observationStore.observations.first?.value)
        guard case .text(let persistedText) = persistedValue else {
            Issue.record("Expected redacted text")
            return
        }
        #expect(persistedText.contains("super-secret") == false)
        #expect(persistedText.contains("person@example.com") == false)
    }

    @Test func physicalObservationKeepsOptionalRedactedDesktopContextWithoutActionData() throws {
        let observationStore = PaceWorldObservationStore(fileURL: temporaryFileURL(), now: now)
        let coordinator = PaceCompanionMemoryCoordinator(
            observationStore: observationStore,
            memoryPolicy: PaceCompanionMemoryPolicy(),
            retrievalStore: PaceInMemoryRetrievalStore()
        )
        let physicalObservation = try PaceWorldObservation(
            observedAt: now,
            source: .camera,
            subject: PaceWorldSubject(kind: .object, identifier: "keys"),
            predicate: .isLocatedAt,
            value: .text("keys"),
            location: PaceWorldLocation(source: .camera, zone: "desk"),
            confidence: 0.8,
            context: PaceWorldObservationContext(
                applicationName: "Mail",
                applicationBundleIdentifier: "com.apple.mail",
                windowTitle: "person@example.com — Inbox",
                screenLabel: "display 1"
            )
        )
        try coordinator.accept(
            physicalObservation,
            applicationBundleIdentifier: "com.apple.mail",
            now: now
        )
        let persisted = try #require(observationStore.observations.first)
        #expect(persisted.context?.applicationName == "Mail")
        #expect(persisted.context?.applicationBundleIdentifier == "com.apple.mail")
        #expect(persisted.context?.windowTitle?.contains("person@example.com") == false)
        #expect(persisted.context?.screenLabel == "display 1")
    }

    @Test func retrievalWordingDistinguishesLastSeenUsualStaleAndUnknown() throws {
        let subject = try PaceWorldSubject(kind: .object, identifier: "keys")
        let freshObservation = try observation(predicate: .isLocatedAt, zone: "desk", confidence: 0.9)
        let freshState = PaceWorldModelStore().lastSeen(subject: subject, observations: [freshObservation], now: now)
        #expect(PaceCompanionMemoryDocumentRenderer.lastSeenAnswer(freshState).contains("last observed keys at desk"))

        let staleObservation = try observation(
            observedAt: now.addingTimeInterval(-10),
            predicate: .isLocatedAt,
            zone: "desk",
            confidence: 0.7
        )
        let staleState = PaceWorldModelStore(minimumReliableConfidence: 0.35, confidenceHalfLife: 30)
            .lastSeen(subject: subject, observations: [staleObservation], now: now)
        #expect(PaceCompanionMemoryDocumentRenderer.lastSeenAnswer(staleState).contains("may be stale"))
        #expect(PaceCompanionMemoryDocumentRenderer.lastSeenAnswer(.unknown(reason: "none")).contains("don't have a reliable"))

        let routinePolicy = PaceCompanionMemoryPolicy(configuration: .init(
            routineMinimumSupportCount: 3,
            isRoutineLearningEnabled: true
        ))
        for offset in 0..<3 {
            _ = routinePolicy.promote(try observation(
                observedAt: now.addingTimeInterval(TimeInterval(offset)),
                predicate: .isLocatedAt,
                zone: "desk"
            ), now: now.addingTimeInterval(3))
        }
        #expect(PaceCompanionMemoryDocumentRenderer.usualLocationAnswer(subject: subject, records: routinePolicy.records).contains("usually at desk"))
    }

    private func observation(
        observedAt: Date? = nil,
        source: PacePerceptionSourceKind = .camera,
        subject: PaceWorldSubject? = nil,
        predicate: PaceWorldPredicate,
        value: PaceWorldValue = .text("keys"),
        zone: String = "desk",
        confidence: Double = 0.8,
        expiresAt: Date? = nil
    ) throws -> PaceWorldObservation {
        try PaceWorldObservation(
            observedAt: observedAt ?? now,
            source: source,
            subject: subject ?? PaceWorldSubject(kind: .object, identifier: "keys"),
            predicate: predicate,
            value: value,
            location: try PaceWorldLocation(source: .camera, zone: zone),
            confidence: confidence,
            expiresAt: expiresAt
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-companion-memory-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("observations.json")
    }
}
