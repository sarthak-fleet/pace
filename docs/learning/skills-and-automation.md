# Skills and automation

Pace automates repeated work at four tiers, from most literal to most
flexible: **Tools** (single planner-invoked actions, one per turn) are the
atomic unit every tier above builds on; **Recipes** (bundled, pre-built
flows a user installs by name) are the zero-effort on-ramp; **Flows**
(user-recorded AX click/key sequences replayed verbatim) capture a
literal demonstration; **Skills** (natural-language step lists the
planner re-grounds every run) trade pixel-exactness for resilience to UI
change. This page covers recipes, flows, skills, the voice parsers that
route commands to each tier before the planner, meeting-note profiles,
and the cron scheduler.

## Teachable skills (`.skill.md`)
- What: A skill is a numbered step list stored as a `.skill.md` file (YAML frontmatter + `## Steps` body) that the planner **re-grounds every run** rather than replaying recorded UI actions.
- Why here: The most flexible automation tier — resilient to UI changes because each run re-interprets the steps against the current screen, unlike a recorded flow's verbatim role-path replay.
- Where: `PaceSkillLoader.swift` — `PaceSkillFile` (parsed model: `name`, `slug`, `description`, `category`, `requiredPreferences`, `trigger`, `steps: [PaceSkillStep]`, `notes`); `PaceSkillLoader.parse`/`serialize` round-trip the format; `toPlannerPrompt` turns steps into a numbered instruction prompt for the agent loop.
- Source: internal — `.skill.md` format, inspired by OpenFelix/OpenClicky's SKILL.md convention (see file header comment).

## Teaching a skill by voice or form
- What: Two on-device paths turn a description into a structured `PaceSkillFile`: a spoken description parsed by a privacy-pinned local planner call, or a typed Settings form parsed deterministically.
- Why here: "Teachable by telling" — the user never hand-writes YAML; `skillFromStructuredJSON` (planner path) and `skillFromForm` (typed path) both funnel into the same `PaceSkillFile` model, with `structureSkillDeterministically` as a no-model fallback so teaching never hard-fails.
- Where: `PaceSkillLoader.swift` — `skillStructuringSystemPrompt`, `skillFromStructuredJSON`, `structureSkillDeterministically`, `skillFromForm`; persistence via `PaceSkillLoader.save`/`deleteUserSkill`/`listUserSkills` (atomic temp-file + rename, same pattern as `PaceFlowStore`).
- Source: internal — no external spec.

## Skill command parser
- What: A pure, deterministic parser that recognizes "teach a skill…", "list skills", "install/run the `<name>` skill" before the transcript ever reaches the planner.
- Why here: Fast-path routing — teaching, installing, and running a skill are all one-shot deterministic intents that would otherwise burn a planner round-trip; the create-phrase check runs first so "teach a skill that lists my tasks" doesn't get misrouted to the list branch.
- Where: `PaceAutomationCommandParser.swift` — `PaceSkillCommand` (enum: `.list`, `.run`, `.install`, `.create(rawDescription:)`), `PaceSkillCommandParser.parse`.
- Source: internal — no external spec.

## Recorded flows (pixel tier)
- What: A flow records a literal sequence of AX-tree clicks/keystrokes during a user demonstration (`PaceAXRolePath` per step), then replays them verbatim by walking the same recorded accessibility role-paths, with adaptive retry (delay grows ×1.5, capped, per the file header) if a step's target hasn't resolved yet.
- Why here: The least flexible but most literal automation tier — exact reproduction of a demonstrated sequence, used when a skill's re-grounded interpretation would be too loose (e.g. a precise multi-field form fill).
- Where: `PaceFlowReplayer.swift` — `PaceFlowReplayer` (replay engine), `PaceFlowReplayOutcome`, `PaceAXPressResolution`, `PaceLiveFlowReplayActionSink`; recording side in `PaceFlowRecorder.swift` — `PaceFlowRecorder`, `PaceAXRolePath`; the stored model, `PaceRecordedFlow`, lives in `PaceFlowReplay.swift`.
- Source: internal — no external spec.

