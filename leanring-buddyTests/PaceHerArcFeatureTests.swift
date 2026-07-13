//
//  PaceHerArcFeatureTests.swift
//  leanring-buddyTests
//

import XCTest
@testable import Pace

private final class HerArcNoOpEmbeddingClient: PaceTextEmbedding {
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0, 0] }
    }
}

final class PaceRestraintGateTests: XCTestCase {
    func testPushToTalkBypassesGate() {
        let now = Date()
        let context = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: now,
            lastEpisodicRecallAt: now,
            lastUserInputAt: now,
            frontmostAppBundleIdentifier: "us.zoom.xos",
            isOnActiveCall: true,
            wakeWordConfidence: 0.1,
            intent: .unknown,
            proactiveSource: .userPushToTalk,
            profile: .balanced
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .speak)
    }

    func testActiveCallQueuesProactiveSpeechUntilIdle() {
        let context = PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: "us.zoom.xos",
            isOnActiveCall: false,
            wakeWordConfidence: 0.9,
            intent: .pureKnowledge,
            proactiveSource: .wakeWord,
            profile: .balanced
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .queueUntilIdle(reason: "active call"))
    }

    func testWeakWakeWordDoesNotReprompt() {
        let context = PaceRestraintContext(
            now: Date(),
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: 0.5,
            intent: .pureKnowledge,
            proactiveSource: .wakeWord,
            profile: .balanced
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .stayQuiet(reason: "wake word confidence below threshold"))
    }

    func testRecentInputQueuesUntilIdle() {
        let now = Date()
        let context = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: now.addingTimeInterval(-1),
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .balanced
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .queueUntilIdle(reason: "recent user input"))
    }

    // MARK: - Profile-tuned cooldowns
    //
    // Each test below sets the previous proactive utterance 11 minutes
    // in the past so the .balanced profile (10-minute cooldown) is
    // just past its threshold, the .talkative profile (5-minute
    // cooldown) is well past, and the .reserved profile (30-minute
    // cooldown) is still inside the cooldown window.

    func testTalkativeProfileSpeaksJustAfterFiveMinutes() {
        let now = Date()
        let context = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: now.addingTimeInterval(-11 * 60),
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .talkative
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .speak)
    }

    func testBalancedProfileSpeaksJustAfterTenMinutes() {
        let now = Date()
        let context = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: now.addingTimeInterval(-11 * 60),
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .balanced
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .speak)
    }

    func testReservedProfileStaysQuietBeforeThirtyMinutes() {
        let now = Date()
        let context = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: now.addingTimeInterval(-11 * 60),
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .reserved
        )

        XCTAssertEqual(PaceRestraintGate.decide(context), .stayQuiet(reason: "proactive cooldown"))
    }

    /// The PRD-rename equivalent of `testReservedProfileStaysQuiet
    /// BeforeThirtyMinutes` — pins the explicit 30-minute floor under
    /// `.reserved` so a future refactor of the cooldown table can't
    /// silently move it.
    func testRestraintGateUnderReservedProfileEnforces30MinProactiveCooldown() {
        let now = Date()
        let justInsideThirtyMinuteWindow = now.addingTimeInterval(-29 * 60)
        let justPastThirtyMinuteWindow = now.addingTimeInterval(-31 * 60)

        let stillInsideCooldown = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: justInsideThirtyMinuteWindow,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .reserved
        )

        XCTAssertEqual(
            PaceRestraintGate.decide(stillInsideCooldown),
            .stayQuiet(reason: "proactive cooldown")
        )

        let pastCooldown = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: justPastThirtyMinuteWindow,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: nil,
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .reserved
        )

        XCTAssertEqual(PaceRestraintGate.decide(pastCooldown), .speak)
    }

    /// Recent user input under .talkative / .balanced should return
    /// .queueUntilIdle so the nudge fires once the user pauses;
    /// under .reserved the same context should fall back to the
    /// pre-profile "stay quiet, drop the nudge" behavior.
    func testRestraintGateReturnsQueueUntilIdleWhenInputRecentAndProfileNotReserved() {
        let now = Date()

        for profileUnderTest in [PaceProactivityProfile.talkative, .balanced] {
            let context = PaceRestraintContext(
                now: now,
                lastProactiveUtteranceAt: nil,
                lastEpisodicRecallAt: nil,
                lastUserInputAt: now.addingTimeInterval(-1),
                frontmostAppBundleIdentifier: nil,
                isOnActiveCall: false,
                wakeWordConfidence: nil,
                intent: .screenDescription,
                proactiveSource: .watchNudge,
                profile: profileUnderTest
            )

            XCTAssertEqual(
                PaceRestraintGate.decide(context),
                .queueUntilIdle(reason: "recent user input"),
                "Profile \(profileUnderTest) should queue, not stay quiet, on recent input"
            )
        }

        let reservedContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            lastUserInputAt: now.addingTimeInterval(-1),
            frontmostAppBundleIdentifier: nil,
            isOnActiveCall: false,
            wakeWordConfidence: nil,
            intent: .screenDescription,
            proactiveSource: .watchNudge,
            profile: .reserved
        )

        XCTAssertEqual(
            PaceRestraintGate.decide(reservedContext),
            .stayQuiet(reason: "recent user input")
        )
    }
}

