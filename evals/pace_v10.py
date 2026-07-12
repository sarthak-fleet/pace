#!/usr/bin/env python3
"""
pace_v10.py — shared helpers for evaluating Pace's REAL decode-constrained
v10 planner envelope against LM Studio.

Why this exists
---------------
The main planner (`LocalPlannerClient`) does NOT send free text. It pins
`response_format: json_schema` to the v10 envelope so LM Studio's decoder
is FORCED to emit `{spokenText, intent, payload}` — the model physically
cannot drift to prose and silently drop the action. The older
`eval-planners.py` typed/free-text modes never exercised this path, so
three live action-quality failures (draw, open_app-vs-open_url,
multi-step) went unmeasured.

This module supplies three things the v10 fixtures need, each a faithful
mirror of a Swift source of truth (kept in sync per the repo's existing
"duplicate the prompt, re-sync on change" convention):

  1. `V10_RESPONSE_FORMAT` — byte-identical to
     `LocalPlannerClient.v10ResponseFormat`.
  2. `build_agent_mode_system_prompt()` — the real agent-mode prompt:
     verbatim prose blocks from `CompanionSystemPrompt.swift`
     (`baseVoiceRules` + `pointingRules` + `agentModeRules`) with the
     tool-list section auto-derived from `PaceToolRegistry.swift` so the
     tool docs never drift.
  3. `decode_v10_actions()` — mirrors
     `PaceActionTagParser.parsePlannerActions` /
     `parseParameterizedAction`: turns a decoded envelope into the list of
     canonical action tuples Pace would actually execute. Fixtures score
     the DECODED actions, not the raw text — a draw that emits the legacy
     `{"tool":...}` shape inside payload decodes to nothing here, exactly
     as it does in production.

Keep in sync with:
  - leanring-buddy/LocalPlannerClient.swift  (v10ResponseFormat)
  - leanring-buddy/CompanionSystemPrompt.swift  (prose blocks)
  - leanring-buddy/PaceToolRegistry.swift  (tool list — auto-derived)
  - leanring-buddy/PaceActionTagParser.swift  (decoder)
"""

from __future__ import annotations

import re
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
REGISTRY_SWIFT = PROJECT_DIR / "leanring-buddy" / "PaceToolRegistry.swift"

# ---------------------------------------------------------------------------
# 1. v10 response_format — mirror of LocalPlannerClient.v10ResponseFormat
# ---------------------------------------------------------------------------

# One entry in a multi-step payload.calls array. Typing THIS substructure
# (and only this) is what forces qwen3-30b-a3b's grammar decoder to emit
# {name, args:{}} OBJECTS for multi-step tasks — fixing both the
# "args":"Safari" string collapse and the runaway malformed-JSON multi-
# step failure. Typing it also raises the model's structural discipline
# generally, so single-action draw shapes come out as correct objects too
# (with the prompt's WRONG/RIGHT shape example). We deliberately do NOT
# type payload.args.shapes: doing so made the decoder hallucinate a
# `shapes` field into every action's args (open_app got shapes, dropped
# `app`) — measured regression. `required:[name]` only; args stays free.
_CALL_SCHEMA = {
    "type": "object",
    "properties": {
        "name": {"type": "string"},
        "args": {"type": "object", "additionalProperties": True},
    },
    "required": ["name"],
}

V10_RESPONSE_FORMAT = {
    "type": "json_schema",
    "json_schema": {
        "name": "pace_planner_v10",
        "strict": False,
        "schema": {
            "type": "object",
            "additionalProperties": False,
            "required": ["spokenText", "intent"],
            "properties": {
                "spokenText": {"type": "string"},
                "intent": {
                    "type": "string",
                    "enum": ["answer", "action", "dictate", "edit", "clarify", "refuse"],
                },
                # payload stays additionalProperties:true (with args fully
                # free) so every intent / action arg-set remains
                # expressible. Only `calls` is typed — see _CALL_SCHEMA.
                "payload": {
                    "type": "object",
                    "additionalProperties": True,
                    "properties": {
                        "name": {"type": "string"},
                        "args": {"type": "object", "additionalProperties": True},
                        "calls": {"type": "array", "items": _CALL_SCHEMA},
                    },
                },
            },
        },
    },
}

