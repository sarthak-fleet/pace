# pace — PROJECT STATUS

Last updated: 2026-07-12

## Why/What

**Thesis:** macOS menu-bar voice agent that answers in under ~500 ms time-to-first-spoken-word (TTFSW), fully on-device — no cloud LLM, no API keys, no Worker telemetry. Hold hotkey → speak → Pace reads the screen (optional), plans locally, streams TTS, and optionally executes approved macOS actions.

**In scope:** Menu-bar/notch UI, push-to-talk, on-device ASR/TTS/VLM/planner, action executor (AX-first clicks), trust surfaces, episodic + thread memory, watch mode, journals, proactive nudges (opt-in), MCP substrate, recipe library, `pace://` deeplinks, App Intents (Siri/Shortcuts), bundled MLX model supply, marketing site (`website/`), eval gates, pace-tuned model export scaffold.

**Out / parked:** Persistent KV planner backend (blocked on TinyGPT oMLX), grammar-constrained v10 as runtime default (eval-gated), cloud bridge as default tier, hosted monitoring, CI-automated live-app AX smokes.

## Dependencies

### External

- **Platform:** macOS 14.2+, Apple Silicon recommended, Xcode 16+, ~12–25 GB RAM with models loaded.
- **On-device models (default vs opt-in):** planner default is Apple Foundation Models (Apple Intelligence Macs) or LM Studio Qwen3-30B-A3B; the bundled in-process **MLX Qwen3-4B planner, Qwen3-VL-4B VLM, and TTSKit Qwen3 TTS are opt-in** (Settings → Models, default OFF). ASR default Apple Speech; WhisperKit Large opt-in. TTS default Kokoro-82M via the mlx-audio sidecar → AVSpeechSynthesizer fallback.
- **Optional cloud:** Direct API BYO-key (Keychain); CLI bridge; Apple Foundation Models tier.
- **Legacy path:** LM Studio optional OpenAI-compatible localhost — `./scripts/setup-local.sh`.
- **Landing deploy:** Cloudflare Pages project `pace`.
- **Release:** GitHub Releases + Sparkle updates with bundled model manifest.
- **License:** MIT — `github.com/sarthakagrawal927/pace/releases/latest`.

### Internal fleet

- **Landing standard:** walk `fleet/LANDING_STANDARD.md` before major marketing changes.
- **TinyGPT oMLX:** blocks persistent KV planner backend and grammar-constrained v10 runtime default.

### Stack & commands

| Surface | Stack | Commands |
| --- | --- | --- |
| macOS app | Swift/SwiftUI, Xcode `leanring-buddy.xcodeproj` | Open in Xcode → Cmd+R (**do not** `xcodebuild` — invalidates TCC) |
| Tests | XCTest via isolated DerivedData | `bash scripts/test-pace.sh` — **~1358 tests, all passing (~21 s locally)** |
| Local models | MLX, WhisperKit, TTSKit, Apple Speech | Settings → Models; Sparkle manifest in Info.plist |
| Landing | Astro 5 + Tailwind v4 + Lightning CSS | `cd website && npm install && npm run dev` (:4321) |
| Deploy landing | Cloudflare Pages project `pace` | `npm run build && npm run deploy` |
| Eval / smoke | Shell harnesses | `bash scripts/eval-v10-gate.sh`, `scripts/smoke-executor-surface.sh`, `scripts/benchmark_ttfsw.sh` |
| Pace-tuned export | Local JSONL → repo | `bash scripts/export-pace-tuned-turns.sh` |

**Docs:** `AGENTS.md` (canonical agent instructions), `SETUP_LOCAL.md`, `docs/key-files.md`, `docs/info-plist-switches.md`, `docs/learning/` (learning roadmap — every novel framework/algorithm/pattern), `docs/brand/`.

**Pricing posture (landing):** Try (free) / Pace ($29 one-time) / Studio ($5/mo Composio routing). Checkout via `PUBLIC_PACE_CHECKOUT_URL` (mailto fallback until set).

