//
//  PaceSkillLoader.swift
//  leanring-buddy
//
//  Loads .skill.md files (Claude Code / OpenFelix compatible format)
//  and converts them to PaceRecordedFlow recipes. Inspired by
//  OpenFelix/OpenClicky's SKILL.md system.
//
//  .skill.md format:
//  ---
//  name: "Skill Name"
//  slug: "skill-slug"
//  description: "One-line description"
//  category: "morning" | "work" | "shutdown" | "custom"
//  requiredPreferences: ["preferredNotesFolder"]
//  trigger: "optional voice trigger phrase"
//  ---
//
//  ## Steps
//  1. Open Notes app
//  2. Create new note titled "Standup - {date}"
//  3. Add sections: Yesterday, Today, Blockers
//
//  ## Notes
//  Optional context for the planner.
//

import Foundation

/// Parsed .skill.md file.
struct PaceSkillFile: Codable, Equatable {
    let name: String
    let slug: String
    let description: String
    let category: String
    let requiredPreferences: [String]
    let trigger: String?
    let steps: [PaceSkillStep]
    let notes: String?
}

/// A single step in a skill file.
struct PaceSkillStep: Codable, Equatable {
    let instruction: String
    /// Optional tool call JSON (if the step is a direct tool call
    /// rather than a natural-language instruction).
    let toolCall: String?
}

/// Loader for .skill.md files. Scans the bundled Resources/skills/
/// directory and the user's ~/Library/Application Support/Pace/skills/
/// directory for .skill.md files, parses them, and converts them to
/// PaceRecordedFlow recipes that can be installed via the existing
/// recipe library.
enum PaceSkillLoader {

    /// Load all .skill.md files from bundled and user directories.
    static func loadAllSkills() -> [PaceSkillFile] {
        var skills: [PaceSkillFile] = []

        // Bundled skills (Resources/skills/*.skill.md)
        if let bundledSkills = loadSkillsFromDirectory(bundledSkillsDirectory()) {
            skills.append(contentsOf: bundledSkills)
        }

        // User skills (~/Library/Application Support/Pace/skills/*.skill.md)
        if let userSkills = loadSkillsFromDirectory(userSkillsDirectory()) {
            skills.append(contentsOf: userSkills)
        }

        return skills
    }

