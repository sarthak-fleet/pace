//
//  PaceMeetingNotesJournal.swift
//  leanring-buddy
//
//  Per-meeting journal of synthesized meeting notes, persisted as
//  retrieval documents so "what did we decide in standup?" / "did we
//  agree on the launch date?" questions answer from local history.
//  Mirrors `PaceScreenWatchJournal`'s shape but uses one document per
//  meeting (not day-bucketed) and a 30-day retention window (longer
//  than the 7-day watch journal — meeting decisions are referenced
//  weeks later). Source `.meetingNotes`. Isolation-free so every rule
//  is unit-testable.
//
//  See docs/prds/on-device-meeting-notes.md for the full spec.
//

import Foundation

nonisolated struct PaceMeetingNotesJournal {
    static let retentionDays: Int = 30
    static let documentIdPrefix = "meeting-notes"

    private struct MeetingEntry {
        let meetingID: UUID
        let startedAt: Date
        let endedAt: Date
        let title: String
        let summary: String
        let actionItems: [PaceMeetingActionItem]
        let decisions: [String]
        let synthesisFailed: Bool
        let recordedAt: Date
    }

    private var entriesByMeetingID: [UUID: MeetingEntry] = [:]

    init(rehydratingFrom persistedDocuments: [PaceRetrievalDocument], now: Date) {
        for document in persistedDocuments where document.source == .meetingNotes {
            guard let entry = Self.parseEntry(from: document) else { continue }
            entriesByMeetingID[entry.meetingID] = entry
        }
        pruneOldEntries(now: now)
    }

    /// Records the meeting notes and returns the upserted retrieval
    /// document. Returns nil only if the notes are somehow empty (no
    /// summary, no action items, no decisions, no transcript) — in that
    /// case there is nothing to index.
    mutating func record(_ notes: PaceMeetingNotes, now: Date = Date()) -> PaceRetrievalDocument? {
        let entry = MeetingEntry(
            meetingID: notes.meetingID,
            startedAt: notes.startedAt,
            endedAt: notes.endedAt,
            title: notes.title,
            summary: notes.summary,
            actionItems: notes.actionItems,
            decisions: notes.decisions,
            synthesisFailed: notes.synthesisFailed,
            recordedAt: now
        )
        entriesByMeetingID[notes.meetingID] = entry
        return Self.document(for: entry)
    }

    /// Full current document set after pruning entries older than the
    /// retention window.
    mutating func allDocuments(now: Date) -> [PaceRetrievalDocument] {
        pruneOldEntries(now: now)
        let sortedEntries = entriesByMeetingID.values.sorted { $0.startedAt < $1.startedAt }
        return sortedEntries.map(Self.document(for:))
    }

    // MARK: - Pruning

    private mutating func pruneOldEntries(now: Date) {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400)
        entriesByMeetingID = entriesByMeetingID.filter { _, entry in
            entry.startedAt >= cutoff
        }
    }

    // MARK: - Document building

    private static func document(for entry: MeetingEntry) -> PaceRetrievalDocument {
        let retrievalText = renderRetrievalText(
            title: entry.title,
            summary: entry.summary,
            actionItems: entry.actionItems,
            decisions: entry.decisions,
            synthesisFailed: entry.synthesisFailed
        )
        return PaceRetrievalDocument(
            id: documentId(for: entry.meetingID),
            source: .meetingNotes,
            title: "Meeting notes — \(entry.title) — \(Self.dayFormatter.string(from: entry.startedAt))",
            text: retrievalText,
            modifiedAt: entry.recordedAt,
            permissionScope: "meeting-notes"
        )
    }

    static func documentId(for meetingID: UUID) -> String {
        "\(documentIdPrefix)-\(meetingID.uuidString)"
    }

    /// Renders the summary + action items + decisions as natural
    /// language so BM25 lexical retrieval can match "what did we
    /// decide" / "action items from standup" / "did we agree on the
    /// launch date". Only document text is indexed.
    static func renderRetrievalText(for notes: PaceMeetingNotes) -> String {
        renderRetrievalText(
            title: notes.title,
            summary: notes.summary,
            actionItems: notes.actionItems,
            decisions: notes.decisions,
            synthesisFailed: notes.synthesisFailed
        )
    }

    private static func renderRetrievalText(
        title: String,
        summary: String,
        actionItems: [PaceMeetingActionItem],
        decisions: [String],
        synthesisFailed: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("Meeting notes: \(title).")

        if synthesisFailed {
            lines.append("Notes synthesis failed; the raw transcript was saved as the summary.")
        }

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            lines.append("Summary: \(trimmedSummary)")
        }

        if !actionItems.isEmpty {
            lines.append("Action items:")
            for item in actionItems {
                var line = "- \(item.text)"
                if let owner = item.owner, !owner.isEmpty {
                    line += " (owner: \(owner))"
                }
                if let due = item.due, !due.isEmpty {
                    line += " (due: \(due))"
                }
                lines.append(line)
            }
        }

        if !decisions.isEmpty {
            lines.append("Decisions:")
            for decision in decisions {
                lines.append("- \(decision)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Rehydration parsing

    /// Rebuilds a `MeetingEntry` from a persisted retrieval document.
    /// The document text is the natural-language rendering produced by
    /// `renderRetrievalText`; we parse it back into structured fields.
    /// The meeting ID is recovered from the document id.
    private static func parseEntry(from document: PaceRetrievalDocument) -> MeetingEntry? {
        guard document.id.hasPrefix("\(documentIdPrefix)-") else { return nil }
        let uuidString = String(document.id.dropFirst("\(documentIdPrefix)-".count))
        guard let meetingID = UUID(uuidString: uuidString) else { return nil }

        // Parse the title from the document title:
        // "Meeting notes — <title> — <dayKey>"
        let titleComponents = document.title.components(separatedBy: " — ")
        guard titleComponents.count >= 3, titleComponents[0] == "Meeting notes" else {
            return nil
        }
        let title = titleComponents[1...].dropLast().joined(separator: " — ")
        let dayKey = titleComponents.last ?? ""
        let startedAt = dayFormatter.date(from: dayKey) ?? Date()

        // Parse the text body back into summary / action items / decisions.
        let textLines = document.text.split(separator: "\n").map(String.init)
        var summary = ""
        var actionItems: [PaceMeetingActionItem] = []
        var decisions: [String] = []
        var synthesisFailed = false
        var currentSection: Section? = nil

        for line in textLines {
            if line.hasPrefix("Meeting notes:") {
                continue
            }
            if line.contains("Notes synthesis failed") {
                synthesisFailed = true
                continue
            }
            if line.hasPrefix("Summary:") {
                summary = String(line.dropFirst("Summary: ".count))
                currentSection = nil
                continue
            }
            if line == "Action items:" {
                currentSection = .actionItems
                continue
            }
            if line == "Decisions:" {
                currentSection = .decisions
                continue
            }
            if line.hasPrefix("- ") {
                let content = String(line.dropFirst(2))
                switch currentSection {
                case .actionItems:
                    actionItems.append(parseActionItem(from: content))
                case .decisions:
                    decisions.append(content)
                case .none:
                    break
                }
            }
        }

        return MeetingEntry(
            meetingID: meetingID,
            startedAt: startedAt,
            endedAt: startedAt,
            title: title,
            summary: summary,
            actionItems: actionItems,
            decisions: decisions,
            synthesisFailed: synthesisFailed,
            recordedAt: document.modifiedAt ?? startedAt
        )
    }

    private enum Section {
        case actionItems
        case decisions
    }

    /// Parses an action item line like "Review the PR (owner: them) (due: tomorrow)"
    /// back into a `PaceMeetingActionItem`.
    private static func parseActionItem(from content: String) -> PaceMeetingActionItem {
        var text = content
        var owner: String?
        var due: String?

        // Extract (owner: ...) suffix.
        if let ownerRange = text.range(of: " (owner: ", options: .backwards) {
            let afterOwner = text[ownerRange.upperBound...]
            if let closeParen = afterOwner.firstIndex(of: ")") {
                owner = String(afterOwner[afterOwner.startIndex..<closeParen])
                text = String(text[..<ownerRange.lowerBound])
            }
        }

        // Extract (due: ...) suffix.
        if let dueRange = text.range(of: " (due: ", options: .backwards) {
            let afterDue = text[dueRange.upperBound...]
            if let closeParen = afterDue.firstIndex(of: ")") {
                due = String(afterDue[afterDue.startIndex..<closeParen])
                text = String(text[..<dueRange.lowerBound])
            }
        }

        return PaceMeetingActionItem(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            owner: owner?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            due: due?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    // MARK: - Formatters

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - String helper

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
