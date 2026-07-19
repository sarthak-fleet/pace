//
//  PaceQueryComplexityEstimator.swift
//  leanring-buddy
//
//  Rule-based query complexity estimation. Runs in microseconds (string
//  contains checks + word count) — no model, no network, no latency.
//
//  The intent classifier (PaceIntentClassifier) answers "what kind of
//  turn is this?" but not "how hard is it?" A confident pureKnowledge
//  classification for "what's the capital of France" and "write a
//  2000-word essay comparing the economic causes of WWI and WWII" are
//  both routed to the same local text-only planner. The complexity
//  estimator catches the second case and escalates it to the large
//  model, where long-form synthesis, multi-step reasoning, and code
//  generation produce materially better output.
//
//  Escalation only applies to local-answer intents (chitchat,
//  pureKnowledge, screenDescription). screenAction is excluded because
//  the action layer needs local model action-tag generation
//  ([CLICK:...], [TYPE:...]) — a cloud model can't produce those.
//

import Foundation

/// Estimated complexity of a user query. Drives whether the local
/// model is trusted to handle it or whether it should be escalated
/// to the large model.
enum PaceQueryComplexity: String, Equatable {
    /// Short factual question, single action, or social filler.
    /// The local model handles these well.
    case simple

    /// Short explanation or simple draft. The local model is adequate
    /// but a larger model would be marginally better. Not escalated.
    case moderate

    /// Long-form synthesis, multi-step reasoning, code generation, or
    /// a very long query. The local 3B active-param model produces
    /// noticeably worse output here. Escalated to the large model.
    case complex
}

/// Pure rule-based complexity estimator. No model, no learning, no
/// retraining needed. Tuned conservatively to avoid false positives —
/// it's better to let a complex query run locally than to escalate
/// a simple one and pay the cloud round-trip.
enum PaceQueryComplexityEstimator {

    /// Word count thresholds for voice queries. Voice queries are
    /// typically shorter than typed ones — a 40-word voice query is
    /// already substantial. These are intentionally lower than typed-
    /// query thresholds would be.
    nonisolated static let wordCountModerateThreshold = 20
    nonisolated static let wordCountComplexThreshold = 40

    // MARK: - Strong complexity signals
    //
    // Any single match triggers `.complex` regardless of length.
    // These are phrases where the local 3B model will clearly
    // underperform a cloud model.

    private static let complexIndicators: [String] = [
        // Long-form content generation
        "essay", "write a blog", "blog post", "write a report",
        "write a proposal", "write a document", "write an article",
        "write a paper", "write a story", "write a letter",
        "write a memo", "write a manifesto",

        // Depth / thoroughness cues
        "in detail", "in depth", "comprehensive", "thorough",
        "deep dive", "deep analysis", "exhaustive",
        "step by step", "step-by-step", "walk me through",

        // Synthesis / reasoning
        "compare and contrast", "pros and cons",
        "trade-offs", "tradeoffs", "trade offs",
        "synthesize", "synthesise", "critique",
        "evaluate the", "assess the",

        // Code generation (beyond snippets)
        "write a function", "write a script", "write a class",
        "write a program", "write a method", "write a component",
        "implement a", "implement the", "refactor this",
        "refactor the", "write a test", "write tests for",

        // Quantitative length demands
        "1000 words", "500 words", "2000 words", "3000 words",
        "long answer", "long form", "long-form",
        "multiple paragraphs", "several paragraphs",

        // Multi-step planning
        "create a plan", "make a plan", "project plan",
        "roadmap", "strategy for",
    ]

    // MARK: - Moderate complexity signals
    //
    // These hint at complexity but aren't definitive. A moderate
    // indicator combined with a long query (>= moderate threshold)
    // triggers `.complex`. Otherwise `.moderate`.

    private static let moderateIndicators: [String] = [
        "summarize", "summarise", "analyze", "analyse",
        "elaborate", "outline", "draft a", "compose a",
        "explain in detail", "describe in detail",
        "review the", "design a", "design the",
        "breakdown", "break down",
    ]

    // MARK: - Estimation

    /// Estimate the complexity of a transcript. This is called from
    /// `PaceIntentClassifier.classify` after the intent is determined,
    /// so the transcript is already trimmed and non-empty.
    static func estimate(transcript: String) -> PaceQueryComplexity {
        let lowercase = transcript.lowercased()
        let wordCount = lowercase.split { $0.isWhitespace }.count

        // Strong signals — any match → complex, regardless of length.
        for indicator in complexIndicators {
            if lowercase.contains(indicator) {
                return .complex
            }
        }

        // Moderate signals — escalate to complex if the query is also
        // long enough that the local model will struggle.
        for indicator in moderateIndicators {
            if lowercase.contains(indicator) {
                return wordCount >= wordCountModerateThreshold
                    ? .complex
                    : .moderate
            }
        }

        // Length-based: a very long query is likely complex even
        // without explicit keywords. Voice queries rarely exceed
        // 40 words unless the user is describing a multi-part task.
        if wordCount >= wordCountComplexThreshold {
            return .complex
        }
        if wordCount >= wordCountModerateThreshold {
            return .moderate
        }

        return .simple
    }
}
