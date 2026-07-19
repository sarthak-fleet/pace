# Smoke-test checklist — 2026-05-29 autonomous-loop changes

After `killall Pace && Cmd+R`, walk through this list. Each item is
self-contained: hold push-to-talk, say the prompt, look for the
expected behavior, glance at the Xcode console for the marker line.

## Setup

1. **LM Studio is running** with both models pinned:
   - `qwen/qwen3-30b-a3b` (planner)
   - `ui-venus-1.5-2b` (VLM)
   - Confirm via `lms ps` from terminal — both should show `IDLE`,
     no `:2` duplicates.
2. **LM Studio Settings → max-loaded-models = 2** so they don't evict
   each other mid-turn.
3. **Pace running**, walking avatar visible at bottom of cursor screen.

## Tests

### T1 — Chitchat fast-path (NEW this loop)

> Hold PTT, say: **"hi pace"**

Expected:
- TTS replies near-instantly with one of: "hey", "hey there", "hi! what's on your mind?"
- **Total turn ≈ 100–500ms** (vs ~2700ms before)
- Avatar mouth animates open
- Cursor stays parked at avatar — no flight, no VLM, no screenshot capture

Xcode console marker:
```
🎯 Intent: chitchat (confidence 0.95) — fast-path
```

Repeat with: **"thanks"**, **"good morning"**, **"how are you"**, **"bye for now"**.
All should hit the fast-path.

### T2 — Full pipeline still works (regression check)

> Hold PTT, say: **"what's on this screen"**

Expected:
- Pace describes whatever's in front of you
- Total turn ≈ 2000–3500ms
- VLM ran (you'll see the timing line)

Xcode console marker:
```
🎯 Intent: screenDescription (confidence 0.85) — full pipeline
⏱  Step 1 screen capture: <N>ms
⏱  Step 1 screen context (VLM + OCR + AX): <N>ms
⚡ Planner TTFT: <N>ms (model=qwen/qwen3-30b-a3b, 4 msgs)
⚡ TTFSW: <N>ms (PTT-release → first TTS dispatch)
```

If any stage looks unexpectedly slow (planner > 3000ms, screen
context > 3000ms), that's where to investigate.

### T3 — Action chain (regression check)

> Position cursor over an app with a visible button. Hold PTT, say:
> **"click the save button"** (or any visible button).

Expected:
- Cursor flies from avatar to the button
- The button gets pressed (real click via AX or CGEvent)
- TTS narrates ("clicking the save button" or similar)
- Avatar returns

### T4 — Planner identity (regression check)

> Hold PTT, say: **"who are you"**

Expected:
- Reply: "i'm pace" (or close variant)
- NEVER says "siri" or "apple intelligence"

### T5 — Voice quality (regression check)

Listen for Samantha-Enhanced or whichever voice you have configured.
First TTS dispatch should print the picked voice:

```
🔊 Local TTS voice: Samantha (Enhanced)
```

If it says `Compact — sounds shrill`, the upgrade-hint log will tell
you which voice to download.

### T6 — diag-pace.py self-test

From terminal:
```
bash scripts/verify.sh
```

Expected: all blocking checks pass. Per-fixture eval shows 19/19 pass.
LM Studio model config printed at top should read `context=4096,
parallel=4` for the planner (not the 32768/32 we caught last time).

## If anything fails

Capture the Xcode console for the failing turn. The per-stage timing
lines + `🎯 Intent:` line + planner TTFT line together pinpoint
which layer regressed. Paste the log when reporting.

## Things this loop deliberately didn't ship

- **MLX in-process planner is dormant** — `PlannerProvider=local` is
  still the active config. To activate the in-process path, follow
  the steps in `AppleMLXPlannerClient.swift`.
- **Core ML intent classifier is dormant** — rule-based backend is
  active. To upgrade accuracy, train the `.mlmodel` from
  `evals/intent-corpus/seed.csv` and follow steps in
  `PaceIntentClassifier.swift`.
- **Pure-knowledge fast-path (skip VLM)** — not wired yet; the
  existing `transcriptIsLikelyScreenReferential` heuristic mostly
  covers this case already. Will wire once Core ML model is in.

## Commits validated by this test (in order)

```
3b1311c  Per-stage turn timing — screen capture + screen context
313f9f0  Wire intent classifier into CompanionManager: chitchat fast-path
2c3b14d  #113 skeleton: PaceIntentClassifier + 200-example seed corpus
f99b52d  #114 skeleton: AppleMLXPlannerClient placeholder + factory routing
c867eab  diag-pace.py: print loaded model config
b60c263  diag-pace.py: surface failing fixture + retry transients
9280915  diag-pace.py: synthetic full-turn simulation
8b79af0  Add action-chain eval coverage
4cff3e5  verify.sh + fix duplicate-load chaining
aa18d3a  Sync AGENTS.md to current planner default
8624b26  diag-pace.py --eval flag
11866f9  Sanitize pipe-separated VLM roles
197993a  Tolerate VLM JSON missing description
```
