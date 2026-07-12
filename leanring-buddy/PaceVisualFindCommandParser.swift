//
//  PaceVisualFindCommandParser.swift
//  leanring-buddy
//
//  Parses explicit "find <text> on screen" voice commands that route to
//  the deterministic OCR-grounded visual-find path (screenshot → Vision
//  OCR → draw rectangles at the matches) instead of the planner. Routed
//  BEFORE the planner in the agent loop so a text search never burns a
//  planner round-trip and never lets the planner GUESS coordinates.
//
//  Mirrors the structural shape of `PaceClearAnnotationsCommandParser`
//  and `PaceWatchModeCommandParser`: pure, `nonisolated`, no I/O. The
//  match requires an explicit screen-y marker ("on screen" / "on the
//  screen" / "on my screen") OR the "show me where <text> is" form, so a
//  plain "find my keys" chitchat utterance never triggers a screen search.
//

import Foundation

/// One parsed visual-find command. Carries the extracted search query
/// (the text the user wants marked on screen), already stripped of
/// wrapping quotes and surrounding whitespace.
nonisolated struct PaceVisualFindCommand: Equatable {
    /// The text to search for and highlight on screen. Guaranteed
    /// non-empty by the parser (an empty query returns nil instead).
    let searchQuery: String
}

nonisolated enum PaceVisualFindCommandParser {

    /// Try to parse the transcript as a visual-find command. Returns nil
    /// when the utterance is not a screen-text search, or when the
    /// extracted query is empty.
    ///
    /// Recognized forms (case-insensitive, quotes optional):
    ///   * "find <query> on screen" / "on the screen" / "on my screen"
    ///   * "search for <query> on screen"
    ///   * "where is <query> on screen"
    ///   * "highlight <query> on screen"
    ///   * "mark <query> on screen"
    ///   * "show me where <query> is"  (screen marker not required —
    ///      this form is unambiguously a locate-on-screen request)
    static func parse(_ transcript: String) -> PaceVisualFindCommand? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return nil }

        let lowercasedTranscript = trimmedTranscript.lowercased()

        // First try the "show me where <query> is" form, which is
        // self-contained (it does not need an explicit screen marker
        // because "show me where … is" already means "locate it for me
        // on screen"). Handled first so its own trailing "is" doesn't get
        // mistaken for query text by the prefix forms below.
        if let showMeWhereQuery = extractShowMeWhereQuery(
            fromLowercasedTranscript: lowercasedTranscript,
            originalTranscript: trimmedTranscript
        ) {
            return makeCommand(fromRawQuery: showMeWhereQuery)
        }

        // Every other form REQUIRES an explicit screen marker so a plain
        // "find my keys" / "search for a good restaurant" chitchat
        // utterance can never trigger a screen search.
        guard transcriptContainsScreenMarker(lowercasedTranscript) else { return nil }

        if let prefixQuery = extractQueryAfterLeadingVerb(
            fromLowercasedTranscript: lowercasedTranscript,
            originalTranscript: trimmedTranscript
        ) {
            return makeCommand(fromRawQuery: prefixQuery)
        }

        return nil
    }

    // MARK: - Screen marker

    /// Explicit "this is about the screen" phrases. Required for the
    /// leading-verb forms so free-form "find <thing>" chitchat never
    /// matches. Checked as a substring so it can appear anywhere in the
    /// utterance (usually the tail: "find the login button on screen").
    private static func transcriptContainsScreenMarker(_ lowercasedTranscript: String) -> Bool {
        let screenMarkers = [
            "on screen",
            "on the screen",
            "on my screen",
            "on this screen",
        ]
        return screenMarkers.contains { lowercasedTranscript.contains($0) }
    }

    // MARK: - Leading-verb forms

    /// For "find <query> on screen" style utterances: match a known
    /// leading verb phrase, then take everything AFTER it as the raw
    /// query, then strip the trailing screen marker. Returns nil when no
    /// leading verb matches.
    private static func extractQueryAfterLeadingVerb(
        fromLowercasedTranscript lowercasedTranscript: String,
        originalTranscript: String
    ) -> String? {
        // Longest, most-specific prefixes first so "search for " wins over
        // a hypothetical bare "search ".
        let leadingVerbPrefixes = [
            "search for ",
            "find me ",
            "find the ",
            "find ",
            "highlight the ",
            "highlight ",
            "mark the ",
            "mark ",
            "where is the ",
            "where is ",
            "where's the ",
            "where's ",
            "locate the ",
            "locate ",
        ]

        for prefix in leadingVerbPrefixes where lowercasedTranscript.hasPrefix(prefix) {
            // Slice the ORIGINAL (case-preserving) transcript by the same
            // prefix length so the returned query keeps the user's casing
            // — the label drawn next to the match should read naturally.
            let rawQueryWithTrailingMarker = String(originalTranscript.dropFirst(prefix.count))
            return stripTrailingScreenMarker(fromRawQuery: rawQueryWithTrailingMarker)
        }

        return nil
    }

    // MARK: - "show me where <query> is" form

    /// For "show me where <query> is" style utterances: match the leading
    /// "show me where " (or "show where ") phrase, take everything after
    /// it, then drop a trailing " is" / " is located" / screen marker.
    private static func extractShowMeWhereQuery(
        fromLowercasedTranscript lowercasedTranscript: String,
        originalTranscript: String
    ) -> String? {
        let showMeWherePrefixes = [
            "show me where ",
            "show me the ",
            "show where ",
        ]

        for prefix in showMeWherePrefixes where lowercasedTranscript.hasPrefix(prefix) {
            var rawQuery = String(originalTranscript.dropFirst(prefix.count))
            rawQuery = stripTrailingScreenMarker(fromRawQuery: rawQuery)
            rawQuery = stripTrailingLocatorWords(fromRawQuery: rawQuery)
            return rawQuery
        }

        return nil
    }

    // MARK: - Query cleanup

    /// Drop a trailing screen marker ("… on screen", "… on the screen")
    /// from a raw query so the searched text is just what the user wants
    /// found, not the routing phrase.
    private static func stripTrailingScreenMarker(fromRawQuery rawQuery: String) -> String {
        var cleaned = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingMarkers = [
            "on this screen",
            "on my screen",
            "on the screen",
            "on screen",
        ]
        for marker in trailingMarkers {
            if cleaned.lowercased().hasSuffix(marker) {
                cleaned = String(cleaned.dropLast(marker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return cleaned
    }

    /// Drop trailing locator words left over from the "show me where …"
    /// form ("… is", "… is located", "… is at"). Handles both a trailing
    /// locator after real query text AND the degenerate case where the
    /// whole remaining string IS the locator ("show me where is" → the
    /// query is just "is", which is no query at all → empty).
    private static func stripTrailingLocatorWords(fromRawQuery rawQuery: String) -> String {
        var cleaned = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingLocators = [
            "is located",
            "is at",
            "is",
        ]
        for locator in trailingLocators {
            // Whole string is nothing but the locator → no real query left.
            if cleaned.lowercased() == locator {
                return ""
            }
            if cleaned.lowercased().hasSuffix(" " + locator) {
                cleaned = String(cleaned.dropLast(locator.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return cleaned
    }

    /// Strip a single leading article ("the ", "a ", "an ") so
    /// "find the login button" searches for "login button", not
    /// "the login button" — the article is routing filler, not part of
    /// the on-screen text the user wants marked. Only the leading word is
    /// touched; an interior "the" inside the query survives.
    private static func stripLeadingArticle(fromRawQuery rawQuery: String) -> String {
        var cleaned = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadingArticles = ["the ", "a ", "an "]
        for article in leadingArticles where cleaned.lowercased().hasPrefix(article) {
            cleaned = String(cleaned.dropFirst(article.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return cleaned
    }

    /// Strip wrapping quotes, a leading article, and whitespace from an
    /// extracted query, then build the command. Returns nil when nothing
    /// meaningful is left.
    private static func makeCommand(fromRawQuery rawQuery: String) -> PaceVisualFindCommand? {
        let unquotedQuery = stripWrappingQuotes(fromQuery: rawQuery)
        let articleStrippedQuery = stripLeadingArticle(fromRawQuery: unquotedQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !articleStrippedQuery.isEmpty else { return nil }
        return PaceVisualFindCommand(searchQuery: articleStrippedQuery)
    }

    /// Remove a single matched pair of wrapping quotes (straight or curly)
    /// so `find "account balance" on screen` searches for the text
    /// without the quote characters.
    private static func stripWrappingQuotes(fromQuery query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let openingQuotes: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}"]
        let closingQuotes: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}"]
        guard let firstCharacter = trimmed.first,
              let lastCharacter = trimmed.last,
              trimmed.count >= 2,
              openingQuotes.contains(firstCharacter),
              closingQuotes.contains(lastCharacter) else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