@MainActor
final class PaceProactiveQueueDrainTests: XCTestCase {
    func testExpiredQueuedUtteranceIsDiscardedWithoutBlockingNextEntry() {
        let companionManager = CompanionManager()
        let now = Date()
        companionManager.enqueueProactiveUtterance(PaceProactiveUtterance(
            spokenText: "expired companion observation",
            source: .companionEvent,
            confidence: 0.9,
            relevanceWindowExpiresAt: now.addingTimeInterval(-1)
        ))
        companionManager.enqueueProactiveUtterance(PaceProactiveUtterance(
            spokenText: "still relevant reminder",
            source: .backgroundReminder,
            confidence: 0.9,
            relevanceWindowExpiresAt: now.addingTimeInterval(60)
        ))

        companionManager.drainProactiveQueueIfIdle(now: now)

        XCTAssertEqual(
            companionManager.proactiveUtteranceQueueSnapshot().map(\.spokenText),
            ["still relevant reminder"]
        )
    }

    func testCompanionSpeechOptOutRemovesOnlyCompanionQueueEntries() {
        let companionManager = CompanionManager()
        companionManager.enqueueProactiveUtterance(PaceProactiveUtterance(
            spokenText: "companion observation",
            source: .companionEvent,
            confidence: 0.9,
            relevanceWindowExpiresAt: nil
        ))
        companionManager.enqueueProactiveUtterance(PaceProactiveUtterance(
            spokenText: "calendar reminder",
            source: .backgroundReminder,
            confidence: 0.9,
            relevanceWindowExpiresAt: nil
        ))

        companionManager.proactivityPipeline.removeQueuedProactiveUtterances(
            from: .companionEvent
        )

        XCTAssertEqual(
            companionManager.proactiveUtteranceQueueSnapshot().map(\.source),
            [.backgroundReminder]
        )
    }

