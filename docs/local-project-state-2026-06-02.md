# Local Project State - 2026-06-02

This checkout is now treated as a local Pace project.

## Git State

- Active branch: `main`
- Remotes: none configured
- Published cleanup already done:
  - The accidental external draft PR is closed.
  - The exposed fork branches were deleted.
  - The old upstream/fork remotes were removed from this checkout.

Do not add a GitHub remote or push this project unless the target repository is
explicitly confirmed first.

## Current Product Work

The latest local `main` includes:

- Menu-bar/notch overlay as the primary always-visible Pace surface.
- Right-side voice animation in the notch during listening/processing/responding.
- Simpler left-side state icon in the notch.
- Cursor annotation preference and panel toggle.
- Grouped `<tool_calls>` parser where outer arrays are sequential and inner
  arrays are parallel.
- Local action tools for apps, URLs, Music, volume, brightness, Calendar, and
  Reminders.
- Screen image diffing primitive for watch-mode capture gating.
- Parser, TTS-stripping, and image-diff tests.
- Updated `AGENTS.md` architecture notes.

## Validation Already Performed

- `swiftc -parse -parse-as-library` over modified Swift files passed before the
  local merge.
- `plutil -lint leanring-buddy/Info.plist` passed.
- `jq empty evals/fixtures/action-mode-off.json evals/fixtures/qa-no-screen.json`
  passed.
- `git diff --check` passed.
- Xcode build via AppleScript succeeded before the local merge.

## Still Needs Manual Verification

- Run the Xcode test suite on a stable machine.
- Physically click the notch capsule and confirm the companion panel opens and
  dismisses correctly.
- Test the `Cursor Annotations` toggle in the app.
- Start LM Studio with the configured VLM and planner, then smoke-test:
  - screen-aware Q&A
  - open app
  - open URL
  - volume and brightness controls
  - Music controls
  - Calendar reads
  - Reminder creation
- Treat `EnableActions` carefully because enabled action mode can post real
  local input and system actions.
