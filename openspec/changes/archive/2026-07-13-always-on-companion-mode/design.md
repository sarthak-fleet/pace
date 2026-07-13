## Context

Pace currently has three useful but disconnected loops:

1. `PaceAmbientContextStore` polls cheap app, window, AX-structure, clipboard-metadata, display, and time context every three seconds.
2. Explicit Watch Mode captures screens once per second, runs `PaceScreenImageDiffer`, emits typed meaningful-change events, optionally describes them with the local VLM, and records a seven-day retrieval journal.
3. Proactive generators feed `PaceProactivityPipeline` and `PaceRestraintGate`, which apply active-call, Focus mode, recent-input, confidence, and cooldown policy before speech.

These are a strong base, but a watch event is currently a description rather than an update to a durable model of the world. There is no shared observation contract, no distinction between uncertain evidence and remembered fact, no spatial history, and no single lifecycle/privacy surface for background awareness.

Always-On Companion Mode must remain fully on-device, default off, comprehensible to the user, and cheap enough to leave enabled. It must also degrade safely when permissions, camera availability, models, battery, or thermals change.

## Goals / Non-Goals

**Goals:**

- Make Pace continuously context-aware without continuously invoking a model.
- Answer time-aware questions such as "what changed?", "where did I last see my keys?", and "when did someone enter?" from cited local observations.
- Maintain current-state hypotheses separately from append-only evidence.
- Make silence the default proactive outcome and reuse the existing restraint system for every spoken intervention.
- Give the user an obvious, reversible privacy contract and bounded storage/resource cost.
- Ship a coherent room-companion loop first: local wake conversation, physical presence/change perception, spatial last-seen memory, and restrained response.

**Non-Goals:**

- Face identity or covert person identification. V1 records presence and non-identifying descriptions only.
- Continuous ambient-microphone transcription or background meeting capture. V1 uses local VAD/wake gating; diarization is session-local when multiple speakers are detected and is not identity.
- Surveillance, security monitoring, or safety-critical alerting.
- Training foundation models, custom object detectors, or a general SLAM system.
- Robotics, navigation, motor control, or hardware embodiment.
- Cloud inference, cloud storage, cloud telemetry, or silent fallback to an off-device planner tier.

## Decisions

### 1. One coordinator, staged perception

Add a `PaceCompanionModeController` that owns the lifecycle and a `PacePerceptionCoordinator` that normalizes sensor output into `PaceObservationCandidate` values. Sensor adapters do not write memory or speak directly.

The pipeline is deliberately staged:

```text
cheap signal -> change/motion gate -> targeted extraction -> local interpretation
             -> typed observation -> world-model update -> intervention policy
```

- Tier 0: event notifications and cheap metadata (frontmost app, app switch, AX focus, display, time).
- Tier 1: fingerprints, motion regions, OCR deltas, and tracking against the previous accepted frame.
- Tier 2: local VLM interpretation only when Tier 1 reports a meaningful, policy-relevant change.

This extends `PaceAmbientContextStore` and `PaceScreenWatchChangeDetector`. The alternative—fixed-rate VLM inference—has simpler control flow but unacceptable latency, energy, thermal, and privacy costs.

### 2. Room awareness is the first vertical slice

The first product milestone is not a better screen watcher. It combines an optional `PaceCameraPerceptionSource`, a local `PaceAmbientVoiceSource`, and the world model to support four end-to-end outcomes: natural wake-to-conversation, object last-seen, non-identifying person entry, and changes-since-time. Camera processing uses low-rate frames plus motion/object gating; only accepted structured observations survive the short raw-frame buffer.

The microphone source runs a tiny on-device VAD/wake gate while explicitly enabled. It does not continuously transcribe: STT starts only after the wake phrase or an active conversational session begins, and stops at session timeout. Optional diarization separates speakers within that active session using ephemeral labels; it does not identify them and does not turn ambient room audio into meeting notes. Push-to-talk remains available and Meeting Mode remains separately explicit.

Screen, AX, app, and time signals are secondary context sources. They help Pace connect room activity with the user's current work, but no first-slice acceptance criterion depends on clicking, tool execution, or observing an app UI.

### 3. Evidence log plus derived world state

Introduce a common observation envelope:

```swift
struct PaceWorldObservation {
    let id: UUID
    let observedAt: Date
    let source: PacePerceptionSource
    let kind: PaceWorldObservationKind
    let subject: PaceWorldSubject
    let predicate: PaceWorldPredicate
    let value: PaceWorldValue
    let location: PaceWorldLocation?
    let confidence: Double
    let evidenceReference: PaceEvidenceReference?
    let expiresAt: Date?
}
```

The append-only, bounded observation log answers "what was seen and when." `PaceWorldModelStore` derives current hypotheses (for example, keys last observed on the desk) and links each hypothesis to supporting observation IDs. Corrections add superseding evidence rather than rewriting history.

This is preferable to storing only natural-language summaries: typed observations can be deduplicated, expired, contradicted, tested, and rendered into retrieval documents without asking a model to reconstruct provenance.

### 4. Conservative entity and spatial modeling

V1 entity types are intentionally narrow: generic person-presence, user-confirmed or high-confidence tracked object, room zone, and secondary application/window/topic context. Spatial locations are coarse user-named camera zones such as "desk" or "door," plus optional screen/display labels—not metric 3D coordinates.

