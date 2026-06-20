#!/usr/bin/env bash
#
# smoke-executor-surface.sh — executor PRD acceptance runner.
#
# Runs the deterministic dry-run unit suite (no real app mutations) and,
# when a Debug Pace.app is available, the runtime smoke hooks that cover
# click-target clarification and all-fail observation breadcrumbs.
#
# Real-app AX/performance smokes (Mail latency, Safari click, etc.) still
# require a user Xcode Debug build with TCC grants — see the checklist at
# the end of this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "▶ Executor surface smoke — dry-run unit tests"
bash "$SCRIPT_DIR/test-pace.sh" PaceActionExecutorDryRunTests

echo
echo "▶ v10 schema fixture gate"
python3 "$SCRIPT_DIR/eval-v10-schema-fixtures.py"

echo
if APP_PATH="$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/Pace.app 2>/dev/null | head -1)" \
   && [[ -x "$APP_PATH/Contents/MacOS/Pace" ]]; then
    echo "▶ Runtime smoke hooks (click clarification + all-fail observation)"
    bash "$SCRIPT_DIR/smoke-runtime-hooks.sh"
else
    echo "⚠️  Skipping runtime smoke hooks — build Pace.app from Xcode first."
    echo "    (Dry-run unit coverage above still validates the dispatcher surface.)"
fi

cat <<'EOF'

Manual real-app checklist (pace-executor-surface.md / pace-v9-body-streaming-wiring.md):
  [ ] Mail compose: voice draft with streaming body lands in <700ms after stop-talk
  [ ] Safari: AX.press on a visible labelled control succeeds
  [ ] Notes: create + append without clipboard pollution
  [ ] Slack / VS Code / Cursor: focused-field setValue or click smoke
  [ ] Grammar-constrained planner decode: run scripts/eval-planners.py before switching default model

EOF

echo "executor surface smoke runner finished"