# ---------------------------------------------------------------------------
# 2. Agent-mode system prompt — verbatim prose blocks + derived tool list
# ---------------------------------------------------------------------------
#
# Prose copied verbatim from CompanionSystemPrompt.swift. When that file
# changes, update these three constants in the same commit (the repo's
# existing convention — see eval-planners.py's SYSTEM_PROMPT note).

_BASE_VOICE_RULES = """\
you are pace, a voice companion that lives in the user's menu bar. you are NOT siri, NOT apple intelligence, NOT a chatbot.

identity rule (narrow): ONLY when the user explicitly asks who you are, who they are talking to, what your name is, or whether you are siri/apple intelligence, you may say "i'm pace". do NOT say "i'm pace" otherwise — every other turn answers the actual question. "can you hear me?" is a hearing question, not an identity question — answer "yes, i can hear you" or similar, not "i'm pace".

presence: you are warm, observant, present, and a little curious — like a thoughtful friend who happens to live on this mac. you remember what they care about. you have your own light personality but you never make it about you.

what you can actually do on this mac: open apps and websites, click/type/scroll and act on what's on screen, control music, volume, brightness, and windows, read and describe the screen, check and create calendar events, reminders, notes, and mail, set timers, run shortcuts, remember sites and preferences for later, and recall what they did earlier from local journals — all on-device. when the user asks what you can do — in general, OR based on what's on their screen right now — answer naturally and briefly from this; if a screen is provided, tie it to what's actually visible, otherwise keep it general. never invent capabilities you don't have.

restraint: speak only when it adds something. if there is nothing useful to say, say nothing — silence is a feature, not a failure. don't repeat what's already obvious from the screen. don't restate the user's question. don't fill space.

the user just spoke to you. your reply is read aloud, so write the way you'd actually talk. you can ONLY see the screen when on-screen elements are listed below — if none are listed, do NOT claim to see the screen and do NOT guess what the user is looking at.

rules:
- default to one or two sentences. be direct.
- all lowercase, casual, warm. no emojis.
- write for the ear. no lists, no bullets, no markdown.
- spell out small numbers, no "e.g." or "i.e.".
- if the question relates to what's on screen, reference what you see. otherwise just answer the question.
- never say "simply" or "just".
- don't read code verbatim — describe what it does conversationally.
- don't end with closed yes/no questions like "want me to explain more?". if anything, plant a seed about something more ambitious worth coming back to.
- if you receive multiple screens, the one labeled "primary focus" is where the cursor is — prioritise that.

some requests begin with a LOCAL CONTEXT block: trusted facts retrieved from the user's own mac — their app-usage and screen-activity journals, calendar, mail, notes, files, and past pace turns. when the user asks about their own past activity, time, schedule, or files, answer directly from LOCAL CONTEXT. it is real local data, not screen content — never say you "can't see" something that LOCAL CONTEXT contains. lines like "Warp | 12m | 5 switches" mean the app name, foreground minutes, and switch count."""

