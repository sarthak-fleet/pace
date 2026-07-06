## 1. Profile model + library (pure, test-first)

- [x] 1.1 Add `PaceMeetingNoteProfile.swift`: `PaceMeetingNoteProfile` value type (`slug`, `name`, `description`, `sections: [PaceMeetingNoteSection{key,title,instruction}]`, `emitsActionItems`, `emitsDecisions`), `Codable`/`Equatable`/`Sendable`, plus a `general` static profile whose rendered prompt equals the current `PaceMeetingNotesPrompt`.
- [x] 1.2 Add `PaceMeetingNoteProfileLibrary.swift` mirroring `PaceRecipeLibrary`: load bundled `Resources/meeting-note-profiles/*.json`, load user overrides from `~/Library/Application Support/Pace/meeting-note-profiles/`, override-by-slug, startup validation (loud for bundled, soft-skip for user).
- [x] 1.3 Add bundled `Resources/meeting-note-profiles/{general,standup,one-on-one}.json` and register the resource dir in the app target/Info.plist alongside recipes/skills.
- [x] 1.4 Tests: `PaceMeetingNoteProfileTests` (general renders identical prompt) + `PaceMeetingNoteProfileLibraryTests` (bundled load/validate, user override, malformed user skipped, malformed bundled fails validation).

## 2. Profile-driven synthesis + grounding

- [x] 2.1 Add optional `source: PaceMeetingActionItemSource?` (`{timestamp: Date, quote: String}`) to `PaceMeetingActionItem`; keep decode backward-compatible.
- [x] 2.2 Refactor `PaceMeetingNotesBuilder.build` to take a `profile: PaceMeetingNoteProfile`, render the profile's sections into the JSON-only prompt, and map the response back (section map + gated actionItems/decisions). Preserve `synthesisFailed` behavior.
- [x] 2.3 Add deterministic grounding: parse an optional per-action `quote`, resolve it against `[PaceMeetingTurnRecord]` (case/space-insensitive, longest-match-wins) into a `source`; unresolved → nil.
- [x] 2.4 Tests: `PaceMeetingNotesBuilderTests` additions — profile-shaped output, grounded/ungrounded action items, backward-compatible decode of pre-change notes, general profile == legacy output, planner-failure still preserves transcript.

## 3. Selection + inference wiring

- [x] 3.1 `PaceUserPreferencesStore`: add `meetingNotesDefaultProfileSlug` (default "general") and `meetingNotesProfileInferenceEnabled` (default false) with getters/setters.
- [x] 3.2 In `PaceMeetingModeController.stop()`, resolve profile precedence (explicit-for-meeting → default pref → local inference → general) before calling `build`; add a settable per-meeting profile override.
- [x] 3.3 Add local inference: a tiny classify call on the injected privacy-pinned planner returning one known slug, with deterministic `general` fallback on failure/unknown. Gated by the inference toggle only — the silent, post-meeting classify call produces no speech, so a `PaceRestraintGate` check (which governs speech during calls) would be inconsistent with the existing ungated synthesis path; deliberately omitted.
- [x] 3.4 Tests: precedence resolution unit test (explicit wins, inference fallback, disabled inference → default/general).

## 4. Surfaces (Settings, panel, retrieval)

- [x] 4.1 `PaceGeneralSettingsTab` meeting-notes subsection: default-profile picker (populated from the library) + inference toggle.
- [x] 4.2 `CompanionPanelView` meeting card: per-meeting profile picker + render grounded action items with a jump-to-transcript affordance.
- [x] 4.3 `PaceMeetingNotesJournal`: include action-item grounding (timestamp/quote) in the journaled retrieval document text.
- [x] 4.4 Test: journal document text contains grounding and remains lexically matchable.

## 6. Voice-triggered profile selection

- [x] 6.1 Add optional `voiceAliases: [String]` to `PaceMeetingNoteProfile` (lenient decode, default []); populate standup/one-on-one bundled JSON with natural aliases (1:1, one on one, daily standup, scrum…).
- [x] 6.2 Extend `PaceMeetingModeCommand.start` to carry `profileSlug: String?`; broaden `PaceMeetingModeCommandParser.parse` to recognize "start/record … <profile> …" and match name/slug/aliases against the available profiles (pure — profiles passed in).
- [x] 6.3 In `handleMeetingModeCommand`, set `controller.selectedProfileSlug` before `start()` when a profile was named, and confirm by name in the spoken response.
- [x] 6.4 Tests: parser recognizes the user's phrasings (named + generic start, stop unaffected, alias matching), lenient decode of profiles without `voiceAliases`.

## 5. Docs + verification

- [x] 5.1 Update `docs/prds/on-device-meeting-notes.md` (or add a short profiles PRD), `docs/key-files.md`, and AGENTS.md architecture note for the new files.
- [x] 5.2 Run `bash scripts/test-pace.sh` — must end green.
- [x] 5.3 Commit with the standard format (do NOT run release-pace.sh); then `/opsx:archive adaptive-meeting-notes` + update `PROJECT_STATUS.md`.
