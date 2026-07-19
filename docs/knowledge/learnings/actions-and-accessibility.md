# Actions and accessibility

How Pace turns a planner response into a safe, reversible action on the user's
Mac — the tool catalog, the risk/approval gate, AX-vs-CGEvent targeting, the
agent loop that drives multi-step tasks, and the external entry points
(App Intents, deeplinks) that feed the same command pipeline.

## Tool registry (single source of truth)
- What: A typed catalog (`PaceLocalToolDefinition`) of every local tool — canonical name, aliases, JSON schema example, risk level, execution/observation summaries, and an example voice utterance.
- Why here: Prompt docs, alias resolution, and startup validation all read from one array instead of three hand-maintained lists that could silently drift.
- Where: `PaceToolRegistry.swift` — `PaceLocalToolDefinition`, `PaceToolRegistry.localTools`, `PaceToolRegistry.plannerToolListText` (rendered into `CompanionSystemPrompt.swift`), `PaceToolRegistry.validateForAppStartup()`
- Source: internal — no external spec

## Risk-level policy
- What: Every tool declares one of five risk levels — `readOnly`, `appOrSystemMutation`, `inputInjection`, `destructive`, `externalIntegration`.
- Why here: The risk level (not the tool name) decides whether an action needs an approval popup — routine local actions (click, scroll, app/URL open, media, volume, clipboard read) auto-run, while higher-risk non-undoable or external actions stop for explicit user approval.
- Where: `PaceToolRegistry.swift` — `PaceToolRiskLevel`
- Source: internal — no external spec

## Approval gate (allow/cancel contract)
- What: A pure, testable allow/cancel decision layer that sits in front of the actual `NSAlert` UI, so the approval contract can be unit-tested without controlling the user's Mac.
- Why here: `PaceActionApprovalPolicy.requiresExplicitApproval` decides *whether* to ask; the alert (built in `CompanionManager+PostureWatch.swift`) adds "Cancel" as the first button before "Allow Once", so the default/highlighted action on Enter or accidental dismiss is always Cancel, never execution.
- Where: `PaceActionApproval.swift` — `PaceActionApprovalPolicy`, `PaceActionApprovalDecision`; alert construction in `CompanionManager+PostureWatch.swift` — `requestUserApprovalForActionPlan(_:preflightIssues:smokeAutoCancelAfter:)`
- Source: internal — no external spec

## AX-tree targeting vs CGEvent fallback
- What: Pace tries to press UI elements through the accessibility tree (role-based, coordinate-independent) before ever falling back to a synthesized CGEvent coordinate click.
- Why here: AX press lands semantically (like a real user activating a control) and survives small layout shifts; CGEvent is the fallback of last resort when no pressable AX ancestor is found or the press action fails. The AX framework itself is covered once in [`new-things.md`](new-things.md) — this entry is Pace's specific strategy layered on top.
- Where: `PaceAXTargeter.swift` — `PaceAXTargeter.tryClickViaAccessibility(atGlobalCGPoint:)`, `climbToPressableAncestor(startingAt:)`
- Source: internal — no external spec (AX API itself: see `new-things.md`)

## Undo mutation log (reversibility trust surface)
- What: A session-local stack of `PaceActionMutation` entries — currently `.axValue(element:oldValue:summary:)` — recorded every time Pace performs a reversible AX set-value edit.
- Why here: The AX API has no built-in undo primitive, so Pace builds its own: `Undo.last` / "undo that" pops the most recent entry off `mutationLog` and restores the prior value. This is the mechanism behind the 5-second floating undo banner described in `CLAUDE.md`'s trust-surfaces section.
- Where: `PaceActionExecutor.swift` — `mutationLog: [PaceActionMutation]`; `PaceActionTagParserTypes.swift` — `PaceActionMutation`; `PaceActionExecutor+Keyboard.swift` — `undoLastMutation()`
- Source: internal — no external spec