    /// Parse a single .skill.md file from its raw content.
    static func parse(skillMarkdown: String, fallbackSlug: String = "") -> PaceSkillFile? {
        // Split frontmatter and body.
        guard skillMarkdown.hasPrefix("---") else { return nil }
        let afterFirstDelimiter = String(skillMarkdown.dropFirst(3))
        guard let endRange = afterFirstDelimiter.range(of: "\n---\n") else { return nil }
        let frontmatter = String(afterFirstDelimiter[..<endRange.lowerBound])
        let body = String(afterFirstDelimiter[endRange.upperBound...])

        // Parse frontmatter as simple key: value pairs.
        var name = ""
        var slug = fallbackSlug
        var description = ""
        var category = "custom"
        var requiredPreferences: [String] = []
        var trigger: String?

        for line in frontmatter.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colonIndex)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            switch key {
            case "name": name = value
            case "slug": slug = value
            case "description": description = value
            case "category": category = value
            case "requiredPreferences":
                // Parse as JSON array or comma-separated list.
                requiredPreferences = parseStringArray(value)
            case "trigger": trigger = value.isEmpty ? nil : value
            default: break
            }
        }

        guard !name.isEmpty, !slug.isEmpty else { return nil }

        // Parse steps from the body.
        let (steps, notes) = parseBody(body)

        guard !steps.isEmpty else { return nil }

        return PaceSkillFile(
            name: name,
            slug: slug,
            description: description.isEmpty ? name : description,
            category: category,
            requiredPreferences: requiredPreferences,
            trigger: trigger,
            steps: steps,
            notes: notes
        )
    }

    /// Resolve a spoken run request ("run the cat search skill" →
    /// slug "cat-search", name "cat search") against the loaded skills.
    ///
    /// Exact slug/name matches win. When there is no exact match, a
    /// UNIQUE prefix/contains match resolves instead — the structurer
    /// often produces longer slugs than the user speaks (a skill taught
    /// as "cat search: open Safari" persists as `cat-search-open-safari`,
    /// but the user says "run the cat search skill"). Ambiguous fuzzy
    /// requests (2+ candidates) return nil so the caller keeps the
    /// honest "couldn't find" reply instead of guessing.
    static func resolveSkillForRunRequest(
        requestedSlug: String,
        requestedName: String,
        in skills: [PaceSkillFile]
    ) -> PaceSkillFile? {
        let lowercasedRequestedName = requestedName.lowercased()
        if let exactMatch = skills.first(where: {
            $0.slug == requestedSlug || $0.name.lowercased() == lowercasedRequestedName
        }) {
            return exactMatch
        }
        let fuzzyMatches = skills.filter { skill in
            skill.slug.hasPrefix(requestedSlug)
                || skill.name.lowercased().contains(lowercasedRequestedName)
        }
        return fuzzyMatches.count == 1 ? fuzzyMatches.first : nil
    }

    /// Convert a PaceSkillFile's steps into a planner prompt that
    /// the agent loop can execute. Unlike recipes (which are recorded
    /// UI actions replayed verbatim), skills are natural-language
    /// instructions that the planner interprets and executes step by
    /// step — more flexible and more resilient to UI changes.
    static func toPlannerPrompt(_ skill: PaceSkillFile) -> String {
        var prompt = "Execute the \"\(skill.name)\" skill. Follow these steps:\n\n"
        for (index, step) in skill.steps.enumerated() {
            // A step with a non-nil `toolCall` was authored to run a
            // specific tool, so we append an explicit directive using the
            // SAME tool-call JSON dialect the planner sees everywhere else
            // (`PaceLocalToolDefinition.schemaExample`, e.g.
            // `{"tool":"create_note",...}`). A step WITHOUT a toolCall
            // renders exactly as before — byte-identical — so natural-
            // language skills are unaffected.
            if let toolCallJSON = step.toolCall, !toolCallJSON.isEmpty {
                prompt += "\(index + 1). \(step.instruction) (use tool: \(toolCallJSON))\n"
            } else {
                prompt += "\(index + 1). \(step.instruction)\n"
            }
        }
        if let notes = skill.notes, !notes.isEmpty {
            prompt += "\nContext: \(notes)\n"
        }
        return prompt
    }

    // MARK: - Run-time preference enforcement

    /// The outcome of checking a skill's `requiredPreferences` before a
    /// run. `.ready` means every required preference is set and the run
    /// may proceed. `.missingPreference` names the FIRST unset preference
    /// so the caller can speak a precise, plain-language message.
    enum PaceSkillRunPreflight: Equatable {
        case ready
        case missingPreference(preferenceKey: String)
    }

    /// Deterministic, no-LLM check run BEFORE a taught skill executes.
    /// Mirrors `PaceRecipeLibrary.install`'s `requiredPreferences` gate —
    /// it reads through the SAME `PaceLocalMemoryStoreReadable` abstraction
    /// the recipe installer uses (`PaceLocalMemoryStore` in production), so
    /// there is exactly one source of truth for where a required preference
    /// lives. A preference is "set" only when the store returns a non-nil
    /// value for it. Unknown keys (not a valid `PaceLocalMemoryKey`) are
    /// treated as missing, because a skill can't run against a preference
    /// Pace doesn't know how to read.
    static func preflightRequiredPreferences(
        for skill: PaceSkillFile,
        memoryStore: PaceLocalMemoryStoreReadable.Type = PaceLocalMemoryStore.self
    ) -> PaceSkillRunPreflight {
        for requiredPreferenceKey in skill.requiredPreferences {
            guard let resolvedKey = PaceLocalMemoryKey(rawValue: requiredPreferenceKey) else {
                return .missingPreference(preferenceKey: requiredPreferenceKey)
            }
            if memoryStore.string(for: resolvedKey) == nil {
                return .missingPreference(preferenceKey: requiredPreferenceKey)
            }
        }
        return .ready
    }

    // MARK: - Private helpers

    private static func loadSkillsFromDirectory(_ directory: URL) -> [PaceSkillFile]? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        var skills: [PaceSkillFile] = []
        for entry in entries where entry.pathExtension == "md" {
            guard let content = try? String(contentsOf: entry, encoding: .utf8) else { continue }
            let fallbackSlug = entry.deletingPathExtension().lastPathComponent
            if let skill = parse(skillMarkdown: content, fallbackSlug: fallbackSlug) {
                skills.append(skill)
            }
        }
        return skills.isEmpty ? nil : skills
    }

    private static func bundledSkillsDirectory() -> URL {
        // In the app bundle, skills live in Resources/skills/
        Bundle.main.resourceURL?
            .appendingPathComponent("skills", isDirectory: true)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    static func userSkillsDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    private static func parseStringArray(_ value: String) -> [String] {
        // Try JSON array first.
        if let data = value.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            return array
        }
        // Fall back to comma-separated.
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseBody(_ body: String) -> (steps: [PaceSkillStep], notes: String?) {
        var steps: [PaceSkillStep] = []
        var notes: String?

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var inStepsSection = false
        var inNotesSection = false
        var notesLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("## ") {
                let heading = String(trimmed.dropFirst(3)).lowercased()
                inStepsSection = heading.contains("step")
                inNotesSection = heading.contains("note")
                continue
            }

            if inStepsSection {
                // Match numbered list items: "1. Do something"
                if let dotIndex = trimmed.firstIndex(of: ".") {
                    let prefix = String(trimmed[..<dotIndex])
                    if Int(prefix.trimmingCharacters(in: .whitespaces)) != nil {
                        let instruction = String(trimmed[trimmed.index(after: dotIndex)...])
                            .trimmingCharacters(in: .whitespaces)
                        if !instruction.isEmpty {
                            // Check for tool call in code block.
                            let toolCall = extractToolCall(from: instruction)
                            steps.append(PaceSkillStep(
                                instruction: toolCall == nil ? instruction : instruction,
                                toolCall: toolCall
                            ))
                        }
                    }
                }
            } else if inNotesSection {
                if !trimmed.isEmpty {
                    notesLines.append(trimmed)
                }
            }
        }

        if !notesLines.isEmpty {
            notes = notesLines.joined(separator: " ")
        }

        return (steps, notes)
    }

    /// Extract a tool call JSON from a code block in the instruction.
    private static func extractToolCall(from instruction: String) -> String? {
        // Look for ```json ... ``` blocks.
        guard let startRange = instruction.range(of: "```json") else {
            return nil
        }
        let searchStart = startRange.upperBound
        guard let endRange = instruction.range(of: "```", range: searchStart..<instruction.endIndex) else {
            return nil
        }
        let jsonContent = instruction[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return jsonContent.isEmpty ? nil : jsonContent
    }
}

