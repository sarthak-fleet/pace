# codex-direct-brain Specification

## Purpose
TBD - created by archiving change codex-general-brain. Update Purpose after archive.
## Requirements
### Requirement: Direct-spawn CLI planner tier

The system SHALL provide a `.cliDirect` planner tier that plans **all** turn types by
direct-spawning the user's already-authenticated `codex` or `claude` CLI via
`PaceLocalCLIPlannerClient`, selectable in Settings → Planner. The tier SHALL carry an
upstream selection (`PaceLocalCLIUpstream`, `claude` | `codex`) defaulting to `codex`. The
tier SHALL require only the chosen CLI on `PATH` — no Node bridge server. Adding the tier
SHALL be additive: previously persisted `PacePlannerTier` values SHALL decode unchanged.

#### Scenario: Codex plans a general (non-research) turn

- **WHEN** the user has selected `.cliDirect` with upstream `codex`, consented, and the soak gate has elapsed
- **AND** a normal screen-action or pure-knowledge turn runs (not `.research`)
- **THEN** the planner is `PaceLocalCLIPlannerClient` spawning `codex`
- **AND** the streamed text flows through the same `CompanionSystemPrompt` and `<tool_calls>`/action-tag parsing as every other tier

#### Scenario: Existing tier selections are unaffected

- **WHEN** a user who previously selected `.local`, `.cliBridge`, `.directAPI`, or `.appleFoundationModels` upgrades
- **THEN** their persisted tier decodes and resolves exactly as before, with no behavior change

#### Scenario: Missing CLI surfaces a plain-language preflight

- **WHEN** `.cliDirect` is selected but the chosen upstream binary is not on `PATH`
- **THEN** a plain-language message is surfaced before the turn runs (not a silent hang)

### Requirement: Direct-spawn turns honor the off-device safety contract

A `.cliDirect` turn SHALL inherit the same off-device guarantees as the `.cliBridge` tier —
explicit consent, soak gate, off-device visual indicator, audit logging, and fail-loud
behavior — because spawning the CLI sends the turn's transcript and screen context off the
user's Mac.

#### Scenario: Consent + soak gate required before any direct-spawn turn

- **WHEN** `.cliDirect` is selected but direct-spawn consent has not been accepted or the soak gate has not elapsed
- **THEN** no direct-spawn turn runs and the planner falls back to local with a logged reason

#### Scenario: Bridge consent does not grant direct-spawn consent

- **WHEN** a user previously consented to the `.cliBridge` (Node bridge) path
- **AND** selects `.cliDirect` for the first time
- **THEN** consent is re-requested for the direct-spawn path and the soak gate restarts

#### Scenario: Off-device indicator + audit entry

- **WHEN** a `.cliDirect` turn is in flight
- **THEN** the menu-bar capsule tints amber (`isOffDeviceTurnInFlight`)
- **AND** a `PaceAPIAuditLog` entry records the bytes sent and the upstream target
- **AND** the privacy dashboard headline changes from "0 bytes sent off this Mac" to "X KB to <upstream>"

#### Scenario: Upstream failure fails loud

- **WHEN** the spawned CLI errors, is unauthenticated, or exits non-zero
- **THEN** the failure is narrated via `PaceFailureNarrator`
- **AND** the turn does NOT silently fall back to local unless the existing explicit fallback opt-in is set

