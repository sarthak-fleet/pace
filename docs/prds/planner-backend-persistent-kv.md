# PRD — Persistent-prefix-KV / KV-SSD planner backend (oMLX-class)

Status: proposed (not-started). Depends on tinyGPT qualifying the backend
(see tinygpt `docs/prds/B34-batched-eval-runtime.md`); Pace consumes it.

## Goal

Replace Pace's LM Studio planner bridge with an **oMLX-class local inference
backend** that gives Pace two things LM Studio doesn't: (1) a **persistent
prefix-KV cache on disk** — compute the system-prompt + tool-schema KV *once*
and reuse it across turns *and across app restarts* — and (2) **tiered KV
cache RAM→SSD** so Pace can hold longer context / run the 30B-A3B planner with
more headroom on a 48 GB Mac. The win is squarely on Pace's north-star metric:
time-to-first-word.

## Why this exists

- **Pace's whole game is tail latency** (the 330→119 ms TTFW hunt). Every turn
  re-feeds a large, *invariant* prefix: the system prompt + the full tool
  schema + recent conversation. Recomputing that prefix's KV every turn is
  wasted prefill on the critical path.
- **LM Studio caches the prefix in-memory, per-session at best** — it's gone on
  restart, and it doesn't page cold KV to SSD. oMLX does both (hot RAM / cold
  SSD KV, continuous batching, OpenAI+Anthropic APIs, native menu-bar). For
  Pace's single-user, huge-reused-prefix shape, **persistent prefix-KV is the
  single biggest TTFT lever left.**
- The model-supply doctrine (`docs/architecture.md` §1) already says Pace
  consumes the best qualified runtime; this picks one and wires the win.

## What we steal from oMLX (Pace-specific)

| oMLX feature | For Pace? | Why |
|---|---|---|
| Persistent prefix-KV cache to disk | **Yes — top priority** | system prompt + tools reused every turn; survives restart → big TTFT win |
| Tiered KV cache RAM→SSD | **Yes** | hold longer context / bigger planner on 48 GB |
| OpenAI **+ Anthropic** API compat | **Yes** | matches Pace's cloud-bridge (Claude Code / Codex) |
| Native menu-bar model management | **Yes (UX)** | Pace is already a menu-bar app; fold model download/swap in |
| Continuous batching | **No** | Pace is single-user; throughput batching buys nothing here (that's tinyGPT's eval need) |

## Scope — in

- **Swap the planner backend** from LM Studio to the qualified oMLX-class
  backend (loopback HTTP, OpenAI-compatible — same wire format Pace already
  speaks, so `LocalVLMClient` / planner clients need minimal change).
- **Persistent prefix-KV cache**: ensure Pace submits the invariant prefix
  (system + tools) byte-stably so the backend's prefix cache hits; verify the
  prefix KV persists across an app restart; log TTFT with vs without the cache.
- **KV-SSD headroom**: configure the backend so a 30B-A3B planner runs with the
  larger context Pace's longer sessions want, paging cold KV to SSD.
- **Anthropic-format path** wired alongside the existing OpenAI one so the
  same client can hit cloud-bridge or local interchangeably.

## Scope — out

- **Building the KV-SSD / prefix-cache engine** — adopt the backend, don't
  rebuild it (that's oMLX/LM Studio's commoditized lane).
- **Pace's eventual in-process MLX runtime** (`local-vlm-runtime-port.md`,
  `whisperkit-streaming-asr.md`) — this backend is the *bridge* that delivers
  the latency win now; the in-process runtime is the longer-term destination
  and can inherit the same persistent-prefix-KV idea.
- **Distillation / model training** — separate; though note the validated
  cost-compression result (a fine-tuned 0.6B matched a 4B on tool-calling at
  1/7th size) means a future Pace planner could be a *distilled small* model
  this backend serves even faster.

## Acceptance criteria

- [ ] Pace runs end-to-end (voice → planner → action) on the new backend with
  no regression on the fm-fixture gate.
- [ ] On a warm prefix (system + tools cached), **TTFT drops measurably** vs the
  LM Studio path — and the cache survives an app restart.
- [ ] A longer-context session that OOM'd / truncated under the old path runs
  via KV-SSD paging.
- [ ] The planner client can target an Anthropic-format endpoint as well as
  OpenAI.

## Reference

- `docs/architecture.md` §1 (model-supply doctrine; in-process is the eventual
  target, this is the bridge).
- tinyGPT `docs/prds/B34-batched-eval-runtime.md` (qualifies the backend; the
  *eval* side of the same oMLX steal — batching there, persistent-prefix here).
- oMLX (https://omlx.ai) — the RAM↔SSD KV + prefix-cache implementation being
  adopted.

## Open questions

- Adopt oMLX directly vs `mlx_lm.server` vs Pace embedding the cache logic in
  its own loopback shim — qualify on the TTFT smoke (`scripts/profile-pace-turn.sh`).
- Whether the persistent prefix cache invalidates correctly when the tool
  schema changes between releases (cache key must include a tools-hash).
