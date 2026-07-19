//
//  PaceIntentClassifier.swift
//  leanring-buddy
//
//  Predicts what kind of turn the user just spoke (task #113) so the
//  pipeline can skip work the turn doesn't need. Four classes:
//
//    .pureKnowledge       "what is HTML"          → skip VLM, skip OCR/AX
//    .screenDescription   "what's on screen"      → run AX+OCR, maybe skip VLM
//    .screenAction        "click the save button" → full pipeline
//    .phoneLargeModel     "ask the big model"     → reserved escalation route
//    .chitchat            "hi pace", "thanks"     → skip VLM, skip planner
//
//  Today this is a rule-based / keyword matcher. The training corpus at
//  `evals/intent-corpus/seed.csv` (200 labeled examples) is the basis
//  for a Create ML text classifier later — when that .mlmodel is
//  bundled, swap the impl behind this class without touching callers.
//  The rule-based version is intentionally generous on chitchat (high
//  recall) and conservative everywhere else (any uncertainty falls
//  through to .unknown, which means "run the full pipeline").
//

import Foundation

/// What kind of turn the user is asking for. Drives pipeline routing
/// inside CompanionManager. Ordering of cases mirrors the cost-to-
/// execute axis: chitchat is cheapest (canned response), pureKnowledge
/// just needs the planner, screenDescription needs AX+OCR, screenAction
/// needs everything.
enum PaceIntent: String, CaseIterable {
    /// Factual question, no screen context required. e.g. "what is CSS".
    case pureKnowledge

    /// User wants a description of what's on screen. AX-tree + OCR is
    /// enough; VLM is optional. e.g. "what am I looking at".
    case screenDescription

    /// User wants Pace to do something via the action layer. Full VLM
    /// + planner + action exec needed. e.g. "click the save button".
    case screenAction

    /// Greeting or social filler. Canned response is fine. e.g. "hi pace".
    case chitchat

    /// Explicit escalation request. No cloud path is wired today, but
    /// the route exists so the product can add "phone a large model"
    /// behind one switch without retraining the classifier.
    case phoneLargeModel

    /// Research-class turn ("research X", "look into Y", "compare A vs
    /// B", "investigate Z"). Routed through `PaceResearchTierStore`'s
    /// configured tier — Anthropic Opus via Direct API, or Claude Opus
    /// via CLI bridge — with a larger step budget so the planner can
    /// fetch + read + synthesize across many MCP calls. Falls back to
    /// `.phoneLargeModel` when the user hasn't opted into a research
    /// tier yet.
    case research

    /// Classifier could not confidently assign one of the above. The
    /// caller MUST treat this as "run the full pipeline" — never skip
    /// the VLM or planner on an unknown intent.
    case unknown

    /// Classifier was not confident enough (below
    /// `PaceIntentPrediction.confidenceEscalationThreshold`) to trust
    /// its top-1 prediction. Instead of executing a potentially-wrong
    /// action, the turn is routed directly to the large model — same
    /// path as `.phoneLargeModel` but reached via low-confidence
    /// escalation rather than an explicit user request.
    case lowConfidenceEscalation
}

/// Result of a classification call. Confidence is roughly 0...1; a
/// low value tells CompanionManager to fall through to the full
/// pipeline regardless of the predicted class. Complexity estimates
/// how hard the query is — a confident `pureKnowledge` for "what's
/// the capital of France" (simple) vs "write a 2000-word essay
/// comparing WWI and WWII" (complex) route to different models.
struct PaceIntentPrediction: Equatable {
    let intent: PaceIntent
    let confidence: Double
    var complexity: PaceQueryComplexity = .simple

    /// Below this confidence the prediction is escalated to the large
    /// model via `.escalateToLargeModel` instead of executing the
    /// predicted action. This prevents the classifier from taking a
    /// potentially-wrong action when it isn't sure — the large model
    /// can always re-route if needed, but a wrong local action is
    /// harder to undo. 0.90 was chosen so the trained TinyGPT router
    /// (which outputs calibrated softmax probabilities) escalates only
    /// its genuinely uncertain predictions; the rule-based and FM
    /// backends rarely hit this threshold because their confidences
    /// are either 0.0 (nothing matched) or >= 0.90.
    nonisolated static let confidenceEscalationThreshold: Double = 0.90

