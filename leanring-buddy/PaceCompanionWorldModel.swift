//
//  PaceCompanionWorldModel.swift
//  leanring-buddy
//
//  Typed, local-only evidence and derived state for Always-On Companion Mode.
//  Raw sensor data never enters this layer; observations contain only bounded,
//  structured claims and optional opaque evidence metadata.
//


import Foundation

nonisolated enum PacePerceptionSourceKind: String, Codable, CaseIterable, Sendable {
    case camera
    case ambientVoice
    case screen
    case macOSContext
    case userCorrection
}

nonisolated struct PaceWorldSubject: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case object
        case personPresence
        case application
        case window
        case topic
        case environment
    }

    let kind: Kind
    let identifier: String
    private enum CodingKeys: String, CodingKey { case kind, identifier }

    init(kind: Kind, identifier: String) throws {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedIdentifier.isEmpty == false else {
            throw PaceWorldObservationValidationError.emptySubjectIdentifier
        }
        if kind == .personPresence,
           normalizedIdentifier != "person",
           normalizedIdentifier.hasPrefix("ephemeral-track-") == false {
            throw PaceWorldObservationValidationError.personIdentityIsNotPermitted
        }
        self.kind = kind
        self.identifier = normalizedIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(Kind.self, forKey: .kind),
            identifier: container.decode(String.self, forKey: .identifier)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(identifier, forKey: .identifier)
    }
}

nonisolated enum PaceWorldPredicate: String, Codable, CaseIterable, Sendable {
    case isLocatedAt
    case entered
    case exited
    case changed
    case isActive
    case says
    case userConfirmed
}

nonisolated enum PaceWorldValue: Hashable, Codable, Sendable {
    case text(String)
    case boolean(Bool)
    case number(Double)
    case presence

    private enum CodingKeys: String, CodingKey { case type, text, boolean, number }
    private enum ValueType: String, Codable { case text, boolean, number, presence }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .text: self = .text(try container.decode(String.self, forKey: .text))
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .boolean))
        case .number: self = .number(try container.decode(Double.self, forKey: .number))
        case .presence: self = .presence
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(ValueType.text, forKey: .type)
            try container.encode(value, forKey: .text)
        case .boolean(let value):
            try container.encode(ValueType.boolean, forKey: .type)
            try container.encode(value, forKey: .boolean)
        case .number(let value):
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(value, forKey: .number)
        case .presence:
            try container.encode(ValueType.presence, forKey: .type)
        }
    }
}

nonisolated struct PaceWorldLocation: Hashable, Codable, Sendable {
    let source: PacePerceptionSourceKind
    let zone: String

    init(source: PacePerceptionSourceKind, zone: String) throws {
        let normalizedZone = zone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedZone.isEmpty == false else {
            throw PaceWorldObservationValidationError.emptyLocationZone
        }
        self.source = source
        self.zone = normalizedZone
    }
}

nonisolated struct PaceEvidenceReference: Hashable, Codable, Sendable {
    let type: String
    let identifier: String

    init(type: String, identifier: String) throws {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedType.isEmpty == false, normalizedIdentifier.isEmpty == false else {
            throw PaceWorldObservationValidationError.emptyEvidenceReference
        }
        self.type = normalizedType
        self.identifier = normalizedIdentifier
    }
}

nonisolated struct PaceWorldObservationContext: Hashable, Codable, Sendable {
    let applicationName: String?
    let applicationBundleIdentifier: String?
    let windowTitle: String?
    let screenLabel: String?
}

nonisolated enum PaceWorldObservationValidationError: Error, Equatable {
    case emptySubjectIdentifier
    case personIdentityIsNotPermitted
    case emptyLocationZone
    case emptyEvidenceReference
    case confidenceOutsideUnitInterval
    case expiryPrecedesObservation
}

