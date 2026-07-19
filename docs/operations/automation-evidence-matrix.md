# Automation evidence matrix

Privacy-safe build, release, activation, failure, distribution, and Foundry
evidence contracts for HeyPace (Pace). Implements the
`heypace-automation-readiness` capability from the
`automate-heypace` OpenSpec change.

**Why this exists:** Pace's product contract is *fully on-device* — no cloud
LLM/STT/TTS/telemetry. Automation must prove the app builds, releases,
activates, and fails safely **without** routing screen, voice, transcript, or
on-device context to fleet analytics. Where proof requires a physical device
or signing material that automation cannot reach, the matrix records the gap
as **blocked** rather than inheriting a simulator/build pass as a release
pass.

**Companion Robot** remains a frozen input — it is not a separately automated
product. Companion-mode privacy boundaries are documented in
[`companion-mode-privacy.md`](../product/companion-mode-privacy.md) and are
covered by the same privacy-boundary assertions as the rest of the app.

## Layered evidence model

Each layer is independently reportable. A pass at an earlier layer does NOT
satisfy a later layer.

| Layer | What it proves | Source of truth | Automation |
| --- | --- | --- | `scripts/automation-readiness.sh` flag |
| `landing` | Canonical surface is live, build/indexable, exposes the latest release tied to a source revision | `website/` Astro build, `website/src/config/release-info.json`, `https://heypace.app` | `--landing` |
| `build` | The Swift target compiles for macOS | `leanring-buddy.xcodeproj` (scheme `leanring-buddy`) | `--build` |
| `tests` | The Swift Testing suite executes a non-zero count and passes | `leanring-buddyTests` via `scripts/test-pace.sh` | `--tests` |
| `simulator` | The app launches in a macOS destination and the test host runs | `xcodebuild test` result bundle | `--simulator` |
| `signing` | A Developer ID / signing identity is reachable for release packaging | Keychain (read-only presence check, never exports key material) | `--signing` |
| `device` | A physical Apple Silicon Mac ran the release smoke checklist | `docs/operations/release-smoke-checklist.md` (manual) | `--device` (always reports `blocked` from automation) |
| `distribution` | A release artifact is published and the Sparkle appcast is consistent | `appcast.xml`, GitHub Releases | `--distribution` (read-only live artifact check; never publishes) |
| `activation` | A first non-empty spoken reply completed locally | `PaceTelemetryLog.recordFirstSuccessfulLocalActivation` (local OSLog only) | `--activation` (central collection intentionally N/A — see below) |
| `failure` | A crash/failure path emits version/build + aggregate failure class without user content | `PaceTelemetryLog.recordFailure` (local OSLog only) | `--failure` (covered by unit tests, not by automation runs) |
| `release-readiness` | A receipt aggregating the above layers without signing or publishing | `scripts/release-readiness.sh` → `releases/readiness-receipt.json` | `--release-readiness` |

## Current evidence state (2026-07-19)