    var route: PaceIntentRoute {
        // Low-confidence gate: before consulting the predicted intent,
        // check whether the classifier is sure enough to act on its
        // prediction. If not, escalate to the large model immediately
        // — do NOT execute the predicted action first.
        if intent != .unknown && confidence < Self.confidenceEscalationThreshold {
            return .escalateToLargeModel
        }
        // Complexity gate: if the query is complex AND the intent
        // would route to a local-only answer path, escalate to the
        // large model. The local 3B active-param model produces
        // noticeably worse output for long-form synthesis, multi-step
        // reasoning, and code generation. screenAction is excluded
        // because the action layer needs local model action-tag
        // generation ([CLICK:...], [TYPE:...]) — a cloud model can't
        // produce those. research and phoneLargeModel already route
        // to capable models; unknown runs the full pipeline.
        if complexity == .complex {
            switch intent {
            case .chitchat, .pureKnowledge, .screenDescription:
                return .escalateToLargeModel
            default:
                break
            }
        }
        switch intent {
        case .chitchat:
            return .chitchatFastPath
        case .pureKnowledge:
            return .answerDirectly
        case .screenDescription:
            return .readScreen
        case .screenAction:
            return .executeTool
        case .phoneLargeModel:
            return .phoneLargeModel
        case .research:
            return .research
        case .unknown:
            return .fullPipeline
        case .lowConfidenceEscalation:
            return .escalateToLargeModel
        }
    }
}

enum PaceIntentRoute: String, Equatable {
    case chitchatFastPath
    case answerDirectly
    case readScreen
    case executeTool
    case phoneLargeModel
    case research
    case fullPipeline
    /// Low-confidence escalation — route to the large model directly
    /// instead of running the full pipeline and risking a wrong action.
    case escalateToLargeModel
}

@MainActor
final class PaceIntentClassifier {
    /// Legacy floor kept for compatibility — predictions below this
    /// confidence are returned with intent `.unknown` so the caller can
    /// log the raw prediction. The actual routing decision (escalate
    /// vs. act) is made by `PaceIntentPrediction.route` using
    /// `confidenceEscalationThreshold` (0.90), which is higher than
    /// this floor.
    nonisolated static let defaultMinimumConfidence: Double = 0.6

    private let minimumConfidence: Double

    init(minimumConfidence: Double = PaceIntentClassifier.defaultMinimumConfidence) {
        self.minimumConfidence = minimumConfidence
        print("🧠 PaceIntentClassifier: rule-based backend")
    }

    /// Drops a leading wake phrase plus its trailing comma/space so every
    /// rule below sees the bare intent. Only the FIRST matching prefix is
    /// stripped; "hi pace" alone stays intact (it is itself chitchat).
    private static func strippedOfWakePhrase(_ lowercaseTranscript: String) -> String {
        for wakePhrasePrefix in wakePhrasePrefixes {
            guard lowercaseTranscript.hasPrefix(wakePhrasePrefix + " ")
                || lowercaseTranscript.hasPrefix(wakePhrasePrefix + ",") else {
                continue
            }
            let remainder = lowercaseTranscript
                .dropFirst(wakePhrasePrefix.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            // A bare wake phrase ("hey pace ?") classifies as itself.
            return remainder.isEmpty ? lowercaseTranscript : remainder
        }
        return lowercaseTranscript
    }

    /// Classify a transcript. Returns the raw prediction with the
    /// predicted intent and its confidence score. The routing decision
    /// (escalate to large model vs. execute the predicted action) is
    /// made by `PaceIntentPrediction.route`, which checks
    /// `confidenceEscalationThreshold`. Predictions below
    /// `minimumConfidence` are still marked `.unknown` for logging
    /// clarity, but the route will escalate either way.
    func classify(_ transcript: String) -> PaceIntentPrediction {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return PaceIntentPrediction(intent: .unknown, confidence: 0)
        }
        var prediction = ruleBasedClassify(trimmed)
        // Estimate complexity from the transcript. This runs after
        // intent classification so the complexity signal is independent
        // — a confidently-classified pureKnowledge query can still be
        // complex enough to warrant escalation to the large model.
        prediction.complexity = PaceQueryComplexityEstimator.estimate(transcript: trimmed)
        // Mark genuinely low-confidence predictions as .unknown for
        // logging — but preserve the confidence (and complexity) so
        // the route property can escalate to the large model.
        if prediction.confidence < minimumConfidence {
            return PaceIntentPrediction(
                intent: .unknown,
                confidence: prediction.confidence,
                complexity: prediction.complexity
            )
        }
        return prediction
    }

