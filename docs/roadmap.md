# Pace Roadmap

This is the current local roadmap. Pace has local tools today; it does not yet
ship MCP integrations.

## Priority 1: Approval And Safety

Status: implemented and runtime-smoked.

- Ask before executing local tool calls.
- Keep approval default-on.
- Add clearer risk labels for actions: read-only, app/system mutation,
  input injection, and destructive.
- Keep `EnableActions` as the hard kill switch.
- Approval popup copy and allow/cancel policy are covered by pure unit tests;
  `scripts/smoke-runtime-hooks.sh` verifies the real popup cancellation path in
  a running app launched with gated smoke hooks.

## Priority 2: Typed Tool Registry

Status: implemented.

- Move tools out of prompt text and parser switch cases into a typed registry.
- Each tool should define name, schema, description, risk level, executor, and
  observation formatter.
- Generate planner prompt tool docs from the registry.
- Use the registry as the bridge point for future MCP-backed tools.

## Priority 3: Apple App Integrations

Status: implemented for first local tool pass; Notes expanded; dry-run executor coverage passing.

- Calendar and Reminders exist as local EventKit tools.
- Things, Notes, Mail drafts, Finder, Shortcuts, and Messages opening are
  registered as local tools.
- Notes supports create, append, and search actions through the `notes` tool.
- Prefer local macOS APIs or AppleScript only when the app does not expose a
  better native API.
- Xcode dry-run executor tests cover non-mutating observations for URL, Music,
  Calendar, Reminders, Finder, Notes, Mail, Things, Shortcuts, and Messages.

## Priority 4: Watch Mode

Status: implemented with panel, explicit voice triggers, and v2 event categories.

- `PaceScreenImageDiffer` exists as the screen-change primitive.
- `PaceScreenWatchModeController` samples the screen and emits events only when
  the image diff crosses a meaningful threshold.
- The first watch mode is explicit through the `Watch Mode` panel toggle. Pace
  reports meaningful screen changes while it is on.
- Watch events are classified as major screen changes, content updates, or
  focused-region changes before UI/speech feedback.
- Voice commands such as "watch my screen" and "stop watching" toggle watch
  mode before the planner/VLM pipeline.

## Priority 5: Local Intent Classifier

Status: implemented as a rule-based scaffold.

- Add a tiny local classifier for routing turns into:
  - answer directly
  - read screen
  - execute tool
  - phone large model
- Pure-knowledge turns now use a text-only planner path to avoid unnecessary
  screen capture/VLM work.
- Phone-large-model is classified and logged, but there is intentionally no
  cloud model transport wired yet.

## Priority 6: Tests

Status: implemented for unit/build and runtime-smoke coverage.

- Keep parser and image-diff tests current.
- Parser tests cover registry aliases and Apple app tool parsing.
- Image-diff tests cover watch-mode change throttling.
- Intent tests cover the route mapping.
- Watch-mode command tests cover explicit start/stop routing.
- Approval tests cover default-on request creation and cancellation blocking
  action execution.
- Dry-run executor tests cover local tool observations without changing local
  apps or system state.
- Latest Xcode test run passed 129 tests after local test-target signing cleanup
  and local action-result/preflight/memory/watch coverage.
- Runtime diagnostic passed with both LM Studio models resident, no model
  thrash, VLM JSON health ok, synthetic VLM->planner turn under 3.5s, and
  planner eval 19/19.
- Runtime smoke hooks passed for panel show/hide, cursor annotation off/on
  state, and approval-popup cancellation.

## Priority 7: Permission Preflight

Status: implemented, pending live panel review.

- Core setup now includes Microphone, Speech Recognition, Accessibility,
  Screen Recording, and Screen Content.
- The panel shows local-tool preflight rows for Automation, Calendar, and
  Reminders so app-control failures are visible before tool execution.
- Automation stays per-target in macOS; Pace opens the Automation settings
  pane and still relies on the native first-use prompt for Notes/Music/etc.

## Priority 8: Action Result Center

Status: implemented, pending live panel review.

- CompanionManager records planned, completed, failed, denied, and skipped
  local tool runs.
- The panel shows the latest action results with compact status/detail rows.
- Tool observations are still fed back to the planner and spoken as fallback
  user feedback when the planner ends silently.

## Priority 9: Local Memory

Status: implemented for first preference pass.

- `PaceLocalMemoryStore` persists lightweight local preferences in UserDefaults.
- Voice commands can remember/forget preferred browser.
- `open_url` honors the preferred browser when present.
- The panel shows a read-only local memory summary.

## Priority 10: Voice Quality

Status: implemented for Apple voice quality preflight.

