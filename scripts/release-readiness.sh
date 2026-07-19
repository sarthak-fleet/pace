#!/usr/bin/env bash
#
# release-readiness.sh — Aggregate a Foundry-readable release-readiness
# receipt WITHOUT signing, publishing, enrolling a device, or deploying
# production.
#
# The receipt is written to releases/readiness-receipt.json and records
# the layered status of every evidence layer in the automation matrix
# (see docs/operations/automation-evidence-matrix.md). It ends with
# `distributionApprovalRequired: true` — automation never publishes.
#
# Privacy contract: the receipt contains only layer names, status
# strings ("pass" / "blocked" / "n/a"), the source git revision, the
# latest app version/build from appcast.xml, and a UTC timestamp. No
# secrets, no signing key material, no transcripts, no screen context,
# no action targets.
#
# Usage:
#   ./scripts/release-readiness.sh
#   ./scripts/release-readiness.sh --output path/to/receipt.json
#   ./scripts/release-readiness.sh --no-build   # skip the slow build/tests layers
#
# --no-build records the build/tests/simulator layers as "blocked"
# rather than running them. Use this for a quick receipt; use the
# default (or CI) when you want the real build evidence.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT="$PROJECT_DIR/releases/readiness-receipt.json"
SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --output) shift; OUTPUT="$1"; shift || true ;;
    --no-build) SKIP_BUILD=1 ;;
  esac
done

mkdir -p "$(dirname "$OUTPUT")"

# Source revision (short SHA). Empty when git is unavailable.
SOURCE_REVISION=""
if command -v git >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.git" ]; then
  SOURCE_REVISION="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
fi
SOURCE_BRANCH=""
if command -v git >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.git" ]; then
  SOURCE_BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi
SOURCE_DIRTY=0
if command -v git >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.git" ]; then
  if ! git -C "$PROJECT_DIR" diff --quiet HEAD 2>/dev/null; then
    SOURCE_DIRTY=1
  fi
fi

# Latest version/build from appcast.xml.
LATEST_VERSION="unknown"
LATEST_BUILD="unknown"
if [ -f "$PROJECT_DIR/appcast.xml" ]; then
  parsed="$(python3 -c '
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
items = root.findall(".//item")
items.sort(key=lambda i: int(i.findtext("sparkle:version", "", ns) or "0"), reverse=True)
if items:
    print(items[0].findtext("sparkle:shortVersionString", "", ns))
    print(items[0].findtext("sparkle:version", "", ns))
' "$PROJECT_DIR/appcast.xml" 2>/dev/null || true)"
  if [ -n "$parsed" ]; then
    LATEST_VERSION="$(echo "$parsed" | sed -n 1p)"
    LATEST_BUILD="$(echo "$parsed" | sed -n 2p)"
  fi
fi

