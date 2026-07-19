#!/usr/bin/env bash
#
# automation-readiness.sh — Layered build/release/activation/failure/
# distribution evidence for the HeyPace automation matrix.
#
# Each layer is independently reportable. A pass at an earlier layer
# does NOT satisfy a later layer — that's the whole point of the
# matrix (see docs/operations/automation-evidence-matrix.md).
#
# Layers and their flags:
#   --landing            Canonical surface + manifest consistency
#   --build              Swift target compiles (xcodebuild build, no tests)
#   --tests              Swift Testing suite executes a non-zero count
#   --simulator         (alias of --tests for macOS; there is no iOS target)
#   --signing            Developer ID presence (read-only; never exports keys)
#   --device             Always reports blocked — device proof is manual
#   --distribution       appcast.xml + release-info.json manifest check (read-only)
#   --activation         Intentionally N/A — documented in the matrix
#   --failure            Covered by unit tests, not by automation runs
#   --release-readiness  Aggregate receipt (delegates to release-readiness.sh)
#   --all                Run every layer except --build/--tests (those need
#                        a Mac + Xcode and are left to the caller / CI)
#
# Privacy contract: this script never reads or prints secrets, signing
# key material, transcripts, screen context, or action targets. The
# --signing layer only checks for the PRESENCE of a Developer ID
# certificate in the login keychain via `security find-identity`; it
# does not export or print the key.
#
# Exit codes:
#   0  all requested layers passed
#   1  at least one layer failed
#   2  at least one layer is blocked (not a failure — needs human action)
#
# Usage:
#   ./scripts/automation-readiness.sh --landing
#   ./scripts/automation-readiness.sh --landing --distribution --signing
#   ./scripts/automation-readiness.sh --all
#   ./scripts/automation-readiness.sh --release-readiness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Layer flags
RUN_LANDING=0
RUN_BUILD=0
RUN_TESTS=0
RUN_SIMULATOR=0
RUN_SIGNING=0
RUN_DEVICE=0
RUN_DISTRIBUTION=0
RUN_ACTIVATION=0
RUN_FAILURE=0
RUN_RELEASE_READINESS=0
RUN_ALL=0

if [ $# -eq 0 ]; then
  echo "Usage: $0 [--landing|--build|--tests|--simulator|--signing|--device|--distribution|--activation|--failure|--release-readiness|--all]"
  exit 0
fi

for arg in "$@"; do
  case "$arg" in
    --landing) RUN_LANDING=1 ;;
    --build) RUN_BUILD=1 ;;
    --tests) RUN_TESTS=1 ;;
    --simulator) RUN_SIMULATOR=1 ;;
    --signing) RUN_SIGNING=1 ;;
    --device) RUN_DEVICE=1 ;;
    --distribution) RUN_DISTRIBUTION=1 ;;
    --activation) RUN_ACTIVATION=1 ;;
    --failure) RUN_FAILURE=1 ;;
    --release-readiness) RUN_RELEASE_READINESS=1 ;;
    --all) RUN_ALL=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

if [ $RUN_ALL -eq 1 ]; then
  RUN_LANDING=1
  RUN_SIGNING=1
  RUN_DEVICE=1
  RUN_DISTRIBUTION=1
  RUN_ACTIVATION=1
  RUN_FAILURE=1
  RUN_RELEASE_READINESS=1
  # --build and --tests are NOT included in --all because they need a
  # Mac + Xcode + the Metal toolchain and can take 10+ minutes. Run
  # them explicitly or via CI.
fi

PASS=0
FAIL=0
BLOCKED=0

record_pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
record_fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
record_blocked() { echo "  ⛔ $1 (blocked — needs human action)"; BLOCKED=$((BLOCKED + 1)); }
record_na() { echo "  ⚪ $1 (N/A — documented in evidence matrix)"; }

echo "▶ HeyPace automation readiness"
echo "  repo: $PROJECT_DIR"
echo "  date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

# --- landing ---------------------------------------------------------------

if [ $RUN_LANDING -eq 1 ]; then
  echo "## landing"
  if bash "$SCRIPT_DIR/check-landing-health.sh" --offline >/tmp/pace-landing-health.$$ 2>&1; then
    record_pass "landing health (offline manifest check)"
  else
    record_fail "landing health (offline manifest check)"
    cat /tmp/pace-landing-health.$$
  fi
  rm -f /tmp/pace-landing-health.$$
  echo
fi

# --- build -----------------------------------------------------------------

if [ $RUN_BUILD -eq 1 ]; then
  echo "## build"
  echo "  (delegates to scripts/test-pace.sh — the only terminal build path"
  echo "   that avoids touching the interactive app's TCC grants)"
  if bash "$SCRIPT_DIR/test-pace.sh" >/tmp/pace-build.$$ 2>&1; then
    record_pass "build + tests (isolated DerivedData)"
  else
    record_fail "build + tests (isolated DerivedData)"
    tail -30 /tmp/pace-build.$$
  fi
  rm -f /tmp/pace-build.$$
  echo
fi

# --- tests / simulator -----------------------------------------------------

if [ $RUN_TESTS -eq 1 ] || [ $RUN_SIMULATOR -eq 1 ]; then
  echo "## tests / simulator"
  echo "  (macOS is the only destination — there is no iOS-adjacent target."
  echo "   --simulator is an alias of --tests for this repo.)"
  if bash "$SCRIPT_DIR/test-pace.sh" >/tmp/pace-tests.$$ 2>&1; then
    record_pass "tests (Swift Testing suite, isolated DerivedData)"
  else
    record_fail "tests (Swift Testing suite, isolated DerivedData)"
    tail -30 /tmp/pace-tests.$$
  fi
  rm -f /tmp/pace-tests.$$
  echo
