//
//  PaceMorningBriefBuilderTests.swift
//  leanring-buddyTests
//
//  Unit tests for the pure deterministic morning-brief composer.
//

import XCTest
@testable import Pace

final class PaceMorningBriefBuilderTests: XCTestCase {

    private func fixedMorningDate() -> Date {
        // 2026-06-12 08:30 local. The brief itself doesn't render
        // `now` directly — `now` is just here so events that match
        // it can be rendered as today's events.
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 12
        components.hour = 8
        components.minute = 30
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    private func eventDate(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 12
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    // MARK: - Empty inputs

    func testEmptyInputsProducesClearMorningCopy() {
        let inputs = PaceMorningBriefInputs(now: fixedMorningDate())
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("good morning"))
        XCTAssertTrue(briefText.contains("your morning's clear"))
    }

    func testEmptyInputsWithFirstNameStillReadsCleanly() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            userFirstName: "Sam"
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("good morning, Sam"))
        XCTAssertTrue(briefText.contains("your morning's clear"))
    }

    // MARK: - Calendar-only

    func testCalendarOnlyBriefRendersOneEvent() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            todaysEvents: [
                CalendarBriefEvent(title: "Design review", startDate: eventDate(hour: 10, minute: 0), isAllDay: false)
            ]
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("one thing on the calendar today"))
        XCTAssertTrue(briefText.contains("Design review"))
        // Time clause renders via the user's current timezone; we
        // assert only that an "at <something>" phrase appears for the
        // single event so the test stays timezone-independent.
        XCTAssertTrue(briefText.contains("Design review at "))
        XCTAssertFalse(briefText.contains("unread"))
        XCTAssertFalse(briefText.contains("reminder"))
    }

    func testCalendarOnlyBriefPluralizesAndMentionsTopTwoEvents() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            todaysEvents: [
                CalendarBriefEvent(title: "Standup", startDate: eventDate(hour: 9, minute: 0), isAllDay: false),
                CalendarBriefEvent(title: "1:1 with Ben", startDate: eventDate(hour: 14, minute: 30), isAllDay: false),
                CalendarBriefEvent(title: "Demo prep", startDate: eventDate(hour: 16, minute: 0), isAllDay: false)
            ]
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("three things on the calendar today"))
        XCTAssertTrue(briefText.contains("Standup"))
        XCTAssertTrue(briefText.contains("1:1 with Ben"))
        // The third event is intentionally NOT mentioned — the brief
        // only renders the top two so it stays short.
        XCTAssertFalse(briefText.contains("Demo prep"))
    }

    func testAllDayEventGetsAllDayPhraseNotZeroHour() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            todaysEvents: [
                CalendarBriefEvent(title: "Offsite", startDate: eventDate(hour: 0, minute: 0), isAllDay: true)
            ]
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("Offsite all day"))
        XCTAssertFalse(briefText.contains("at 12:00"))
    }

    // MARK: - Mail-only

    func testMailOnlyBriefMentionsCountAndPluralizes() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            unreadMailCount: 1
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("one unread message waiting"))
        XCTAssertFalse(briefText.contains("messages waiting"))
    }

    func testMailWithTopSenderAndSubjectIncludesBoth() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            unreadMailCount: 4,
            topMailSender: "Tom",
            topMailSubject: "Q3 plan"
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("four unread messages waiting"))
        XCTAssertTrue(briefText.contains("including one from Tom about Q3 plan"))
    }

    // MARK: - Reminders-only

    func testRemindersOnlyBriefMentionsTopReminder() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            openRemindersDueToday: 2,
            topReminderTitle: "Send invoice",
            topReminderDueText: "at noon"
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("two reminders due today"))
        XCTAssertTrue(briefText.contains("the closest is Send invoice at noon"))
    }

    // MARK: - Yesterday-only

    func testYesterdayAppUsageRendersMinutesAndApp() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            yesterdayTopApp: "Xcode",
            yesterdayTopAppMinutes: 240
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("yesterday you spent 240 minutes in Xcode"))
    }

    func testWatchHighlightWithoutAppUsageStillRenders() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            yesterdayWatchHighlight: "in Figma"
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.contains("yesterday you were mostly in Figma"))
    }

    // MARK: - Full inputs

    func testFullInputsAssemblesAllClausesInOrder() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            userFirstName: "Sarthak",
            todaysEvents: [
                CalendarBriefEvent(title: "Standup", startDate: eventDate(hour: 9, minute: 0), isAllDay: false),
                CalendarBriefEvent(title: "Demo", startDate: eventDate(hour: 14, minute: 0), isAllDay: false)
            ],
            unreadMailCount: 3,
            topMailSender: "Lin",
            topMailSubject: "Beta launch",
            openRemindersDueToday: 1,
            topReminderTitle: "Pay rent",
            topReminderDueText: "at noon",
            yesterdayTopApp: "Xcode",
            yesterdayTopAppMinutes: 180,
            yesterdayWatchHighlight: "writing Swift"
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertTrue(briefText.hasPrefix("good morning, Sarthak."))
        XCTAssertTrue(briefText.contains("two things on the calendar today"))
        XCTAssertTrue(briefText.contains("Standup"))
        XCTAssertTrue(briefText.contains("Demo"))
        XCTAssertTrue(briefText.contains("three unread messages waiting"))
        XCTAssertTrue(briefText.contains("including one from Lin about Beta launch"))
        XCTAssertTrue(briefText.contains("one reminder due today"))
        XCTAssertTrue(briefText.contains("the closest is Pay rent at noon"))
        XCTAssertTrue(briefText.contains("yesterday you spent 180 minutes in Xcode"))
        XCTAssertTrue(briefText.contains("mostly writing Swift"))
    }

    func testZeroValuesAreOmitted() {
        let inputs = PaceMorningBriefInputs(
            now: fixedMorningDate(),
            todaysEvents: [],
            unreadMailCount: 0,
            openRemindersDueToday: 0
        )
        let briefText = PaceMorningBriefBuilder.build(inputs)

        XCTAssertFalse(briefText.contains("unread"))
        XCTAssertFalse(briefText.contains("reminders"))
        XCTAssertFalse(briefText.contains("calendar"))
        XCTAssertTrue(briefText.contains("your morning's clear"))
    }
}
