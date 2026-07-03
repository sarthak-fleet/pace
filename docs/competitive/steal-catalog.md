# Steal Catalog — Famous Products Only

Patterns worth stealing from products the user actually knows about.
Sourced from deep code-level dives on FluidVoice, OpenSuperWhisper, and
Handy (June 2026), plus well-known commercial products (Wispr Flow,
Granola, Superwhisper, ChatGPT app, Apple Dictation).

Pace's product thesis:
**Performance-first local command interface for macOS. 100ms perceived
latency for simple commands. Subagents for parallel work. Jarvis-like
ambient intelligence. Skills as a first-class extensibility surface.
Conversation exists but is a second-class citizen.**

---

## 1. Subagents & Parallel Agent Orchestration

Pace today: single-threaded agent loop. One planner turn → one tool → observe → next turn.

### Shiro — Parallel sub-agents with atomic SQL checkout
- Each sub-agent gets a persona injection, depth guard, and token budget
- Atomic SQL checkout so sub-agents don't stomp each other's state
- Coordinator spawns N parallel workers, merges results
- **Why steal:** "Research X, Y, and Z simultaneously" becomes one turn instead of three sequential turns. Cuts wall-clock time for complex tasks.
- **Complexity:** Large — needs a sub-agent coordinator, state isolation, result merging

### ChatGPT App — Background task queue
- Queue a task → it runs headless → notifies on completion
- User keeps working in the foreground; agent doesn't block
- **Why steal:** We already have `PaceBackgroundAgentRunner` but it's single-task. The pattern to steal is the *queue + notify* UX — multiple background agents with progress and completion notifications.
- **Complexity:** Medium — extends existing `PaceBackgroundAgentRunner`

### Recommended for Pace
1. **Sub-agent coordinator** (from Shiro) — spawn N parallel planner turns with budgets, merge results. ✅ Done (Sprint 2.1)
2. **Background agent queue** (from ChatGPT App) — extend `PaceBackgroundAgentRunner` to a multi-slot queue with progress + completion notifications.
3. **Dual-agent pre-fetch** — background agent pre-computes likely-next-turn context while user is speaking. This is the 100ms enabler for complex turns.

---

## 2. Jarvis-Like Ambient Intelligence

Pace today: reactive only. User speaks → Pace responds. No ambient awareness.

### FluidVoice — AX tree first-tier screen context
- Reads the AX tree of the focused window first (5-50ms)
- Falls back to OCR (50-150ms) only when AX is insufficient
- Falls back to VLM (800ms-3s) only when AX + OCR are insufficient
- **Why steal:** This 3-tier ladder is already in Pace (`PaceAXScreenReader`). The pattern to steal is making it *always-on* — poll the AX tree every 2-3s so the planner already has context before the user speaks.
- **Complexity:** Medium — extends existing `PaceAXScreenReader` with a periodic poll

### Granola — Always-on meeting context
- Captures system audio continuously, transcribes in background
- Builds a live summary that's ready when the meeting ends
- **Why steal:** The "always-on capture + deferred summary" pattern applies to Pace's screen watch. Instead of on-demand screenshots, continuously build a lightweight context buffer.
- **Complexity:** Medium

### Recommended for Pace
1. **Always-on AX tree polling** (from FluidVoice) — every 2-3s, cache the frontmost app's AX tree so the planner has instant context. ✅ Partial (AX reader exists, needs always-on polling)
2. **Window/document title tracking** — know what the user is looking at without screenshots
3. **Clipboard change observer** — "paste what I just copied" without explicit context
4. **Prediction cards** (from Granola pattern) — Fn key shows context-aware suggestions based on ambient state

---

## 3. Performance — 100ms Perceived Latency

Pace today: ~1.5-3s end-to-end for a simple command. Target: 100ms perceived.

### FluidVoice — Streaming everything
- STT partials stream directly to the planner prompt builder
- Planner starts on the first stable partial, not the final transcript
- TTS starts speaking the first sentence before the planner finishes
- **Why steal:** This is the #1 latency win. Start the planner on a stable partial transcript, not the final. We already have speculative fast-action (Sprint 1.2); the next step is speculative *planner* start for non-fast-action commands.
- **Complexity:** Medium — needs a speculative planner task that can be cancelled if the final transcript differs