// MARK: - Writing / teaching skills

extension PaceSkillLoader {

    /// Serialize a `PaceSkillFile` back into `.skill.md` text. This is the
    /// inverse of `parse(...)` — parsing the output reproduces the same
    /// `PaceSkillFile` for every field the format carries, so a taught skill
    /// on disk is indistinguishable from a hand-authored one. Optional fields
    /// (`trigger`, `notes`) and an empty `requiredPreferences` are omitted so
    /// the file stays clean.
    static func serialize(_ skill: PaceSkillFile) -> String {
        var frontmatterLines: [String] = []
        frontmatterLines.append("name: \"\(skill.name)\"")
        frontmatterLines.append("slug: \"\(skill.slug)\"")
        frontmatterLines.append("description: \"\(skill.description)\"")
        frontmatterLines.append("category: \"\(skill.category)\"")
        if !skill.requiredPreferences.isEmpty {
            let joinedPreferences = skill.requiredPreferences
                .map { "\"\($0)\"" }
                .joined(separator: ", ")
            frontmatterLines.append("requiredPreferences: [\(joinedPreferences)]")
        }
        if let trigger = skill.trigger, !trigger.isEmpty {
            frontmatterLines.append("trigger: \"\(trigger)\"")
        }

        var body = "\n## Steps\n\n"
        for (index, step) in skill.steps.enumerated() {
            body += "\(index + 1). \(step.instruction)\n"
        }
        if let notes = skill.notes, !notes.isEmpty {
            body += "\n## Notes\n\n\(notes)\n"
        }

        return "---\n" + frontmatterLines.joined(separator: "\n") + "\n---\n" + body
    }

