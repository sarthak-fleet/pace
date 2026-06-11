# Pace — architecture

## Doctrine

1. **Tinygpt's job is to provide Pace the BEST model for each role.** This is a mix of (a) training new specialists where no off-the-shelf model fits — LoRAs, distilled SLMs, fine-tunes; (b) vetting + qualifying external open-source models when they're already good enough — WhisperKit, embedding models, possibly VLMs. Tinygpt is NOT mandated to train everything itself. Sometimes the right call is "this external model passes our eval, ship it as-is." **Pace owns its own model runner at runtime** — embeds MLX-Swift / WhisperKit / CoreML directly, loads bundled artifacts in-process. The current LM Studio development bridge is loopback-only HTTP and is guarded against non-local hosts; the shipping target is in-process model runners. The factory's serve is for development + eval only; Pace ships self-contained, easy to install.
2. **Steal from anywhere that runs local.** Apple frameworks (WhisperKit, AX, EventKit, MessageUI, Shortcuts CLI, NSWorkspace, Speech, FoundationModels for short answer turns), open-source models (Qwen3, UI-Venus, mxbai-embed, BGE, Whisper, Kokoro, Piper), open-source runtimes (MLX, CoreML, llama.cpp, Outlines), open-source datasets (xLAM, ToolBench, FineWeb). The constraint is local-only, not vendor.
3. Fastest AND most precise. Both required.
4. **100 ms is the END-TO-END completion budget**. User-stops-talking → action perceived. Total. Today's path is ~500 ms on the lightest action — not good enough. Parallelize aggressively (ASR partials drive planner prefill; planner emits intent; executor dispatches; all overlapped). Never accept a "good enough" win — keep shaving.
5. All data stays local. No cloud calls, ever. No "fallback to cloud for hard cases."
6. English speakers + Mac only. Narrow focus is the speed advantage.
7. Timelines are bullshit. Ship the next correct thing now.

## The constellation

```
                ┌──────────────────────────────────────────────┐
                │  Voice model — WhisperKit-on-ANE             │
USER VOICE ───►│  streaming partials + LocalAgreement +       │
                │  initial_prompt biasing (vocab from repos)   │
                └─────────────────────┬────────────────────────┘
                                      │ transcript stream
                                      ▼
                ┌──────────────────────────────────────────────┐
                │  Intent disambiguator (planner emits intent) │
                │  dictate │ edit │ action │ answer            │
                │  + reference resolver via AXSelectedTextRange│
                └──┬──────────────┬─────────────────┬──────────┘
                   │              │                 │
       ┌───────────┘              │                 └───────────┐
       ▼                          ▼                             ▼
  ┌──────────┐         ┌────────────────────┐          ┌────────────┐
  │  RAG     │         │  Planner — v10     │          │ Vision     │
  │  mxbai-  │◄───────►│  parameterized     │◄────────►│ UI-Venus + │
  │  embed + │  ctx    │  action emitter    │  context │ ANE chunk  │
  │  SQLite- │         │  {spokenText,      │          │ (#266/#275)│
  │  vec on  │         │   intent, payload} │          │            │
  │  Mail,   │         │  grammar-          │          │            │
  │  Notes,  │         │  constrained       │          │            │
  │  Files,  │         │  119ms TTFW        │          │            │
  │  past    │         │                    │          │            │
  │  Pace    │         │                    │          │            │
  └──────────┘         └─────────┬──────────┘          └────────────┘
                                 │
                                 ▼
                ┌──────────────────────────────────────────────┐
                │  Executor — AX dispatch primary              │
                │  AX setValue + AXPress, then EventKit,       │
                │  MessageUI, MapKit, Contacts, shortcuts run  │
                │  CGEvent keyboard fallback (never pasteboard)│
                └──────────────┬───────────────────────────────┘
                               │
                               ▼
                ┌──────────────────────────────────────────────┐
                │  Responder                                   │
                │  streaming TTS via Apple SpeechSynth +       │
                │  bodyText streamed into AX setValue +        │
                │  HUD overlay                                 │
                └──────────────────────────────────────────────┘
```

## Stolen from Apple

Every box above leans on something Apple already shipped. Pace writes glue, not models from scratch.

