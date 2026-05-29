#!/usr/bin/env python3
"""
eval-planners.py — head-to-head comparison of multiple planners against the
Pace FM-fixture set.

Why this exists
---------------
We want to know "is a bigger model meaningfully smarter at Pace's job
than Apple Foundation Models' 3B?" — empirically, on Pace's actual
behavior expectations, not vibes.

This script:
  1. Loads each model sequentially via `lms load` / `lms unload` so we
     never have multiple multi-GB weights in RAM at once on a 48GB Mac.
  2. Sends each fixture through the model with response_format set to
     a JSON schema mirroring PaceFMTurnResponse — apples-to-apples with
     the @Generable path FM uses.
  3. For "fm" model name, runs the existing Apple Foundation Models
     CLI eval (which already uses @Generable typed output).
  4. Scores each fixture against the EXPECT_* fields in the fixture
     file (see evals/fm-fixtures/README.md).
  5. Prints a markdown comparison table at the end.

Usage
-----
  ./scripts/eval-planners.py \
      --models fm qwen/qwen3-14b qwen/qwen3-30b-a3b \
                google/gemma-3-12b zai-org/glm-4.7-flash

  ./scripts/eval-planners.py --models fm qwen/qwen3-14b  # smaller subset
  ./scripts/eval-planners.py --fixtures-only short-list  # diagnostic single-fixture
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
FIXTURES_DIR = PROJECT_DIR / "evals" / "fm-fixtures"
LMS_BIN = os.environ.get("LMS_BIN", str(Path.home() / ".lmstudio" / "bin" / "lms"))
LM_STUDIO_URL = os.environ.get(
    "PACE_LM_STUDIO_URL", "http://localhost:1234/v1/chat/completions"
)
FM_RUNNER_SCRIPT = SCRIPT_DIR / "eval-fm.sh"

# ---------------------------------------------------------------------------
# System prompt — MUST stay in sync with CompanionSystemPrompt.swift.
# We duplicate it here (same as eval-fm.sh does) so the comparison reflects
# what Pace actually sends. Drift is OK for diagnostic runs but will skew
# real comparisons — re-sync any time the Swift prompt changes.
# ---------------------------------------------------------------------------

BASE_VOICE_RULES = """\
you are pace, a voice companion that lives in the user's menu bar. you are NOT siri, NOT apple intelligence, NOT a chatbot. you are pace. if the user asks who you are, who they are talking to, or whether you are siri, you must answer "i'm pace" — never "siri", never "apple intelligence".

the user just spoke to you via push-to-talk and you can see their screen. your reply is read aloud, so write the way you'd actually talk.

rules:
- default to one or two sentences. be direct.
- all lowercase, casual, warm. no emojis.
- write for the ear. no lists, no bullets, no markdown.
- if the question relates to what's on screen, reference what you see. otherwise just answer the question."""

POINTING_RULES = """\
on-screen elements are given to you in this format, one per line:
    [N] role|x,y|label|text
where N is the integer element ID. POINT and CLICK fields take ONE of those integer IDs, or -1 for "no target".

- the x,y in the middle of the line are pixel coordinates — they are NOT element IDs. only the integer in brackets at the start of the line is the ID. do not confuse the two.
- spokenText is what's read aloud to the user. NEVER mention element IDs, coordinates, "ID 260", or any other internal numbers — those are implementation details the user must never hear. talk like a person, not a parser.

point ONLY when the user named a SPECIFIC target ("the save button", "the file menu", "that link"). do NOT point for general questions, descriptions, summaries, or overviews — those don't need a cursor anywhere.

decide which case the user's request falls into:

A. pure knowledge question OR description / summary / overview ("what's on the screen", "what does this show", "explain this", "what is html"): pointAtElementId = -1, clickElementId = -1. spokenText answers naturally. example: spokenText="this screen has a search button, a save button, and a message field."

B. user named a target that IS in the element list. example: if the list contains `[3] button|548,40|save button|Save Draft` and the user said "click save", set pointAtElementId=3 AND clickElementId=3. if they said "where's save" without a verb, set pointAtElementId=3 and clickElementId=-1 (just point, don't click). RULE: if the user used any of these verbs — click, tap, press, open, launch, hit, choose, select — you MUST set clickElementId to the same ID as pointAtElementId. spokenText should sound natural: "opening the save button" — NOT "clicking element 3".

C. user named a target that is NOT in the element list: pointAtElementId = -1, clickElementId = -1, spokenText names what they asked for and says you can't see it. example: spokenText="i can't see an elephant button on this screen."

case C is critical. picking a wrong but nearby element from the list is FORBIDDEN. picking arbitrary IDs is FORBIDDEN. the only acceptable response when the target is missing is to refuse cleanly with both IDs set to -1."""