fi

# --- signing ---------------------------------------------------------------

if [ $RUN_SIGNING -eq 1 ]; then
  echo "## signing"
  echo "  (read-only presence check via security find-identity — never"
  echo "   exports or prints key material)"
  # Look for a Developer ID Application certificate. The -v flag prints
  # the cert SHA-1 + common name, which is public-facing identity info
  # (it's embedded in the signed app bundle). We do NOT print the
  # private key or export it.
  if command -v security >/dev/null 2>&1; then
    if security find-identity -v -p codesigning login.keychain 2>/dev/null | grep -q "Developer ID Application"; then
      record_pass "Developer ID Application certificate present in login keychain"
    else
      record_blocked "no Developer ID Application certificate in login keychain"
    fi
  else
    record_blocked "security(1) unavailable — cannot check signing identity"
  fi
  echo
fi

# --- device ----------------------------------------------------------------

if [ $RUN_DEVICE -eq 1 ]; then
  echo "## device"
  echo "  (physical-device proof is not remotely automatable — see"
  echo "   docs/operations/release-smoke-checklist.md for the manual gate)"
  record_blocked "physical-device smoke checklist — manual hardware gate"
  echo
fi

# --- distribution ----------------------------------------------------------

if [ $RUN_DISTRIBUTION -eq 1 ]; then
  echo "## distribution"
  echo "  (read-only manifest check — never publishes, signs, or enrolls)"
  APPCAST="$PROJECT_DIR/appcast.xml"
  RELEASE_INFO="$PROJECT_DIR/website/src/config/release-info.json"
  if [ ! -f "$APPCAST" ]; then
    record_fail "appcast.xml missing"
  elif [ ! -f "$RELEASE_INFO" ]; then
    record_fail "release-info.json missing"
  else
    # Both files exist — check manifest consistency (delegates to the
    # landing health check's offline path, which already verifies the
    # latest download URL matches across both files).
    if bash "$SCRIPT_DIR/check-landing-health.sh" --offline >/tmp/pace-dist.$$ 2>&1; then
      record_pass "appcast.xml + release-info.json manifest consistent"
    else
      record_fail "appcast.xml + release-info.json manifest drift"
      cat /tmp/pace-dist.$$
    fi
    rm -f /tmp/pace-dist.$$
  fi
  echo
fi

# --- activation ------------------------------------------------------------

if [ $RUN_ACTIVATION -eq 1 ]; then
  echo "## activation"
  echo "  (intentionally N/A — the on-device moat forbids a fleet-bound"
  echo "   return path. The local OSLog signal"
  echo "   PaceTelemetryLog.recordFirstSuccessfulLocalAction is the"
  echo "   accepted contract; see docs/operations/automation-evidence-matrix.md)"
  record_na "activation return signal — intentionally not centralized"
  echo
fi

# --- failure ---------------------------------------------------------------

if [ $RUN_FAILURE -eq 1 ]; then
  echo "## failure"
  echo "  (covered by unit tests: PaceTelemetryLogFailureTests and"
  echo "   PaceTelemetryLogPrivacyBoundaryTests. Automation runs do not"
  echo "   synthesize failure signals — the contract is local-only.)"
  record_na "failure evidence — covered by unit tests, not automation runs"
  echo
fi

# --- release-readiness -----------------------------------------------------

if [ $RUN_RELEASE_READINESS -eq 1 ]; then
  echo "## release-readiness"
  if [ -x "$SCRIPT_DIR/release-readiness.sh" ]; then
    # Pass --no-build so the receipt generation doesn't re-run the
    # slow build that --build/--tests already covers as separate
    # layers. The receipt records build/tests/simulator as "blocked"
    # when --no-build is passed; run release-readiness.sh directly
    # without --no-build for a receipt that includes real build evidence.
    if bash "$SCRIPT_DIR/release-readiness.sh" --no-build >/tmp/pace-readiness.$$ 2>&1; then
      record_pass "release-readiness receipt generated (--no-build)"
    else
      # Exit code 2 = blocked (not a failure for this layer — the
      # receipt still generated successfully, it just reports blockers).
      if [ -f /tmp/pace-readiness.$$ ] && grep -q "release-readiness receipt written" /tmp/pace-readiness.$$; then
        record_pass "release-readiness receipt generated (--no-build, overall=blocked)"
      else
        record_fail "release-readiness receipt generation failed"
        cat /tmp/pace-readiness.$$
      fi
    fi
    rm -f /tmp/pace-readiness.$$
  else
    record_fail "release-readiness.sh not found"
  fi
  echo
fi

# --- summary ---------------------------------------------------------------

echo "▶ Summary"
echo "  passed:   $PASS"
echo "  failed:   $FAIL"
echo "  blocked:  $BLOCKED"
echo

if [ $FAIL -gt 0 ]; then
  echo "❌ Automation readiness: $FAIL failure(s)."
  exit 1
elif [ $BLOCKED -gt 0 ]; then
  echo "⛔ Automation readiness: $BLOCKED layer(s) blocked — not a failure, but human action is required."
  exit 2
else
  echo "✅ Automation readiness: all requested layers passed."
  exit 0
fi