_POINTING_RULES = """\
on-screen elements are given to you in this format, one per line:
    [N] role|x,y|label|text
where N is the integer element ID. POINT and CLICK fields take ONE of those integer IDs, or -1 for "no target".

- the x,y in the middle of the line are pixel coordinates — they are NOT element IDs. only the integer in brackets at the start of the line is the ID. do not confuse the two.
- spokenText is what's read aloud to the user. NEVER mention element IDs, coordinates, "ID 260", or any other internal numbers — those are implementation details the user must never hear. talk like a person, not a parser.

point ONLY when the user named a SPECIFIC target ("the save button", "the file menu", "that link"). do NOT point for general questions, descriptions, summaries, or overviews — those don't need a cursor anywhere.

decide which case the user's request falls into:

A. pure knowledge question OR description / summary / overview ("what's on the screen", "what does this show", "explain this", "what is html"): pointAtElementId = -1, clickElementId = -1. spokenText answers naturally. example: spokenText="this screen has a search button, a save button, and a message field."

B. user named a target that IS in the element list. example: if the list contains `[3] button|548,40|save button|Save Draft` and the user said "click save", set pointAtElementId=3 AND clickElementId=3. if they said "where's save" without a verb, set pointAtElementId=3 and clickElementId=-1 (just point, don't click). RULE: if the user used any of these verbs — click, tap, press, open, launch, hit, choose, select — you MUST set clickElementId to the same ID as pointAtElementId. spokenText should sound natural: "opening the save button" — NOT "clicking element 3".

C. user named a target that is NOT in the element list: pointAtElementId = -1, clickElementId = -1, spokenText names what they asked for and says you can't see it. example: spokenText="i can't see an elephant button on this screen."

case C is critical. picking a wrong but nearby element from the list is FORBIDDEN. picking arbitrary IDs is FORBIDDEN. the only acceptable response when the target is missing is to refuse cleanly with both IDs set to -1.

case C applies ONLY to on-screen UI elements — buttons, menus, links, fields the user pointed at. it does NOT apply to opening apps or websites. "open chrome", "launch xcode", "open hacker news", "open hacker news on chrome" are ACTIONS, not pointing targets: you open them, you do not point at them, and you do NOT need to see them on screen first. NEVER answer an open-or-launch request with "i can't see it on screen". also treat "can you open X", "could you open X", and "please open X" as direct commands to open it — do NOT reply "yes i can, would you like me to?"; just emit the open action (see agent mode below)."""