| Pillar | Apple gift | Used as |
|---|---|---|
| Voice model | WhisperKit (Argmax OSS, May 2026) on ANE | Streaming ASR with LocalAgreement |
| Voice model | Apple Speech framework | Fallback / quick partial when WhisperKit is loading |
| Vision | CoreML + ANE compute units | UI-Venus port lives here |
| Vision | Apple Vision OCR (VNRecognizeTextRequest) | OCR pipeline for screen text |
| RAG | NSMetadataQuery / Spotlight | Initial file retrieval before semantic re-rank |
| RAG | EventKit | Calendar + Reminders index |
| RAG | Contacts framework | Name resolution + recipient lookup |
| Executor | AX (AXUIElement) | Primary dispatch — AXPress, setValue, AXSelectedTextRange |
| Executor | NSWorkspace | App launch + frontmost detection |
| Executor | EventKit / MessageUI | Calendar, mail, message dispatch |
| Executor | `shortcuts run` CLI | Last-mile fallback for non-AX-compliant actions |
| Responder | Apple SpeechSynthesizer | TTS, streaming |
| Responder | NSWindow + NSPanel | HUD overlay |
| Permissions | Accessibility + Input Monitoring | One-time onboarding; required for AX dispatch |
| Answer planner | Apple Foundation Models (3B) | Fast in-process pure-knowledge answers when Apple Intelligence is available; larger LM Studio planner still handles harder action/screen turns. |

## Models — tinygpt picks the best per role; Pace runs them

Tinygpt's deliverable per pillar is "the BEST model for this role, whether we trained it or vetted it." Each model goes through tinygpt's eval gate before Pace bundles it. Two paths:

- **Train new specialist** — when no off-the-shelf model fits the role well enough (e.g., Pace planner v9/v10, voice-edit, dictation post-proc). Factory loop produces LoRA + dataset + eval.
- **Vet external** — when an open-source model is already good enough (e.g., WhisperKit-large-v3-turbo for ASR, mxbai-embed-large for embeddings, UI-Venus for VLM). Tinygpt verifies on Pace's eval suite, possibly fine-tunes lightly, then qualifies for shipping.

Once approved, the artifact (LoRA file + base reference, or external model dir, or quantized CoreML bundle) is **bundled into Pace** and loaded in-process via Pace's embedded MLX-Swift / WhisperKit / CoreML runner. All models load at app boot (eager), live resident in memory, fire conditionally per intent.

