# What Pace Can Do

Pace's abilities split into two layers: **tools** (discrete actions it executes)
and **capability classes** (whole behaviors that aren't single tools). The tools
are the canonical, drift-checked list; the classes are the surrounding system.

`docs/architecture.md` is the system map. This page is the user-facing "what can
I ask it" reference.

## Tools (the action catalog)

The 28 local tools live in `PaceToolRegistry.localTools` and are surfaced,
auto-generated, in **PaceMainWindow → Skills** (every tool has a name, an
example utterance, and a risk badge). Startup validation refuses to launch if
any tool lacks an example utterance, so the Skills tab can never go stale.

Grouped:

- **Screen control** — click, double-click, scroll, type text, press keys, snap window
- **Apps & web** — open app (`open_app`), open URL (`open_url`), open Messages, open/reveal in Finder
- **System** — volume, brightness, Music control, read clipboard, undo last edit
- **Productivity** — Calendar read/create, reminders, Apple Notes (create/append/search), Mail draft, Things to-do, run a Shortcut
- **Text editing** — dictate into the focused field, voice-edit selected text ("make this more concise")
- **Utility** — start a timer, download a file to ~/Downloads, record/run a saved flow, call an MCP tool

Multi-action commands ride in a single planner response (the v10 envelope's
`payload.calls`), not across multiple turns — see
[conversation-model.md](conversation-model.md) for why.

## Capability classes (beyond tools)

**Understanding the screen** — describe what's on screen, answer questions about
it, point the cursor at / click a named element. Backed by the local VLM +
OCR + AX tree (`PaceScreenContextService`).

**Knowledge & chitchat** — pure-knowledge questions ("what is HTTP?") route to a
fast text-only planner with no screen capture; chitchat gets a canned instant
reply. Routing is `PaceIntentClassifier`.

**Memory** — three distinct layers:
- *Durable preferences* — "remember my preferred browser" (`PaceLocalMemoryStore`)
- *Episodic memory* — lasting facts extracted from turns, surfaced across sessions
- *Conversational thread memory* — this-conversation coherence (see [conversation-model.md](conversation-model.md))

**Time / journal recall** — "what did I do today?" answers from the screen-watch
and app-usage journals (`PaceScreenWatchJournal`, `PaceAppUsageJournal`).

**Local retrieval (RAG)** — grounds answers in your own Calendar, Mail, Notes,
Contacts, Reminders, explicitly-chosen file folders, and past Pace turns
(`PaceLocalRetrieval`). Each source is permission-aware and individually
toggleable; nothing is crawled without an explicit root.

**Modes** — push-to-talk (the floor), always-listening / "hey pace" wake word,
barge-in (interrupt mid-speech by speaking, with echo rejection during TTS
playback), watch mode (observe the screen and emit change events), meeting mode
(capture system audio excluding Pace's own output), in-window chat (text instead
of voice).

**Always-On Companion Mode (implementation in progress; default OFF)** — the
local evidence/world-model and silence-first intervention-policy foundations are
implemented. Deterministic companion memory can promote typed evidence into
episodic, semantic, spatial, and routine records and render a dedicated local
retrieval source. Settings/menu-bar transparency and default-off lifecycle are
wired for existing ambient/watch sources; camera/ambient-voice adapters remain
behind injected boundaries and visibly degrade until hardware acceptance.
Silent cards, speech, and routine learning remain locked off.
See [companion-mode-privacy.md](companion-mode-privacy.md) for capture,
retention, local-only, correction, and threat-model details.

**Proactive surfaces (all default OFF)** — posture watch, focus-fatigue nudges,
calendar pre-meeting nudges, watch-mode observation nudges, the weekday morning
brief. Every one flows through `PaceRestraintGate` (stays silent during a
call / when you're actively typing).

**External integrations (MCP)** — anything a configured Model Context Protocol
server exposes. Configured via `~/.config/pace/mcp-servers.json` or the one-tap
catalog in Settings → MCP (filesystem, fetch, github, applescript, slack, linear).

**Automation (all default OFF)** — four opt-in automation surfaces in Settings →
General → Automation:
- *Meeting mode* — captures system audio (excluding Pace's own TTS) via SCStream
  so Pace can listen during calls. Voice: "start meeting mode" / "stop meeting
  mode" (`PaceMeetingModeController`).
- *Cron scheduling* — recurring planner tasks on a timer. Voice: "every 30
  minutes check my calendar" (`PaceCronScheduler`).
- *Dynamic plugins* — user-installed shell-command tools from
  `~/Library/Application Support/Pace/plugins/`, with planner-powered auto-repair
  of failed commands (`PaceDynamicToolRegistry`).
- *Background agents* — run headless planner turns in the background. Voice: "in
  the background, draft a reply to..." (`PaceBackgroundAgentRunner`).

**Skills** — `.skill.md` files in `Resources/skills/` define reusable multi-step
workflows that are parsed into planner prompts. Voice: "run the standup skill"
(`PaceSkillLoader`).

**Apple Foundation Models tool-calling** — when the planner tier is Apple FM,
multi-step tool calls are serialized from the typed `PaceFMTurnResponse.toolCalls`
array into `<tool_calls>` JSON blocks that the existing action parser executes.

**Telemetry** — E2E turn latency, STT latency, VLM latency, and token throughput
are recorded per turn via `PaceTelemetryLog` and visible in the benchmark script
`scripts/benchmark_ttfsw.sh`.

**Entry points** — voice (PTT/wake word), text (chat), and `pace://` deeplinks
(`listen`, `chat`, `watch`, `panel`) from Raycast / Shortcuts.

## What stays on-device

Everything above is local. The only off-device action is `download_file`, which
fetches a user-named http(s) URL into ~/Downloads on explicit command — and the
opt-in cloud-bridge / Direct-API planner tiers, which are consent-gated and
default-off. See `docs/architecture.md` for the privacy posture.

## How a command is routed (fastest → slowest)

1. **Fast path** (`PaceFastActionCommandParser`) — deterministic, no model, no
   screen: open app/URL/known site, media, volume, brightness, undo, window
   snap, common key shortcuts. Sub-200ms.
2. **Automation parsers** — deterministic, no model: cron scheduling ("every 30
   minutes..."), background agents ("in the background..."), meeting mode
   ("start meeting mode"), skills ("run the standup skill"). Routes to the
   relevant module before the planner.
3. **Text-only planner** — pure-knowledge answers, no screen capture.
4. **Screen pipeline** — VLM + planner, for commands that genuinely need to see
   or act on the screen. The VLM is skipped for launch/navigate verbs that don't
   reference an on-screen element (see `PaceTagParsers.transcriptIsLikelyScreenReferential`).

The Settings → Debug tab shows, per turn, which lane handled it, the latency,
the raw planner output, the parsed tool calls, and the dispatch outcome.
