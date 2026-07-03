//
//  PaceDictationFastPath.swift
//  leanring-buddy
//
//  Zero-latency dictation mode — STT → cleanup → paste, no planner.
//
//  Inspired by Apple Dictation's "text flows directly into the focused
//  field" pattern. When the user triggers dictation mode, Pace skips
//  the planner entirely:
//
//    1. STT transcript arrives (Apple Speech, on-device)
//    2. PaceDictationPostProcessor cleans up spoken punctuation,
//       capitalization, and contractions (deterministic, <1ms)
//    3. Optional Apple FM cleanup pass for disfluencies ("um", "uh",
//       repeated words) — only if Apple Intelligence is available
//    4. Result is typed directly into the focused field via CGEvent
//       (same typeText path as [TYPE:...])
//
//  No screenshot, no VLM, no planner, no TTS. The text just appears.
//
//  Trigger: a voice command "dictate ..." / "type ..." that routes
//  here before the planner. "write ..." intentionally does NOT
//  trigger — it is a compose verb ("write an email to Alice") that
//  belongs to the planner.
//

import Foundation

/// Dictation fast path — bypasses the planner for pure text input.
/// The transcript is cleaned up and typed directly into the focused
/// field.
@MainActor
final class PaceDictationFastPath {
    static let shared = PaceDictationFastPath()

    private init() {}

    /// Callback to type text into the focused app. Set by
    /// CompanionManager to `actionExecutor.typeText`.
    var typeTextCallback: ((String) async -> Void)?

    /// Callback to run Apple FM cleanup. Set by CompanionManager.
    /// Returns the cleaned-up text, or nil if Apple FM isn't available.
    var appleFMCleanupCallback: ((String) async -> String?)?

    /// Whether the dictation fast path is enabled. When false,
    /// dictation commands fall through to the normal planner path.
    var isEnabled: Bool = true

    /// Process a dictation transcript: clean it up and type it into
    /// the focused field. Returns the cleaned text that was typed
    /// (for UI display), or nil if the fast path was skipped.
    func dictate(transcript: String, mode: String? = nil) async -> String? {
        guard isEnabled else { return nil }
        guard let typeTextCallback else {
            print("📝 Dictation fast path: no typeText callback, skipping")
            return nil
        }

        PaceLatencyBudget.shared.mark(.sttComplete)

        // Step 1: deterministic cleanup (<1ms)
        var cleanedText = PaceDictationPostProcessor.process(rawText: transcript, mode: mode)

        // Step 2: optional Apple FM cleanup for disfluencies.
        // This is the only async step and it's optional — if Apple FM
        // isn't available, we skip it and use the deterministic output.
        if let appleFMCleanupCallback, !cleanedText.isEmpty {
            PaceLatencyBudget.shared.mark(.plannerStart)
            if let fmCleaned = await appleFMCleanupCallback(cleanedText) {
                cleanedText = fmCleaned
            }
            PaceLatencyBudget.shared.mark(.plannerComplete)
        }

        guard !cleanedText.isEmpty else { return nil }

        // Step 3: type the text directly into the focused field.
        PaceLatencyBudget.shared.mark(.toolExecStart)
        await typeTextCallback(cleanedText)
        PaceLatencyBudget.shared.mark(.toolExecComplete)

        print("📝 Dictation fast path: typed \(cleanedText.count) chars, skipped planner/VLM/TTS")

        return cleanedText
    }

    /// Check if a transcript looks like a dictation command.
    /// "dictate ..." / "type ..." trigger the fast path. "write" is
    /// deliberately NOT a trigger: compose intents like "write an
    /// email to Alice" must reach the planner's Mail-compose flow,
    /// not get literally typed into the focused field.
    /// Returns the text to dictate (with the trigger word stripped),
    /// or nil if the transcript isn't a dictation command.
    static func extractDictationText(from transcript: String) -> String? {
        let normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for trigger words at the start.
        let triggers = ["dictate", "type"]

        for trigger in triggers {
            // Match "dictate " or "dictate, " or "dictate: "
            let prefix = trigger + " "
            if normalized.lowercased().hasPrefix(prefix) {
                let text = String(normalized.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return text
            }
        }

        return nil
    }
}
