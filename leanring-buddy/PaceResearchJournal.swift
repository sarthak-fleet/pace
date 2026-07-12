//
//  PaceResearchJournal.swift
//  leanring-buddy
//
//  Pure day-bucketed journal of past research turns, persisted as
//  retrieval documents so "what did I research about X?" questions can be
//  answered from local history AND the user can browse their past research
//  in Settings → Memory. One rolling document per day keeps the BM25
//  chunker cheap and retention enforceable with source-wide replaces.
//  Isolation-free so every rule is unit-testable — mirrors
//  PaceScreenWatchJournal / PaceAppUsageJournal.
//

import Foundation

nonisolated struct PaceResearchJournalEntry: Equatable {
    let id: String
    let recordedAt: Date
    let question: String
    let answer: String
}

nonisolated struct PaceResearchJournal {
    /// Cap on stored entries across all day buckets. When exceeded the
    /// oldest entries are dropped — keeps the browsable list bounded even
    /// inside the retention window.
    static let maximumStoredEntryCount = 100
    static let maximumDayBucketCount = 30
    static let maximumQuestionCharacterCount = 300
    static let maximumAnswerCharacterCount = 1_200
    static let documentIdPrefix = "research-journal"

    private struct JournalLine {
        let id: String
        let recordedAt: Date
        let question: String
        let answer: String

        var renderedText: String {
            let timeOfDay = PaceResearchJournal.timeFormatter.string(from: recordedAt)
            return "\(id) | \(timeOfDay) | \(question) | \(answer)"
        }
    }

    private struct DayBucket {
        let dayKey: String
        var lines: [JournalLine]
    }

    private var bucketsByDayKey: [String: DayBucket] = [:]

    init(rehydratingFrom persistedDocuments: [PaceRetrievalDocument], now: Date) {
        for document in persistedDocuments where document.source == .researchHistory {
            guard document.id.hasPrefix("\(Self.documentIdPrefix)-") else { continue }
            let dayKey = String(document.id.dropFirst("\(Self.documentIdPrefix)-".count))
            guard Self.dayFormatter.date(from: dayKey) != nil else { continue }

            let lines = document.text
                .split(separator: "\n")
                .compactMap { Self.parseLine(String($0), dayKey: dayKey) }
            guard !lines.isEmpty else { continue }
            bucketsByDayKey[dayKey] = DayBucket(dayKey: dayKey, lines: lines)
        }
        pruneOldDayBuckets(now: now)
        enforceStoredEntryCap()
    }

    /// Records the research turn and returns the changed day-bucket
    /// document, or nil when the entry was suppressed as a same-day
    /// duplicate question.
    mutating func record(_ entry: PaceResearchJournalEntry) -> PaceRetrievalDocument? {
        let sanitizedQuestion = Self.sanitizeForLineFormat(entry.question)
        let sanitizedAnswer = Self.answerExcerpt(from: entry.answer)
        guard !sanitizedQuestion.isEmpty, !sanitizedAnswer.isEmpty else { return nil }

        let dayKey = Self.dayFormatter.string(from: entry.recordedAt)
        var bucket = bucketsByDayKey[dayKey] ?? DayBucket(dayKey: dayKey, lines: [])

        // Dedupe: the same question already researched on this day is
        // suppressed so a re-asked question doesn't create a second row.
        let normalizedQuestion = Self.normalizedForDuplicateComparison(sanitizedQuestion)
        let alreadyRecordedToday = bucket.lines.contains { existingLine in
            Self.normalizedForDuplicateComparison(existingLine.question) == normalizedQuestion
        }
        guard !alreadyRecordedToday else { return nil }

        bucket.lines.append(JournalLine(
            id: entry.id,
            recordedAt: entry.recordedAt,
            question: sanitizedQuestion,
            answer: sanitizedAnswer
        ))
        bucketsByDayKey[dayKey] = bucket
        enforceStoredEntryCap()

        // The cap may have dropped the day bucket entirely (all its lines
        // were the oldest). Only return a document when the bucket survives.
        guard let survivingBucket = bucketsByDayKey[dayKey] else { return nil }
        return Self.document(for: survivingBucket)
    }

    /// Full current document set after pruning buckets older than the
    /// retention window and enforcing the stored-entry cap.
    mutating func allDocuments(now: Date) -> [PaceRetrievalDocument] {
        pruneOldDayBuckets(now: now)
        enforceStoredEntryCap()
        return bucketsByDayKey.keys.sorted().map { document(for: bucketsByDayKey[$0]!) }
    }

    /// Reverse-chronological view of every stored entry, for the browsable
    /// "Past research" roster in Settings → Memory.
    func entriesReverseChronological() -> [PaceResearchJournalEntry] {
        let allEntries = bucketsByDayKey.values.flatMap { bucket in
            bucket.lines.map { line in
                PaceResearchJournalEntry(
                    id: line.id,
                    recordedAt: line.recordedAt,
                    question: line.question,
                    answer: line.answer
                )
            }
        }
        return allEntries.sorted { firstEntry, secondEntry in
            firstEntry.recordedAt > secondEntry.recordedAt
        }
    }

    /// Removes the entry with the given id and returns the affected day
    /// bucket's rebuilt document (or nil when the whole bucket became
    /// empty and was dropped). Returns nil overall when the id was absent.
    mutating func removeEntry(withId entryId: String) -> (changedDocument: PaceRetrievalDocument?, didRemove: Bool) {
        for (dayKey, bucket) in bucketsByDayKey {
            guard bucket.lines.contains(where: { $0.id == entryId }) else { continue }
            var updatedBucket = bucket
            updatedBucket.lines.removeAll { $0.id == entryId }
            if updatedBucket.lines.isEmpty {
                bucketsByDayKey.removeValue(forKey: dayKey)
                return (nil, true)
            }
            bucketsByDayKey[dayKey] = updatedBucket
            return (Self.document(for: updatedBucket), true)
        }
        return (nil, false)
    }

    // MARK: - Pruning

    private mutating func pruneOldDayBuckets(now: Date) {
        let sortedDayKeys = bucketsByDayKey.keys.sorted()
        guard sortedDayKeys.count > Self.maximumDayBucketCount else { return }
        for dayKeyToDrop in sortedDayKeys.dropLast(Self.maximumDayBucketCount) {
            bucketsByDayKey.removeValue(forKey: dayKeyToDrop)
        }
    }

    /// Drops the oldest individual entries until the total is within the
    /// stored-entry cap, then removes any day bucket left empty.
    private mutating func enforceStoredEntryCap() {
        var totalEntryCount = bucketsByDayKey.values.reduce(0) { $0 + $1.lines.count }
        guard totalEntryCount > Self.maximumStoredEntryCount else { return }

        // Oldest day first, oldest line first within each day.
        for dayKey in bucketsByDayKey.keys.sorted() {
            guard totalEntryCount > Self.maximumStoredEntryCount else { break }
            guard var bucket = bucketsByDayKey[dayKey] else { continue }
            bucket.lines.sort { $0.recordedAt < $1.recordedAt }
            while totalEntryCount > Self.maximumStoredEntryCount, !bucket.lines.isEmpty {
                bucket.lines.removeFirst()
                totalEntryCount -= 1
            }
            if bucket.lines.isEmpty {
                bucketsByDayKey.removeValue(forKey: dayKey)
            } else {
                bucketsByDayKey[dayKey] = bucket
            }
        }
    }

    // MARK: - Document building

    private func document(for bucket: DayBucket) -> PaceRetrievalDocument {
        Self.document(for: bucket)
    }

    private static func document(for bucket: DayBucket) -> PaceRetrievalDocument {
        let sortedLines = bucket.lines.sorted { $0.recordedAt < $1.recordedAt }
        // Natural-language header so BM25 lexical retrieval can match
        // questions like "what did I research" / "what did we look into" —
        // only document text is indexed, and the data lines share few tokens
        // with those questions. The rehydration line parser skips it (wrong
        // shape).
        let retrievalHeader = "Past research: questions I researched and what I found on \(bucket.dayKey):"
        return PaceRetrievalDocument(
            id: "\(documentIdPrefix)-\(bucket.dayKey)",
            source: .researchHistory,
            title: "Research history — \(bucket.dayKey)",
            text: ([retrievalHeader] + sortedLines.map(\.renderedText)).joined(separator: "\n"),
            modifiedAt: sortedLines.last?.recordedAt,
            permissionScope: "research-history"
        )
    }

    // MARK: - Line round-tripping

    private static func sanitizeForLineFormat(_ rawText: String) -> String {
        let collapsed = rawText
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maximumQuestionCharacterCount else { return collapsed }
        return String(collapsed.prefix(maximumQuestionCharacterCount)) + "…"
    }

    private static func answerExcerpt(from rawAnswer: String) -> String {
        let collapsed = rawAnswer
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maximumAnswerCharacterCount else { return collapsed }
        return String(collapsed.prefix(maximumAnswerCharacterCount)) + "…"
    }

    private static func parseLine(_ renderedLine: String, dayKey: String) -> JournalLine? {
        let parts = renderedLine.components(separatedBy: " | ")
        guard parts.count >= 4 else { return nil }
        let id = parts[0]
        let timeOfDay = parts[1]
        guard let recordedAt = dateTimeFormatter.date(from: "\(dayKey) \(timeOfDay)") else {
            return nil
        }
        let question = parts[2]
        // The answer can itself contain " | " after sanitization only if the
        // raw answer held that sequence; rejoin any trailing parts so the
        // whole answer survives the round-trip.
        let answer = parts[3...].joined(separator: " | ")
        return JournalLine(
            id: id,
            recordedAt: recordedAt,
            question: question,
            answer: answer
        )
    }

    private static func normalizedForDuplicateComparison(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    // MARK: - Formatters

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