    /// Persist a taught skill to the user skills directory. Uses the same
    /// atomic temp-file + rename pattern as `PaceFlowStore.writeAtomically`
    /// and `PaceMCPServerCatalog.atomicallyWriteMCPServers`, so a crash
    /// mid-write can never leave a half-written skill on disk. Bundled skills
    /// are never touched — this only ever writes into `userSkillsDirectory()`.
    static func save(
        _ skill: PaceSkillFile,
        to directory: URL = PaceSkillLoader.userSkillsDirectory()
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationFileURL = directory.appendingPathComponent("\(skill.slug).skill.md")
        let skillFileData = Data(serialize(skill).utf8)
        try writeSkillFileAtomically(data: skillFileData, to: destinationFileURL)
    }

    /// Delete a taught skill by slug. Idempotent (missing file is a no-op).
    /// Only ever removes from the user directory; bundled skills are read-only.
    static func deleteUserSkill(
        slug: String,
        in directory: URL = PaceSkillLoader.userSkillsDirectory()
    ) throws {
        let targetFileURL = directory.appendingPathComponent("\(slug).skill.md")
        if FileManager.default.fileExists(atPath: targetFileURL.path) {
            try FileManager.default.removeItem(at: targetFileURL)
        }
    }

    /// All user-taught skills (the user directory only, not bundled). The
    /// Settings "Your skills" section lists these; keeping them separate from
    /// `loadAllSkills()` is what lets the UI show bundled skills as read-only.
    static func listUserSkills(
        in directory: URL = PaceSkillLoader.userSkillsDirectory()
    ) -> [PaceSkillFile] {
        loadSkillsFromDirectory(directory) ?? []
    }

    // MARK: - Natural-language → structured skill

    /// System prompt for the local planner that turns a free-form spoken
    /// description ("when I say start my day, open Notes then open Slack")
    /// into a structured skill. JSON-only, mirroring the structured-synthesis
    /// approach in `PaceMeetingNotesBuilder`. The user's raw description is
    /// passed as the planner's `userPrompt`.
    static let skillStructuringSystemPrompt: String = """
    You convert a spoken description of a repeatable task into a structured "skill".
    Return ONLY a JSON object — no prose, no markdown fences — with exactly this shape:
    {"name": "<short title>", "trigger": "<phrase the user will say to run it, or empty>", "steps": ["<step 1>", "<step 2>"], "notes": "<optional context or empty>"}
    Rules:
    - Each step is a single imperative instruction, e.g. "Open Notes" or "Create a note titled Standup".
    - Preserve the user's intent. Do NOT invent steps they did not describe.
    - If the description says "when I say X", set trigger to X and name to a title-case of X.
    - The steps array must be non-empty.
    """

