//
//  PaceAutomationCommandParser.swift
//  leanring-buddy
//
//  Pre-planner voice command parsers for the automation features:
//  cron scheduling, background agents, meeting mode, and skills.
//  Each parser follows the existing pattern (PaceWatchModeCommandParser,
//  PaceRecipeCommandParser, etc.) — deterministic, no model, no screen.
//

import Foundation

// MARK: - Cron scheduling

enum PaceCronCommand {
    case add(prompt: String, displayName: String)
    case list
    case remove(displayName: String)
    case enable
    case disable
}

nonisolated enum PaceCronCommandParser {
    static func parse(_ transcript: String) -> PaceCronCommand? {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // "list my scheduled tasks" / "list cron tasks" / "what are my recurring tasks"
        if lower.contains("list") && (lower.contains("recurring") || lower.contains("scheduled task") || lower.contains("cron")) {
            return .list
        }

        // "stop all recurring tasks" / "disable cron" / "disable scheduling"
        if (lower.contains("stop") || lower.contains("disable")) && (lower.contains("recurring") || lower.contains("cron") || lower.contains("scheduling")) {
            return .disable
        }

        // "enable cron" / "enable scheduling"
        if (lower.contains("enable") || lower.contains("start")) && (lower.contains("cron") || lower.contains("scheduling")) && !lower.contains("every") {
            return .enable
        }

        // "remove the <name> task" / "cancel the <name> recurring task"
        if (lower.hasPrefix("remove ") || lower.hasPrefix("cancel ")) && lower.contains("task") {
            let name = lower
                .replacingOccurrences(of: "remove the ", with: "")
                .replacingOccurrences(of: "remove ", with: "")
                .replacingOccurrences(of: "cancel the ", with: "")
                .replacingOccurrences(of: "cancel ", with: "")
                .replacingOccurrences(of: " recurring task", with: "")
                .replacingOccurrences(of: " task", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return .remove(displayName: name)
            }
        }

        // "every 30 minutes check my calendar" — delegate to PaceCronScheduler
        if lower.hasPrefix("every ") {
            if let task = PaceCronScheduler.parseVoiceCommand(transcript) {
                return .add(prompt: task.taskPrompt, displayName: task.displayName)
            }
        }

        return nil
    }
}

// MARK: - Background agents

enum PaceBackgroundAgentCommand {
    case run(prompt: String, displayName: String)
    case list
    case cancel(displayName: String)
}

nonisolated enum PaceBackgroundAgentCommandParser {
    static func parse(_ transcript: String) -> PaceBackgroundAgentCommand? {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // "list background tasks" / "what's running in the background"
        if (lower.contains("list") || lower.contains("what")) && lower.contains("background") {
            return .list
        }

        // "cancel the background task" / "stop the background agent"
        if (lower.contains("cancel") || lower.contains("stop")) && lower.contains("background") {
            return .cancel(displayName: lower)
        }

        // "in the background, draft a reply to..." / "background: do something"
        if lower.hasPrefix("in the background") || lower.hasPrefix("background:") {
            let prompt = lower
                .replacingOccurrences(of: "in the background", with: "")
                .replacingOccurrences(of: "background:", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ", :"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                let displayName = String(prompt.prefix(40))
                return .run(prompt: prompt, displayName: displayName)
            }
        }

        return nil
    }
}

// MARK: - Meeting mode

enum PaceMeetingModeCommand: Equatable {
    /// Start a meeting. `profileSlug` is the note profile named in the
    /// utterance ("start my one-on-one recording" → "one-on-one"), or
    /// nil for a generic start (normal profile precedence applies).
    case start(profileSlug: String?)
    case stop
    case status
}

