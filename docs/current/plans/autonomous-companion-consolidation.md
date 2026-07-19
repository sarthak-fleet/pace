# Autonomous companion consolidation

Status: handoff backlog
Last reviewed: 2026-07-17

## Why this exists

Pace already has most of the required companion primitives: perception, local
memory, restraint, proactive cards and speech, tools, skills, background work,
scheduling, and plan-act-observe execution. The remaining work is not another
broad capability wave. It is making those systems behave like one dependable
companion during ordinary use.

The target loop is:

```text
Observe -> Understand -> Remember -> Anticipate -> Offer or Act -> Learn
```

The product is ready for the next phase when this loop works repeatedly across
real multi-hour and multi-day workflows, with useful interventions, low
annoyance, visible provenance, safe authority boundaries, and measurable
outcomes.

## Current gaps

### 1. Persistent goal and activity understanding

Pace records observations and retrieves history, but it does not yet maintain a
strong, continuously updated representation of the user's active outcome,
unfinished work, relevant commitments, and likely next step.

Needed:

- A typed active-activity/goal model derived from existing evidence rather than
  another unstructured summary.
- Explicit confidence, provenance, expiry, correction, and supersession.
- Goal transitions across apps, meetings, screen changes, and idle/resume.
- A clear distinction between observation, inference, user-stated intent, and
  an authorized task.

### 2. One prioritization path for proactive opportunities

Meeting context, calendar events, watch mode, routines, background agents, and
physical-world observations can all produce useful opportunities. They need a
shared ranking layer before the existing intervention/restraint policy decides
whether to stay silent, show a card, ask, or speak.

Needed:

- Deduplicate equivalent opportunities across producers.
- Rank by relevance, urgency, confidence, interruption cost, reversibility, and
  recent acceptance/rejection history.
- Cap simultaneous suggestions and expire stale opportunities.
- Expose the evidence behind every suggestion.

The reusable product primitive should be a dynamic "next move" card. Meetings
are one producer, not a separate product: answer a live question, suggest a
follow-up, recap a decision, or turn a commitment into a reminder. The same
surface should support errors, unfinished work, routines, and completed
background research.

### 3. Learning from outcomes, not only storing facts

Current learning primitives cover facts, corrections, routines, taught skills,
and local turn collection. The missing loop is behavioral adaptation based on
what happened after Pace intervened or acted.

Needed:

- Record whether a suggestion was accepted, dismissed, ignored, edited, undone,
  or completed successfully.
- Use that feedback to tune timing and ranking without silently expanding
  authority.
- Propose a skill or automation only after a repeated workflow has enough
  independent evidence.
- Preserve user corrections as explicit superseding evidence.
- Provide a readable "why Pace learned this" and forget/reset path.

Self-learning must never mean self-granting permissions, silently changing a
high-risk workflow, or training on data outside the documented local policy.

### 4. Background work as a first-class surface

Background agents and scheduled tasks exist, but they need a coherent user
surface for active, queued, blocked, completed, and failed work.

Needed:

- A small `Working` view with progress, latest evidence, required approval, and
  completion state.
- Durable task identity across foreground turns and relaunches where safe.
- Cancellation and bounded retry behavior.
- A completion card that returns the result to the current activity rather than
  creating an isolated notification.

### 5. Product-surface consolidation

Avoid exposing every subsystem as a separate mini-product. Converge toward
three understandable surfaces:

- **Now**: current activity, relevant context, and at most a few next moves.
- **Working**: background and scheduled work, progress, blockers, approvals.
- **Memory**: learned facts/routines, provenance, corrections, and forgetting.

Settings remain the place for permissions, model/provider choices, source
toggles, and diagnostics.

### 6. Live proof and release evidence

The always-on companion code milestone is complete, but the hardware/resource
thresholds and manual Xcode checklist in `docs/product/companion-mode-dogfood.md` remain
unmeasured. Meeting capture and real-app action paths also retain manual gates.

Before claiming the consolidated companion experience is ready:

- Complete and retain the companion-mode dogfood measurements.
- Run the hardware meeting-recording smoke checklist.
- Exercise real-app screen/action scenarios, including ambiguity and undo.
- Measure intervention usefulness, dismissal/ignore rate, repetition, and false
  interruption rate over at least seven days.
- Publish latency or accuracy numbers only from the existing measurement tools.

## Five acceptance stories

Do not call the consolidation milestone complete until all five stories work
repeatedly on a real Mac.

1. **Resume work**: Pace observes a multi-app work session, identifies the
   active outcome with evidence, and restores useful context after an idle
   period or relaunch.
2. **Learn a routine**: Pace observes a repeated workflow, proposes a skill,
   incorporates a correction, and runs it only after explicit acceptance.
3. **Meeting lifecycle**: Pace prepares a local pre-meeting brief, offers quiet
   live assistance, produces grounded notes, and follows through on accepted
   commitments.
4. **Investigate in the background**: Pace notices or is given a problem,
   performs bounded background work, reports progress, and returns a verified
   result without blocking the foreground conversation.
5. **Remember and follow through**: Pace records a promise with provenance,
   resurfaces it at an appropriate time, and records whether the user completed,
   deferred, corrected, or dismissed it.

For every story, retain evidence for correctness, latency, authority/approval,
undo or cancellation, intervention timing, and persistence across relaunch.

## Recommended order

1. Restore a green repository test baseline.
2. Complete live companion and meeting hardware evidence before building on
   unproven capture paths.
3. Add outcome/feedback telemetry to existing local intervention records.
4. Implement the typed active-activity/goal model.
5. Add shared opportunity ranking and dynamic next-move cards.
6. Consolidate the `Now`, `Working`, and `Memory` surfaces.
7. Dogfood the five acceptance stories for at least seven days, then fix the
   highest-frequency failure rather than adding breadth.

## Baseline observed on 2026-07-17

`bash scripts/test-pace.sh` did not reach test execution under the installed
Xcode 27 beta. The test target failed to compile because actor
`TestCompanionScreenAnalysisClient` could not conform to the global-actor-
isolated `PaceScreenAnalysisClient` protocol. Treat older all-green test counts
in status documents as historical until this baseline is restored and rerun.

No implementation change is implied by this handoff. Each substantial behavior
change should enter the normal OpenSpec explore/propose/apply/archive workflow
when picked up.
