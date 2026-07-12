import Foundation
import Testing

@testable import Pace

struct PaceCompanionPrivacyAndResourcesTests {
    @Test func privacyPolicyDeniesSensitiveAppsRedactsSecretsAndFailsClosedOnRemoteEndpoint() throws {
        let policy = PaceCompanionPrivacyPolicy(maximumPersistedTextLength: 80)
        #expect(policy.mayPersistContext(fromApplicationBundleIdentifier: "com.1password.1password") == false)
        #expect(policy.mayPersistContext(fromApplicationBundleIdentifier: "com.apple.TextEdit"))

        let redacted = policy.redactedTextForPersistence(
            "Email me at person@example.com token=super-secret and use 4111 1111 1111 1111"
        )
        #expect(redacted.contains("person@example.com") == false)
        #expect(redacted.contains("super-secret") == false)
        #expect(redacted.contains("4111") == false)
        #expect(redacted.contains("[redacted]"))

        try policy.validateCompanionEndpoint(
            try #require(URL(string: "http://127.0.0.1:1234/v1")),
            settingName: "CompanionPlannerURL"
        )
        #expect(throws: PaceLocalEndpointGuardError.self) {
            try policy.validateCompanionEndpoint(
                try #require(URL(string: "https://example.com/v1")),
                settingName: "CompanionPlannerURL"
            )
        }
    }

    @Test func rawDataBufferIsStrictlyBoundedAndReleasesOversizedInput() {
        var buffer = PaceBoundedRawDataBuffer(maximumValueCount: 2, maximumTotalByteCount: 10)
        buffer.append(Data(repeating: 1, count: 6))
        buffer.append(Data(repeating: 2, count: 6))
        #expect(buffer.values.count == 1)
        #expect(buffer.totalByteCount == 6)
        buffer.append(Data(repeating: 3, count: 11))
        #expect(buffer.values.isEmpty)
        #expect(buffer.totalByteCount == 0)
    }

    @Test func criticalThermalLowBatteryMemoryAndConcurrencyDegradeOnlyExpensiveStages() {
        let budget = PaceCompanionResourceBudget(
            minimumBatteryLevelForExpensiveStages: 0.25,
            maximumStructuredMemoryBytes: 1_024
        )
        let cases: [(PaceCompanionResourceSnapshot, PaceCompanionDegradedReason)] = [
            (.init(
                isRunningOnBattery: false,
                batteryLevel: nil,
                thermalRecommendation: .suspendBackground,
                structuredMemoryByteCount: 100,
                inFlightAnalysisCountBySource: [:]
            ), .thermalPressure),
            (.init(
                isRunningOnBattery: true,
                batteryLevel: 0.1,
                thermalRecommendation: .unrestricted,
                structuredMemoryByteCount: 100,
                inFlightAnalysisCountBySource: [:]
            ), .batteryBudget),
            (.init(
                isRunningOnBattery: false,
                batteryLevel: nil,
                thermalRecommendation: .unrestricted,
                structuredMemoryByteCount: 2_048,
                inFlightAnalysisCountBySource: [:]
            ), .memoryBudget),
            (.init(
                isRunningOnBattery: false,
                batteryLevel: nil,
                thermalRecommendation: .unrestricted,
                structuredMemoryByteCount: 100,
                inFlightAnalysisCountBySource: [.camera: 2]
            ), .analysisBudget),
        ]
        for (snapshot, expectedReason) in cases {
            let decision = PaceCompanionResourceBudgetPolicy.decision(budget: budget, snapshot: snapshot)
            #expect(decision.mayRunCheapEventSources)
            #expect(decision.mayRunCameraSampling == false)
            #expect(decision.mayRunVLMAnalysis == false)
            #expect(decision.degradedReason == expectedReason)
        }
    }

    @Test func nominalResourcesAllowWorkAndMetricsExposeIdleAndModelCallBehavior() {
        let decision = PaceCompanionResourceBudgetPolicy.decision(
            budget: PaceCompanionResourceBudget(),
            snapshot: .init(
                isRunningOnBattery: false,
                batteryLevel: nil,
                thermalRecommendation: .unrestricted,
                structuredMemoryByteCount: 1_000,
                inFlightAnalysisCountBySource: [.camera: 1]
            )
        )
        #expect(decision.mayRunCameraSampling)
        #expect(decision.mayRunVLMAnalysis)
        #expect(decision.degradedReason == nil)

        var metrics = PaceCompanionResourceMetrics()
        metrics.recordCandidate(accepted: true)
        metrics.recordCandidate(accepted: false)
        metrics.recordModelCall()
        metrics.recordRawBufferByteCount(512)
        metrics.recordIdleSample()
        #expect(metrics.acceptedCandidateCount == 1)
        #expect(metrics.droppedCandidateCount == 1)
        #expect(metrics.modelCallCount == 1)
        #expect(metrics.maximumRawBufferByteCount == 512)
        #expect(metrics.idleSampleCount == 1)
    }
}
