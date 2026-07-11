## Why

Users want to point Pace's "brain" at Codex because it is integration-friendly — it
brings its own MCP/tool ecosystem and stays current without Pace shipping model weights.
Pace can *already* route planning to Codex today, but only through the `.cliBridge` tier,
which requires a separate Node bridge server running at `localhost:3456`
(`CloudBridgePlannerClient` speaks SSE-over-HTTP to it, and the Node process spawns the CLI).
That extra hop is friction the product doesn't need: Pace already ships
`PaceLocalCLIPlannerClient`, which direct-spawns the `codex` (or `claude`) CLI with
stream-json parsing (ported from CodeVetter) and needs only `codex` on `PATH`. But that
client is wired for **one narrow path** — the `.research` intent lane
(`researchTurnPlannerOverride` in `CompanionManager+AgentLoop.swift`). So the cleanest,
lowest-friction way to "use Codex as the brain" exists in the codebase but is unreachable
as a general planner.

This is privacy-sensitive. Pace's headline moat is "0 bytes sent off this Mac." Routing a
turn's transcript + screen context to Codex sends bytes off-device via the CLI's provider,
so a general Codex brain MUST inherit the exact same guarantees the cloud-bridge tier
already enforces: explicit consent + soak gate, the amber off-device capsule indicator, an
audit-log entry that flips the privacy dashboard off its "0 bytes" headline, and fail-loud
behavior (no silent fallback to local).

## What Changes

- Add a **`.cliDirect` planner tier**: a user-selectable general planner that direct-spawns
  the user's already-authenticated `codex` (or `claude`) CLI via the existing
  `PaceLocalCLIPlannerClient`, with an upstream sub-selection (`PaceLocalCLIUpstream`:
  `claude` / `codex`). No Node bridge; the only prerequisite is the CLI on `PATH`.
- Keep the existing `.cliBridge` (Node-bridge) tier **untouched** — different transport,
  different prerequisites, different lifetime model. The new tier sits beside it, exactly as
  `PaceLocalCLIPlannerClient`'s own header argues.
- Route the tier through `BuddyPlannerClientFactory.makeDefault()` so the **same
  `CompanionSystemPrompt` + tool dialect** flow through Codex as through every other tier —
  persona and `<tool_calls>`/action-tag parsing stay byte-identical.
- Reuse the **off-device safety contract** the cloud bridge already established: consent +
  24h soak (`PaceCloudBridgeConsent`, made transport-aware), amber capsule
  (`isOffDeviceTurnInFlight`), `PaceAPIAuditLog` entry per turn, and fail-loud (respecting the
  existing `directAPIFallsBackToLocalOnCloudFailure`-style opt-in only).
- Add the tier + upstream picker to **Settings → Planner**, reusing the cloud-bridge
  upstream-picker pattern.
- Backward compatible: `.cliDirect` is a new additive `PacePlannerTier` case. Existing users'
  persisted tier decodes unchanged; nothing about `.local` / `.cliBridge` / `.directAPI` /
  `.appleFoundationModels` changes.

## Capabilities

### New Capabilities
- `codex-direct-brain`: a general `.cliDirect` planner tier that direct-spawns the `codex`/
  `claude` CLI for all turns (not just `.research`), under the existing off-device consent,
  amber-indicator, audit-log, and fail-loud guarantees.

## Out of Scope

- The `.cliBridge` (Node bridge) tier and its behavior.
- Gemini as a direct-spawn upstream (its headless contract differs; stays on the Node bridge).
- Making Codex the *default* tier — it stays opt-in; the on-device tiers remain default.
- Any new Codex-specific tool surface beyond what already flows through `CompanionSystemPrompt`.
