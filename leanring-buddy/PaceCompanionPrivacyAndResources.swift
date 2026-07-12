//
//  PaceCompanionPrivacyAndResources.swift
//  leanring-buddy
//
//  Fail-closed privacy checks and deterministic background-work budgets for
//  Always-On Companion Mode.
//

import Foundation

nonisolated struct PaceCompanionPrivacyPolicy: Sendable {
    let deniedApplicationBundleIdentifiers: Set<String>
    let maximumPersistedTextLength: Int

    init(
        deniedApplicationBundleIdentifiers: Set<String> = [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.apple.keychainaccess",
            "com.bitwarden.desktop",
            "com.lastpass.LastPass",
        ],
        maximumPersistedTextLength: Int = 500
    ) {
        self.deniedApplicationBundleIdentifiers = deniedApplicationBundleIdentifiers
        self.maximumPersistedTextLength = max(0, maximumPersistedTextLength)
    }

    func mayPersistContext(fromApplicationBundleIdentifier bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        return deniedApplicationBundleIdentifiers.contains(bundleIdentifier) == false
    }

    func redactedTextForPersistence(_ text: String) -> String {
        var redactedText = text
        let patterns = [
            #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"\b(?:\d[ -]*?){13,19}\b"#,
            #"(?i)\b(?:api[_ -]?key|token|password|secret)\s*[:=]\s*\S+"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let fullRange = NSRange(redactedText.startIndex..<redactedText.endIndex, in: redactedText)
            redactedText = expression.stringByReplacingMatches(
                in: redactedText,
                range: fullRange,
                withTemplate: "[redacted]"
            )
        }
        if redactedText.count > maximumPersistedTextLength {
            redactedText = String(redactedText.prefix(maximumPersistedTextLength)) + "…"
        }
        return redactedText
    }

    func validateCompanionEndpoint(_ endpoint: URL, settingName: String) throws {
        try PaceLocalEndpointGuard.validateLocalHTTPURL(endpoint, settingName: settingName)
    }

    @MainActor
    func makePrivacyPinnedPlanner() -> any BuddyPlannerClient {
        BuddyPlannerClientFactory.makeLocalOnlyPlannerForPrivacyPinnedFeatures()
    }
}

nonisolated struct PaceBoundedRawDataBuffer: Sendable {
    private(set) var values: [Data] = []
    private(set) var totalByteCount = 0
    let maximumValueCount: Int
    let maximumTotalByteCount: Int

    init(maximumValueCount: Int, maximumTotalByteCount: Int) {
        self.maximumValueCount = max(1, maximumValueCount)
        self.maximumTotalByteCount = max(1, maximumTotalByteCount)
    }

    mutating func append(_ value: Data) {
        guard value.count <= maximumTotalByteCount else {
            removeAll()
            return
        }
        values.append(value)
        totalByteCount += value.count
        while values.count > maximumValueCount || totalByteCount > maximumTotalByteCount {
            totalByteCount -= values.removeFirst().count
        }
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: false)
        totalByteCount = 0
    }
}

nonisolated struct PaceCompanionResourceBudget: Equatable, Sendable {
    let maximumCameraFramesPerSecond: Double
    let maximumScreenFramesPerSecond: Double
    let maximumConcurrentAnalysesPerSource: Int
    let minimumBatteryLevelForExpensiveStages: Double
    let maximumStructuredMemoryBytes: Int

    init(
        maximumCameraFramesPerSecond: Double = 1,
        maximumScreenFramesPerSecond: Double = 0.2,
        maximumConcurrentAnalysesPerSource: Int = 1,
        minimumBatteryLevelForExpensiveStages: Double = 0.2,
        maximumStructuredMemoryBytes: Int = 20 * 1_024 * 1_024
    ) {
        self.maximumCameraFramesPerSecond = min(max(maximumCameraFramesPerSecond, 0.1), 2)
        self.maximumScreenFramesPerSecond = min(max(maximumScreenFramesPerSecond, 0.05), 1)
        self.maximumConcurrentAnalysesPerSource = 1
        self.minimumBatteryLevelForExpensiveStages = min(max(minimumBatteryLevelForExpensiveStages, 0), 1)
        self.maximumStructuredMemoryBytes = max(1_024, maximumStructuredMemoryBytes)
    }
}

nonisolated struct PaceCompanionResourceSnapshot: Equatable, Sendable {
    let isRunningOnBattery: Bool
    let batteryLevel: Double?
    let thermalRecommendation: PaceThermalRecommendation
    let structuredMemoryByteCount: Int
    let inFlightAnalysisCountBySource: [PacePerceptionSourceKind: Int]
}

nonisolated struct PaceCompanionResourceDecision: Equatable, Sendable {
    let mayRunCheapEventSources: Bool
    let mayRunCameraSampling: Bool
    let mayRunVLMAnalysis: Bool
    let degradedReason: PaceCompanionDegradedReason?
}

nonisolated enum PaceCompanionResourceBudgetPolicy {
    static func decision(
        budget: PaceCompanionResourceBudget,
        snapshot: PaceCompanionResourceSnapshot
    ) -> PaceCompanionResourceDecision {
        if snapshot.structuredMemoryByteCount > budget.maximumStructuredMemoryBytes {
            return .init(
                mayRunCheapEventSources: true,
                mayRunCameraSampling: false,
                mayRunVLMAnalysis: false,
                degradedReason: .memoryBudget
            )
        }
        if snapshot.thermalRecommendation == .suspendBackground {
            return .init(
                mayRunCheapEventSources: true,
                mayRunCameraSampling: false,
                mayRunVLMAnalysis: false,
                degradedReason: .thermalPressure
            )
        }
        if snapshot.isRunningOnBattery,
           let batteryLevel = snapshot.batteryLevel,
           batteryLevel < budget.minimumBatteryLevelForExpensiveStages {
            return .init(
                mayRunCheapEventSources: true,
                mayRunCameraSampling: false,
                mayRunVLMAnalysis: false,
                degradedReason: .batteryBudget
            )
        }
        let exceedsConcurrencyBudget = snapshot.inFlightAnalysisCountBySource.values.contains {
            $0 > budget.maximumConcurrentAnalysesPerSource
        }
        return .init(
            mayRunCheapEventSources: true,
            mayRunCameraSampling: exceedsConcurrencyBudget == false,
            mayRunVLMAnalysis: exceedsConcurrencyBudget == false,
            degradedReason: exceedsConcurrencyBudget ? .analysisBudget : nil
        )
    }
}

nonisolated struct PaceCompanionResourceMetrics: Equatable, Sendable {
    private(set) var acceptedCandidateCount = 0
    private(set) var droppedCandidateCount = 0
    private(set) var modelCallCount = 0
    private(set) var maximumRawBufferByteCount = 0
    private(set) var idleSampleCount = 0

    mutating func recordCandidate(accepted: Bool) {
        if accepted { acceptedCandidateCount += 1 } else { droppedCandidateCount += 1 }
    }

    mutating func recordModelCall() { modelCallCount += 1 }
    mutating func recordRawBufferByteCount(_ byteCount: Int) {
        maximumRawBufferByteCount = max(maximumRawBufferByteCount, max(0, byteCount))
    }
    mutating func recordIdleSample() { idleSampleCount += 1 }
}
