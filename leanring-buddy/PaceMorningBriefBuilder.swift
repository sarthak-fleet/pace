//
//  PaceMorningBriefBuilder.swift
//  leanring-buddy
//
//  Pure deterministic composer for the daily morning brief. Takes
//  typed inputs (calendar events, mail count, reminders, app-usage,
//  watch highlight) and returns a single spoken-ready paragraph.
//
//  Intentionally NOT an LLM call — keeps the brief cheap, predictable,
//  and unit-testable without any model. See PRD
//  docs/prds/morning-triage.md for the brief shape.
//

import Foundation

/// Compact calendar-event view consumed by the brief builder.
/// Kept separate from `PaceCalendarRetrievalEventSnapshot` so the
/// builder stays free of EventKit and easy to fake in tests.
struct CalendarBriefEvent: Equatable {
    let title: String
    let startDate: Date
    let isAllDay: Bool
}

/// Typed inputs for the deterministic brief composer. Each source is
/// optional / zeroable so the builder degrades gracefully when a
/// retrieval source is disabled or empty.
struct PaceMorningBriefInputs: Equatable {
    let now: Date
    let userFirstName: String?
    let todaysEvents: [CalendarBriefEvent]
    let unreadMailCount: Int
    let topMailSender: String?
    let topMailSubject: String?
    let openRemindersDueToday: Int
    let topReminderTitle: String?
    let topReminderDueText: String?
    let yesterdayTopApp: String?
    let yesterdayTopAppMinutes: Int?
    let yesterdayWatchHighlight: String?

    init(
        now: Date,
        userFirstName: String? = nil,
        todaysEvents: [CalendarBriefEvent] = [],
        unreadMailCount: Int = 0,
        topMailSender: String? = nil,
        topMailSubject: String? = nil,
        openRemindersDueToday: Int = 0,
        topReminderTitle: String? = nil,
        topReminderDueText: String? = nil,
        yesterdayTopApp: String? = nil,
        yesterdayTopAppMinutes: Int? = nil,
        yesterdayWatchHighlight: String? = nil
    ) {
        self.now = now
        self.userFirstName = userFirstName
        self.todaysEvents = todaysEvents
        self.unreadMailCount = unreadMailCount
        self.topMailSender = topMailSender
        self.topMailSubject = topMailSubject
        self.openRemindersDueToday = openRemindersDueToday
        self.topReminderTitle = topReminderTitle
        self.topReminderDueText = topReminderDueText
        self.yesterdayTopApp = yesterdayTopApp
        self.yesterdayTopAppMinutes = yesterdayTopAppMinutes
        self.yesterdayWatchHighlight = yesterdayWatchHighlight
    }
}

enum PaceMorningBriefBuilder {
    /// Composes the spoken-ready brief from typed inputs. Each clause
    /// is omitted when its source is empty/zero. If ALL sources are
    /// empty, returns a single calm sentence so the brief never feels
    /// broken.
    static func build(_ inputs: PaceMorningBriefInputs) -> String {
        let greeting = openingGreeting(firstName: inputs.userFirstName)

        var clauses: [String] = []

        if let calendarClause = calendarClause(events: inputs.todaysEvents, now: inputs.now) {
            clauses.append(calendarClause)
        }
        if let mailClause = mailClause(
            unreadCount: inputs.unreadMailCount,
            topSender: inputs.topMailSender,
            topSubject: inputs.topMailSubject
        ) {
            clauses.append(mailClause)
        }
        if let remindersClause = remindersClause(
            openCount: inputs.openRemindersDueToday,
            topTitle: inputs.topReminderTitle,
            topDueText: inputs.topReminderDueText
        ) {
            clauses.append(remindersClause)
        }
        if let yesterdayClause = yesterdayClause(
            topApp: inputs.yesterdayTopApp,
            topAppMinutes: inputs.yesterdayTopAppMinutes,
            watchHighlight: inputs.yesterdayWatchHighlight
        ) {
            clauses.append(yesterdayClause)
        }

        if clauses.isEmpty {
            return "\(greeting). your morning's clear."
        }

        return "\(greeting). " + clauses.joined(separator: " ")
    }

    // MARK: - Clause builders