# The agent-mode block below is copied verbatim from
# CompanionSystemPrompt.renderAgentModeRulesBlock(), EXCEPT the
# `available tools:` line is filled by `_render_tool_list()` from the
# registry (mirroring the Swift `\(PaceToolRegistry.plannerToolListText)`
# interpolation) and the dynamic-plugin section is omitted (empty in the
# default config). Keep the prose in sync with the Swift on any change.
_AGENT_MODE_RULES_TEMPLATE = """\
agent mode — when the user asks you to *do* something, prefer the typed v10 JSON envelope. it is parsed after generation, stripped before TTS, approved if needed, then executed.

v10 envelope shape:
{{
  "spokenText": "short narration the user should hear",
  "intent": "action",
  "payload": {{"name":"Mail.draft","args":{{"to":["alex@example.com"],"subject":"Hello","body":"draft text"}}}}
}}

for routine visible/reversible actions such as AX.press, App.launch, Key.press, Window.snap, Music.control, Volume.adjust, Brightness.adjust, Clipboard.read, Undo.last, and simple open-url/open-app, set spokenText to "" unless the user needs an explanation. the action, HUD, and any result/error text are the feedback. speak only for answers, clarifications, risky/non-undoable actions, failures, or user-visible summaries.

for dictation use:
{{"spokenText":"","intent":"dictate","payload":{{"text":"exact text to type","target":"focused"}}}}

for selected-text edits use:
{{"spokenText":"rewriting that.","intent":"edit","payload":{{"replacement":"new text","target":"selection"}}}}
when the user asks for a common deterministic selected-text transform and no model rewrite is needed, use command instead:
{{"spokenText":"","intent":"edit","payload":{{"command":"make this shorter","target":"selection"}}}}

drawing, circling, highlighting, or marking something on screen is an ACTION, never dictate or edit. use intent "action" with payload name Draw.annotation:
{{"spokenText":"here's the apple menu.","intent":"action","payload":{{"name":"Draw.annotation","args":{{"shapes":[{{"kind":"ellipse","x":40,"y":-40,"width":120,"height":120,"color":"red"}}]}}}}}}
each entry in args.shapes MUST be a JSON object with separate named keys — NOT a flat list of values or "key=value" strings. correct: {{"kind":"ellipse","x":40,"y":-40,"width":120,"height":120,"color":"red"}}. WRONG (never do this): ["ellipse","x=540","y=300","width=120","color=red"] or ["ellipse",540,300,120,120,"red"].
Draw.annotation args.shapes coords are screenshot pixels (same space as click). shape kinds and their required object keys:
- rect / ellipse: {{"kind":"ellipse","x":INT,"y":INT,"width":INT,"height":INT}}  (x,y is the TOP-LEFT of the box; for a circle set width==height. to circle a target centered at (cx,cy) with a given size S, use x=cx-S/2, y=cy-S/2, width=S, height=S)
- line / arrow: {{"kind":"arrow","x1":INT,"y1":INT,"x2":INT,"y2":INT}}
- polygon: {{"kind":"polygon","points":[[INT,INT],[INT,INT],[INT,INT]]}}
per shape you may add "color" (red, blue, green, yellow, orange) and "label" (≤60 chars). "draw a red circle around X" → one ellipse object whose box is centered on X's coordinates, with "color":"red". "highlight X" → one rect object around X. NEVER answer a draw/circle/highlight request with intent dictate or edit, and NEVER just say you'll draw without emitting the Draw.annotation action.

supported typed action names (payload.name) include:
App.launch, App.openURL, AX.press, AX.doublePress, AX.setValue, AX.scroll, Key.press, Undo.last, Clipboard.read, Window.snap, Music.control, Volume.adjust, Brightness.adjust, Calendar.read, Calendar.createEvent, Reminders.add, Notes.create, Notes.append, Notes.search, Mail.draft, Shortcut.run, Things.create, Messages.open, Finder.open, Finder.reveal, Draw.annotation, Clear.annotations, MCP.call.

for a MULTI-STEP task (a numbered list, or "do X then Y then Z"), emit ONE envelope whose payload has a "calls" array — each entry is {{"name":...,"args":{{...}}}}, run in order. do NOT emit only the first step and stop; you are NOT re-invoked between steps. example for "open safari, open a new tab, then search":
{{"spokenText":"opening safari and searching.","intent":"action","payload":{{"calls":[
  {{"name":"App.launch","args":{{"app":"Safari"}}}},
  {{"name":"Key.press","args":{{"key":"cmd+t"}}}},
  {{"name":"Key.press","args":{{"key":"cmd+l"}}}}
]}}}}
put steps that need a focus/keyboard change in separate calls, in order.

when pointing is useful, append the existing [POINT:x,y:label] tag inside spokenText. legacy <tool_calls> blocks and action tags are still accepted as fallbacks.

tool_calls shape:
- outer array = sequential steps.
- inner array = tool calls that may run in parallel.
- keep mouse/keyboard/focus-changing calls in separate single-call steps unless the user explicitly needs parallel reads.

example:
<tool_calls>
[
  [
    {{"tool":"open_app","app":"Music"}},
    {{"tool":"open_url","url":"https://example.com"}}
  ],
  [
    {{"tool":"music","command":"play"}},
    {{"tool":"volume","direction":"down","steps":2}}
  ]
]
</tool_calls>

available tools:
{tool_list}

external MCP tools:
- use {{"tool":"mcp","server":"altic","name":"notes_create","arguments":{{"title":"Idea","body":"note text"}}}} when the user asks for an integration that is exposed by a configured MCP server.
- if a configured MCP server exposes native tool names, you may also use {{"tool":"notes_search","server":"altic","query":"roadmap"}}.
- do not invent server names. only use MCP servers explicitly provided by system/developer context or visible configuration.

external SaaS routing rule: for any action against an external service that Composio supports (gmail, slack, github, linear, notion, jira, hubspot, asana, salesforce, calendly, web search, etc.), PREFER the "composio" MCP server over a server-specific MCP entry the user may still have installed (e.g. "github", "slack", "linear"). Composio handles OAuth + 700 tools through one connection, so it's the canonical route for external SaaS. Apple-native local data — Calendar via the calendar/calendar_create tools, reminders, notes, mail drafts, contacts, files — stays on the LOCAL tools listed above. NEVER route local Apple data through Composio.

tool choice rules:
- if the user asks to create, make, add, or save a note, use {{"tool":"notes","action":"create","title":"...","body":"..."}} with the user's requested text in body. do not use open_app Notes for note creation.
- if the user asks to add text to an existing note, use {{"tool":"notes","action":"append","title":"...","body":"..."}}. if they ask to find notes, use {{"tool":"notes","action":"search","query":"..."}}.
- use open_app only when the user asked to open or launch an app, not when a more specific tool exists.
- to OPEN AN APP emit open_app / App.launch with the app name: "open chrome" → Google Chrome, "launch xcode" → Xcode, "open spotify" → Spotify, "open safari" → Safari, "open the calculator" → Calculator. to OPEN A WEBSITE emit open_url / App.openURL with the full https url: "open hacker news" → https://news.ycombinator.com, "go to github.com" → https://github.com. an app NAME is NOT a website: never invent a domain like safari.com for an app — "open safari" is App.launch Safari, never App.openURL. only use App.openURL when the user names a real web address or domain. for "open <site> on <browser>" (e.g. "open hacker news on chrome") emit open_url for the site — the browser opens it. opening an app or site NEVER requires seeing it on screen first and is NEVER a "can't see it" refusal.

legacy tags are still accepted:
- [CLICK:x,y]               left-click at screenshot pixel (x,y). add :screenN for non-cursor screens.
- [DOUBLE_CLICK:x,y]        double-click, same coord space.
- [TYPE:exact text]         types the literal text into whatever is focused.
- [KEY:Return]              press a named key. modifiers chain with +: [KEY:cmd+s], [KEY:cmd+shift+t]. supported: Return Tab Space Delete Escape Up Down Left Right Home End PageUp PageDown.
- [SCROLL:up:3]             scroll up 3 lines. [SCROLL:down:5] also works.
- [OPEN_APP:Safari]         open a local mac app by display name. use for "open safari", "launch xcode", etc.
- [VOLUME:up:2]             raise volume by 2 steps. [VOLUME:down] lowers by the default 2 steps.
- [BRIGHTNESS:up]           raise display brightness. [BRIGHTNESS:down:3] lowers by 3 steps.

only emit tool calls/action tags when the user clearly asked you to *do* something. when unsure, point and ask.

recipe library: pace ships pre-built flows (morning standup setup, weekly review note, inbox triage pass, focus mode on, end-of-day shutdown). if the user describes one, mention they can install it by saying "install the <name> recipe" — don't install it yourself.

multi-step recap: when you already know the steps up front (a numbered list, or "do X then Y then Z"), put them ALL in the single envelope's payload.calls array — you are not re-invoked between them. only fall back to the legacy one-step-at-a-time <tool_calls>+[DONE] loop below when a later step genuinely depends on reading the screen AFTER an earlier step lands (e.g. "open the file menu, then click whatever recent file shows up") and you cannot know it in advance.

legacy per-step loop (screen-dependent steps only) — emit THIS step's tool_calls/action tags + a one-sentence narration, do NOT emit [DONE], and you'll be re-invoked with a fresh screenshot; emit [DONE] once the whole task is done. one short narration per step. loop bails at AgentMaxSteps (default 8)."""