    func testProactiveQueueDrainsOldestFirstWhenIdleConditionsRestore() async {
        // Build a real CompanionManager so the queue / drain interplay
        // is exercised end-to-end rather than against a hand-rolled
        // double. We don't `start()` it — only the queue API matters
        // here, and start() would spin up CGEvent taps + screen capture
        // which an XCTest shouldn't touch.
        let companionManager = CompanionManager()

        let firstUtterance = PaceProactiveUtterance(
            spokenText: "first queued nudge",
            source: .watchNudge,
            confidence: 0.8,
            relevanceWindowExpiresAt: nil
        )
        let secondUtterance = PaceProactiveUtterance(
            spokenText: "second queued nudge",
            source: .watchNudge,
            confidence: 0.8,
            relevanceWindowExpiresAt: nil
        )
        let thirdUtterance = PaceProactiveUtterance(
            spokenText: "third queued nudge",
            source: .watchNudge,
            confidence: 0.8,
            relevanceWindowExpiresAt: nil
        )

        companionManager.enqueueProactiveUtterance(firstUtterance)
        companionManager.enqueueProactiveUtterance(secondUtterance)
        companionManager.enqueueProactiveUtterance(thirdUtterance)

        XCTAssertEqual(
            companionManager.proactiveUtteranceQueueSnapshot().map { $0.spokenText },
            ["first queued nudge", "second queued nudge", "third queued nudge"]
        )

        // Capacity cap: a fourth utterance evicts the oldest.
        let fourthUtterance = PaceProactiveUtterance(
            spokenText: "fourth queued nudge",
            source: .watchNudge,
            confidence: 0.8,
            relevanceWindowExpiresAt: nil
        )
        companionManager.enqueueProactiveUtterance(fourthUtterance)

        XCTAssertEqual(
            companionManager.proactiveUtteranceQueueSnapshot().map { $0.spokenText },
            ["second queued nudge", "third queued nudge", "fourth queued nudge"],
            "Oldest entry should be evicted on overflow"
        )

        // Simulate "idle restored": no recent input, not on a call,
        // voice state is .idle (CompanionManager default). A single
        // drain pass should consume exactly the oldest entry.
        companionManager.drainProactiveQueueIfIdle(now: Date())

        // The drain task speaks via TTS asynchronously; the queue
        // mutation is synchronous and happens before the speak Task
        // is dispatched, so the snapshot reflects removal immediately.
        XCTAssertEqual(
            companionManager.proactiveUtteranceQueueSnapshot().map { $0.spokenText },
            ["third queued nudge", "fourth queued nudge"],
            "Drain should remove only the oldest entry per pass"
        )
        XCTAssertNotNil(
            companionManager.proactivityPipeline.lastProactiveUtteranceAt,
            "Queued delivery must stamp the shared proactive cooldown"
        )
    }
}

final class PaceAlwaysListeningCommandParserTests: XCTestCase {
    func testStartAndStopCommandsParse() {
        XCTAssertEqual(PaceAlwaysListeningCommandParser.parse("turn on always listening"), .start)
        XCTAssertEqual(PaceAlwaysListeningCommandParser.parse("pace stop always listening"), .stop)
    }

    func testNonCommandsReturnNil() {
        XCTAssertNil(PaceAlwaysListeningCommandParser.parse("what is always listening"))
    }
}

final class PaceWakeWordSpotterTests: XCTestCase {
    func testSpotterOnlyFiresWhenEnabledAndConfident() {
        let spotter = PaceWakeWordSpotter()

        XCTAssertFalse(spotter.detectWakeWord(in: "hey pace", confidence: 1.0))

        spotter.setEnabled(true)
        XCTAssertFalse(spotter.detectWakeWord(in: "hey pace", confidence: 0.4))
        XCTAssertTrue(spotter.detectWakeWord(in: "hey pace can you hear me", confidence: 0.9))
        XCTAssertTrue(spotter.detectWakeWord(in: "pace listen", confidence: 0.9))
        XCTAssertFalse(spotter.detectWakeWord(in: "space bar", confidence: 0.9))
    }
}

final class PaceBargeInVADTests: XCTestCase {
    func testSustainedSpeechFires() {
        var detector = PaceBargeInVAD(configuration: PaceBargeInVADConfiguration(
            speechLevelThreshold: 0.2,
            sustainedSpeechDuration: 0.6,
            maximumInterSampleGap: 0.3
        ))
        let start = Date()

        XCTAssertFalse(detector.observe(normalizedLevel: 0.25, at: start))
        XCTAssertFalse(detector.observe(normalizedLevel: 0.25, at: start.addingTimeInterval(0.2)))
        XCTAssertFalse(detector.observe(normalizedLevel: 0.25, at: start.addingTimeInterval(0.4)))
        XCTAssertTrue(detector.observe(normalizedLevel: 0.25, at: start.addingTimeInterval(0.61)))
    }

    func testLowEnergyDoesNotFire() {
        var detector = PaceBargeInVAD()
        let start = Date()

        XCTAssertFalse(detector.observe(normalizedLevel: 0.02, at: start))
        XCTAssertFalse(detector.observe(normalizedLevel: 0.02, at: start.addingTimeInterval(1)))
    }
}

