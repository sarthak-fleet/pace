//
//  PaceCompanionMemoryPolicy.swift
//  leanring-buddy
//
//  Deterministic promotion and retrieval policy for structured companion
//  evidence. The planner cannot promote memories directly.
//

import Foundation

nonisolated enum PaceCompanionMemoryType: String, Codable, CaseIterable, Sendable {
    case episodic
    case semantic
    case spatial
    case routine
}

nonisolated struct PaceCompanionMemoryRecord: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let type: PaceCompanionMemoryType
    let subject: PaceWorldSubject
    let predicate: PaceWorldPredicate
    var value: PaceWorldValue
    var location: PaceWorldLocation?
    var confidence: Double
    var firstObservedAt: Date
    var lastObservedAt: Date
    var supportingObservationIDs: [UUID]
    var contradictingObservationIDs: [UUID]
    var sourceKinds: Set<PacePerceptionSourceKind>
    var isCompactedSummary: Bool
    var expiresAt: Date?
}

nonisolated struct PaceCompanionMemoryQuery: Equatable, Sendable {
    let timeRange: ClosedRange<Date>?
    let subject: PaceWorldSubject?
    let location: PaceWorldLocation?
    let types: Set<PaceCompanionMemoryType>

    init(
        timeRange: ClosedRange<Date>? = nil,
        subject: PaceWorldSubject? = nil,
        location: PaceWorldLocation? = nil,
        types: Set<PaceCompanionMemoryType> = Set(PaceCompanionMemoryType.allCases)
    ) {
        self.timeRange = timeRange
        self.subject = subject
        self.location = location
        self.types = types
    }
}

nonisolated struct PaceCompanionMemoryPolicyConfiguration: Equatable, Sendable {
    let maximumEpisodicRecordCount: Int
    let routineMinimumSupportCount: Int
    let confidenceHalfLife: TimeInterval
    let isRoutineLearningEnabled: Bool

    init(
        maximumEpisodicRecordCount: Int = 200,
        routineMinimumSupportCount: Int = 3,
        confidenceHalfLife: TimeInterval = 14 * 86_400,
        isRoutineLearningEnabled: Bool = false
    ) {
        self.maximumEpisodicRecordCount = max(2, maximumEpisodicRecordCount)
        self.routineMinimumSupportCount = max(2, routineMinimumSupportCount)
        self.confidenceHalfLife = max(1, confidenceHalfLife)
        self.isRoutineLearningEnabled = isRoutineLearningEnabled
    }
}

