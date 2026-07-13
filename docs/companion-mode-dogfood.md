# Always-On Companion Mode dogfood gate

This is the acceptance record for OpenSpec tasks 6.2–6.5, 7.5, and 8.4.
Do not check those tasks or unlock cards, speech, or routine learning from a
code review or synthetic test run. Record measured evidence from a signed
Xcode `Cmd+R` build on Apple Silicon here first.

## Current executable surface

- Camera: the production AVFoundation client samples at no more than 1 fps,
  computes a 32×24 luma motion delta, and runs Vision human-rectangle
  detection. It emits only non-identifying, session-local person tracks in the
  coarse `room` zone. Full camera frames do not cross the capture client and
  are not persisted.
- Screen and Mac context: existing Watch Mode and ambient-context loops feed
  the world model without duplicate polling.
- Wake conversation: Settings → Companion → Talk to Pace now explicitly invokes
  the existing push-to-talk conversation path. The separate legacy always-listening
  preference also hands an accepted wake event into a bounded six-second
  post-wake push-to-talk window; the detected phrase itself is never sent to the
  planner. Companion ambient voice stays visibly degraded: the legacy Apple
  Speech spotter recognizes speech to find the phrase, so it cannot satisfy the
  stricter companion invariant that pre-wake speech never reaches STT. Do not wire
  it into companion capture or describe it as satisfying that invariant.
  Graduation needs an approved, genuinely pre-STT local keyword gate.
- Objects: Settings → Companion lets the user hold an object centered in view
  and capture a local Vision feature print. No photo is persisted. The low-rate
  camera compares overlapping coarse left/center/right regions, accepts only
  matches inside a conservative distance threshold, and emits expiring
  user-taught object evidence into the existing last-seen pipeline. Accuracy
  and continuity still require the hardware runs below.
- Output: unsolicited cards, speech, and routine promotion remain locked in
  production regardless of stored preferences.

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

If any threshold fails, keep observe-only enabled only for developers, leave
all downstream gates locked, and attach the failing measurements to the next
iteration.

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
6. Click **Talk to Pace now** and complete a turn through push-to-talk. Do not enable the
   companion Ambient voice source until a true pre-STT keyword gate exists.
7. Teach a centered object, move it through the three coarse camera zones, and
   inspect the structured evidence. Confirm the store contains a feature-print
   archive and label but no source pixels; verify stale/unknown wording after expiry.
8. Confirm Silent cards and Spoken interventions remain disabled. No
   observation may create a card, clarification, speech, or action.
9. Complete every row in the threshold table with dated measurements before
   changing an acceptance constant.

## Downstream unlock order

1. Finish and pass person, object, wake, resource, privacy, and lifecycle
   observe-only gates.
2. Unlock silent cards behind their separate default-off preference and rerun
   repetition/accuracy dogfood. Cards must never imply identity or certainty
   beyond provenance.
3. Pass active-call, Focus, recent-input, cooldown, repetition, and interruption
   fixtures plus live dogfood before unlocking restraint-gated speech.
4. Enable routine learning last, only after all four room outcomes remain above
   threshold over at least seven days. A single observation must never become
   a routine.