## Flow store
- What: Atomic JSON persistence for recorded flows — one file per flow, keyed by a slug derived from the flow's display name.
- Why here: The durable-storage layer both recipes and flows share: installing a bundled recipe means writing its flow JSON into the same store a user-recorded flow would land in, so `run_flow` doesn't need to know which tier produced a flow.
- Where: `PaceFlowStore.swift` — `PaceFlowStore` (`slug(for:)`, atomic `writeAtomically`), `PaceFlowStoreError`; the Settings surface for browsing/installing/deleting flows and recipes is `PaceFlowsSettingsTab.swift` — `PaceFlowsSettingsTab`.
- Source: internal — no external spec.

## Recipe library
- What: A small set of pre-built flow definitions ("recipes") bundled as `Resources/recipes/<slug>.json`, installable by voice or from Settings → Flows.
- Why here: The zero-effort on-ramp to automation — a user says "install the morning standup recipe" and gets a working flow with no recording step; recipes that need user state declare `requiredPreferences` and refuse install until that preference is set.
- Where: `PaceRecipeLibrary.swift` — `PaceBundledRecipe` (`slug`, `requiredPreferences`, …), `PaceRecipeLibrary.install`, `PaceRecipeValidationIssue`, `PaceRecipeInstallError`. Bundled recipe/skill/profile JSON is all validated at app launch through one shared entry point, `PaceToolRegistry.validateForAppStartup` (`PaceToolRegistry.swift`), so malformed drift in any bundled file fails loud at startup instead of silently at first use.
- Source: internal — no external spec.

## Voice command parsers (pre-planner fast path)
- What: A family of small, pure, deterministic parsers that each recognize one automation surface's trigger phrases and short-circuit before the transcript reaches the planner or intent classifier.
- Why here: Installing a recipe, toggling watch mode, starting a profiled meeting, or teaching/running a skill are all one-shot deterministic intents — routing them here avoids a planner round-trip and keeps the grammar unit-testable without constructing `CompanionManager`.
- Where: `PaceRecipeCommandParser.swift` — `PaceRecipeCommandParser`/`PaceRecipeCommand`; `PaceWatchModeCommandParser.swift` — `PaceWatchModeCommandParser`/`PaceWatchModeCommand`; `PaceAutomationCommandParser.swift` — `PaceMeetingModeCommandParser`/`PaceMeetingModeCommand` and `PaceSkillCommandParser`/`PaceSkillCommand` (both live in this one file alongside `PaceCronCommandParser` and `PaceBackgroundAgentCommandParser`).
- Source: internal — no external spec.

## Meeting note profiles
- What: A selectable `PaceMeetingNoteProfile` (bundled `general`/`standup`/`one-on-one` in `Resources/meeting-note-profiles/`, plus user overrides) shapes how `PaceMeetingNotesBuilder` synthesizes a meeting's summary/action-items/decisions.
- Why here: Meetily-informed but Pace-native adaptive notes — the `general` profile reproduces the pre-profiles prompt byte-for-byte (the compat anchor), so adding profiles changed zero behavior for existing users by default.
- Where: `PaceMeetingNoteProfile.swift` — `PaceMeetingNoteProfile` (`.general` static value), `PaceMeetingNoteSection`; `PaceMeetingNoteProfileLibrary.swift` — `PaceMeetingNoteProfileLibrary.loadProfiles`/`resolveProfile`/`shouldInfer`. Selection precedence (`resolveProfile`): explicit per-meeting slug → non-`general` pinned default preference → locally-inferred slug (only when inference is enabled and no non-general default is pinned) → `general`.
- Source: internal — meetily-informed, no external spec.

## Cron scheduler
- What: A general-purpose recurring-task scheduler — "every 30 minutes check my calendar" — where each task is a stored interval + prompt that fires through the normal restraint-gated speaking pipeline.
- Why here: Extends automation from "user-triggered" (recipes/flows/skills) to "time-triggered": a fired task sends its `taskPrompt` through the same planner pipeline a live voice turn would use, so scheduled automation gets the same tool/approval guarantees as a spoken command.
- Where: `PaceCronScheduler.swift` — `PaceCronScheduler` (`@MainActor` `ObservableObject`, `.shared`), `PaceCronTask`; voice grammar in `PaceAutomationCommandParser.swift` — `PaceCronCommandParser`/`PaceCronCommand`.
- Source: internal — no external spec.

## See also
- [`README.md`](README.md)