Objects receive stable local track IDs only while evidence supports continuity. Person observations never infer identity. "Who entered?" therefore yields "a person" plus an optional non-identifying description unless a separately proposed, explicit identity feature exists.

### 5. Memory promotion is policy, not model whim

`PaceCompanionMemoryPolicy` maps observations into four stores/views:

- episodic: bounded events and changes with timestamps;
- semantic: user-confirmed durable facts and preferences;
- spatial: last-seen and usual-location hypotheses with evidence/confidence;
- routine: repeated time/context patterns that cross a minimum support threshold.

Promotion requires deterministic thresholds and/or user confirmation. Confidence decays with time and contradictory evidence. Similar low-value episodes compact into summaries; raw evidence references expire before structured memory. Every memory type has source-specific retention and can be corrected, forgotten, cleared, or disabled.

The alternative—letting the planner decide freely what to remember—would be hard to audit and would turn model hallucinations into durable user facts.

### 6. Intervention policy is a state machine with an information-value gate

The controller state is `off`, `starting`, `observing`, `interpreting`, `paused`, `degraded(reason)`, or `privacyBlocked(reason)`. Observation processing is independent of conversation state so the runtime can coalesce or drop low-priority work during push-to-talk, TTS, meetings, active calls, or thermal pressure.

Each meaningful event becomes a `PaceCompanionInterventionCandidate` with novelty, usefulness, urgency, confidence, reversibility, and interruption-cost scores. Deterministic policy chooses one of:

- remember silently;
- show a non-speaking panel card;
- queue until idle;
- ask a clarifying question;
- speak now;
- discard.

Only candidates above minimum confidence/usefulness can leave memory, and all speech still passes through `PaceRestraintGate`. Repeated observations coalesce, negative feedback raises the source/category threshold, and a global cooldown prevents commentary loops. This makes "when to stay silent" a product contract rather than prompt wording.

### 7. Privacy and resource budgets are runtime invariants

Always-On Companion Mode is default off and never enabled by migration. The panel and Settings show which sources are active, last observation time, processing tier, recent interventions, and storage use. Menu-bar state visibly changes while a camera or screen source is sampling. Pause immediately cancels capture tasks and drains no queued interventions.

All endpoints pass `PaceLocalEndpointGuard`; companion mode always uses `makeLocalOnlyPlannerForPrivacyPinnedFeatures()` regardless of the selected conversational planner tier. Raw frames and pre-wake audio live only in bounded in-memory buffers and are released after gating/extraction. Pre-wake audio is never persisted or transcribed. Structured records use atomic local persistence.

The coordinator enforces per-source sampling ceilings, one in-flight expensive analysis per source, backpressure/coalescing, idle/active cadence, and battery/thermal degradation. It suspends camera/VLM work on critical thermal pressure or user-configured battery thresholds while cheap event sources continue.

### 8. Retrieval explains uncertainty and provenance

World-model queries return an answer candidate plus observation time, confidence, location/source, and uncertainty. User-facing answers distinguish:

- observed: "I last saw the keys on the desk at 09:42";
- typical: "They are usually on the desk";
- inferred/uncertain: "The last camera observation suggests...";
- unknown: "I haven't seen them since...".

The existing local retrieval index receives compact, source-tagged documents for episodic and routine recall, while exact last-seen/state queries use the typed store directly.

## Risks / Trade-offs

- [Always-on capture feels invasive] → Default off, source-by-source consent, persistent indicators, immediate pause, short raw-data lifetime, and a review/clear surface.
- [False object continuity creates a wrong world model] → Conservative track expiry, confidence decay, provenance, user correction, and explicit uncertainty in answers.
- [The companion becomes noisy] → Remember silently by default; score information value; coalesce duplicates; route every spoken candidate through restraint and cooldown policy.
- [Battery, memory, or thermals regress] → Staged inference, backpressure, sampling budgets, Metrics/OSLog instrumentation, and automatic degraded modes.
- [Camera permissions or hardware are unavailable] → Desktop sources remain independently useful; camera capability reports degraded state without blocking companion mode.
- [Sensitive screen content enters durable memory] → Redaction before persistence, allow/deny app lists, no raw frame persistence by default, source retention controls, and local-only processing.
- [Scope becomes an unshippable "general intelligence" project] → Ship four measured room-companion outcomes first: wake conversation, person entry, object last-seen, and changes-since-time; routine learning and desktop enrichment follow.

## Migration Plan

1. Add models/stores and deterministic tests without enabling runtime capture.
2. Add separately consented local VAD/wake and camera sources behind default-off source preferences.
3. Dogfood the four end-to-end room outcomes in observe-only mode: local evidence/world model, no proactive output.
4. Add silent cards, then restraint-gated speech as separate opt-ins after privacy, false-positive, and resource gates pass.
5. Add desktop/AX enrichment and routine learning without making click automation an acceptance dependency.
6. Roll back by disabling the preference and stopping all source tasks; the user may retain or clear existing structured memory.

## Open Questions

- Should user-named camera zones be configured from a still image, a lightweight live preview, or voice plus point/click?
- Which app categories should be denied durable screen memory by default (password managers, private browsing, health, finance)?
- What battery and thermal thresholds should graduate from dogfood defaults to release defaults?
- Should object labels be user-taught only in V1, or may the local VLM introduce labels that require later confirmation?
