//
//  PaceProactiveNudgeFrameworkTests.swift
//  leanring-buddyTests
//
//  Unit tests for the proactive nudge framework introduced in Wave 1b.
//  Covers orchestrator dispatch, gate-aware routing (emit vs queue
//  vs drop), and the three concrete generators in isolation.
//

import Combine
import XCTest
@testable import Pace

@MainActor
final class PaceProactiveNudgeFrameworkOrchestratorTests: XCTestCase {
    func testOrchestratorStartsAndStopsEveryGenerator() {
        let firstGenerator = RecordingNudgeGenerator(identifier: "first-generator")
        let secondGenerator = RecordingNudgeGenerator(identifier: "second-generator")
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: [firstGenerator, secondGenerator]
        )

        orchestrator.start(emit: { _ in }, queueForLater: { _ in })

        XCTAssertEqual(firstGenerator.startCalls, 1)
        XCTAssertEqual(secondGenerator.startCalls, 1)

        orchestrator.stop()

        XCTAssertEqual(firstGenerator.stopCalls, 1)
        XCTAssertEqual(secondGenerator.stopCalls, 1)
    }

    func testRouteEvaluationStayQuietDoesNotEmitOrQueue() {
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: []
        )
        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []

        orchestrator.routeEvaluationForTesting(
            (.stayQuiet(reason: "test"), nil),
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertTrue(emittedUtterances.isEmpty)
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testRouteEvaluationQueueUntilIdleSendsToQueueForLater() {
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: []
        )
        let queuedUtterance = PaceProactiveUtterance(
            spokenText: "queued",
            source: .watchNudge,
            confidence: 0.8,
            relevanceWindowExpiresAt: nil
        )
        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []

        orchestrator.routeEvaluationForTesting(
            (.queueUntilIdle(reason: "test"), queuedUtterance),
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertTrue(emittedUtterances.isEmpty)
        XCTAssertEqual(queuedUtterances.map(\.spokenText), ["queued"])
    }

    func testRouteEvaluationSpeakSendsToEmit() {
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: []
        )
        let spokenUtterance = PaceProactiveUtterance(
            spokenText: "go",
            source: .watchNudge,
            confidence: 0.8,
            relevanceWindowExpiresAt: nil
        )
        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []

        orchestrator.routeEvaluationForTesting(
            (.speak, spokenUtterance),
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertEqual(emittedUtterances.map(\.spokenText), ["go"])
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testPerGeneratorToggleOnlyTouchesOneGenerator() {
        let firstGenerator = RecordingNudgeGenerator(identifier: "first-generator")
        let secondGenerator = RecordingNudgeGenerator(identifier: "second-generator")
        let orchestrator = PaceProactiveNudgeOrchestrator(
            restraintContextProvider: stableRestraintContextProvider(),
            generators: [firstGenerator, secondGenerator]
        )

        orchestrator.start(emit: { _ in }, queueForLater: { _ in })
        orchestrator.setGeneratorEnabled(
            identifier: "second-generator",
            enabled: false,
            emit: { _ in },
            queueForLater: { _ in }
        )

        XCTAssertEqual(firstGenerator.stopCalls, 0)
        XCTAssertEqual(secondGenerator.stopCalls, 1)
    }

    private func stableRestraintContextProvider() -> () -> PaceRestraintContext {
        return {
            PaceRestraintContext(
                now: Date(),
                lastProactiveUtteranceAt: nil,
                lastEpisodicRecallAt: nil,
                lastUserInputAt: nil,
                frontmostAppBundleIdentifier: nil,
                isOnActiveCall: false,
                wakeWordConfidence: nil,
                intent: .pureKnowledge,
                proactiveSource: .watchNudge,
                profile: .balanced
            )
        }
    }
}

@MainActor
final class PaceFocusFatigueNudgeGeneratorTests: XCTestCase {
    func testGeneratorEmitsWhenForegroundLongAndGateAllows() {
        let now = Date()
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: now.addingTimeInterval(-60),
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .watchNudge,
            profile: .balanced
        )
        let generator = PaceFocusFatigueNudgeGenerator(
            restraintContextProvider: { restraintContext },
            frontmostApplicationNameProvider: { "Figma" },
            nowProvider: { now }
        )
        generator.injectFrontmostApplicationActivationForTesting(
            applicationName: "Figma",
            activatedAt: now.addingTimeInterval(-60 * 60)
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []
        generator.evaluateNow(
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertEqual(emittedUtterances.count, 1)
        XCTAssertTrue(emittedUtterances.first?.spokenText.contains("Figma") == true)
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testGeneratorDoesNotEmitDuringActiveCall() {
        let now = Date()
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: "us.zoom.xos",
            isOnActiveCall: true,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .watchNudge,
            profile: .balanced
        )
        let generator = PaceFocusFatigueNudgeGenerator(
            restraintContextProvider: { restraintContext },
            frontmostApplicationNameProvider: { "Figma" },
            nowProvider: { now }
        )
        generator.injectFrontmostApplicationActivationForTesting(
            applicationName: "Figma",
            activatedAt: now.addingTimeInterval(-60 * 60)
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []
        generator.evaluateNow(
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertTrue(emittedUtterances.isEmpty, "Active call must suppress the focus-fatigue nudge")
        XCTAssertTrue(queuedUtterances.isEmpty, "Gate returns queue, but utterance is nil for active-call")
    }
}

@MainActor
final class PaceCalendarPreMeetingNudgeGeneratorTests: XCTestCase {
    func testGeneratorEmitsWhenEventStartsSoonAndGateAllows() {
        let now = Date()
        let upcomingEvent = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "event-1",
            title: "Design review",
            startDate: now.addingTimeInterval(240),
            endDate: now.addingTimeInterval(240 + 30 * 60)
        )
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .backgroundReminder,
            profile: .balanced
        )
        let generator = PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { restraintContext },
            upcomingEventSnapshotsProvider: { _ in [upcomingEvent] },
            nowProvider: { now }
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []
        generator.evaluateNow(
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertEqual(emittedUtterances.first?.source, .backgroundReminder)
        XCTAssertTrue(emittedUtterances.first?.spokenText.contains("Design review") == true)
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testGeneratorQueuesWhenInputRecent() {
        let now = Date()
        let upcomingEvent = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "event-1",
            title: "Sync with team",
            startDate: now.addingTimeInterval(180),
            endDate: now.addingTimeInterval(180 + 30 * 60)
        )
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: now.addingTimeInterval(-1),
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .backgroundReminder,
            profile: .balanced
        )
        let generator = PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { restraintContext },
            upcomingEventSnapshotsProvider: { _ in [upcomingEvent] },
            nowProvider: { now }
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []
        generator.evaluateNow(
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertTrue(emittedUtterances.isEmpty)
        XCTAssertEqual(queuedUtterances.count, 1, "Recent input under .balanced should queue, not drop")
    }

    func testGeneratorDeduplicatesSameEventAcrossTicks() {
        let now = Date()
        let upcomingEvent = PaceCalendarRetrievalEventSnapshot(
            stableIdentifier: "event-1",
            title: "Sync",
            startDate: now.addingTimeInterval(180),
            endDate: now.addingTimeInterval(180 + 30 * 60)
        )
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .backgroundReminder,
            profile: .balanced
        )
        let generator = PaceCalendarPreMeetingNudgeGenerator(
            restraintContextProvider: { restraintContext },
            upcomingEventSnapshotsProvider: { _ in [upcomingEvent] },
            nowProvider: { now }
        )

        var emittedCount = 0
        generator.evaluateNow(
            emit: { _ in emittedCount += 1 },
            queueForLater: { _ in }
        )
        generator.evaluateNow(
            emit: { _ in emittedCount += 1 },
            queueForLater: { _ in }
        )

        XCTAssertEqual(emittedCount, 1, "Same event must not nudge twice in one session")
    }
}

@MainActor
final class PaceWatchModeObservationNudgeGeneratorTests: XCTestCase {
    func testGeneratorEmitsOnMajorChangeWithErrorKeyword() {
        let restraintContext = PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .balanced
        )
        let publisher = PassthroughSubject<PaceScreenWatchEvent, Never>()
        let generator = PaceWatchModeObservationNudgeGenerator(
            restraintContextProvider: { restraintContext },
            watchEventPublisher: publisher.eraseToAnyPublisher(),
            screenDescriptionProvider: { _ in "build failed in xcode" },
            nowProvider: { restraintContext.now }
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        var queuedUtterances: [PaceProactiveUtterance] = []

        let majorChangeEvent = PaceScreenWatchEvent(
            screenLabel: "Built-in Display",
            diff: PaceScreenImageDiff(meanPixelDelta: 35, changedPixelRatio: 0.5),
            category: .majorScreenChange,
            capture: CompanionScreenCapture(
                imageData: Data(),
                label: "Built-in Display",
                isCursorScreen: true,
                displayWidthInPoints: 1440,
                displayHeightInPoints: 900,
                displayFrame: .zero,
                screenshotWidthInPixels: 1440,
                screenshotHeightInPixels: 900
            ),
            detectedAt: restraintContext.now
        )
        generator.handleWatchEvent(
            majorChangeEvent,
            emit: { emittedUtterances.append($0) },
            queueForLater: { queuedUtterances.append($0) }
        )

        XCTAssertEqual(emittedUtterances.first?.source, .watchNudge)
        XCTAssertTrue(queuedUtterances.isEmpty)
    }

    func testGeneratorSkipsContentUpdateCategory() {
        let restraintContext = PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .balanced
        )
        let publisher = PassthroughSubject<PaceScreenWatchEvent, Never>()
        let generator = PaceWatchModeObservationNudgeGenerator(
            restraintContextProvider: { restraintContext },
            watchEventPublisher: publisher.eraseToAnyPublisher(),
            screenDescriptionProvider: { _ in "build failed in xcode" },
            nowProvider: { restraintContext.now }
        )

        var emittedUtterances: [PaceProactiveUtterance] = []
        let contentUpdateEvent = PaceScreenWatchEvent(
            screenLabel: "Built-in Display",
            diff: PaceScreenImageDiff(meanPixelDelta: 15, changedPixelRatio: 0.2),
            category: .contentUpdate,
            capture: CompanionScreenCapture(
                imageData: Data(),
                label: "Built-in Display",
                isCursorScreen: true,
                displayWidthInPoints: 1440,
                displayHeightInPoints: 900,
                displayFrame: .zero,
                screenshotWidthInPixels: 1440,
                screenshotHeightInPixels: 900
            ),
            detectedAt: restraintContext.now
        )
        generator.handleWatchEvent(
            contentUpdateEvent,
            emit: { emittedUtterances.append($0) },
            queueForLater: { _ in }
        )

        XCTAssertTrue(emittedUtterances.isEmpty, "Only majorScreenChange should fire the observation nudge")
    }
}

// MARK: - Test doubles

@MainActor
private final class RecordingNudgeGenerator: PaceProactiveNudgeGenerator {
    let identifier: String
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init(identifier: String) {
        self.identifier = identifier
    }

    func start(
        emit: @escaping (PaceProactiveUtterance) -> Void,
        queueForLater: @escaping (PaceProactiveUtterance) -> Void
    ) {
        startCalls += 1
    }

    func stop() {
        stopCalls += 1
    }
}
