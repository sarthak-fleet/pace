import Foundation
import Testing

@testable import Pace

struct PaceCompanionWorldModelTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func objectSubject(_ identifier: String = "keys") throws -> PaceWorldSubject {
        try PaceWorldSubject(kind: .object, identifier: identifier)
    }

    private func observation(
        id: UUID = UUID(),
        observedAt: Date? = nil,
        source: PacePerceptionSourceKind = .camera,
        predicate: PaceWorldPredicate = .isLocatedAt,
        value: PaceWorldValue = .text("keys"),
        zone: String = "desk",
        confidence: Double = 0.9,
        expiresAt: Date? = nil,
        supersedes: [UUID] = []
    ) throws -> PaceWorldObservation {
        try PaceWorldObservation(
            id: id,
            observedAt: observedAt ?? now,
            source: source,
            subject: objectSubject(),
            predicate: predicate,
            value: value,
            location: try PaceWorldLocation(source: source, zone: zone),
            confidence: confidence,
            evidenceReference: try PaceEvidenceReference(type: "frame-fingerprint", identifier: "sha256:abc"),
            expiresAt: expiresAt,
            supersedesObservationIDs: supersedes
        )
    }

    @Test func valueTypesValidateConfidenceExpiryAndNonIdentifyingPresence() throws {
        #expect(throws: PaceWorldObservationValidationError.self) {
            _ = try observation(confidence: 1.01)
        }
        #expect(throws: PaceWorldObservationValidationError.self) {
            _ = try observation(expiresAt: now.addingTimeInterval(-1))
        }
        #expect(throws: PaceWorldObservationValidationError.self) {
            _ = try PaceWorldSubject(kind: .personPresence, identifier: "name: Alice")
        }
        let anonymousPresence = try PaceWorldSubject(kind: .personPresence, identifier: "ephemeral-track-4")
        #expect(anonymousPresence.identifier == "ephemeral-track-4")

        let injectedIdentityJSON = Data(#"{"kind":"personPresence","identifier":"Alice"}"#.utf8)
        #expect(throws: PaceWorldObservationValidationError.self) {
            _ = try JSONDecoder().decode(PaceWorldSubject.self, from: injectedIdentityJSON)
        }
    }

    @Test func valueAndObservationRoundTripPreservesProvenance() throws {
        let original = try observation()
        let decoded = try JSONDecoder().decode(
            PaceWorldObservation.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.evidenceReference?.identifier == "sha256:abc")
    }

    @Test func appendStorePersistsRehydratesAndIgnoresDuplicateIdentifiers() throws {
        let fileURL = temporaryFileURL()
        let original = try observation()
        let store = PaceWorldObservationStore(fileURL: fileURL, now: now)
        try store.append(original, now: now)
        try store.append(original, now: now)

        let rehydrated = PaceWorldObservationStore(fileURL: fileURL, now: now)
        #expect(rehydrated.observations == [original])
        #expect(rehydrated.lastLoadErrorDescription == nil)
    }

    @Test func appendStoreBoundsRetentionAndClearsOnlyRequestedSource() throws {
        let fileURL = temporaryFileURL()
        let configuration = PaceWorldObservationStore.Configuration(
            maximumObservationCount: 2,
            retentionInterval: 100
        )
        let store = PaceWorldObservationStore(fileURL: fileURL, configuration: configuration, now: now)
        try store.append(try observation(observedAt: now.addingTimeInterval(-200)), now: now)
        try store.append(try observation(observedAt: now.addingTimeInterval(-20)), now: now)
        try store.append(try observation(observedAt: now.addingTimeInterval(-10), source: .screen), now: now)
        try store.append(try observation(observedAt: now, source: .macOSContext), now: now)

        #expect(store.observations.count == 2)
        #expect(store.observations.map(\.source) == [.screen, .macOSContext])
        try store.clear(source: .screen)
        #expect(store.observations.map(\.source) == [.macOSContext])
        #expect(PaceWorldObservationStore(fileURL: fileURL, configuration: configuration, now: now).observations.count == 1)
    }

    @Test func corruptPersistenceFailsClosedWithRecoverableEmptyState() throws {
        let fileURL = temporaryFileURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)

        let store = PaceWorldObservationStore(fileURL: fileURL, now: now)
        #expect(store.observations.isEmpty)
        #expect(store.lastLoadErrorDescription != nil)
        try store.append(try observation(), now: now)
        #expect(PaceWorldObservationStore(fileURL: fileURL, now: now).observations.count == 1)
    }

    @Test func newerCorrectionSupersedesOlderLocationWithoutErasingHistory() throws {
        let originalID = UUID()
        let original = try observation(
            id: originalID,
            observedAt: now.addingTimeInterval(-60),
            zone: "door"
        )
        let correction = try observation(
            observedAt: now,
            source: .userCorrection,
            zone: "desk",
            confidence: 1,
            supersedes: [originalID]
        )
        let result = PaceWorldModelStore().lastSeen(
            subject: try objectSubject(),
            observations: [original, correction],
            now: now
        )

        guard case .known(let hypothesis) = result else {
            Issue.record("Expected a known corrected location")
            return
        }
        #expect(hypothesis.location?.zone == "desk")
        #expect(hypothesis.supportingObservationIDs == [correction.id])
        #expect(hypothesis.supersededObservationIDs == [originalID])
        #expect([original, correction].count == 2)
    }

    @Test func contradictionLinksRemainAvailableAndHigherConfidenceWins() throws {
        let door = try observation(observedAt: now.addingTimeInterval(-10), zone: "door", confidence: 0.6)
        let desk = try observation(observedAt: now, zone: "desk", confidence: 0.95)
        let result = PaceWorldModelStore().lastSeen(
            subject: try objectSubject(),
            observations: [door, desk],
            now: now
        )

        guard case .known(let hypothesis) = result else {
            Issue.record("Expected a known location")
            return
        }
        #expect(hypothesis.location?.zone == "desk")
        #expect(hypothesis.contradictingObservationIDs == [door.id])
    }

    @Test func expiredOrDecayedEvidenceReturnsUnknown() throws {
        let expired = try observation(
            observedAt: now.addingTimeInterval(-100),
            expiresAt: now.addingTimeInterval(-1)
        )
        let model = PaceWorldModelStore(minimumReliableConfidence: 0.4, confidenceHalfLife: 10)
        #expect(model.lastSeen(subject: try objectSubject(), observations: [expired], now: now) == .unknown(reason: "no unexpired evidence"))

        let old = try observation(observedAt: now.addingTimeInterval(-100), confidence: 1)
        #expect(model.lastSeen(subject: try objectSubject(), observations: [old], now: now) == .unknown(reason: "evidence confidence decayed below threshold"))
    }

    @Test func changesAndPresenceQueriesAreTypedChronologicalAndBoundedByTime() throws {
        let changeOne = try observation(observedAt: now.addingTimeInterval(-20), predicate: .changed, zone: "screen 1")
        let changeTwo = try observation(observedAt: now.addingTimeInterval(-10), predicate: .changed, zone: "screen 1")
        let outOfRange = try observation(observedAt: now.addingTimeInterval(-200), predicate: .changed, zone: "screen 1")
        let presenceSubject = try PaceWorldSubject(kind: .personPresence, identifier: "ephemeral-track-2")
        let presence = try PaceWorldObservation(
            observedAt: now.addingTimeInterval(-5),
            source: .camera,
            subject: presenceSubject,
            predicate: .entered,
            value: .presence,
            location: try PaceWorldLocation(source: .camera, zone: "door"),
            confidence: 0.8
        )
        let observations = [changeTwo, presence, outOfRange, changeOne]
        let model = PaceWorldModelStore()

        #expect(model.changes(since: now.addingTimeInterval(-30), observations: observations, now: now).observations.map(\.id) == [changeOne.id, changeTwo.id])
        #expect(model.presence(since: now.addingTimeInterval(-30), observations: observations, now: now).observations.map(\.id) == [presence.id])
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-world-model-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("observations.json")
    }
}
