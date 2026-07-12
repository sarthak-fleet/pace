#!/usr/bin/env python3
"""
eval-vlm-mark-reading.py — synthetic micro-eval for Pace's Set-of-Mark
click-recovery grounding step.

Why this exists
---------------
Pace's Set-of-Mark click recovery (leanring-buddy/PaceSetOfMarkRenderer.swift,
PaceSetOfMarkClickRecovery.swift, LocalVLMClient.groundMarkedClickTarget) draws
numbered magenta marks on a screenshot and asks the local VLM which mark sits on
a target element. The VLM's mark-READING accuracy — "can it even read the number
drawn on the box I mean?" — has never been measured. This script isolates that
one skill on deterministic synthetic UI screenshots where we know the ground
truth exactly, so a bad grounding number can be blamed on mark-reading vs.
element-map extraction vs. planner reasoning.

What it does
------------
  1. Generates deterministic synthetic app-window mockups (PIL) with a toolbar,
     sidebar, text-labelled buttons, text fields, and checkboxes. 12 distinct
     layouts, element counts varying 5..15.
  2. Draws numbered magenta marks EXACTLY the way PaceSetOfMarkRenderer draws
     them (systemPink 2px outline, white-on-systemPink index chip at the box's
     top-left, top-left-origin coordinates). See replicate_set_of_mark_renderer.
  3. For each (marked image, target label, ground-truth mark index): POSTs to
     LM Studio /v1/chat/completions with the SAME prompt shape as
     LocalVLMClient.groundMarkedClickTarget (temperature 0, max_tokens 16, image
     as a base64 data URL) and scores exact integer match.
  4. Prints a per-model accuracy table plus a per-case CSV dump.

If LM Studio is unreachable it prints a clear "start LM Studio and load <model>"
message and exits nonzero — it never fabricates results.

Usage
-----
  # Single model (default ui-venus-1.5-2b)
  ./scripts/eval-vlm-mark-reading.py

  # Explicit model
  ./scripts/eval-vlm-mark-reading.py --model qwen3-vl-8b-instruct

  # Several models in one run
  ./scripts/eval-vlm-mark-reading.py --models ui-venus-1.5-2b,qwen3-vl-8b-instruct

  # Just generate the synthetic images to a dir and inspect them (no model)
  ./scripts/eval-vlm-mark-reading.py --generate-only --image-dir /tmp/marks
"""

from __future__ import annotations

import argparse
import base64
import csv
import io
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

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover - Pillow is a hard requirement.
    print(
        "❌ Pillow is required to generate synthetic screenshots.\n"
        "   Install it with:  pip3 install --user pillow",
        file=sys.stderr,
    )
    sys.exit(2)

# ---------------------------------------------------------------------------
# Locations / defaults
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
LM_STUDIO_URL = os.environ.get(
    "PACE_LM_STUDIO_URL", "http://localhost:1234/v1/chat/completions"
)
DEFAULT_MODEL = "ui-venus-1.5-2b"

# ---------------------------------------------------------------------------
# Set-of-Mark renderer convention — replicated from Swift.
#
# PaceSetOfMarkRenderer.swift draws each mark as:
#   - A 2.0-px stroke rectangle in NSColor.systemPink       (drawBoxOutline, L138-145)
#   - A filled systemPink "chip" at the box's TOP-LEFT      (drawIndexLabel,  L149-197)
#     sized to the rendered index text + labelPadding (=2) on each side of the
#     width and labelPadding vertically; the index is drawn in bold white text.
#   - Coordinates are TOP-LEFT origin, y grows DOWN (bbox = [x, y, w, h],
#     see PaceSetOfMarkBox doc-comment L14-20). PIL's origin is also top-left,
#     so — unlike the Swift NSBitmapImageRep path which must y-flip (L50-69) —
#     we pass coordinates straight through.
#
# NSColor.systemPink in sRGB is approximately RGB(255, 45, 85). That is the
# "magenta" the model is told to look for in groundMarkedClickTarget's prompt
# ("numbered magenta marks").
# ---------------------------------------------------------------------------

