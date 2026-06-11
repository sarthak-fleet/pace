//
//  PaceTimerServiceTests.swift
//  leanring-buddyTests
//
//  Tests for the timer skill — duration parser, store persistence,
//  past-due partitioning, and the scheduler's fire callback. The
//  Scheduler tests skip the live Timer arming path (we don't want
//  to actually wait seconds inside a unit test) and exercise the
//  rehydration flow instead, which fires past-due timers on the
//  next runloop tick.
//

import XCTest
@testable import Pace

final class PaceTimerDurationParserTests: XCTestCase {
    func testPlainSecondsStringParsesToSeconds() {
        XCTAssertEqual(PaceTimerDurationParser.seconds(from: "180"), 180)
    }

    func testThreeMinutesParsesToOneEightyFiveSeconds() {
        XCTAssertEqual(PaceTimerDurationParser.seconds(from: "3 minutes"), 180)
        XCTAssertEqual(PaceTimerDurationParser.seconds(from: "3min"), 180)
        XCTAssertEqual(PaceTimerDurationParser.seconds(from: "3 m"), 180)
    }

    func testThirtySecondsParsesToThirty() {
        XCTAssertEqual(PaceTimerDurationParser.seconds(from: "30s"), 30)
        XCTAssertEqual(PaceTimerDurationParser.seconds(from: "30 seconds"), 30)
    }

    func testHoursParseToSeconds() {
        XCTAssertEqual(PaceTimerDurationParser.seconds(from: "2 hours"), 7200)
        XCTAssertEqual(PaceTimerDurationParser.seconds(from: "1h"), 3600)
    }

    func testMonthsRejectedToAvoidMinuteCollision() {
        // "1 month" should not be parsed as 1 minute. Returns nil; the
        // executor surfaces a validation error.
        XCTAssertNil(PaceTimerDurationParser.seconds(from: "1 month"))
    }

    func testEmptyAndGarbageReturnsNil() {
        XCTAssertNil(PaceTimerDurationParser.seconds(from: ""))
        XCTAssertNil(PaceTimerDurationParser.seconds(from: "soon"))
        XCTAssertNil(PaceTimerDurationParser.seconds(from: "0"))
        XCTAssertNil(PaceTimerDurationParser.seconds(from: "-5 minutes"))
    }
}

final class PaceTimerStoreTests: XCTestCase {
    private var temporaryDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-timer-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        super.tearDown()
    }

    private func makeStore() -> PaceTimerStore {
        PaceTimerStore(fileURL: temporaryDirectoryURL.appendingPathComponent("timers.json"))
    }

    func testEmptyStoreReturnsNoTimers() {
        let store = makeStore()
        XCTAssertEqual(store.load(), [])
    }

    func testSaveAndLoadRoundtripsTimers() throws {
        let store = makeStore()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let originalTimers = [
            PaceScheduledTimer(
                identifier: "abc",
                label: "tea",
                fireDate: fixedNow.addingTimeInterval(180),
                createdAt: fixedNow
            )
        ]
        try store.save(originalTimers)
        XCTAssertEqual(store.load(), originalTimers)
    }

    func testPartitionSplitsPastDueAndFuture() {
        let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)
        let pastDueTimer = PaceScheduledTimer(
            identifier: "past",
            label: "old",
            fireDate: referenceNow.addingTimeInterval(-10),
            createdAt: referenceNow.addingTimeInterval(-100)
        )
        let futureTimer = PaceScheduledTimer(
            identifier: "future",
            label: "soon",
            fireDate: referenceNow.addingTimeInterval(60),
            createdAt: referenceNow
        )
        let (pastDueTimers, stillScheduledTimers) = PaceTimerStore.partition(
            [pastDueTimer, futureTimer],
            relativeTo: referenceNow
        )
        XCTAssertEqual(pastDueTimers, [pastDueTimer])
        XCTAssertEqual(stillScheduledTimers, [futureTimer])
    }

    func testSpokenReminderTextUsesLabelOrFallback() {
        let withLabel = PaceScheduledTimer(
            identifier: "id1",
            label: "tea",
            fireDate: .distantFuture,
            createdAt: .distantPast
        )
        XCTAssertEqual(withLabel.spokenReminderText, "timer for tea just went off.")

        let withoutLabel = PaceScheduledTimer(
            identifier: "id2",
            label: "",
            fireDate: .distantFuture,
            createdAt: .distantPast
        )
        XCTAssertEqual(withoutLabel.spokenReminderText, "your timer just went off.")
    }
}

@MainActor
final class PaceTimerSchedulerTests: XCTestCase {
    private var temporaryFileURL: URL!

    override func setUp() {
        super.setUp()
        temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-scheduler-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryFileURL)
        super.tearDown()
    }

    func testSchedulePersistsTimer() throws {
        let store = PaceTimerStore(fileURL: temporaryFileURL)
        let scheduler = PaceTimerScheduler(store: store)
        _ = scheduler.schedule(label: "tea", durationInSeconds: 600)
        let persistedTimers = store.load()
        XCTAssertEqual(persistedTimers.count, 1)
        XCTAssertEqual(persistedTimers.first?.label, "tea")
    }

    func testRehydratePastDueTimerFiresOnCallback() async {
        let store = PaceTimerStore(fileURL: temporaryFileURL)
        let pastDueTimer = PaceScheduledTimer(
            identifier: "past",
            label: "expired",
            fireDate: Date().addingTimeInterval(-30),
            createdAt: Date().addingTimeInterval(-90)
        )
        try? store.save([pastDueTimer])

        let scheduler = PaceTimerScheduler(store: store)
        let fireExpectation = expectation(description: "past-due timer fires on rehydrate")
        scheduler.onFire = { spokenText in
            XCTAssertEqual(spokenText, "timer for expired just went off.")
            fireExpectation.fulfill()
        }
        scheduler.rehydrate()
        await fulfillment(of: [fireExpectation], timeout: 1.0)
        XCTAssertEqual(store.load(), [], "past-due timer should be removed from persistence")
    }
}
