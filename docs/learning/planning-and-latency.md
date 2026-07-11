# Planning and latency

How Pace decides what a turn needs, which planner backend answers it, how fast
it answered, whether it's allowed to speak unprompted, and how it backs off
when the Mac is running hot.

## Intent classifier
- What: A rule-based keyword router that predicts one of seven turn classes — `.chitchat`, `.pureKnowledge`, `.screenDescription`, `.screenAction`, `.phoneLargeModel`, `.research`, `.unknown` — before any screenshot or planner call happens.
- Why here: Lets the pipeline skip the VLM and even the full planner on cheap turns (a greeting doesn't need a screenshot); any ambiguity biases toward `.unknown`, which forces the full pipeline rather than silently under-serving a turn.
- Where: `PaceIntentClassifier.swift` — `PaceIntentClassifier`, `PaceIntent`, `PaceIntentPrediction`
- Source: internal — no external spec

## Planner tier picker + first-launch default
- What: User-facing store for the four planner backends (`.local`, `.cliBridge`, `.directAPI`, `.appleFoundationModels`) plus the logic that resolves which tier a brand-new install should start on.
- Why here: `loadConfiguration()` checks `hasAnyPlannerTierUserDefaultsState()` first — on a fresh install with zero prior state it resolves to `.appleFoundationModels` when Apple Intelligence is available (zero external install to start talking to Pace) or `.local` otherwise; any user who has ever opened Settings → Planner keeps their pinned tier byte-identical.
- Where: `PacePlannerTierStore.swift` — `PacePlannerTier`, `defaultTierForFirstLaunch(appleIntelligenceAvailable:)`, `loadConfiguration()`
- Source: internal — no external spec

## Latency budget / TTFSW
- What: A per-turn stage-timing tracker — one `TurnBudget` created at push-to-talk press, marked at each pipeline boundary (STT, intent, VLM, planner first token, tool exec, TTS), emitting a single structured `BUDGET=...` log line plus a rolling p50/p90 window.
- Why here: TTFSW (time-to-first-spoken-word) is Pace's headline metric — this is the instrumentation that makes the sub-500ms claim measurable per turn instead of anecdotal, and feeds both the dev console line and `scripts/benchmark_ttfsw.sh`.
- Where: `PaceLatencyBudget.swift` — `PaceLatencyBudget`, `TurnBudget`, `TurnBudget.Stage`
- Source: internal — no external spec

## Restraint gate
- What: A pure policy function — given a context snapshot (active call, Focus mode, recent user input, cooldowns, intent confidence, proactivity profile) it returns `.speak`, `.stayQuiet(reason:)`, or `.queueUntilIdle(reason:)`, with no I/O of its own.
- Why here: The single chokepoint every proactive utterance must pass through so Pace never talks over a Zoom call, a Focus session, or the user mid-sentence; the `.talkative` / `.balanced` / `.reserved` profile tunes cooldown length without touching the decision logic itself.
- Where: `PaceRestraintGate.swift` — `PaceRestraintGate.decide(_:)`, `PaceRestraintContext`, `PaceProactivityProfile`
- Source: internal — no external spec
- Note: the proactive *sources* that call into this gate (morning triage, posture, focus-fatigue, watch-mode nudges) are documented in `proactive-surfaces.md` — this page only covers the gate itself.

## Thermal state advisor
- What: Maps `ProcessInfo.thermalState` (`.nominal` / `.fair` / `.serious` / `.critical`) to one of four typed `PaceThermalRecommendation` levels, each gating a specific set of expensive background surfaces.
- Why here: Pace runs a VLM, a planner, a TTS sidecar, OCR, an AX walk, and optional watch-mode/posture sampling in parallel — under real thermal pressure the advisor dampens the speculative planner race first, then background loops (watch-mode cadence, proactive surfaces), then suspends everything but user-initiated PTT turns, so the OS doesn't throttle Pace's own processes into being slower.
- Where: `PaceThermalStateAdvisor.swift` — `PaceThermalStateAdvisor`, `PaceThermalRecommendation`, `shouldRunSpeculativeRace(underRecommendation:)`
- Source: https://developer.apple.com/documentation/foundation/processinfo/3000875-thermalstate

## Research tier
- What: A fifth intent class (`.research`, e.g. "research X" / "look into Y" / "compare A vs B") and a dedicated tier store — `.cliBridge` (default), `.directAPI`, or `.off` — that swaps in a per-turn planner client with a larger step budget (16 vs. 8) and a hard output-token cap (200k, clamped 50k–500k) for multi-step fetch-read-synthesize turns.
- Why here: Research turns need more agentic headroom than a normal action turn without silently escalating cost — `.off` (opt-in required) falls back to the existing `.phoneLargeModel` route, and the classifier checks research keywords *before* the phone-a-large-model keywords so "deep research this" lands on the more specific lane.
- Where: `PaceResearchTierStore.swift` — `PaceResearchTierStore`, `PaceResearchTier`, `PaceResearchTierConfiguration`; wired in `CompanionManager+AgentLoop.swift` where `mutableIntentPrediction.route == .research` loads this configuration.
- Source: internal — no external spec

See also: [`README.md`](README.md).