## Plan-act-observe agent loop
- What: A multi-step loop that re-screenshots, re-runs the local VLM (heuristic permitting), re-invokes the planner, executes any tool calls/action tags, and feeds the results back as observations for the next step.
- Why here: Turns a single planner call into an agent that can complete multi-step screen tasks — the loop only stops when the planner emits `[DONE]`, emits no tool calls/action tags, or hits `AgentMaxSteps`. Each iteration re-grounds in the current screen state rather than assuming the previous step's action landed as predicted.
- Where: `CompanionManager+AgentLoop.swift` — `sendTranscriptToPlannerWithScreenshot(transcript:)`, `sendTranscriptToPlannerWithScreenshotAsync(transcript:)`, `maxAgentStepCount` (bounded by `researchTurnMaxAgentSteps`)
- Source: internal — no external spec

## AgentMaxSteps (loop bound)
- What: An Info.plist-configurable cap (default `"8"`, clamped to `[1, 30]`) on how many plan-act-observe iterations a single turn can run.
- Why here: Prevents a stuck or looping planner from running forever; the system prompt tells the model to explain what got stuck if it can't finish within budget.
- Where: `Info.plist` — `AgentMaxSteps` key; `PaceTagParsers.swift` — the clamped parse of the Info.plist value; referenced in `CompanionSystemPrompt.swift`
- Source: internal — no external spec

## Click candidate ranking and verification
- What: When a click target resolves to more than one plausible on-screen location, Pace ranks all candidates, tries up to three top-ranked ones in order, and verifies each attempt by diffing UI state before/after.
- Why here: Screen coordinates from a VLM/planner are noisy; ranking by confidence (then by cursor distance and focused-window membership) plus a state-change check catches a click that "succeeded" syntactically but hit nothing.
- Where: `PaceActionExecutor+Mouse.swift` — `clickBestCandidate(_:screenCaptures:)`; `PaceActionExecutor.swift` — `PaceClickCandidateSet.orderedCandidates(currentGlobalCursorPoint:focusedWindowGlobalFrame:screenCaptures:coordinateConverter:)`, `PaceClickStateSnapshot`
- Source: internal — no external spec

## download_file tool (Pace's one intentional network touch)
- What: A user-commanded tool that fetches a validated http(s) URL into `~/Downloads`, sanitizing the filename and appending Finder-style " 2", " 3" collision suffixes.
- Why here: The single scoped exception to Pace's fully-on-device architecture — approval-gated, fetch-only, sends nothing off the Mac. URL validation rejects non-http(s) schemes, loopback hosts, and embedded credentials (a phishing-shaped pattern).
- Where: `PaceFileDownload.swift` — `PaceFileDownloadURLValidator.validatedDownloadURL(from:)`, `PaceDownloadFilenameSanitizer.sanitizedFilename(suggestedFilename:downloadURL:)`, `PaceDownloadFilenameSanitizer.collisionFreeFilename(_:existingFilenames:)`
- Source: internal — no external spec

## App Intents (Shortcuts/Siri/Spotlight/Focus entry points)
- What: Apple's declarative framework for exposing app actions to Shortcuts, Siri, Spotlight, and Focus filters as first-class system objects (`AppIntent`, `AppShortcutsProvider`).
- Why here: `PaceConversationIntent`, `PaceStartListeningIntent`, `PaceShowPanelIntent`, `PaceSetWatchModeIntent`, and `PaceTranscribeAudioFileIntent` all route into the exact same `executePaceExternalCommand` entry point as `pace://` deeplinks — same 500-char chat cap, same behavior regardless of which surface triggered it.
- Where: `PaceAppIntents.swift` — `PaceConversationIntent`, `PaceAppShortcuts`
- Source: https://developer.apple.com/documentation/appintents

## Deeplinks (`pace://`)
- What: A pure, dependency-free parser for the `pace://` URL scheme (`listen`, `chat?text=`, `watch?enabled=`, `panel`) used by external launchers like Raycast and Shortcuts.
- Why here: Reject-on-ambiguity by design — unknown hosts, extra path segments, malformed `enabled` values, and over-cap chat text (500 chars) all return `nil` rather than guessing, so a deeplink can never do more than the user's own voice could.
- Where: `PaceDeepLinkParser.swift` — `PaceDeepLinkParser.parse(_:)`, `PaceDeepLinkCommand`, `maximumChatTextCharacterCount`
- Source: internal — no external spec

## See also
[`README.md`](README.md)
