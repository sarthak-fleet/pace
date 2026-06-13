//
//  PaceTurnHUDState.swift
//  leanring-buddy
//
//  Small user-visible turn status model for the notch panel and cursor
//  bubble. It keeps fast intent/progress feedback out of the planner prompt.
//

import Foundation

enum PaceTurnHUDStatus: Equatable {
    case idle
    case listening
    case understanding
    case acting
    case needsClarification
    case done
    case failed
    case unsupported
}

struct PaceTurnHUDState: Equatable {
    let status: PaceTurnHUDStatus
    let title: String
    let detail: String?
    let options: [String]

    static let idle = PaceTurnHUDState(
        status: .idle,
        title: "Ready",
        detail: nil,
        options: []
    )

    static let listening = PaceTurnHUDState(
        status: .listening,
        title: "Listening",
        detail: "Hold Control+Option",
        options: []
    )

    static func understanding(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .understanding,
            title: "Understanding",
            detail: detail,
            options: []
        )
    }

    static func acting(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .acting,
            title: "Acting",
            detail: detail,
            options: []
        )
    }

    static func clarification(question: String, options: [String]) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .needsClarification,
            title: question,
            detail: options.joined(separator: " / "),
            options: options
        )
    }

    static func done(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .done,
            title: "Done",
            detail: detail,
            options: []
        )
    }

    static func failed(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .failed,
            title: "Needs attention",
            detail: detail,
            options: []
        )
    }

    static func unsupported(_ detail: String) -> PaceTurnHUDState {
        PaceTurnHUDState(
            status: .unsupported,
            title: "Local only",
            detail: detail,
            options: []
        )
    }
}

struct PaceIntentClarification: Equatable {
    let question: String
    let options: [String]
}

/// One offered click target in a visual-target ambiguity clarification
/// (PRD docs/prds/hud-intent-disambiguator.md). The `label` is the chip
/// text the panel renders and the user reads/taps; the
/// `candidateIndex` is the stable index back into the paused click
/// candidate set so resolving option N executes candidate N's target.
struct PaceClickTargetOption: Equatable {
    let label: String
    let candidateIndex: Int
}

/// State for a paused click that surfaced a visual-target ambiguity
/// question. The original click candidate set and the executor screen
/// captures are held verbatim so resolution can execute the chosen
/// candidate directly — it must NOT re-run the planner, because a
/// re-plan could produce a different candidate set than the one the user
/// just chose from.
struct PacePendingClickTargetClarification {
    let prompt: String
    let options: [PaceClickTargetOption]
    let candidateSet: PaceClickCandidateSet
    let screenCaptures: [CompanionScreenCapture]

    /// Maps a tapped option label back to the candidate it represents.
    /// Matching is case-insensitive and whitespace-trimmed to mirror the
    /// existing `PaceIntentClarificationResolver` option matching.
    func candidate(forSelectedOptionLabel selectedOptionLabel: String) -> PaceClickCandidate? {
        let normalizedSelectedOptionLabel = selectedOptionLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let matchedOption = options.first(where: { option in
            option.label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == normalizedSelectedOptionLabel
        }) else {
            return nil
        }

        guard candidateSet.candidates.indices.contains(matchedOption.candidateIndex) else {
            return nil
        }
        return candidateSet.candidates[matchedOption.candidateIndex]
    }
}

/// Pure builder for a visual-target ambiguity clarification from the
/// candidates the executor's ambiguity check selected. Keeps the prompt
/// copy + option construction unit-testable without touching
/// CompanionManager. The candidate→option index mapping is computed
/// against the FULL candidate set so the held set and the offered
/// options stay in lockstep.
enum PaceClickTargetClarificationBuilder {
    static let defaultPrompt = "Two matches — which one?"

    static func makeClarification(
        offeredCandidates: [PaceClickCandidate],
        in candidateSet: PaceClickCandidateSet,
        prompt: String = defaultPrompt
    ) -> PacePendingClickTargetClarification? {
        guard offeredCandidates.count >= 2 else { return nil }

        var options: [PaceClickTargetOption] = []
        for offeredCandidate in offeredCandidates {
            guard let trimmedLabel = offeredCandidate.label?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmedLabel.isEmpty else {
                continue
            }
            guard let candidateIndex = candidateSet.candidates.firstIndex(where: { candidate in
                candidate.label?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedLabel
                    && candidate.confidence == offeredCandidate.confidence
            }) else {
                continue
            }
            options.append(
                PaceClickTargetOption(label: trimmedLabel, candidateIndex: candidateIndex)
            )
        }

        guard options.count >= 2 else { return nil }

        return PacePendingClickTargetClarification(
            prompt: prompt,
            options: options,
            candidateSet: candidateSet,
            screenCaptures: []
        )
    }
}

