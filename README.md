# Pace

**Product:** [heypace.app](https://heypace.app)


<p align="center">
  <img src="docs/brand/pace-mascot-hero.svg" alt="Pace — your Mac, listening. Fully on-device." width="820">
</p>

**Voice agent for Mac. Answers in under 500ms. Zero API cost. Fully on-device.**

![Pace demo](pace-demo.gif)

<sub>Meet the mascot — the notch, alive. Brand assets in [`docs/brand/`](docs/brand/).</sub>

A menu-bar voice agent for macOS. Hold a hotkey, talk, and Pace answers — reading the screen you're looking at and (optionally) clicking on your behalf. Every byte stays on your Mac.

**[Download for Mac — free](https://github.com/sarthakagrawal927/pace/releases/latest)** · macOS 14.2+, Apple Silicon, no account, no email.

- **Every byte stays on your Mac.** No cloud LLM, no API keys, no Cloudflare Worker. Speech, vision, reasoning, and speech-out all run locally. The "airplane mode" badge is the moat — Wispr Flow, Claude Computer Use, and Superhuman literally cannot ship this.
- **Time-to-first-spoken-word in milliseconds, not seconds.** Streaming sentence-by-sentence TTS, pre-warmed VLM + OCR during your speech window, prompt-cache reuse across turns, and per-screen hash caching collapse the perceived latency. The number is logged per turn (`⚡ TTFSW: …ms`) and aggregated by [`scripts/benchmark_ttfsw.sh`](./scripts/benchmark_ttfsw.sh) — own the metric, don't just claim the speed.
- **Agent mode that acts.** With `EnableActions=true` Pace can click, type, scroll, and press keys — synthesised via AX-tree-first targeting that falls back to CGEvent. The app can ask for approval before executing tools. Plan-act-observe loop re-screenshots between actions; the planner emits `[DONE]` when finished. Capped at 8 steps by default.
- **Quiet by default.** Action mode off; permissions gated; the local VLM only fires when the transcript references the screen.

## Install (users)

Grab the latest build from [Releases](https://github.com/sarthakagrawal927/pace/releases/latest) and launch it. Apple Intelligence Macs can talk to Pace immediately via the Apple Foundation Models tier — zero external installs. Bigger local models (in-process MLX planner/VLM/ASR/TTS) download from **Settings → Models** inside the app and enable with one toggle there; no external tools required.

## Build from source (developers)

```bash
# Open the project and Cmd+R. Models come from Settings → Models in-app.
open leanring-buddy.xcodeproj

# OPTIONAL power-user path: LM Studio as the planner/VLM backend
# (larger models than the bundled defaults). Idempotent provisioner:
./scripts/setup-local.sh
```

Full setup details, switches, and tuning guidance: see [`SETUP_LOCAL.md`](./SETUP_LOCAL.md).

Architecture and per-file responsibilities: see [`AGENTS.md`](./AGENTS.md).

## What it runs on

- **Speech-to-text**: Apple `SFSpeechRecognizer` (on-device, instant); WhisperKit auto-preferred when its model is installed.
- **Screen understanding**: a small vision-language model — bundled MLX VLM by default, or LM Studio (UI-Venus-1.5-2B, the GUI-specialist 2B model) on the power-user path — merged with native Apple Vision OCR for text fidelity.
- **Reasoning / planning**: Apple Foundation Models out of the box; one toggle enables the in-process MLX planner (Qwen3-4B); or any OpenAI-compatible local reasoner via LM Studio (Qwen3-30B-A3B MoE scored 15/15 on Pace's eval at ~925ms mean). `cache_prompt: true` sent on every request. Optional tiers: Apple Foundation Models, BYO-key Direct API, CLI bridge — all opt-in, all visibly indicated.
- **Text-to-speech**: Kokoro-82M via a loopback sidecar (~150 ms/sentence warm) with `AVSpeechSynthesizer` fallback, sentence-streamed so audio starts within ~500ms of the planner's first token.
- **Click / keystroke synthesis**: `AXUIElement` (semantic press) then `CGEvent` fallback.
- **Meeting notes**: mic + system audio captured as two 16 kHz tracks, segmented, transcribed, and summarized entirely on-device.
- **Cursor**: Codex-style arrow with linear gradient + highlight stroke.

## Requirements

- macOS 14.2+ (ScreenCaptureKit)
- Xcode 16+ to build from source (SwiftPM synchronized folder groups)
- Apple Silicon recommended (MLX acceleration)
- ~12–25 GB free RAM with models loaded (bundled defaults; the optional LM Studio 30B planner wants ~20–28 GB)
- Homebrew only for the optional LM Studio path

## Benchmark your own latency

```bash
# Use Pace normally for a few minutes, then:
./scripts/benchmark_ttfsw.sh --last 10m
```

Outputs a markdown table with n, min, p50, p95, max, mean for TTFSW (time-to-first-spoken-word) and TTFT (planner time-to-first-token). The number you publish is the number you measure on your own machine — paste straight into PRs, blog posts, or the landing page.

## Test coverage

Pace targets an **EXEMPLARY** testing tier: **> 80%** line coverage on core logic (parser, executor, memory, planner clients) and **> 70%** on UI. The suite is 1079 tests (see `PROJECT_STATUS.md` for the current count), and coverage is collected on every CI run.

<!-- coverage badge placeholder — swap in a live badge once coverage gating is wired to a reporting backend -->
![coverage](https://img.shields.io/badge/coverage-EXEMPLARY%20tier-blue)

Run coverage locally:

```bash
./scripts/test-pace.sh --coverage
```

Per-component targets, local extraction details, and how CI enforces coverage: see [`docs/test-coverage.md`](./docs/test-coverage.md).

## License

MIT — see [`LICENSE`](./LICENSE).

---

*Wispr Flow needs a server. Claude Computer Use needs the cloud. Pace needs neither — and it answers in under 500ms.*
