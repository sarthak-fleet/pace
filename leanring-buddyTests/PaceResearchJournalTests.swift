//
//  PaceResearchJournalTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceResearchJournalTests {
    private func makeEntry(
        id: String = UUID().uuidString,
        recordedAt: Date,
        question: String = "what is a monad",
        answer: String = "a monad is a monoid in the category of endofunctors"
    ) -> PaceResearchJournalEntry {
        PaceResearchJournalEntry(
            id: id,
            recordedAt: recordedAt,
            question: question,
            answer: answer
        )
    }

    @Test func firstEntryCreatesDayBucketDocumentWithExpectedIdSourceAndTitle() async throws {
        var journal = PaceResearchJournal(rehydratingFrom: [], now: Date())
        let recordedAt = Date()
        let document = journal.record(makeEntry(recordedAt: recordedAt))

        let dayKey = PaceResearchJournal.dayFormatter.string(from: recordedAt)
        #expect(document?.id == "research-journal-\(dayKey)")
        #expect(document?.source == .researchHistory)
        #expect(document?.title == "Research history — \(dayKey)")
    }

    @Test func sameQuestionSameDayIsDeduplicated() async throws {
        var journal = PaceResearchJournal(rehydratingFrom: [], now: Date())
        let recordedAt = Date()
        #expect(journal.record(makeEntry(recordedAt: recordedAt, question: "what is rust")) != nil)
        // Same question, same day (differing only in whitespace/case) is suppressed.
        #expect(journal.record(makeEntry(recordedAt: recordedAt.addingTimeInterval(60), question: "What is Rust")) == nil)
        // A different question the same day is recorded.
        #expect(journal.record(makeEntry(recordedAt: recordedAt.addingTimeInterval(120), question: "what is go")) != nil)
        #expect(journal.entriesReverseChronological().count == 2)
    }

    @Test func bucketsOlderThanThirtyDaysAreDropped() async throws {
        var journal = PaceResearchJournal(rehydratingFrom: [], now: Date())
        let now = Date()
        for dayOffset in 0..<35 {
            _ = journal.record(makeEntry(
                recordedAt: now.addingTimeInterval(TimeInterval(-dayOffset) * 86_400),
                question: "question for day \(dayOffset)"
            ))
        }
        let documents = journal.allDocuments(now: now)
        #expect(documents.count == PaceResearchJournal.maximumDayBucketCount)
    }

    @Test func storedEntryCapDropsOldestEntries() async throws {
        var journal = PaceResearchJournal(rehydratingFrom: [], now: Date())
        let now = Date()
        // All same-day so retention won't drop buckets; the entry cap does.
        for entryIndex in 0..<(PaceResearchJournal.maximumStoredEntryCount + 10) {
            _ = journal.record(makeEntry(
                recordedAt: now.addingTimeInterval(TimeInterval(entryIndex)),
                question: "question number \(entryIndex)"
            ))
        }
        let entries = journal.entriesReverseChronological()
        #expect(entries.count == PaceResearchJournal.maximumStoredEntryCount)
        // The oldest entries were dropped: question 0 is gone, the newest remains.
        #expect(!entries.contains { $0.question == "question number 0" })
        #expect(entries.contains { $0.question == "question number \(PaceResearchJournal.maximumStoredEntryCount + 9)" })
    }

    @Test func rehydrationPreservesEntriesAcrossRestart() async throws {
        let now = Date()
        var firstJournal = PaceResearchJournal(rehydratingFrom: [], now: now)
        _ = firstJournal.record(makeEntry(recordedAt: now, question: "first question", answer: "first answer"))
        let secondDocument = firstJournal.record(makeEntry(
            recordedAt: now.addingTimeInterval(60),
            question: "second question",
            answer: "second answer"
        ))
        let persistedDocuments = [try #require(secondDocument)]

        var rehydratedJournal = PaceResearchJournal(rehydratingFrom: persistedDocuments, now: now)
        let entries = rehydratedJournal.entriesReverseChronological()
        #expect(entries.count == 2)
        #expect(entries[0].question == "second question")
        #expect(entries[0].answer == "second answer")
        #expect(entries[1].question == "first question")

        // A new entry after rehydrate joins the same-day bucket instead of
        // clobbering it.
        let thirdDocument = rehydratedJournal.record(makeEntry(
            recordedAt: now.addingTimeInterval(120),
            question: "third question"
        ))
        #expect(thirdDocument != nil)
        #expect(rehydratedJournal.entriesReverseChronological().count == 3)
    }

    @Test func removeEntryDropsSingleEntryAndKeepsBucketWhenOthersRemain() async throws {
        let now = Date()
        var journal = PaceResearchJournal(rehydratingFrom: [], now: now)
        _ = journal.record(makeEntry(id: "keep-1", recordedAt: now, question: "keep one"))
        _ = journal.record(makeEntry(id: "drop-1", recordedAt: now.addingTimeInterval(60), question: "drop one"))

        let removal = journal.removeEntry(withId: "drop-1")
        #expect(removal.didRemove)
        #expect(removal.changedDocument != nil)
        let remaining = journal.entriesReverseChronological()
        #expect(remaining.count == 1)
        #expect(remaining[0].id == "keep-1")
    }

    @Test func removeOnlyEntryDropsBucketAndReturnsNilDocument() async throws {
        let now = Date()
        var journal = PaceResearchJournal(rehydratingFrom: [], now: now)
        _ = journal.record(makeEntry(id: "solo", recordedAt: now, question: "solo question"))

        let removal = journal.removeEntry(withId: "solo")
        #expect(removal.didRemove)
        #expect(removal.changedDocument == nil)
        #expect(journal.entriesReverseChronological().isEmpty)
    }

    @Test func removeAbsentEntryReportsNoRemoval() async throws {
        var journal = PaceResearchJournal(rehydratingFrom: [], now: Date())
        _ = journal.record(makeEntry(id: "present", recordedAt: Date()))
        let removal = journal.removeEntry(withId: "not-there")
        #expect(!removal.didRemove)
    }

    @Test func answerAndQuestionWithDelimitersAndNewlinesRoundTrip() async throws {
        let now = Date()
        var journal = PaceResearchJournal(rehydratingFrom: [], now: now)
        let recorded = journal.record(makeEntry(
            recordedAt: now,
            question: "compare A | B\nversus C",
            answer: "line one\nline two | with pipe"
        ))
        let persisted = [try #require(recorded)]
        var rehydrated = PaceResearchJournal(rehydratingFrom: persisted, now: now)
        let entries = rehydrated.entriesReverseChronological()
        #expect(entries.count == 1)
        // Newlines collapsed to spaces, pipes escaped to slashes — but the
        // text survives the day-document round-trip intact.
        #expect(entries[0].question == "compare A / B versus C")
        #expect(entries[0].answer == "line one line two / with pipe")
    }
}
