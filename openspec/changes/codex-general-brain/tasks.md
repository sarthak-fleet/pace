## 1. Tier + config (pure, test-first)

- [ ] 1.1 Add `case cliDirect` to `PacePlannerTier` (`PacePlannerTierStore.swift`); confirm it is additive and existing persisted tiers still decode (round-trip test).
- [ ] 1.2 Add tier-scoped config key `pace.planner.tier.cliDirect.upstream` (`PaceLocalCLIUpstream`, default `.codex`) with getter/setter in the tier store; reuse `PaceLocalCLIUpstream` verbatim.
- [ ] 1.3 Tests: `PacePlannerTierStoreTests` — new case decodes, upstream default is `.codex`, upstream persists, unknown legacy values still resolve.

## 2. Factory dispatch under the off-device contract

- [ ] 2.1 In `BuddyPlannerClientFactory.makeDefault()`, add a `.cliDirect` branch that constructs `PaceLocalCLIPlannerClient(upstream:)` with the **same** `CompanionSystemPrompt` injection used by the other tiers (mirror the research-lane construction in `CompanionManager+AgentLoop.swift`).
- [ ] 2.2 Gate the branch on direct-spawn consent + soak (see §3); when not consented/soaked, fall back to local with a logged reason (mirror the `.cliBridge` "consent not accepted" branch).
- [ ] 2.3 Ensure a `.cliDirect` turn marks `isOffDeviceTurnInFlight` for its duration (same hook as `.cliBridge`/`.directAPI`).
- [ ] 2.4 Ensure a `.cliDirect` turn writes a `PaceAPIAuditLog` entry (bytes + target = upstream label) so the privacy dashboard flips off "0 bytes".
- [ ] 2.5 Ensure fail-loud on upstream failure via `PaceFailureNarrator`; no silent local fallback unless the existing explicit fallback opt-in is set.
- [ ] 2.6 Tests: factory returns `PaceLocalCLIPlannerClient` for `.cliDirect` when consented; returns local (with reason) when not; amber flag + audit entry asserted; failure routes to narrator, not silent fallback.

## 3. Consent (transport-aware, shared)

- [ ] 3.1 Generalize `PaceCloudBridgeConsent` to a CLI-consent record parameterized by tier + upstream; keep one store + soak clock but render the NSAlert body for the direct-spawn path ("spawns your local `codex`/`claude` CLI, which sends this turn off your Mac via <provider>").
- [ ] 3.2 Consent for `.cliBridge` does NOT auto-grant `.cliDirect` (different data path); selecting `.cliDirect` first time re-requests consent and restarts the soak gate.
- [ ] 3.3 Tests: consent required before first `.cliDirect` turn; soak enforced; bridge consent ≠ direct consent; alert defaults to Cancel.

## 4. Preflight + failure copy

- [ ] 4.1 Preflight: if the selected upstream binary is not on `PATH`, surface a plain-language message before the turn (reuse `PaceLocalCLIPlannerError.spawnFailed` copy) instead of a silent hang.
- [ ] 4.2 Add codex stream-json fixture tests to `PaceLocalCLIStreamJSONParser` coverage (assistant text extraction + session-id) so `codex` version drift is caught.
- [ ] 4.3 Tests: missing-binary preflight message; codex line fixtures parse to expected text.

## 5. Settings surface

- [ ] 5.1 Add `.cliDirect` to the Settings → Planner tier picker with a display label + one-line prerequisite hint ("needs `codex` on PATH").
- [ ] 5.2 When `.cliDirect` is selected, show an upstream sub-picker (Claude Code / Codex) reusing the cloud-bridge upstream-picker component, plus the off-device consent affordance.
- [ ] 5.3 Manual QA note (not CI): with `codex` on PATH + consent accepted, a normal (non-research) turn plans via Codex and the capsule tints amber.

## 6. Docs + status

- [ ] 6.1 Update `AGENTS.md` planner section + `docs/key-files.md` (`PaceLocalCLIPlannerClient`, `PacePlannerTierStore`) to document the `.cliDirect` tier.
- [ ] 6.2 Add a learning-roadmap pointer if warranted (`docs/learning/planning-and-latency.md` already documents the tier picker — extend it).
- [ ] 6.3 On ship: archive this change, move it into `PROJECT_STATUS.md` Features (shipped) + Timeline.

## Verification

- Unit suite green via `bash scripts/test-pace.sh` (CI installs the Metal Toolchain).
- Privacy scenarios (amber + audit + consent + fail-loud) covered by tests, not just manual.
- One manual hardware pass: real `codex` turn plans + speaks, capsule amber, dashboard shows "X KB to codex".