SYSTEM_PINK_RGB = (255, 45, 85)
MARK_OUTLINE_WIDTH = 2
MARK_LABEL_FONT_SIZE = 11
MARK_LABEL_PADDING = 2


def _load_bold_label_font() -> ImageFont.ImageFont:
    """PaceSetOfMarkRenderer uses NSFont.boldSystemFont(ofSize: 11). Match the
    size and weight as closely as PIL allows; fall back gracefully if no bold
    TrueType face is on the box so the generator never hard-fails."""
    bold_font_candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/HelveticaNeue.ttc",
        "/Library/Fonts/Arial Bold.ttf",
    ]
    for font_path in bold_font_candidates:
        if Path(font_path).exists():
            try:
                return ImageFont.truetype(font_path, MARK_LABEL_FONT_SIZE)
            except OSError:
                continue
    # Bitmap default font — still legible for single/double digits.
    return ImageFont.load_default()


def _measure_text(
    draw: "ImageDraw.ImageDraw", text: str, font: "ImageFont.ImageFont"
) -> tuple[float, float]:
    """Return (width, height) of `text` for the current Pillow, which dropped
    the old textsize() API in favour of textbbox()."""
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    return (right - left, bottom - top)


def replicate_set_of_mark_renderer(
    base_image: "Image.Image", boxes: list[tuple[int, list[int]]]
) -> "Image.Image":
    """Draw numbered magenta marks onto `base_image`, replicating
    PaceSetOfMarkRenderer.drawMarks. `boxes` is a list of (index, [x, y, w, h])
    in top-left-origin pixels. Returns a NEW image (does not mutate input)."""
    marked_image = base_image.convert("RGB").copy()
    draw = ImageDraw.Draw(marked_image)
    label_font = _load_bold_label_font()

    image_pixel_width, image_pixel_height = marked_image.size

    for mark_index, bbox in boxes:
        if len(bbox) != 4:
            continue
        bbox_x, bbox_y, bbox_width, bbox_height = bbox
        if bbox_width <= 0 or bbox_height <= 0:
            continue

        # Clamp to image bounds — mirrors drawSingleMark's clamp (Swift L112-119).
        clamped_x = max(0, min(bbox_x, image_pixel_width - 1))
        clamped_y = max(0, min(bbox_y, image_pixel_height - 1))
        clamped_right = max(clamped_x, min(bbox_x + bbox_width, image_pixel_width))
        clamped_bottom = max(clamped_y, min(bbox_y + bbox_height, image_pixel_height))
        clamped_width = clamped_right - clamped_x
        clamped_height = clamped_bottom - clamped_y
        if clamped_width <= 0 or clamped_height <= 0:
            continue

        # --- Box outline: 2px systemPink stroke (Swift drawBoxOutline). ---
        # Pillow strokes centred on the path; the Swift stroke is centred too,
        # so a rectangle from (x,y) to (x+w, y+h) matches closely enough for a
        # model to read. We draw the rect edge-inclusive.
        outline_rect = [
            clamped_x,
            clamped_y,
            clamped_x + clamped_width,
            clamped_y + clamped_height,
        ]
        draw.rectangle(
            outline_rect, outline=SYSTEM_PINK_RGB, width=MARK_OUTLINE_WIDTH
        )

        # --- Index chip: white text on filled systemPink, top-left corner. ---
        label_text = str(mark_index)
        text_width, text_height = _measure_text(draw, label_text, label_font)
        # Swift: chipWidth = textW + padding*2 ; chipHeight = textH + padding.
        chip_width = text_width + MARK_LABEL_PADDING * 2
        chip_height = text_height + MARK_LABEL_PADDING

        # Swift clamps the chip so it stays fully inside the image (L173-176).
        chip_x = min(float(clamped_x), image_pixel_width - chip_width)
        chip_y = min(float(clamped_y), image_pixel_height - chip_height)
        chip_x = max(0.0, chip_x)
        chip_y = max(0.0, chip_y)

        draw.rectangle(
            [chip_x, chip_y, chip_x + chip_width, chip_y + chip_height],
            fill=SYSTEM_PINK_RGB,
        )
        # Swift textOrigin = (chipX + padding, chipY + padding/2) (L193-196).
        draw.text(
            (chip_x + MARK_LABEL_PADDING, chip_y + MARK_LABEL_PADDING / 2),
            label_text,
            fill=(255, 255, 255),
            font=label_font,
        )

    return marked_image


