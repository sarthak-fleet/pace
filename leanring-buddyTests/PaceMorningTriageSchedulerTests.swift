//
//  PaceMorningTriageSchedulerTests.swift
//  leanring-buddyTests
//
//  Tests for the @MainActor morning-brief scheduler. We never let a
//  real Timer fire here — `handleScheduledFire()` is driven directly
//  with an injected clock so the assertions stay deterministic.
//

import XCTest
@testable import Pace

@MainActor
private final class RecordingTTSClient: BuddyTTSClient {
    private(set) var spokenTexts: [String] = []
    var isPlaying: Bool { false }

    func speakText(_ text: String) async throws {
        spokenTexts.append(text)
    }

    func stopPlayback() {}
}

@MainActor
final class PaceMorningTriageSchedulerTests: XCTestCase {

    // MARK: - Helpers

    private func weekdayMorningDate(hour: Int = 8, minute: Int = 30) -> Date {
        // 2026-06-12 is a Friday → weekday in tests.
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 12
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    private func saturdayMorningDate(hour: Int = 8, minute: Int = 30) -> Date {
        // 2026-06-13 is a Saturday.
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 13
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    private func sundayMorningDate(hour: Int = 8, minute: Int = 30) -> Date {
        // 2026-06-14 is a Sunday.
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 14
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    private func calendarPST() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }

    /// Convenience factory — keeps each test focused on its scenario
    /// without re-declaring the seven init parameters every time.
    private func makeScheduler(
        currentTime: Date,
        inputs: PaceMorningBriefInputs? = nil,
        restraintDecision: PaceRestraintDecision = .speak,
        tts: RecordingTTSClient,
        paceHistoryRecorder: ((String, String, Date) -> Void)? = nil
    ) -> PaceMorningTriageScheduler {
        let resolvedInputs = inputs ?? PaceMorningBriefInputs(now: currentTime)
        return PaceMorningTriageScheduler(
            retriever: nil,
            ttsClient: tts,
            inputsProvider: { _ in resolvedInputs },
            restraintContextProvider: { context in
                // Build a context shape consistent with restraintDecision.
                // The gate is deterministic — only the morning-brief
                // factors that matter for this test are active-call
                // (controlled via bundle identifier) and intent.
                switch restraintDecision {
                case .speak:
                    return PaceRestraintContext(
                        now: context.now,
                        lastProactiveUtteranceAt: nil,
                        lastEpisodicRecallAt: nil,
                        lastUserInputAt: nil,
                        frontmostAppBundleIdentifier: "com.apple.Xcode",
                        isOnActiveCall: false,
                        wakeWordConfidence: nil,
                        intent: .pureKnowledge,
                        proactiveSource: .morningTriage
                    )
                case .stayQuiet(_):
                    return PaceRestraintContext(
                        now: context.now,
                        lastProactiveUtteranceAt: nil,
                        lastEpisodicRecallAt: nil,
                        lastUserInputAt: nil,
                        frontmostAppBundleIdentifier: "us.zoom.xos",
                        isOnActiveCall: true,
                        wakeWordConfidence: nil,
                        intent: .pureKnowledge,
                        proactiveSource: .morningTriage
                    )
                case .queueUntilIdle(_):
                    return PaceRestraintContext(
                        now: context.now,
                        lastProactiveUtteranceAt: nil,
                        lastEpisodicRecallAt: nil,
                        lastUserInputAt: context.now.addingTimeInterval(-1),
                        frontmostAppBundleIdentifier: nil,
                        isOnActiveCall: false,
                        wakeWordConfidence: nil,
                        intent: .pureKnowledge,
                        proactiveSource: .morningTriage
                    )
                }
            },
            currentTimeProvider: { currentTime },
            calendar: calendarPST(),
            paceHistoryRecorder: paceHistoryRecorder
        )
    }

    // MARK: - Speak path (weekday, no restraint)

    func testWeekdayFireSpeaksBriefAndMarksDelivered() async {
        let now = weekdayMorningDate()
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(
            currentTime: now,
            inputs: PaceMorningBriefInputs(
                now: now,
                userFirstName: nil,
                todaysEvents: [],
                unreadMailCount: 2
            ),
            restraintDecision: .speak,
            tts: tts
        )

        await scheduler.handleScheduledFire()

        XCTAssertEqual(tts.spokenTexts.count, 1)
        XCTAssertTrue(tts.spokenTexts.first?.contains("good morning") == true)
        XCTAssertTrue(tts.spokenTexts.first?.contains("two unread messages waiting") == true)
        XCTAssertNotNil(scheduler.lastBriefDeliveredAt)
        XCTAssertNil(scheduler.pendingMorningBriefCard)
    }

    // MARK: - Weekend skip

    func testSaturdayFireDoesNotSpeak() async {
        let now = saturdayMorningDate()
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(currentTime: now, tts: tts)

        await scheduler.handleScheduledFire()

        XCTAssertTrue(tts.spokenTexts.isEmpty)
        XCTAssertNil(scheduler.lastBriefDeliveredAt)
        XCTAssertNil(scheduler.pendingMorningBriefCard)
    }

    func testSundayFireDoesNotSpeak() async {
        let now = sundayMorningDate()
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(currentTime: now, tts: tts)

        await scheduler.handleScheduledFire()

        XCTAssertTrue(tts.spokenTexts.isEmpty)
        XCTAssertNil(scheduler.lastBriefDeliveredAt)
    }

    // MARK: - Restraint paths

    func testStayQuietRouteParksBriefOnPendingCardInsteadOfSpeaking() async {
        let now = weekdayMorningDate()
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(
            currentTime: now,
            restraintDecision: .stayQuiet(reason: "test"),
            tts: tts
        )

        await scheduler.handleScheduledFire()

        XCTAssertTrue(tts.spokenTexts.isEmpty)
        XCTAssertNotNil(scheduler.pendingMorningBriefCard)
        XCTAssertNotNil(scheduler.lastBriefDeliveredAt)
    }

    func testQueueUntilIdleAlsoParksOnPendingCard() async {
        let now = weekdayMorningDate()
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(
            currentTime: now,
            restraintDecision: .queueUntilIdle(reason: "test"),
            tts: tts
        )

        await scheduler.handleScheduledFire()

        XCTAssertTrue(tts.spokenTexts.isEmpty)
        XCTAssertNotNil(scheduler.pendingMorningBriefCard)
    }

    func testDismissPendingCardClearsIt() async {
        let now = weekdayMorningDate()
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(
            currentTime: now,
            restraintDecision: .stayQuiet(reason: "test"),
            tts: tts
        )

        await scheduler.handleScheduledFire()
        XCTAssertNotNil(scheduler.pendingMorningBriefCard)

        scheduler.dismissPendingCard()
        XCTAssertNil(scheduler.pendingMorningBriefCard)
    }

    // MARK: - Same-day double-fire suppression

    func testTwoFiresOnSameDayOnlySpeakOnce() async {
        let now = weekdayMorningDate()
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(currentTime: now, tts: tts)

        await scheduler.handleScheduledFire()
        await scheduler.handleScheduledFire()

        XCTAssertEqual(tts.spokenTexts.count, 1)
    }

    // MARK: - deliverNowForTesting (preview)

    func testDeliverNowForTestingSpeaksRegardlessOfWeekend() async {
        let now = saturdayMorningDate()
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(currentTime: now, tts: tts)

        await scheduler.deliverNowForTesting()

        XCTAssertEqual(tts.spokenTexts.count, 1)
        XCTAssertTrue(tts.spokenTexts.first?.contains("good morning") == true)
    }

    func testDeliverNowForTestingSpeaksRegardlessOfRestraint() async {
        let now = weekdayMorningDate()
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(
            currentTime: now,
            restraintDecision: .stayQuiet(reason: "test"),
            tts: tts
        )

        await scheduler.deliverNowForTesting()

        XCTAssertEqual(tts.spokenTexts.count, 1)
        // Preview should NOT queue a card — it's a synchronous user-
        // initiated speak action.
        XCTAssertNil(scheduler.pendingMorningBriefCard)
    }

    // MARK: - paceHistory recording

    func testFireRecordsBriefIntoPaceHistory() async {
        let now = weekdayMorningDate()
        let tts = RecordingTTSClient()
        var recorderInvocations: [(String, String, Date)] = []
        let scheduler = makeScheduler(
            currentTime: now,
            tts: tts,
            paceHistoryRecorder: { userTranscript, assistantResponse, recordedAt in
                recorderInvocations.append((userTranscript, assistantResponse, recordedAt))
            }
        )

        await scheduler.handleScheduledFire()

        XCTAssertEqual(recorderInvocations.count, 1)
        XCTAssertEqual(recorderInvocations.first?.0, "morning brief")
        XCTAssertTrue(recorderInvocations.first?.1.contains("good morning") == true)
    }

    // MARK: - nextFireDateAfter

    func testNextFireDateSkipsSaturdayAndSunday() {
        // Friday morning 9:00 → next 08:30 fire is Monday, not Saturday.
        let fridayMidMorning = weekdayMorningDate(hour: 9, minute: 0)
        let tts = RecordingTTSClient()
        let scheduler = makeScheduler(currentTime: fridayMidMorning, tts: tts)
        scheduler.setFireTime(hourOfDay: 8, minuteOfHour: 30)

        let nextFireDate = scheduler.nextFireDateAfter(fridayMidMorning)
        let weekdayComponent = calendarPST().component(.weekday, from: nextFireDate ?? Date())

        // 2 = Monday in Calendar's weekday numbering.
        XCTAssertEqual(weekdayComponent, 2)
    }
}
