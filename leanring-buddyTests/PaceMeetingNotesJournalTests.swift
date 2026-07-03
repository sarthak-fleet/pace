//
//  PaceMeetingNotesJournalTests.swift
//  leanring-buddyTests
//
//  Tests for the per-meeting notes journal. Mirrors the screen-watch
//  journal test shape: record → document upserted with `.meetingNotes`
//  source, rehydration across a simulated restart, 30-day retention
//  pruning, disabled source → no-op (via the retriever).
//

import Foundation
import Testing

@testable import Pace

struct PaceMeetingNotesJournalTests {
    private func makeNotes(
        meetingID: UUID = UUID(),
        startedAt: Date = Date(),
        title: String = "Standup",
        summary: String = "Discussed the launch and assigned tasks.",
        actionItems: [PaceMeetingActionItem] = [
            PaceMeetingActionItem(text: "Review the PR", owner: "Alice", due: "tomorrow"),
            PaceMeetingActionItem(text: "Ship the feature", owner: "Bob", due: "Friday")
        ],
        decisions: [String] = ["Use the new API design", "Postpone the docs update"],
        synthesisFailed: Bool = false
    ) -> PaceMeetingNotes {
        PaceMeetingNotes(
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(600),
            title: title,
            transcript: "you: Let's ship by Friday.\nthem: Agreed.",
            turns: [],
            summary: summary,
            actionItems: actionItems,
            decisions: decisions,
            synthesisFailed: synthesisFailed
        )
    }

    @Test func recordCreatesDocumentWithMeetingNotesSourceAndExpectedId() async throws {
        var journal = PaceMeetingNotesJournal(rehydratingFrom: [], now: Date())
        let meetingID = UUID()
        let startedAt = Date()
        let notes = makeNotes(meetingID: meetingID, startedAt: startedAt)
        let document = journal.record(notes)

        #expect(document?.id == "meeting-notes-\(meetingID.uuidString)")
        #expect(document?.source == .meetingNotes)
        #expect(document?.title == "Meeting notes — Standup — \(PaceMeetingNotesJournal.dayFormatter.string(from: startedAt))")
        #expect(document?.permissionScope == "meeting-notes")
    }

    @Test func documentTextContainsSummaryActionItemsAndDecisionsAsNaturalLanguage() async throws {
        var journal = PaceMeetingNotesJournal(rehydratingFrom: [], now: Date())
        let document = journal.record(makeNotes())

        let text = try #require(document?.text)
        #expect(text.contains("Summary: Discussed the launch and assigned tasks."))
        #expect(text.contains("Action items:"))
        #expect(text.contains("- Review the PR (owner: Alice) (due: tomorrow)"))
        #expect(text.contains("- Ship the feature (owner: Bob) (due: Friday)"))
        #expect(text.contains("Decisions:"))
        #expect(text.contains("- Use the new API design"))
        #expect(text.contains("- Postpone the docs update"))
    }

    @Test func synthesisFailedNoteRendersFailureMessageInDocumentText() async throws {
        var journal = PaceMeetingNotesJournal(rehydratingFrom: [], now: Date())
        let document = journal.record(makeNotes(
            summary: "raw transcript fallback",
            actionItems: [],
            decisions: [],
            synthesisFailed: true
        ))

        let text = try #require(document?.text)
        #expect(text.contains("Notes synthesis failed; the raw transcript was saved as the summary."))
        #expect(text.contains("Summary: raw transcript fallback"))
    }