nonisolated struct PaceWorldObservation: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let observedAt: Date
    let source: PacePerceptionSourceKind
    let subject: PaceWorldSubject
    let predicate: PaceWorldPredicate
    let value: PaceWorldValue
    let location: PaceWorldLocation?
    let confidence: Double
    let evidenceReference: PaceEvidenceReference?
    let expiresAt: Date?
    let supersedesObservationIDs: [UUID]
    let context: PaceWorldObservationContext?

    init(
        id: UUID = UUID(),
        observedAt: Date,
        source: PacePerceptionSourceKind,
        subject: PaceWorldSubject,
        predicate: PaceWorldPredicate,
        value: PaceWorldValue,
        location: PaceWorldLocation? = nil,
        confidence: Double,
        evidenceReference: PaceEvidenceReference? = nil,
        expiresAt: Date? = nil,
        supersedesObservationIDs: [UUID] = [],
        context: PaceWorldObservationContext? = nil
    ) throws {
        guard confidence.isFinite, (0...1).contains(confidence) else {
            throw PaceWorldObservationValidationError.confidenceOutsideUnitInterval
        }
        if let expiresAt, expiresAt < observedAt {
            throw PaceWorldObservationValidationError.expiryPrecedesObservation
        }
        self.id = id
        self.observedAt = observedAt
        self.source = source
        self.subject = subject
        self.predicate = predicate
        self.value = value
        self.location = location
        self.confidence = confidence
        self.evidenceReference = evidenceReference
        self.expiresAt = expiresAt
        self.supersedesObservationIDs = Array(Set(supersedesObservationIDs)).sorted { $0.uuidString < $1.uuidString }
        self.context = context
    }

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= date
    }
}

nonisolated final class PaceWorldObservationStore {
    struct Configuration: Equatable {
        let maximumObservationCount: Int
        let retentionInterval: TimeInterval

        init(maximumObservationCount: Int = 5_000, retentionInterval: TimeInterval = 30 * 86_400) {
            self.maximumObservationCount = max(1, maximumObservationCount)
            self.retentionInterval = max(0, retentionInterval)
        }
    }

    private let fileURL: URL
    private let configuration: Configuration
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private(set) var observations: [PaceWorldObservation]
    private(set) var lastLoadErrorDescription: String?

    static func defaultPersistenceURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupportURL
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("companion-observations.json")
    }

    init(fileURL: URL, configuration: Configuration = Configuration(), now: Date = Date()) {
        self.fileURL = fileURL
        self.configuration = configuration
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        do {
            let data = try Data(contentsOf: fileURL)
            observations = try decoder.decode([PaceWorldObservation].self, from: data)
            observations = Self.pruned(observations, configuration: configuration, now: now)
        } catch CocoaError.fileReadNoSuchFile {
            observations = []
        } catch {
            observations = []
            lastLoadErrorDescription = String(describing: error)
        }
    }

    func append(_ observation: PaceWorldObservation, now: Date = Date()) throws {
        if observations.contains(where: { $0.id == observation.id }) == false {
            observations.append(observation)
        }
        observations = Self.pruned(observations, configuration: configuration, now: now)
        try persist()
    }

    func prune(now: Date = Date()) throws {
        observations = Self.pruned(observations, configuration: configuration, now: now)
        try persist()
    }

    func clear(source: PacePerceptionSourceKind) throws {
        observations.removeAll { $0.source == source }
        try persist()
    }

    func clear(subject: PaceWorldSubject) throws {
        observations.removeAll { $0.subject == subject }
        try persist()
    }

    func clearAll() throws {
        observations.removeAll()
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(observations).write(to: fileURL, options: [.atomic])
    }

    private static func pruned(
        _ observations: [PaceWorldObservation],
        configuration: Configuration,
        now: Date
    ) -> [PaceWorldObservation] {
        let retentionCutoff = now.addingTimeInterval(-configuration.retentionInterval)
        return observations
            .filter { $0.observedAt >= retentionCutoff && $0.isExpired(at: now) == false }
            .sorted { $0.observedAt < $1.observedAt }
            .suffix(configuration.maximumObservationCount)
            .map { $0 }
    }
}

nonisolated enum PaceWorldHypothesisState: Equatable {
    case known(PaceWorldHypothesis)
    case unknown(reason: String)
}

nonisolated struct PaceWorldHypothesis: Equatable {
    let subject: PaceWorldSubject
    let predicate: PaceWorldPredicate
    let value: PaceWorldValue
    let location: PaceWorldLocation?
    let observedAt: Date
    let confidence: Double
    let supportingObservationIDs: [UUID]
    let contradictingObservationIDs: [UUID]
    let supersededObservationIDs: [UUID]
    let source: PacePerceptionSourceKind
    let evidenceReference: PaceEvidenceReference?
    let isStale: Bool
}

