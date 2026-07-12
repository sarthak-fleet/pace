#!/usr/bin/env python3
"""
eval-vlm-grounding.py — real-VLM grounding eval over the fm-vlm-fixtures-v1
corpus, using REAL captured screenshots.

Why this exists
---------------
fm-vlm-fixtures-v1/README.md documents an AX+OCR rule-based baseline
(tinygpt/scripts/fake_pace_vlm.py) and a >30 percentage-point acceptance bar:
the real VLM must beat that baseline by >30pp on AX-blind cases to justify its
existence. But the "real VLM" column was never wired — the fixtures shipped
without screenshots. scripts/capture-grounding-corpus.sh now attaches real
screenshots; this script runs the full grounding flow on them.

For each fixture that carries a `SCREENSHOT_PATH`, it runs three stages against
LM Studio, replicating the Swift paths:
  (a) Element-map extraction — LocalVLMClient.analyzeScreenshot's prompt +
      response shape (leanring-buddy/LocalVLMClient.swift L316-436).
  (b) Target-found check — does the extracted element map contain an element
      whose label/text plausibly matches the fixture's expected target
      (from SPOKEN_MUST_CONTAIN / the USER instruction), with a well-formed
      bbox inside the image?
  (c) Set-of-Mark mark-reading — render the extracted element map's marks with
      the SAME convention as PaceSetOfMarkRenderer (reused from
      eval-vlm-mark-reading.py) and ask the VLM which mark is on the target
      (groundMarkedClickTarget's prompt), then check the returned mark lands on
      the matched element.

It scores per fixture and prints an accuracy table with an AX-blind-only row,
compared against the AX+OCR baseline the fixture files record (BASELINE_PASS).

Graceful degradation: if ZERO fixtures have screenshots, it prints the
capture-helper instruction and exits 0 (nothing to measure yet, not an error).
If LM Studio is down while there ARE screenshots, it fails loud and exits
nonzero — never fabricates results.

Usage
-----
  ./scripts/eval-vlm-grounding.py
  ./scripts/eval-vlm-grounding.py --model qwen3-vl-8b-instruct
  ./scripts/eval-vlm-grounding.py --fixtures-only ax-blind-figma-export
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
FIXTURES_DIR = PROJECT_DIR / "evals" / "fm-vlm-fixtures-v1"
LM_STUDIO_URL = os.environ.get(
    "PACE_LM_STUDIO_URL", "http://localhost:1234/v1/chat/completions"
)
DEFAULT_MODEL = "ui-venus-1.5-2b"

# Reuse the Set-of-Mark renderer replica + grounding helpers from the
# mark-reading micro-eval so both scripts draw marks the ONE way that matches
# PaceSetOfMarkRenderer, and parse the grounding reply the ONE way that matches
# LocalVLMClient.parseGroundedMarkNumber.
sys.path.insert(0, str(SCRIPT_DIR))
try:
    import importlib

    _mark_reading_module = importlib.import_module("eval-vlm-mark-reading")
except ModuleNotFoundError:  # pragma: no cover
    _spec = importlib.util.spec_from_file_location(  # type: ignore[attr-defined]
        "eval_vlm_mark_reading", SCRIPT_DIR / "eval-vlm-mark-reading.py"
    )
    _mark_reading_module = importlib.util.module_from_spec(_spec)  # type: ignore[attr-defined]
    _spec.loader.exec_module(_mark_reading_module)  # type: ignore[union-attr]

replicate_set_of_mark_renderer = _mark_reading_module.replicate_set_of_mark_renderer
build_grounding_system_prompt = _mark_reading_module.build_grounding_system_prompt
build_grounding_user_message = _mark_reading_module.build_grounding_user_message
parse_grounded_mark_number = _mark_reading_module.parse_grounded_mark_number
lm_studio_is_reachable = _mark_reading_module.lm_studio_is_reachable

from PIL import Image  # noqa: E402  (import after path insert on purpose)


# ---------------------------------------------------------------------------
# Fixture parsing
# ---------------------------------------------------------------------------


@dataclass
class GroundingFixture:
    name: str
    user_instruction: str
    app_frontmost: str
    ax_blind: bool
    screenshot_path: Optional[str]
    spoken_must_contain: list[str] = field(default_factory=list)
    # The AX+OCR baseline verdict for this fixture, if recorded. Fixture files
    # may carry `BASELINE_PASS: true|false` from a FakePaceVLM run. When absent
    # we fall back to the README's category rule: ax-blind-* baseline fails.
    baseline_pass: Optional[bool] = None

    @property
    def is_ax_blind(self) -> bool:
        return self.ax_blind or self.name.startswith("ax-blind-")

    @property
    def baseline_pass_effective(self) -> bool:
        """Recorded baseline if present; else the README category rule
        (ax-blind fixtures fail the AX+OCR baseline, everything else passes)."""
        if self.baseline_pass is not None:
            return self.baseline_pass
        return not self.is_ax_blind


def parse_grounding_fixture(path: Path) -> GroundingFixture:
    user_instruction = ""
    app_frontmost = ""
    ax_blind = False
    screenshot_path: Optional[str] = None
    spoken_must_contain: list[str] = []
    baseline_pass: Optional[bool] = None

    with path.open() as fixture_file:
        for raw_line in fixture_file:
            line = raw_line.rstrip("\n")
            if line.startswith("USER: "):
                user_instruction = line[len("USER: ") :]
            elif line.startswith("APP_FRONTMOST: "):
                app_frontmost = line[len("APP_FRONTMOST: ") :].strip()
            elif line.startswith("AX_BLIND: "):
                ax_blind = line[len("AX_BLIND: ") :].strip().lower() in (
                    "true",
                    "1",
                    "yes",
                )
            elif line.startswith("SCREENSHOT_PATH: "):
                candidate = line[len("SCREENSHOT_PATH: ") :].strip()
                screenshot_path = candidate if candidate else None
            elif line.startswith("SPOKEN_MUST_CONTAIN: "):
                spoken_must_contain = [
                    token.strip().lower()
                    for token in line[len("SPOKEN_MUST_CONTAIN: ") :].split(",")
                    if token.strip()
                ]
            elif line.startswith("BASELINE_PASS: "):
                baseline_pass = line[len("BASELINE_PASS: ") :].strip().lower() in (
                    "true",
                    "1",
                    "yes",
                )

    return GroundingFixture(
        name=path.stem,
        user_instruction=user_instruction,
        app_frontmost=app_frontmost,
        ax_blind=ax_blind,
        screenshot_path=screenshot_path,
        spoken_must_contain=spoken_must_contain,
        baseline_pass=baseline_pass,
    )


# ---------------------------------------------------------------------------
# Stage (a): element-map extraction — LocalVLMClient.analyzeScreenshot replica.
# ---------------------------------------------------------------------------

# Byte-for-byte the systemInstruction from analyzeScreenshot (Swift L334-353).
ANALYZE_SYSTEM_PROMPT = (
    "You are a UI vision model. Output STRICT JSON only — no prose, no "
    "markdown fences, no commentary outside the JSON object.\n\n"
    "Schema. `elements` FIRST, `description` LAST and SHORT:\n"
    '{"elements":[{"label":"<≤4 words>","role":"<button|text_field|static_text|link|image|menu_item|checkbox|tab|other>","bbox":[<x>,<y>,<w>,<h>],"text":"<verbatim or null>"}],"description":"<≤20 words, app + main view>"}\n\n'
    "HARD FORMATTING RULES — failure to follow these causes truncation:\n"
    "- Compact JSON only. NO indentation, NO newlines inside the object. "
    "One element per line is fine; multi-line per element is NOT.\n"
    "- No trailing commas. Strings double-quoted. `text:null` (not "
    '`text:"null"`) for non-text elements.\n'
    "- Coordinates are screen pixels, top-left origin.\n\n"
    "CONTENT RULES:\n"
    "- `description` is one terse sentence, not a paragraph.\n"
    "- Prefer high recall on interactive elements (buttons, fields, "
    "links, tabs). Skip purely decorative chrome.\n"
    "- If the user intent below names a target, list that element first."
)


@dataclass
class ExtractedElement:
    label: str
    role: str
    bbox: list[int]
    text: Optional[str]


def _sanitize_role_value(raw_role: str) -> str:
    """Port of LocalVLMScreenElement.sanitizeRoleValue (Swift L58-64): collapse
    a pipe-joined composite role to its first non-empty token."""
    tokens = [token.strip() for token in raw_role.split("|") if token.strip()]
    return tokens[0] if tokens else raw_role.strip()


def _extract_json_object_string(raw_content: str) -> str:
    """Port of LocalVLMClient.extractJSONObjectString (Swift L535-579): pull the
    first balanced {...} block out of possibly-fenced / prose-wrapped output."""
    trimmed = raw_content.strip()
    if trimmed.startswith("{") and trimmed.endswith("}"):
        return trimmed
    # Strip a ```json ... ``` fence.
    fence_start = trimmed.find("```")
    if fence_start != -1:
        fence_end = trimmed.find("```", fence_start + 3)
        if fence_end != -1:
            body = trimmed[fence_start + 3 : fence_end]
            first_newline = body.find("\n")
            if first_newline != -1 and body[:first_newline].strip().lower() == "json":
                body = body[first_newline + 1 :]
            return body.strip()
    # Greedy balanced-brace match.
    first_brace = trimmed.find("{")
    if first_brace != -1:
        depth = 0
        for cursor in range(first_brace, len(trimmed)):
            if trimmed[cursor] == "{":
                depth += 1
            elif trimmed[cursor] == "}":
                depth -= 1
                if depth == 0:
                    return trimmed[first_brace : cursor + 1]
    return trimmed


@dataclass
class AnalyzeResult:
    elements: list[ExtractedElement]
    description: str
    elapsed_ms: int
    raw_reply: str = ""
    error: Optional[str] = None


def run_analyze_screenshot(
    model_identifier: str, screenshot_png: bytes, user_intent: str
) -> AnalyzeResult:
    """Replicates LocalVLMClient.analyzeScreenshot's request (Swift L316-436):
    temperature 0.1, max_tokens 4096, image as a base64 data URL, no
    response_format (LM Studio MLX rejects json_object)."""
    media_type = "image/png" if screenshot_png[:4] == b"\x89PNG" else "image/jpeg"
    image_data_url = (
        f"data:{media_type};base64,"
        + base64.b64encode(screenshot_png).decode("ascii")
    )
    request_body = {
        "model": model_identifier,
        "messages": [
            {"role": "system", "content": ANALYZE_SYSTEM_PROMPT},
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": f"User intent: {user_intent}\n\nAnalyse the screenshot and return the JSON element map.",
                    },
                    {"type": "image_url", "image_url": {"url": image_data_url}},
                ],
            },
        ],
        "temperature": 0.1,
        "max_tokens": 4096,
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
        return AnalyzeResult(
            elements=[],
            description="",
            elapsed_ms=int((time.monotonic() - started_at) * 1000),
            error=f"HTTP {http_error.code}: {http_error.read().decode('utf-8', errors='replace')[:200]}",
        )
    except (urllib.error.URLError, TimeoutError) as transport_error:
        return AnalyzeResult(
            elements=[],
            description="",
            elapsed_ms=int((time.monotonic() - started_at) * 1000),
            error=f"transport: {transport_error}",
        )

    elapsed_ms = int((time.monotonic() - started_at) * 1000)
    try:
        payload = json.loads(body)
        raw_content = payload["choices"][0]["message"]["content"]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as parse_error:
        return AnalyzeResult(
            elements=[],
            description="",
            elapsed_ms=elapsed_ms,
            error=f"envelope parse error: {parse_error}",
        )

    json_string = _extract_json_object_string(raw_content)
    try:
        analysis = json.loads(json_string)
    except json.JSONDecodeError as decode_error:
        return AnalyzeResult(
            elements=[],
            description="",
            elapsed_ms=elapsed_ms,
            raw_reply=raw_content[:400],
            error=f"element-map JSON decode error: {decode_error}",
        )

    extracted: list[ExtractedElement] = []
    for element_dict in analysis.get("elements", []):
        if not isinstance(element_dict, dict):
            continue
        bbox_raw = element_dict.get("bbox", [])
        # Coerce bbox to ints where possible; keep only well-formed 4-tuples.
        try:
            bbox = [int(round(float(value))) for value in bbox_raw]
        except (TypeError, ValueError):
            bbox = []
        extracted.append(
            ExtractedElement(
                label=str(element_dict.get("label", "")),
                role=_sanitize_role_value(str(element_dict.get("role", "other"))),
                bbox=bbox,
                text=(
                    str(element_dict["text"])
                    if element_dict.get("text") is not None
                    else None
                ),
            )
        )

    return AnalyzeResult(
        elements=extracted,
        description=str(analysis.get("description", "")),
        elapsed_ms=elapsed_ms,
        raw_reply=raw_content[:400],
    )


# ---------------------------------------------------------------------------
# Stage (b): target-found check.
# ---------------------------------------------------------------------------


def _bbox_is_well_formed(bbox: list[int], image_width: int, image_height: int) -> bool:
    if len(bbox) != 4:
        return False
    element_x, element_y, element_width, element_height = bbox
    if element_width <= 0 or element_height <= 0:
        return False
    # Must sit at least partially inside the image.
    if element_x >= image_width or element_y >= image_height:
        return False
    if element_x + element_width <= 0 or element_y + element_height <= 0:
        return False
    return True


def find_target_element_index(
    elements: list[ExtractedElement],
    target_tokens: list[str],
    image_width: int,
    image_height: int,
) -> Optional[int]:
    """Return the index of the first extracted element whose label/text matches
    any of `target_tokens` (case-insensitive substring) AND has a well-formed
    in-bounds bbox. `target_tokens` come from the fixture's SPOKEN_MUST_CONTAIN,
    which names the thing the answer must reference (e.g. "export", "send")."""
    if not target_tokens:
        return None
    for element_index, element in enumerate(elements):
        if not _bbox_is_well_formed(element.bbox, image_width, image_height):
            continue
        haystack = (element.label + " " + (element.text or "")).lower()
        if any(token in haystack for token in target_tokens):
            return element_index
    return None


# ---------------------------------------------------------------------------
# Stage (c): Set-of-Mark mark-reading on the extracted element map.
# ---------------------------------------------------------------------------


def run_mark_reading_stage(
    model_identifier: str,
    screenshot_image: "Image.Image",
    elements: list[ExtractedElement],
    target_description: str,
) -> tuple[Optional[int], str, int]:
    """Render marks for every element with a well-formed bbox (mark index =
    element index, matching PaceSetOfMarkClickRecovery), then ask the VLM which
    mark is on the target. Returns (predicted_mark, raw_reply, elapsed_ms)."""
    image_width, image_height = screenshot_image.size
    boxes = [
        (element_index, element.bbox)
        for element_index, element in enumerate(elements)
        if _bbox_is_well_formed(element.bbox, image_width, image_height)
    ]
    if not boxes:
        return None, "(no well-formed boxes to mark)", 0

    marked_image = replicate_set_of_mark_renderer(screenshot_image, boxes)
    import io

    png_buffer = io.BytesIO()
    marked_image.save(png_buffer, format="PNG")
    marked_png = png_buffer.getvalue()

    mark_count = len(elements)
    image_data_url = "data:image/png;base64," + base64.b64encode(marked_png).decode(
        "ascii"
    )
    request_body = {
        "model": model_identifier,
        "messages": [
            {"role": "system", "content": build_grounding_system_prompt(mark_count)},
            {
                "role": "user",
                "content": build_grounding_user_message(
                    target_description, image_data_url
                ),
            },
        ],
        "temperature": 0,
        "max_tokens": 16,
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
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
        return None, f"error: {error}", int((time.monotonic() - started_at) * 1000)

    elapsed_ms = int((time.monotonic() - started_at) * 1000)
    try:
        payload = json.loads(body)
        raw_content = payload["choices"][0]["message"]["content"]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError):
        return None, body[:120], elapsed_ms
    predicted = parse_grounded_mark_number(raw_content, mark_count)
    return predicted, raw_content.strip(), elapsed_ms


# ---------------------------------------------------------------------------
# Per-fixture scoring.
# ---------------------------------------------------------------------------


@dataclass
class FixtureGroundingResult:
    fixture_name: str
    is_ax_blind: bool
    baseline_pass: bool
    element_count: int
    target_found_index: Optional[int]
    predicted_mark: Optional[int]
    grounding_correct: bool
    total_ms: int
    error: Optional[str] = None
    note: str = ""


def evaluate_fixture(
    model_identifier: str, fixture: GroundingFixture
) -> FixtureGroundingResult:
    screenshot_absolute = FIXTURES_DIR / fixture.screenshot_path  # type: ignore[arg-type]
    if not screenshot_absolute.is_file():
        return FixtureGroundingResult(
            fixture_name=fixture.name,
            is_ax_blind=fixture.is_ax_blind,
            baseline_pass=fixture.baseline_pass_effective,
            element_count=0,
            target_found_index=None,
            predicted_mark=None,
            grounding_correct=False,
            total_ms=0,
            error=f"screenshot missing on disk: {fixture.screenshot_path}",
        )

    screenshot_png = screenshot_absolute.read_bytes()
    screenshot_image = Image.open(screenshot_absolute).convert("RGB")
    image_width, image_height = screenshot_image.size

    # Stage (a) — element-map extraction.
    analyze = run_analyze_screenshot(
        model_identifier, screenshot_png, fixture.user_instruction
    )
    if analyze.error:
        return FixtureGroundingResult(
            fixture_name=fixture.name,
            is_ax_blind=fixture.is_ax_blind,
            baseline_pass=fixture.baseline_pass_effective,
            element_count=0,
            target_found_index=None,
            predicted_mark=None,
            grounding_correct=False,
            total_ms=analyze.elapsed_ms,
            error=f"analyze: {analyze.error}",
        )

    # Stage (b) — target-found check.
    target_index = find_target_element_index(
        analyze.elements,
        fixture.spoken_must_contain,
        image_width,
        image_height,
    )

    # Stage (c) — Set-of-Mark mark-reading. The target description is the raw
    # user instruction, mirroring PaceSetOfMarkClickRecovery.Inputs.targetDescription.
    predicted_mark, mark_raw, mark_ms = run_mark_reading_stage(
        model_identifier,
        screenshot_image,
        analyze.elements,
        fixture.user_instruction,
    )

    # Grounding is "correct" when the model's chosen mark lands on the element
    # we independently matched to the target. If we couldn't even find the
    # target in the map, grounding can't be correct (the whole point of the
    # AX-blind cases: an AX+OCR baseline can't locate the element at all).
    grounding_correct = (
        target_index is not None
        and predicted_mark is not None
        and predicted_mark == target_index
    )

    note_parts = []
    if target_index is None:
        note_parts.append("target not found in element map")
    if predicted_mark is None:
        note_parts.append("no valid mark returned")
    note = "; ".join(note_parts) + (f" | mark_reply={mark_raw!r}" if note_parts else "")

    return FixtureGroundingResult(
        fixture_name=fixture.name,
        is_ax_blind=fixture.is_ax_blind,
        baseline_pass=fixture.baseline_pass_effective,
        element_count=len(analyze.elements),
        target_found_index=target_index,
        predicted_mark=predicted_mark,
        grounding_correct=grounding_correct,
        total_ms=analyze.elapsed_ms + mark_ms,
        note=note if not grounding_correct else "",
    )


# ---------------------------------------------------------------------------
# Reporting.
# ---------------------------------------------------------------------------


def print_grounding_report(
    model_identifier: str, results: list[FixtureGroundingResult]
) -> None:
    print("\n## Real-VLM grounding accuracy\n")
    print("| Fixture | AX-blind | Baseline | VLM grounded | Elements | ms | Note |")
    print("|---|---|---|---|---|---|---|")
    for result in results:
        baseline_cell = "pass" if result.baseline_pass else "FAIL"
        vlm_cell = "✓" if result.grounding_correct else "✗"
        if result.error:
            vlm_cell = "! " + result.error[:60]
        print(
            f"| {result.fixture_name} "
            f"| {'yes' if result.is_ax_blind else 'no'} "
            f"| {baseline_cell} "
            f"| {vlm_cell} "
            f"| {result.element_count} "
            f"| {result.total_ms} "
            f"| {result.note[:60]} |"
        )

    total = len(results)
    vlm_correct = sum(1 for result in results if result.grounding_correct)
    baseline_correct = sum(1 for result in results if result.baseline_pass)

    ax_blind_results = [result for result in results if result.is_ax_blind]
    ax_blind_total = len(ax_blind_results)
    ax_blind_vlm = sum(1 for result in ax_blind_results if result.grounding_correct)
    ax_blind_baseline = sum(1 for result in ax_blind_results if result.baseline_pass)

    def as_pct(numerator: int, denominator: int) -> float:
        return (100.0 * numerator / denominator) if denominator else 0.0

    print("\n### Summary\n")
    print(f"- **Model**: {model_identifier}")
    print(
        f"- **All fixtures**: VLM {vlm_correct}/{total} "
        f"({as_pct(vlm_correct, total):.1f}%) vs "
        f"AX+OCR baseline {baseline_correct}/{total} "
        f"({as_pct(baseline_correct, total):.1f}%)"
    )
    if ax_blind_total:
        vlm_pct = as_pct(ax_blind_vlm, ax_blind_total)
        baseline_pct = as_pct(ax_blind_baseline, ax_blind_total)
        delta_pp = vlm_pct - baseline_pct
        print(
            f"- **AX-blind only**: VLM {ax_blind_vlm}/{ax_blind_total} "
            f"({vlm_pct:.1f}%) vs baseline {ax_blind_baseline}/{ax_blind_total} "
            f"({baseline_pct:.1f}%) — delta {delta_pp:+.1f}pp"
        )
        # Acceptance bar from fm-vlm-fixtures-v1/README.md: >30pp on AX-blind.
        verdict = "MEETS" if delta_pp > 30.0 else "BELOW"
        print(
            f"- **Acceptance bar (>30pp on AX-blind)**: {verdict} "
            f"(delta {delta_pp:+.1f}pp)"
        )
    else:
        print(
            "- **AX-blind only**: no AX-blind fixtures had screenshots yet — "
            "capture ax-blind-* fixtures to measure the bar that matters most."
        )


# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Real-VLM grounding eval over fm-vlm-fixtures-v1 screenshots.",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"LM Studio VLM model id (default {DEFAULT_MODEL}).",
    )
    parser.add_argument(
        "--fixtures-only",
        nargs="*",
        default=None,
        help="Only run the named fixtures (without .txt).",
    )
    parser.add_argument(
        "--fixtures-dir",
        default=str(FIXTURES_DIR),
        help="Fixtures directory (default evals/fm-vlm-fixtures-v1).",
    )
    args = parser.parse_args(argv)

    fixtures_directory = Path(args.fixtures_dir)
    if not fixtures_directory.is_dir():
        print(f"❌ fixtures dir not found: {fixtures_directory}", file=sys.stderr)
        return 2

    fixture_paths = sorted(
        path
        for path in fixtures_directory.glob("*.txt")
        if not path.name.startswith("README")
    )
    fixtures = [parse_grounding_fixture(path) for path in fixture_paths]

    if args.fixtures_only:
        wanted = set(args.fixtures_only)
        fixtures = [fixture for fixture in fixtures if fixture.name in wanted]

    fixtures_with_screenshots = [
        fixture for fixture in fixtures if fixture.screenshot_path
    ]

    if not fixtures_with_screenshots:
        print(
            "No fixtures carry a SCREENSHOT_PATH yet, so there is nothing for the "
            "real VLM to ground against.\n\n"
            "Capture real screenshots first:\n"
            "  ./scripts/capture-grounding-corpus.sh --status   # see what's missing\n"
            "  ./scripts/capture-grounding-corpus.sh            # capture them\n\n"
            "Then re-run this eval:\n"
            "  ./scripts/eval-vlm-grounding.py"
        )
        return 0

    reachable, detail = lm_studio_is_reachable()
    if not reachable:
        print(
            f"\n❌ LM Studio is unreachable at {LM_STUDIO_URL} ({detail}).\n"
            f"   Start LM Studio and load the VLM: {args.model}\n"
            "   (LM Studio → Developer → Start Server, port 1234.)\n"
            "   No results were fabricated.",
            file=sys.stderr,
        )
        return 1

    print(
        f"Running {len(fixtures_with_screenshots)} fixture(s) with screenshots "
        f"against {args.model}…"
    )
    results: list[FixtureGroundingResult] = []
    for fixture in fixtures_with_screenshots:
        print(f"  ▶ {fixture.name}…", flush=True)
        result = evaluate_fixture(args.model, fixture)
        verdict = "✓" if result.grounding_correct else "✗"
        if result.error:
            verdict = "!"
        print(
            f"    {verdict} grounded={result.grounding_correct} "
            f"target_idx={result.target_found_index} mark={result.predicted_mark} "
            f"({result.total_ms}ms)"
            + (f" — {result.error}" if result.error else "")
        )
        results.append(result)

    print_grounding_report(args.model, results)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