nonisolated final class PaceCompanionMemoryPolicy {
    private(set) var records: [PaceCompanionMemoryRecord]
    private(set) var disabledPromotionSources: Set<PacePerceptionSourceKind>
    let configuration: PaceCompanionMemoryPolicyConfiguration

    init(
        records: [PaceCompanionMemoryRecord] = [],
        disabledPromotionSources: Set<PacePerceptionSourceKind> = [],
        configuration: PaceCompanionMemoryPolicyConfiguration = PaceCompanionMemoryPolicyConfiguration()
    ) {
        self.records = records
        self.disabledPromotionSources = disabledPromotionSources
        self.configuration = configuration
    }

    @discardableResult
    func promote(
        _ observation: PaceWorldObservation,
        now: Date = Date()
    ) -> [PaceCompanionMemoryRecord] {
        guard disabledPromotionSources.contains(observation.source) == false,
              observation.isExpired(at: now) == false else {
            return []
        }

        var changedRecords: [PaceCompanionMemoryRecord] = []
        if shouldPromoteEpisodically(observation) {
            changedRecords.append(insertEpisode(observation))
        }
        if observation.source == .userCorrection || observation.predicate == .userConfirmed {
            changedRecords.append(upsertDurableRecord(type: .semantic, observation: observation))
        }
        if observation.subject.kind == .object, observation.predicate == .isLocatedAt {
            changedRecords.append(upsertSpatialRecord(observation))
        }
        if configuration.isRoutineLearningEnabled,
           let routineRecord = promoteRoutineIfSupported(observation) {
            changedRecords.append(routineRecord)
        }
        compactLowValueEpisodesIfNeeded()
        return changedRecords
    }

    func query(_ query: PaceCompanionMemoryQuery, now: Date = Date()) -> [PaceCompanionMemoryRecord] {
        records
            .filter { record in
                guard query.types.contains(record.type) else { return false }
                guard record.expiresAt.map({ $0 > now }) ?? true else { return false }
                guard query.subject.map({ $0 == record.subject }) ?? true else { return false }
                guard query.location.map({ $0 == record.location }) ?? true else { return false }
                guard query.timeRange.map({ $0.overlaps(record.firstObservedAt...record.lastObservedAt) }) ?? true else {
                    return false
                }
                return true
            }
            .map { record in
                var decayedRecord = record
                if record.type == .spatial || record.type == .routine {
                    decayedRecord.confidence = effectiveConfidence(for: record, now: now)
                }
                return decayedRecord
            }
            .sorted { $0.lastObservedAt < $1.lastObservedAt }
    }

    func forget(subject: PaceWorldSubject) {
        records.removeAll { $0.subject == subject }
    }

    func clear(type: PaceCompanionMemoryType) {
        records.removeAll { $0.type == type }
    }

    func clear(source: PacePerceptionSourceKind, disableFuturePromotion: Bool) {
        records.removeAll { $0.sourceKinds.contains(source) }
        if disableFuturePromotion {
            disabledPromotionSources.insert(source)
        }
    }

    func clearAll() {
        records.removeAll()
    }

    func setPromotionEnabled(_ isEnabled: Bool, for source: PacePerceptionSourceKind) {
        if isEnabled {
            disabledPromotionSources.remove(source)
        } else {
            disabledPromotionSources.insert(source)
        }
    }

    private func shouldPromoteEpisodically(_ observation: PaceWorldObservation) -> Bool {
        switch observation.predicate {
        case .entered, .exited, .changed:
            return true
        case .isLocatedAt, .isActive, .says, .userConfirmed:
            return false
        }
    }

    private func insertEpisode(_ observation: PaceWorldObservation) -> PaceCompanionMemoryRecord {
        let record = PaceCompanionMemoryRecord(
            id: UUID(),
            type: .episodic,
            subject: observation.subject,
            predicate: observation.predicate,
            value: observation.value,
            location: observation.location,
            confidence: observation.confidence,
            firstObservedAt: observation.observedAt,
            lastObservedAt: observation.observedAt,
            supportingObservationIDs: [observation.id],
            contradictingObservationIDs: [],
            sourceKinds: [observation.source],
            isCompactedSummary: false,
            expiresAt: observation.expiresAt
        )
        records.append(record)
        return record
    }

    private func upsertDurableRecord(
        type: PaceCompanionMemoryType,
        observation: PaceWorldObservation
    ) -> PaceCompanionMemoryRecord {
        if let existingIndex = records.firstIndex(where: {
            $0.type == type && $0.subject == observation.subject && $0.predicate == observation.predicate
        }) {
            reinforceRecord(at: existingIndex, with: observation)
            return records[existingIndex]
        }
        let record = record(type: type, observation: observation)
        records.append(record)
        return record
    }

    private func upsertSpatialRecord(_ observation: PaceWorldObservation) -> PaceCompanionMemoryRecord {
        let matchingIndex = records.firstIndex(where: {
            $0.type == .spatial && $0.subject == observation.subject && $0.location == observation.location
        })
        let contradictingIndexes = records.indices.filter {
            records[$0].type == .spatial
                && records[$0].subject == observation.subject
                && records[$0].location != observation.location
        }
        for contradictingIndex in contradictingIndexes {
            records[contradictingIndex].confidence *= 0.5
            if records[contradictingIndex].contradictingObservationIDs.contains(observation.id) == false {
                records[contradictingIndex].contradictingObservationIDs.append(observation.id)
            }
        }
        if let matchingIndex {
            reinforceRecord(at: matchingIndex, with: observation)
            return records[matchingIndex]
        }
        var newRecord = record(type: .spatial, observation: observation)
        newRecord.contradictingObservationIDs = contradictingIndexes.flatMap {
            records[$0].supportingObservationIDs
        }
        records.append(newRecord)
        return newRecord
    }

    private func promoteRoutineIfSupported(
        _ observation: PaceWorldObservation
    ) -> PaceCompanionMemoryRecord? {
        guard observation.predicate == .isLocatedAt || observation.predicate == .changed else { return nil }
        let matchingObservationIDs = records
            .filter {
                ($0.type == .episodic || $0.type == .spatial)
                    && $0.subject == observation.subject
                    && $0.predicate == observation.predicate
                    && $0.value == observation.value
                    && $0.location == observation.location
            }
            .flatMap(\.supportingObservationIDs)
        let uniqueObservationIDs = Array(Set(matchingObservationIDs + [observation.id]))
        guard uniqueObservationIDs.count >= configuration.routineMinimumSupportCount else { return nil }

        if let routineIndex = records.firstIndex(where: {
            $0.type == .routine && $0.subject == observation.subject
                && $0.predicate == observation.predicate && $0.location == observation.location
        }) {
            reinforceRecord(at: routineIndex, with: observation)
            records[routineIndex].supportingObservationIDs = uniqueObservationIDs
            return records[routineIndex]
        }
        var routineRecord = record(type: .routine, observation: observation)
        routineRecord.supportingObservationIDs = uniqueObservationIDs
        records.append(routineRecord)
        return routineRecord
    }

    private func reinforceRecord(at index: Int, with observation: PaceWorldObservation) {
        let oldConfidence = records[index].confidence
        records[index].confidence = 1 - ((1 - oldConfidence) * (1 - observation.confidence))
        records[index].lastObservedAt = max(records[index].lastObservedAt, observation.observedAt)
        records[index].value = observation.value
        records[index].location = observation.location
        records[index].sourceKinds.insert(observation.source)
        if records[index].supportingObservationIDs.contains(observation.id) == false {
            records[index].supportingObservationIDs.append(observation.id)
        }
        records[index].expiresAt = observation.expiresAt
    }

    private func compactLowValueEpisodesIfNeeded() {
        var episodeIndexes = records.indices.filter { records[$0].type == .episodic }
        while episodeIndexes.count > configuration.maximumEpisodicRecordCount {
            let oldestIndexes = Array(episodeIndexes.prefix(2))
            let oldestRecords = oldestIndexes.map { records[$0] }
            let summary = PaceCompanionMemoryRecord(
                id: UUID(),
                type: .episodic,
                subject: oldestRecords[0].subject,
                predicate: .changed,
                value: .text("\(oldestRecords.count) compacted low-value episodes"),
                location: nil,
                confidence: oldestRecords.map(\.confidence).reduce(0, +) / Double(oldestRecords.count),
                firstObservedAt: oldestRecords.map(\.firstObservedAt).min() ?? oldestRecords[0].firstObservedAt,
                lastObservedAt: oldestRecords.map(\.lastObservedAt).max() ?? oldestRecords[0].lastObservedAt,
                supportingObservationIDs: oldestRecords.flatMap(\.supportingObservationIDs),
                contradictingObservationIDs: oldestRecords.flatMap(\.contradictingObservationIDs),
                sourceKinds: Set(oldestRecords.flatMap(\.sourceKinds)),
                isCompactedSummary: true,
                expiresAt: oldestRecords.compactMap(\.expiresAt).max()
            )
            for index in oldestIndexes.sorted(by: >) {
                records.remove(at: index)
            }
            records.append(summary)
            records.sort { $0.lastObservedAt < $1.lastObservedAt }
            episodeIndexes = records.indices.filter { records[$0].type == .episodic }
        }
    }

    private func record(
        type: PaceCompanionMemoryType,
        observation: PaceWorldObservation
    ) -> PaceCompanionMemoryRecord {
        PaceCompanionMemoryRecord(
            id: UUID(),
            type: type,
            subject: observation.subject,
            predicate: observation.predicate,
            value: observation.value,
            location: observation.location,
            confidence: observation.confidence,
            firstObservedAt: observation.observedAt,
            lastObservedAt: observation.observedAt,
            supportingObservationIDs: [observation.id],
            contradictingObservationIDs: [],
            sourceKinds: [observation.source],
            isCompactedSummary: false,
            expiresAt: observation.expiresAt
        )
    }

    private func effectiveConfidence(for record: PaceCompanionMemoryRecord, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(record.lastObservedAt))
        return record.confidence * pow(0.5, age / configuration.confidenceHalfLife)
    }
}

