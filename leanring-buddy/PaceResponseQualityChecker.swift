//
//  PaceResponseQualityChecker.swift
//  leanring-buddy
//
//  Post-hoc response quality detection. After the local model
//  generates a response, this checks whether it's adequate before
//  speaking it to the user. If the response is poor AND a stronger
//  model is available (codex CLI), the turn is re-routed.
//
//  Two layers:
//  1. Heuristic checks (instant, zero cost) — catches obvious failures
//  2. Apple FM scoring (~200ms, in-process) — catches subtle quality
//     issues that heuristics miss
//
//  Only applied to text-only answer paths (pureKnowledge, chitchat)
//  where the response is generated fully before TTS begins. The main
//  agent loop (screenAction, screenDescription) streams to TTS
//  during generation and can't be cleanly intercepted.
//

import Foundation
import FoundationModels

/// Result of a quality check on a planner response.
enum PaceResponseQualityVerdict: Equatable {
    /// Response is adequate — proceed with speaking it.
    case adequate

    /// Response is poor — re-route to a stronger model if available.
    /// The reason is logged for debugging.
    case inadequate(reason: String)

    /// Quality check could not run (e.g., Apple FM unavailable).
    /// Proceed with the response — don't block on uncertainty.
    case skipped(reason: String)
}

/// Heuristic quality checks on a planner response. Zero latency, zero
/// model cost. Catches the most common failure modes of small local
/// models: hedging, repetition, non-answers, and too-short responses.
enum PaceResponseQualityHeuristics {

    /// Phrases that indicate the local model is hedging or failing.
    /// These are strong signals that the response is not useful.
    private static let failureMarkers: [String] = [
        "i'm not sure",
        "i am not sure",
        "i don't know",
        "i do not know",
        "i can't help with that",
        "i cannot help with that",
        "i'm unable to",
        "i am unable to",
        "unable to help",
        "sorry, i can't",
        "sorry, i cannot",
        "i don't have access to",
        "i do not have access to",
        "i don't have information",
        "i do not have information",
        "i'm just a",
        "i am just a",
        "as an ai",
        "as a language model",
        "i don't have the ability to",
        "i do not have the ability to",
    ]

    /// Check heuristic quality of a response against the original query.
    /// Returns `.inadequate` with a reason if any check fails.
    static func check(query: String, response: String) -> PaceResponseQualityVerdict {
        let lowercaseResponse = response.lowercased()
        let responseWords = lowercaseResponse.split { $0.isWhitespace }
        let responseWordCount = responseWords.count

        // 1. Too short for a knowledge question (chitchat is exempt —
        //    "yes" or "no problem" are valid chitchat responses).
        //    A pureKnowledge answer under 10 words is almost always
        //    a non-answer like "I don't know" or a one-word hedge.
        if responseWordCount < 10 {
            // Allow short responses if they contain actionable content
            // (URLs, numbers, direct answers to "what is X" questions).
            let queryLower = query.lowercased()
            let isLikelyDefinitionQuery = queryLower.hasPrefix("what is ")
                || queryLower.hasPrefix("what's ")
                || queryLower.hasPrefix("who is ")
                || queryLower.hasPrefix("who's ")
            if isLikelyDefinitionQuery && responseWordCount < 5 {
                return .inadequate(reason: "response too short for knowledge query (\(responseWordCount) words)")
            }
        }

        // 2. Failure markers — the model is explicitly saying it
        //    can't answer. These are definitive.
        for marker in failureMarkers {
            if lowercaseResponse.contains(marker) {
                return .inadequate(reason: "failure marker: \"\(marker)\"")
            }
        }

        // 3. Repetition — same phrase repeated 3+ times indicates
        //    the model is stuck in a loop. Check 3-gram repetition.
        if responseWordCount > 15 {
            let words = responseWords.map(String.init)
            var ngramCounts: [String: Int] = [:]
            for i in 0..<(words.count - 2) {
                let ngram = words[i..<(i + 3)].joined(separator: " ")
                ngramCounts[ngram, default: 0] += 1
            }
            if let maxCount = ngramCounts.values.max(), maxCount >= 4 {
                return .inadequate(reason: "repetitive 3-gram (count: \(maxCount))")
            }
        }

        // 4. Echo — the response just repeats the query back without
        //    adding information. Common with small models on edge cases.
        //    Check if most UNIQUE words in the response are also in the
        //    query — if the response adds no new vocabulary, it's an echo.
        let queryWords = Set(query.lowercased().split { $0.isWhitespace }.map(String.init))
        let responseWordSet = Set(responseWords.map(String.init))
        if responseWordCount > 5 && responseWordSet.count < 15 {
            let overlap = queryWords.intersection(responseWordSet).count
            let overlapRatio = Double(overlap) / Double(responseWordSet.count)
            // If >80% of unique response words are also in the query,
            // the response isn't adding new information — it's an echo.
            if overlapRatio > 0.80 {
                return .inadequate(reason: "response echoes query (overlap: \(Int(overlapRatio * 100))%)")
            }
        }

        return .adequate
    }
}