```
Menu bar capsule (PaceMenuBarOverlay) → floating panel + optional cursor overlay
  ├─ Voice: AVAudioEngine push-to-talk, global CGEvent tap (ctrl+option)
  ├─ ASR: Apple SFSpeechRecognizer default; WhisperKit optional scaffold
  ├─ Screen: ScreenCaptureKit multi-monitor; optional local VLM (LM Studio / MLX)
  ├─ Planner: BuddyPlannerClient — tier picker (Local MLX / Apple FM / CLI bridge / Direct API)
  ├─ TTS: LocalServerTTSClient (Kokoro sidecar) → AVSpeechSynthesizer fallback
  ├─ Actions: PaceActionExecutor — AX press → CGEvent; approval policy; undo banner
  ├─ Memory: PaceThreadMemory (K=4 verbatim + rolling summary, persisted JSON)
  │          PaceEpisodicMemory, screen-watch + app-usage journals (7-day retention)
  ├─ MCP: PaceMCPClient stdio servers from ~/.pace/mcp-servers.json + bundled catalog
  └─ Trust: PaceUndoBanner, reply replay, PaceFailureNarrator, PacePrivacyDashboard
```

**Privacy moat:** "0 bytes sent off this Mac" badge unless off-device tier active (amber capsule tint). Loopback guard on local HTTP endpoints.

**Plan-act-observe:** Up to `AgentMaxSteps` (default 8) with re-screenshot between steps; planner emits `[DONE]` when finished.

## Timeline

