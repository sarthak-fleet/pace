import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceCompanionControlCenterTests {
    @Test func controlsPersistOptInsPauseRetentionAndClearCallbacks() throws {
        let suiteName = "PaceCompanionControlCenterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        var latestPreferences: PaceCompanionPreferences?
        var pauseCount = 0
        var clearedSource: PacePerceptionSourceKind?
        var clearAllCount = 0
        var taughtObjectLabel: String?
        var forgottenObjectLabel: String?
        var conversationRequestCount = 0
        let controlCenter = PaceCompanionControlCenter(
            userDefaults: defaults,
            observationFileURL: temporaryFileURL(),
            onModePreferenceChanged: { latestPreferences = $0 },
            onPauseRequested: { pauseCount += 1 },
            onSourceClearRequested: { clearedSource = $0 },
            onClearAllRequested: { clearAllCount += 1 },
            onTeachObjectRequested: { taughtObjectLabel = $0 },
            onForgetTaughtObjectRequested: { forgottenObjectLabel = $0 },
            onConversationRequested: { conversationRequestCount += 1 }
        )

        #expect(controlCenter.preferences == .disabled)
        controlCenter.setModeEnabled(true)
        controlCenter.setSource(.camera, enabled: true)
        controlCenter.setSilentCardsEnabled(true)
        controlCenter.setSpokenInterventionsEnabled(true)
        controlCenter.setRetentionDays(14)
        #expect(latestPreferences?.isCompanionModeEnabled == true)
        #expect(latestPreferences?.enabledSources == [.camera])
        #expect(latestPreferences?.areSilentCardsEnabled == true)
        #expect(latestPreferences?.areSpokenInterventionsEnabled == true)
        #expect(latestPreferences?.structuredObservationRetentionDays == 14)
        #expect(PaceCompanionPreferenceStore.load(userDefaults: defaults) == latestPreferences)

        controlCenter.pause()
        #expect(controlCenter.runtimeState == .paused)
        #expect(pauseCount == 1)
        controlCenter.clear(source: .camera)
        controlCenter.clearAll()
        #expect(clearedSource == .camera)
        #expect(clearAllCount == 1)

        controlCenter.teachObject(label: "  keys  ")
        #expect(taughtObjectLabel == "keys")
        controlCenter.recordObjectTeachingResult(.success(["keys"]))
        #expect(controlCenter.taughtObjectLabels == ["keys"])
        controlCenter.forgetTaughtObject(label: "keys")
        #expect(forgottenObjectLabel == "keys")
        controlCenter.startUserInvokedConversation()
        #expect(conversationRequestCount == 1)
    }

    @Test func runtimePresentationExposesAllStatesSourcesReadinessAndStorage() throws {
        let fileURL = temporaryFileURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 321).write(to: fileURL)
        let controlCenter = PaceCompanionControlCenter(observationFileURL: fileURL)
        let observedAt = Date()
        controlCenter.updateRuntime(
            state: .interpreting,
            activeSources: [.camera, .screen],
            lastObservationAt: observedAt
        )
        controlCenter.updateLocalModelReadiness(true)

        #expect(controlCenter.runtimeStatusText == "Interpreting locally")
        #expect(controlCenter.activeSources == [.camera, .screen])
        #expect(controlCenter.lastObservationAt == observedAt)
        #expect(controlCenter.isLocalModelReady)
        #expect(controlCenter.structuredStorageByteCount == 321)

        controlCenter.updateRuntime(state: .degraded(.thermalPressure), activeSources: [], lastObservationAt: observedAt)
        #expect(controlCenter.runtimeStatusText.contains("thermalPressure"))
        controlCenter.updateRuntime(state: .privacyBlocked(.invalidLocalEndpoint), activeSources: [], lastObservationAt: nil)
        #expect(controlCenter.runtimeStatusText.contains("invalidLocalEndpoint"))
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-companion-controls-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("observations.json")
    }
}