| Layer | Status | Evidence | Notes |
| --- | --- | --- | --- |
| `landing` | **pass** | `website/` builds; `release-info.json` carries latest version, download URL, EdDSA signature, `generatedAt`, and `sourceRevision` | Acquisition/download intent is observable via the `/download` route + GitHub Releases page; no cloud analytics SDK is linked by design. `generate-release-info.sh` now also records the source git revision. `scripts/check-landing-health.sh` verifies manifest consistency and live HTTP reachability. |
| `build` | **pass** | `scripts/test-pace.sh` compiles and runs the full suite on Xcode 27.0 Beta 3 (1606/1606 passed, 2026-07-19). The earlier Xcode 27 beta compile block (`TestCompanionScreenAnalysisClient` actor isolation) is resolved. | CI still runs the suite on the pinned `macos-26` runner with a zero-tests-executed guard. |
| `tests` | **pass** | 1606/1606 passed via `scripts/test-pace.sh` (isolated DerivedData, 2026-07-19). Includes the new `PaceTelemetryLogFailureTests` and `PaceTelemetryLogPrivacyBoundaryTests`. | Swift Testing (`import Testing`) suite; `xcresulttool` summary is the source of truth for executed-count. |
| `simulator` | **pass** | The `xcodebuild test` result bundle is the simulator evidence (macOS destination). 1606/1606 tests executed in the test host. | The macOS destination is the only destination — there is no iOS-adjacent target. |
| `signing` | **blocked** | `scripts/release-pace.sh` extracts the team ID from Keychain and attempts a team-signed build, falling back to ad-hoc. Automation does not read or export the key material; it records only presence/absence of a Developer ID. | Signing material lives in Keychain; automation never reads key bytes. |
| `device` | **blocked** | `docs/operations/release-smoke-checklist.md` is a manual hardware checklist. The 2026-07-13 companion milestone explicitly risk-accepted the missing hardware measurements. | Device proof is not remotely automatable — this is a durable blocker, not a regression. |
| `distribution` | **blocked** | `appcast.xml` and GitHub's release API list build 19 (v0.3.19), but the anonymous public asset URL currently returns 404. The live check now catches this instead of accepting local manifest agreement. | Restore or republish the release asset through the explicit release workflow, then rerun `scripts/check-landing-health.sh`; automation does not publish or sign it. |
| `activation` | **pass locally / N/A centrally** | A privacy-safe first-local-activation signal is defined (`PaceTelemetryLog.recordFirstSuccessfulLocalActivation`) and emitted to local OSLog after the first non-empty spoken reply completes. There is no fleet-bound event path by design. | Foundry records the local contract and central N/A explicitly; it must not infer a centrally observed activation. |
| `failure` | **pass (local)** | `PaceTelemetryLog.recordFailure` emits `FAIL kind=<class> ver=<version> build=<build>` to the local unified log; `CompanionManager+TrustSurfacesRuntime.speakPlainLanguageFailure` calls it for every documented `PaceFailureKind`. No user content (transcript, screen, action target) is included. | Covered by `PaceTelemetryLogFailureTests` and the privacy-boundary assertion in `PaceTelemetryLogPrivacyBoundaryTests`. |
| `release-readiness` | **blocked until manual gates pass** | `scripts/release-readiness.sh` aggregates the layers above into `releases/readiness-receipt.json` without signing or publishing and exits `2` while signing, device, or other required evidence is blocked. | Receipt generation is not itself a readiness pass; Foundry preserves the blocked state and may prepare diagnostics or PRs only. |

## Privacy boundary (invariant)

The following MUST NOT appear in any automation artifact, log line, receipt,
or Foundry-bound payload:

- raw audio buffers or audio file paths under
  `~/Library/Application Support/Pace/meetings/`
- transcript text or transcript-derived strings
- screenshots, screen-context frames, or VLM element maps
- local action targets (click coordinates, AX labels, typed key chords)
- signing key material, Keychain values, or `PaceKeychainStore` secrets
- `companion-observations.json` contents
- `pace-tuned-turns.jsonl` contents (redacted export is opt-in and stays local)

`PaceTelemetryLog.recordFailure` and `recordFirstSuccessfulLocalActivation`
accept only closed telemetry enums and emit aggregate, `privacy: .public`
fields: failure class, outcome, activation kind, app version, build number,
and counts. The privacy-boundary tests
(`PaceTelemetryLogPrivacyBoundaryTests`) assert this at compile time by
calling every recording function with representative inputs and confirming
the API surface accepts only public-annotated scalars.

## Foundry integration

Automation emits Foundry-readable receipts to `releases/readiness-receipt.json`.
Foundry may:

- read the receipt and the evidence matrix above,
- prepare diagnostics, PRs, or bounded tasks,
- surface blockers (e.g. the Xcode 27 beta compile block) to the dashboard.

Foundry MUST NOT:

- sign, notarize, or publish a release,
- enroll a physical device,
- push to TestFlight or the App Store (no such path exists today),
- deploy production (landing deploys remain manual `workflow_dispatch`),
- read or centralize the private-context fields listed in the privacy
  boundary above.

## Out of scope

- Hosted backend, accounts, or cloud telemetry — none will be introduced.
- App Store / TestFlight distribution — none exists and none is planned.
- Automated signing — `scripts/release-pace.sh` remains human-triggered.
- Automated physical-device smoke — `docs/operations/release-smoke-checklist.md`
  remains a manual hardware gate.
- Companion Robot as a separately automated product — frozen input.