SYSTEM_PROMPT = BASE_VOICE_RULES + "\n\n" + POINTING_RULES

# JSON schema used as response_format for LM Studio models. Mirrors
# PaceFMTurnResponse's @Generable schema.
RESPONSE_SCHEMA = {
    "type": "json_schema",
    "json_schema": {
        "name": "PaceTurn",
        "strict": True,
        "schema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "spokenText": {"type": "string"},
                "pointAtElementId": {"type": "integer"},
                "clickElementId": {"type": "integer"},
            },
            "required": ["spokenText", "pointAtElementId", "clickElementId"],
        },
    },
}

# ---------------------------------------------------------------------------
# Fixture parsing + scoring
# ---------------------------------------------------------------------------


@dataclass
class FixtureExpectations:
    point_id_exact: Optional[int] = None
    click_id_exact: Optional[int] = None
    point_id_one_of: Optional[list[int]] = None
    click_id_one_of: Optional[list[int]] = None
    spoken_must_contain: list[str] = field(default_factory=list)
    spoken_must_not_contain: list[str] = field(default_factory=list)
    spoken_max_words: Optional[int] = None

    @property
    def has_any_check(self) -> bool:
        return any(
            value not in (None, [], "")
            for value in (
                self.point_id_exact,
                self.click_id_exact,
                self.point_id_one_of,
                self.click_id_one_of,
                self.spoken_must_contain,
                self.spoken_must_not_contain,
                self.spoken_max_words,
            )
        )


@dataclass
class Fixture:
    name: str
    transcript: str
    element_map: str
    expectations: FixtureExpectations


def parse_fixture(path: Path) -> Fixture:
    transcript = ""
    element_lines: list[str] = []
    expectations = FixtureExpectations()

    with path.open() as fixture_file:
        for raw_line in fixture_file:
            line = raw_line.rstrip("\n")
            if line.startswith("USER: "):
                transcript = line[len("USER: ") :]
            elif line.startswith("ELEMENT: "):
                element_lines.append(line[len("ELEMENT: ") :])
            elif line.startswith("EXPECT_POINT_ID: "):
                expectations.point_id_exact = int(line[len("EXPECT_POINT_ID: ") :])
            elif line.startswith("EXPECT_CLICK_ID: "):
                expectations.click_id_exact = int(line[len("EXPECT_CLICK_ID: ") :])
            elif line.startswith("EXPECT_POINT_ID_ONE_OF: "):
                expectations.point_id_one_of = [
                    int(value.strip())
                    for value in line[len("EXPECT_POINT_ID_ONE_OF: ") :].split(",")
                ]
            elif line.startswith("EXPECT_CLICK_ID_ONE_OF: "):
                expectations.click_id_one_of = [
                    int(value.strip())
                    for value in line[len("EXPECT_CLICK_ID_ONE_OF: ") :].split(",")
                ]
            elif line.startswith("SPOKEN_MUST_CONTAIN: "):
                expectations.spoken_must_contain = [
                    token.strip().lower()
                    for token in line[len("SPOKEN_MUST_CONTAIN: ") :].split(",")
                    if token.strip()
                ]
            elif line.startswith("SPOKEN_MUST_NOT_CONTAIN: "):
                expectations.spoken_must_not_contain = [
                    token.strip().lower()
                    for token in line[len("SPOKEN_MUST_NOT_CONTAIN: ") :].split(",")
                    if token.strip()
                ]
            elif line.startswith("SPOKEN_MAX_WORDS: "):
                expectations.spoken_max_words = int(line[len("SPOKEN_MAX_WORDS: ") :])

    return Fixture(
        name=path.stem,
        transcript=transcript,
        element_map="\n".join(element_lines),
        expectations=expectations,
    )


