## Why

Pace already has the pieces of an aware companion—cheap ambient context, explicit screen watch, local journals, background scheduling, and a restraint gate—but they operate as separate features and do not maintain a coherent model of what changed. An opt-in Always-On Companion Mode can turn those primitives into useful continuity while preserving Pace's defining on-device privacy posture and avoiding a wasteful "run a VLM every second" loop.

## What Changes

- Add an explicit, default-off **Always-On Companion Mode** with visible running, paused, degraded, and privacy-blocked states.
- Replace independent polling features with an event-driven multimodal perception coordinator: camera frames pass through motion/object gates, microphone audio passes through local VAD/wake gating, screen frames pass through change gates, and expensive STT/OCR/VLM analysis runs only for accepted events.
- Add a local temporal world model that records typed observations about apps, screens, people-presence, objects, locations, and changes, including time, source, and confidence. Presence is non-identifying by default.
- Add companion memory policy across episodic, semantic, spatial, and routine memory, with evidence, confidence decay, compression, retention, correction, forgetting, and time-aware retrieval.
- Add a companion state machine and intervention policy that decides whether to update memory, surface a silent card, queue an intervention, ask a clarifying question, or speak through the existing restraint gate.
- Add privacy and resource controls: per-sensor consent, a persistent capture indicator, instant pause, local-only processing, bounded raw-data lifetime, source-level clear/export controls, and battery/thermal budgets.
- Ship one room-companion vertical slice first: wake Pace naturally, ask where an object was last seen, detect non-identifying person entry, and summarize what changed over time. Desktop/AX context enriches that loop but is not the product center. Face identity, covert continuous transcription, and robotics remain outside the first release.

## Capabilities

### New Capabilities

- `ambient-perception`: Event-driven collection and staged analysis of separately enabled camera, local VAD/wake audio, screen, and cheap macOS context.
- `temporal-world-model`: Typed, confidence-bearing observations and derived current state for objects, places, presence, activities, and changes over time.
- `companion-memory-policy`: Rules for promoting observations into episodic, semantic, spatial, and routine memory and for retrieval, correction, compression, retention, and forgetting.
- `proactive-companion-policy`: State-machine orchestration and taste-aware decisions about when Pace stays silent, shows, queues, asks, or speaks.
- `companion-mode-controls`: Explicit opt-in, sensor transparency, privacy controls, local-only enforcement, and power/thermal operating budgets.

### Modified Capabilities

<!-- No existing OpenSpec capability covers watch mode, retrieval journals, or proactive restraint; those behaviors currently live in code and product docs. -->

## Impact

- Extends Pace's local speech pipeline, `PaceAmbientContextStore`, `PaceScreenWatchModeController`, local retrieval journals, `PaceProactivityPipeline`, and `PaceRestraintGate` rather than centering the feature on action execution.
- Adds a perception coordinator, typed observation/event models, temporal world-model store, memory policy engine, companion-mode runtime controller, and Settings/panel privacy surfaces.
- Adds focused local persistence and migration for world-state evidence; raw screen/camera frames are not long-term memory.
- Uses existing Apple/macOS frameworks and local planner/VLM clients. No cloud path and no new production dependency are planned.
- Requires separate, explicit Camera and Microphone opt-ins for room companion abilities; Screen Recording remains an independent optional context source. Local VAD and wake detection may listen while enabled, but transcription begins only after a wake/engagement gate and raw ambient audio is never persisted.