- `PaceTTSVoiceResolver` ensures Premium/Enhanced Apple voices override compact
  fallback configuration.
- The panel shows the active voice and whether an upgrade is recommended.
- A true non-Apple local neural TTS runtime remains a future optional backend.

## Priority 11: MCP Integration Substrate

Status: first bridge implemented, pending live server install.

- Added a generic stdio MCP client for `initialize` + `tools/call`.
- Added `mcp` parsed actions so the planner can call configured OSS servers
  without Pace hand-building each integration.
- Added config discovery from `~/.config/pace/mcp-servers.json` or
  `~/.pace/mcp-servers.json`, accepting either `mcpServers` or `servers`.
- Added preflight for missing MCP server names before the approval popup.
- Added `mcp-servers.example.json` for Altic/AirMCP-style setup.
- Added a normal macOS settings window because MCP/config/permissions no longer
  fit cleanly in the notch panel. The notch panel remains the quick surface.

Next live step: install one OSS server, preferably Altic MCP first because it
covers Notes, Reminders, Calendar, Finder/files, clipboard, browsers, screen
capture, app opening, volume, and brightness with a narrower surface than the
largest Apple-ecosystem servers.

---

# Next Up (handoff for the next agent)

The priorities above are implemented. The items below are the live unstarted /
in-flight threads. Each is written to be picked up cold — no prior session
context needed.

## Priority 12: Set-of-Mark Click Recovery — SHIP VERDICT PENDING

Status: built + unit-tested + live on the local dev Mac (branch
`feature/set-of-mark-click-recovery`, commit `ccd2bbf`). NOT on `main`, NOT
released. Awaiting a real-world click-miss test before shipping.

- What: when a planner click misses (all candidates fail with no observable
  state change), render numbered marks on the same screenshot, round-trip the
  MARKED image through the local VLM ("which mark is `<target>`?"), and re-click
  the chosen element's bbox center. Full design in PRD
  `docs/prds/set-of-mark-click-recovery.md`.
- Why: gives the previously-dead `PaceSetOfMarkRenderer` a real consumer; turns
  wasted clicks into self-correction; generates the click-failure data the
  UI-TARS direction below would need.
- Files: `PaceSetOfMarkClickRecovery.swift` (pure coordinator),
  `LocalVLMClient.groundMarkedClickTarget`, `PaceActionExecutor` (the all-fail
  recovery signal + `executeRecoveredClick`), `CompanionManager
  .attemptSetOfMarkClickRecovery`, pref `enableSetOfMarkClickRecovery`
  (default on, only fires on a miss).
- Unverified: the VLM's actual mark-reading hit-rate. Logic is tested; live
  quality is not. Watch Console (`com.pace.app`) for `🎯 Set-of-Mark recovery
  succeeded`.
- Next step: live-test on a real miss. If the VLM re-grounds reliably → PR to
  `main` → release v0.3.17. If the hit-rate disappoints → iterate the grounding
  prompt in `LocalVLMClient.groundMarkedClickTarget` before shipping.

## Priority 12a: Automation Modules — IMPLEMENTED + WIRED