# ---------------------------------------------------------------------------
# Synthetic UI screenshot generation
#
# Each synthetic screen is an app-window mockup: a title bar, a left sidebar, a
# toolbar row of text-labelled buttons, and a content area with text fields and
# checkboxes. Every interactive element gets a stable label AND a bbox. The
# generator knows which mark index maps to which label — that IS the ground
# truth for the mark-reading eval.
# ---------------------------------------------------------------------------

CANVAS_BACKGROUND = (245, 246, 248)
TITLE_BAR_FILL = (222, 224, 228)
SIDEBAR_FILL = (236, 238, 242)
BUTTON_FILL = (255, 255, 255)
BUTTON_BORDER = (176, 180, 188)
FIELD_FILL = (255, 255, 255)
FIELD_BORDER = (198, 202, 210)
TEXT_COLOR = (40, 44, 52)
CANVAS_WIDTH = 1024
CANVAS_HEIGHT = 700


@dataclass
class SyntheticElement:
    """One interactive element on a synthetic screen. `label` is what the eval
    asks the model to find; `bbox` is [x, y, w, h] top-left origin."""

    label: str
    role: str
    bbox: list[int]


@dataclass
class SyntheticScreen:
    name: str
    app_title: str
    elements: list[SyntheticElement] = field(default_factory=list)


# A pool of plausible button / field / checkbox labels the layouts draw from.
_TOOLBAR_LABEL_POOL = [
    "Send",
    "Save",
    "Export",
    "Delete",
    "Share",
    "Reply",
    "Forward",
    "Archive",
    "New",
    "Print",
    "Refresh",
    "Settings",
]
_FIELD_LABEL_POOL = [
    "To",
    "Subject",
    "Search",
    "Name",
    "Email",
    "Password",
    "Title",
    "Tags",
]
_CHECKBOX_LABEL_POOL = [
    "Remember me",
    "Notify",
    "Archive after send",
    "Mark as read",
    "Include attachments",
]
_SIDEBAR_LABEL_POOL = [
    "Inbox",
    "Drafts",
    "Sent",
    "Trash",
    "Projects",
    "Notes",
    "Starred",
]


