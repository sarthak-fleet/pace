## Context

Two facts shape this design:

1. **The direct-spawn client already exists and is complete.** `PaceLocalCLIPlannerClient`
   spawns `claude`/`codex` (`PaceLocalCLIUpstream`), parses their stream-json output
   (`PaceLocalCLIStreamJSONParser`, ported function-for-function from CodeVetter's
   `cli_brain.rs`), and honors the session-resume contract. It is used today only as
   `researchTurnPlannerOverride` for the `.research` lane in
   `CompanionManager+AgentLoop.swift`.
2. **The off-device safety contract already exists** for `.cliBridge`: `PaceCloudBridgeConsent`
   (consent + 24h soak), `isOffDeviceTurnInFlight` (amber capsule), `PaceAPIAuditLog` (feeds
   the privacy dashboard's "0 bytes → X KB to <target>" headline), and fail-loud dispatch in
   `BuddyPlannerClientFactory`.

So this change is mostly **wiring an existing planner into the general tier path under an
existing safety contract** — not building new machinery. The risk is entirely in the
privacy-boundary correctness, which is why it goes through a spec.

## Goals / Non-Goals

**Goals**
- Codex (or Claude) as a general planner brain for *all* turns, selectable in Settings.
- Zero new privacy holes: the direct-spawn path is gated, indicated, audited, and fail-loud
  identically to the cloud bridge.
- Byte-identical persona/tool dialect vs other tiers (same `CompanionSystemPrompt`).

**Non-Goals**
- Changing `.cliBridge`, `.local`, `.directAPI`, `.appleFoundationModels`.
- Making Codex the default. Gemini direct-spawn. New Codex-only tools.

## Decisions

### (a) New tier `.cliDirect` — NOT a mode on `.cliBridge`

Add `case cliDirect` to `PacePlannerTier`. Rationale: `.cliBridge` requires a running Node
server (`localhost:3456`) and speaks SSE-over-HTTP; `.cliDirect` requires only the CLI on
`PATH` and spawns a `Process`. Different transport, prerequisites, failure modes, and test
surface — overloading one tier with a hidden "mode" flag would make the factory branch on
two axes and muddy the consent/preflight copy. A distinct case keeps each path's preflight
message honest ("start the bridge server" vs "install `codex` / put it on PATH"). The case
is additive, so persisted tier values decode unchanged.

Tier-scoped config keys (mirroring the existing `pace.planner.tier.*` namespace):
`pace.planner.tier.cliDirect.upstream` (`claude` | `codex`, default `codex` since that is
the requested brain). Reuse `PaceLocalCLIUpstream` verbatim.

### (b) Make consent transport-aware, shared across both CLI tiers

`PaceCloudBridgeConsent` currently gates the bridge. Generalize it to a CLI-consent record
keyed by *what runs off-device*, not by transport, so `.cliBridge` and `.cliDirect` share the
soak clock and audit posture but the consent **copy** names the actual mechanism (direct
`codex`/`claude` spawn vs Node bridge). Concretely: keep one consent store; parameterize the
NSAlert body by tier + upstream. A user who consented to the bridge is NOT auto-consented to
direct-spawn (different data path) — consent is re-requested when first selecting `.cliDirect`.
This is the conservative choice for a privacy product; the soak gate restarts for the new path.

### (c) Same `CompanionSystemPrompt` + tool dialect

The factory constructs `PaceLocalCLIPlannerClient` with the same `CompanionSystemPrompt`
injection used by `LocalPlannerClient`/`CloudBridgePlannerClient`. The CLI receives the system
prompt via its system-prompt flag (`codex`/`claude` both accept one) or, failing that,
prepended to the first user message — whichever the existing research-lane construction
already uses, kept identical. The client's job is unchanged: stream assistant *text*; that text
flows through the **same** `PaceActionTagParser` / `<tool_calls>` path as every tier, so
`[POINT:...]`, grouped tool calls, and `[DONE]` behave identically. No tier-specific parsing.

### (d) Settings surface

Extend Settings → Planner: `.cliDirect` appears in the tier picker; when selected, show an
upstream sub-picker (Claude Code / Codex) reusing the cloud-bridge upstream-picker component,
a one-line prerequisite hint ("needs `codex` on PATH"), and the off-device consent affordance.
The amber capsule + audit-log wiring is automatic via the shared off-device dispatch path.

## Privacy invariants (non-negotiable, enforced by spec + tests)

- A `.cliDirect` turn SHALL set `isOffDeviceTurnInFlight` (amber capsule) for its duration.
- A `.cliDirect` turn SHALL write a `PaceAPIAuditLog` entry recording bytes sent + target, so
  the privacy dashboard flips from "0 bytes" to "X KB to <upstream>".
- A `.cliDirect` turn SHALL NOT run until consent for the direct-spawn path is accepted and the
  soak gate has elapsed.
- On upstream failure, `.cliDirect` SHALL fail loud (surface via `PaceFailureNarrator`) and
  SHALL NOT silently fall back to local unless the existing explicit fallback opt-in is set.

## Risks / Trade-offs

- **Off-device data path.** Mitigated by reusing the entire cloud-bridge safety contract; the
  spec's privacy scenarios are the acceptance gate.
- **CLI availability / auth drift.** `codex` may be missing or unauthenticated; preflight
  surfaces a plain-language message (reuse `PaceLocalCLIPlannerError.spawnFailed` copy) rather
  than a silent hang.
- **Stream-json format drift** between `codex` versions. Contained to
  `PaceLocalCLIStreamJSONParser`, already the single sync point with CodeVetter; add fixture
  tests for the codex line shape.

## Migration

Purely additive. No data migration; `.cliDirect` only activates when a user selects it and
completes consent.