@MainActor
final class PaceEpisodicMemoryTests: XCTestCase {
    func testDurableHealthFactExtracts() {
        let extractor = PaceEpisodicPatternFactExtractor(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let facts = extractor.extractFacts(from: "my mom is in the hospital with pneumonia", sourceTurnId: "turn-1")

        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.subject, "user's mom")
        XCTAssertEqual(facts.first?.predicate, "is in")
        XCTAssertEqual(facts.first?.value, "the hospital")
        XCTAssertGreaterThanOrEqual(facts.first?.confidence ?? 0, 0.7)
    }

    func testEphemeralAndActionTurnsDoNotExtract() {
        let extractor = PaceEpisodicPatternFactExtractor()

        XCTAssertEqual(extractor.extractFacts(from: "I'm hungry"), [])
        XCTAssertEqual(extractor.extractFacts(from: "open Safari"), [])
    }

    func testFactsBecomeRetrievableDocuments() {
        // The #health fact is by policy a sensitive topic — it
        // stays out of the LOCAL CONTEXT block unless the user
        // opts in. Flip the opt-in for this test so the retrieval
        // mechanics get exercised end to end. Restored on teardown
        // so other tests inherit the default-off behavior.
        let originalInjectSensitivePreference = PaceUserPreferencesStore
            .bool(.injectSensitiveEpisodicTopics, default: false)
        PaceUserPreferencesStore.setBool(true, for: .injectSensitiveEpisodicTopics)
        defer {
            PaceUserPreferencesStore.setBool(
                originalInjectSensitivePreference,
                for: .injectSensitiveEpisodicTopics
            )
        }

        let store = PaceInMemoryRetrievalStore()
        let retriever = PaceLocalRetriever(
            store: store,
            appliesPersistedSourcePreferences: false,
            embeddingClient: HerArcNoOpEmbeddingClient()
        )
        let fact = PaceEpisodicFact(
            identifier: "episodic-test",
            extractedAt: Date(),
            subject: "user's mom",
            predicate: "is in",
            value: "the hospital",
            confidence: 0.9,
            expiresAt: nil,
            topicHashtags: ["#family", "#health"],
            sourceTurnId: "turn-1"
        )

        retriever.recordEpisodicFacts([fact])
        let context = retriever.localContextBlock(for: PaceRetrievalQuery(text: "how is my mom doing hospital"))

        XCTAssertTrue(context?.contains("Episodic memory") == true)
        XCTAssertTrue(context?.contains("hospital") == true)
    }
}

final class PaceProactiveNudgeDecisionTests: XCTestCase {
    func testFocusFatigueRequiresLongActiveSession() {
        let now = Date()
        XCTAssertNil(PaceFocusFatigueNudgeDecision.utterance(
            appName: "Figma",
            continuousForegroundSeconds: 20 * 60,
            lastUserInputAt: now,
            now: now
        ))

        let utterance = PaceFocusFatigueNudgeDecision.utterance(
            appName: "Figma",
            continuousForegroundSeconds: 50 * 60,
            lastUserInputAt: now.addingTimeInterval(-60),
            now: now
        )
        XCTAssertEqual(utterance?.source, .watchNudge)
        XCTAssertTrue(utterance?.spokenText.contains("Figma") == true)
    }

    func testCalendarNudgeFiltersByKeywordAndLeadTime() {
        let now = Date()
        XCTAssertNil(PaceCalendarPreMeetingNudgeDecision.utterance(
            eventTitle: "Take dog out",
            startsInSeconds: 300,
            now: now
        ))

        XCTAssertNotNil(PaceCalendarPreMeetingNudgeDecision.utterance(
            eventTitle: "Design review",
            startsInSeconds: 300,
            now: now
        ))
    }

    func testWatchObservationNudgeTriggersOnBuildFailure() {
        let utterance = PaceWatchModeObservationNudgeDecision.utterance(
            screenDescription: "terminal with build failed",
            ocrText: "",
            now: Date()
        )

        XCTAssertEqual(utterance?.source, .watchNudge)
    }