def _build_synthetic_screen(layout_index: int, element_count: int) -> SyntheticScreen:
    """Deterministically build one synthetic screen. `layout_index` selects the
    app persona; `element_count` (5..15) controls how many interactive elements
    are laid out. Determinism (no randomness) keeps the eval reproducible."""
    app_personas = [
        "Mail",
        "Notes",
        "Files",
        "Settings",
        "Browser",
        "Chat",
        "Tasks",
        "Calendar",
        "Music",
        "Photos",
        "Terminal",
        "Editor",
    ]
    app_title = app_personas[layout_index % len(app_personas)]
    screen = SyntheticScreen(
        name=f"layout{layout_index:02d}-{app_title.lower()}-{element_count}el",
        app_title=app_title,
    )

    # Deterministic rotation offset per layout so labels differ across screens.
    rotation = layout_index

    remaining = element_count

    # --- Sidebar entries (up to 3, role "menu_item"). ---
    sidebar_count = min(3, remaining)
    for sidebar_position in range(sidebar_count):
        label = _SIDEBAR_LABEL_POOL[
            (rotation + sidebar_position) % len(_SIDEBAR_LABEL_POOL)
        ]
        screen.elements.append(
            SyntheticElement(
                label=label,
                role="menu_item",
                bbox=[16, 70 + sidebar_position * 44, 150, 34],
            )
        )
    remaining -= sidebar_count

    # --- Toolbar buttons across the top of the content area. ---
    toolbar_count = min(4, remaining)
    for toolbar_position in range(toolbar_count):
        label = _TOOLBAR_LABEL_POOL[
            (rotation * 2 + toolbar_position) % len(_TOOLBAR_LABEL_POOL)
        ]
        screen.elements.append(
            SyntheticElement(
                label=label,
                role="button",
                bbox=[200 + toolbar_position * 130, 60, 110, 36],
            )
        )
    remaining -= toolbar_count

    # --- Text fields stacked in the content area. ---
    field_count = min(4, remaining)
    for field_position in range(field_count):
        label = _FIELD_LABEL_POOL[
            (rotation + field_position) % len(_FIELD_LABEL_POOL)
        ]
        screen.elements.append(
            SyntheticElement(
                label=f"{label} field",
                role="text_field",
                bbox=[200, 130 + field_position * 60, 500, 40],
            )
        )
    remaining -= field_count

    # --- Checkboxes fill any remaining slots. ---
    for checkbox_position in range(remaining):
        label = _CHECKBOX_LABEL_POOL[
            (rotation + checkbox_position) % len(_CHECKBOX_LABEL_POOL)
        ]
        screen.elements.append(
            SyntheticElement(
                label=label,
                role="checkbox",
                bbox=[200, 400 + checkbox_position * 44, 260, 30],
            )
        )

    return screen


def render_synthetic_screen(screen: SyntheticScreen) -> "Image.Image":
    """Paint a synthetic app-window mockup (NO marks yet). The marks are added
    separately by replicate_set_of_mark_renderer so the mark-drawing path is
    exactly the one under test."""
    image = Image.new("RGB", (CANVAS_WIDTH, CANVAS_HEIGHT), CANVAS_BACKGROUND)
    draw = ImageDraw.Draw(image)
    body_font = _load_bold_label_font()

    # Title bar + app title.
    draw.rectangle([0, 0, CANVAS_WIDTH, 48], fill=TITLE_BAR_FILL)
    draw.text((16, 16), screen.app_title, fill=TEXT_COLOR, font=body_font)

    # Sidebar column.
    draw.rectangle([0, 48, 182, CANVAS_HEIGHT], fill=SIDEBAR_FILL)

    for element in screen.elements:
        element_x, element_y, element_width, element_height = element.bbox
        element_rect = [
            element_x,
            element_y,
            element_x + element_width,
            element_y + element_height,
        ]
        if element.role == "button":
            draw.rectangle(element_rect, fill=BUTTON_FILL, outline=BUTTON_BORDER)
            draw.text(
                (element_x + 12, element_y + 9),
                element.label,
                fill=TEXT_COLOR,
                font=body_font,
            )
        elif element.role == "text_field":
            draw.rectangle(element_rect, fill=FIELD_FILL, outline=FIELD_BORDER)
            draw.text(
                (element_x + 8, element_y + 11),
                element.label,
                fill=(120, 124, 132),
                font=body_font,
            )
        elif element.role == "checkbox":
            # Small box + adjacent label.
            box_side = min(element_height, 22)
            draw.rectangle(
                [element_x, element_y, element_x + box_side, element_y + box_side],
                fill=FIELD_FILL,
                outline=FIELD_BORDER,
            )
            draw.text(
                (element_x + box_side + 8, element_y + 4),
                element.label,
                fill=TEXT_COLOR,
                font=body_font,
            )
        else:  # menu_item / sidebar entry
            draw.text(
                (element_x + 10, element_y + 8),
                element.label,
                fill=TEXT_COLOR,
                font=body_font,
            )

    return image


