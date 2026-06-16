# Set-of-Mark click recovery

**Status:** wired (Phase A — miss-case recovery)
**One-line:** When a planner-chosen click misses, render numbered marks on the
screenshot and let the local VLM visually pick the right mark, then re-click —
turning a dead click into a self-correction.

## Problem

Pace's click path is **text-grounded**: the VLM detects elements and emits a
text element map; the text planner (`LocalPlannerClient`, image-blind) reads
that numbered list and picks an element; the executor clicks its coordinates.
This misses when the planner picks the wrong element, the coordinates are stale,
or the label is ambiguous. On a miss the turn just reports failure and re-plans.

Separately, `PaceSetOfMarkRenderer` (draws numbered marks on a JPEG) shipped as
**dead code** — Set-of-Mark is a *vision-grounded* technique (a VLM picks a mark
off the marked image), but Pace had no vision-grounded click decider to consume
it. That architectural mismatch is the whole reason the renderer was inert.

## Approach

Use Set-of-Mark as a **recovery fallback on the miss case only**:

1. The planner's click executes as today (text-grounded).
2. If `clickBestCandidate` exhausts all candidates with no observable state
   change, it returns a failure observation now carrying a structured
   `PaceSetOfMarkRecoveryRequest` (the target description + screen number).
3. If `enableSetOfMarkClickRecovery` is on, the agent loop renders the marks on
   the same screenshot, round-trips the **marked image** through the already-
   loaded VLM ("which numbered mark is `<target>`?"), maps the returned mark back
   to that element's bbox center, and re-clicks via a single-candidate set.
4. On success the failure observation is replaced with a recovery success; on
   failure the original failure stands and the planner re-plans as before.

Cost is one extra VLM round-trip **only on a miss** — the happy path is
byte-identical. This also turns click-failure events into productive signal,
which is exactly the data a future grounding-VLM (UI-TARS) direction needs.

### Scope

- **In:** the all-fail (miss) case.
- **Out (intentional):** near-tied/ambiguous candidates already resolve through
  the HUD clarification chips (`raiseClickTargetClarificationIfAmbiguous`,
  PRD `hud-intent-disambiguator.md`). SoM-for-ties (resolve without asking the
  user) is a clean follow-on but would change existing UX, so it is deferred.

## Flow

```
happy path:  VLM detect -> text planner picks element -> click            (unchanged)

miss:        click all-fail -> [recovery on] render marks on screenshot
             -> VLM reads MARKED image -> "mark #k is <target>"
             -> element[k].bbox center -> re-click -> success | re-plan
```

## Components

| File | Change |
|---|---|
| `PaceSetOfMarkRenderer.swift` | (existing) now has a real consumer — committed. |
| `PaceSetOfMarkClickRecovery.swift` | NEW pure coordinator: `resolve(inputs, renderMarks, groundMark)` → `ScreenshotPixelLocation?`. Build marks from element indices, render, ground, validate index, return bbox-center location. Fully unit-tested with injected closures. |
| `PaceActionTagParserTypes.swift` | `PaceSetOfMarkRecoveryRequest`; optional `setOfMarkRecovery` field on `PaceActionExecutionObservation` (defaulted — existing call sites unchanged). |
| `PaceActionExecutor.swift` | Populate the signal on the `clickBestCandidate` all-fail return; add public `executeRecoveredClick(at:screenCaptures:)`. |
| `LocalVLMClient.swift` | `groundMarkedClickTarget(markedImageData:targetDescription:markCount:)` → `Int?` on the protocol + HTTP impl. Marks numbered 0…N-1; replies a single number or -1. |
| `PaceScreenContextService.swift` | `cachedAnalysisIfFresh(screenLabel:…)` → `LocalVLMScreenAnalysis?` so the loop can reuse the element map built for the failed click. |
| `CompanionManager.swift` | After execution: detect the signal, pick the target capture, pull the cached analysis, run the coordinator, re-click, replace the observation on success. |
| `PaceUserPreferencesStore.swift` / `Info.plist` | `enableSetOfMarkClickRecovery` / `EnableSetOfMarkClickRecovery` (default true — only fires on a miss). |

## Risks & mitigations

- **VLM picks a wrong mark** → it can't be worse than the miss it's recovering;
  the index is range-validated and the re-click still requires an observable
  state change, else the failure stands.
- **Extra latency** → only on a miss, never on the happy path.
- **Stale element map** → `cachedAnalysisIfFresh` bounds age; nil → recovery is
  skipped and the original failure stands.

## Testing

Pure coordinator: in-range mark → correct bbox-center location; out-of-range /
ground-nil / empty-elements / render-nil → nil. Renderer keeps its existing
tests. Full suite via `scripts/test-pace.sh`.