### Handy — VAD-segmented STT
- Silero VAD segments audio into speech chunks
- Each chunk is transcribed independently while the user is still talking
- Final transcript is the concatenation of all chunk transcripts
- **Why steal:** Process audio while talking, not after. Cuts STT latency from "wait for silence → transcribe all" to "transcribe as you go."
- **Complexity:** Large — needs VAD integration + chunked transcription + concatenation

### Wispr Flow — Speculative action execution
- Detects intent from partial transcripts
- Starts executing deterministic actions before the user finishes speaking
- Shows a "preparing..." state that transitions to "done" instantly
- **Why steal:** We already have this via `PaceFastActionCommandParser` + speculative fast-action (Sprint 1.2). The pattern to steal is the *UI feedback* — show "opening Music..." the moment the speculative action fires.
- **Complexity:** Small — UI change only

### Apple Dictation — Zero-latency dictation
- Apple's built-in dictation starts typing immediately on partial recognition
- No "submit" step — text flows directly into the focused field
- **Why steal:** For pure dictation mode (no planner), STT → Apple FM cleanup → paste should be zero-latency. No planner, no screenshot, no VLM.
- **Complexity:** Small — bypass planner for dictation-mode transcripts

### Recommended for Pace
1. **Speculative fast-action on stable partials** ✅ Done (Sprint 1.2)
2. **Lazy stream close** ✅ Done (Sprint 1.3) — engine stays warm 30s
3. **Speculative planner start** — start planner on stable partial for non-fast-action commands, cancel if final differs
4. **VAD-segmented STT** (from Handy) — process audio chunks while talking
5. **Dictation fast path** (from Apple Dictation) — STT → Apple FM cleanup → paste, no planner
6. **KV cache for system prompt prefix** — avoid re-encoding the ~2k-token system prompt every turn (Apple FM / MLX)
7. **Streaming TTS first-sentence** ✅ Done — `StreamingSentenceTTSPipeline` already renders sentence N+1 while N plays

---

## 4. Skills & Extensibility

Pace today: 3 bundled skills, `PaceSkillLoader` reads markdown skill files.

### ChatGPT App — GPT Store / custom GPTs
- Users create custom "GPTs" with system prompts + knowledge files
- Marketplace for sharing
- **Why steal:** Skills are Pace's version of custom GPTs. The pattern to steal is *skill composition* — skills that invoke tools and other skills.
- **Complexity:** Medium

### Superwhisper — Model-agnostic STT pipeline
- Supports Whisper, Parakeet, Distil-Whisper, etc.
- Post-processing pipeline with configurable steps
- **Why steal:** Pace's STT is Apple Speech first, WhisperKit scaffolded. The pattern is the *post-processing pipeline* — configurable steps for cleanup, punctuation, etc.
- **Complexity:** Small — Pace already has `PaceDictationPostProcessor`

### Recommended for Pace
1. **Skill composition** — skills can invoke tools and other skills
2. **Skill marketplace format** — versioned, portable skill files
3. **Three-tier extensibility** — Skills (markdown) / Plugins (Swift) / MCP (external)
4. **Expand bundled skill catalog** — 10-20 skills covering common workflows

---

## 5. UX & Personality

Pace today: notch capsule + floating panel. Functional but not delightful.

### Wispr Flow — Floating pill with streaming text
- Compact floating pill shows the transcript as you speak
- Transitions smoothly to the response as it streams
- **Why steal:** Pace already has this via `responseOverlayManager`. The pattern to steal is the *smoothness* — animated transitions between listening → thinking → responding states.
- **Complexity:** Small — polish work

### ChatGPT App — Conversation history sidebar
- Scrollable history of all turns
- Search and filter
- **Why steal:** Pace has `paceHistory` but no UI for browsing it. A history view is table stakes for a voice assistant.
- **Complexity:** Medium