    private static func openingGreeting(firstName: String?) -> String {
        let trimmedFirstName = firstName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedFirstName, !trimmedFirstName.isEmpty {
            return "good morning, \(trimmedFirstName)"
        }
        return "good morning"
    }

    private static func calendarClause(events: [CalendarBriefEvent], now: Date) -> String? {
        guard !events.isEmpty else { return nil }
        let pluralizedNoun = events.count == 1 ? "thing" : "things"
        var clause = "\(spelledNumber(events.count)) \(pluralizedNoun) on the calendar today"

        let firstEvent = events[0]
        clause += " — \(firstEvent.title) \(eventTimePhrase(firstEvent, now: now))"
        if events.count >= 2 {
            let secondEvent = events[1]
            clause += ", and \(secondEvent.title) \(eventTimePhrase(secondEvent, now: now))"
        }
        clause += "."
        return clause
    }

    private static func mailClause(unreadCount: Int, topSender: String?, topSubject: String?) -> String? {
        guard unreadCount > 0 else { return nil }
        let pluralizedNoun = unreadCount == 1 ? "message" : "messages"
        var clause = "\(spelledNumber(unreadCount)) unread \(pluralizedNoun) waiting"

        let trimmedSender = topSender?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubject = topSubject?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSender, !trimmedSender.isEmpty,
           let trimmedSubject, !trimmedSubject.isEmpty {
            clause += ", including one from \(trimmedSender) about \(trimmedSubject)"
        } else if let trimmedSender, !trimmedSender.isEmpty {
            clause += ", including one from \(trimmedSender)"
        }
        clause += "."
        return clause
    }

    private static func remindersClause(openCount: Int, topTitle: String?, topDueText: String?) -> String? {
        guard openCount > 0 else { return nil }
        let pluralizedNoun = openCount == 1 ? "reminder" : "reminders"
        var clause = "\(spelledNumber(openCount)) \(pluralizedNoun) due today"

        let trimmedTitle = topTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDue = topDueText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty,
           let trimmedDue, !trimmedDue.isEmpty {
            clause += ", the closest is \(trimmedTitle) \(trimmedDue)"
        } else if let trimmedTitle, !trimmedTitle.isEmpty {
            clause += ", the closest is \(trimmedTitle)"
        }
        clause += "."
        return clause
    }

    private static func yesterdayClause(
        topApp: String?,
        topAppMinutes: Int?,
        watchHighlight: String?
    ) -> String? {
        let trimmedTopApp = topApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHighlight = watchHighlight?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmedTopApp, !trimmedTopApp.isEmpty,
              let topAppMinutes, topAppMinutes > 0 else {
            // No app-usage signal — if we only have a watch highlight,
            // surface it on its own so the clause still adds value.
            if let trimmedHighlight, !trimmedHighlight.isEmpty {
                return "yesterday you were mostly \(trimmedHighlight)."
            }
            return nil
        }

        var clause = "yesterday you spent \(topAppMinutes) minute\(topAppMinutes == 1 ? "" : "s") in \(trimmedTopApp)"
        if let trimmedHighlight, !trimmedHighlight.isEmpty {
            clause += ", mostly \(trimmedHighlight)"
        }
        clause += "."
        return clause
    }

    // MARK: - Formatting helpers

    /// Spells small counts (1...9) so the brief reads naturally; falls
    /// back to digits for larger numbers. Keeps copy aligned with how
    /// the rest of the Pace TTS surface reads numbers.
    private static func spelledNumber(_ count: Int) -> String {
        switch count {
        case 1: return "one"
        case 2: return "two"
        case 3: return "three"
        case 4: return "four"
        case 5: return "five"
        case 6: return "six"
        case 7: return "seven"
        case 8: return "eight"
        case 9: return "nine"
        default: return "\(count)"
        }
    }

    /// Renders an event's time of day as "at <h:mm a>" — lowercased AM/PM
    /// so the brief feels like spoken English, not a calendar app.
    /// All-day events get a special phrase so we don't say "at 12 AM".
    private static func eventTimePhrase(_ event: CalendarBriefEvent, now: Date) -> String {
        if event.isAllDay {
            return "all day"
        }
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        let renderedTime = timeFormatter.string(from: event.startDate).lowercased()
        return "at \(renderedTime)"
    }
}