nonisolated enum PaceCompanionMemoryDocumentRenderer {
    static func documents(from records: [PaceCompanionMemoryRecord]) -> [PaceRetrievalDocument] {
        records.map { record in
            PaceRetrievalDocument(
                id: "companion-memory-\(record.id.uuidString.lowercased())",
                source: .companionMemory,
                title: "Companion \(record.type.rawValue) memory — \(record.subject.identifier)",
                text: documentText(for: record),
                modifiedAt: record.lastObservedAt,
                permissionScope: record.sourceKinds.map(\.rawValue).sorted().joined(separator: ",")
            )
        }
    }

    static func lastSeenAnswer(_ state: PaceWorldHypothesisState) -> String {
        switch state {
        case .unknown:
            return "I don't have a reliable last-seen observation."
        case .known(let hypothesis):
            let zone = hypothesis.location?.zone ?? "an unknown place"
            let uncertainty = hypothesis.isStale ? " The observation may be stale." : ""
            return "I last observed \(hypothesis.subject.identifier) at \(zone) at \(timestamp(hypothesis.observedAt)).\(uncertainty)"
        }
    }

    static func usualLocationAnswer(
        subject: PaceWorldSubject,
        records: [PaceCompanionMemoryRecord]
    ) -> String {
        guard let routine = (records
            .filter { $0.type == .routine && $0.subject == subject && $0.location != nil }
            .max(by: { $0.confidence < $1.confidence })) else {
            return "I haven't seen enough consistent evidence to know where \(subject.identifier) usually is."
        }
        return "\(subject.identifier) are usually at \(routine.location?.zone ?? "an unknown place"), based on \(routine.supportingObservationIDs.count) observations."
    }

    private static func documentText(for record: PaceCompanionMemoryRecord) -> String {
        let locationText = record.location.map { " at \($0.zone)" } ?? ""
        return "\(record.subject.identifier) \(record.predicate.rawValue)\(locationText). "
            + "Confidence \(String(format: "%.2f", record.confidence)); "
            + "observed \(timestamp(record.firstObservedAt)) through \(timestamp(record.lastObservedAt)); "
            + "evidence \(record.supportingObservationIDs.map(\.uuidString).joined(separator: ", "))."
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

@MainActor
final class PaceCompanionMemoryCoordinator {
    let observationStore: PaceWorldObservationStore
    let memoryPolicy: PaceCompanionMemoryPolicy
    private let replaceRetrievalDocuments: ([PaceRetrievalDocument]) -> Void
    private let discardPendingCandidates: (PacePerceptionSourceKind?) -> Void
    private let privacyPolicy: PaceCompanionPrivacyPolicy

    init(
        observationStore: PaceWorldObservationStore,
        memoryPolicy: PaceCompanionMemoryPolicy,
        retrievalStore: PaceRetrievalStore,
        privacyPolicy: PaceCompanionPrivacyPolicy = PaceCompanionPrivacyPolicy(),
        discardPendingCandidates: @escaping (PacePerceptionSourceKind?) -> Void = { _ in }
    ) {
        self.observationStore = observationStore
        self.memoryPolicy = memoryPolicy
        self.replaceRetrievalDocuments = { documents in
            retrievalStore.removeDocuments(withSource: .companionMemory)
            retrievalStore.upsertDocuments(documents)
        }
        self.privacyPolicy = privacyPolicy
        self.discardPendingCandidates = discardPendingCandidates
    }

    init(
        observationStore: PaceWorldObservationStore,
        memoryPolicy: PaceCompanionMemoryPolicy,
        privacyPolicy: PaceCompanionPrivacyPolicy = PaceCompanionPrivacyPolicy(),
        replaceRetrievalDocuments: @escaping ([PaceRetrievalDocument]) -> Void,
        discardPendingCandidates: @escaping (PacePerceptionSourceKind?) -> Void = { _ in }
    ) {
        self.observationStore = observationStore
        self.memoryPolicy = memoryPolicy
        self.replaceRetrievalDocuments = replaceRetrievalDocuments
        self.privacyPolicy = privacyPolicy
        self.discardPendingCandidates = discardPendingCandidates
    }

    func accept(
        _ observation: PaceWorldObservation,
        applicationBundleIdentifier: String? = nil,
        now: Date = Date()
    ) throws {
        guard privacyPolicy.mayPersistContext(
            fromApplicationBundleIdentifier: applicationBundleIdentifier
        ) else { return }
        let persistenceSafeObservation = try redactedObservation(observation)
        try observationStore.append(persistenceSafeObservation, now: now)
        memoryPolicy.promote(persistenceSafeObservation, now: now)
        refreshRetrievalDocuments()
    }

    func forget(subject: PaceWorldSubject) throws {
        try observationStore.clear(subject: subject)
        memoryPolicy.forget(subject: subject)
        discardPendingCandidates(nil)
        refreshRetrievalDocuments()
    }

    func clear(source: PacePerceptionSourceKind, disableFuturePromotion: Bool = false) throws {
        try observationStore.clear(source: source)
        memoryPolicy.clear(source: source, disableFuturePromotion: disableFuturePromotion)
        discardPendingCandidates(source)
        refreshRetrievalDocuments()
    }

    func clearAll() throws {
        try observationStore.clearAll()
        memoryPolicy.clearAll()
        discardPendingCandidates(nil)
        refreshRetrievalDocuments()
    }

    func refreshRetrievalDocuments() {
        replaceRetrievalDocuments(
            PaceCompanionMemoryDocumentRenderer.documents(from: memoryPolicy.records)
        )
    }

    private func redactedObservation(
        _ observation: PaceWorldObservation
    ) throws -> PaceWorldObservation {
        let redactedValue: PaceWorldValue
        switch observation.value {
        case .text(let text):
            redactedValue = .text(privacyPolicy.redactedTextForPersistence(text))
        case .boolean, .number, .presence:
            redactedValue = observation.value
        }
        return try PaceWorldObservation(
            id: observation.id,
            observedAt: observation.observedAt,
            source: observation.source,
            subject: observation.subject,
            predicate: observation.predicate,
            value: redactedValue,
            location: observation.location,
            confidence: observation.confidence,
            evidenceReference: observation.evidenceReference,
            expiresAt: observation.expiresAt,
            supersedesObservationIDs: observation.supersedesObservationIDs,
            context: observation.context.map { context in
                PaceWorldObservationContext(
                    applicationName: context.applicationName.map(privacyPolicy.redactedTextForPersistence),
                    applicationBundleIdentifier: context.applicationBundleIdentifier,
                    windowTitle: context.windowTitle.map(privacyPolicy.redactedTextForPersistence),
                    screenLabel: context.screenLabel.map(privacyPolicy.redactedTextForPersistence)
                )
            }
        )
    }
}
