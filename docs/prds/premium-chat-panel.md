# PRD: Premium chat panel — Pace's primary surface

Status: phase 1 in progress
Owner vision: Claude-Desktop-style chat panel as THE primary surface;
mascot perch top-right; notch code kept behind a flag (never deleted).

## Problem

Pace's current primary surface is the notch capsule + a floating panel
that has grown into a dashboard (many stacked sections) plus a
15-tab-ish settings window. Power flows through voice, but the visual
anchor reads as a debug HUD, not a companion. World-class macOS
assistants (Claude Desktop, ChatGPT desktop, Raycast AI) share one
shape: a clean conversation column — input at the bottom, transcript
above, tool activity inline, everything else demoted behind a gear.

## What ships (phase 1)

A new `PaceChatPanelView` that becomes the DEFAULT panel content:

1. **Transcript column** — user + assistant turns, newest at bottom,
   auto-scroll. Reuses the existing conversation state that already
   feeds `recordConversationTurn` / thread memory; NO new store.
2. **Inline tool activity** — when a turn executes tools, a compact
   row under the assistant bubble: tool name + one-line result state
   (running / done / failed), driven by the existing
   `PaceActionExecutionObservation` flow. No new execution paths.
3. **Input field** — the existing chat input (same submit path:
   `submitChatTranscriptFromChatSession`), permanently docked at the
   bottom. PTT keeps working exactly as today; a spoken turn appears
   in the transcript like a typed one.
4. **Header strip** — mic/live state on the left (reuses voice state),
   gear on the right opening the existing `PaceSettingsWindow`.
   Nothing else. All current panel sections (watch mode, morning
   brief, meeting card, flows…) move behind either the transcript
   (as inline cards when they fire) or the settings window.
5. **Meeting + morning-brief cards** render as inline transcript
   cards when they occur (they are events in a conversation, not
   permanent dashboard fixtures).

## Feature flag

`PaceUserPreferencesStore` boolean `useChatPanelAsPrimarySurface`,
default OFF in phase 1 (flips ON in phase 2 after real use). The
notch capsule stays the summoning affordance either way. The old
panel body remains compiled and selectable — per the standing rule,
notch/dashboard code is flagged off, never deleted.

## Non-goals (phase 1)

- No mascot perch yet (phase 2; needs its own design pass).
- No message editing, no history browsing beyond the live thread.
- No visual redesign of Settings.
- No changes to planner/TTS/executor behavior of any kind.

## Design language

- macOS-native: system materials (`.ultraThinMaterial`), SF Symbols,
  vibrancy; respect Reduce Motion.
- Bubbles: user right-aligned tinted, assistant left-aligned neutral;
  generous line height; max width ~65ch.
- One accent color drawn from the existing capsule styling. No new
  colors, no gradients beyond what the capsule already uses.
- Pointer cursor on every interactive element (repo convention).

## Acceptance

- Flag OFF → byte-identical current behavior.
- Flag ON → panel shows transcript/input; voice turn and typed turn
  both append correctly; tool turns show the inline activity row; gear
  opens Settings; outside-click dismissal unchanged.
- All existing tests stay green; new unit tests cover the transcript
  view-model mapping (turn → row model, tool observation → activity
  row), which must be a pure, isolation-free type.

## Phase 2 (separate PR)

Mascot perch top-right, flag default ON, transcript persistence UI
(browse past sessions from thread-memory JSON), polish pass with
screenshots against Claude Desktop for reference.
