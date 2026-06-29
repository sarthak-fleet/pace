//
//  PaceSubagentCommandParser.swift
//  leanring-buddy
//
//  Parses voice commands that trigger parallel subagent execution.
//  Routed BEFORE the planner so "research X, Y, and Z simultaneously"
//  doesn't burn a single-agent planner round-trip — it spawns N
//  parallel subagents directly.
//
//  Detected patterns:
//    "research X, Y, and Z"       → 3 parallel research subagents
//    "compare A, B, and C"        → 3 parallel comparison subagents
//    "draft emails to X, Y, and Z" → 3 parallel draft subagents
//    "look into X, Y, and Z"      → 3 parallel research subagents
//
//  The parser splits on commas and "and" to extract sub-topics.
//  Requires at least 2 sub-topics to trigger (otherwise it's a
//  normal single-topic command).
//

import Foundation

/// A parsed subagent command — the parent prompt and the list of
/// sub-tasks to run in parallel.
struct PaceSubagentCommand: Equatable {
    let parentPrompt: String
    let subtasks: [(displayName: String, prompt: String)]
    let mergeStrategy: PaceSubagentMergeStrategy

    static func == (lhs: PaceSubagentCommand, rhs: PaceSubagentCommand) -> Bool {
        lhs.parentPrompt == rhs.parentPrompt &&
            lhs.subtasks.count == rhs.subtasks.count &&
            lhs.mergeStrategy == rhs.mergeStrategy
    }
}

nonisolated enum PaceSubagentCommandParser {
    /// Keywords that trigger subagent decomposition.
    private static let triggerKeywords = [
        "research",
        "compare",
        "look into",
        "investigate",
        "analyze",
        "draft emails to",
        "draft messages to",
    ]

    /// Conjunctions used to split sub-topics.
    private static let conjunctions = ["and", "plus", "as well as"]

    /// Parse a transcript into a subagent command, if it matches.
    /// Returns nil if the transcript doesn't contain a trigger keyword
    /// or doesn't have enough sub-topics (needs 2+).
    static func parse(_ transcript: String) -> PaceSubagentCommand? {
        let normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Check if any trigger keyword is present.
        guard let keyword = triggerKeywords.first(where: { normalized.contains($0) }) else {
            return nil
        }

        // Extract the part after the trigger keyword.
        guard let keywordRange = normalized.range(of: keyword) else { return nil }
        let afterKeyword = String(normalized[keywordRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !afterKeyword.isEmpty else { return nil }

        // Split on commas and "and" to extract sub-topics.
        let subTopics = splitSubTopics(afterKeyword)
        guard subTopics.count >= 2 else { return nil }

        // Build subtasks.
        let verb = keyword == "draft emails to" || keyword == "draft messages to"
            ? "draft"
            : keyword == "compare"
                ? "compare"
                : "research"

        let subtasks = subTopics.map { topic in
            (
                displayName: topic.capitalized,
                prompt: "\(verb) \(topic)"
            )
        }

        // Determine merge strategy.
        let mergeStrategy: PaceSubagentMergeStrategy
        if keyword == "compare" {
            // Comparison results should be concatenated so the user
            // can see all options side by side.
            mergeStrategy = .concatenate
        } else if keyword.contains("draft") {
            // Drafts should be concatenated (separate sections).
            mergeStrategy = .concatenate
        } else {
            // Research results should be summarized into one coherent
            // answer.
            mergeStrategy = .summarize
        }

        return PaceSubagentCommand(
            parentPrompt: transcript,
            subtasks: subtasks,
            mergeStrategy: mergeStrategy
        )
    }

    /// Split a string into sub-topics using commas and conjunctions.
    private static func splitSubTopics(_ text: String) -> [String] {
        // First split on commas.
        let commaParts = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Then split each part on "and" / "plus" / "as well as".
        var topics: [String] = []
        for part in commaParts {
            // Strip leading conjunction ("and svelte" → "svelte")
            var cleanedPart = part
            for conjunction in conjunctions {
                let prefix = "\(conjunction) "
                if cleanedPart.lowercased().hasPrefix(prefix) {
                    cleanedPart = String(cleanedPart.dropFirst(prefix.count))
                    break
                }
            }
            let subParts = splitOnConjunctions(cleanedPart)
            topics.append(contentsOf: subParts)
        }

        // Clean up and dedupe.
        return topics
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 1 } // filter out single chars
    }

    /// Split a string on conjunctions like "and", "plus".
    private static func splitOnConjunctions(_ text: String) -> [String] {
        var result: [String] = [text]
        for conjunction in conjunctions {
            var newResult: [String] = []
            for part in result {
                let pattern = " \(conjunction) "
                let parts = part.components(separatedBy: pattern)
                newResult.append(contentsOf: parts)
            }
            result = newResult
        }
        return result
    }
}