# Layer status helpers. Each layer function echoes one of:
#   pass | blocked | n/a | fail
landing_status() {
  if bash "$SCRIPT_DIR/check-landing-health.sh" --offline >/dev/null 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

build_status() {
  # The build layer needs a Mac + Xcode + the Metal toolchain. When
  # xcodebuild is unavailable or --no-build was passed, record blocked
  # rather than running a doomed or slow build. When xcodebuild is
  # available and --no-build was NOT passed, delegate to test-pace.sh
  # (the only terminal build path that avoids TCC invalidation).
  if [ "$SKIP_BUILD" -eq 1 ]; then
    echo "blocked"
    return
  fi
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "blocked"
    return
  fi
  if bash "$SCRIPT_DIR/test-pace.sh" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

signing_status() {
  if ! command -v security >/dev/null 2>&1; then
    echo "blocked"
    return
  fi
  if security find-identity -v -p codesigning login.keychain 2>/dev/null | grep -q "Developer ID Application"; then
    echo "pass"
  else
    echo "blocked"
  fi
}

device_status() {
  # Device proof is never automatable — always blocked.
  echo "blocked"
}

distribution_status() {
  if bash "$SCRIPT_DIR/check-landing-health.sh" --offline >/dev/null 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

activation_status() {
  # Intentionally N/A — the on-device moat forbids a fleet-bound
  # return path. See docs/operations/automation-evidence-matrix.md.
  echo "n/a"
}

failure_status() {
  # Covered by unit tests (PaceTelemetryLogFailureTests,
  # PaceTelemetryLogPrivacyBoundaryTests). Automation runs do not
  # synthesize failure signals.
  echo "n/a"
}

LAYER_LANDING="$(landing_status)"
LAYER_BUILD="$(build_status)"
LAYER_TESTS="$LAYER_BUILD"  # tests inherit the build layer's status
LAYER_SIMULATOR="$LAYER_BUILD"  # macOS is the only destination
LAYER_SIGNING="$(signing_status)"
LAYER_DEVICE="$(device_status)"
LAYER_DISTRIBUTION="$(distribution_status)"
LAYER_ACTIVATION="$(activation_status)"
LAYER_FAILURE="$(failure_status)"

# Overall status: fail if any layer failed; else blocked if any layer
# is blocked; else pass.
overall() {
  local statuses=("$LAYER_LANDING" "$LAYER_BUILD" "$LAYER_TESTS" "$LAYER_SIMULATOR" "$LAYER_SIGNING" "$LAYER_DEVICE" "$LAYER_DISTRIBUTION" "$LAYER_ACTIVATION" "$LAYER_FAILURE")
  for s in "${statuses[@]}"; do
    if [ "$s" = "fail" ]; then echo "fail"; return; fi
  done
  for s in "${statuses[@]}"; do
    if [ "$s" = "blocked" ]; then echo "blocked"; return; fi
  done
  echo "pass"
}

OVERALL="$(overall)"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Write the receipt as JSON via Python for reliable escaping.
python3 - "$OUTPUT" <<PYEOF
import json, os, sys
output_path = sys.argv[1]

receipt = {
    "schema": "heypace.release-readiness/v1",
    "generatedAt": "$GENERATED_AT",
    "sourceRevision": "$SOURCE_REVISION" or "unknown",
    "sourceBranch": "$SOURCE_BRANCH" or "unknown",
    "sourceDirty": $SOURCE_DIRTY == 1,
    "latestVersion": "$LATEST_VERSION",
    "latestBuild": "$LATEST_BUILD",
    "overall": "$OVERALL",
    "distributionApprovalRequired": True,
    "layers": {
        "landing":       "$LAYER_LANDING",
        "build":         "$LAYER_BUILD",
        "tests":         "$LAYER_TESTS",
        "simulator":     "$LAYER_SIMULATOR",
        "signing":       "$LAYER_SIGNING",
        "device":        "$LAYER_DEVICE",
        "distribution":  "$LAYER_DISTRIBUTION",
        "activation":    "$LAYER_ACTIVATION",
        "failure":       "$LAYER_FAILURE"
    },
    "notes": [
        "device proof is a manual hardware gate (docs/operations/release-smoke-checklist.md)",
        "activation is intentionally N/A — the on-device moat forbids a fleet-bound return path",
        "failure evidence is covered by unit tests, not by automation runs",
        "automation never signs, publishes, enrolls a device, or deploys production"
    ]
}

with open(output_path, "w") as f:
    json.dump(receipt, f, indent=2)
    f.write("\\n")

print(f"✓ release-readiness receipt written to {output_path}")
print(f"  overall: {receipt['overall']}")
print(f"  latest:  {receipt['latestVersion']} (build {receipt['latestBuild']})")
print(f"  source:  {receipt['sourceRevision']} (branch {receipt['sourceBranch']}, dirty={receipt['sourceDirty']})")
for layer, status in receipt["layers"].items():
    icon = {"pass": "✅", "blocked": "⛔", "n/a": "⚪", "fail": "❌"}.get(status, "?")
    print(f"  {icon} {layer}: {status}")
PYEOF

# Exit code reflects overall status: 0 = pass, 1 = fail, 2 = blocked.
case "$OVERALL" in
  pass) exit 0 ;;
  fail) exit 1 ;;
  blocked) exit 2 ;;
  *) exit 1 ;;
esac
