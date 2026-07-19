# Always-On Companion Mode privacy

Always-On Companion Mode is optional and defaults off. Upgrading Pace never
enables the mode, a sensor, a card, or speech. Camera, ambient voice, screen,
and cheap Mac context each have a separate switch in Settings → Companion.

## What the indicators mean

The menu-bar capsule and Settings show starting, observing, interpreting
locally, paused, degraded, or privacy blocked. Separate dots show camera and
screen sampling. Pause cancels capture/analysis and clears queued
interventions. Degraded means cheap enabled sources may continue while an
unavailable or resource-limited expensive source is suspended.

## Data boundaries

- Camera frames and screen captures live only in bounded memory for gating and
  targeted extraction. Accepted screen frames are take-once.
- Ambient audio uses a local AVAudioEngine/Core ML gate before STT. Its fixed
  model contract is `PaceWakeWordClassifier` with labels `hey_pace` and
  `background`; missing or malformed assets fail closed. Pre-wake audio is not
  transcribed or persisted. Accepted wakes release the analysis microphone
  before a bounded post-wake conversation starts; optional `speaker-1` labels
  disappear when the session ends.
- People are generic presence or expiring `ephemeral-track-*` values. Identity
  fields are rejected during model construction and JSON decoding.
- Objects must be user taught before camera evidence can create a last-seen
  observation. Tracks expire and answers retain confidence/time provenance.
- Structured observations stay in
  `~/Library/Application Support/Pace/companion-observations.json`. Retention is
  1–90 days, with per-source and clear-all controls.

## Local-only inference

Companion planning always uses `makeLocalOnlyPlannerForPrivacyPinnedFeatures()`.
Visual interpretation is in-process or a validated loopback endpoint. Invalid
or remote endpoints fail closed into `privacyBlocked`; the selected cloud tier
is never used. Sensitive-app bundle IDs are denied durable context. Email,
payment-card-like, and secret/token/password values are redacted before
persistence.

## Correction and forgetting

Corrections add high-confidence superseding evidence instead of rewriting
history. Queries retain supporting/contradicting IDs and answer “unknown” when
evidence expires or decays. Forget/clear removes evidence, derived memory,
retrieval documents, and pending candidates together.

## Threat model

| Threat | Control | Residual risk |
| --- | --- | --- |
| Accidental upgrade opt-in | Missing preferences decode to every source/output off. | Users can intentionally enable a source; copy and persistent indicators explain the state. |
| Covert ambient transcription | Direct Core ML inference runs before STT; model/label failures fail closed; pre-wake buffers clear. | Wake false-positive and false-negative rates remain unmeasured on target hardware. |
| Raw data accumulation | Byte/count-bounded buffers, take-once frames, cancellation clearing, no raw persistence field. | OS capture internals are outside Pace’s storage controls. |
| Cloud exfiltration | Privacy-pinned local factories and fail-closed loopback validation. | A user-controlled local process may proxy elsewhere. |
| Sensitive app persistence | Default deny list, redaction, source clear. | Bundle IDs cannot identify every sensitive window. |
| False identity/continuity | No identity schema, taught objects only, expiry, decay, contradiction, provenance. | Local detection can be wrong; this is not security or safety monitoring. |
| Noisy intervention | Cards/speech are separate default-off opt-ins; presentations use policy/deduplication and speech passes live restraint/cooldowns. | Manual repetition/interruption acceptance remains unmeasured. |
| Resource regression | Sampling ceilings, one analysis/source, coalescing, battery/memory/thermal degradation and metrics. | Hardware measurements remain machine-specific. |

Routine promotion requires at least three unique supporting observations; one
observation cannot become a routine. On 2026-07-13 the owner explicitly directed
"push through," accepting the remaining unmeasured live/hardware and manual
`Cmd+R` risk for milestone closeout. This does not mean the thresholds passed.
The preserved measurement protocol is a release follow-up in
[`companion-mode-dogfood.md`](companion-mode-dogfood.md).

Companion Mode is not a security camera, identity system, meeting recorder,
safety monitor, robotics controller, or click/action automation path.