### Recommended for Pace
1. **Multi-mode notch state machine** — distinct visual states for idle / listening / thinking / acting / error
2. **Step-based agent execution UI** — show each step as it executes (like ChatGPT's "Searching..." / "Reading page...")
3. **Streaming thinking tokens** — show `<think>` blocks in real-time
4. **Audio-reactive visualizer** — Jarvis-style waveform during listening
5. **Conversation history view** — browseable, searchable

---

## 6. Memory & RAG

Pace today: two-tier thread memory (verbatim K=4 + rolling summary). Episodic memory for durable facts.

### Granola — Per-meeting memory
- Each meeting gets its own memory document
- Meetings are searchable by topic, attendee, date
- **Why steal:** Pace's episodic memory is flat. Per-project or per-topic memory documents would make recall faster and more relevant.
- **Complexity:** Medium

### ChatGPT App — Persistent conversation memory
- Conversations persist across sessions
- "Memory" feature extracts and stores user facts
- **Why steal:** Pace already has `PaceThreadMemoryStore` for cross-session persistence and `PaceEpisodicFactExtractor` for durable facts. The pattern to steal is *proactive fact extraction* — automatically extract facts from every turn without asking.
- **Complexity:** Small — extends existing `PaceEpisodicFactExtractor`

### Recommended for Pace
1. **Per-project memory** — group episodic facts by project/context
2. **Proactive fact extraction** — extract facts from every turn automatically
3. **Local RAG with vector search** — semantic recall over episodic memory
4. **Work pattern extraction** — "you always open Slack after checking email"

---

## 7. Distribution

Pace today: manual build, no auto-update.

### Handy — Sparkle OTA updates
- Sparkle framework for auto-updates
- Signed and notarized DMG
- **Why steal:** Sparkle is the standard for macOS app auto-updates. Pace should ship with it.
- **Complexity:** Small — Sparkle integration

### Recommended for Pace
1. **Sparkle OTA updates** ✅ Already integrated
2. **Signed & notarized DMG** — for distribution
3. **Hardware-aware first-run** — detect M-series chip and configure models accordingly

---

## Sprint Plan

### Sprint 1 — Performance Foundation ✅ In Progress
- [x] Latency budget tracker (per-turn, per-stage)
- [x] Lazy stream close (30s engine warm)
- [x] Speculative fast-action on stable partials
- [x] Subagent coordinator (parallel task decomposition)
- [ ] Speculative planner start on stable partial
- [ ] VAD-segmented STT (process chunks while talking)
- [ ] Dictation fast path (STT → Apple FM cleanup → paste)
- [ ] KV cache for system prompt prefix

### Sprint 2 — Subagents & Background Agents
- [x] Sub-agent coordinator (Sprint 2.1)
- [ ] Background agent queue (multi-slot, progress, notify)
- [ ] Dual-agent pre-fetch (background pre-computes context)

### Sprint 3 — Ambient Intelligence
- [ ] Always-on AX tree polling (every 2-3s)
- [ ] Window/document title tracking
- [ ] Clipboard change observer
- [ ] Prediction cards (Fn key suggestions)

### Sprint 4 — Skills & Extensibility
- [ ] Expand bundled skill catalog (10-20 skills)
- [ ] Skill marketplace format (versioned, portable)
- [ ] Three-tier extensibility (Skills / Plugins / MCP)
- [ ] Skill composition (skills invoke tools and other skills)

### Sprint 5 — UX & Personality
- [ ] Multi-mode notch state machine
- [ ] Step-based agent execution UI
- [ ] Streaming thinking tokens
- [ ] Audio-reactive visualizer
- [ ] Conversation history view

### Sprint 6 — Memory & RAG
- [ ] Per-project memory
- [ ] Proactive fact extraction
- [ ] Local RAG with vector search
- [ ] Work pattern extraction

### Sprint 7 — Distribution
- [x] Sparkle OTA updates
- [ ] Signed & notarized DMG
- [ ] Hardware-aware first-run

---

## Sources

- **FluidVoice** (altic-dev/FluidVoice) — 3.6k stars, GPLv3, Swift — deep code dive, 59 patterns
- **OpenSuperWhisper** (stmarc/OpenSuperWhisper) — 1.3k stars, MIT, Swift — deep code dive, 22 patterns
- **Handy** (cjpais/Handy) — 25.1k stars, Tauri/Rust+React — deep code dive, 30 patterns
- **Wispr Flow** — commercial, popular voice dictation app
- **Granola** — commercial, AI meeting notes
- **Superwhisper** — commercial, Whisper-based dictation
- **ChatGPT App** — OpenAI's macOS app
- **Apple Dictation** — built-in macOS dictation
- **Shiro** — parallel sub-agents pattern
