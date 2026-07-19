# Teachable Skills (teach-by-telling)

Status: **shipped** (2026-07-04). Canonical status: [PROJECT_STATUS.md](https://github.com/HeyPace/pace/blob/main/PROJECT_STATUS.md).

## Problem

Pace's capability tiers include a Tier-5 goal: *capture intent, not pixels, and
re-ground via the model on replay.* Two halves existed separately, both inadequate:

- **`record_flow`** (Flows tab) teaches *by demonstration* but captures AX steps
  and replays them **verbatim** — brittle to any UI change. Pixel tier.
- **`.skill.md` skills** (`PaceSkillLoader`) are the intent layer — NL steps the
  planner re-grounds each run — but **could not be created**. Only hand-authored
  files in `~/Library/Application Support/Pace/skills/`. The voice grammar was
  list/run/install only (`install` was a no-op that just confirmed a bundled
  skill exists), one bundled skill shipped, and the Skills tab showed something
  else entirely (built-in tools + MCP servers), so taught skills were invisible.

## What shipped

Users teach Pace a skill by **describing it in natural language** — spoken or
typed — fully on-device. Example:

> "Pace, learn a skill. When I say 'start my day', open Notes, make a standup
> note, then open Slack." → saved `start-my-day.skill.md` (3 NL steps) →
> "run start my day" executes it through the normal planner loop, re-grounding
> the UI each run.

Modality chosen: **teach-by-telling** (lowest risk, on-device). Teach-by-
demonstration (generalize `record_flow` AX steps → NL skill) is a deferred
fast-follow on the same foundation.

## Design

Zero new source files — the pure, testable core lives in `PaceSkillLoader`; the
one async model call lives where a planner already exists.

### Skill writer — `PaceSkillLoader.swift`
- `serialize(_:)` — inverse of `parse`, round-trips (parse∘serialize = identity).
- `save` / `deleteUserSkill` / `listUserSkills` — user-dir only; bundled skills
  never touched. Atomic temp-file + rename, mirroring `PaceFlowStore.writeAtomically`
  and `PaceMCPServerCatalog.atomicallyWriteMCPServers`. Slug reuses
  `PaceFlowStore.slug(for:)`.

### NL → skill
- `skillStructuringSystemPrompt` + `skillFromStructuredJSON` — a privacy-pinned
  LOCAL planner (`BuddyPlannerClientFactory.makeLocalOnlyPlannerForPrivacyPinnedFeatures()`,
  the same pin meeting-notes uses — teaching stays on-device even for cloud-tier
  users) structures the description into `{name, trigger, steps, notes}`. Lenient
  decode: strips markdown fences, grabs the outermost `{…}`, rejects empty steps.
- `structureSkillDeterministically` — no-model fallback that splits on connectives
  (" then ", ", ", "; ", ". ") and pulls a "when I say …," clause out of the front.
  Runs when the planner is unavailable or returns junk, so teaching never hard-fails.

### Voice — `PaceAutomationCommandParser.swift`
- `PaceSkillCommand.create(rawDescription:)`; the parser matches "teach/learn/
  create a skill …" (anchored, case-insensitive) and captures the rest. Checked
  **before** list/install/run so a create utterance ("teach a skill that lists…")
  isn't swallowed. No new routing slot — the existing dispatch at
  `CompanionManager+AgentLoop.swift` already runs this parser.

### Create handler — `CompanionManager.handleTeachSkillCommand`
Local planner → `skillFromStructuredJSON` → deterministic fallback → `save` →
spoken confirmation ("saved X with N steps — say run X anytime"). Fails soft.

### Settings — `PaceSkillsView.swift`
Resolves the naming collision: a **"Your skills"** section lists taught skills
(delete per row) with an inline **"Teach a skill"** typed form
(`skillFromForm`, deterministic, no model — the typed sibling of the voice path),
plus a read-only "Built-in skills" subsection. Skills tab now = "everything Pace
can do, including what you taught it."

## Privacy

Structuring runs on the privacy-pinned local planner — never the CLI bridge or
Direct API tier — so a taught skill never leaves the Mac, consistent with the
on-device moat.

## Deferred

- **Teach by demonstration → generalize** — reuse `record_flow` AX capture, convert
  steps to NL intent, save as a skill. Builds on `PaceSkillLoader.save` + the
  Skills-tab section shipped here.
- `requiredPreferences` on *taught* skills — default `[]`; bundled-skill preference
  gating via `PaceLocalMemoryKey` is unchanged.

## Tests

`leanring-buddyTests/PaceSkillLoaderTests.swift`: serialize round-trip, save/list/
delete + overwrite (temp dir), `skillFromStructuredJSON` (clean/fenced/prose/empty/
fallback/garbage), deterministic splitter, `skillFromForm`, and parser create +
list/install/run regression. Run via `bash scripts/test-pace.sh PaceSkillLoaderTests`.
