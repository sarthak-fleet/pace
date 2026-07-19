# Always-On Companion Mode dogfood gate

This preserves the live/hardware acceptance protocol for Always-On Companion
Mode. On 2026-07-13 the owner explicitly directed "push through," accepting the
remaining unmeasured live/hardware and manual Xcode `Cmd+R` risk for milestone
closeout. No signed live build, threshold row, or manual checklist item is
represented as performed or passed. Complete and record this evidence before a
release claim that relies on these thresholds.

## Current executable surface

- Camera: the production AVFoundation client samples at no more than 1 fps,
  computes a 32×24 luma motion delta, and runs Vision human-rectangle
  detection. It emits only non-identifying, session-local person tracks in the
  coarse `room` zone. Full camera frames do not cross the capture client and
  are not persisted.
- Screen and Mac context: existing Watch Mode and ambient-context loops feed
  the world model without duplicate polling.
- Wake conversation: Settings → Companion → Talk to Pace now explicitly invokes
  the existing push-to-talk conversation path. Ambient voice uses a production
  local Core ML gate before STT, requiring consecutive
  high-confidence `hey_pace` classifications from `PaceWakeWordClassifier` and
  validating that both exact labels, `hey_pace` and `background`, exist. Missing
  permission, model, labels, or audio input fails closed. An accepted wake
  releases the analysis microphone before a bounded post-wake conversation;
  pre-wake audio is not transcribed or persisted. The bundled model's synthetic
  metrics and limitations are recorded in `pace-wake-word-classifier.md`.
- Objects: Settings → Companion lets the user hold an object centered in view
  and capture a local Vision feature print. No photo is persisted. The low-rate
  camera compares overlapping coarse left/center/right regions, accepts only
  matches inside a conservative distance threshold, and emits expiring
  user-taught object evidence into the existing last-seen pipeline. Accuracy
  and continuity still require the hardware runs below.
- Output: silent cards and spoken interventions are independently default off.
  When explicitly enabled, typed observations flow through the intervention
  policy, provenance-safe presenter, deduplication/queueing, and existing live
  restraint path for speech. Routine promotion requires three unique supporting
  observations; a single observation cannot become a routine.

## Observe-only thresholds

Use one representative 16 GB Apple Silicon Mac and one higher-memory Mac when
available. Keep Pace otherwise idle, enable only the source under test, and
retain the raw measurement output with the PR or release evidence.

| Gate | Required evidence | Pass threshold |
| --- | --- | --- |
| CPU | `ps` samples every 10 seconds for 30 idle minutes and 30 active-room minutes | idle p95 ≤ 8%; active p95 ≤ 15% |
| Resident memory | RSS before enable and after 60 minutes | delta ≤ 250 MB and no monotonic growth over the final 30 minutes |
| Analysis rate | accepted/dropped candidate and analysis counters over 60 minutes | camera analysis ≤ 60/min; screen analysis obeys Watch Mode cadence; one in flight/source |
| Journal growth | structured observation file bytes at start and after 8 hours | projected growth ≤ 5 MB/day and total remains below the 20 MB budget |
| Person entry | 30 scripted entries/exits across room lighting conditions | precision ≥ 90%, recall ≥ 90%, no identity-like persisted field |
| Object continuity | 20 scripted moves of each taught object between named zones | last-seen zone accuracy ≥ 90%; stale/unknown wording after expiry |
| Wake quality | 40 addressed phrases plus 8 hours ordinary room audio | false negatives ≤ 10%; false positives ≤ 1 per 8 hours; zero pre-wake STT calls/persisted audio |
| Pause | ten active-capture pauses measured from click to camera/mic indicator off | p95 ≤ 500 ms; no observations after pause timestamp |
| Sleep/wake | ten sleep/wake cycles with camera enabled | capture stops before sleep and resumes once after wake; no duplicate session |
| Permission loss | revoke camera/mic while observing, then restore intentionally | affected source stops and reports blocked/degraded; other sources continue |
| Local model unavailable | stop loopback models while screen interpretation is enabled | no off-device request; visible local-model degradation; cheap sources continue |

These rows remain release follow-ups. If a threshold fails, keep the affected
source/output out of release claims and attach the measurements to the next
iteration. The 2026-07-13 owner waiver closes the milestone risk; it does not
alter a threshold or manufacture a pass.

## Manual Xcode checklist

Run from Xcode, never terminal `xcodebuild`:

1. Build and run with `Cmd+R`; confirm companion mode and every source are off
   on a fresh defaults domain.
2. Enable Camera in Settings → Companion. Confirm the native permission prompt
   appears once, camera activity is visible in Settings and the menu bar, and
   denial removes camera from active sources while Mac context can continue.
3. Walk into and out of frame. Confirm stored observations contain only
   `personPresence`, an `ephemeral-track-*` identifier, time, confidence, and
   `room`; inspect the JSON to prove no pixels or identity are present.
4. Press Pause while capture is active. Confirm the indicator clears within
   the threshold and no later camera observation appears.
5. Sleep and wake the Mac. Confirm one capture session resumes and status does
   not remain stuck at `starting`.
6. Click **Talk to Pace now** and complete a turn through push-to-talk. Then,
   with a valid bundled wake model, enable Ambient voice, address `hey pace`,
   and verify that pre-wake audio never reaches STT or persistence.
7. Teach a centered object, move it through the three coarse camera zones, and
   inspect the structured evidence. Confirm the store contains a feature-print
   archive and label but no source pixels; verify stale/unknown wording after expiry.
8. Confirm Silent cards and Spoken interventions are separately off on fresh
   defaults. Enable each independently: cards must retain provenance and avoid
   identity claims; speech must stay silent during active-call, Focus,
   recent-input, and cooldown conditions.
9. Confirm routine promotion requires three unique supporting observations.
10. Complete every row in the threshold table with dated measurements before
    making a release claim based on those thresholds.

## Release follow-up order

1. Measure person, object, wake, resource, privacy, and lifecycle rows on target
   hardware; retain dated evidence.
2. Rerun silent-card repetition/accuracy and provenance checks with cards as a
   separate opt-in. Cards must never imply identity or excess certainty.
3. Run active-call, Focus, recent-input, cooldown, repetition, and interruption
   live checks with speech as a separate opt-in.
4. Observe routine quality over at least seven days while preserving the
   minimum of three unique supporting observations.