@dataclass
class ModelResponse:
    spoken_text: str
    point_at_element_id: int
    click_element_id: int
    elapsed_ms: int
    raw: str = ""
    error: Optional[str] = None


@dataclass
class FixtureScore:
    passed: bool
    failures: list[str]


def score_fixture(response: ModelResponse, expectations: FixtureExpectations) -> FixtureScore:
    failures: list[str] = []

    if response.error:
        failures.append(f"error: {response.error}")
        return FixtureScore(passed=False, failures=failures)

    if expectations.point_id_exact is not None:
        if response.point_at_element_id != expectations.point_id_exact:
            failures.append(
                f"pointAt={response.point_at_element_id}, expected {expectations.point_id_exact}"
            )

    if expectations.click_id_exact is not None:
        if response.click_element_id != expectations.click_id_exact:
            failures.append(
                f"click={response.click_element_id}, expected {expectations.click_id_exact}"
            )

    if expectations.point_id_one_of is not None:
        if response.point_at_element_id not in expectations.point_id_one_of:
            failures.append(
                f"pointAt={response.point_at_element_id}, expected one of {expectations.point_id_one_of}"
            )

    if expectations.click_id_one_of is not None:
        if response.click_element_id not in expectations.click_id_one_of:
            failures.append(
                f"click={response.click_element_id}, expected one of {expectations.click_id_one_of}"
            )

    spoken_lower = response.spoken_text.lower()

    for required_token in expectations.spoken_must_contain:
        if required_token not in spoken_lower:
            failures.append(f'spoken missing "{required_token}"')

    for forbidden_token in expectations.spoken_must_not_contain:
        if forbidden_token in spoken_lower:
            failures.append(f'spoken contains forbidden "{forbidden_token}"')

    if expectations.spoken_max_words is not None:
        word_count = len(response.spoken_text.split())
        if word_count > expectations.spoken_max_words:
            failures.append(
                f"spoken {word_count} words (max {expectations.spoken_max_words})"
            )

    return FixtureScore(passed=not failures, failures=failures)


# ---------------------------------------------------------------------------
# Planner adapters
# ---------------------------------------------------------------------------


def build_user_prompt(fixture: Fixture) -> str:
    element_section = fixture.element_map if fixture.element_map else "(no elements detected)"
    return (
        "On-device screen analysis (auto-extracted by a local vision model + native OCR):\n\n"
        "=== primary focus ===\n"
        f"{element_section}\n\n"
        f"User said: {fixture.transcript}"
    )


def run_via_lm_studio(model_identifier: str, fixture: Fixture) -> ModelResponse:
    request_body = {
        "model": model_identifier,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": build_user_prompt(fixture)},
        ],
        "temperature": 0,
        "max_tokens": 400,
        "response_format": RESPONSE_SCHEMA,
        "stream": False,
    }
    request = urllib.request.Request(
        LM_STUDIO_URL,
        data=json.dumps(request_body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer lm-studio",
        },
        method="POST",
    )
    started_at = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=300) as response_stream:
            body = response_stream.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as http_error:
        return ModelResponse(
            spoken_text="",
            point_at_element_id=-99,
            click_element_id=-99,
            elapsed_ms=int((time.monotonic() - started_at) * 1000),
            error=f"HTTP {http_error.code}: {http_error.read().decode('utf-8', errors='replace')[:200]}",
        )
    except (urllib.error.URLError, TimeoutError) as transport_error:
        return ModelResponse(
            spoken_text="",
            point_at_element_id=-99,
            click_element_id=-99,
            elapsed_ms=int((time.monotonic() - started_at) * 1000),
            error=f"transport: {transport_error}",
        )

    elapsed_ms = int((time.monotonic() - started_at) * 1000)

    try:
        payload = json.loads(body)
        raw_content = payload["choices"][0]["message"]["content"]
        # Strip thinking blocks if present (some models leak <think>...</think>)
        cleaned_content = re.sub(
            r"<think>.*?</think>", "", raw_content, flags=re.DOTALL | re.IGNORECASE
        ).strip()
        parsed = json.loads(cleaned_content)
        return ModelResponse(
            spoken_text=parsed.get("spokenText", ""),
            point_at_element_id=int(parsed.get("pointAtElementId", -1)),
            click_element_id=int(parsed.get("clickElementId", -1)),
            elapsed_ms=elapsed_ms,
            raw=raw_content,
        )
    except (json.JSONDecodeError, KeyError, ValueError, TypeError) as parse_error:
        return ModelResponse(
            spoken_text="",
            point_at_element_id=-99,
            click_element_id=-99,
            elapsed_ms=elapsed_ms,
            error=f"parse error: {parse_error} — body head: {body[:200]}",
        )