    /// Conversation-aware classification. After the per-query
    /// complexity is estimated, this checks whether the conversation
    /// context warrants upgrading complexity to `.complex` — e.g., a
    /// short follow-up ("so what about the edge cases?") in a deep
    /// technical conversation should escalate even without keywords.
    ///
    /// The conversation history is the same `conversationHistory`
    /// array used by the planner — no new state to manage.
    func classify(
        _ transcript: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)]
    ) -> PaceIntentPrediction {
        var prediction = classify(transcript)
        // Only upgrade — never downgrade. If the per-query estimator
        // already said .complex, conversation context can't make it
        // simpler. Only upgrade .simple or .moderate to .complex when
        // the conversation is deep enough to warrant it.
        if prediction.complexity != .complex {
            let shouldEscalate = PaceConversationComplexityTracker.shouldEscalateBasedOnContext(
                transcript: transcript,
                conversationHistory: conversationHistory
            )
            if shouldEscalate {
                prediction.complexity = .complex
            }
        }
        return prediction
    }

    // MARK: - Rule-based classifier
    //
    // Strong indicators for each class. Picked from the seed corpus
    // generation patterns at `evals/intent-corpus/seed.csv` — anything
    // the seed generator emits should be matchable here. False positives
    // are biased toward the more expensive class so we don't accidentally
    // skip the VLM on an ambiguous turn.

    /// Leading wake phrases users naturally prepend ("hey pace, …"). They
    /// carry no intent, so they are stripped before any rule matching —
    /// otherwise "Hey Pace, how is it going?" misses every chitchat
    /// pattern and pays the full screenshot+VLM+planner pipeline for a
    /// greeting.
    private static let wakePhrasePrefixes: [String] = [
        "hey pace", "hi pace", "hello pace", "ok pace", "okay pace",
        "yo pace",
    ]

    /// Conversational utterances that should answer about the user/Pace,
    /// not the screen. These route to the chitchat fast-path — which now
    /// just calls the text-only planner — so the LLM writes the reply
    /// instead of a hand-rolled lookup table.
    private static let chitchatStarters: [String] = [
        "hi pace", "hello pace", "hey there", "hi there", "good morning",
        "good evening", "good afternoon", "what's up", "how are you",
        "how's it going", "how is it going", "how are things",
        "how's everything", "how's your day",
        "can you hear me", "do you hear me", "are you there",
        "are you listening", "mic check", "test test",
        "thanks", "thank you", "appreciate it", "you're great",
        "you're awesome", "good job", "nice work", "bye for now",
        "talk later", "catch you later", "later pace", "see you",
        "alright", "okay cool", "got it", "sounds good", "perfect", "nice",
    ]

    private static let knowledgePatterns: [String] = [
        "what is ", "what's ", "explain ", "tell me about ",
        "how does ", "remind me what ", "what does ",
        "in plain english what is ", "describe ",
    ]

    /// Action verbs — when the transcript contains any of these AND
    /// doesn't look like a description hint ("describe", "show me"),
    /// it's probably a screen-action turn.
    private static let actionVerbs: [String] = [
        "click", "tap", "press", "hit", "open", "launch",
        "choose", "select", "focus", "toggle", "type ",
        "scroll", "page down", "page up", "save with",
        "save the file", "quit the app", "play", "pause",
        "next track", "previous track", "skip", "turn up",
        "turn down", "raise", "lower", "increase", "decrease",
        "dim", "brighten", "create", "make", "add",
        "compose", "draft", "reveal", "show in finder",
        "run shortcut",
    ]

    /// Tool-specific action phrases. These are the user-facing local tools
    /// Pace is allowed to route into the action pipeline even when the phrase
    /// does not start with a generic verb like "click".
    private static let actionToolPhrases: [String] = [
        "open app", "open apps", "open application", "launch app",
        "open url", "open website", "open a website", "go to ",
        "play music", "pause music", "music controls", "next song",
        "previous song", "volume up", "volume down", "turn volume up",
        "turn volume down", "reduce volume", "lower volume",
        "increase volume", "raise volume", "brightness up",
        "brightness down", "turn brightness up", "turn brightness down",
        "reduce brightness", "lower brightness", "increase brightness",
        "read calendar", "check calendar", "calendar reads",
        "what's on my calendar", "what is on my calendar",
        "create reminder", "add reminder", "remind me",
        "open finder", "show in finder", "reveal in finder",
        "finder notes", "make a note", "create note", "create notes",
        "open notes", "compose mail", "draft email", "create things",
        "add things", "run shortcut", "open messages",
    ]

    /// Journal-recall hints — questions about the user's own past activity.
    /// These answer from the local retrieval journals (screen watch + app
    /// usage), not from the current screen, so they route text-only: no
    /// screenshot, no VLM, and the LOCAL CONTEXT block carries the history.
    private static let journalRecallHints: [String] = [
        "what did i do today", "what did i do yesterday",
        "what did i do this morning", "what apps did i use",
        "which apps did i use", "how did i spend my time",
        "how am i spending my time", "how much time did i spend",
        "what have i been working on", "what have i been doing",
        "what was i doing earlier", "what was i working on",
        "summarize my day", "summarise my day",
    ]

    /// Description hints — phrases that suggest the user wants Pace to
    /// describe the screen rather than act on it.
    private static let descriptionHints: [String] = [
        "what's on the screen", "what am i looking at",
        "describe what i'm looking at", "describe this",
        "summarise this", "summarize", "what does this show",
        "what does this say", "what's happening on screen",
        "read this", "what's in front of me", "give me the gist",
        "what can you see", "tell me what's open", "what's this window about",
        "walk me through", "what's visible", "scan the screen",
        "what's on display", "what page am i on", "what app is this",
        "explain what's shown", "describe my current view",
        "what's this all about", "lay out what's on the screen",
    ]

    private static let largeModelHints: [String] = [
        "phone a large model", "ask the big model", "use the big model",
        "use a large model", "call the large model", "hard mode",
        "think deeply", "stronger model",
    ]

    /// Research-class triggers — phrases that suggest the user wants
    /// Pace to take a long, multi-step research turn (fetch + read +
    /// synthesize) against the configured research-tier model. Checked
    /// BEFORE the action-verb heuristic so "research X" routes to
    /// `.research` instead of being mis-classified as a tool action.
    /// Single-word "research" without trailing context is intentionally
    /// missing — "I researched HTML yesterday" should NOT trip the
    /// research lane.
    private static let researchHints: [String] = [
        "research ",
        "do research on",
        "do some research on",
        "research the ",
        "deep research",
        "look into ",
        "dig into ",
        "investigate ",
        "find sources ",
        "find me sources ",
        "summarize sources",
        "summarise sources",
        "what's the latest on",
        "whats the latest on",
        "give me a writeup on",
        "give me a write-up on",
        "compare ",
        " vs ",
        " versus ",
    ]

    private func ruleBasedClassify(_ transcript: String) -> PaceIntentPrediction {
        let lowercaseTranscript = Self.strippedOfWakePhrase(transcript.lowercased())

        // Chitchat: very high confidence when the whole transcript
        // matches a known phrase (often a single short utterance).
        // Trailing punctuation is ignored for the whole-utterance check —
        // dictation regularly appends "?" or "!" to greetings.
        let punctuationTrimmedTranscript = lowercaseTranscript
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        for chitchatPhrase in Self.chitchatStarters {
            if punctuationTrimmedTranscript == chitchatPhrase
                || lowercaseTranscript.hasPrefix(chitchatPhrase + " ") {
                return PaceIntentPrediction(intent: .chitchat, confidence: 0.95)
            }
        }

        // Research keywords checked BEFORE phoneLargeModel because
        // "deep research this" used to route to phoneLargeModel and we
        // want it to land on the more-specific research lane now.
        for researchHint in Self.researchHints {
            if lowercaseTranscript.contains(researchHint) {
                return PaceIntentPrediction(intent: .research, confidence: 0.92)
            }
        }

        for largeModelHint in Self.largeModelHints {
            if lowercaseTranscript.contains(largeModelHint) {
                return PaceIntentPrediction(intent: .phoneLargeModel, confidence: 0.90)
            }
        }

        // Journal recall checked BEFORE description/action rules: "what
        // apps did i use" must not read as a screen question ("apps") or
        // an action ("use"), and the answer lives in local history.
        for journalRecallHint in Self.journalRecallHints {
            if lowercaseTranscript.contains(journalRecallHint) {
                return PaceIntentPrediction(intent: .pureKnowledge, confidence: 0.95)
            }
        }

        // Description hints checked BEFORE action verbs because phrases
        // like "describe this" don't start with an action verb but
        // contain words like "this" that the broader heuristic could
        // miscategorise. Order matters here.
        for descriptionHint in Self.descriptionHints {
            if lowercaseTranscript.contains(descriptionHint) {
                return PaceIntentPrediction(intent: .screenDescription, confidence: 0.95)
            }
        }

        // Action: any action verb in the transcript.
        for actionVerb in Self.actionVerbs {
            if lowercaseTranscript.contains(actionVerb) {
                return PaceIntentPrediction(intent: .screenAction, confidence: 0.94)
            }
        }

        for actionToolPhrase in Self.actionToolPhrases {
            if lowercaseTranscript.contains(actionToolPhrase) {
                return PaceIntentPrediction(intent: .screenAction, confidence: 0.95)
            }
        }

        // Pure-knowledge: starts with a "what is" / "explain" pattern.
        for knowledgePattern in Self.knowledgePatterns {
            if lowercaseTranscript.hasPrefix(knowledgePattern) {
                return PaceIntentPrediction(intent: .pureKnowledge, confidence: 0.95)
            }
        }

        // Nothing matched — return .unknown with a deliberately low
        // confidence so the minimumConfidence gate downgrades it and
        // CompanionManager runs the full pipeline.
        return PaceIntentPrediction(intent: .unknown, confidence: 0.0)
    }
}
