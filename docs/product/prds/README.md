# Pace PRDs

Index of Pace product briefs and their current disposition.

Canonical status: [PROJECT_STATUS.md](https://github.com/HeyPace/pace/blob/main/PROJECT_STATUS.md).

## PRDs

- [`on-device-meeting-notes.md`](on-device-meeting-notes.md) — P0. Assemble
  Pace's meeting-mode stub into a real product: two-track capture →
  energy-based turn segmentation → on-device transcription → structured
  notes synthesis → retrieval wiring. The wedge against Granola/Otter/
  Fireflies (all cloud). Status: **shipped in code**; hardware recording smoke
  remains a release gate.
- [`premium-chat-panel.md`](premium-chat-panel.md) — Claude-Desktop-style primary
  chat surface. Status: **phase 1 shipped** behind its feature flag; phase 2 is
  deferred.
- [`teachable-skills.md`](teachable-skills.md) — Teach Pace a `.skill.md`
  skill by describing it in natural language (spoken or typed), structured
  on-device by a privacy-pinned local planner. Fills the Tier-5 intent layer's
  authoring gap. Status: **shipped** (2026-07-04).

`PROJECT_STATUS.md` remains authoritative for release gates and deferred work.
