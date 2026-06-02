# Pace Roadmap

This is the current local roadmap. Pace has local tools today; it does not yet
ship MCP integrations.

## Priority 1: Approval And Safety

Status: in progress.

- Ask before executing local tool calls.
- Keep approval default-on.
- Add clearer risk labels for actions later: read-only, app/system mutation,
  input injection, and destructive.
- Keep `EnableActions` as the hard kill switch.

## Priority 2: Typed Tool Registry

Status: next highest ROI.

- Move tools out of prompt text and parser switch cases into a typed registry.
- Each tool should define name, schema, description, risk level, executor, and
  observation formatter.
- Generate planner prompt tool docs from the registry.
- Use the registry as the bridge point for future MCP-backed tools.

## Priority 3: Apple App Integrations

Status: planned.

- Calendar and Reminders exist as local EventKit tools.
- Next useful tools: Things, Notes, Mail, Finder, Shortcuts, and Messages.
- Prefer local macOS APIs or AppleScript only when the app does not expose a
  better native API.

## Priority 4: Watch Mode

Status: planned.

- `PaceScreenImageDiffer` exists as the screen-change primitive.
- Next step: a watch loop that samples the screen and only sends a frame when
  the image diff crosses a meaningful threshold.
- The first watch mode should be explicit: the user asks Pace to watch for a
  while, then Pace reports or assists based on changes.

## Priority 5: Local Intent Classifier

Status: planned.

- Add a tiny local classifier for routing turns into:
  - answer directly
  - read screen
  - execute tool
  - phone large model
- Keep the large planner for hard reasoning; use the classifier to avoid
  unnecessary VLM/planner calls.

## Priority 6: Tests

Status: ongoing.

- Keep parser and image-diff tests current.
- Add dry-run executor tests once the tool registry exists.
- Add Xcode-run smoke tests for approval prompts and action cancellation.
