//
//  PaceResearchCancelCommandParser.swift
//  leanring-buddy
//
//  Parses explicit voice commands that cancel an in-flight research
//  turn. Routed BEFORE the planner in `CompanionManager` so saying
//  "stop researching" doesn't burn another planner round-trip.
//
//  Mirrors the structural shape of `PaceClearAnnotationsCommandParser`
//  and `PaceWatchModeCommandParser` — alphanumeric-normalized substring
//  match against a small phrase list. Pure module, no async, no AppKit.
//

import Foundation

nonisolated enum PaceResearchCancelCommand: Equatable {
    case cancel
}

nonisolated enum PaceResearchCancelCommandParser {
    static func parse(_ transcript: String) -> PaceResearchCancelCommand? {
        let normalizedTranscript = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalizedTranscript.isEmpty else { return nil }
        return matchesCancelCommand(normalizedTranscript) ? .cancel : nil
    }

    private static func matchesCancelCommand(_ normalizedTranscript: String) -> Bool {
        let cancelPhrases = [
            "stop researching",
            "stop the research",
            "cancel the research",
            "cancel research",
            "abort the research",
            "abort research",
            "quit research",
            "stop the deep research",
            "stop deep research",
            "end the research",
            "end research",
            "nevermind research",
            "never mind research",
            "drop the research",
        ]
        return cancelPhrases.contains { normalizedTranscript.contains($0) }
    }
}
