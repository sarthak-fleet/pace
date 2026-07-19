# Pace - Info.plist switch reference (local mode)

<!-- Canonical home for the local-mode Info.plist switch table. Linked from AGENTS.md → Architecture → Local-mode setup, and from SETUP_LOCAL.md. -->

See [SETUP_LOCAL.md](https://github.com/HeyPace/pace/blob/main/SETUP_LOCAL.md) for the full local-mode recipe. This is the canonical summary of the Info.plist switches that control local VLM / planner / TTS / transcription behavior; it was relocated here from the [repository AGENTS.md](https://github.com/HeyPace/pace/blob/main/AGENTS.md) to keep the agent-instructions file lean.

Always-On Companion Mode adds no Info.plist enable switch. Mode, camera,
ambient-voice, screen, Mac-context, silent-card, and spoken-intervention choices
are explicit default-off UserDefaults managed in Settings → Companion. Companion
visual inference still honors `LocalVLMBaseURL` but validates it fail-closed as
loopback-only; it never uses the selected cloud conversational tier. See
[`companion-mode-privacy.md`](../product/companion-mode-privacy.md).

Ambient voice has no plist override for its classifier contract. The local
Core ML runtime expects the app-bundled resource
`PaceWakeWordClassifier.mlmodelc` with exact labels `hey_pace` and `background`.
Missing or malformed assets fail closed before Speech.framework or the bounded
post-wake conversation can start.

Ambient voice has no plist override for its classifier contract. The local
Core ML runtime expects the app-bundled resource
`PaceWakeWordClassifier.mlmodelc` with exact labels `hey_pace` and `background`.
Missing or malformed assets fail closed before Speech.framework or the bounded
post-wake conversation can start.

Always-On Companion Mode adds no Info.plist enable switch. Mode, camera,
ambient-voice, screen, Mac-context, silent-card, and spoken-intervention choices
are explicit default-off UserDefaults managed in Settings → Companion. Companion
visual inference still honors `LocalVLMBaseURL` but validates it fail-closed as
loopback-only; it never uses the selected cloud conversational tier. See
[`companion-mode-privacy.md`](../product/companion-mode-privacy.md).

| Key | Default | Effect when changed |
|---|---|---|
| `UseLocalVLMForScreenContext` | `true` | `false` to skip the VLM call and send the raw transcript to the planner. |
| `ScreenAnalysisProvider` | `lmStudio` | `inProcess` / `coreML` / `mlx` select the in-process VLM placeholder and currently fall back to LM Studio HTTP until the runtime bridge is wired. |
| `LocalVLMBaseURL` | `http://localhost:1234/v1` | OpenAI-compatible root for the local VLM. Must be loopback (`localhost`, `127.0.0.0/8`, or `::1`); remote/LAN hosts are refused. |
| `LocalVLMModelIdentifier` | `ui-venus-1.5-2b` | Must match the model name loaded in LM Studio. 2B GUI specialist; the OCR layer fills in text fidelity the smaller model would miss. |
| `AlwaysRunLocalVLMRegardlessOfTranscript` | `false` | `true` → bypass the VLM-skip heuristic, run VLM on every turn |
| `LocalPlannerBaseURL` | `http://localhost:1234/v1` | OpenAI-compatible root for the local reasoner. Must be loopback (`localhost`, `127.0.0.0/8`, or `::1`); remote/LAN hosts are refused. |
| `LocalPlannerModelIdentifier` | `google/gemma-3-12b` | Must match the model name loaded in LM Studio for the planner role. Gemma-3-12B-it (qat-4bit, ~8 GB) is the eval-validated default (2026-06-12 drilldown: only ≤14B model beating the 4B baseline on clarify + out-of-scope + destructive-confirm); swap down to `qwen3-4b-instruct` for tighter RAM, or `qwen/qwen3-30b-a3b` for stronger multi-step reasoning on 48 GB machines. |
| `EnableActions` | `true` | `false` → parse action tags but do not execute local macOS actions. Keep `Approve Risky Actions` on when this is true. |
| `AgentMaxSteps` | `8` | Per-task ceiling for the plan-act-observe loop. `1` disables multi-step (loop exits after first response). |
| `TTSProvider` | `localServer` | `apple` → always use `AVSpeechSynthesizer` directly. `localServer` uses the Kokoro sidecar with automatic per-utterance Apple fallback. |
| `LocalTTSServerBaseURL` | `http://localhost:8880/v1` | Loopback-only OpenAI-compatible TTS root (mlx-audio / kokoro-fastapi). |
| `LocalTTSServerModel` | `mlx-community/Kokoro-82M-bf16` | Model identifier the sidecar expects (`kokoro` for kokoro-fastapi). |
| `LocalTTSServerVoice` | `af_heart` | Kokoro voice name. |
| `LocalTTSServerSpeed` | `1.2` | Playback speed multiplier (0.25–4.0). |
| `PushToTalkShortcut` | `controlOption` | One of `controlOption`, `shiftFunction`, `shiftControl`, `controlOptionSpace`, `shiftControlSpace`. Swap if another global dictation tool (e.g. Wispr Flow) is on the same key. |
| `TranscriptionProvider` | `whisperKit` | Shipped default. Resolves to WhisperKit when the runtime is linked and its model is on disk, otherwise falls back to Apple Speech (`appleSpeech` / `apple` forces Apple Speech). When the key is unset the factory auto-prefers WhisperKit if the model is already installed. |
| `PrewarmMailForDrafts` | `false` | Shipped default. Set to any value other than `false`/`0`/`no` (or remove the key) to non-activating-launch Mail at Pace startup, avoiding Mail's cold-launch tax for the streaming draft path. |
| `LocalRetrievalFileRootPaths` | empty | Optional comma/newline-separated explicit roots for file retrieval. With no roots, File retrieval records a skipped status and does not crawl the Mac. |
