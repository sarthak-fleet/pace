#!/usr/bin/env bash
#
# verify.sh — single-command pre-commit verification gate.
#
# Why this exists
# ---------------
# The autonomous-loop cadence calls for fast green/red signal after
# every change. Before, that meant remembering to run two scripts in
# the right order:
#
#   bash scripts/test-pace.sh
#   python3 scripts/diag-pace.py --quick --no-load --eval
#
# One command instead. Runs the Swift unit suite first (cheap,
# ~5000ms, catches compile breaks and pure-function regressions),
# then the runtime + behavior diagnostic (~60000ms, catches LM
# Studio thrash and planner behavior regressions). Exits non-zero
# on any failure so it's safe to chain with `&& git commit`.
#
# Skips:
#   --no-eval     skip the planner behavior eval (~30000ms saved,
#                 use for pure refactor commits that can't change
#                 model behavior)
#   --tests-only  Swift tests only (use for doc commits)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RUN_DIAG=true
RUN_EVAL=true
for argument in "$@"; do
    case "$argument" in
        --tests-only)
            RUN_DIAG=false
            RUN_EVAL=false
            ;;
        --no-eval)
            RUN_EVAL=false
            ;;
        --help|-h)
            sed -n '2,28p' "$0"
            exit 0
            ;;
        *)
            echo "❌ unknown argument: $argument" >&2
            exit 2
            ;;
    esac
done

echo "▶ verify.sh: Swift unit tests"
bash "$SCRIPT_DIR/test-pace.sh"

if [[ "$RUN_DIAG" == "true" ]]; then
    echo
    echo "▶ verify.sh: Pace runtime diagnostic"
    if [[ "$RUN_EVAL" == "true" ]]; then
        python3 "$SCRIPT_DIR/diag-pace.py" --quick --no-load --eval
    else
        python3 "$SCRIPT_DIR/diag-pace.py" --quick --no-load
    fi
fi

echo
echo "✅ verify.sh: all gates passed"
