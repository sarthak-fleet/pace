#!/usr/bin/env bash
#
# make-readme-gif.sh — convert a macOS screen-recording .mov into an
# optimized GIF suitable for embedding in README.md.
#
# Why this exists
# ---------------
# A 5-second GIF showing a real Pace turn (hold PTT → speak → cursor
# flies → response) is the single biggest conversion lever for a
# github-distributed Mac app. macOS Cmd+Shift+5 is the easy way to
# record the .mov; this script handles the harder part: producing a
# small, sharp .gif that GitHub will actually display inline (the
# upload limit is 10MB; under 5MB renders without click-to-play).
#
# Prerequisites:
#   brew install gifski   # ~10MB, dominant Rust-based .gif encoder
#   brew install ffmpeg   # used to extract frames before gifski
#
# Usage:
#   1. Cmd+Shift+5 → "Record Selected Portion" → record 4-6 seconds
#      of a real Pace interaction. Save to ~/Desktop/pace-demo.mov
#      (or anywhere).
#   2. bash scripts/make-readme-gif.sh ~/Desktop/pace-demo.mov
#
# Output:
#   docs/assets/pace-demo.gif (overwrites if exists)
#
# Defaults are tuned for "loops cleanly + readable + under 5MB":
#   width=720 (sharp on Retina, small enough not to bloat)
#   fps=15  (smooth enough for cursor flight; halves the size vs 30)
#   quality=85 (gifski 1-100; sweet spot)

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <path-to-recording.mov>" >&2
    exit 2
fi

SOURCE_VIDEO_PATH="$1"
if [[ ! -f "$SOURCE_VIDEO_PATH" ]]; then
    echo "❌ Source recording not found: $SOURCE_VIDEO_PATH" >&2
    exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "❌ ffmpeg not installed. Run: brew install ffmpeg" >&2
    exit 1
fi

if ! command -v gifski >/dev/null 2>&1; then
    echo "❌ gifski not installed. Run: brew install gifski" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/docs/assets"
OUTPUT_GIF="$OUTPUT_DIR/pace-demo.gif"

# Tunables. Override via env vars if a specific demo needs different.
TARGET_WIDTH="${GIF_WIDTH:-720}"
TARGET_FPS="${GIF_FPS:-15}"
GIFSKI_QUALITY="${GIF_QUALITY:-85}"

mkdir -p "$OUTPUT_DIR"

# Extract resized PNG frames at the chosen fps. gifski needs frames on
# disk; piping doesn't work cleanly for arbitrary movie sources.
FRAMES_DIR="$(mktemp -d -t pace-gif-frames.XXXXXX)"
trap 'rm -rf "$FRAMES_DIR"' EXIT

echo "▶ Extracting frames at ${TARGET_FPS}fps, ${TARGET_WIDTH}px wide…"
ffmpeg -hide_banner -loglevel error \
    -i "$SOURCE_VIDEO_PATH" \
    -vf "fps=${TARGET_FPS},scale=${TARGET_WIDTH}:-1:flags=lanczos" \
    "$FRAMES_DIR/frame-%04d.png"

FRAME_COUNT=$(ls -1 "$FRAMES_DIR"/frame-*.png 2>/dev/null | wc -l | tr -d ' ')
if [[ "$FRAME_COUNT" -eq 0 ]]; then
    echo "❌ ffmpeg produced no frames. Was the .mov actually a video?" >&2
    exit 1
fi
echo "    ${FRAME_COUNT} frames extracted"

echo "▶ Encoding GIF with gifski (quality=${GIFSKI_QUALITY})…"
gifski \
    --output "$OUTPUT_GIF" \
    --fps "$TARGET_FPS" \
    --width "$TARGET_WIDTH" \
    --quality "$GIFSKI_QUALITY" \
    --quiet \
    "$FRAMES_DIR"/frame-*.png

OUTPUT_SIZE_BYTES=$(stat -f%z "$OUTPUT_GIF")
OUTPUT_SIZE_MB=$(echo "scale=2; $OUTPUT_SIZE_BYTES / 1048576" | bc)
echo
echo "✅ Wrote $OUTPUT_GIF (${OUTPUT_SIZE_MB} MB)"
echo
if (( OUTPUT_SIZE_BYTES > 5242880 )); then
    echo "⚠️  Over 5MB — GitHub will lazy-load (user has to click to play)."
    echo "   Try: GIF_WIDTH=600 bash scripts/make-readme-gif.sh $SOURCE_VIDEO_PATH"
    echo "   or trim the recording shorter."
elif (( OUTPUT_SIZE_BYTES > 10485760 )); then
    echo "❌ Over 10MB — GitHub will reject inline display. Trim or shrink."
fi
echo
echo "Embed in README.md with:"
echo "  ![Pace demo](docs/assets/pace-demo.gif)"
