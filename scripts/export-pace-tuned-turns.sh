#!/usr/bin/env bash
#
# export-pace-tuned-turns.sh — copy opt-in local export JSONL into the repo.
#
# Source: ~/Library/Application Support/Pace/pace-tuned-turns.jsonl
# Dest:   evals/pace-tuned-export/export-YYYYMMDD.jsonl
#
# Usage:
#   bash scripts/export-pace-tuned-turns.sh
#   bash scripts/export-pace-tuned-turns.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_FILE="${PACE_TUNED_EXPORT_SOURCE:-$HOME/Library/Application Support/Pace/pace-tuned-turns.jsonl}"
DEST_DIR="$PROJECT_DIR/evals/pace-tuned-export"
STAMP="$(date +%Y%m%d)"
DEST_FILE="$DEST_DIR/export-${STAMP}.jsonl"
dry_run=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "❌ No export file at: $SOURCE_FILE"
  echo "   Enable Settings → Models → Contribute anonymized planner turns, use Pace locally, then retry."
  exit 1
fi

line_count="$(grep -c . "$SOURCE_FILE" || true)"
if [[ "$line_count" -eq 0 ]]; then
  echo "❌ Export file is empty: $SOURCE_FILE"
  exit 1
fi

mkdir -p "$DEST_DIR"

if [[ "$dry_run" == true ]]; then
  echo "Would copy $line_count line(s)"
  echo "  from: $SOURCE_FILE"
  echo "  to:   $DEST_FILE"
  exit 0
fi

cp "$SOURCE_FILE" "$DEST_FILE"
echo "✅ Copied $line_count training row(s) → $DEST_FILE"
echo "Next: bash scripts/train-pace-tuned-model.sh --check"
