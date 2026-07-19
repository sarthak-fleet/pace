# Failed and deferred approaches

Approaches that were tried and rejected, or deliberately deferred, with the
reason. Read this before retrying a dead end — the next agent should not spend a
turn rediscovering why something doesn't work here. Update this page when an
approach is abandoned or a deferred idea is revisited.

The durable status record is [PROJECT_STATUS.md](https://github.com/HeyPace/pace/blob/main/PROJECT_STATUS.md); this
page is the curated "do not retry without new information" list.

## Rejected: cloud anything as a default

**Why rejected:** Pace's headline differentiator is fully-on-device operation
(speed + zero operating cost + "0 bytes sent off this Mac"). Cloud LLM, cloud
STT, cloud TTS, and cloud telemetry call paths have all been removed. Cloud
bridge / Direct API / CLI direct-spawn exist only as **opt-in** tiers, each
visibly indicated (amber capsule), audit-logged, and fail-loud. Making any cloud
path the default contradicts the moat. Do not reintroduce a cloud default or a
silent cloud fallback (the `directAPIFallsBackToLocalOnCloudFailure` opt-in is
the one explicit, off-by-default exception).

## Rejected: dual-agent prefetch (removed as dead code)

**Why rejected:** a partial-transcript-keyed RAG prewarm / dual-agent prefetch
was removed as dead code — it added hot-path complexity for negligible,
unmeasurable TTFSW upside. The expensive prewarm (VLM screen context) already
runs at PTT press via `PaceScreenContextService.prewarmScreenContext`, and local
retrieval (BM25 + in-memory episodic) is already sub-millisecond. Revisit only
if a `benchmark_ttfsw.sh` run shows retrieval on the critical path. (Tracked in
[`competitive/steal-catalog.md`](competitive/steal-catalog.md).)

## Rejected: meetily's meeting-notes shape (partially)

**What was taken:** the selectable meeting-note **profile** idea (general /
standup / one-on-one, with a `general` byte-for-byte compat anchor).

**Rejected as non-fits from meetily:**
- Its 7 markdown-table templates — too rigid; Pace uses one structured shape
  per profile.
- VAD (voice-activity detection) — Pace's `PaceMeetingTurnSegmenter` already
  covers segmentation (Accelerate RMS + hysteresis + echo trimming).
- RMS ducking — two-track capture (mic + system as separate tracks) is better
  than ducking one mixed track.
- Real-time transcription + diarization — separate large efforts, not in scope
  for the notes wedge.

## Deferred: persistent KV planner backend

**Why deferred:** blocked on TinyGPT oMLX qualification. The in-process MLX
planner (Qwen3-4B) is available behind the Settings → Models toggle but is
**not** the default — fresh installs talk via Apple Foundation Models or LM
Studio. Do not flip the bundled-MLX planner to default without a 4B-vs-30B
eval-gate run on real hardware; per project memory, Pace-side model work is
otherwise concluded.

## Deferred: grammar-constrained v10 as runtime default

**Why deferred:** TinyGPT / eval gated. The shipping planner remains the current
MLX / Qwen stack with `response_format: json_schema` decode constraining. The
grammar-constrained gate is a shipping-decision harness, not the runtime path.

## Deferred: real-app AX smokes in CI

**Why deferred:** TCC makes automated live-app tests fragile — terminal
`xcodebuild` invalidates permissions. Live-app executor smokes
(`scripts/smoke-executor-surface.sh`, `scripts/smoke-real-apps.sh`) are
manual-only. The 3 hardware-bound tests are gated behind `TEST_RUNNER_PACE_CI`
in CI and still run locally.

## Deferred: hosted telemetry or accounts

**Why deferred:** contradicts the on-device moat. Analytics are local-only
no-op/timing-safe hooks (`PaceAnalytics.swift`); no cloud analytics SDK is
linked. Do not add accounts or hosted telemetry.

## Deferred: speaking-time context prefetch (episodic/RAG)

**Why deferred:** the expensive prewarm already runs at PTT press and local
retrieval is sub-millisecond, so a partial-transcript-keyed RAG prewarm adds
hot-path complexity for negligible upside — and it mirrors the dual-agent
prefetch already removed as dead code. Revisit only if a benchmark shows
retrieval on the critical path.

## Known live-testing follow-ups (not failures — unfinished edges)

These are not rejected approaches; they are known rough edges surfaced by the
live gauntlet that should be fixed, not retried as-is:

- **Few-shot coordinate echo** — the planner can echo coordinates from few-shot
  examples; needs a prompt/parser guard.
- **`PacePlannerModelResolver` silent brain swap** — served gemma-3-12b when
  qwen unloaded; needs fail-loud + served-model in traces.
- **MCP fixture subprocess vs parallel test workers** — known CI interaction;
  CI runs serial because parallel workers crash on the image.

## Rejected: fixing the known non-blocking warnings

**Why rejected:** Swift 6 concurrency warnings and the deprecated `onChange` in
`OverlayWindow.swift` are intentionally not fixed (per `AGENTS.md`). Do not
attempt these unless explicitly asked — they are noise, not signal, and chasing
them risks churn on stable paths.
