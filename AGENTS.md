# Pace - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->
<!-- Keep this file CONCISE. Deep architecture detail lives in docs/architecture/. This file is the bootloader, not the spec. -->

## What Pace is

Pace is a macOS menu-bar voice agent. It lives entirely in the menu-bar/notch surface (no dock icon, no main window). Hold a hotkey (`ctrl+option`), speak, and Pace transcribes on-device, optionally reads the screen with a local VLM, plans with a local reasoner, streams TTS, and (with `EnableActions=true`) executes approved macOS actions. **Fully on-device** — no cloud LLM, no cloud STT, no cloud TTS, no cloud telemetry. Every byte stays on the user's Mac. That privacy posture is the product's headline differentiator and the architecture is built to protect it.

## Critical constraints (read first)

- **On-device moat is inviolable.** No cloud LLM/STT/TTS/telemetry call paths. The one scoped exception is the approval-gated `download_file` tool (fetch-only, sends nothing). Any non-local planner tier (CLI bridge, Direct API, CLI direct-spawn) tints the capsule amber, writes an audit-log entry, and fails loud. See `docs/architecture/systems.md`.
- **Do NOT run `xcodebuild` from the terminal** for routine dev — it invalidates TCC (screen recording, accessibility, mic) permissions. Build and run from Xcode (Cmd+R). The isolated-DerivedData test script (`scripts/test-pace.sh`) is the only terminal build path that avoids touching the interactive app's TCC grants.
- **Do NOT rename the project directory or scheme** — the `leanring` typo is intentional/legacy.
- **Do NOT fix the known non-blocking warnings** (Swift 6 concurrency, deprecated `onChange` in `OverlayWindow.swift`).
- **Releases cut from clean, synced `main` only**, via `scripts/release-pace.sh`. Walk `docs/operations/release-smoke-checklist.md` on real hardware first — the unit suite injects synthetic data and is blind to hardware-boundary defects.
- **Never commit secrets.** Direct-API keys live in macOS Keychain via `PaceKeychainStore` — never UserDefaults, never a plist, never a log line. Do not edit `.env`, SSH keys, or cloud credentials.

## Build & Run

```bash
# Open in Xcode, select the leanring-buddy scheme, set signing team, Cmd+R.
open leanring-buddy.xcodeproj

# OPTIONAL power-user path: LM Studio as the planner/VLM backend (larger models
# than the bundled defaults). Idempotent provisioner:
./scripts/setup-local.sh
```

Full setup, switches, and tuning: [`SETUP_LOCAL.md`](./SETUP_LOCAL.md). Info.plist switch reference: [`docs/development/info-plist-switches.md`](./docs/development/info-plist-switches.md).

## Tests & eval

```bash
bash scripts/test-pace.sh            # ~1400 unit tests, isolated DerivedData (no TCC impact)
bash scripts/eval-v10-gate.sh        # v10 planner-response schema gate
bash scripts/benchmark_ttfsw.sh --last 10m   # publishable TTFSW/TTFT latency table
```

Local isolated-DerivedData builds require the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) because `mlx-swift` compiles Metal shaders. The current Xcode 27 beta baseline is compile-blocked — see `STATUS.md` → Blockers and `PROJECT_STATUS.md`.

## Documentation navigation

The committed Markdown under `docs/` is the source of truth. Blume (see `blume.config.ts`) is only the presentation/search layer. Start at [`docs/index.md`](./docs/index.md) for the full map.