def build_synthetic_screens() -> list[SyntheticScreen]:
    """12 distinct layouts with element counts stepping across 5..15."""
    # Element counts spread across the 5..15 band; wraps if >11 layouts.
    element_count_schedule = [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 9]
    screens: list[SyntheticScreen] = []
    for layout_index, element_count in enumerate(element_count_schedule):
        screens.append(_build_synthetic_screen(layout_index, element_count))
    return screens


# ---------------------------------------------------------------------------
# Eval cases
# ---------------------------------------------------------------------------


@dataclass
class MarkReadingCase:
    screen_name: str
    target_label: str
    ground_truth_index: int
    marked_image_png: bytes
    mark_count: int


def build_cases_for_screen(screen: SyntheticScreen) -> list[MarkReadingCase]:
    """One case per interactive element on the screen. All elements get a mark
    (index = element position, matching PaceSetOfMarkClickRecovery where mark
    numbers ARE element array indices). The target label is asked verbatim."""
    boxes = [(index, element.bbox) for index, element in enumerate(screen.elements)]
    base_image = render_synthetic_screen(screen)
    marked_image = replicate_set_of_mark_renderer(base_image, boxes)

    png_buffer = io.BytesIO()
    marked_image.save(png_buffer, format="PNG")
    marked_image_png = png_buffer.getvalue()

    cases: list[MarkReadingCase] = []
    for element_index, element in enumerate(screen.elements):
        cases.append(
            MarkReadingCase(
                screen_name=screen.name,
                target_label=element.label,
                ground_truth_index=element_index,
                marked_image_png=marked_image_png,
                mark_count=len(screen.elements),
            )
        )
    return cases


# ---------------------------------------------------------------------------
# LM Studio round-trip — same prompt shape as
# LocalVLMClient.groundMarkedClickTarget (Swift L438-482).
# ---------------------------------------------------------------------------


def build_grounding_system_prompt(mark_count: int) -> str:
    """Byte-for-byte the systemInstruction from groundMarkedClickTarget, with
    the same "0 to markCount-1" phrasing (Swift L454-460)."""
    return (
        "You are a UI grounding model. The screenshot has numbered magenta marks "
        f"on its UI elements, numbered 0 to {mark_count - 1}. Reply with ONLY the "
        "single integer mark number drawn on the element that matches the target. "
        "Reply -1 if no mark is on a matching element. Output the number alone — "
        "no words, no punctuation, no JSON."
    )


def build_grounding_user_message(target_description: str, image_data_url: str) -> list:
    """Mirrors groundMarkedClickTarget's user message (Swift L461-464)."""
    return [
        {
            "type": "text",
            "text": f'Target to click: "{target_description}". Which mark number is on that element?',
        },
        {"type": "image_url", "image_url": {"url": image_data_url}},
    ]


def parse_grounded_mark_number(raw_content: str, mark_count: int) -> Optional[int]:
    """Port of LocalVLMClient.parseGroundedMarkNumber (Swift L486-503): first
    signed integer anywhere in the reply, rejected if -1 / out of range."""
    match = re.search(r"-?\d+", raw_content)
    if not match:
        return None
    parsed = int(match.group(0))
    if parsed < 0 or parsed >= mark_count:
        return None
    return parsed


@dataclass
class GroundingResult:
    predicted_index: Optional[int]
    raw_reply: str
    elapsed_ms: int
    error: Optional[str] = None


