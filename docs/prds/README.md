# Pace PRDs

This directory holds the per-pillar product requirements for Pace. `docs/architecture.md`
is the canonical system map; these PRDs turn each pillar into implementation
scope, test gates, and acceptance criteria.

## Current Set

| PRD | Status | Purpose |
|---|---|---|
| `restraint-policy.md` | shipped (v0.3.12) | Pure speak/stay-quiet/queue gate that every proactive source flows through. Active-call detection + user-input timing wired. |
| `proactive-nudges.md` | shipped (v0.3.12) | Focus-fatigue / calendar pre-meeting / watch-mode observation nudges, all default-off, gated by restraint. |
| `barge-in-tts-interrupt.md` | shipped (v0.3.12) | User can interrupt Pace mid-TTS by speaking; VAD subscribes to the existing audio tap. |
| `episodic-memory.md` | shipped (v0.3.12) | Apple FM (with LM Studio fallback) extracts durable facts from completed turns, dedups, tombstones, and surfaces them through retrieval. |
| `always-listening-mode.md` | shipped (v0.3.12) | Apple Speech on-device wake-word spotter on ANE; PTT preserved as the safety floor. |
| `demonstration-replay.md` | shipped (v0.3.12) | Voice-driven record-and-replay AX flows into auditable local JSON, plus Settings → Flows surface. |
| `chat-interface.md` | shipped (v0.3.11) | In-window chat tab + sticky text input in PaceMainWindow → Conversations; voice + chat share `paceHistory`. |
| `cloud-bridge-toggle.md` | shipped (v0.3.11) | Consent-gated planner routing through the sibling Claude Code / Codex / Gemini CLI bridge; 24-hour soak before always-bridge. |
| `conversational-thread-memory.md` | shipped (v0.3.11) | Last K turns verbatim + rolling FM summary of older turns; injected as `<conversation_so_far>` each planner call. |
| `first-run-experience.md` | shipped (v0.3.11) | Clean-install tier defaults to Apple FM when available; notch starter prompts; PaceMainWindow Skills tab. |
| `inclusivity-surface.md` | shipped (v0.3.11) | `cmd+shift+P` notch chat input, one-tap MCP server catalog, Privacy dashboard reading the local audit log. |
| `morning-triage.md` | shipped (v0.3.11) | Weekday morning brief composed deterministically from Calendar/Mail/Reminders/usage/watch sources; restraint-gated. |
| `planner-tier-picker.md` | shipped (v0.3.11) | Settings → Planner picker (Local / CLI bridge / Direct API BYO / Apple FM); Keychain-backed API keys + amber-tinted capsule for non-Local turns. |
| `recipe-library.md` | shipped (v0.3.11) | Five bundled installable `PaceFlow` recipes under `Resources/recipes/`, install/uninstall via voice or Settings. |
| `trust-and-failures.md` | shipped (v0.3.11) | Visible undo banner after every reversible action, 30 s spoken-reply replay, plain-language `PaceFailureNarrator`. |
| `pace-v9-body-streaming-wiring.md` | deferred (model-work track) | Streaming `Mail.draft` detection/writes, `mailto:` first-draft setup, AX-first body writer, and launch-time Mail prewarm are wired; manual latency demo remains queued. |
| `pace-planner-v10-parameterized-actions.md` | partial (actionable) | Typed v10 envelope parsing, registry/artifact validation, deterministic schema fixture evals, local planner-output envelope/action rejection, legacy compatibility, and `Mail.draft` streaming are wired; grammar-constrained model-output gate and runtime-default model switch remain queued. |
| `pace-executor-surface.md` | partial (actionable) | Local dispatcher surface, v1 action mappings, destructive-only approval, `Shortcut.run` installed-name checks, Mail streaming with AX-first body writing, and AX mutation/undo scaffolds are wired; real-app/performance smokes remain queued. |
| `click-executor-improvements.md` | partial (actionable) | Improve click accuracy with midpoint targeting, foreground/window-aware top-K tiebreaks, recency hints, verification, and all-fail observations; manual ambiguity evals remain queued. |
| `hud-intent-disambiguator.md` | shipped (v0.3.13) | HUD route/progress state, panel option-click clarification resolution, visual-target ambiguity chips, local-only unsupported routing, and Reduce Motion cursor-overlay fallback are wired; the runtime smoke flow passes 7/7 (`scripts/smoke-runtime-hooks.sh`, 2026-06-13). |
| `whisperkit-streaming-asr.md` | deferred (model-work track) | Selectable WhisperKit provider scaffold with Apple Speech fallback, ASR status, contextual phrases, and runtime-wired LocalAgreement partial stabilization are wired; real WhisperKit streaming runtime remains queued. |
| `local-rag-layer.md` | deferred (model-work track) | JSON-backed BM25-style lexical retrieval over preferences/Pace history, built-in competitive research (Minimi, Dayflow, voice-assistant category), screen-watch + app-usage journals for time recall, Settings-selected explicit-root Spotlight files, and permission-aware Calendar/Reminders/Contacts/Notes/Mail data; vector store + bundled embedding model remain queued. |
| `local-vlm-runtime-port.md` | deferred (model-work track) | Screen-analysis provider abstraction and in-process placeholder are wired; real CoreML/MLX runtime remains queued. |
| `dictation-postproc-and-voice-edit.md` | deferred (model-work track) | Rule-backed dictation cleanup plus deterministic selected-text voice-edit scaffold; trained specialists remain queued. |
| `pace-planner-v8-deployment.md` | superseded | Runtime planner moved to off-the-shelf qwen3-30b-a3b (eval-validated); the v8 LoRA path is parked on the TinyGPT side. |
| `her-arc-roadmap.md` | planning | Meta roadmap that ordered the restraint/memory/listening/nudge/barge-in/replay PRDs and defines the arc's overall acceptance criteria. **Arc is now fully shipped.** |