    /// Wave 1b: the gate-aware `evaluate(...)` shape returns
    /// `.queueUntilIdle` (with the utterance forwarded so the
    /// framework can park it) when the user is on an active call.
    /// The framework reads `evaluation.utterance` and routes through
    /// `queueForLater` — never `emit` — so nothing actually speaks
    /// during a Zoom call. This pins the fix for the original bug
    /// (proactive nudges emitting BEFORE consulting the gate).
    func testFocusFatigueGeneratorRespectsRestraintGateActiveCall() {
        let now = Date()
        let restraintContext = PaceRestraintContext(
            now: now,
            lastProactiveUtteranceAt: nil,
            lastEpisodicRecallAt: nil,
            // Last input was 60 seconds ago — the pure helper's
            // 10-minute input recency check passes so a candidate
            // utterance forms, letting the gate's active-call check
            // do the actual work the test is asserting on.
            lastUserInputAt: now.addingTimeInterval(-60),
            frontmostAppBundleIdentifier: "us.zoom.xos",
            isOnActiveCall: true,
            wakeWordConfidence: nil,
            intent: .pureKnowledge,
            proactiveSource: .watchNudge,
            profile: .balanced
        )

        let evaluation = PaceFocusFatigueNudgeDecision.evaluate(
            appName: "Figma",
            continuousForegroundSeconds: 60 * 60,
            restraintContext: restraintContext
        )

        XCTAssertEqual(evaluation.decision, .queueUntilIdle(reason: "active call"))
        XCTAssertNotNil(evaluation.utterance, "Active call should queue (not drop) so the nudge fires once the call ends")
    }

    /// Wave 1b: when the user typed within the last three seconds the
    /// gate returns `.queueUntilIdle` for non-reserved profiles. The
    /// generator's evaluator must return the utterance alongside the
    /// queue decision so the framework parks it.
    func testCalendarPreMeetingGeneratorQueuesWhenInputRecent() {
        let now = Date()
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

        let evaluation = PaceCalendarPreMeetingNudgeDecision.evaluate(
            eventTitle: "Design review",
            startsInSeconds: 240,
            restraintContext: restraintContext
        )

        XCTAssertEqual(evaluation.decision, .queueUntilIdle(reason: "recent user input"))
        XCTAssertEqual(evaluation.utterance?.source, .backgroundReminder)
    }

    /// Wave 1b: under `.reserved` the same recent-input context
    /// returns `.stayQuiet` and the utterance is dropped.
    func testCalendarPreMeetingGeneratorStaysQuietUnderReservedWithRecentInput() {
        let now = Date()
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
            profile: .reserved
        )

        let evaluation = PaceCalendarPreMeetingNudgeDecision.evaluate(
            eventTitle: "Design review",
            startsInSeconds: 240,
            restraintContext: restraintContext
        )

        XCTAssertEqual(evaluation.decision, .stayQuiet(reason: "recent user input"))
        XCTAssertNil(evaluation.utterance)
    }

    /// Watch-mode generator: gate `.speak` path returns the utterance
    /// for the framework to forward to TTS.
    func testWatchModeObservationGeneratorSpeaksWhenGateAllows() {
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

        let evaluation = PaceWatchModeObservationNudgeDecision.evaluate(
            screenDescription: "terminal with build failed",
            ocrText: "",
            restraintContext: restraintContext
        )

        XCTAssertEqual(evaluation.decision, .speak)
        XCTAssertEqual(evaluation.utterance?.source, .watchNudge)
    }
}

