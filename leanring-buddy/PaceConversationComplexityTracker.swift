//
//  PaceConversationComplexityTracker.swift
//  leanring-buddy
//
//  Conversation-aware complexity estimation. Tracks how deep the
//  current conversation has gotten and escalates follow-up queries
//  even when they're short and have no complexity keywords.
//
//  "So what about the edge cases?" is simple by keyword/length but
//  complex in context — it's a follow-up in a deep technical
//  conversation. This tracker catches that case.
//
//  Signals:
//  - Turn count on the same topic (keyword overlap between turns)
//  - Total conversation depth (turn count in current session)
//  - Prior turn complexity (if recent turns were moderate+, the
//    conversation is getting deeper)
//
//  Stateless per-turn check — reads from PaceThreadMemory which
//  already tracks conversation history. No new persistence needed.
//

import Foundation

/// Tracks conversation depth and topic continuity to inform complexity
/// estimation. Reads from the existing conversation history — no new
/// state to manage.
enum PaceConversationComplexityTracker {

    /// After this many turns on the same topic, follow-up queries
    /// are escalated even if they're short. "Same topic" is defined
    /// by keyword overlap between consecutive turns.
    nonisolated static let sameTopicTurnThreshold = 4

    /// After this many total turns in a session, the conversation is
    /// considered "deep" and short follow-ups are escalated.
    nonisolated static let deepConversationTurnThreshold = 8

    /// Minimum keyword overlap ratio to consider two turns "same topic".
    nonisolated static let topicOverlapThreshold = 0.30

    /// Estimate whether a follow-up query should be escalated based
    /// on conversation context. Called after the per-query complexity
    /// estimator returns `.simple` or `.moderate` — if this returns
    /// true, the complexity is upgraded to `.complex`.
    ///
    /// - Parameters:
    ///   - transcript: The current user query
    ///   - conversationHistory: Recent conversation turns (user + assistant)
    /// - Returns: true if conversation context warrants escalation
    static func shouldEscalateBasedOnContext(
        transcript: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)]
    ) -> Bool {
        guard !conversationHistory.isEmpty else { return false }

        let turnCount = conversationHistory.count

        // 1. Deep conversation — after N total turns, the conversation
        //    has enough context that even short follow-ups benefit from
        //    a larger model. The user is clearly engaged in a multi-turn
        //    discussion.
        if turnCount >= deepConversationTurnThreshold {
            return true
        }

        // 2. Same-topic streak — count how many consecutive recent
        //    turns share keyword overlap with the current query. If
        //    the user has been on the same topic for N+ turns, the
        //    follow-up is likely building on accumulated context that
        //    the local model is starting to lose.
        let currentKeywords = contentWords(from: transcript)
        guard !currentKeywords.isEmpty else { return false }

        var sameTopicStreak = 0
        for pastTurn in conversationHistory.reversed() {
            let pastKeywords = contentWords(from: pastTurn.userTranscript)
            guard !pastKeywords.isEmpty else { break }
            let overlap = currentKeywords.intersection(pastKeywords)
            let overlapRatio = Double(overlap.count) / Double(min(currentKeywords.count, pastKeywords.count))
            if overlapRatio >= topicOverlapThreshold {
                sameTopicStreak += 1
            } else {
                break
            }
        }

        if sameTopicStreak >= sameTopicTurnThreshold {
            return true
        }

        return false
    }

    /// Extract content words from a transcript — lowercase, no stop
    /// words, no punctuation. Used for topic overlap detection.
    private static func contentWords(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been",
            "being", "have", "has", "had", "do", "does", "did", "will",
            "would", "could", "should", "may", "might", "must", "can",
            "to", "of", "in", "on", "at", "by", "for", "with", "about",
            "from", "as", "into", "through", "during", "before", "after",
            "and", "or", "but", "if", "then", "so", "because", "than",
            "that", "this", "these", "those", "it", "its", "they", "them",
            "their", "we", "us", "our", "you", "your", "he", "she", "his",
            "her", "i", "me", "my", "what", "how", "why", "when", "where",
            "who", "which", "whats", "what's", "pace", "hey", "hi",
            "ok", "okay", "yeah", "yes", "no", "not", "just", "like",
            "really", "very", "more", "most", "some", "any", "all",
            "also", "too", "either", "neither", "both", "each",
        ]

        return Set(
            text.lowercased()
                .split { $0.isWhitespace || $0.isPunctuation }
                .map(String.init)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }
}
