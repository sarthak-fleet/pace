//
//  PaceMeetingNoteProfile.swift
//  leanring-buddy
//
//  A meeting note profile is a Pace-native "shape" for synthesized
//  meeting notes. Each profile declares the sections that matter for a
//  meeting type (a standup wants Yesterday/Today/Blockers; a 1:1 wants
//  topics/feedback/follow-ups) and whether action items + decisions are
//  extracted and grounded to the transcript. Profiles render into the
//  JSON-only synthesis prompt consumed by `PaceMeetingNotesBuilder`;
//  the output JSON contract stays `{summary, actionItems, decisions}`
//  so the panel, retrieval journal, and lenient decoder are unchanged.
//
//  The `general` profile reproduces the pre-profiles prompt byte-for-
//  byte, so existing users and existing tests see zero behavior change
//  until they opt into another profile.
//
//  Bundled profiles ship at `Resources/meeting-note-profiles/<slug>.json`
//  and user profiles override by slug from
//  `~/Library/Application Support/Pace/meeting-note-profiles/`, mirroring
//  the `PaceRecipeLibrary` / `PaceSkillLoader` pattern.
//
//  See openspec/changes/adaptive-meeting-notes for the full spec.
//

import Foundation

// MARK: - Section

/// One labeled section the profile asks the summary to be organized
/// around. `key` is a stable identifier; `title` is the human label
/// used in the rendered prompt; `instruction` tells the planner what
/// to capture for it.
nonisolated struct PaceMeetingNoteSection: Equatable, Codable, Sendable {
    let key: String
    let title: String
    let instruction: String

    init(key: String, title: String, instruction: String) {
        self.key = key
        self.title = title
        self.instruction = instruction
    }
}

// MARK: - Profile

nonisolated struct PaceMeetingNoteProfile: Equatable, Codable, Sendable {
    /// Stable identifier. Matches the bundled resource filename and is
    /// used for override-by-slug and preference persistence.
    let slug: String
    /// Human-readable name shown in the Settings + panel pickers.
    let name: String
    /// 1-line description shown in the picker.
    let description: String
    /// Ordered sections the summary is organized around. A single
    /// section is rendered as a one-line summary rule (this is how the
    /// `general` profile reproduces the legacy prompt); multiple
    /// sections render as a labeled "organize into these sections" block.
    let sections: [PaceMeetingNoteSection]
    /// Whether the planner is asked to extract action items.
    let emitsActionItems: Bool
    /// Whether the planner is asked to extract decisions.
    let emitsDecisions: Bool
    /// Whether action items should be grounded to the transcript by
    /// asking the planner for a short verbatim quote per item. The
    /// `general` profile leaves this false so its rendered prompt stays
    /// identical to the legacy prompt.
    let groundsActionItems: Bool

    /// Natural spoken trigger phrases for starting this profile by voice
    /// ("start my one-on-one recording"). The parser also matches the
    /// profile's `name` and `slug`, so aliases only need to cover extra
    /// phrasings (e.g. "1:1", "daily standup"). Optional in JSON —
    /// defaults to empty, so user profiles need not declare it.
    let voiceAliases: [String]

    init(
        slug: String,
        name: String,
        description: String,
        sections: [PaceMeetingNoteSection],
        emitsActionItems: Bool,
        emitsDecisions: Bool,
        groundsActionItems: Bool,
        voiceAliases: [String] = []
    ) {
        self.slug = slug
        self.name = name
        self.description = description
        self.sections = sections
        self.emitsActionItems = emitsActionItems
        self.emitsDecisions = emitsDecisions
        self.groundsActionItems = groundsActionItems
        self.voiceAliases = voiceAliases
    }

    // Lenient decode: `voiceAliases` is optional in the JSON so profiles
    // authored before it existed (and user profiles that don't need it)
    // still decode cleanly. All other fields are required.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        sections = try container.decode([PaceMeetingNoteSection].self, forKey: .sections)
        emitsActionItems = try container.decode(Bool.self, forKey: .emitsActionItems)
        emitsDecisions = try container.decode(Bool.self, forKey: .emitsDecisions)
        groundsActionItems = try container.decode(Bool.self, forKey: .groundsActionItems)
        voiceAliases = try container.decodeIfPresent([String].self, forKey: .voiceAliases) ?? []
    }

    // MARK: - Prompt rendering

    /// Render this profile into the JSON-only synthesis system prompt.
    /// For the `general` profile this equals `PaceMeetingNotesPrompt
    /// .systemPrompt` byte-for-byte (asserted by tests), so upgrading
    /// existing users changes nothing.
    func renderSystemPrompt() -> String {
        var lines: [String] = []
        lines.append(
            "You are a meeting-notes transcription assistant. Read the meeting transcript and produce structured notes as JSON. Return ONLY a JSON object with this exact shape, no markdown fences, no commentary:"
        )

        // JSON shape line.
        var shapeParts: [String] = ["\"summary\": string"]
        if emitsActionItems {
            let itemFields = groundsActionItems
                ? "{\"text\": string, \"owner\": string|null, \"due\": string|null, \"quote\": string|null}"
                : "{\"text\": string, \"owner\": string|null, \"due\": string|null}"
            shapeParts.append("\"actionItems\": [\(itemFields)]")
        }
        if emitsDecisions {
            shapeParts.append("\"decisions\": [string]")
        }
        lines.append("{\(shapeParts.joined(separator: ", "))}")

        lines.append("Rules:")

        // Summary rule. A single section renders as one line (this is
        // what makes `general` identical to the legacy prompt); multiple
        // sections render as a labeled block.
        if sections.count == 1 {
            lines.append("- \(sections[0].key): \(sections[0].instruction)")
        } else if sections.count > 1 {
            lines.append("- summary: organize into these labeled sections:")
            for section in sections {
                lines.append("  - \(section.title): \(section.instruction)")
            }
        } else {
            lines.append("- summary: a brief paragraph capturing the key points of the meeting.")
        }

        if emitsActionItems {
            var actionRule = "- actionItems: concrete tasks agreed during the meeting. Omit if none."
            if groundsActionItems {
                actionRule += " For each, include a short verbatim \"quote\" (a few words) from the transcript where it was agreed, or null."
            }
            lines.append(actionRule)
        }
        if emitsDecisions {
            lines.append("- decisions: explicit decisions made. Omit if none.")
        }

        lines.append("- If the transcript is too short or unclear, return empty arrays and a brief summary.")
        lines.append("- Do NOT include attendees or any field not listed above.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Built-in

    /// The compatibility anchor. Its rendered prompt is byte-for-byte
    /// identical to `PaceMeetingNotesPrompt.systemPrompt`, and it is the
    /// fallback whenever no profile is selected or inference fails.
    static let general = PaceMeetingNoteProfile(
        slug: "general",
        name: "General",
        description: "Balanced notes for any meeting: summary, action items, decisions.",
        sections: [
            PaceMeetingNoteSection(
                key: "summary",
                title: "Summary",
                instruction: "2-4 sentences capturing the key points of the meeting."
            )
        ],
        emitsActionItems: true,
        emitsDecisions: true,
        groundsActionItems: false
    )
}