Status: implemented, wired into the app, tested (1154 tests pass), merged to
`main` (PR #54, commit `d236148`).

Seven modules that were previously standalone stubs are now fully integrated:

- **Barge-in echo rejection** — `PaceBargeInVAD` suppresses echo during TTS
  playback with a raised threshold and echo suppression window. Wired into
  `CompanionManager+PrivateBindings` to activate/deactivate with TTS state.
- **Meeting mode** — `PaceSystemAudioCapture` / `PaceMeetingModeController`
  captures system audio via SCStream (excluding Pace's own TTS). Voice: "start
  meeting mode" / "stop meeting mode". Settings toggle in General → Automation.
  Resumes on launch if preference is on. **Note:** v1 only publishes RMS levels
  for VAD — no recording, transcription, or notes. The full on-device
  meeting-notes assembly (two-track capture → turn segmentation → transcription
  → structured notes → retrieval) is scoped in
  [`docs/prds/on-device-meeting-notes.md`](prds/on-device-meeting-notes.md).
- **Apple FM tool-calling** — `PaceFMTurnResponse.toolCalls` array is serialized
  via `serializedToolCallsJSON()` in `AppleFoundationModelsPlannerClient` into
  `<tool_calls>` JSON blocks. Previously the field was silently dropped.
- **Background agents** — `PaceBackgroundAgentRunner` runs headless planner
  turns in the background. Voice: "in the background, draft a reply...".
  CompanionManager wires `executePlannerTurn` + `speakResult` callbacks.
- **SKILL.md system** — `PaceSkillLoader` parses `.skill.md` files from
  `Resources/skills/` into planner prompts. Voice: "run the standup skill".
  Sample skill: `resources/skills/standup-notes.skill.md`.
- **Cron scheduling** — `PaceCronScheduler` runs recurring planner tasks on
  timers. Voice: "every 30 minutes check my calendar". Settings toggle in
  General → Automation. CompanionManager wires `executeTaskCallback`.
- **Self-modifying plugins** — `PaceDynamicToolRegistry` loads user-installed
  shell-command plugins from `~/Library/Application Support/Pace/plugins/`.
  Plugin tool docs are injected into `CompanionSystemPrompt` so the planner
  sees them. Auto-repair callback asks the planner to fix failed commands.
  Settings toggle in General → Automation.
- **Telemetry** — `PaceTelemetryLog` records E2E, STT, VLM, and token
  throughput metrics from the actual agent loop. `benchmark_ttfsw.sh` updated.

All modules are voice-command-routable via `PaceAutomationCommandParser` in the
pre-planner dispatch (after named-destination fast path, before chitchat
classifier). All default OFF except barge-in echo rejection (always on).

## Priority 12b: Always-On Companion Mode — IN PROGRESS

- Completed foundation: typed observations, bounded atomic evidence storage,
  derived current-state and time-aware queries, an event-driven perception
  adapter/coordinator with per-source backpressure, explicit runtime states,
  deterministic companion-memory promotion/retrieval/clear integration,
  default-off source/output preferences, and silence-first intervention policy.
- Concrete but not app-wired adapters: separately permissioned, low-rate and
  motion-gated camera capture; wake-gated bounded ambient-voice sessions;
  ephemeral diarization; non-identifying person and user-taught object records.
- App wiring now starts/stops the default-off observe-only runtime and exposes
  Settings plus menu-bar state/active-source indicators. Existing ambient/watch
  adapters can run; camera/voice remain visibly degraded until real hardware
  clients and manual acceptance are complete. Silent cards and speech remain off.
- Privacy/resource threat model and deterministic denial, redaction, buffer,
  device-loss, false-wake/continuity, source-clear, and degradation fixtures are
  in place. See `docs/companion-mode-privacy.md`.
- Remaining: real camera/audio hardware clients and observe-only dogfood;
  measured accuracy/resource/sleep-wake/permission acceptance; then separately
  gated cards, speech, and routine learning; full Xcode tests and manual smokes.
- Source of truth: OpenSpec change `always-on-companion-mode`.

## Priority 13: Premium Conversational UI

Status: unstarted. Biggest remaining quality lever toward "best local tool."

- What: make the primary surface a clean Claude-Desktop-style chat panel (text
  input + transcript + inline tool-use chips + gear → Settings), with the
  mascot on a top-right perch; add wake/listen/think/speak animation polish.
  Keep the notch code behind a flag — do NOT delete it.
- Why: today's primary surface is a dense ~15-section dashboard; the product
  vision is a focused chat surface.
- Scaffolding that exists: `PaceConversationsView`, `PaceMainWindow`,
  `PaceChatSession`.
- IMPORTANT for the next agent: this needs HUMAN visual review on each rebuild —
  an agent can't see the UI render, so treat it as iterative back-and-forth with
  the user, not fire-and-forget. Don't claim UI correctness from a green build.

## Priority 14: One-Tap obscura (headless browser) in the MCP catalog

Status: unstarted. Drivable solo (no visual judgment needed).

- Context: the bundled six-server catalog (`PaceMCPServerCatalog`, Settings →
  MCP) already does one-tap npx/uvx installs. obscura is validated end-to-end
  via a hand-edited `~/.config/pace/mcp-servers.json` but is NOT in the catalog.
- What: add obscura to `PaceMCPServerCatalog` plus a binary-download install
  path (obscura ships as a prebuilt per-arch binary, not npx/uvx) so any user
  gets the headless programmable browser.
- Why: obscura (Rust + V8, CDP + MCP, ~35 tools) renders JS pages; productizing
  it lifts it beyond the current hand-config.
- Consideration: downloading + running a third-party binary at install is a
  trust surface on a privacy-first product — confirm the install/consent UX
  before shipping.

## Deferred (gated, do NOT start blind): UI-TARS / GUI-grounding VLM

A purpose-built grounding VLM (UI-TARS-class) that makes the click decision
directly from the (optionally marked) screenshot is the "real" Set-of-Mark
architecture. Gated on click-failure data — which Priority 12's recovery now
logs. Let that data accumulate first; a larger TEXT planner (e.g. qwen3-30b-a3b)
does NOT consume the marked image, so it would not benefit from this.