nonisolated enum PaceMeetingModeCommandParser {
    /// Parse a meeting-mode voice command. `profiles` supplies the
    /// available note profiles so a spoken profile name/alias
    /// ("standup", "1:1") starts a meeting with that profile pinned.
    /// Pure — the caller loads profiles via `PaceMeetingNoteProfileLibrary`.
    static func parse(
        _ transcript: String,
        profiles: [PaceMeetingNoteProfile] = []
    ) -> PaceMeetingModeCommand? {
        let lower = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        let matchedProfileSlug = matchProfileSlug(in: lower, profiles: profiles)

        // A meeting command must be clearly about meetings/recording, so
        // generic verbs ("record a memo") don't hijack the planner.
        let hasMeetingContext = lower.contains("meeting")
            || lower.contains("recording")
            || matchedProfileSlug != nil

        let hasStartVerb = ["start", "begin", "enable", "record"].contains { lower.contains($0) }
        let hasStopVerb = ["stop", "finish", "wrap up", "disable", "end the meeting", "end meeting", "end recording", "end my"].contains { lower.contains($0) }
        let hasStatusWord = lower.contains("status") || lower.contains("is it on") || lower.contains("is meeting mode")

        // Bare "meeting mode" (no verb) still toggles on, preserving the
        // original behavior.
        if lower.contains("meeting mode") && !hasStartVerb && !hasStopVerb && !hasStatusWord {
            return .start(profileSlug: matchedProfileSlug)
        }

        guard hasMeetingContext else { return nil }

        if hasStatusWord && lower.contains("meeting") {
            return .status
        }
        // Stop before start: "stop the meeting recording" contains both.
        if hasStopVerb {
            return .stop
        }
        if hasStartVerb {
            return .start(profileSlug: matchedProfileSlug)
        }
        return nil
    }

    /// Find the best-matching non-`general` profile for the utterance by
    /// scanning each profile's name, slug, and `voiceAliases`. When
    /// several match, the longest matched term wins (most specific).
    static func matchProfileSlug(in lower: String, profiles: [PaceMeetingNoteProfile]) -> String? {
        var best: (slug: String, length: Int)?
        for profile in profiles where profile.slug != "general" {
            let terms = ([profile.name, profile.slug] + profile.voiceAliases)
                .map { $0.lowercased() }
                .filter { !$0.isEmpty }
            for term in terms where lower.contains(term) {
                if best == nil || term.count > best!.length {
                    best = (profile.slug, term.count)
                }
            }
        }
        return best?.slug
    }
}

// MARK: - Skills

enum PaceSkillCommand {
    case list
    case run(slug: String, name: String)
    case install(slug: String, name: String)
    /// Teach Pace a new skill from a free-form spoken description. The raw
    /// text (everything after the "teach/learn/create a skill" phrase) is
    /// structured into a `PaceSkillFile` by the create handler.
    case create(rawDescription: String)
}

nonisolated enum PaceSkillCommandParser {
    static func parse(_ transcript: String) -> PaceSkillCommand? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmedTranscript.lowercased()

        // "teach/learn/create a skill ..." — teach a new skill from a spoken
        // description. Checked FIRST: a create utterance ("teach a skill that
        // lists my tasks") also contains "skill"/"list", so it must win before
        // the list/install/run branches below. Everything after the trigger
        // phrase (case preserved) becomes the raw description.
        // "teach/learn/create" are unambiguous teach verbs. "make a skill" is
        // deliberately excluded — "make a skill list" would be captured as a
        // create of "list" instead of routing to the list branch.
        let createSkillPrefixes = [
            "teach you a skill",
            "teach yourself a skill",
            "teach a skill",
            "learn a new skill",
            "learn a skill",
            "create a new skill",
            "create a skill",
        ]
        for createSkillPrefix in createSkillPrefixes {
            // Anchored + case-insensitive match on the ORIGINAL string so the
            // returned range indexes `trimmedTranscript` directly (indices from
            // a separate `.lowercased()` copy are not safe to reuse here).
            guard let prefixRange = trimmedTranscript.range(
                of: createSkillPrefix,
                options: [.caseInsensitive, .anchored]
            ) else {
                continue
            }
            var rawDescription = String(trimmedTranscript[prefixRange.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " :,.-\t"))
            // Drop a leading connective the user naturally speaks after the
            // trigger phrase ("teach a skill TO open notes").
            for leadingConnective in ["to ", "that ", "called ", "named ", "for ", "which "] {
                if let connectiveRange = rawDescription.range(
                    of: leadingConnective,
                    options: [.caseInsensitive, .anchored]
                ) {
                    rawDescription = String(rawDescription[connectiveRange.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if !rawDescription.isEmpty {
                return .create(rawDescription: rawDescription)
            }
        }

        // "list skills" / "what skills do you have"
        if (lower.contains("list") || lower.contains("what")) && lower.contains("skill") {
            return .list
        }

        // "install the standup skill" / "add the standup notes skill"
        if (lower.hasPrefix("install ") || lower.hasPrefix("add ")) && lower.contains("skill") {
            let name = lower
                .replacingOccurrences(of: "install the ", with: "")
                .replacingOccurrences(of: "install ", with: "")
                .replacingOccurrences(of: "add the ", with: "")
                .replacingOccurrences(of: "add ", with: "")
                .replacingOccurrences(of: " skill", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let slug = name.replacingOccurrences(of: " ", with: "-")
                return .install(slug: slug, name: name)
            }
        }

        // "run the standup skill" / "execute the standup notes skill"
        if (lower.hasPrefix("run ") || lower.hasPrefix("execute ")) && lower.contains("skill") {
            let name = lower
                .replacingOccurrences(of: "run the ", with: "")
                .replacingOccurrences(of: "run ", with: "")
                .replacingOccurrences(of: "execute the ", with: "")
                .replacingOccurrences(of: "execute ", with: "")
                .replacingOccurrences(of: " skill", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let slug = name.replacingOccurrences(of: " ", with: "-")
                return .run(slug: slug, name: name)
            }
        }

        return nil
    }
}
