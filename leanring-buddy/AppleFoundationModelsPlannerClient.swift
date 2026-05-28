//
//  AppleFoundationModelsPlannerClient.swift
//  leanring-buddy
//
//  `BuddyPlannerClient` backed by macOS 26's built-in 3B on-device
//  language model via the FoundationModels framework. This is the
//  fast path: stateful `LanguageModelSession` means the KV cache
//  persists across turns, so second-turn TTFT collapses to ~100-300ms
//  (vs the 5-13s we measured for Qwen3-14B over LM Studio HTTP).
//
//  Quality caveat: the system model is ~3B params at 2-bit weights,
//  scoring around 44% on MMLU per Apple. It's purpose-built for
//  summarization, extraction, refinement — exactly Pace's planner
//  job for short voice turns. For multi-step plan-act-observe with
//  the VLM element map prepended, escalate to `LocalPlannerClient`.
//  The router (Create ML intent classifier) decides which to use.
//
//  Why we maintain a session ourselves (not one per call): the
//  whole TTFT win comes from KV-cache reuse across turns. Building
//  a fresh `LanguageModelSession` each call discards the cache and
//  re-prefills the instructions every turn — that's the same anti-
//  pattern LM Studio's OpenAI-compat layer falls into. We hold the
//  session across turns and only rebuild when the system prompt
//  changes (which Pace's static `CompanionSystemPrompt` blocks make
//  rare).
//

import Foundation
import FoundationModels

@available(macOS 26.0, *)
@MainActor
final class AppleFoundationModelsPlannerClient: BuddyPlannerClient {
    let displayName = "Apple Foundation Models (on-device 3B)"

    /// The system model is text-only; image input goes through the
    /// upstream VLM + OCR pipeline which prepends an element map to
    /// `userPrompt` before this client is called. Same shape as
    /// `LocalPlannerClient`.
    let supportsImageInput = false

    /// The active session. Held across turns so its KV cache survives.
    /// Reset when `currentSessionInstructions` no longer matches the
    /// system prompt we're being asked to use (which should almost
    /// never happen — Pace's system prompt is byte-stable until the
    /// user toggles `EnableActions`).
    private var currentSession: LanguageModelSession?
    private var currentSessionInstructions: String?

    /// Reset the session — caller-facing API for "start a new
    /// conversation." Useful for tests; CompanionManager doesn't
    /// currently need it because turns flow continuously, but the
    /// hook stays here so the menu-bar panel can wire a "clear
    /// conversation" button later.
    func resetSession() {
        currentSession = nil
        currentSessionInstructions = nil
    }

    func generateResponseStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        if !images.isEmpty {
            print("ℹ️ AppleFoundationModelsPlannerClient: \(images.count) image(s) attached but model is text-only — ignoring")
        }

        let startedAt = Date()
        let session = resolveSessionMatching(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory
        )

        var accumulatedResponseText = ""
        var hasLoggedFirstTokenLatency = false

        // `streamResponse(to:generating:)` returns an `AsyncSequence`
        // of `Snapshot`s. For `Content == String` each `Snapshot
        // .content` is the cumulative text so far — exactly what our
        // streaming-TTS pipeline wants (it does its own diff). The
        // explicit `generating: String.self` is needed because Swift
        // can't infer the generic Content parameter without context.
        let responseStream = session.streamResponse(
            to: userPrompt,
            generating: String.self
        )
        for try await snapshot in responseStream {
            accumulatedResponseText = snapshot.content
            if !hasLoggedFirstTokenLatency, !accumulatedResponseText.isEmpty {
                hasLoggedFirstTokenLatency = true
                let timeToFirstTokenMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                print("⚡ FM Planner TTFT: \(timeToFirstTokenMilliseconds)ms (\(conversationHistory.count + 1) msgs)")
                PaceTelemetryLog.recordPlannerTimeToFirstToken(
                    milliseconds: timeToFirstTokenMilliseconds,
                    modelIdentifier: displayName,
                    messageCount: conversationHistory.count + 1
                )
            }
            onTextChunk(accumulatedResponseText)
        }

        let totalDurationSeconds = Date().timeIntervalSince(startedAt)
        return (text: accumulatedResponseText, duration: totalDurationSeconds)
    }

    /// Pick a session whose KV cache is valid for the current call.
    /// Reuses across turns when instructions are unchanged — which is
    /// the common case. Rebuilds and seeds with history when the
    /// instructions changed (e.g. user toggled `EnableActions`).
    private func resolveSessionMatching(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)]
    ) -> LanguageModelSession {
        if let existingSession = currentSession,
           currentSessionInstructions == systemPrompt {
            return existingSession
        }

        // Build a fresh session. Seed the prior history via Transcript
        // so the model has continuity, then store for reuse.
        let seededTranscript = buildTranscript(fromConversationHistory: conversationHistory)
        let freshSession: LanguageModelSession
        if seededTranscript.entries.isEmpty {
            freshSession = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: { systemPrompt }
            )
        } else {
            freshSession = LanguageModelSession(
                model: SystemLanguageModel.default,
                transcript: seededTranscript
            )
        }

        currentSession = freshSession
        currentSessionInstructions = systemPrompt
        return freshSession
    }

    /// Convert Pace's `(userPlaceholder, assistantResponse)` pairs into
    /// a `Transcript` for session seeding. Each pair becomes a
    /// `prompt` entry and a `response` entry. Pace already strips
    /// thinking blocks + action tags before storing the assistant
    /// response, so what we pass here is the user-facing spoken text.
    /// `Transcript` is a `RandomAccessCollection` of `Entry` — its
    /// `init(entries:)` takes any `Sequence<Entry>`.
    private func buildTranscript(
        fromConversationHistory conversationHistory: [(userPlaceholder: String, assistantResponse: String)]
    ) -> Transcript {
        var transcriptEntries: [Transcript.Entry] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            transcriptEntries.append(.prompt(Transcript.Prompt(
                segments: [.text(Transcript.TextSegment(content: userPlaceholder))]
            )))
            transcriptEntries.append(.response(Transcript.Response(
                assetIDs: [],
                segments: [.text(Transcript.TextSegment(content: assistantResponse))]
            )))
        }
        return Transcript(entries: transcriptEntries)
    }
}

private extension Transcript {
    /// `Transcript` is a `RandomAccessCollection`, not a struct with
    /// an `.entries` property. This helper exists so the resolver
    /// code reads naturally — `transcript.entries.isEmpty` is more
    /// honest than `transcript.isEmpty` (which would also work via
    /// the collection conformance but reads like a string check).
    var entries: [Entry] {
        Array(self)
    }
}