final class PaceFlowReplayTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-flow-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        super.tearDown()
    }

    func testFlowStoreRoundTripsAndRedactsSecureText() throws {
        let store = PaceFlowStore(directoryURL: temporaryDirectoryURL)
        let flow = PaceRecordedFlow(
            name: "Morning Standup",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            steps: [
                .activateApp(bundleIdentifier: "com.apple.mail"),
                .typeText(text: "secret", secure: true),
                .keyShortcut(key: "cmd+s"),
            ]
        )

        try store.save(flow)

        let loadedFlow = try XCTUnwrap(store.load(named: "Morning Standup"))
        XCTAssertEqual(loadedFlow.name, "Morning Standup")
        XCTAssertEqual(loadedFlow.steps.count, 3)

        let rawJSON = try String(
            contentsOf: temporaryDirectoryURL.appendingPathComponent("morning-standup.json"),
            encoding: .utf8
        )
        XCTAssertFalse(rawJSON.contains("secret"))
        XCTAssertTrue(rawJSON.contains("<password redacted>"))
    }

    func testFlowCommandParser() {
        XCTAssertEqual(
            PaceFlowCommandParser.parse("remember this flow as morning standup"),
            .startRecording(name: "morning standup")
        )
        XCTAssertEqual(PaceFlowCommandParser.parse("stop recording"), .stopRecording)
        XCTAssertEqual(PaceFlowCommandParser.parse("run morning standup"), .run(name: "morning standup"))
        XCTAssertEqual(PaceFlowCommandParser.parse("delete the flow morning standup"), .delete(name: "morning standup"))
    }

    func testFlowRunDefersSkillUtterancesToTheSkillParser() {
        // Regression (found in live testing 2026-07-12): the bare "run "
        // prefix swallowed EVERY skill-run utterance before the skill parser
        // (which runs later in the agent loop) could see it, so Pace answered
        // "i couldn't find a flow named the cat search skill" and taught
        // skills could never be run by voice.
        XCTAssertNil(PaceFlowCommandParser.parse("run the cat search skill"))
        XCTAssertNil(PaceFlowCommandParser.parse("run cat search skill"))
        XCTAssertNil(PaceFlowCommandParser.parse("do the standup notes skill"))
        // The skill parser DOES claim the deferred utterance.
        if case .run(let slug, _)? = PaceSkillCommandParser.parse("run the cat search skill") {
            XCTAssertEqual(slug, "cat-search")
        } else {
            XCTFail("skill parser should claim 'run the cat search skill'")
        }
        // Plain flow runs (no "skill" mention) are untouched.
        XCTAssertEqual(PaceFlowCommandParser.parse("run email zero"), .run(name: "email zero"))
    }

    func testSkillRunResolverMatchesSpokenNameToLongerTaughtSlug() {
        // A skill taught as "cat search: open Safari" persists as slug
        // `cat-search-open-safari`, but the user says "run the cat search
        // skill" (slug `cat-search`). Exact match wins; otherwise a UNIQUE
        // prefix/contains match resolves; ambiguity returns nil.
        let taughtSkill = PaceSkillFile(
            name: "Cat search: open Safari",
            slug: "cat-search-open-safari",
            description: "Cat search",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Open Safari", toolCall: nil)],
            notes: nil
        )
        let unrelatedSkill = PaceSkillFile(
            name: "Standup notes",
            slug: "standup-notes",
            description: "Standup",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Open Notes", toolCall: nil)],
            notes: nil
        )
        let skills = [taughtSkill, unrelatedSkill]
        XCTAssertEqual(
            PaceSkillLoader.resolveSkillForRunRequest(
                requestedSlug: "cat-search", requestedName: "cat search", in: skills
            )?.slug,
            "cat-search-open-safari"
        )
        // Exact slug still wins.
        XCTAssertEqual(
            PaceSkillLoader.resolveSkillForRunRequest(
                requestedSlug: "standup-notes", requestedName: "standup notes", in: skills
            )?.slug,
            "standup-notes"
        )
        // Ambiguous fuzzy request (two skills share the prefix) returns nil.
        let secondCatSkill = PaceSkillFile(
            name: "Cat search: open Chrome",
            slug: "cat-search-open-chrome",
            description: "Cat search 2",
            category: "custom",
            requiredPreferences: [],
            trigger: nil,
            steps: [PaceSkillStep(instruction: "Open Chrome", toolCall: nil)],
            notes: nil
        )
        XCTAssertNil(
            PaceSkillLoader.resolveSkillForRunRequest(
                requestedSlug: "cat-search", requestedName: "cat search",
                in: [taughtSkill, secondCatSkill]
            )
        )
    }

    @MainActor
    func testFlowRecorderProducesFlowAndReplayPlannerPausesBeforeSend() async throws {
        // Wave 3a renamed `PaceFlowRecorder` from a passive struct into
        // a @MainActor class backed by a real CGEventTap. The replay
        // planner is unaffected — we use a hand-built `PaceRecordedFlow`
        // here so this test still pins the "pause before send"
        // heuristic without needing to drive the live tap.
        let flow = PaceRecordedFlow(
            name: "mail draft",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            steps: [
                .activateApp(bundleIdentifier: "com.apple.mail"),
                .axPress(rolePath: ["window", "button"], label: "Send"),
            ]
        )

        XCTAssertEqual(flow.steps.count, 2)
        XCTAssertEqual(
            PaceFlowReplayPlanner.replayObservations(for: flow).last,
            "ready to send - say go ahead"
        )
    }

    func testFlowToolsParseThroughActionLayer() {
        let parseResult = PaceActionTagParser.parseActions(from: """
        recording.
        <tool_calls>
        [
          [
            {"tool":"record_flow","name":"morning standup"},
            {"tool":"run_flow","name":"morning standup"}
          ]
        ]
        </tool_calls>
        """)

        XCTAssertEqual(parseResult.actions.count, 2)
        guard case .recordFlow(let recordRequest) = parseResult.actions[0] else {
            XCTFail("Expected record flow action")
            return
        }
        XCTAssertEqual(recordRequest.name, "morning standup")

        guard case .runFlow(let runRequest) = parseResult.actions[1] else {
            XCTFail("Expected run flow action")
            return
        }
        XCTAssertEqual(runRequest.name, "morning standup")
    }
}

