---
status: planning
owner: Sarthak
priority: meta — orchestrates the next sprint
---

# Roadmap — "Her" Arc

Goal: move Pace from "voice search with actions" to "ambient
companion that remembers you" while staying fully on-device.

Self-assessment at the start of this arc: Pace is ~30% of the Samantha
target. Voice in/out, screen awareness, action execution, multi-turn
history, app integrations — all there. The gaps are entry-point
(PTT-only), restraint (Pace speaks too freely once invited),
durability (no fact memory), and replayability (can't learn a flow).

## Shipping order

The order matters because some PRDs hard-depend on others.

```
┌─────────────────────────────┐
│ 1. Timer skill   ← SHIPPED  │
│ 2. Personality   ← SHIPPED  │
└─────────────────────────────┘
              │
              ▼
┌─────────────────────────────┐
│ 3. Restraint policy         │   blocks 4, 5, 6
│    [restraint-policy.md]    │
└─────────────────────────────┘
              │
        ┌─────┴─────┐
        ▼           ▼
┌────────────┐ ┌─────────────────┐
│ 4. Episodic│ │ 5. Always-      │
│   memory   │ │   listening     │
└────────────┘ └─────────────────┘
                    │
                    ▼
              ┌──────────────────┐
              │ 6. Proactive     │
              │   nudges         │
              └──────────────────┘
                    │
                    ▼
              ┌──────────────────┐
              │ 7. Barge-in      │
              └──────────────────┘

(independent, slot in anywhere)
┌──────────────────────┐
│ 8. Demonstration     │
│    replay            │
└──────────────────────┘
```

## Why this order

- **Restraint first.** Every proactive feature needs the gate. Ship
  the gate before opening the floodgates.
- **Episodic memory before always-listening.** Memory landing first
  means the always-listening rollout immediately benefits from
  recall — bigger first-impression effect.
- **Always-listening before proactive nudges.** Nudges feel right
  when Pace is "around"; PTT-then-nudge feels disjointed.
- **Barge-in last.** Polish — useful but not a wow moment without
  always-listening to chain off of.
- **Demonstration replay is independent.** Different surface, no
  shared dependency. Slot in based on engineering bandwidth.

## Acceptance for the arc

The arc is "done" when:

- Pace listens ambiently with no PTT required (PTT remains as a
  fallback).
- Pace remembers durable facts the user has shared and surfaces
  them when relevant.
- Pace volunteers ≤3 useful observations per work day on average.
- Pace can be interrupted mid-sentence by voice.
- The user can demonstrate a flow and have Pace replay it.
- All of the above remain 100% on-device.

## Risks across the arc

- **Cumulative latency.** Each new mid-loop ML call adds ms. Track
  TTFSW across the arc — if it regresses by >20% from current
  baseline, pause and optimize before adding the next feature.
- **Cumulative annoyance.** Even with restraint, the sum of nudges +
  memory recalls + always-listening false triggers could feel like a
  lot. The Talkative/Balanced/Reserved slider must scale to "almost
  silent" as a credible Reserved setting.
- **Battery + thermals.** Always-listening + barge-in VAD run
  continuously. Measure on a real M1 over a workday before declaring
  ready.

## Out of scope for this arc (queued for later)

- Wake-word voice-print (speaker ID).
- Multi-device handoff (Mac → iPhone).
- Cloud sync (deliberately out of scope; no-cloud principle).
- Real-time speaker emotional-state detection.
- Trained dictation/edit specialists (separate model arc).
- Vector-embedding RAG (separate retrieval arc).