struct PacePendingIntentClarification: Equatable {
    let originalTranscript: String
    let clarification: PaceIntentClarification
}

enum PaceIntentClarificationResolver {
    static func clarifiedTranscript(
        for pendingClarification: PacePendingIntentClarification,
        selectedOption: String
    ) -> String? {
        let normalizedSelectedOption = selectedOption
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard pendingClarification.clarification.options.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedSelectedOption
        }) else {
            return nil
        }

        let clarifiedTarget: String
        if normalizedSelectedOption.contains("selected text") {
            clarifiedTarget = "selected text"
        } else if normalizedSelectedOption.contains("focused field") {
            clarifiedTarget = "focused field"
        } else if normalizedSelectedOption.contains("current item") {
            clarifiedTarget = "current item"
        } else {
            clarifiedTarget = normalizedSelectedOption
        }

        return replacingAmbiguousReference(
            in: pendingClarification.originalTranscript,
            with: clarifiedTarget
        )
    }

    private static func replacingAmbiguousReference(
        in transcript: String,
        with clarifiedTarget: String
    ) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return "the \(clarifiedTarget)" }

        let pattern = #"\b(it|that|this)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return "\(trimmedTranscript) the \(clarifiedTarget)"
        }

        let fullRange = NSRange(trimmedTranscript.startIndex..<trimmedTranscript.endIndex, in: trimmedTranscript)
        guard regex.firstMatch(in: trimmedTranscript, range: fullRange) != nil else {
            return "\(trimmedTranscript) the \(clarifiedTarget)"
        }

        return regex.stringByReplacingMatches(
            in: trimmedTranscript,
            options: [],
            range: fullRange,
            withTemplate: "the \(clarifiedTarget)"
        )
    }
}

struct PaceIntentUnsupportedResponse: Equatable {
    let spokenText: String
    let reason: String
}

enum PaceIntentUnsupportedDetector {
    static func unsupportedResponse(
        for transcript: String,
        prediction: PaceIntentPrediction
    ) -> PaceIntentUnsupportedResponse? {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard prediction.route == .phoneLargeModel
                || normalizedTranscript.contains("use cloud")
                || normalizedTranscript.contains("ask gemini")
                || normalizedTranscript.contains("ask chatgpt")
                || normalizedTranscript.contains("private cloud") else {
            return nil
        }

        return PaceIntentUnsupportedResponse(
            spokenText: "I only use local models on this Mac.",
            reason: "Cloud or large-model escalation is not available."
        )
    }
}

enum PaceIntentClarifier {
    static func clarification(for transcript: String) -> PaceIntentClarification? {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedTranscript.isEmpty else { return nil }

        if looksLikeAmbiguousEditCommand(normalizedTranscript) {
            return PaceIntentClarification(
                question: "Edit selected text or the focused field?",
                options: ["Selected text", "Focused field"]
            )
        }

        if looksLikeAmbiguousDestructiveCommand(normalizedTranscript) {
            return PaceIntentClarification(
                question: "What should I delete?",
                options: ["Selected text", "Current item"]
            )
        }

        return nil
    }

    private static func looksLikeAmbiguousEditCommand(_ normalizedTranscript: String) -> Bool {
        let editPhrases = [
            "edit it", "edit that", "edit this",
            "rewrite it", "rewrite that", "rewrite this",
            "fix it", "fix that", "fix this",
            "change it", "change that", "change this",
            "make it better", "clean it up", "polish it"
        ]

        guard editPhrases.contains(where: normalizedTranscript.contains) else {
            return false
        }

        let explicitTargets = [
            "selected text", "selection", "highlighted text",
            "focused field", "current field", "text field",
            "whole field", "draft", "email", "note"
        ]
        return !explicitTargets.contains(where: normalizedTranscript.contains)
    }

    private static func looksLikeAmbiguousDestructiveCommand(_ normalizedTranscript: String) -> Bool {
        let ambiguousDestructivePhrases = [
            "delete it", "delete that", "delete this",
            "remove it", "remove that", "remove this",
            "discard it", "discard that", "discard this"
        ]

        guard ambiguousDestructivePhrases.contains(where: normalizedTranscript.contains) else {
            return false
        }

        let explicitObjects = [
            "selected text", "selection", "highlighted text",
            "sentence", "paragraph", "file", "folder", "email",
            "message", "event", "reminder", "note", "draft",
            "current item"
        ]
        return !explicitObjects.contains(where: normalizedTranscript.contains)
    }
}
