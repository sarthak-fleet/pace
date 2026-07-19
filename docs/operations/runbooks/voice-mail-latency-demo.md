# Voice → Mail latency demo (`<700 ms` TTFSW)

Reproducible check that a spoken "draft an email…" turn reaches
first-spoken-word in under 700 ms with the Mail app pre-warmed. This is the
publishable number behind the "fast voice → action" claim.

> **Why this is a manual runbook, not a unit test:** TTFSW is measured from
> real push-to-talk release to the first TTS dispatch on real hardware. The
> unit suite injects synthetic transcripts and cannot observe capture/render
> timing. Run this on the Mac you demo from. `xcodebuild` is banned for dev
> (TCC) — build + run from Xcode (Cmd+R).

## One-time setup

1. **Enable Mail prewarm.** In `leanring-buddy/Info.plist` set
   `PrewarmMailForDrafts` to `true` (default is `false` so normal installs
   don't launch Mail at startup). This makes `prewarmMailForFastDraftsIfNeeded()`
   (`leanring_buddyApp.swift`) launch + warm Mail so the first draft turn
   isn't paying cold-launch cost.
2. Sign in to Mail so a compose window can actually open.
3. Grant Pace mic + screen-recording + accessibility once (normal first-run).

## Run

1. Build + launch from Xcode (Cmd+R) so TCC grants persist. Wait for Mail to
   finish pre-warming (log line `📬 Pace: Mail prewarmed for drafts …`).
2. Do **8–10** voice-to-Mail turns, e.g. hold ctrl+option and say:
   *"Draft an email to Alex saying I'll be five minutes late."*
   Vary the recipient/body so you're not measuring a cache.
3. Aggregate the metrics from the unified log (scope the window to just your
   run):

   ```bash
   bash scripts/benchmark_ttfsw.sh --last 10m
   ```

   Each turn emits `TTFSW=NNNms` (PTT-release → first TTS dispatch) via
   `PaceTelemetryLog` (OSLog `com.pace.app` / `metrics`), which is what the
   script queries.

## Read the result

The script prints a markdown table (`n`, `min`, `p50`, `p95`, `max`, `mean`).

- **Pass:** `p50 TTFSW < 700 ms` across the run (and ideally `p95 < 700 ms`).
- If `p50` is over budget, check `STT` and `VLM` columns — a Mail-draft turn
  should be `.tool-action` intent and normally **skips the VLM** (see the
  VLM-skip heuristic), so the budget is dominated by STT + planner first token.
- Record the `p50`/`p95` you measured and the machine (chip, RAM, macOS
  version) alongside the number — do not publish a latency claim without the
  local numbers (fleet rule).

## Cleanup

Set `PrewarmMailForDrafts` back to `false` before committing/releasing — it's
a demo-only setting, not a shipping default.

## Publish

Put the measured `p50`/`p95` (with hardware) on the landing latency claim and
in `PROJECT_STATUS.md`. Then close Planned item #4.
