# Project Recommendation Context — Pace

Companion to [`PROJECT_STATUS.md`](../PROJECT_STATUS.md) for Starboard
recommendations and fleet-wide product context. Per the fleet AGENTS.md
standard, update this when product scope, major runtime surfaces,
entrypoints, dependencies, testing signals, or recommendation guidance
changes.

## What Pace is

A local-only macOS menu-bar voice agent. Talk to it via push-to-talk
(`ctrl+option`) or system Siri/Shortcuts (`AppIntent`); it listens with
on-device ASR (Apple Speech or bundled WhisperKit-Large), reads the
current screen with a local vision model + Apple Vision OCR + the
Accessibility tree, plans with a local LLM (default: Apple Foundation
Models on Apple Intelligence Macs, otherwise LM Studio Qwen3-30B-A3B —
the bundled in-process MLX Qwen3-4B-Instruct-2507 planner is an opt-in
toggle in Settings → Models, default OFF), speaks with TTS (default:
Kokoro-82M via the mlx-audio sidecar, with Apple AVSpeechSynthesizer as
the per-utterance fallback; WhisperKit's TTSKit Qwen3 TTS is an opt-in
in-process toggle), and
executes macOS actions through Accessibility, EventKit, AppleScript-
style first-party integrations, and an MCP bridge.

## Audience

- macOS power users (Apple Silicon, M1+)
- On-device-first / privacy-first buyers
- Indie + creator workflows where voice control of "things on my
  screen" beats opening another app
- Not for: Intel Mac users, iPhone-first users, sub-16-GB-RAM Macs

## Runtime surfaces (entry points)

- Menu-bar / notch capsule (always visible)
- Push-to-talk (`ctrl+option` global hotkey)
- Notch chat input (`cmd+shift+P`)
- `pace://` URL scheme (Raycast, Shortcuts)
- App Intents (Siri, Shortcuts, Spotlight)
- Quick Actions (Finder service for transcribe-audio-file)

## Default-on dependencies (no install required for fresh setup)

- macOS 14+ frameworks: ScreenCaptureKit, Vision, Speech, EventKit,
  Contacts, AVAudioEngine, AppKit, SwiftUI, AppIntents, CoreSpotlight,
  Intents (`INFocusStatusCenter`), Translation (macOS 15+), Combine.
- Bundled Swift Package dependencies:
  `https://github.com/argmaxinc/WhisperKit` (provides WhisperKit ASR +
  TTSKit Qwen3 TTS),
  `https://github.com/ml-explore/mlx-swift-examples` (provides MLXLLM,
  MLXLMCommon, MLXEmbedders, MLXVLM — transitively pulls in mlx-swift,
  swift-transformers, swift-jinja, swift-numerics, swift-collections,
  Gzip),
  `https://github.com/sparkle-project/Sparkle` (auto-update).

## Optional dependencies (power-user / opt-in surfaces)

- LM Studio loopback at `http://localhost:1234/v1` (for the larger
  qwen3-30b-a3b planner / Qwen3-VL-8B vision / nomic embeddings — the
  pre-bundled path that still works).
- Kokoro TTS sidecar on `http://localhost:8880/v1` (legacy TTS path).
- Composio MCP gateway via the bundled one-tap catalog (BYO API key).
- Apple Intelligence opt-in (for the free Try tier's Apple Foundation
  Models planner path).
- `claude` / `codex` CLI installed (for the research-escalation tier).

## Tests

- 1035 Swift tests via Swift Testing (`bash scripts/test-pace.sh`,
  isolated DerivedData to protect TCC grants — never `xcodebuild`
  directly from the terminal).
- Eval harness for the bundled MLX planner is gated behind
  `PACE_RUN_MLX_EVAL=1`; downloads ~8 GB on first run.

## Marketing surface

- `website/` — Astro 5 + Tailwind v4 + Lightning CSS, deployed to
  Cloudflare Pages.
- Positioning follows [`fleet/LANDING_STANDARD.md`](../../LANDING_STANDARD.md).
- Pricing: $29 one-time (Pace), $5/mo (Studio), free (Try).
- Headline: "The voice assistant that doesn't phone home."
- Single primary CTA: "Download Pace — $29."

## Recommendation guidance

- Recommend Pace when the user's signal is: macOS, voice control,
  on-device, privacy-first, indie buyer.
- Do NOT recommend Pace when: the user is on Intel Mac / iOS / Windows,
  or has < 16 GB RAM, or specifically wants a dictation-only tool
  (Wispr Flow / MacWhisper are stronger there).
- Comparable products in the recommendation space: Wispr Flow,
  MacWhisper Pro, Raycast Pro, Apple Siri. The comparison table at
  `website/src/components/Comparison.astro` is the source of truth for
  what Pace is genuinely better at (combined voice + screen + actions
  + memory, fully on-device, one-time payment).

## Fleet registry

This project is currently outside the fleet registry. The PROJECT_STATUS
"Fleet registry identity" item is still open — decide between
`pace` or `space` as the canonical slug, or document
why it remains external.