def run_grounding_call(model_identifier: str, case: MarkReadingCase) -> GroundingResult:
    image_data_url = "data:image/png;base64," + base64.b64encode(
        case.marked_image_png
    ).decode("ascii")
    request_body = {
        "model": model_identifier,
        "messages": [
            {
                "role": "system",
                "content": build_grounding_system_prompt(case.mark_count),
            },
            {
                "role": "user",
                "content": build_grounding_user_message(
                    case.target_label, image_data_url
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
    except urllib.error.HTTPError as http_error:
        return GroundingResult(
            predicted_index=None,
            raw_reply="",
            elapsed_ms=int((time.monotonic() - started_at) * 1000),
            error=f"HTTP {http_error.code}: {http_error.read().decode('utf-8', errors='replace')[:200]}",
        )
    except (urllib.error.URLError, TimeoutError) as transport_error:
        return GroundingResult(
            predicted_index=None,
            raw_reply="",
            elapsed_ms=int((time.monotonic() - started_at) * 1000),
            error=f"transport: {transport_error}",
        )

    elapsed_ms = int((time.monotonic() - started_at) * 1000)
    try:
        payload = json.loads(body)
        raw_content = payload["choices"][0]["message"]["content"]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as parse_error:
        return GroundingResult(
            predicted_index=None,
            raw_reply=body[:200],
            elapsed_ms=elapsed_ms,
            error=f"parse error: {parse_error}",
        )

    predicted_index = parse_grounded_mark_number(raw_content, case.mark_count)
    return GroundingResult(
        predicted_index=predicted_index,
        raw_reply=raw_content.strip(),
        elapsed_ms=elapsed_ms,
    )


# ---------------------------------------------------------------------------
# Reachability probe — fail loud, never fake.
# ---------------------------------------------------------------------------


def lm_studio_is_reachable() -> tuple[bool, str]:
    """Probe the /v1/models endpoint derived from LM_STUDIO_URL. Returns
    (reachable, detail)."""
    models_url = LM_STUDIO_URL.replace("/chat/completions", "/models")
    request = urllib.request.Request(
        models_url, headers={"Authorization": "Bearer lm-studio"}, method="GET"
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response_stream:
            response_stream.read()
        return True, "reachable"
    except urllib.error.HTTPError as http_error:
        # A live server that answers the endpoint (even non-200) is reachable.
        return True, f"HTTP {http_error.code}"
    except (urllib.error.URLError, TimeoutError) as transport_error:
        return False, str(transport_error)


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def evaluate_model(
    model_identifier: str, cases: list[MarkReadingCase]
) -> list[tuple[MarkReadingCase, GroundingResult]]:
    results: list[tuple[MarkReadingCase, GroundingResult]] = []
    for case in cases:
        result = run_grounding_call(model_identifier, case)
        verdict = "✓" if result.predicted_index == case.ground_truth_index else "✗"
        if result.error:
            verdict = "!"
        print(
            f"  {verdict} {case.screen_name} target={case.target_label!r} "
            f"gt={case.ground_truth_index} pred={result.predicted_index} "
            f"({result.elapsed_ms}ms)"
            + (f" ERROR {result.error}" if result.error else "")
        )
        results.append((case, result))
    return results


def print_accuracy_table(
    per_model_results: dict[str, list[tuple[MarkReadingCase, GroundingResult]]],
) -> None:
    print("\n## VLM mark-reading accuracy\n")
    print("| Model | Correct | Total | Accuracy | Errors | Mean ms |")
    print("|---|---|---|---|---|---|")
    for model_identifier, results in per_model_results.items():
        total = len(results)
        correct = sum(
            1
            for case, result in results
            if result.predicted_index == case.ground_truth_index
        )
        errors = sum(1 for _, result in results if result.error)
        latencies = [result.elapsed_ms for _, result in results if not result.error]
        mean_ms = int(sum(latencies) / len(latencies)) if latencies else 0
        accuracy_pct = (100.0 * correct / total) if total else 0.0
        print(
            f"| {model_identifier} | {correct} | {total} | {accuracy_pct:.1f}% "
            f"| {errors} | {mean_ms} |"
        )


def write_case_csv(
    csv_path: Path,
    per_model_results: dict[str, list[tuple[MarkReadingCase, GroundingResult]]],
) -> None:
    with csv_path.open("w", newline="") as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(
            [
                "model",
                "screen",
                "target_label",
                "ground_truth_index",
                "predicted_index",
                "correct",
                "mark_count",
                "elapsed_ms",
                "raw_reply",
                "error",
            ]
        )
        for model_identifier, results in per_model_results.items():
            for case, result in results:
                writer.writerow(
                    [
                        model_identifier,
                        case.screen_name,
                        case.target_label,
                        case.ground_truth_index,
                        result.predicted_index
                        if result.predicted_index is not None
                        else "",
                        int(result.predicted_index == case.ground_truth_index),
                        case.mark_count,
                        result.elapsed_ms,
                        result.raw_reply.replace("\n", " ")[:120],
                        result.error or "",
                    ]
                )
    print(f"\nWrote per-case CSV → {csv_path}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Synthetic mark-reading micro-eval for Pace's Set-of-Mark "
        "grounding step.",
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Single LM Studio model id to evaluate (default {DEFAULT_MODEL}).",
    )
    parser.add_argument(
        "--models",
        default=None,
        help="Comma-separated list of model ids to loop over. Overrides --model.",
    )
    parser.add_argument(
        "--image-dir",
        default=None,
        help="If set, write each marked synthetic screenshot as a PNG here for "
        "visual inspection.",
    )
    parser.add_argument(
        "--generate-only",
        action="store_true",
        help="Only generate the synthetic marked images (requires --image-dir); "
        "do NOT call any model. Useful for verifying the renderer convention.",
    )
    parser.add_argument(
        "--csv",
        default=str(PROJECT_DIR / "evals" / "vlm-mark-reading-cases.csv"),
        help="Path for the per-case CSV dump.",
    )
    args = parser.parse_args(argv)

    screens = build_synthetic_screens()
    all_cases: list[MarkReadingCase] = []
    # Build one marked image per screen once, dump if requested, collect cases.
    for screen in screens:
        screen_cases = build_cases_for_screen(screen)
        all_cases.extend(screen_cases)
        if args.image_dir:
            image_directory = Path(args.image_dir)
            image_directory.mkdir(parents=True, exist_ok=True)
            # All cases for a screen share one marked image; write it once.
            (image_directory / f"{screen.name}.png").write_bytes(
                screen_cases[0].marked_image_png
            )

    print(
        f"Generated {len(screens)} synthetic screens → {len(all_cases)} mark-reading cases."
    )
    if args.image_dir:
        print(f"Wrote marked screenshots → {args.image_dir}")

    if args.generate_only:
        if not args.image_dir:
            print(
                "❌ --generate-only requires --image-dir so there's somewhere to "
                "write the images.",
                file=sys.stderr,
            )
            return 2
        return 0

    model_identifiers = (
        [name.strip() for name in args.models.split(",") if name.strip()]
        if args.models
        else [args.model]
    )

    reachable, detail = lm_studio_is_reachable()
    if not reachable:
        print(
            "\n❌ LM Studio is unreachable at "
            f"{LM_STUDIO_URL} ({detail}).\n"
            "   Start LM Studio, then load one of: "
            + ", ".join(model_identifiers)
            + "\n   (Enable the local server: LM Studio → Developer → Start Server, "
            "port 1234.)\n"
            "   Then re-run this script. No results were fabricated.",
            file=sys.stderr,
        )
        return 1

    per_model_results: dict[
        str, list[tuple[MarkReadingCase, GroundingResult]]
    ] = {}
    for model_identifier in model_identifiers:
        print(f"\n══════════════ {model_identifier} ══════════════", flush=True)
        per_model_results[model_identifier] = evaluate_model(
            model_identifier, all_cases
        )

    print_accuracy_table(per_model_results)
    write_case_csv(Path(args.csv), per_model_results)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
