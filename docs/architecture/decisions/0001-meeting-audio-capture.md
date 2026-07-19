---
title: "ADR-0001: Meeting audio capture approach"
description: Decision record for in-process ScreenCaptureKit meeting audio capture.
---

# ADR-0001: Meeting audio capture approach — in-process SCStream

Date: 2026-07-03
Status: Accepted

## Context

The on-device meeting-notes feature ([PRD](../../product/prds/on-device-meeting-notes.md))
needs to capture two audio tracks: mic (the user) and system (the other
participants). The system track is the harder one — macOS does not expose
a simple "capture system audio" API. Two viable approaches:

1. **In-process SCStream** (ScreenCaptureKit) — the approach Pace already
   uses for watch-mode screen capture and for the existing meeting-mode
   RMS-only stub. `SCStream` with `capturesAudio = true` captures the
   display's audio mix. Requires the **Screen Recording** TCC permission
   (the same one Pace already requests for screen capture).

2. **Out-of-process CoreAudio tap** — a separate helper process (XPC
   service) that installs a `kAudioProcessPropertyTap` on the system
   output process via `AudioHardwareCreateProcessTap`. Requires a
   separate **audio entitlement** + helper app + XPC wiring. This is the
   approach `os-june` took (their ADR-0004).

## Decision

Keep Pace's **in-process SCStream** for system audio capture. Do not
adopt the out-of-process CoreAudio tap.

## 3-part test

- **Hard-to-reverse?** No. Both approaches are replaceable. The
  in-process path is one app, one target, one TCC prompt. Switching to
  an out-of-process tap later is a contained change (add an XPC helper,
  move the capture code, re-prompt for the audio entitlement). No data
  format or persistent state depends on which path produced the audio.

- **Surprising?** Mildly. The tradeoff is Screen-Recording TCC
  (in-process SCStream) vs a separate audio entitlement (out-of-process
  tap). The Screen-Recording TCC is the same permission Pace already
  needs for watch mode and screen context, so it's free for the user —
  they don't see a new permission prompt. An out-of-process tap would
  add a new entitlement they've never seen before.

- **Real trade-off?** Yes. The out-of-process tap is more robust to
  Pace crashes — if Pace's main process dies, the helper keeps recording
  and the audio file survives. The in-process SCStream dies with Pace.
  However, the recorder's `.part` → atomic rename + RIFF-header crash
  repair (`PaceMeetingAudioRecorder.crashRepairIfNeeded`) mitigates the
  in-process crash risk: a force-quit mid-meeting still yields a
  playable file with a patched header. For a single menu-bar app, the
  complexity of an XPC helper + second entitlement is not justified by
  the marginal crash robustness gain.

## Consequences

- One TCC permission (Screen Recording) covers both screen capture and
  system audio capture. No new entitlement.
- If Pace crashes mid-meeting, the recording may be truncated but the
  `.part` file is repairable via `crashRepairIfNeeded` at next launch.
- The SCStream captures the display's audio mix (all apps), not per-app
  audio. This is intentional — meeting audio may come from Zoom, Teams,
  Chrome, or any app. Pace excludes its own process audio via
  `excludesCurrentProcessAudio = true` to avoid capturing its own TTS.
- If a future need arises for per-app audio capture (e.g. "only record
  Zoom's audio"), revisit this decision — SCStream's display-level
  filter can't do per-app audio isolation without additional filtering.

## References

- PRD: [`docs/product/prds/on-device-meeting-notes.md`](../../product/prds/on-device-meeting-notes.md)
- os-june ADR-0004 (out-of-process CoreAudio tap) — referenced in the
  competitive analysis; not in this repo.
- `PaceSystemAudioCapture.swift` — the in-process SCStream implementation.
- `PaceMeetingAudioRecorder.swift` — the two-track recorder + crash repair.
