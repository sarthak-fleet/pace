## ADDED Requirements

### Requirement: Bundled note profiles

The system SHALL ship a curated set of meeting note profiles as bundled JSON under
`Resources/meeting-note-profiles/<slug>.json`. Each profile SHALL declare a `slug`,
a display `name`, and an ordered list of `sections`, where each section declares a
`title` and a synthesis `instruction`. A `general` profile SHALL exist whose output
is byte-for-byte identical to the pre-change `{summary, actionItems, decisions}`
synthesis so existing behavior is preserved.

#### Scenario: Bundled profiles load at startup

- **WHEN** the app starts
- **THEN** every bundled profile JSON is parsed and validated
- **AND** an invalid or malformed bundled profile fails validation loudly at startup (matching the existing recipe/skill validation posture) rather than shipping silently broken

#### Scenario: Default profile reproduces existing output

- **WHEN** a meeting is synthesized with the `general` profile and no other profile is selected
- **THEN** the produced `PaceMeetingNotes` has the same `summary`, `actionItems`, and `decisions` shape as before this change

### Requirement: User-custom note profiles

The system SHALL load user-authored profiles from Application Support
(`~/Library/Application Support/Pace/meeting-note-profiles/`). A user profile whose
`slug` matches a bundled profile SHALL override the bundled one.

#### Scenario: User profile overrides bundled by slug

- **WHEN** a user profile exists with the same slug as a bundled profile
- **THEN** the user profile is used and the bundled one is ignored

#### Scenario: Malformed user profile is skipped, not fatal

- **WHEN** a user profile file is malformed
- **THEN** it is skipped with a logged reason and the remaining valid profiles still load (a bad user file MUST NOT crash the app)

### Requirement: Profile selection per meeting

The system SHALL select exactly one profile to synthesize each meeting. Selection
precedence SHALL be: (1) a profile explicitly chosen for the active meeting, else
(2) the user's default profile preference, else (3) a locally-inferred profile, else
(4) the `general` profile.

#### Scenario: Explicit selection wins

- **WHEN** the user picks a profile for the active meeting
- **THEN** that profile is used regardless of the default preference or inference

#### Scenario: Inference is local and never blocks

- **WHEN** no profile is explicitly chosen and no default is pinned and inference is enabled
- **THEN** the local planner classifies the transcript into one of the known profile slugs
- **AND** if inference fails, errors, or returns an unknown slug, synthesis falls back to `general` and the meeting still completes

#### Scenario: Fully on-device

- **WHEN** any profile selection, inference, or synthesis runs
- **THEN** zero bytes are sent off the Mac (the `PaceAPIAuditLog` records no off-device entries for the meeting)

### Requirement: Voice-triggered profile selection

A profile SHALL be startable by voice in one phrase, e.g. "start my
one-on-one recording" or "record this standup". Each profile MAY declare
`voiceAliases` (natural trigger phrases like "1:1", "one on one",
"daily standup"); the meeting-mode voice command parser SHALL match the
transcript against a profile's name, slug, and aliases and start a
meeting with that profile pre-selected. A start utterance naming no
profile SHALL start a meeting with the normal precedence (default →
inference → general), exactly as the panel-only flow does.

#### Scenario: Named profile starts a meeting with that profile

- **WHEN** the user says "start my one-on-one recording"
- **THEN** meeting mode starts
- **AND** the meeting's explicit profile is set to `one-on-one` before synthesis

#### Scenario: Generic start uses normal precedence

- **WHEN** the user says "start meeting mode" (no profile named)
- **THEN** meeting mode starts with no explicit profile
- **AND** synthesis resolves via default preference → inference → general

#### Scenario: Stop is unaffected

- **WHEN** the user says "stop recording" / "stop meeting mode"
- **THEN** meeting mode stops and notes are synthesized as before

### Requirement: Profile-driven synthesis

The notes builder SHALL render the selected profile's sections into the JSON-only
synthesis prompt and map the planner's response back into `PaceMeetingNotes`. On
planner failure or malformed JSON, the builder SHALL preserve the raw transcript and
set `synthesisFailed: true`, exactly as today.

#### Scenario: Planner failure preserves transcript

- **WHEN** the planner throws or returns unparseable output during profile-driven synthesis
- **THEN** the returned notes have `synthesisFailed: true` with the transcript preserved
