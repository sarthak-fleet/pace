## 1. Observation and world-model foundations

- [x] 1.1 Add pure `PaceWorldObservation`, source, subject, predicate, value, coarse-location, confidence, evidence-reference, and expiry value types with validation tests.
- [x] 1.2 Add an append-only bounded observation store with atomic persistence, rehydration, source clearing, retention pruning, and corruption-recovery tests.
- [x] 1.3 Add `PaceWorldModelStore` derivation for current hypotheses, supporting/contradicting observation links, supersession, confidence decay, and unknown-state behavior.
- [x] 1.4 Add exact typed queries for last-seen, changes-since, presence-since, and current-state with provenance and uncertainty tests.

## 2. Multimodal perception coordinator

- [x] 2.1 Define a `PacePerceptionSource` adapter contract and `PacePerceptionCoordinator` with cancellation, one-in-flight analysis, coalescing, stale-work dropping, and injected clocks/capture clients.
- [x] 2.2 Add a separately permissioned `PaceCameraPerceptionSource` with low-rate sampling, motion/object gating, named camera zones, and immediate cancellation.
- [x] 2.3 Add a separately permissioned `PaceAmbientVoiceSource` with local VAD/wake gating, bounded conversational sessions, on-device STT, and no pre-wake transcription or persistence.
- [x] 2.4 Add optional non-identifying, session-local speaker diarization with ephemeral labels that expire when the conversational session ends.
- [x] 2.5 Adapt `PaceAmbientContextStore` and explicit screen Watch Mode as secondary observation sources without duplicating their existing loops.
- [x] 2.6 Add targeted OCR/VLM interpretation after meaningful-change gating through the privacy-pinned local-only client path.
- [x] 2.7 Add deterministic fixtures proving ambient speech does not reach STT before wake, unchanged frames skip VLM, meaningful changes emit observations, and bursts coalesce under backpressure.

## 3. Memory policy and retrieval

- [x] 3.1 Implement `PaceCompanionMemoryPolicy` promotion rules for episodic, semantic, spatial, and routine memory with provenance.
- [x] 3.2 Implement confidence reinforcement, decay, contradiction, user correction, expiry, and low-value episode compaction.
- [x] 3.3 Render compact companion-memory documents into the existing local retrieval index while keeping typed last-seen/state queries direct.
- [x] 3.4 Add forget/clear operations that remove derived state, source observations, retrieval documents, and pending candidates consistently.
- [x] 3.5 Add retrieval fixtures for "what changed since morning?", "where did I last see my keys?", usual-vs-last-seen wording, stale evidence, and unknown answers.

## 4. Runtime state and intervention taste

- [x] 4.1 Add `PaceCompanionModeController` with explicit lifecycle states, deterministic transitions, pause/cancel semantics, and degraded/privacy-blocked reasons.
- [x] 4.2 Add `PaceCompanionInterventionCandidate` scoring for novelty, usefulness, urgency, confidence, reversibility, and interruption cost.
- [x] 4.3 Implement remember/show/queue/ask/speak/discard decisions, duplicate coalescing, expiry, category/global cooldowns, and negative-feedback threshold updates.
- [x] 4.4 Extend `PaceProactiveSource` for companion events and route all spoken/clarifying output through `PaceRestraintGate` and the existing proactive queue.
- [x] 4.5 Add policy tests for active calls, Focus mode, recent input, low confidence, expired events, repeated events, reserved/talkative profiles, and silence-by-default behavior.

## 5. Privacy, controls, and resource budgets

- [x] 5.1 Add default-off companion and source preferences with migration tests proving no existing user is opted in.
- [x] 5.2 Add Settings controls for enable/pause, source permissions, retention, storage usage, source clear, clear all, and local-model readiness.
- [x] 5.3 Add menu-bar/panel state for observing, interpreting, paused, degraded, privacy-blocked, screen-active, and camera-active with explicit hover behavior.
- [x] 5.4 Enforce local endpoint guards, privacy-pinned planner selection, in-memory raw-frame bounds, app deny lists, and redaction before persistence.
- [x] 5.5 Add sampling, analysis-concurrency, battery, and thermal budgets plus metrics proving idle and degraded behavior.

## 6. Room-companion vertical slice

- [x] 6.1 Wire companion startup/shutdown into `CompanionManager+Lifecycle` behind the opt-in preference.
- [x] 6.2 Ship default-silent dogfood for person-entry, object-last-seen, and changes-since-time, plus a user-invoked wake conversation; cards and speech remain separately default-off.
- [x] 6.3 Preserve the CPU, memory, model-call, journal, wake, continuity, accuracy, lifecycle, permission, and model-unavailable thresholds as release follow-ups; owner explicitly accepted the unmeasured milestone risk on 2026-07-13 without claiming a pass.
- [x] 6.4 Enable silent cards as a separate default-off opt-in after the owner explicitly accepted the remaining unmeasured observe-only risk; preserve the original thresholds as release follow-ups.
- [x] 6.5 Enable restraint-gated speech as a separate default-off opt-in after deterministic repetition/interruption fixtures and explicit owner risk acceptance; live checks remain release follow-ups.

## 7. Desktop enrichment and routine learning

- [x] 7.1 Add non-identifying person-presence and ephemeral tracking observations; reject identity fields at model validation and persistence boundaries.
- [x] 7.2 Add conservative user-taught object tracking and last-seen observations with track expiry and uncertainty.
- [x] 7.3 Add camera and voice privacy/resource tests for permission denial, device removal, pause, raw-buffer release, critical thermal pressure, false wake, false continuity, and source clearing.
- [x] 7.4 Enrich physical-world events with optional app/window/screen context without making action execution or click automation part of companion-mode acceptance.
- [x] 7.5 Enable the existing conservative routine learning (minimum three unique supporting observations) under explicit owner acceptance of the still-unmeasured room-companion thresholds.

## 8. Documentation and verification

- [x] 8.1 Update `AGENTS.md`, `PROJECT_STATUS.md`, `docs/capabilities.md`, `docs/key-files.md`, `docs/roadmap.md`, and `docs/info-plist-switches.md` as implementation milestones land.
- [x] 8.2 Add a privacy threat model and user-facing explanation covering capture indicators, non-identification, local-only inference, retention, correction, and clear controls.
- [x] 8.3 Run the smallest focused pure tests after each task and `bash scripts/test-pace.sh` at milestone boundaries; do not run terminal `xcodebuild`.
- [x] 8.4 Record the owner's 2026-07-13 waiver of the unperformed manual Xcode `Cmd+R` checklist for this milestone; retain every check in the dogfood runbook and do not represent it as performed or passed.