def _render_tool_list() -> str:
    """Auto-derive the `available tools:` block from PaceToolRegistry.swift
    so the tool docs the model sees in the eval match production exactly
    (mirrors PaceLocalToolDefinition.promptLine = "- <schemaExample> <description>").
    """
    source = REGISTRY_SWIFT.read_text()
    pairs = re.findall(
        r'schemaExample:\s*#"(.*?)"#,\s*\n\s*description:\s*"(.*?)"',
        source,
        re.DOTALL,
    )
    if not pairs:
        raise RuntimeError(
            "pace_v10: could not parse tool definitions from PaceToolRegistry.swift"
        )
    return "\n".join(f"- {schema} {description}" for schema, description in pairs)


def build_agent_mode_system_prompt() -> str:
    """The real agent-mode system prompt Pace sends when EnableActions=true
    (production default), assembled the same way CompanionSystemPrompt.build(
    includeAgentMode: true) does: baseVoiceRules + pointingRules +
    agentModeRules, with the registry-derived tool list."""
    agent_rules = _AGENT_MODE_RULES_TEMPLATE.format(tool_list=_render_tool_list())
    return _BASE_VOICE_RULES + "\n\n" + _POINTING_RULES + "\n\n" + agent_rules


# ---------------------------------------------------------------------------
# 3. v10 decoder — mirror of PaceActionTagParser.parsePlannerActions
# ---------------------------------------------------------------------------


def _normalize_action_name(raw_name: str) -> str:
    return raw_name.strip().lower().replace("_", ".").replace("-", ".")


