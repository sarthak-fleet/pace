# Pace learning roadmap

A map of every novel framework, algorithm, API, and non-obvious engineering
pattern in Pace — the on-device macOS voice+action assistant. Read this to
onboard onto *what's genuinely new here*, not the SwiftUI boilerplate.

## How to read this

Each entry is deliberately short (per the fleet docs standard):

- **What** — one sentence.
- **Why here** — one sentence on the role it plays in *this* project.
- **Where** — the file / type to open in the codebase (line numbers drift; the
  symbol name is the durable anchor).
- **Source** — the canonical external doc/paper/repo. When the concept has a
  definitive external source we do **not** re-explain it — follow the link.

Concepts are **not** duplicated across pages. If page A needs a concept that
lives on page B, it links there with a one-line pointer.

## Pages

| Page | Covers |
| --- | --- |
| [`new-things.md`](new-things.md) | **Foundational frameworks** — Apple FoundationModels, MCP, WhisperKit, Kokoro/mlx-audio, ScreenCaptureKit, Accessibility API, LM Studio (+ JIT loading/idle-unload keepalive), BM25, `@Generable`, constrained decoding (`response_format: json_schema`), loopback-guard, speculative planner race |
| [`memory-and-retrieval.md`](memory-and-retrieval.md) | Two-tier thread memory, rolling FM summary, episodic facts, local retrieval + embedding rerank, CoreSpotlight mirror, journals |
| [`screen-and-vision.md`](screen-and-vision.md) | VLM element maps, screen diffing, watch mode, Set-of-Mark click recovery + mark-reading measurement, Vision OCR + NSDataDetector, ambient context |
| [`actions-and-accessibility.md`](actions-and-accessibility.md) | Tool registry, plan-act-observe loop, AX vs CGEvent, approval/risk policy, undo mutation log, deeplinks, App Intents, `download_file` |
| [`audio-pipeline.md`](audio-pipeline.md) | Push-to-talk CGEvent tap, streaming sentence TTS, barge-in VAD, wake word, two-track meeting capture, turn segmentation, RIFF crash repair |
| [`planning-and-latency.md`](planning-and-latency.md) | Intent classifier, planner tier picker, RAM budgeting for co-resident models, latency budget/TTFSW, restraint gate, thermal advisor |
| [`skills-and-automation.md`](skills-and-automation.md) | Teachable `.skill.md` skills, recorded flows, recipes, meeting-note profiles, voice command parsers + chain-precedence lesson, cron scheduler, consent-gated background automation |
| [`proactive-surfaces.md`](proactive-surfaces.md) | Proactive nudge framework, morning triage, focus-fatigue, posture monitor, active-call/IDE detectors |
| [`infra-and-patterns.md`](infra-and-patterns.md) | Loopback endpoint guard, atomic temp-file+rename, Keychain, Sparkle updates, MCP bridge/catalog, `LSUIElement` menu-bar-only, Swift 6 concurrency idioms, CI hardware-boundary lessons |

## Architecture cross-references

- Full architecture prose: the [repository AGENTS.md](https://github.com/HeyPace/pace/blob/main/AGENTS.md), [`architecture/overview.md`](../../architecture/overview.md), and [`architecture/systems.md`](../../architecture/systems.md).
- Per-file reference table: [`development/key-files.md`](../../development/key-files.md).
- Info.plist switches that gate many of these features: [`development/info-plist-switches.md`](../../development/info-plist-switches.md).
