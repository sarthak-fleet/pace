//
//  PaceTaughtObjectStore.swift
//  leanring-buddy
//
//  Local-only persistence and conservative matching policy for objects the
//  user explicitly teaches to companion mode. Vision feature-print archives
//  are retained; source camera pixels are never written to disk.
//

import Foundation

nonisolated enum PaceTaughtObjectError: Error, Equatable, LocalizedError {
    case emptyLabel
    case cameraNotActive
    case featurePrintUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyLabel:
            return "Enter a short object name first."
        case .cameraNotActive:
            return "Enable companion mode and its Camera source before teaching an object."
        case .featurePrintUnavailable:
            return "Pace could not capture a usable view. Center the object and try again."
        }
    }
}

nonisolated struct PaceTaughtObjectTemplate: Codable, Equatable, Sendable {
    let label: String
    let featurePrintArchive: Data
    let taughtAt: Date

    init(label: String, featurePrintArchive: Data, taughtAt: Date = Date()) throws {
        let normalizedLabel = Self.normalizedLabel(label)
        guard normalizedLabel.isEmpty == false else { throw PaceTaughtObjectError.emptyLabel }
        guard featurePrintArchive.isEmpty == false else {
            throw PaceTaughtObjectError.featurePrintUnavailable
        }
        self.label = normalizedLabel
        self.featurePrintArchive = featurePrintArchive
        self.taughtAt = taughtAt
    }

    static func normalizedLabel(_ label: String) -> String {
        String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
    }

    var trackIdentifier: String {
        let slug = label.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let compact = String(slug).split(separator: "-").joined(separator: "-")
        return "taught-object-\(compact.isEmpty ? "object" : compact)"
    }
}

nonisolated final class PaceTaughtObjectStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var storedTemplates: [PaceTaughtObjectTemplate]

    init(
        fileURL: URL = PaceTaughtObjectStore.defaultPersistenceURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.storedTemplates = Self.loadTemplates(from: fileURL)
    }

    static func defaultPersistenceURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("companion-taught-objects.json")
    }

    func templates() -> [PaceTaughtObjectTemplate] {
        lock.lock()
        defer { lock.unlock() }
        return storedTemplates.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    func upsert(_ template: PaceTaughtObjectTemplate) throws {
        lock.lock()
        defer { lock.unlock() }
        storedTemplates.removeAll {
            $0.label.caseInsensitiveCompare(template.label) == .orderedSame
        }
        storedTemplates.append(template)
        try persistLocked()
    }

    func remove(label: String) throws {
        let normalizedLabel = PaceTaughtObjectTemplate.normalizedLabel(label)
        lock.lock()
        defer { lock.unlock() }
        storedTemplates.removeAll {
            $0.label.caseInsensitiveCompare(normalizedLabel) == .orderedSame
        }
        try persistLocked()
    }

    private func persistLocked() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(storedTemplates)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func loadTemplates(from fileURL: URL) -> [PaceTaughtObjectTemplate] {
        guard let data = try? Data(contentsOf: fileURL),
              let templates = try? JSONDecoder().decode(
                [PaceTaughtObjectTemplate].self,
                from: data
              ) else { return [] }
        return templates
    }
}

nonisolated struct PaceTaughtObjectRegionMatch: Equatable, Sendable {
    let normalizedCenterX: Double
    let normalizedCenterY: Double
    let distance: Float
}

nonisolated enum PaceTaughtObjectMatchPolicy {
    static let maximumAcceptedDistance: Float = 0.35

    static func bestAcceptedMatch(
        _ matches: [PaceTaughtObjectRegionMatch],
        maximumDistance: Float = maximumAcceptedDistance
    ) -> PaceTaughtObjectRegionMatch? {
        guard maximumDistance > 0,
              let closest = matches.min(by: { $0.distance < $1.distance }),
              closest.distance.isFinite,
              closest.distance <= maximumDistance else { return nil }
        return closest
    }

    static func confidence(
        forDistance distance: Float,
        maximumDistance: Float = maximumAcceptedDistance
    ) -> Double {
        guard maximumDistance > 0, distance.isFinite else { return 0 }
        let normalizedSimilarity = min(max(1 - Double(distance / maximumDistance), 0), 1)
        return 0.5 + (normalizedSimilarity * 0.5)
    }
}