    /// Decode the planner's JSON response into a `PaceSkillFile`. Lenient:
    /// strips markdown fences, grabs the outermost `{...}` if the model wrapped
    /// it in prose, ignores unknown fields, and rejects empty name/steps.
    /// `fallbackName` is used when the model omits a name.
    static func skillFromStructuredJSON(_ rawText: String, fallbackName: String) -> PaceSkillFile? {
        let jsonString = extractJSONObject(from: rawText)
        guard let jsonData = jsonString.data(using: .utf8),
              let response = try? JSONDecoder().decode(StructuredSkillResponse.self, from: jsonData)
        else {
            return nil
        }

        let steps = (response.steps ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { PaceSkillStep(instruction: $0, toolCall: nil) }
        guard !steps.isEmpty else { return nil }

        // Prefer the model's name; if it omitted one, derive a distinctive name
        // from the first step rather than the generic `fallbackName` — otherwise
        // every unnamed skill shares one slug and overwrites the previous one.
        let fallbackNameFromFirstStep = steps.first
            .map { derivedSkillName(fromFirstStep: $0.instruction) } ?? fallbackName
        let resolvedName = sanitizedSkillName(nonEmptyTrimmed(response.name) ?? fallbackNameFromFirstStep)
        guard !resolvedName.isEmpty else { return nil }

        return PaceSkillFile(
            name: resolvedName,
            slug: PaceFlowStore.slug(for: resolvedName),
            description: resolvedName,
            category: "custom",
            requiredPreferences: [],
            trigger: sanitizedFrontmatterValue(response.trigger),
            steps: steps,
            notes: sanitizedNotes(response.notes)
        )
    }

    /// Deterministic, no-model fallback used when the local planner is
    /// unavailable or returns junk, so teaching a skill never hard-fails.
    /// Splits the description into steps on natural connectives and pulls a
    /// "when I say <trigger>," clause out of the front if present. Best-effort:
    /// returns nil only when it can't find a single step.
    static func structureSkillDeterministically(from rawDescription: String) -> PaceSkillFile? {
        let trimmedDescription = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else { return nil }

        var trigger: String?
        var actionText = trimmedDescription
        // Case-insensitive, anchored match so only a LEADING "when I say …" is
        // treated as the trigger clause (never a mid-sentence occurrence), and
        // the returned range indexes `trimmedDescription` directly (safe to slice).
        if let whenClauseRange = trimmedDescription.range(of: "when i say", options: [.caseInsensitive, .anchored]) {
            let afterWhenClause = String(trimmedDescription[whenClauseRange.upperBound...])
            if let firstCommaIndex = afterWhenClause.firstIndex(of: ",") {
                trigger = afterWhenClause[..<firstCommaIndex]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " '\"\u{201C}\u{201D}"))
                actionText = String(afterWhenClause[afterWhenClause.index(after: firstCommaIndex)...])
            }
        }

        let stepSeparators = [" then ", ", and ", ", ", "; ", ". "]
        var stepFragments = [actionText]
        for separator in stepSeparators {
            stepFragments = stepFragments.flatMap { $0.components(separatedBy: separator) }
        }
        let steps = stepFragments
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .,;")) }
            .filter { !$0.isEmpty }
            .map { PaceSkillStep(instruction: capitalizedFirstLetter($0), toolCall: nil) }
        guard !steps.isEmpty else { return nil }

