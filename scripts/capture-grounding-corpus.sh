#!/usr/bin/env bash
#
# capture-grounding-corpus.sh — interactive helper to attach REAL screenshots to
# the fm-vlm-fixtures-v1 grounding fixtures.
#
# Why this exists
# ---------------
# The fm-vlm-fixtures-v1 fixtures describe screens (APP_FRONTMOST / AX_TREE /
# OCR_TEXT / USER) but ship WITHOUT screenshots, so the real-VLM grounding path
# (LocalVLMClient.analyzeScreenshot + Set-of-Mark) has never been measured on
# real pixels. This helper walks the fixtures that lack a screenshot, prints the
# scenario so you can set the screen up, captures it with `screencapture -x`, and
# records a `SCREENSHOT_PATH: screenshots/<name>.png` line in the fixture file.
#
# scripts/eval-vlm-grounding.py then picks up any fixture that has a
# SCREENSHOT_PATH and runs the full grounding flow against LM Studio.
#
# Usage
# -----
#   ./scripts/capture-grounding-corpus.sh            # capture all missing
#   ./scripts/capture-grounding-corpus.sh --status   # list what's missing, capture nothing
#   ./scripts/capture-grounding-corpus.sh --only ax-blind-figma-export   # one fixture
#
# It NEVER overwrites an existing screenshot — a fixture that already has a valid
# SCREENSHOT_PATH pointing at an existing file is skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES_DIR="${PROJECT_DIR}/evals/fm-vlm-fixtures-v1"
SCREENSHOTS_DIR="${FIXTURES_DIR}/screenshots"

STATUS_ONLY=false
ONLY_FIXTURE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)
      STATUS_ONLY=true
      shift
      ;;
    --only)
      ONLY_FIXTURE="${2:-}"
      if [[ -z "${ONLY_FIXTURE}" ]]; then
        echo "❌ --only requires a fixture name (without .txt)" >&2
        exit 2
      fi
      shift 2
      ;;
    -h | --help)
      grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "❌ unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "${FIXTURES_DIR}" ]]; then
  echo "❌ fixtures dir not found: ${FIXTURES_DIR}" >&2
  exit 2
fi

# Read a single-line field value ("KEY: value") from a fixture file. Empty if
# the field is absent.
read_fixture_field() {
  local fixture_file="$1"
  local field_key="$2"
  grep -m1 "^${field_key}: " "${fixture_file}" 2>/dev/null | sed "s/^${field_key}: //" || true
}

# Print the scenario block (everything up to the EXPECT_* / SPOKEN_* asserts) so
# the user knows what screen to set up.
print_scenario() {
  local fixture_file="$1"
  echo "────────────────────────────────────────────────────────"
  echo "Fixture: $(basename "${fixture_file}" .txt)"
  echo "────────────────────────────────────────────────────────"
  # Show USER / APP_FRONTMOST / AX_BLIND / the OCR_TEXT block — the human-set-up
  # relevant parts. Stop before the EXPECT_/SPOKEN_ assertion lines.
  awk '
    /^EXPECT_/ { next }
    /^SPOKEN_/ { next }
    /^SCREENSHOT_PATH:/ { next }
    { print "  " $0 }
  ' "${fixture_file}"
  echo ""
}

# Determine whether a fixture already has a usable screenshot.
fixture_has_screenshot() {
  local fixture_file="$1"
  local recorded_path
  recorded_path="$(read_fixture_field "${fixture_file}" "SCREENSHOT_PATH")"
  if [[ -z "${recorded_path}" ]]; then
    return 1
  fi
  # Path is recorded relative to the fixtures dir.
  if [[ -f "${FIXTURES_DIR}/${recorded_path}" ]]; then
    return 0
  fi
  return 1
}

# Append or replace the SCREENSHOT_PATH line in a fixture file.
set_screenshot_path_line() {
  local fixture_file="$1"
  local relative_path="$2"
  local temp_file
  temp_file="$(mktemp)"
  # Drop any existing SCREENSHOT_PATH line, then append the fresh one.
  grep -v '^SCREENSHOT_PATH: ' "${fixture_file}" >"${temp_file}" || true
  printf 'SCREENSHOT_PATH: %s\n' "${relative_path}" >>"${temp_file}"
  mv "${temp_file}" "${fixture_file}"
}

# Collect the target fixtures.
mapfile -t all_fixtures < <(find "${FIXTURES_DIR}" -maxdepth 1 -name '*.txt' ! -name 'README*' | sort)

missing_count=0
present_count=0
captured_count=0

echo "Corpus: ${FIXTURES_DIR}"
echo "Screenshots: ${SCREENSHOTS_DIR}"
echo ""

for fixture_file in "${all_fixtures[@]}"; do
  fixture_name="$(basename "${fixture_file}" .txt)"

  if [[ -n "${ONLY_FIXTURE}" && "${fixture_name}" != "${ONLY_FIXTURE}" ]]; then
    continue
  fi

  if fixture_has_screenshot "${fixture_file}"; then
    present_count=$((present_count + 1))
    if [[ "${STATUS_ONLY}" == true ]]; then
      echo "  ✓ ${fixture_name} — has screenshot"
    fi
    continue
  fi

  missing_count=$((missing_count + 1))

  if [[ "${STATUS_ONLY}" == true ]]; then
    echo "  ✗ ${fixture_name} — MISSING screenshot"
    continue
  fi

  # --- Interactive capture ---
  print_scenario "${fixture_file}"
  echo "Set up the screen described above, then press Enter to capture"
  echo "(or type 's' + Enter to SKIP this fixture)."
  read -r user_key
  if [[ "${user_key}" == "s" || "${user_key}" == "S" ]]; then
    echo "  ⏭  skipped ${fixture_name}"
    echo ""
    continue
  fi

  mkdir -p "${SCREENSHOTS_DIR}"
  screenshot_relative="screenshots/${fixture_name}.png"
  screenshot_absolute="${FIXTURES_DIR}/${screenshot_relative}"

  # -x disables the capture sound. Full-screen capture (no interactive region)
  # so the whole app window + chrome is present, matching what Pace screenshots.
  screencapture -x "${screenshot_absolute}"

  if [[ ! -f "${screenshot_absolute}" ]]; then
    echo "  ❌ capture failed for ${fixture_name} (screencapture wrote nothing)" >&2
    echo ""
    continue
  fi

  set_screenshot_path_line "${fixture_file}" "${screenshot_relative}"
  captured_count=$((captured_count + 1))
  echo "  ✓ captured → ${screenshot_relative}"
  echo "    recorded SCREENSHOT_PATH in ${fixture_name}.txt"
  echo ""
done

echo "════════════════════════════════════════════════════════"
if [[ "${STATUS_ONLY}" == true ]]; then
  echo "Status: ${present_count} with screenshots, ${missing_count} missing."
else
  echo "Done: ${captured_count} captured this run; ${present_count} already had screenshots."
  if [[ "${missing_count}" -gt "${captured_count}" ]]; then
    echo "Still missing: $((missing_count - captured_count)). Re-run to finish, or use --status to list."
  fi
  echo ""
  echo "Next: run the real-VLM grounding eval —"
  echo "  ./scripts/eval-vlm-grounding.py"
fi
