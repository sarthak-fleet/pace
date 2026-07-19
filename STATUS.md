# STATUS

> At-a-glance current state. The durable record is
> [`PROJECT_STATUS.md`](./PROJECT_STATUS.md) — update both together when state
> changes. Last updated: 2026-07-18.

## Objective

Ship Pace as the dependable on-device macOS voice companion. The broad
capability wave is over; the current phase is **integration and dogfood proof**,
not another feature wave. Make the existing perception / memory / proactivity /
background-work / action primitives behave like one companion across real
multi-hour and multi-day workflows.

## Active work

- **Companion consolidation** — the canonical handoff is
  [`docs/current/plans/autonomous-companion-consolidation.md`](docs/current/plans/autonomous-companion-consolidation.md):
  six remaining gap classes (persistent goal/activity understanding, shared
  proactive prioritization, outcome-driven learning, background-work UX, surface
  consolidation, live proof) and five acceptance stories.
- **Pace-tuned model scaffold** — turn collection is default-ON (local +
  redacted, provenance-tagged). LoRA training is pending accrued turn volume;
  filter by `plannerProvenance` before training. See
  [`docs/current/plans/pace-tuned-model-v1.md`](docs/current/plans/pace-tuned-model-v1.md).
- **Repository knowledge system** — this docs consolidation (AGENTS.md slimmed,
  `docs/` reorganized into architecture/product/development/operations/knowledge/
  current/archive, Blume presentation layer, link-check CI).

## Blockers

- **Test baseline compile-blocked (2026-07-17):** `scripts/test-pace.sh` fails
  to compile the test target under the installed Xcode 27 beta — actor
  `TestCompanionScreenAnalysisClient` cannot conform to global-actor-isolated
  protocol `PaceScreenAnalysisClient`. Older all-green totals (~1435) are
  historical until this is fixed and rerun. CI still runs the suite (pinned
  `macos-26`).
- **TCC:** never run terminal `xcodebuild` for routine dev — it re-requests
  screen recording / accessibility / mic permissions. Use Xcode Cmd+R or
  `scripts/test-pace.sh` (isolated DerivedData).
- **Pace-tuned LoRA** blocked on sufficient exported turn volume.
- **Stripe checkout URL** (`PUBLIC_PACE_CHECKOUT_URL`) blocked on the real
  Stripe link; mailto fallback ships until set.
- **Permissioned public testimonials** blocked on 3+ real quotes; landing uses
  anonymized theme cards meanwhile.
- **Companion release evidence:** hardware accuracy/resource thresholds and the
  manual Xcode `Cmd+R` checklist were explicitly risk-accepted for the
  2026-07-13 milestone, not measured. Complete them before any release claim
  that relies on those thresholds.
- **Benchmark publish:** use measured TTFSW from `scripts/benchmark_ttfsw.sh` —
  do not claim latency without local numbers.

## Open questions

- **VLM default model:** `ui-venus-1.5-2b` is torchSafetensors and LM Studio
  cannot load it (vision silently dead); `ui-venus-1.5-8b@4bit` measured 84.9%
  mark-reading (101/119, ~783ms). Repo default decision pending.
- **`PacePlannerModelResolver`** silently swaps brains (served gemma-3-12b when
  qwen unloaded) — needs fail-loud + served-model in traces.
- **MCP fixture subprocess** vs parallel test workers — known CI interaction to
  resolve.

## Next steps

1. Fix the Xcode 27 beta test-target compile block and re-establish a green
   baseline count.
2. Resume companion consolidation per the plan's recommended order; close out
   the five acceptance stories with live evidence.
3. Wire `PacePlannerModelResolver` fail-loud + served-model tracing.
4. Decide the default VLM model after a real-hardware eval-gate run.
5. Run the voice→Mail latency demo runbook and record a publishable TTFSW.