/// Apple Foundation Models-based quality scoring. Asks the in-process
/// 3B model to rate the response quality on a 1-10 scale. Catches
/// subtle quality issues that heuristics miss (e.g., partially correct
/// but shallow answers). ~200ms warm, in-process, zero cost.
///
/// Only available when Apple Intelligence is enabled. Falls through
/// to `.skipped` when unavailable — the caller proceeds with the
/// response rather than blocking on uncertainty.
@available(macOS 26.0, *)
@MainActor
final class PaceResponseQualityFMScorer {
    private var session: LanguageModelSession?

    /// Score threshold below which the response is considered inadequate.
    /// 6/10 means "adequate but not great" passes, "poor" fails.
    nonisolated static let inadequateThreshold: Int = 6

    func score(query: String, response: String) async -> PaceResponseQualityVerdict {
        let resolvedSession = resolveSession()
        let prompt = """
        Rate this AI assistant response on a 1-10 scale for how well it answers the user's question. \
        Consider: does it answer the question? Is it accurate? Is it helpful? Is it complete? \
        Respond with ONLY a single integer 1-10, nothing else.

        User asked: "\(query)"

        Assistant responded: "\(response.prefix(500))"
        """

        do {
            let result = try await resolvedSession.respond(
                to: prompt,
                options: GenerationOptions(
                    sampling: .greedy,
                    temperature: 0,
                    maximumResponseTokens: 5
                )
            )
            let scoreText = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Extract the first integer from the response
            let digits = scoreText.prefix { $0.isNumber }
            guard let score = Int(digits) else {
                return .skipped(reason: "FM scorer returned non-numeric: \"\(scoreText)\"")
            }
            if score < Self.inadequateThreshold {
                return .inadequate(reason: "FM score: \(score)/10")
            }
            return .adequate
        } catch {
            return .skipped(reason: "FM scorer error: \(error.localizedDescription)")
        }
    }

    private func resolveSession() -> LanguageModelSession {
        if let session { return session }
        let newSession = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Instructions("You are a response quality evaluator. Output only a number 1-10.")
        )
        session = newSession
        return newSession
    }
}

/// Combined quality checker — runs heuristics first (instant), then
/// Apple FM scoring if heuristics pass (~200ms). Returns the final
/// verdict for the caller to act on.
@MainActor
final class PaceResponseQualityChecker {
    private let fmScorer: PaceResponseQualityFMScorer?

    init() {
        if #available(macOS 26.0, *) {
            let systemModel = SystemLanguageModel.default
            if case .available = systemModel.availability {
                self.fmScorer = PaceResponseQualityFMScorer()
            } else {
                self.fmScorer = nil
            }
        } else {
            self.fmScorer = nil
        }
    }

    /// Check response quality. Heuristics run first (instant). If
    /// heuristics pass AND FM scoring is available, run FM scoring.
    /// Returns `.adequate` only if both layers pass.
    func check(query: String, response: String) async -> PaceResponseQualityVerdict {
        // Layer 1: heuristics (instant)
        let heuristicVerdict = PaceResponseQualityHeuristics.check(query: query, response: response)
        if case .inadequate = heuristicVerdict {
            return heuristicVerdict
        }

        // Layer 2: Apple FM scoring (~200ms, if available)
        guard let fmScorer else {
            return .skipped(reason: "Apple FM unavailable — heuristics only")
        }

        // Skip FM scoring for very short responses (chitchat) —
        // heuristics are sufficient there and FM scoring adds latency.
        let responseWordCount = response.split { $0.isWhitespace }.count
        if responseWordCount < 20 {
            return .adequate
        }

        return await fmScorer.score(query: query, response: response)
    }
}