| Baby | Base | Job | Status |
|---|---|---|---|
| `pace-planner` (runtime today) | `qwen/qwen3-30b-a3b` MoE via LM Studio | main screen/action planning | shipped — eval-validated 15/15 on FM fixtures at 925ms mean (`scripts/eval-planners.py`); the v8 LoRA deployment PRD is superseded by this off-the-shelf choice |
| `pace-planner-v9/v10` (LoRA path) | Qwen3-0.6B + LoRA | intent routing, compose body, parameterized actions | parked on the TinyGPT side; resumes if the trained specialist beats the MoE on the eval gate |
| `pace-vlm` | UI-Venus-1.5-2B / Qwen3-VL | screen understanding beyond OCR | porting (#266) |
| `pace-rag` | JSON-backed BM25-style lexical scaffold now; **Qwen3-Embedding-0.6B** planned for vector retrieval | retrieval over personal corpus | lexical fallback + built-in Project Minimi competitive seed + Settings-selected explicit-root Spotlight files + Calendar/Reminders/Contacts/Notes/Mail sources wired; embedding/vector runtime queued |
| `pace-edit` | Rule scaffold now; Qwen3-0.6B + LoRA later | selected-text transforms ("more direct", "shorter", "delete that") | deterministic scaffold wired |
| `pace-dict-postproc` | Rule scaffold now; Whisper-medium + LoRA OR Qwen3-0.6B post-Whisper later | punctuation, capitalization, code-mode, vocab repair | scaffold wired |
| `pace-intent` | tiny ~50M classifier | dictate / edit / action / answer route | folded into planner v10 initially |

Every baby is English-only + Mac-only. No localization. No cross-platform. Narrower training corpora → faster convergence → higher precision per param.

## 100 ms per step — measured + targeted

| Step | Today | Target | Mechanism |
|---|---|---|---|
| ASR streaming partial first chunk | 100-200 ms (Apple Speech) | ≤ 100 ms | WhisperKit provider scaffold wired with LocalAgreement partial stabilization already runtime-wired; real streaming bridge queued |
| Intent + planner TTFW | LM Studio qwen3-30b-a3b, ~925 ms mean per eval-planners.py | ≤ 100 ms | trained-specialist path (119 ms warm via tinygpt serve) parked until it beats the MoE on the eval gate |
| RAG retrieve top-K | JSON-backed BM25-style lexical scaffold | ≤ 80 ms | preferences/Pace history/Calendar/Reminders/Contacts/Notes/Mail/screen-watch + app-usage journals now; Qwen3-Embedding + SQLite-vec queued |
| Vision single-frame analyze | LM Studio HTTP + provider scaffold | ≤ 200 ms | UI-Venus 24 vision blocks on ANE chunked (#275); in-process runtime bridge queued |
| Executor — AX dispatch | < 20 ms when target known | ≤ 50 ms | AXPress + setValue, no scripting layer |
| Responder — TTS first audible | ~ 200 ms | ≤ 200 ms | Apple SpeechSynthesizer streaming |

Pace doesn't always run all steps. Intent decides which sub-pipeline fires.

## Critical paths and the 100 ms end-to-end push

**The target is 100 ms cradle-to-grave for the lightest action.** Today we're at ~400-500 ms. Get there by:

1. **Parallelize, don't serialize**. The classical "ASR finishes → planner starts → executor starts" pipeline is dead. Run all three in overlap.
2. **Speculative dispatch** on ASR partials. If partial transcript matches a high-confidence trigger ("draft mail to ..."), kick off `mailto:` BEFORE the planner finishes. If planner disagrees, retract (close empty window). Cheap retract, big perceived win.
3. **Pre-baked prompt cache** at boot. System-prompt KV cache resident in memory; every PTT press skips 100% of prefill.
4. **ANE for planner**, not GPU. We have M8 chained for Qwen3-0.6B (#269). Run the planner on ANE so GPU is free for vision; ANE first-token is sub-30 ms.
5. **MLX compile + spec decode** (#262). Pending. Cuts decode latency 2-3×.
6. **Skip initial TTS** for routine actions. "Click save" doesn't need spoken confirmation — the click IS the feedback. Pace now suppresses initial narration for routine local plans, gates stream-time narration once a routine plan is visible, and still speaks post-action results/failures.
7. **Streaming partial-JSON → executor**. Already shipped (#274). Body chunks dispatch as they emit; don't wait for closing brace.
8. **Smaller planner** for routing-only cases. If a 200M-param model can do 95% of routing at 5× speed, ship it as the fast-path and fall back to v10 only when 200M is uncertain.

Path-specific targets (PERCEIVED-FEEDBACK = first-thing-user-sees-or-hears):

| User said | Pipeline | Target perceived | Target full completion |
|---|---|---|---|
| Dictation | ASR partials → typewriter (parallel) | < 100 ms first char in field | < ASR final + 50 ms |
| "Click save" / "Open Safari" | ASR partial → planner intent → AX (overlapped) | < 100 ms action initiated | < 250 ms action visible |
| "Draft mail to john about X" | ASR partial → speculative mailto: + planner body stream → AX setValue | < 100 ms compose flicker starts | < 700 ms full body typed |
| "Make this more formal" (selection) | AX selection cached → planner edit → AX setValue | < 200 ms first new text | < 500 ms full rewrite |
| "What did Priya say about the design" | RAG retrieve concurrent with planner spinup → answer streams to TTS | < 300 ms first audible | < 1 s full answer |
| "What's the chart showing" | Vision warm-spun at PTT press → planner → TTS | < 400 ms first audible | < 800 ms full description |

Perceived ≤ 100 ms is the bar for the lightest cases. Everything heavier should still START in < 200 ms even if completion takes longer. Never let user wait without feedback.

## Text injection rules

1. **AX `setValue` on `AXValue` / `AXSelectedTextRange` is primary.** No clipboard pollution. Works in most AX-compliant apps.
2. **`CGEventKeyboardSetUnicodeString` (typewriter mode) is fallback** for Electron/web/non-AX-compliant. Slower but reversible.
3. **NSPasteboard + ⌘V is BANNED.** It pollutes user's clipboard and Wispr users report this as a pain point. We do not bank a moat then give it away with one paste call.
4. Secure-text-entry fields (passwords) are explicitly out of scope. We refuse, with a spoken explanation.

## Constraint enforcement

- All planner outputs are grammar-constrained JSON (tinygpt serve `--grammar`).
- All action calls are validated against the action's args schema before dispatch.
- The model cannot emit a malformed JSON or an unknown action name. This is a hard guarantee from the decode layer, not a runtime check.

## Zero-cloud rule

No network egress. Loopback-only HTTP is allowed for local development runtimes such as LM Studio, and `PaceLocalEndpointGuard` refuses planner/VLM endpoints that are not `localhost`, `127.0.0.0/8`, or `::1`. No telemetry "for analytics". Crash logs are local-only or opt-in plain-text. The product positioning is unambiguous and we will not undermine it for a feature shortcut. If a capability requires cloud, we don't ship it.

## What we are NOT doing

- Multilingual support (English-only)
- Windows / Linux / iPhone (Mac-only)
- Marketplace / SDK (closed-source consumer product)
- Cloud anything (see above)
- BYOK to OpenAI/Anthropic (violates positioning)
- Generic chat (Pace acts, doesn't ramble)
- ReAct multi-turn agentic loops (latency-killing; single-shot tool dispatch only)
- Reinventing what Apple already shipped

## The ordering

Built in this sequence because each baby unblocks the next:

1. v9 (LoRA path parked; runtime planner is LM Studio qwen3-30b-a3b) — body streaming demo
2. Executor surface (Pace-side Swift, AX-first dispatcher with first-party fallbacks)
3. v10 (parameterized actions) — depends on executor surface existing
4. WhisperKit integration — replace Apple Speech for code-mode + vocab biasing
5. RAG layer (embedding model + index over Mail/Notes/files/past sessions)
6. VLM port + ANE chunked
7. Dictation post-processor + voice-edit specialist
8. HUD overlay + intent disambiguator carve-out
9. Restraint policy for every proactive source
10. Episodic memory
11. Always-listening mode
12. Proactive nudges
13. Barge-in TTS interrupt
14. Demonstration replay
15. Polish + ship

There are no months. There are next-correct-things. Do the next one.

## Source PRDs

- PRD index: `pace/docs/prds/README.md`
- Her arc roadmap: `pace/docs/prds/her-arc-roadmap.md`
- tinygpt-side body streaming: `tinygpt/docs/prds/pace-v9-body-streaming.md`
- Pace-side body streaming wiring: `pace/docs/prds/pace-v9-body-streaming-wiring.md`
- Planner v10 parameterized actions: `pace/docs/prds/pace-planner-v10-parameterized-actions.md`
- Executor surface: `pace/docs/prds/pace-executor-surface.md`
- Click executor: `pace/docs/prds/click-executor-improvements.md`
- Planner v8 deployment: `pace/docs/prds/pace-planner-v8-deployment.md`
- WhisperKit streaming ASR: `pace/docs/prds/whisperkit-streaming-asr.md`
- Local RAG layer: `pace/docs/prds/local-rag-layer.md`
- Local VLM runtime port: `pace/docs/prds/local-vlm-runtime-port.md`
- Dictation post-processing and voice edit: `pace/docs/prds/dictation-postproc-and-voice-edit.md`
- HUD and intent disambiguator: `pace/docs/prds/hud-intent-disambiguator.md`
- Restraint policy: `pace/docs/prds/restraint-policy.md`
- Episodic memory: `pace/docs/prds/episodic-memory.md`
- Always-listening mode: `pace/docs/prds/always-listening-mode.md`
- Proactive nudges: `pace/docs/prds/proactive-nudges.md`
- Barge-in TTS interrupt: `pace/docs/prds/barge-in-tts-interrupt.md`
- Demonstration replay: `pace/docs/prds/demonstration-replay.md`

This file is the canonical map. PRDs are the per-pillar specifications. When in doubt, this doc wins.