        let resolvedTrigger = sanitizedFrontmatterValue(trigger)
        // No trigger → derive a distinctive name from the first step so two
        // different triggerless skills don't collapse to one slug and silently
        // overwrite each other on save.
        let resolvedName = sanitizedSkillName(
            resolvedTrigger.map(capitalizedFirstLetter)
                ?? derivedSkillName(fromFirstStep: steps[0].instruction)
        )
        return PaceSkillFile(
            name: resolvedName,
            slug: PaceFlowStore.slug(for: resolvedName),
            description: resolvedName,
            category: "custom",
            requiredPreferences: [],
            trigger: resolvedTrigger,
            steps: steps,
            notes: sanitizedNotes(trimmedDescription)
        )
    }

    /// Build a skill from the Settings "Teach a skill" form fields — one step
    /// per non-empty line, tolerating a leading "1. " the user may type. No
    /// model involved: this is the typed sibling of the voice path. Returns
    /// nil when the name or step list is empty.
    static func skillFromForm(
        name: String,
        stepsText: String,
        trigger: String?,
        notes: String?
    ) -> PaceSkillFile? {
        let resolvedName = sanitizedSkillName(name)
        guard !resolvedName.isEmpty else { return nil }

        let steps = stepsText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var stepText = line.trimmingCharacters(in: .whitespaces)
                // Allow the user to type "1. Open Notes" — drop a leading number.
                if let dotIndex = stepText.firstIndex(of: "."),
                   Int(stepText[..<dotIndex].trimmingCharacters(in: .whitespaces)) != nil {
                    stepText = String(stepText[stepText.index(after: dotIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                return stepText
            }
            .filter { !$0.isEmpty }
            .map { PaceSkillStep(instruction: $0, toolCall: nil) }
        guard !steps.isEmpty else { return nil }

        return PaceSkillFile(
            name: resolvedName,
            slug: PaceFlowStore.slug(for: resolvedName),
            description: resolvedName,
            category: "custom",
            requiredPreferences: [],
            trigger: sanitizedFrontmatterValue(trigger),
            steps: steps,
            notes: sanitizedNotes(notes)
        )
    }

    // MARK: - Private write/parse helpers

    /// JSON shape the planner is asked to return. All fields optional so a
    /// partial response still decodes and the caller can validate/reject.
    private struct StructuredSkillResponse: Codable {
        let name: String?
        let trigger: String?
        let steps: [String]?
        let notes: String?
    }

    private static func writeSkillFileAtomically(data: Data, to destinationFileURL: URL) throws {
        let parentDirectoryURL = destinationFileURL.deletingLastPathComponent()
        let temporaryFileURL = parentDirectoryURL.appendingPathComponent(
            ".\(destinationFileURL.lastPathComponent).pace.tmp.\(UUID().uuidString)"
        )
        try data.write(to: temporaryFileURL, options: [.atomic])
        do {
            if FileManager.default.fileExists(atPath: destinationFileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationFileURL,
                    withItemAt: temporaryFileURL
                )
            } else {
                try FileManager.default.moveItem(at: temporaryFileURL, to: destinationFileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryFileURL)
            throw error
        }
    }

    /// Pull a JSON object out of a planner response that may be fenced or
    /// wrapped in prose. Strips a leading ```json fence + trailing ```, then
    /// falls back to the outermost `{...}`.
    private static func extractJSONObject(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let firstNewlineIndex = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewlineIndex)...])
            } else {
                trimmed = String(trimmed.dropFirst(3))
            }
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let openBraceIndex = trimmed.firstIndex(of: "{"),
           let closeBraceIndex = trimmed.lastIndex(of: "}"),
           openBraceIndex < closeBraceIndex {
            return String(trimmed[openBraceIndex...closeBraceIndex])
        }
        return trimmed
    }

    private static func sanitizedSkillName(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A concise, distinctive skill name derived from the first step, used as
    /// the fallback when there is no trigger and no model-provided name. Without
    /// this, every such skill collapses to one generic name → one slug → one
    /// filename, so a second teach silently overwrites the first on `save`.
    private static func derivedSkillName(fromFirstStep firstStep: String) -> String {
        let leadingWords = firstStep
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .prefix(6)
        let candidate = capitalizedFirstLetter(leadingWords.joined(separator: " "))
        return candidate.isEmpty ? "Custom Skill" : candidate
    }

    /// Clean a value destined for a double-quoted `.skill.md` frontmatter line
    /// (name/description/trigger): strip embedded quotes and newlines so the
    /// hand-rolled serializer/parser round-trips losslessly. Returns nil if
    /// empty after cleaning.
    private static func sanitizedFrontmatterValue(_ value: String?) -> String? {
        guard let trimmed = nonEmptyTrimmed(value) else { return nil }
        let cleaned = trimmed
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return nonEmptyTrimmed(cleaned)
    }

    /// Clean a value destined for the `## Notes` body: collapse to a single
    /// line and drop a leading Markdown heading marker so a stray "## …" line
    /// can't flip `parseBody`'s section detection when the file is re-read.
    private static func sanitizedNotes(_ value: String?) -> String? {
        guard let trimmed = nonEmptyTrimmed(value) else { return nil }
        let singleLine = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let withoutLeadingHash = singleLine.drop(while: { $0 == "#" || $0 == " " })
        return nonEmptyTrimmed(String(withoutLeadingHash))
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func capitalizedFirstLetter(_ text: String) -> String {
        guard let firstCharacter = text.first else { return text }
        return firstCharacter.uppercased() + text.dropFirst()
    }
}
