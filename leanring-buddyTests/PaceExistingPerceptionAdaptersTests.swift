import Foundation
import CoreGraphics
import Testing

@testable import Pace

struct PaceExistingPerceptionAdaptersTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @MainActor
    @Test func ambientAdapterMapsExistingSnapshotWithoutStartingAnotherLoop() {
        let snapshot = PaceAmbientContextSnapshot(
            timestamp: now,
            frontmostAppName: "Xcode",
            frontmostBundleID: "com.apple.dt.Xcode",
            focusedWindowTitle: "PaceCompanion.swift",
            axTreeSummary: "3 buttons",
            clipboardChangeCount: 0,
            clipboardLastChangedAt: nil,
            displayCount: 1,
            focusModeName: nil,
            timeOfDayBucket: "morning",
            dayOfWeek: "Monday"
        )
        let candidate = PaceAmbientContextPerceptionAdapter.candidate(from: snapshot)
        #expect(candidate.source == .macOSContext)
        #expect(candidate.capturedAt == now)
        #expect(candidate.structuredPayload.contains("frontmost app: Xcode"))
        #expect(candidate.structuredPayload.contains("PaceCompanion.swift"))
    }

    @MainActor
    @Test func watchAdapterMapsAcceptedExistingEventAndStoresNoFrameInCandidate() {
        let capture = CompanionScreenCapture(
            imageData: Data(repeating: 0xAB, count: 10_000),
            label: "display 1",
            isCursorScreen: true,
            displayWidthInPoints: 1,
            displayHeightInPoints: 1,
            displayFrame: .zero,
            screenshotWidthInPixels: 1,
            screenshotHeightInPixels: 1
        )
        let event = PaceScreenWatchEvent(
            screenLabel: "display 1",
            diff: PaceScreenImageDiff(meanPixelDelta: 20, changedPixelRatio: 0.2),
            category: .contentUpdate,
            capture: capture,
            detectedAt: now
        )
        let candidate = PaceScreenWatchPerceptionAdapter.candidate(
            from: event,
            evidenceIdentifier: "frame-1"
        )
        #expect(candidate.source == .screen)
        #expect(candidate.structuredPayload == "display 1|content update")
        #expect(candidate.structuredPayload.utf8.count < capture.imageData.count)
        #expect(candidate.evidenceReference?.identifier == "frame-1")
    }

    @Test func ephemeralFrameStoreEvictsOldestAndTakeReleasesFrame() async {
        let store = PaceCompanionEphemeralScreenFrameStore(
            maximumFrameCount: 2,
            maximumTotalByteCount: 10
        )
        await store.insert(Data(repeating: 1, count: 6), identifier: "one")
        await store.insert(Data(repeating: 2, count: 6), identifier: "two")
        #expect(await store.storedFrameCount() == 1)
        #expect(await store.take(identifier: "one") == nil)
        #expect(await store.take(identifier: "two")?.count == 6)
        #expect(await store.storedByteCount() == 0)
    }

    @Test func targetedInterpreterCallsLocalVisualClientOnlyForStoredAcceptedFrame() async throws {
        let store = PaceCompanionEphemeralScreenFrameStore()
        let client = TestCompanionScreenAnalysisClient(description: "Build succeeded for person@example.com")
        let interpreter = PaceTargetedCompanionScreenInterpreter(
            analysisClient: client,
            frameStore: store
        )
        await store.insert(Data(repeating: 1, count: 100), identifier: "accepted-frame")
        let candidate = try screenCandidate(evidenceIdentifier: "accepted-frame")
        let observation = try #require(await interpreter.interpret(candidate))

        #expect(await client.analysisCallCount() == 1)
        guard case .text(let description) = observation.value else {
            Issue.record("Expected description text")
            return
        }
        #expect(description.contains("person@example.com") == false)
        #expect(observation.location?.zone == "display 1")
        #expect(await store.storedFrameCount() == 0)

        #expect(try await interpreter.interpret(candidate) == nil)
        #expect(await client.analysisCallCount() == 1)
    }

    @Test func sensitiveAppDenialReleasesFrameWithoutCallingVisualClient() async throws {
        let store = PaceCompanionEphemeralScreenFrameStore()
        let client = TestCompanionScreenAnalysisClient(description: "secret")
        let interpreter = PaceTargetedCompanionScreenInterpreter(
            analysisClient: client,
            frameStore: store,
            applicationBundleIdentifierProvider: { "com.1password.1password" }
        )
        await store.insert(Data(repeating: 1, count: 100), identifier: "sensitive-frame")
        #expect(try await interpreter.interpret(screenCandidate(evidenceIdentifier: "sensitive-frame")) == nil)
        #expect(await client.analysisCallCount() == 0)
        #expect(await store.storedFrameCount() == 0)
    }

    private func screenCandidate(evidenceIdentifier: String) throws -> PaceObservationCandidate {
        PaceObservationCandidate(
            source: .screen,
            capturedAt: now,
            equivalenceKey: "screen:display 1",
            structuredPayload: "display 1|content update",
            evidenceReference: try PaceEvidenceReference(
                type: "ephemeral-screen-frame",
                identifier: evidenceIdentifier
            )
        )
    }
}

private actor TestCompanionScreenAnalysisClient: PaceScreenAnalysisClient {
    nonisolated let displayName = "test local screen analyzer"
    private let description: String
    private var analysisCalls = 0

    init(description: String) { self.description = description }

    func analyzeScreenshot(
        screenshotImageData: Data,
        userIntent: String
    ) -> LocalVLMScreenAnalysis {
        analysisCalls += 1
        return LocalVLMScreenAnalysis(elements: [], description: description)
    }

    func groundMarkedClickTarget(
        markedImageData: Data,
        targetDescription: String,
        markCount: Int
    ) -> Int? {
        nil
    }

    func analysisCallCount() -> Int { analysisCalls }
}