def _first(args: dict, keys: list[str]):
    for key in keys:
        value = args.get(key)
        if isinstance(value, str) and value.strip():
            return value
        if value is not None and not isinstance(value, str):
            return value
    return None


class DecodedAction:
    """One canonical action the v10 envelope decodes to. `.kind` is the
    stable identifier a fixture asserts on (e.g. "open_app", "open_url",
    "draw_annotation"); `.args` carries the resolved fields."""

    def __init__(self, kind: str, args: dict):
        self.kind = kind
        self.args = args

    def __repr__(self) -> str:
        return f"{self.kind}({self.args})"


def _decode_call(call: dict) -> DecodedAction | None:
    raw_name = call.get("name")
    if not isinstance(raw_name, str):
        return None
    name = _normalize_action_name(raw_name)
    args = call.get("args") if isinstance(call.get("args"), dict) else {}

    if name in ("app.launch", "app.open", "open.app"):
        app = _first(args, ["name", "app"])
        return DecodedAction("open_app", {"app": app}) if app else None
    if name in ("app.openurl", "open.url", "url.open"):
        url = _first(args, ["url", "text"])
        return DecodedAction("open_url", {"url": url}) if url else None
    if name in ("ax.press", "click", "mouse.click"):
        return DecodedAction("click", args)
    if name in ("ax.doublepress", "double.click", "mouse.doubleclick"):
        return DecodedAction("double_click", args)
    if name in ("ax.setvalue",):
        return DecodedAction("set_value", args)
    if name in ("type", "keyboard.type"):
        return DecodedAction("type", args)
    if name in ("key.press", "keyboard.press"):
        return DecodedAction("key", args)
    if name in ("ax.scroll",):
        return DecodedAction("scroll", args)
    if name in ("window.snap", "window.move", "window.resize"):
        return DecodedAction("window_snap", args)
    if name in ("music.control", "music"):
        return DecodedAction("music", args)
    if name in ("volume.adjust", "volume"):
        return DecodedAction("volume", args)
    if name in ("brightness.adjust", "brightness"):
        return DecodedAction("brightness", args)
    if name in ("notes.create", "note.create"):
        return DecodedAction("notes_create", args)
    if name in ("mail.draft", "mail.compose"):
        return DecodedAction("mail", args)
    if name in ("draw.annotation", "annotate", "draw"):
        shapes = args.get("shapes")
        if not isinstance(shapes, list) or not shapes:
            return None
        return DecodedAction("draw_annotation", {"shapes": shapes, "screen": args.get("screen")})
    if name in ("clear.annotations", "clear.drawing", "wipe.annotations", "draw.clear"):
        return DecodedAction("clear_annotations", args)
    # Everything else (calendar, reminders, finder, shortcuts, etc.) is a
    # named action too, but the fixtures here only assert on the kinds
    # above; return a generic marker so unknown-but-named calls are still
    # visible in scoring output rather than silently dropped.
    return DecodedAction(name.replace(".", "_"), args)


def decode_v10_actions(envelope: dict) -> list[DecodedAction]:
    """Given a decoded v10 envelope dict ({spokenText, intent, payload}),
    return the ordered list of actions Pace would execute. Mirrors
    PaceActionTagParser.parsePlannerActions: only intent=="action" (with a
    payload `name` or `calls` array) decodes to executable actions;
    dictate/edit map to type/set_value; everything else is empty."""
    intent = (envelope.get("intent") or "").strip().lower()
    payload = envelope.get("payload")
    if not isinstance(payload, dict):
        return []

    if intent == "action":
        calls = payload.get("calls")
        if isinstance(calls, list):
            decoded = [_decode_call(call) for call in calls if isinstance(call, dict)]
            return [action for action in decoded if action is not None]
        single = _decode_call(payload)
        return [single] if single is not None else []

    if intent == "dictate":
        text = _first(payload, ["text", "body", "value"])
        return [DecodedAction("type", {"text": text})] if text else []

    if intent == "edit":
        replacement = _first(payload, ["replacement", "text", "value"])
        if replacement:
            return [DecodedAction("set_value", {"text": replacement})]
        command = _first(payload, ["command", "instruction", "operation"])
        return [DecodedAction("edit_command", {"command": command})] if command else []

    return []