    @Test func rehydrationPreservesNotesAcrossRestart() async throws {
        let now = Date()
        let meetingID = UUID()
        let startedAt = now.addingTimeInterval(-300)

        var firstJournal = PaceMeetingNotesJournal(rehydratingFrom: [], now: now)
        let firstDocument = firstJournal.record(makeNotes(
            meetingID: meetingID,
            startedAt: startedAt,
            title: "Sprint planning",
            summary: "Planned sprint 12.",
            actionItems: [PaceMeetingActionItem(text: "Write tests", owner: "Carol", due: "Monday")],
            decisions: ["Sprint goal is the notes feature"]
        ))
        let persistedDocuments = [try #require(firstDocument)]

        // Simulate a restart: rehydrate from persisted documents.
        var rehydratedJournal = PaceMeetingNotesJournal(rehydratingFrom: persistedDocuments, now: now)
        let allDocuments = rehydratedJournal.allDocuments(now: now)

        #expect(allDocuments.count == 1)
        #expect(allDocuments.first?.id == "meeting-notes-\(meetingID.uuidString)")
        #expect(allDocuments.first?.text.contains("Planned sprint 12.") == true)
        #expect(allDocuments.first?.text.contains("Write tests") == true)
        #expect(allDocuments.first?.text.contains("Sprint goal is the notes feature") == true)
    }

    @Test func rehydrationAllowsRecordingNewMeetingWithoutClobberingOld() async throws {
        let now = Date()
        let firstMeetingID = UUID()
        let startedAt = now.addingTimeInterval(-600)

        var firstJournal = PaceMeetingNotesJournal(rehydratingFrom: [], now: now)
        let firstDocument = firstJournal.record(makeNotes(
            meetingID: firstMeetingID,
            startedAt: startedAt,
            title: "First meeting"
        ))
        let persistedDocuments = [try #require(firstDocument)]

        // Restart + record a second meeting.
        var rehydratedJournal = PaceMeetingNotesJournal(rehydratingFrom: persistedDocuments, now: now)
        let secondMeetingID = UUID()
        let secondDocument = rehydratedJournal.record(makeNotes(
            meetingID: secondMeetingID,
            startedAt: now,
            title: "Second meeting",
            summary: "Follow-up sync."
        ))

        #expect(secondDocument?.id == "meeting-notes-\(secondMeetingID.uuidString)")
        let allDocuments = rehydratedJournal.allDocuments(now: now)
        #expect(allDocuments.count == 2)
        #expect(allDocuments.contains { $0.id == "meeting-notes-\(firstMeetingID.uuidString)" })
        #expect(allDocuments.contains { $0.id == "meeting-notes-\(secondMeetingID.uuidString)" })
    }

    @Test func entriesOlderThanThirtyDaysArePruned() async throws {
        let now = Date()
        var journal = PaceMeetingNotesJournal(rehydratingFrom: [], now: now)

        // Record a meeting 40 days ago — should be pruned.
        let oldMeetingID = UUID()
        _ = journal.record(makeNotes(
            meetingID: oldMeetingID,
            startedAt: now.addingTimeInterval(-40 * 86_400)
        ))

        // Record a meeting 20 days ago — should survive.
        let recentMeetingID = UUID()
        _ = journal.record(makeNotes(
            meetingID: recentMeetingID,
            startedAt: now.addingTimeInterval(-20 * 86_400)
        ))

        // Record a meeting today — should survive.
        let todayMeetingID = UUID()
        _ = journal.record(makeNotes(
            meetingID: todayMeetingID,
            startedAt: now
        ))

        let documents = journal.allDocuments(now: now)
        #expect(documents.count == 2)
        #expect(!documents.contains { $0.id == "meeting-notes-\(oldMeetingID.uuidString)" })
        #expect(documents.contains { $0.id == "meeting-notes-\(recentMeetingID.uuidString)" })
        #expect(documents.contains { $0.id == "meeting-notes-\(todayMeetingID.uuidString)" })
    }

    @Test func recordingSameMeetingIDReplacesExistingDocument() async throws {
        var journal = PaceMeetingNotesJournal(rehydratingFrom: [], now: Date())
        let meetingID = UUID()
        let startedAt = Date()

        _ = journal.record(makeNotes(
            meetingID: meetingID,
            startedAt: startedAt,
            title: "Original title",
            summary: "Original summary."
        ))
        let updatedDocument = journal.record(makeNotes(
            meetingID: meetingID,
            startedAt: startedAt,
            title: "Updated title",
            summary: "Updated summary."
        ))

        let allDocuments = journal.allDocuments(now: Date())
        #expect(allDocuments.count == 1)
        #expect(updatedDocument?.title.contains("Updated title") == true)
        #expect(allDocuments.first?.text.contains("Updated summary.") == true)
        #expect(!allDocuments.first!.text.contains("Original summary."))
    }

    @Test func emptyNotesStillProduceDocumentWithTitle() async throws {
        var journal = PaceMeetingNotesJournal(rehydratingFrom: [], now: Date())
        let document = journal.record(makeNotes(
            summary: "",
            actionItems: [],
            decisions: []
        ))

        let text = try #require(document?.text)
        #expect(text.contains("Meeting notes: Standup."))
        #expect(!text.contains("Summary:"))
        #expect(!text.contains("Action items:"))
        #expect(!text.contains("Decisions:"))
    }

    // MARK: - Retriever integration (disabled source → no-op)

    @Test func disabledMeetingNotesSourceSkipsRecording() async throws {
        let store = PaceInMemoryRetrievalStore()
        let retriever = PaceLocalRetriever(
            store: store,
            appliesPersistedSourcePreferences: false
        )
        retriever.setSourceEnabled(false, for: .meetingNotes)
        retriever.recordMeetingNotes(makeNotes())
        #expect(store.documents(withSource: .meetingNotes).isEmpty)
    }

    @Test func recordedMeetingNotesAreRetrievableByWhatDidWeDecideQuery() async throws {
        let retriever = PaceLocalRetriever(
            store: PaceInMemoryRetrievalStore(),
            appliesPersistedSourcePreferences: false
        )
        retriever.recordMeetingNotes(makeNotes(
            title: "Standup",
            summary: "We discussed the launch date and agreed to ship Friday.",
            actionItems: [PaceMeetingActionItem(text: "Review the PR", owner: "Alice", due: "tomorrow")],
            decisions: ["Ship the feature by Friday"]
        ))

        let contextBlock = retriever.localContextBlock(
            for: PaceRetrievalQuery(text: "what did we decide in the standup launch date")
        )
        #expect(contextBlock?.contains("Meeting notes") == true)
        #expect(contextBlock?.contains("Ship the feature by Friday") == true)
    }
}