nonisolated struct PaceWorldQueryResult: Equatable {
    let observations: [PaceWorldObservation]
    let hypothesis: PaceWorldHypothesisState?
}

nonisolated struct PaceWorldModelStore {
    let minimumReliableConfidence: Double
    let confidenceHalfLife: TimeInterval

    init(minimumReliableConfidence: Double = 0.35, confidenceHalfLife: TimeInterval = 7 * 86_400) {
        self.minimumReliableConfidence = min(max(minimumReliableConfidence, 0), 1)
        self.confidenceHalfLife = max(confidenceHalfLife, 1)
    }

    func currentState(
        for subject: PaceWorldSubject,
        predicate: PaceWorldPredicate,
        observations: [PaceWorldObservation],
        now: Date = Date()
    ) -> PaceWorldHypothesisState {
        let relevant = observations
            .filter { $0.subject == subject && $0.predicate == predicate && $0.isExpired(at: now) == false }
            .sorted { $0.observedAt < $1.observedAt }
        guard relevant.isEmpty == false else {
            return .unknown(reason: "no unexpired evidence")
        }

        let explicitlySupersededIDs = Set(relevant.flatMap(\.supersedesObservationIDs))
        let candidates = relevant.filter { explicitlySupersededIDs.contains($0.id) == false }
        guard let winningObservation = candidates.max(by: {
            effectiveConfidence(of: $0, now: now) < effectiveConfidence(of: $1, now: now)
                || (effectiveConfidence(of: $0, now: now) == effectiveConfidence(of: $1, now: now)
                    && $0.observedAt < $1.observedAt)
        }) else {
            return .unknown(reason: "all evidence was superseded")
        }
        let effectiveWinningConfidence = effectiveConfidence(of: winningObservation, now: now)
        guard effectiveWinningConfidence >= minimumReliableConfidence else {
            return .unknown(reason: "evidence confidence decayed below threshold")
        }

        let supporting = relevant.filter {
            $0.value == winningObservation.value && $0.location == winningObservation.location
                && explicitlySupersededIDs.contains($0.id) == false
        }
        let contradicting = relevant.filter {
            ($0.value != winningObservation.value || $0.location != winningObservation.location)
                && explicitlySupersededIDs.contains($0.id) == false
        }
        return .known(PaceWorldHypothesis(
            subject: subject,
            predicate: predicate,
            value: winningObservation.value,
            location: winningObservation.location,
            observedAt: winningObservation.observedAt,
            confidence: effectiveWinningConfidence,
            supportingObservationIDs: supporting.map(\.id),
            contradictingObservationIDs: contradicting.map(\.id),
            supersededObservationIDs: Array(explicitlySupersededIDs).sorted { $0.uuidString < $1.uuidString },
            source: winningObservation.source,
            evidenceReference: winningObservation.evidenceReference,
            isStale: effectiveWinningConfidence < max(minimumReliableConfidence + 0.2, 0.6)
        ))
    }

    func lastSeen(
        subject: PaceWorldSubject,
        observations: [PaceWorldObservation],
        now: Date = Date()
    ) -> PaceWorldHypothesisState {
        currentState(for: subject, predicate: .isLocatedAt, observations: observations, now: now)
    }

    func changes(
        since startDate: Date,
        observations: [PaceWorldObservation],
        now: Date = Date()
    ) -> PaceWorldQueryResult {
        PaceWorldQueryResult(
            observations: observations
                .filter { $0.observedAt >= startDate && $0.observedAt <= now && $0.predicate == .changed && !$0.isExpired(at: now) }
                .sorted { $0.observedAt < $1.observedAt },
            hypothesis: nil
        )
    }

    func presence(
        since startDate: Date,
        observations: [PaceWorldObservation],
        now: Date = Date()
    ) -> PaceWorldQueryResult {
        PaceWorldQueryResult(
            observations: observations
                .filter {
                    $0.observedAt >= startDate && $0.observedAt <= now
                        && $0.subject.kind == .personPresence && !$0.isExpired(at: now)
                }
                .sorted { $0.observedAt < $1.observedAt },
            hypothesis: nil
        )
    }

    private func effectiveConfidence(of observation: PaceWorldObservation, now: Date) -> Double {
        guard observation.source != .userCorrection else { return observation.confidence }
        let age = max(0, now.timeIntervalSince(observation.observedAt))
        return observation.confidence * pow(0.5, age / confidenceHalfLife)
    }
}
