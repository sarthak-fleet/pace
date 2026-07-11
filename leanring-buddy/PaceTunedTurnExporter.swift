//
//  PaceTunedTurnExporter.swift
//  leanring-buddy
//
//  Opt-in export of anonymized local planner turns for the first
//  pace-tuned LoRA. Writes chat-shaped JSONL under Application Support;
//  copy into the repo with `scripts/export-pace-tuned-turns.sh`.
//

import Foundation

/// One training row: OpenAI-style messages plus lightweight metadata.
struct PaceTunedTurnExportRow: Equatable, Codable {
    struct Message: Equatable, Codable {
        let role: String
        let content: String
    }

    let messages: [Message]
    let meta: Meta

    struct Meta: Equatable, Codable {
        let lane: String
        let exportedAt: Date
        let sourceRecordId: UUID
        /// Which brain/tier produced this turn (e.g. "cloud bridge (codex)",
        /// "local", "cli bridge") plus its routing lane. REQUIRED for
        /// auditability: turns distilled from a commercial model (Codex,
        /// Claude) can be filtered out before training/shipping a model, so
        /// the distillation source is never silently baked in. Optional for
        /// backward-compatible decode of rows written before this field.
        let plannerProvenance: String?
        let routing: String?
    }
}

enum PaceTunedTurnAnonymizer {
    /// Redact common PII and local paths before anything leaves the Mac.
    static func anonymize(_ text: String) -> String {
        var redacted = text

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty {
            redacted = redacted.replacingOccurrences(of: home, with: "~")
        }

        // API-ish secrets that should never land in a public dataset.
        let secretPatterns = [
            #"(?i)\bsk-[a-z0-9]{10,}\b"#,
            #"(?i)\bxox[baprs]-[a-z0-9-]{10,}\b"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._-]{12,}\b"#
        ]
        for pattern in secretPatterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "[redacted-secret]",
                options: .regularExpression
            )
        }

        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
                | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        ) else {
            return redacted
        }

        let nsRange = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
        var replacements: [(Range<String.Index>, String)] = []
        detector.enumerateMatches(in: redacted, options: [], range: nsRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: redacted) else { return }
            switch match.resultType {
            case .phoneNumber:
                replacements.append((range, "[redacted-phone]"))
            case .link:
                if let url = match.url, url.scheme == "mailto" || url.absoluteString.contains("@") {
                    replacements.append((range, "[redacted-email]"))
                }
            default:
                break
            }
        }
        for (range, replacement) in replacements.reversed() {
            redacted.replaceSubrange(range, with: replacement)
        }

        // Loose email-shaped tokens NSDataDetector can miss in prose.
        redacted = redacted.replacingOccurrences(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            with: "[redacted-email]",
            options: [.regularExpression, .caseInsensitive]
        )

        return redacted
    }
}

enum PaceTunedTurnExportTrace {
    static let maximumRetainedLines = 5_000

    private static let ioQueue = DispatchQueue(label: "com.pace.app.paceTunedTurnExport")

    static var fileURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("pace-tuned-turns.jsonl", isDirectory: false)
    }

    static func append(_ row: PaceTunedTurnExportRow) {
        guard let fileURL else { return }
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let lineData = try? encoder.encode(row),
                  let line = String(data: lineData, encoding: .utf8) else { return }

            let directoryURL = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true
            )

            var lines = (try? String(contentsOf: fileURL, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init) ?? []
            lines.append(line)
            if lines.count > maximumRetainedLines {
                lines.removeFirst(lines.count - maximumRetainedLines)
            }
            try? (lines.joined(separator: "\n") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func clear() {
        guard let fileURL else { return }
        ioQueue.async {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

enum PaceTunedTurnExporter {
    /// Default ON — collects planner turns into the pace-tuned dataset so
    /// Pace's own model has data to train on. Every non-fast-path turn is
    /// collected, including cloud/bridge (Codex, Claude) turns, and each row
    /// is tagged with `plannerProvenance` so distilled-from-commercial turns
    /// can be filtered before training. Stays fully local + redacted (the
    /// file never leaves the Mac); opt out in Settings → Models.
    static var isEnabled: Bool {
        PaceUserPreferencesStore.bool(.isPaceTunedTurnExportEnabled, default: true)
    }

    static func exportIfEnabled(
        record: PaceToolCallDebugRecord,
        systemPrompt: String?
    ) {
        guard isEnabled else { return }
        guard let row = makeExportRow(record: record, systemPrompt: systemPrompt) else { return }
        PaceTunedTurnExportTrace.append(row)
    }

    static func makeExportRow(
        record: PaceToolCallDebugRecord,
        systemPrompt: String?
    ) -> PaceTunedTurnExportRow? {
        guard record.lane != .fastPath else { return nil }
        guard let systemPrompt, !systemPrompt.isEmpty else { return nil }
        guard !record.rawPlannerOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // NOTE: cloud/bridge/CLI (Codex, Claude) and research turns are now
        // COLLECTED (they used to be skipped here). This is deliberate — the
        // strategy is to distill a strong teacher brain into Pace's own local
        // model. It is ToS-sensitive: OpenAI/Anthropic terms generally forbid
        // training a competing model on their outputs, so every row is tagged
        // with `plannerProvenance`/`routing` and can be filtered out before
        // any model is trained or shipped. The redaction below still applies.
        let userContent = PaceTunedTurnAnonymizer.anonymize(
            record.userPrompt.isEmpty ? record.transcript : record.userPrompt
        )
        let assistantContent = PaceTunedTurnAnonymizer.anonymize(record.rawPlannerOutput)
        let systemContent = PaceTunedTurnAnonymizer.anonymize(systemPrompt)

        return PaceTunedTurnExportRow(
            messages: [
                .init(role: "system", content: systemContent),
                .init(role: "user", content: userContent),
                .init(role: "assistant", content: assistantContent)
            ],
            meta: .init(
                lane: record.lane.rawValue,
                exportedAt: Date(),
                sourceRecordId: record.id,
                plannerProvenance: record.plannerPathDetail ?? "unknown",
                routing: record.routingDetail
            )
        )
    }
}
