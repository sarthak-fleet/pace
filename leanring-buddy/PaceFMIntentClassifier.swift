//
//  PaceFMIntentClassifier.swift
//  leanring-buddy
//
//  LLM-backed intent classifier using Apple Foundation Models' typed
//  `@Generable` output. Replaces the 200-line rule-based phrase-list
//  classifier — language understanding belongs to the language model,
//  not to a Swift if/contains tree.
//
//  Latency: greedy-sampled enum classification on a 3B in-process model
//  is ~80-200ms warm. The session is reused across calls so the system
//  prompt's KV cache survives, keeping the marginal cost low.
//
//  Availability: when Apple Intelligence isn't enabled / device isn't
//  eligible, `PaceIntentClassifierFactory` falls back to the rule-based
//  classifier so non-Apple-Intelligence Macs still route turns.
//

import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct PaceFMIntentClassification {
    @Guide(description: """
    The single best route for handling the user's turn.
    - chitchat: greetings, thanks, goodbyes, mic checks like "can you hear me", "are you there".
    - pureKnowledge: any question that wants a spoken answer WITHOUT looking at the current screen — factual questions ("what is HTML"), self-history ("what apps did I use today"), AND questions about you (Pace) yourself: what you can do, your features, who you are, how you work ("what can you do", "what all can you do", "who are you").
    - screenDescription: user wants Pace to look at and describe the current screen ("what's on the screen", "what am I looking at").
    - screenAction: user wants Pace to DO something via the action layer — click, type, open, launch, play, pause, create, draft, etc.
    - research: multi-step research turn — "research X", "compare X vs Y", "dig into the latest on X", "summarize sources on X".
    - phoneLargeModel: user explicitly asked for a bigger/stronger model ("phone a large model", "hard mode", "use the big model").
    - unknown: anything else ambiguous; CompanionManager will run the full pipeline.
    """)
    let route: PaceFMIntentRoute
}

@available(macOS 26.0, *)
@Generable
enum PaceFMIntentRoute: String, CaseIterable {
    case chitchat
    case pureKnowledge
    case screenDescription
    case screenAction
    case research
    case phoneLargeModel
    case unknown

    var asPaceIntent: PaceIntent {
        switch self {
        case .chitchat: return .chitchat
        case .pureKnowledge: return .pureKnowledge
        case .screenDescription: return .screenDescription
        case .screenAction: return .screenAction
        case .research: return .research
        case .phoneLargeModel: return .phoneLargeModel
        case .unknown: return .unknown
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class PaceFMIntentClassifier {
    private static let routingInstructions = """
    You classify a single user voice turn into ONE routing category for Pace, a macOS voice companion. Pick the most accurate route. A turn that asks a question and wants a spoken answer — including questions about Pace itself ("what can you do") — is pureKnowledge, NOT unknown. Reserve unknown only for turns you genuinely cannot categorize; a clear question or a clear action is never unknown.
    """

    func classify(_ transcript: String) async -> PaceIntentPrediction {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return PaceIntentPrediction(intent: .unknown, confidence: 0)
        }
        let resolvedSession = makeSession()
        let generationOptions = GenerationOptions(
            sampling: .greedy,
            temperature: 0,
            maximumResponseTokens: 30
        )

        do {
            let typedResponse: LanguageModelSession.Response<PaceFMIntentClassification>
            typedResponse = try await resolvedSession.respond(
                to: "user said: \"\(trimmedTranscript)\"",
                generating: PaceFMIntentClassification.self,
                options: generationOptions
            )
            return PaceIntentPrediction(
                intent: typedResponse.content.route.asPaceIntent,
                confidence: 0.95,
                complexity: PaceQueryComplexityEstimator.estimate(transcript: trimmedTranscript)
            )
        } catch {
            // Falling back to .unknown means CompanionManager runs the
            // full pipeline — safe degradation, never a wrong route.
            print("⚠️ FM intent classifier failed: \(error.localizedDescription) — falling through to full pipeline")
            return PaceIntentPrediction(intent: .unknown, confidence: 0)
        }
    }

    /// Conversation-aware classification — upgrades complexity based
    /// on conversation depth and topic continuity.
    func classify(
        _ transcript: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)]
    ) async -> PaceIntentPrediction {
        var prediction = await classify(transcript)
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

    /// For stateless classification, create a fresh session each call.
    /// Reusing a session accumulates conversation history that overflows
    /// the context window after ~20 calls, causing all subsequent calls
    /// to fail. Classification is stateless — there's no reason to keep
    /// history between calls.
    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: Instructions(Self.routingInstructions)
        )
    }
}

@MainActor
enum PaceIntentClassifierFactory {
    static func makeDefault() -> any PaceIntentClassifying {
        if #available(macOS 26.0, *) {
            let systemLanguageModel = SystemLanguageModel.default
            if case .available = systemLanguageModel.availability {
                print("🧠 PaceIntentClassifier: Apple Foundation Models backend")
                return PaceFMIntentClassifierAdapter(classifier: PaceFMIntentClassifier())
            }
        }
        print("🧠 PaceIntentClassifier: rule-based fallback (Apple Intelligence unavailable)")
        return PaceRuleBasedIntentClassifierAdapter(classifier: PaceIntentClassifier())
    }
}

@MainActor
protocol PaceIntentClassifying: AnyObject {
    func classify(_ transcript: String) async -> PaceIntentPrediction
    /// Conversation-aware classification — upgrades complexity based
    /// on conversation depth and topic continuity.
    func classify(
        _ transcript: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)]
    ) async -> PaceIntentPrediction
}

/// Rule-based classifier wrapped in the async protocol shape so both
/// backends present the same surface to CompanionManager.
@MainActor
final class PaceRuleBasedIntentClassifierAdapter: PaceIntentClassifying {
    private let classifier: PaceIntentClassifier

    init(classifier: PaceIntentClassifier) {
        self.classifier = classifier
    }

    func classify(_ transcript: String) async -> PaceIntentPrediction {
        classifier.classify(transcript)
    }

    func classify(
        _ transcript: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)]
    ) async -> PaceIntentPrediction {
        classifier.classify(transcript, conversationHistory: conversationHistory)
    }
}

@available(macOS 26.0, *)
@MainActor
final class PaceFMIntentClassifierAdapter: PaceIntentClassifying {
    private let classifier: PaceFMIntentClassifier

    init(classifier: PaceFMIntentClassifier) {
        self.classifier = classifier
    }

    func classify(_ transcript: String) async -> PaceIntentPrediction {
        await classifier.classify(transcript)
    }

    func classify(
        _ transcript: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)]
    ) async -> PaceIntentPrediction {
        await classifier.classify(transcript, conversationHistory: conversationHistory)
    }
}