## Scope: the local-only v0.3.x milestone

The "Her arc" (restraint → memory → listening → nudges → barge-in → replay)
shipped in v0.3.12, and the speculative planner race + factoring sweep shipped
in **v0.3.13**. As of 2026-06-13 the milestone is defined as **all non-model
PRDs**, and the codebase satisfies every pure-Swift, unit-testable acceptance
slice across them. The backlog now splits into exactly two buckets:

- **Code complete — awaiting one user runtime smoke** (no agent can run these;
  they need a user Xcode Debug build because terminal `xcodebuild` invalidates
  the interactive app's TCC grants):
  - `click-executor-improvements.md` — scorer/recency unit suite landed
    (`PaceClickCandidateScorerTests`); only the all-fail-path runtime smoke remains.
  - `pace-executor-surface.md` — dispatcher + handlers wired; only the real-app
    AX + performance smokes remain.
  - `pace-planner-v10-parameterized-actions.md` — typed envelope + schema-reject
    defense shipped; the grammar-constrained decode gate + runtime-default model
    switch are eval/model items (see the deferred track below).

- **Deferred → future model-work track** (explicitly OUT OF SCOPE for the
  local-only v0.3.x milestone; decided 2026-06-13). These need model
  training/conversion/embedding work, not Swift:
  - `whisperkit-streaming-asr.md` — real WhisperKit streaming runtime bridge.
  - `local-vlm-runtime-port.md` — in-process CoreML/MLX VLM runtime.
  - `dictation-postproc-and-voice-edit.md` — trained dictation/voice-edit specialists.
  - `local-rag-layer.md` — vector retrieval + bundled embedding model (sqlite-vec).
  - `pace-v9-body-streaming-wiring.md` — model-side body-streaming latency demo.

Do not treat a PRD as permission to broaden scope. Each implementation pass
should pick one PRD, satisfy its smallest useful acceptance slice, and run the
smallest relevant checks first.
