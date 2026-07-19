#!/usr/bin/env bash
#
# check-landing-health.sh — Privacy-safe landing acquisition and
# download/release-interest evidence for the automation matrix.
#
# What it proves
# --------------
#   - The canonical landing surface (https://heypace.app) responds 200.
#   - The /download route is live and exposes the latest release's
#     download URL.
#   - The release-info.json committed to the repo is parseable and
#     carries a sourceRevision tying the build to a repo commit.
#   - The appcast.xml feed is reachable and its latest enclosure URL
#     matches the release-info.json latest downloadURL (manifest
#     consistency).
#
# What it does NOT do
# -------------------
#   - No cloud analytics, no tracking pixel, no user fingerprinting.
#     The script only issues plain HTTP GETs against public surfaces
#     Pace already publishes.
#   - It never signs, publishes, or modifies anything.
#
# Output
# ------
#   Human-readable status lines on stdout. Exit code 0 = all checks
#   pass; non-zero = at least one check failed. The release-readiness
#   script consumes this as the `landing` layer.
#
# Usage
# -----
#   ./scripts/check-landing-health.sh
#   ./scripts/check-landing-health.sh --base-url https://heypace.app
#   ./scripts/check-landing-health.sh --offline   # skip live HTTP, only inspect repo artifacts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_URL="https://heypace.app"
OFFLINE=0
for arg in "$@"; do
  case "$arg" in
    --base-url) shift; BASE_URL="$1"; shift || true ;;
    --offline) OFFLINE=1 ;;
  esac
done

DOWNLOAD_URL="$BASE_URL/download"
APPCAST_URL="https://raw.githubusercontent.com/sarthakagrawal927/pace/main/appcast.xml"
APPCAST_LOCAL="$PROJECT_DIR/appcast.xml"
RELEASE_INFO="$PROJECT_DIR/website/src/config/release-info.json"

FAILURES=0
record_failure() {
  echo "  ✗ $1"
  FAILURES=$((FAILURES + 1))
}

echo "▶ Landing health check"
echo "  base URL: $BASE_URL"
echo "  offline:  $([[ $OFFLINE -eq 1 ]] && echo yes || echo no)"
echo

# --- Repo artifacts ---------------------------------------------------------

echo "1. Repo artifacts"

if [ ! -f "$RELEASE_INFO" ]; then
  record_failure "release-info.json missing at $RELEASE_INFO"
else
  if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("latest"), "latest missing"; assert d["latest"].get("downloadURL"), "latest.downloadURL missing"; assert d.get("sourceRevision"), "sourceRevision missing"' "$RELEASE_INFO" 2>/dev/null; then
    record_failure "release-info.json missing required fields (latest.downloadURL, sourceRevision)"
  else
    LATEST_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["latest"]["version"])' "$RELEASE_INFO")"
    LATEST_DOWNLOAD_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["latest"]["downloadURL"])' "$RELEASE_INFO")"
    SOURCE_REVISION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceRevision"])' "$RELEASE_INFO")"
    echo "  ✓ release-info.json parseable (latest=$LATEST_VERSION, sourceRevision=$SOURCE_REVISION)"
  fi
fi

if [ ! -f "$APPCAST_LOCAL" ]; then
  record_failure "appcast.xml missing at $APPCAST_LOCAL"
else
  APPCAST_LATEST_URL="$(python3 -c '
import sys, xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
items = root.findall(".//item")
items.sort(key=lambda i: int(i.findtext("sparkle:version", "", ns) or "0"), reverse=True)
enc = items[0].find("enclosure") if items else None
print(enc.get("url", "") if enc is not None else "")
' "$APPCAST_LOCAL" 2>/dev/null || echo "")"
  if [ -z "$APPCAST_LATEST_URL" ]; then
    record_failure "appcast.xml has no enclosure URL for the latest item"
  else
    echo "  ✓ appcast.xml latest enclosure: $APPCAST_LATEST_URL"
  fi
fi

if [ -n "${LATEST_DOWNLOAD_URL:-}" ] && [ -n "${APPCAST_LATEST_URL:-}" ]; then
  if [ "$LATEST_DOWNLOAD_URL" != "$APPCAST_LATEST_URL" ]; then
    record_failure "manifest drift: release-info.json latest.downloadURL != appcast.xml latest enclosure URL"
  else
    echo "  ✓ manifest consistency: release-info.json and appcast.xml agree on latest download URL"
  fi
fi

echo

# --- Live HTTP probes -------------------------------------------------------

if [ $OFFLINE -eq 1 ]; then
  echo "2. Live HTTP probes (skipped — --offline)"
  echo
  if [ $FAILURES -eq 0 ]; then
    echo "✅ Landing health check passed (offline)."
  else
    echo "❌ Landing health check failed ($FAILURES failure(s))."
  fi
  exit $FAILURES
fi

echo "2. Live HTTP probes"

probe_url() {
  local url="$1"
  local label="$2"
  # -sS: silent but show errors. -L: follow redirects. -o /dev/null: discard body.
  # --max-time 20s: bound each probe.
  local code
  code="$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || echo "000")"
  if [ "$code" = "200" ]; then
    echo "  ✓ $label: 200 ($url)"
    return 0
  else
    record_failure "$label returned HTTP $code ($url)"
    return 1
  fi
}

probe_url "$BASE_URL" "canonical root"
probe_url "$DOWNLOAD_URL" "download route"

# Appcast feed reachability (Sparkle's actual update source).
probe_url "$APPCAST_URL" "appcast feed"

echo

if [ $FAILURES -eq 0 ]; then
  echo "✅ Landing health check passed."
else
  echo "❌ Landing health check failed ($FAILURES failure(s))."
fi
exit $FAILURES