def run_all_fixtures_via_foundation_models(
    fixtures: list[Fixture],
) -> dict[str, ModelResponse]:
    """Run eval-fm.sh once across all fixtures so we compile the Swift
    inner program a single time, then parse per-fixture sections out of
    its aggregate stdout.

    eval-fm.sh per-fixture stanza format:
      ▶ Fixture: <name>
      ─── PACE FM EVAL ───
      …
      elapsed: <int>ms
      FM typed response:
        spokenText      : <text>
        pointAtElementId: <int>
        clickElementId  : <int>
      ─── END ───
    """
    fixture_names = {fixture.name for fixture in fixtures}
    results: dict[str, ModelResponse] = {}

    try:
        completed = subprocess.run(
            ["bash", str(FM_RUNNER_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=600,
            cwd=str(PROJECT_DIR),
        )
    except subprocess.TimeoutExpired:
        for fixture in fixtures:
            results[fixture.name] = ModelResponse(
                spoken_text="",
                point_at_element_id=-99,
                click_element_id=-99,
                elapsed_ms=0,
                error="FM eval timed out (>600s aggregate)",
            )
        return results

    stdout = completed.stdout
    # Split on the per-fixture header lines.
    stanzas = re.split(r"(?m)^▶ Fixture: ", stdout)
    for stanza in stanzas[1:]:  # first split chunk is before the first header
        first_line, _, rest = stanza.partition("\n")
        fixture_name = first_line.strip()
        if fixture_name not in fixture_names:
            continue
        spoken_match = re.search(r"spokenText\s*:\s*(.+)", rest)
        point_match = re.search(r"pointAtElementId\s*:\s*(-?\d+)", rest)
        click_match = re.search(r"clickElementId\s*:\s*(-?\d+)", rest)
        elapsed_match = re.search(r"^elapsed:\s*(\d+)ms", rest, flags=re.MULTILINE)
        if not (spoken_match and point_match and click_match):
            results[fixture_name] = ModelResponse(
                spoken_text="",
                point_at_element_id=-99,
                click_element_id=-99,
                elapsed_ms=int(elapsed_match.group(1)) if elapsed_match else 0,
                error=f"parse failure — stanza head: {rest[:200]!r}",
            )
            continue
        results[fixture_name] = ModelResponse(
            spoken_text=spoken_match.group(1).strip(),
            point_at_element_id=int(point_match.group(1)),
            click_element_id=int(click_match.group(1)),
            elapsed_ms=int(elapsed_match.group(1)) if elapsed_match else 0,
            raw=rest,
        )

    # Any fixture that ran but didn't appear in the output
    for fixture in fixtures:
        if fixture.name not in results:
            results[fixture.name] = ModelResponse(
                spoken_text="",
                point_at_element_id=-99,
                click_element_id=-99,
                elapsed_ms=0,
                error="fixture missing from FM eval output — stderr head: "
                + completed.stderr[:200],
            )

    return results


# ---------------------------------------------------------------------------
# Model lifecycle (LM Studio)
# ---------------------------------------------------------------------------


def lms_ps_loaded_identifiers() -> list[str]:
    """Returns the identifier column from `lms ps`. Used to detect whether
    a model is already loaded so we don't ask LM Studio to load a second
    copy — that creates a `:2` duplicate slot and wastes ~18 GB of RAM
    on the planner model."""
    completed = subprocess.run(
        [LMS_BIN, "ps"], capture_output=True, text=True, check=False
    )
    if completed.returncode != 0:
        return []
    loaded: list[str] = []
    for line in completed.stdout.splitlines():
        if not line.strip() or line.lower().startswith("identifier"):
            continue
        parts = re.split(r"\s{2,}", line.strip())
        if parts:
            loaded.append(parts[0])
    return loaded


def lms_load(model_identifier: str) -> bool:
    print(f"⬇ loading {model_identifier}…", flush=True)
    completed = subprocess.run(
        [LMS_BIN, "load", model_identifier],
        capture_output=True,
        text=True,
        timeout=600,
    )
    if completed.returncode != 0:
        print(f"   ❌ lms load failed: {completed.stderr.strip()}")
        return False
    print("   ✓ loaded")
    return True


def lms_unload(model_identifier: str) -> None:
    print(f"⬆ unloading {model_identifier}…", flush=True)
    completed = subprocess.run(
        [LMS_BIN, "unload", model_identifier],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if completed.returncode != 0:
        print(f"   ⚠️  lms unload non-zero: {completed.stderr.strip()}")


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------


def evaluate_model_on_fixtures(
    model_identifier: str,
    fixtures: list[Fixture],
    skip_load_unload: bool = False,
) -> dict[str, tuple[ModelResponse, FixtureScore]]:
    results: dict[str, tuple[ModelResponse, FixtureScore]] = {}
    is_fm = model_identifier.lower() in ("fm", "foundation-models", "foundationmodels")

    if is_fm:
        print("  (running all fixtures via eval-fm.sh in one shot — single compile)")
        fm_responses = run_all_fixtures_via_foundation_models(fixtures)
        for fixture in fixtures:
            response = fm_responses[fixture.name]
            score = score_fixture(response, fixture.expectations)
            results[fixture.name] = (response, score)
            verdict = "PASS" if score.passed else "FAIL"
            print(
                f"  {verdict}  {fixture.name}  point={response.point_at_element_id}  "
                f"click={response.click_element_id}  spoken={response.spoken_text!r}"
            )
            if not score.passed:
                for failure_reason in score.failures:
                    print(f"      · {failure_reason}")
        return results

    # Skip load/unload entirely when the caller already manages it (e.g.
    # diag-pace.py loaded both VLM and planner before delegating to us)
    # OR when the model is already resident (avoids creating a duplicate
    # `<name>:2` slot which silently eats ~18 GB and breaks routing).
    we_loaded_the_model = False
    if not skip_load_unload:
        already_loaded_identifiers = lms_ps_loaded_identifiers()
        if model_identifier in already_loaded_identifiers:
            print(f"  ✓ {model_identifier} already resident — skipping lms load")
        elif not lms_load(model_identifier):
            for fixture in fixtures:
                results[fixture.name] = (
                    ModelResponse(
                        spoken_text="",
                        point_at_element_id=-99,
                        click_element_id=-99,
                        elapsed_ms=0,
                        error="model failed to load",
                    ),
                    FixtureScore(passed=False, failures=["load failed"]),
                )
            return results
        else:
            we_loaded_the_model = True

    try:
        for fixture in fixtures:
            print(f"  ▶ {fixture.name}…", flush=True)
            response = run_via_lm_studio(model_identifier, fixture)
            score = score_fixture(response, fixture.expectations)
            results[fixture.name] = (response, score)
            verdict = "PASS" if score.passed else "FAIL"
            print(
                f"    {verdict}  point={response.point_at_element_id}  "
                f"click={response.click_element_id}  spoken={response.spoken_text!r}"
            )
            if not score.passed:
                for failure_reason in score.failures:
                    print(f"      · {failure_reason}")
    finally:
        # Only unload if we were the ones who loaded it. Don't evict a
        # model some other caller (Pace.app, diag-pace.py, the user) is
        # actively using.
        if we_loaded_the_model:
            lms_unload(model_identifier)

    return results


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Head-to-head planner comparison on Pace's FM-fixture set.",
    )
    parser.add_argument(
        "--models",
        nargs="+",
        required=True,
        help='Model identifiers. Use "fm" for Apple Foundation Models; any other '
        "name is treated as an LM Studio model id (will be loaded/unloaded "
        "automatically via `lms`).",
    )
    parser.add_argument(
        "--fixtures-only",
        nargs="*",
        default=None,
        help="If set, only run the named fixtures (without .txt extension).",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="If set, write the markdown scorecard here in addition to stdout.",
    )
    parser.add_argument(
        "--no-load",
        action="store_true",
        help="Skip lms load / lms unload — assume the caller has already "
        "ensured the model is resident. Use this when chaining from "
        "diag-pace.py so the planner isn't double-loaded into a `:2` slot.",
    )
    args = parser.parse_args(argv)

    fixture_paths = sorted(FIXTURES_DIR.glob("*.txt"))
    fixtures = [parse_fixture(path) for path in fixture_paths]

    if args.fixtures_only:
        wanted = set(args.fixtures_only)
        fixtures = [f for f in fixtures if f.name in wanted]
        if not fixtures:
            print(f"❌ no fixtures matched {args.fixtures_only}", file=sys.stderr)
            return 2

    scored_fixtures = [f for f in fixtures if f.expectations.has_any_check]
    unscored_fixtures = [f for f in fixtures if not f.expectations.has_any_check]
    if unscored_fixtures:
        print(
            "ℹ️  fixtures without EXPECT_* (will be informational only): "
            + ", ".join(f.name for f in unscored_fixtures)
        )

    all_results: dict[str, dict[str, tuple[ModelResponse, FixtureScore]]] = {}

    for model_identifier in args.models:
        print(f"\n══════════════ {model_identifier} ══════════════", flush=True)
        all_results[model_identifier] = evaluate_model_on_fixtures(
            model_identifier, fixtures, skip_load_unload=args.no_load
        )

    # ---- Markdown scorecard ----
    lines: list[str] = []
    lines.append("\n## Pace planner comparison\n")
    header_cells = ["Fixture"] + args.models
    lines.append("| " + " | ".join(header_cells) + " |")
    lines.append("|" + "|".join(["---"] * len(header_cells)) + "|")

    for fixture in fixtures:
        row = [fixture.name]
        for model_identifier in args.models:
            response, score = all_results[model_identifier][fixture.name]
            if not fixture.expectations.has_any_check:
                row.append(f"{response.elapsed_ms}ms (no checks)")
            elif score.passed:
                row.append(f"✓ {response.elapsed_ms}ms")
            else:
                failure_summary = "; ".join(score.failures)[:80]
                row.append(f"✗ {response.elapsed_ms}ms — {failure_summary}")
        lines.append("| " + " | ".join(row) + " |")

    lines.append("")
    summary_rows: list[str] = []
    for model_identifier in args.models:
        passed_count = sum(
            1
            for f in scored_fixtures
            if all_results[model_identifier][f.name][1].passed
        )
        total_scored = len(scored_fixtures)
        latencies = [
            all_results[model_identifier][f.name][0].elapsed_ms
            for f in fixtures
            if all_results[model_identifier][f.name][0].error is None
        ]
        mean_ms = int(sum(latencies) / len(latencies)) if latencies else 0
        summary_rows.append(
            f"- **{model_identifier}**: {passed_count}/{total_scored} pass, "
            f"mean latency {mean_ms}ms"
        )

    lines.append("### Summary\n")
    lines.extend(summary_rows)

    output_text = "\n".join(lines)
    print(output_text)

    if args.output:
        Path(args.output).write_text(output_text)
        print(f"\nWrote scorecard to {args.output}")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
