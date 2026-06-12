# Pace PRDs

This directory holds the per-pillar product requirements for Pace. `docs/architecture.md`
is the canonical system map; these PRDs turn each pillar into implementation
scope, test gates, and acceptance criteria.

## Current Set

| PRD | Status | Purpose |
|---|---|---|
| `pace-planner-v8-deployment.md` | superseded | Runtime planner moved to off-the-shelf qwen3-30b-a3b (eval-validated); the v8 LoRA path is parked on the TinyGPT side. |
| `pace-v9-body-streaming-wiring.md` | partial | Streaming `Mail.draft` detection/writes, `mailto:` first-draft setup, AX-first body writer, and launch-time Mail prewarm are wired; manual latency demo remains queued. |
| `pace-planner-v10-parameterized-actions.md` | partial | Typed v10 envelope parsing, registry/artifact validation, deterministic schema fixture evals, local planner-output envelope/action rejection, legacy compatibility, and `Mail.draft` streaming are wired; grammar-constrained model-output gate and runtime-default model switch remain queued. |
| `pace-executor-surface.md` | partial | Local dispatcher surface, v1 action mappings, destructive-only approval, `Shortcut.run` installed-name checks, Mail streaming with AX-first body writing, and AX mutation/undo scaffolds are wired; real-app/performance smokes remain queued. |
| `click-executor-improvements.md` | partial | Improve click accuracy with midpoint targeting, foreground/window-aware top-K tiebreaks, recency hints, verification, and all-fail observations; manual ambiguity evals remain queued. |
| `whisperkit-streaming-asr.md` | partial | Selectable WhisperKit provider scaffold with Apple Speech fallback, ASR status, contextual phrases, and runtime-wired LocalAgreement partial stabilization are wired; real WhisperKit streaming runtime remains queued. |
| `local-rag-layer.md` | partial | JSON-backed BM25-style lexical retrieval over preferences/Pace history, built-in competitive research (Minimi, Dayflow, voice-assistant category), screen-watch + app-usage journals for time recall, Settings-selected explicit-root Spotlight files, and permission-aware Calendar/Reminders/Contacts/Notes/Mail data; vector store remains queued. |
| `local-vlm-runtime-port.md` | partial | Screen-analysis provider abstraction and in-process placeholder are wired; real CoreML/MLX runtime remains queued. |
| `dictation-postproc-and-voice-edit.md` | partial | Rule-backed dictation cleanup plus deterministic selected-text voice-edit scaffold; trained specialists remain queued. |
| `hud-intent-disambiguator.md` | partial | HUD route/progress state, panel option-click clarification resolution, local-only unsupported routing, and Reduce Motion cursor-overlay fallback are wired; visual target ambiguity and runtime smoke remain queued. |
| `restraint-policy.md` | queued | Defines the pure speak/stay-quiet/queue gate that proactive sources must call before emitting speech. |
| `always-listening-mode.md` | queued | Adds opt-in wake-word/ambient listening while preserving push-to-talk as the default and safety floor. |
| `barge-in-tts-interrupt.md` | queued | Lets the user interrupt Pace mid-TTS by speaking once always-listening is active. |
| `episodic-memory.md` | queued | Extracts durable local facts from completed turns and exposes them through local retrieval with user inspection/deletion. |
| `proactive-nudges.md` | queued | Adds opt-in local nudge generators for focus fatigue, calendar lead time, and watch-mode error observations after restraint lands. |
| `demonstration-replay.md` | queued | Records user-demonstrated AX/key flows into auditable local JSON and replays them with approval gates. |
| `her-arc-roadmap.md` | planning | Meta roadmap that orders the restraint/memory/listening/nudge/barge-in/replay PRDs and defines the arc's overall acceptance criteria. |
| `morning-triage.md` | ready-to-implement | At a user-set weekday time, Pace speaks a calm 30-second brief assembled from Calendar/Mail/Reminders/app-usage/watch-journal sources. Closes the biggest gap to Del-style "AI exec assistant" positioning. Bundled recipe JSONs ship under `leanring-buddy/Resources/recipes/`. |
| `recipe-library.md` | ready-to-implement | Five bundled installable `PaceFlow` recipes (morning standup, weekly review, inbox triage, focus mode, end-of-day shutdown). Multiplier on the flow-replay PRD. Maps to Poke's Recipes. |
| `chat-interface.md` | ready-to-implement | Text input + live transcript inside the existing PaceMainWindow Conversations tab; shares `paceHistory` retrieval with voice. Notch stays voice-first. |
| `conversational-thread-memory.md` | ready-to-implement | Two-tier in-context memory: last K turns verbatim plus a detached rolling summary of older turns, injected as `<conversation_so_far>` on every planner call. Session-scoped, ephemeral, on-device. Sits between literal-recent-window and episodic facts. |
| `planner-tier-picker.md` | ready-to-implement | User-facing planner tier picker (Local / CLI bridge / Direct API BYO / Apple FM only) in Settings → Planner. Adds `DirectAPIPlannerClient` plus Keychain-backed key storage (`PaceKeychainStore`) and an off-device audit log; preserves Local as the upgrade default and tints the menu-bar capsule amber for every non-Local turn. |

## Ordering

1. v9 body streaming
2. Executor surface
3. v10 parameterized actions
4. WhisperKit streaming ASR
5. Local RAG
6. Local VLM runtime port
7. Dictation post-processing and voice edit
8. HUD and intent disambiguator
9. Restraint policy
10. Episodic memory
11. Always-listening mode
12. Proactive nudges
13. Barge-in TTS interrupt
14. Demonstration replay

Do not treat a PRD as permission to broaden scope. Each implementation pass
should pick one PRD, satisfy its smallest useful acceptance slice, and run the
smallest relevant checks first.
