//
//  PaceCompanionControlCenter.swift
//  leanring-buddy
//
//  Main-actor presentation/control model for companion Settings and menu-bar
//  indicators. Sensitive sources and outputs remain independently default off.
//

import Combine
import Foundation

@MainActor
final class PaceCompanionControlCenter: ObservableObject {
    /// Product-owner risk acceptance makes both intervention surfaces
    /// available for explicit dogfood opt-in. They remain independently
    /// default-off, and spoken output still passes the restraint gate.
    static let silentCardsAcceptancePassed = true
    static let spokenInterventionsAcceptancePassed = true
    @Published private(set) var preferences: PaceCompanionPreferences
    @Published private(set) var runtimeState: PaceCompanionRuntimeState = .off
    @Published private(set) var activeSources: Set<PacePerceptionSourceKind> = []
    @Published private(set) var lastObservationAt: Date?
    @Published private(set) var structuredStorageByteCount = 0
    @Published private(set) var isLocalModelReady = false
    @Published private(set) var taughtObjectLabels: [String] = []
    @Published private(set) var objectTeachingStatusText: String?

    private let userDefaults: UserDefaults
    private let observationFileURL: URL
    private let onModePreferenceChanged: (PaceCompanionPreferences) -> Void
    private let onPauseRequested: () -> Void
    private let onSourceClearRequested: (PacePerceptionSourceKind) -> Void
    private let onClearAllRequested: () -> Void
    private let onTeachObjectRequested: (String) -> Void
    private let onForgetTaughtObjectRequested: (String) -> Void
    private let onConversationRequested: () -> Void

    init(
        userDefaults: UserDefaults = .standard,
        observationFileURL: URL = PaceWorldObservationStore.defaultPersistenceURL(),
        onModePreferenceChanged: @escaping (PaceCompanionPreferences) -> Void = { _ in },
        onPauseRequested: @escaping () -> Void = {},
        onSourceClearRequested: @escaping (PacePerceptionSourceKind) -> Void = { _ in },
        onClearAllRequested: @escaping () -> Void = {},
        onTeachObjectRequested: @escaping (String) -> Void = { _ in },
        onForgetTaughtObjectRequested: @escaping (String) -> Void = { _ in },
        onConversationRequested: @escaping () -> Void = {}
    ) {
        self.userDefaults = userDefaults
        self.observationFileURL = observationFileURL
        var loadedPreferences = PaceCompanionPreferenceStore.load(userDefaults: userDefaults)
        if Self.silentCardsAcceptancePassed == false {
            loadedPreferences.areSilentCardsEnabled = false
        }
        if Self.spokenInterventionsAcceptancePassed == false {
            loadedPreferences.areSpokenInterventionsEnabled = false
        }
        self.preferences = loadedPreferences
        self.onModePreferenceChanged = onModePreferenceChanged
        self.onPauseRequested = onPauseRequested
        self.onSourceClearRequested = onSourceClearRequested
        self.onClearAllRequested = onClearAllRequested
        self.onTeachObjectRequested = onTeachObjectRequested
        self.onForgetTaughtObjectRequested = onForgetTaughtObjectRequested
        self.onConversationRequested = onConversationRequested
        refreshStorageUsage()
    }

    func setModeEnabled(_ isEnabled: Bool) {
        preferences.isCompanionModeEnabled = isEnabled
        persistPreferencesAndNotify()
        runtimeState = isEnabled ? .starting : .off
        if isEnabled == false { activeSources.removeAll() }
    }

    func setSource(_ source: PacePerceptionSourceKind, enabled: Bool) {
        if enabled { preferences.enabledSources.insert(source) }
        else { preferences.enabledSources.remove(source) }
        persistPreferencesAndNotify()
    }

    func setSilentCardsEnabled(_ isEnabled: Bool) {
        preferences.areSilentCardsEnabled = isEnabled && Self.silentCardsAcceptancePassed
        persistPreferencesAndNotify()
    }

    func setSpokenInterventionsEnabled(_ isEnabled: Bool) {
        preferences.areSpokenInterventionsEnabled = isEnabled && Self.spokenInterventionsAcceptancePassed
        persistPreferencesAndNotify()
    }

    func setRetentionDays(_ retentionDays: Int) {
        preferences.structuredObservationRetentionDays = min(max(retentionDays, 1), 90)
        persistPreferencesAndNotify()
    }

    func pause() {
        runtimeState = .paused
        activeSources.removeAll()
        onPauseRequested()
    }

    func clear(source: PacePerceptionSourceKind) {
        onSourceClearRequested(source)
        refreshStorageUsage()
    }

    func clearAll() {
        onClearAllRequested()
        lastObservationAt = nil
        refreshStorageUsage()
    }

    func teachObject(label: String) {
        let normalizedLabel = PaceTaughtObjectTemplate.normalizedLabel(label)
        guard normalizedLabel.isEmpty == false else {
            objectTeachingStatusText = PaceTaughtObjectError.emptyLabel.localizedDescription
            return
        }
        objectTeachingStatusText = "Capturing \(normalizedLabel) from the next camera frame…"
        onTeachObjectRequested(normalizedLabel)
    }

    func forgetTaughtObject(label: String) {
        onForgetTaughtObjectRequested(label)
    }

    func startUserInvokedConversation() {
        onConversationRequested()
    }

    func recordObjectTeachingResult(_ result: Result<[String], Error>) {
        switch result {
        case .success(let labels):
            taughtObjectLabels = labels
            objectTeachingStatusText = "Object saved locally. Pace will report conservative last-seen matches."
        case .failure(let error):
            objectTeachingStatusText = error.localizedDescription
        }
    }

    func updateTaughtObjectLabels(_ labels: [String]) {
        taughtObjectLabels = labels
    }

    func updateRuntime(
        state: PaceCompanionRuntimeState,
        activeSources: Set<PacePerceptionSourceKind>,
        lastObservationAt: Date?
    ) {
        self.runtimeState = state
        self.activeSources = activeSources
        self.lastObservationAt = lastObservationAt
        refreshStorageUsage()
    }

    func updateLocalModelReadiness(_ isReady: Bool) {
        isLocalModelReady = isReady
    }

    func refreshStorageUsage() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: observationFileURL.path)
        structuredStorageByteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    var runtimeStatusText: String {
        switch runtimeState {
        case .off: return "Off"
        case .starting: return "Starting"
        case .observing: return "Observing"
        case .interpreting: return "Interpreting locally"
        case .paused: return "Paused"
        case .degraded(let reason): return "Degraded: \(reason.rawValue)"
        case .privacyBlocked(let reason): return "Privacy blocked: \(reason.rawValue)"
        }
    }

    private func persistPreferencesAndNotify() {
        PaceCompanionPreferenceStore.save(preferences, userDefaults: userDefaults)
        onModePreferenceChanged(preferences)
    }
}