| Area | Canonical doc |
| --- | --- |
| Architecture (doctrine + constellation) | [`docs/architecture/overview.md`](./docs/architecture/overview.md) |
| Architecture (per-system detail) | [`docs/architecture/systems.md`](./docs/architecture/systems.md) |
| Architecture decisions (ADRs) | [`docs/architecture/decisions/`](./docs/architecture/decisions/) |
| Per-file reference table | [`docs/development/key-files.md`](./docs/development/key-files.md) |
| Info.plist switches | [`docs/development/info-plist-switches.md`](./docs/development/info-plist-switches.md) |
| Test coverage tiers | [`docs/development/test-coverage.md`](./docs/development/test-coverage.md) |
| Capabilities / what it can do | [`docs/product/capabilities.md`](./docs/product/capabilities.md) |
| Conversation memory model | [`docs/product/conversation-model.md`](./docs/product/conversation-model.md) |
| Roadmap | [`docs/product/roadmap.md`](./docs/product/roadmap.md) |
| Product briefs (PRDs) | [`docs/product/prds/`](./docs/product/prds/) |
| Learning roadmap (every novel concept) | [`docs/knowledge/learnings/`](./docs/knowledge/learnings/) |
| Competitive analysis | [`docs/knowledge/competitive/`](./docs/knowledge/competitive/) |
| Failed / deferred approaches | [`docs/knowledge/failed-approaches.md`](./docs/knowledge/failed-approaches.md) |
| Release smoke checklist | [`docs/operations/release-smoke-checklist.md`](./docs/operations/release-smoke-checklist.md) |
| Runbooks | [`docs/operations/runbooks/`](./docs/operations/runbooks/) |
| Current objective / active work / blockers | [`STATUS.md`](./STATUS.md) (lean) · [`PROJECT_STATUS.md`](./PROJECT_STATUS.md) (full) |
| Active plans | [`docs/current/plans/`](./docs/current/plans/) |
| Companion-mode privacy & dogfood | [`docs/product/companion-mode-privacy.md`](./docs/product/companion-mode-privacy.md) · [`docs/product/companion-mode-dogfood.md`](./docs/product/companion-mode-dogfood.md) |

## Code Style & Conventions

### Variable and method naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading the name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main
- PR titles and bodies must describe the FULL payload. Never label a feature PR as a docs fix — reviewers triage by title, and mislabeled payloads are how shipped-broken code escapes review.
- A feature must be wired end-to-end before it merges: callbacks assigned, UI reachable, integration exercised. Scaffolding whose hooks are never set is dead code — delete it or finish it; do not merge it "for later."
- Releases are cut from clean, synced `main` only, via `scripts/release-pace.sh` (the script enforces this). Walk `docs/operations/release-smoke-checklist.md` on real hardware first.

## Documentation maintenance

The committed Markdown is the source of truth; code is authoritative for implementation details. Keep docs accurate as the code changes.

- **New source files**: add an entry to `docs/development/key-files.md` (purpose + approximate line count).
- **Deleted files**: remove their `key-files.md` entry.
- **Architecture changes**: update `docs/architecture/systems.md` (per-system detail) and/or `docs/architecture/overview.md` (doctrine/constellation). Do NOT bloat this file with architecture prose — link out.
- **New conventions**: add to the Code Style section above.
- **New product briefs / decisions**: add a PRD under `docs/product/prds/` or an ADR under `docs/architecture/decisions/` (numbered `NNNN-slug.md`).
- **Failed / deferred approaches**: record in `docs/knowledge/failed-approaches.md` so the next agent doesn't retry a dead end.
- **Status changes**: update `STATUS.md` (lean current view) and `PROJECT_STATUS.md` (full history) together — `STATUS.md` is the at-a-glance, `PROJECT_STATUS.md` is the durable record.
- **Line-count drift > 50 lines**: update the approximate count in `key-files.md`.
- **Do not** update docs for minor edits or bug fixes that don't change documented architecture or conventions.
- **Do not** duplicate a fact in two homes. Each fact has one canonical doc; others link to it.
- **Do not** invent information. Mark unresolved questions explicitly (see `STATUS.md` → Open questions).

### Validating docs

```bash
bash scripts/validate-docs.sh   # markdown link check across docs/ + root agent docs
bash scripts/build-docs.sh      # Blume build (presentation layer) — optional, not required for truth
```

CI runs the link check on every push/PR via the `docs` job in `.github/workflows/docs.yml`.