- **v0.3.12–0.3.14 cycle:** Her-arc voice loop, trust surfaces, on-device model supply, macOS integrations, executor/planner v10, MCP/recipes, landing shipped.
- **2026-06-20:** Restraint policy, episodic memory, wake word, proactive nudges, barge-in VAD, demonstration replay, trust-and-failures, recipe library, planner tier picker, cloud-bridge toggle, chat interface, conversational thread memory, first-run experience, morning triage, inclusivity surface, always-listening mode, unified memory, local RAG layer (substrate), local VLM runtime port, WhisperKit streaming scaffold, HUD intent disambiguator, dictation postproc, v8/v9/v10 planner iterations, click executor improvements, set-of-mark click recovery, executor surface, Her-arc roadmap meta — all landed.
- **2026-07-04:** Quality overhaul — sprint payload reviewed + fixed (speculative fast-action double-execution, dead dual-agent prefetch removed, dictation trigger tightening); meeting-notes shipping bugs fixed (16 kHz sample-rate labeling, stop-time OOB crash, crash repair, O(1) memory, cross-track alignment, privacy-pinned synthesis); amber indicator extended to headless planner turns; release-from-main guard + hardware smoke checklist; premium chat panel phase 1 (flag-gated); landing meeting-notes wedge + /privacy + /terms; PRs #57–#63 landed. Teachable skills shipped — describe a `.skill.md` skill by voice or typed form, structured on-device by the privacy-pinned local planner (`docs/prds/teachable-skills.md`).
- **2026-07-06:** Adaptive meeting-note profiles shipped (meetily-informed, Pace-native; OpenSpec adopted as the fleet spec workflow — `openspec/changes/adaptive-meeting-notes`). Notes now shaped by a selectable `PaceMeetingNoteProfile` (bundled general/standup/one-on-one + user overrides), selection precedence explicit → default pref → optional local inference → general (`general` reproduces the legacy output byte-for-byte, default). Action items are transcript-grounded (`quote` → `PaceMeetingActionItemSource{timestamp, quote}`) with a panel jump-to-transcript control and grounding in the retrieval doc. Fully on-device. Rejected as non-fits from meetily: its 7 markdown-table templates, VAD (segmenter already covers it), RMS ducking (two-track is better), real-time transcription + diarization (separate large efforts).
- **2026-07-11:** Planned-backlog closeout — WhisperKit streaming bridge confirmed fully wired (was Planned #5); meeting-notes audio fast-follow shipped (v0.3.18/v0.3.19, was #6); meeting audio capture moved off the main actor to a per-track `AsyncStream` serial writer with FIFO guarantee (was #7, hardware smoke pending); bundled-MLX planner default decided to stay opt-in with drift copy aligned (was #8); speaking-time RAG prefetch deferred with rationale (was #9). Learning roadmap expanded to cover the whole project — `docs/learning/` now indexes 9 themed pages (60+ concepts, all "Why here" filled, DRY, cross-linked). Doc drift fixed: MCP bundled catalog is 4 servers (composio supersedes github/slack/linear), not six.
- **2026-07-12:** Distillation flywheel + Codex brain + cleanup. Pace-tuned turn collection flipped **default-ON** (local + redacted) and now collects cloud/Codex turns too, each **provenance-tagged** so commercial-model turns can be filtered before training (ToS-sensitive — the teacher-distillation strategy; PR #72). **Codex as a first-class general planner brain** shipped — new `.cliDirect` tier direct-spawns the `codex`/`claude` CLI for all turns under the full off-device contract (consent+soak, amber capsule, audit-log, fail-loud), OpenSpec `codex-general-brain` archived (PR #77; #71 superseded). Ruthless dead-code cleanup: **34 unused symbols removed** (Periphery 75→41, `scripts/find-dead-code.sh` fixed for beta Xcode; PR #75); planner-client message-building dedup (#73); crashRepair test fixed for macOS 27 (#74, caught via local build). Release 0.3.20 prepped (`docs/release-notes/0.3.20.md` + notes-file wiring; PR #76) — awaiting the hardware smoke + signed build.
- **2026-07-12 (later):** Codex promoted to the primary **phone-a-friend** default, plus one unified RAM-aware provider UI. Research lane defaults to **Codex** for fresh installs (upstream `.claude`→`.codex`, model unset so Codex uses its own authenticated model; existing users' persisted upstream honored). Scheduled/cron fires route to a Codex direct-spawn brain **only when direct-spawn consent + 24h soak are satisfied** (`cronTaskBrainDecision`, sharing `cliDirectDispatchDecision`), else fall back to the local planner — a background fire never silently goes off-device. Settings → Models gained a **planner-brain picker** folded into the RAM budget section: PR #79's `PaceModelMemoryBudget` model + rich budget UI merged in, and picking a cloud/Apple-FM brain frees the local-planner RAM while the section live-updates the per-model breakdown, fits verdict, and largest-VLM-that-fits recommendation (shared `selectPlannerTierWithConsent`, no duplicated consent logic). **#79 superseded.** 1400/1400 tests.
- **2026-07-12 (history):** "See my past research and recurring tasks" shipped. New Settings → **Tasks** tab lists `PaceCronScheduler` recurring tasks (humanized interval, skips-weekend note, last-run relative time, delete); `PaceCronTask` gained a backward-compatible `lastRunAt`. New **`PaceResearchJournal`** (`researchHistory` source, mirrors the screen-watch journal) captures each research turn as `{question, answer}` via a strictly `isResearchTurn`-guarded, non-blocking, fire-once agent-loop hook (question = original transcript) — browsable in Settings → Memory → Past research and recallable. 1417/1417 tests (+17).
- **2026-07-12 (focus passes + web):** Honest quality assessment of drawing/skills/memory → two focus passes. **Skills (#84):** found + fixed a pre-existing bug where taught skills NEVER executed (run prompt re-matched the skill parser; now gated on `activeSkillRun`); `requiredPreferences` enforced at run time (recipes' store seam + wording); `toolCall` honored in the planner prompt (byte-identical without); `PaceSkillRunJournal` local JSONL run telemetry. 1430/1430 tests. **Grounding measurement (#85):** `eval-vlm-mark-reading.py` (119 synthetic Set-of-Mark cases, renderer-exact), `capture-grounding-corpus.sh`, `eval-vlm-grounding.py` (real-VLM fixture eval, >30pp AX-blind bar) — first numbers pending an LM Studio run. **Website (#86):** 15 per-competitor `/compared/<slug>` SEO pages from one shared component + sitemap.xml/robots.txt (no new deps); capability coverage completed (Features 7→10 verbs, Automation/Reach/Trust sections, JSON-LD featureList ×13) with a no-grounding-accuracy-claims guard. **CI (#82):** coverage opt-in + DerivedData cache — measured 36m11s→32m57s (~9%); step timings revealed the real cost is the ~30-min Test step (build is ~3 min), so the next CI lever is test parallelization, not build caching.
- **2026-07-12 (live gauntlet → drawing works):** Live end-to-end testing on real hardware (deeplink-driven, ground-truth-verified via thread-memory/traces/journals/screenshots — see `reference` memories) took the drawing pipeline from never-working to a **red circle visibly drawn on screen by voice command**. Fix chain, each layer a real bug: **VLM (measured):** default `ui-venus-1.5-2b` is torchSafetensors — LM Studio cannot load it (vision silently dead); `ui-venus-1.5-8b@4bit` = **84.9% mark-reading** (101/119, ~783ms) via the #85 suite — repo default decision pending. **Skills run by voice (#89):** flow parser's bare "run " prefix swallowed every skill-run utterance; + fuzzy slug resolution. **Planner (#90):** the failures were INSIDE the decode-constrained v10 envelope — `Draw.annotation` missing from the documented action vocabulary, `payload.calls` untyped, contradictory plan-act-observe prose; new `fm-fixtures-actions` family 2/8→8/8 (decoded-action scoring via `evals/pace_v10.py` mirrors), existing 19/19 kept, latency improved. **Overlay (#91):** mascot mode hid the window hosting the annotation layer — presence-callback transient reveal; + invalid-structured-JSON retry (cache_prompt off on retry, audited). **CI honest+fast (#88/#92):** Test step was `continue-on-error` + xcpretty-blind (never really gated!); mic-less-runner AVAudioEngine hang was the 30-min wedge; `macos-latest` lottery serves macOS 15 images that can't run macOS-26 tests; parallel workers crash (mass 0.000s failures) → pinned `macos-26`, serial, 3-iteration retry, zero-tests guard: **Test 30m34s → ~1-3 min, and green means green**. Learning docs +7 concepts (#93). Known follow-ups: few-shot coordinate echo; `PacePlannerModelResolver` silently swapping brains (served gemma-3-12b when qwen unloaded — needs fail-loud + served-model in traces); MCP fixture subprocess vs parallel test workers.
- **2026-07-13 (companion camera milestone):** Always-On Companion Mode gained a real opt-in AVFoundation/Vision camera source: ≤1 fps capture, 32×24 luma motion gating, non-identifying human rectangles, ephemeral session-local tracks, runtime permission/device failure reporting, and system sleep/wake suspension. The dogfood document now defines literal accuracy/resource/privacy thresholds and unlock order. The OpenSpec remains 32/40: object teaching/tracking, a true pre-STT wake gate, measurements, and manual Xcode acceptance are still required; cards, speech, and routine learning remain locked.
- **Active plan:** `docs/plans/pace-tuned-model-v1.md` — collection now default-ON; LoRA pending accrued turn volume (filter by `plannerProvenance` before training a shippable model).
- **Test suite:** ~1435 test cases via `scripts/test-pace.sh` (serial, ~15-20s locally); CI runs the full suite on every push/PR via `.github/workflows/ci.yml` — pinned `macos-26` runner (the `macos-latest` pool serves macOS 15 images that cannot run macOS-26-target tests), serial execution (parallel workers crash on the CI image), `-retry-tests-on-failure -test-iterations 3` for the timing-sensitive tail, a zero-tests-executed guard, and 3 hardware-bound tests gated behind `TEST_RUNNER_PACE_CI` (they still run locally). Coverage is opt-in via workflow_dispatch. Local isolated-DerivedData builds require the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`) because `mlx-swift` compiles Metal shaders.

## Products

| Product | Surface | Role |
| --- | --- | --- |
| Pace macOS app | Menu-bar/notch capsule + floating panel | On-device voice agent with optional screen actions |
| Marketing site | `website/` on Cloudflare Pages | Try/Pace/Studio pricing, on-device pitch, FAQ |
| Pace-tuned model scaffold | Settings export + eval scripts | Local turn collection → LoRA training pipeline |
| MCP + recipes | Settings → MCP, bundled flows | stdio tool bridge + voice-installable recipe library |

## Features (shipped)

### Voice loop & core UX (v0.3.12–13, Her-arc)

- Push-to-talk with glassmorphic notch animation; Codex-style cursor with gradient arrow.
- Streaming sentence TTS for sub-500 ms perceived latency; TTFSW logged per turn (`scripts/benchmark_ttfsw.sh`).
- In-window chat (`cmd+shift+P`) in menu-bar panel.
- Intent classifier routes chitchat / pure-knowledge / screen-action paths.
- VLM-skip heuristic for non-screen-referential transcripts; override `AlwaysRunLocalVLMRegardlessOfTranscript`.
- Speculative planner race (first step): Apple FM lite vs full VLM path; action parsing always from full planner text.

### Trust & failures

- 5-second floating undo banner for reversible mutations; `Undo.last` via executor.
- 30-second reply replay after TTS (same post-processed string, no re-plan).
- `PaceFailureNarrator` — deterministic plain-language failures (planner offline, permission, click missed, TTS sidecar, MCP).
- `PaceRestraintGate` — silence during active calls; proactive cooldown.
- Privacy dashboard reads local `PaceAPIAuditLog` JSONL only.

### Restraint policy & proactive (opt-in, default OFF)

- Wake word (ANE), proactive nudges, barge-in VAD, demonstration replay — gated by restraint.
- Posture watch (frames never stored), focus-fatigue nudges, calendar pre-meeting nudges.
- Morning brief (`PaceMorningTriageScheduler`) parked on panel when restraint says quiet.
- Watch mode: `PaceScreenWatchModeController` + voice commands via `PaceWatchModeCommandParser`.

### Memory & recall

- Two-tier thread memory: last 4 turns verbatim + rolling Apple FM summary; persists `~/Library/Application Support/Pace/thread-memory.json`.
- Episodic memory for durable facts (separate from thread summary).
- Screen-watch journal + app-usage journal (7 days, NSWorkspace — no extra permission).
- Research-history journal (`PaceResearchJournal`, `researchHistory` source): each research turn captured as `{question, answer}`, browsable in Settings → Memory → Past research and recallable ("what did I research about X?"); 30-day/100-entry retention.
- CoreSpotlight memory mirror; memory write-time enrichment.

### On-device model supply

- In-process MLX planner (Qwen3-4B), MLXVLM, chained embedder (MLX + Apple NL fallback).
- Qwen3 TTS via TTSKit; WhisperKit auto-default ASR path scaffolded.
- Settings → Models tab: download prefetch, Info.plist model manifest for Sparkle delivery.
- RAM-aware budget section (`PaceModelMemoryBudget`): per-model resident-RAM estimate registry, fits/over-budget verdict, and `largestVLMThatFits`. Folds in a **planner-brain picker** — selecting a cloud/Apple-FM brain frees local-planner RAM and the budget + biggest-fitting-VLM recommendation update live.
- Eval-gate harness pins shipping model identifiers (`PaceBundledModelsSettingsTests.shippingDefaults`).

### macOS integrations

- App Intents — Siri / Shortcuts / Spotlight entry points.
- `pace://` deeplinks: `listen`, `chat?text=`, `watch?enabled=`, `panel` — reject-on-ambiguity parser.
- NSDataDetector entities; IDE focus detector; thermal-state advisor.
- Focus Status in restraint gate; long-form audio transcription.
- Contacts resolution for Mail compose; EventKit calendar/reminders; Finder/Notes/Mail/Things/Shortcuts/Messages integrations.

### Executor & planner (v0.3.14)

- **Click executor:** top-K parser/scorer, focused-window scoring, AX verify/retry, recency hints, unit fixtures.
- **Set-of-mark click recovery:** Phase A miss-case (`PaceSetOfMarkClickRecovery`).
- **Planner v10 + executor surface:** typed envelope, registry validation, streaming fields, smoke runners.
- **Click ambiguity fixtures**, v10 generic field streaming, executor smoke runner, remote model manifest, v10 eval gate.
- Grammar-constrained model gate remains TinyGPT/eval gated — not runtime default.
- Tool registry (`PaceToolRegistry`) validates at startup; grouped parallel `<tool_calls>` JSON + legacy action tags.

### MCP & recipes

- MCP stdio bridge with fixture server integration tests; example config for filesystem/fetch/github/applescript.
- Bundled catalog — 4 one-tap servers (filesystem, fetch, applescript, composio); github/slack/linear now route through the composio OAuth bridge (`PaceMCPServerCatalog.supersededBySlug`) — atomic install into `mcp-servers.json`.
- Recipe library: 5 bundled flows (morning-standup, weekly-review, email-zero, focus-mode, end-of-day); voice install/uninstall.

### Skills — flows vs recipes vs skills vs tools

Four complementary "do more than talk" layers, from most literal to most flexible:
- **Tools** (`PaceToolRegistry`) — atomic built-in capabilities (click, type, open app…).
- **Recipes** — bundled `PaceRecordedFlow` JSON, voice-installable.
- **Flows** (`record_flow`) — user-recorded AX steps, replayed **verbatim** (pixel tier).
- **Skills** (`.skill.md`) — natural-language step lists the planner **re-grounds each run** (intent tier). **Teachable by telling** (PRD `docs/prds/teachable-skills.md`): say "teach a skill …" or use Settings → Skills → "Teach a skill"; a privacy-pinned LOCAL planner structures the description into a `.skill.md` (deterministic fallback if the planner is unavailable), saved to `~/Library/Application Support/Pace/skills/` and runnable via "run <name>". Fully on-device.

### Planner tier picker & optional cloud paths

- Settings → Planner: Local (default) / Apple Foundation Models / CLI bridge / Direct API BYO-key (Keychain) / CLI direct (Codex/Claude direct-spawn). Also selectable from the Settings → Models RAM-budget brain picker via the shared `selectPlannerTierWithConsent`.
- Direct API keys never in UserDefaults/logs; off-device turn amber indicator.
- Cloud bridge consent + 24-hour soak gate; fails loud unless explicit fallback toggle.
- **Codex is the phone-a-friend default:** research lane defaults to Codex (fresh installs), and cron/scheduled fires use Codex when direct-spawn consent + soak are satisfied, else the local planner — background fires never silently go off-device.

### Landing & product scaffold

- Astro landing deployed to Cloudflare Pages (`pace` project).
- Sections: Nav, Hero (CSS demo), OnDevice, Features, Comparison, Pricing, FAQ, Footer ("0 bytes" counter).
- OG PNG at `website/public/og-image.png`; regenerate via `scripts/generate-og-image.sh`.
- Social proof section is live (`showSocialProofSection = true`) showing 3 **anonymized theme cards** (no fictional names, per the fleet landing standard); a flag-gated dummy attributed layout (`showDummyAttributedTestimonials`, default OFF) exists for local preview only. Real attributed quotes pending permission.
- Commerce config: `src/config/commerce.ts` — mailto checkout fallback.

### Pace-tuned model scaffold

- Settings opt-in exporter → `~/Library/Application Support/Pace/pace-tuned-turns.jsonl` (redacted).
- `scripts/export-pace-tuned-turns.sh` → `evals/pace-tuned-export/`.
- `scripts/train-pace-tuned-model.sh` + eval gate docs in `docs/plans/pace-tuned-model-v1.md`.
- Holdout fixtures: `evals/fm-fixtures-holdout/` never used for training.

### Eval & quality

- FM fixture sets: v1, v2, holdout, OOS, destructive, ambig — under `evals/fm-fixtures*/`.
- VLM fixtures: `evals/fm-vlm-fixtures-v1/` for vision-grounded planner cases.
- `scripts/eval-planners.py` — empirical planner comparison (Qwen3-30B-A3B baseline).
- `scripts/eval-v10-gate.sh` — grammar-constrained gate for shipping decisions (`PACE_RUN_MLX_EVAL=1` for MLX path).
- `scripts/benchmark_ttfsw.sh` — aggregates TTFSW/TTFT from app logs for publishable latency tables.
- Live-app executor smokes: `scripts/smoke-executor-surface.sh` (manual-only, not CI).
- Coverage spans: action tag parser, click ambiguity fixtures, set-of-mark recovery, MLX planner eval harness, MCP catalog/installer, restraint gate, annotation overlay, remote model manifest, streaming field detector, privacy dashboard classification, IDE focus detector, thermal advisor, Spotlight indexer, CompanionManager extension modules.

### Settings & configuration surfaces

- **PaceSettingsWindow** (gear from notch panel): MCP servers, permissions, voice, preferences, memory (with Past-research history), scheduled tasks (Tasks tab), action history, planner tier, models download, flows/recipes, privacy dashboard.
- **Info.plist switches** documented in `docs/info-plist-switches.md` — `EnableActions`, `UseLocalVLMForScreenContext`, `TranscriptionProvider`, `TTSProvider`, planner/VLM URLs, smoke hooks (`PACE_ENABLE_SMOKE_HOOKS=1`).
- **First-run default:** fresh installs with no planner tier UserDefaults prefer Apple Foundation Models when Apple Intelligence available; existing users unchanged.

### Action & tool surface (agent mode)

- Grouped parallel `<tool_calls>` JSON with sequential outer array; legacy tags still parsed.
- Local tools: click/double-click, type, key chords, scroll, open app/URL, music/volume/brightness, calendar/reminders, mail compose, Notes/Things/Shortcuts/Messages, clipboard read, window snap, `download_file` (http(s) → ~/Downloads, approval-gated), `run_flow` / `record_flow`, MCP passthrough.
- AX-first targeting (`PaceAXTargeter`) with CGEvent fallback; session mutation log + undo for set-value edits.
- Approval policy: risky/non-undoable actions prompt when `Approve Risky Actions` on; routine local actions execute without popup.

### Website (`website/`)

- Astro 5 static export; Cloudflare Pages project **`pace`**.
- Components: Nav, Hero (CSS-only animated demo), OnDevice pitch, Features (six capabilities), Comparison vs Wispr/Raycast/MacWhisper/Siri, Pricing (Try/Pace/Studio), gated SocialProof, FAQ (eight questions), Footer with "0 bytes" counter + founder signature.
- Commerce: `src/config/commerce.ts` — mailto fallback; `PUBLIC_PACE_CHECKOUT_URL` / `PUBLIC_STUDIO_CHECKOUT_URL` at deploy.
- OG: `public/og-image.png` via `scripts/generate-og-image.sh`; audit against `fleet/LANDING_STANDARD.md`.

## Todo / Planned / Deferred / Blocked

### Active implementation

- **Always-On Companion Mode OpenSpec** — 32/40 tasks complete. The typed world model, multimodal coordinator/adapters, targeted local visual interpretation, non-identifying/context-enriched physical-world mapping, companion memory/retrieval, restraint-gated policy, privacy/resource budgets, Settings/menu-bar transparency, default-off app lifecycle, privacy threat model, and resource/privacy fixture coverage are implemented. The lifecycle runs a real opt-in low-rate AVFoundation/Vision camera client for non-identifying person-entry evidence and conservative user-taught object matching: Settings captures a centered object into a locally persisted Vision feature print, the camera searches coarse left/center/right zones, and accepted matches enter the existing expiring last-seen pipeline without persisting photos. Settings also exposes an explicit user-clicked conversation action through the existing push-to-talk path; it does not enable ambient recognition. The separate legacy always-listening path now opens a real, bounded post-wake push-to-talk window without sending the detected phrase to the planner. Ambient voice remains visibly degraded because that legacy Apple Speech spotter performs recognition before phrase acceptance and therefore cannot prove the OpenSpec's stricter no-pre-wake-STT invariant. Hardware accuracy/resource dogfood remains open, so task 6.2 and proactive-output gates stay unchecked. Silent cards and speech are compile-time locked until their acceptance gates pass.

### Planned (remaining — each blocked on an external input, not on code)

1. **First pace-tuned model** — collect turns via Settings export, LoRA train + eval gate per `docs/plans/pace-tuned-model-v1.md`. Blocked on exported turn volume (see Blocked). Per project memory, Pace-side model work is otherwise concluded — this is a data-collection milestone, not new model engineering.
2. **Stripe checkout URL** — set `PUBLIC_PACE_CHECKOUT_URL` (and optional `PUBLIC_STUDIO_CHECKOUT_URL`) in the Pages build env. Blocked on the real Stripe URL; the mailto checkout fallback ships until it is set.
3. **Permissioned public testimonials** — replace private-beta theme cards when 3+ real quotes exist. Blocked on real permissioned quotes.
4. **Voice Mail latency demo** — manual `<700 ms` check with Mail prewarm. Turnkey runbook written (`docs/voice-mail-latency-demo.md`); blocked only on the one hardware measurement run (enable `PrewarmMailForDrafts`, do 8–10 voice→Mail turns, `bash scripts/benchmark_ttfsw.sh --last 10m`).

### Resolved this cycle (2026-07-11)

- **WhisperKit streaming bridge (was Planned #5)** — DONE. `WhisperKitTranscriptionProvider.isRuntimeAvailable = true`; the full streaming session (`startStreamingSession` / `appendAudioBuffer` / `requestFinalTranscript`) is wired and the factory selects it when `TranscriptionProvider=whisperKit` and the model is present. Model is still pre-placed (`download: false`) — no silent fetch.
- **Meeting-notes audio fast-follow (was Planned #6)** — DONE. v0.3.18 (build 18) and v0.3.19 (build 19) shipped; appcast is current at build 19.
- **Meeting audio capture off the main actor (was Planned #7)** — DONE (code). Per-buffer `Task { @MainActor }` hops replaced by a per-track `MeetingTrackWriter` (an `AsyncStream` drained by a single detached consumer): Float32→PCM16 conversion and `FileHandle` writes now run off the main actor and land in FIFO order by construction; the SCStream delegate pushes system samples through a `@Sendable` sink (`makeSystemSampleSink()`) instead of hopping to main. Mic conversion is boxed in `MicSampleConverter`. Unit suite green with a new `appendedBuffersArePersistedInFIFOOrder` regression guard. **Requires hardware meeting-recording smoke before release** (`docs/release-smoke-checklist.md`) — unit tests inject synthetic samples and cannot see capture-timing defects.
- **Bundled-MLX planner default decision (was Planned #8)** — RESOLVED: keep the in-process MLX Qwen3-4B planner **opt-in** (default OFF). Rationale: WhisperKit precedent (a downloaded model on disk is an opt-in signal; an explicit Settings choice always wins), flipping would need a 4B-vs-30B eval-gate run on real hardware, and per project memory Pace-side model work is concluded. Stale "default" copy aligned in this file and `docs/PROJECT_RECOMMENDATION_CONTEXT.md`; the site FAQ/Features already say "one toggle in Settings → Models."

### Deferred

- **Speaking-time context prefetch (episodic/RAG) (was Planned #9)** — Deferred, not built. The expensive prewarm (VLM screen context) already runs at PTT press via `PaceScreenContextService.prewarmScreenContext`, and local retrieval (BM25 + in-memory episodic) is already sub-millisecond, so a partial-transcript-keyed RAG prewarm adds hot-path complexity for negligible, unmeasurable TTFSW upside — and it mirrors the dual-agent prefetch already removed as dead code. Revisit only if a `benchmark_ttfsw.sh` run shows retrieval on the critical path. Idea tracked in `docs/competitive/steal-catalog.md`.
- **Persistent KV planner backend** — blocked on TinyGPT oMLX qualification. (Note: the in-process MLX planner is available behind the Settings → Models toggle, NOT the default — fresh installs talk via Apple FM or LM Studio.)
- **Grammar-constrained v10 runtime default** — TinyGPT/eval gated; shipping planner remains current MLX/Qwen stack.
- **Real-app AX smokes in CI** — manual-only; TCC makes automated live-app tests fragile.
- **Cloud bridge / Direct API as default** — contradicts on-device moat; opt-in tiers only.
- **Hosted telemetry or accounts** — local-only analytics hooks; no cloud SDK.

### Blocked

- Live-app click ambiguity smokes not CI-automated.
- Real attributed testimonials pending permission — the live section uses anonymized theme cards (dummy attributed layout is preview-only behind a default-OFF flag).
- Known non-blocking Xcode warnings (Swift 6 concurrency, deprecated onChange) — intentionally not fixed per AGENTS.md.
- Pace-tuned LoRA run blocked on sufficient exported turn volume.
- **TCC:** Never run terminal `xcodebuild` for routine dev — re-requests screen recording, accessibility, mic permissions.
- **Benchmark publish:** Use measured TTFSW from `benchmark_ttfsw.sh` — do not claim latency without local numbers.