// MARK: - PaceFlowReplayOutcome contract

/// The outcome enum is the only piece of state the replayer surfaces
/// past the `play(...)` boundary. Pinning its `Equatable` cases here
/// keeps `CompanionManager.speakFlowReplayOutcome(...)` honest: any
/// shape change forces the narration switch to update at compile time.
final class PaceFlowReplayOutcomeContractTests: XCTestCase {

    func testOutcomeCasesCompareCorrectly() {
        XCTAssertEqual(PaceFlowReplayOutcome.completed, .completed)
        XCTAssertNotEqual(PaceFlowReplayOutcome.completed, .userCancelled)
        XCTAssertEqual(
            PaceFlowReplayOutcome.stoppedBeforeSendStep(stepIndex: 2),
            .stoppedBeforeSendStep(stepIndex: 2)
        )
        XCTAssertNotEqual(
            PaceFlowReplayOutcome.stoppedBeforeSendStep(stepIndex: 2),
            .stoppedBeforeSendStep(stepIndex: 3)
        )
        XCTAssertEqual(
            PaceFlowReplayOutcome.failedToFindTarget(stepIndex: 1, axLabel: "Send"),
            .failedToFindTarget(stepIndex: 1, axLabel: "Send")
        )
        XCTAssertNotEqual(
            PaceFlowReplayOutcome.failedToFindTarget(stepIndex: 1, axLabel: "Send"),
            .failedToFindTarget(stepIndex: 1, axLabel: "Submit")
        )
    }

    func testSendRestrictionHeuristicFiresOnLastSendStep() {
        // The replayer relies on PaceFlowReplayPlanner.shouldPauseBeforeSend
        // for its hard halt. Pin the contract that "Send" matches as
        // the LAST step but not as a mid-flow step.
        let sendStep = PaceRecordedStep.axPress(rolePath: ["AXButton"], label: "Send")
        XCTAssertTrue(
            PaceFlowReplayPlanner.shouldPauseBeforeSend(step: sendStep, isLastStep: true)
        )
        XCTAssertFalse(
            PaceFlowReplayPlanner.shouldPauseBeforeSend(step: sendStep, isLastStep: false)
        )
    }

    func testSendRestrictionHeuristicMatchesReplyAndPost() {
        for label in ["Reply", "Post", "Submit", "send"] {
            let step = PaceRecordedStep.axPress(rolePath: ["AXButton"], label: label)
            XCTAssertTrue(
                PaceFlowReplayPlanner.shouldPauseBeforeSend(step: step, isLastStep: true),
                "Expected last-step send heuristic to match label \(label)"
            )
        }
    }
}
