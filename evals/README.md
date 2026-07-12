# Pace Evals

Reproducible fast + correct checks for the local planner pipeline.

## Why this exists

Two things move regularly and need ongoing measurement:

- **Latency.** Every system-prompt tweak, every conversation-history change, every model swap pushes TTFT up or down. Without a fixture suite we're guessing.
- **Behavior.** The local planner is non-deterministic — what worked yesterday with Qwen3-14B at temperature 0.4 may regress today with Qwen3-1.7B at temperature 0. We need to catch "planner started emitting markdown again," "agent rules leaked into a non-action turn," etc.

Both eval kinds live here. They run against your real `localhost:1234` LM Studio, not against mocks — the whole point is to measure what the user actually feels.

## Running

```bash
# Hit every fixture, print pass/fail table.
./scripts/eval-pace.sh

# Run a single fixture by name.
./scripts/eval-pace.sh qa-no-screen

# Skip the speed evals (faster, only checks correctness).
./scripts/eval-pace.sh --no-latency

# Validate deterministic v10 planner-response schema fixtures without LM Studio.
python3 scripts/eval-v10-schema-fixtures.py
```

The script reads the planner endpoint + model identifier from `leanring-buddy/Info.plist`, so it always evaluates whatever Pace itself would call.
The streaming helper retries only when LM Studio returns HTTP 200 with zero raw content; retry attempts disable `cache_prompt` to avoid local prefix-cache blank streams, then use a non-streaming fallback if SSE stays empty. Incorrect answers, thinking-only answers, regex misses, HTTP errors, and latency misses still fail normally.

## Fixtures

Each fixture is a single JSON file under `fixtures/`:

```json
{
  "name": "qa-no-screen",
  "category": "qa",
  "request": {
    "messages": [
      {"role": "system", "content": "<system prompt — keep in sync with CompanionSystemPrompt.swift>"},
      {"role": "user", "content": "what is html?"}
    ],
    "temperature": 0,
    "max_tokens": 200
  },
  "expectations": {
    "max_ttft_ms": 1500,
    "must_contain_patterns": ["html", "markup"],
    "must_not_contain_patterns": ["<tool_calls", "\\[CLICK", "\\[TYPE", "\\[KEY", "\\[OPEN_APP", "\\[VOLUME", "\\[BRIGHTNESS", "^\\s*-\\s", "\\*\\*"]
  }
}
```

Field reference:

| Field | Purpose |
|---|---|
| `name` | Unique fixture id — file name without `.json`. |
| `category` | Used to bucket the latency report (`qa`, `screen-referential`, `action`, etc.). |
| `request` | Verbatim body POSTed to `/v1/chat/completions` (apart from `model`, which the script injects from Info.plist). |
| `expectations.max_ttft_ms` | TTFT budget. Failing means too slow. |
| `expectations.must_contain_patterns` | List of regexes that MUST appear (case-insensitive) in the response. |
| `expectations.must_not_contain_patterns` | List of regexes that MUST NOT appear. |

## VLM screen-grounding measurement

Pace's Set-of-Mark click recovery (`leanring-buddy/PaceSetOfMarkRenderer.swift`,
`PaceSetOfMarkClickRecovery.swift`, `LocalVLMClient.groundMarkedClickTarget`)
draws numbered magenta marks on a screenshot and asks the local VLM which mark
sits on a target element. That VLM path — mark reading and element grounding —
was never measured. Three steps close the gap, isolating each failure mode:

1. **Synthetic mark-reading micro-eval** — `scripts/eval-vlm-mark-reading.py`.
   Generates deterministic synthetic UI mockups (PIL) and draws numbered marks
   with the exact `PaceSetOfMarkRenderer` convention (2px `systemPink` outline +
   white-on-`systemPink` index chip at each box's top-left, top-left-origin
   coordinates). It then asks the VLM which mark is on a named element and scores
   exact integer match — the pure "can the model read the number I drew?" skill,
   with ground truth we control.

   ```bash
   ./scripts/eval-vlm-mark-reading.py                       # default ui-venus-1.5-2b
   ./scripts/eval-vlm-mark-reading.py --models ui-venus-1.5-2b,qwen3-vl-8b-instruct
   ./scripts/eval-vlm-mark-reading.py --generate-only --image-dir /tmp/marks  # inspect only
   ```

2. **Capture the real corpus** — `scripts/capture-grounding-corpus.sh`.
   Interactive helper you run on your Mac: for each `fm-vlm-fixtures-v1` fixture
   that lacks a screenshot, it prints the scenario, captures the screen with
   `screencapture -x` into `fm-vlm-fixtures-v1/screenshots/<name>.png`, and
   records a `SCREENSHOT_PATH:` line in the fixture. Skip-if-exists; `--status`
   lists what's still missing without capturing.

   ```bash
   ./scripts/capture-grounding-corpus.sh --status   # list missing
   ./scripts/capture-grounding-corpus.sh            # capture them
   ```

3. **Real-VLM fixture eval** — `scripts/eval-vlm-grounding.py`.
   For fixtures that carry a `SCREENSHOT_PATH`, runs the full flow against LM
   Studio: (a) element-map extraction (`analyzeScreenshot`), (b) target-found
   check, (c) Set-of-Mark mark-reading on the extracted map (same renderer
   convention as step 1). Scores per fixture, prints an **AX-blind-only** row,
   and compares against the AX+OCR baseline (`ax-blind-*` fixtures fail it).
   Graceful when zero screenshots exist (prints the step-2 instruction, exits 0);
   fails loud if LM Studio is down while screenshots exist.

   ```bash
   ./scripts/eval-vlm-grounding.py
   ```

**Acceptance bar** (from `fm-vlm-fixtures-v1/README.md`): the real VLM must beat
the AX+OCR baseline by **> 30 percentage points on the AX-blind cases** to claim
real screen-grounding contribution. The step-3 summary prints this delta and a
MEETS / BELOW verdict.

Both eval scripts hit the real `localhost:1234` LM Studio and NEVER fabricate
results — if the server is unreachable they print a "start LM Studio and load
`<model>`" message and exit nonzero.

## V10 Schema Fixtures

`v10-schema-fixtures/` contains deterministic planner-response JSON examples.
They do not call a model. `scripts/eval-v10-schema-fixtures.py` reads the
bundled `pace-fm-response-v10.schema.json` artifact and verifies that each
fixture's `valid` flag matches the schema result. Use this to catch envelope
drift before switching the planner runtime default or changing the v10 prompt.

## Budgets

`budgets.json` is a per-category latency target you can paste into the README hero number. Today's targets are aspirational — the point is to see how the numbers move as we iterate, not to gate releases.

## Drift caveat

The fixtures embed a system prompt. That string is a snapshot of `CompanionSystemPrompt.swift` at the time the fixture was written. When the real prompt changes, update the fixtures — otherwise the evals stop reflecting reality. There's a comment marker `<!-- system-prompt-version: N -->` near the top of each fixture to track which generation it's from.
