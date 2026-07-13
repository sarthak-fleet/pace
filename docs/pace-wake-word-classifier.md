# Pace wake-word classifier

`PaceWakeWordClassifier.mlpackage` is the bundled local keyword model for
Always-On Companion Mode. It accepts a bounded two-second PCM window and runs
before any Speech framework API is reachable.

## Runtime contract

- Input: `audio_samples`, Float32 multi-array shaped `[1, 32000]`.
- Audio: mono, 16 kHz, normalized to `[-1, 1]`.
- Outputs: `classLabel` and `classLabel_probs` with exact labels `background`
  and `hey_pace`.
- Wake threshold: `0.986`.
- Runtime policy: sample every 4,000 new samples and require two consecutive
  accepted windows. Pre-wake PCM remains in a bounded two-second ring plus one
  coalescing audio-ingress chunk; stop clears ingress immediately.

The model contains an audio-to-mel frontend, the frozen Google speech-embedding
backbone, and a Pace-trained 45,169-parameter temporal CNN head in one Core ML
package. No ONNX runtime or Python dependency ships in the app.
Bundled weight SHA-256: `21bcc05e64da54f6bb26fcc06673cf951d0a24fce68d0efd4b7aa6614e42834c`.

## Training and evaluation

Training used locally synthesized Kokoro-82M v1.0 speech. Speaker families were
disjoint by split:

| Split | Voices | Positive clips | Negative clips | Inference windows |
| --- | ---: | ---: | ---: | ---: |
| Training | 16 | 640 | 893 | 1,789 |
| Calibration | 4 | 160 | 233 | 420 |
| Evaluation | 8 | 320 | 433 | 856 |

The corpus included clean, quiet, room-echo, telephone-band, and pink-noise
variants. Negative clips included close confusables such as “hey space,” “hey
face,” “hey Grace,” “hey Ace,” “okay Pace,” and “Pace,” unrelated speech, pure
noise, and silence. Threshold `0.986` was selected only from calibration results
under a maximum 1% clip-level false-accept constraint.

Compiled Core ML results:

| Split | Recall | False accepts |
| --- | ---: | ---: |
| Calibration | 125/160 (78.13%) | 2/233 (0.86%) |
| Evaluation | 179/320 (55.94%) | 0/433 (0.00%) |

Across all 1,276 calibration and evaluation windows, the maximum absolute
difference between Core ML and the PyTorch reference was `2.8610e-6`. The mel
and speech-embedding conversions independently matched their ONNX references
within `1.4305e-6` and `2.8610e-5`, respectively.

These are synthetic clip-level results, not false accepts per hour. They do not
measure real microphones, rooms, accents, distance, hardware cost, or the
production two-consecutive-window recall penalty. In particular, 55.94%
held-out synthetic recall means misses remain common. The owner explicitly
accepted that dogfood risk for this milestone; the hardware runbook remains the
release gate.

## Provenance and licenses

- Pace temporal head, conversion, and package metadata: MIT.
- `livekit-wakeword` feature-extraction resources and conversion reference:
  Apache-2.0.
- Google `speech_embedding/1` backbone used by those resources: Apache-2.0.
- Kokoro-82M v1.0 weights used only to generate the local corpus: Apache-2.0.
- Acoustic transformations: FFmpeg filters over locally generated material.

No bundled openWakeWord wake-word head, CC BY-NC-SA model, commercial-service
model, or third-party negative corpus was used.

The bundled `PaceWakeWordClassifier-APACHE-2.0.txt` license covers the Apache
backbone and feature-extraction resources incorporated into the model.

## Reproduction recipe

1. Generate “Hey Pace” positives and the documented hard negatives with the 28
   speaker families above, keeping 16/4/8 voices disjoint.
2. Produce the five acoustic variants plus pure noise and silence at 16 kHz
   mono; never mix variants of one voice across splits.
3. Extract 16 consecutive 96-dimensional embeddings from each bounded
   two-second window with the Apache Google speech-embedding frontend.
4. Train the 45,169-parameter temporal CNN head with seed `927`, AdamW
   (`lr=0.001`, weight decay `0.0003`), positive-class weighting, and
   calibration-loss early stopping.
5. Choose the highest-recall calibration threshold whose false-accept rate is
   at most 1%, then evaluate that locked threshold once on the eight-voice
   holdout.
6. Convert the fixed 32,000-sample mel frontend, embedding backbone, and custom
   head into one Core ML ML Program; verify full-corpus output parity
   before replacing the bundled package.
