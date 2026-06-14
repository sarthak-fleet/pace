#!/usr/bin/env bash
#
# rebuild-local-signed.sh — local Release rebuild + reinstall signed with a
# STABLE self-signed cert so macOS TCC grants survive the rebuild.
#
# Why this exists
# ---------------
# Ad-hoc signing (`codesign --sign -`) gives the app no stable identity, so
# TCC falls back to the binary's cdhash, which changes every build — every
# rebuild looks like a brand-new app and screen-recording / accessibility /
# mic grants reset. This script signs with the "Pace Local Signing" cert in a
# dedicated keychain (created once, see ~/.config/pace-signing), whose
# designated requirement is anchored to the cert root hash. That requirement
# is identical across rebuilds, so the grants persist — NO tccutil reset, NO
# re-granting after a rebuild.
#
# This is the local-dev path. The real fix for distribution is a paid Apple
# Developer ID Application cert + notarization; this gives the same
# TCC-persistence benefit for free on this machine.
#
# Usage:  bash scripts/rebuild-local-signed.sh
#
# First run only: the "Pace Local Signing" keychain/cert must already exist
# (created out-of-band). If it's missing, the script stops with instructions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/release"
APP_NAME="Pace"
SCHEME="leanring-buddy"
APP_PATH="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"

# Local-machine VLM model that actually loads in LM Studio here. The repo
# default (ui-venus-1.5-2b) is correct for the codebase but doesn't load on
# this Mac, so the installed app pins the 8b@4bit build instead.
LOCAL_VLM_MODEL_ID="ui-venus-1.5-8b@4bit"

# The working Xcode (the /Applications/Xcode.app stub is broken on this beta).
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Users/sarthak/Downloads/Xcode-beta.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Users/sarthak/Downloads/Xcode-beta.app/Contents/Developer"
    fi
fi

# Locate the stable signing identity. Use the dedicated keychain so we never
# depend on it being in the global search list. NOTE: -v (valid only) is
# intentionally NOT used — a self-signed cert reads as untrusted, which is
# fine for signing and for TCC (TCC keys on the cert hash, not CA trust).
KEYCHAIN="$HOME/.config/pace-signing/pace-signing.keychain-db"
KC_PW="pace-local-signing-2026"
if [[ ! -f "$KEYCHAIN" ]]; then
    echo "❌ Signing keychain not found: $KEYCHAIN" >&2
    echo "   The 'Pace Local Signing' cert hasn't been created on this machine yet." >&2
    exit 1
fi
security unlock-keychain -p "$KC_PW" "$KEYCHAIN"
CERT_HASH="$(security find-identity -p codesigning "$KEYCHAIN" \
    | awk '/Pace Local Signing/{print $2; exit}')"
if [[ -z "$CERT_HASH" ]]; then
    echo "❌ 'Pace Local Signing' identity not found in $KEYCHAIN" >&2
    exit 1
fi
echo "🔑 Signing identity: $CERT_HASH (Pace Local Signing)"

echo "🏗  Building Release into $BUILD_DIR ..."
xcodebuild \
    -project "$PROJECT_DIR/leanring-buddy.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    > "$BUILD_DIR/local-signed-build.log" 2>&1
if [[ ! -d "$APP_PATH" ]]; then
    echo "❌ Build failed. Tail of $BUILD_DIR/local-signed-build.log:" >&2
    tail -40 "$BUILD_DIR/local-signed-build.log" >&2
    exit 1
fi
echo "✅ Built $APP_PATH"

echo "📦 Bundling start-tts-server.sh ..."
mkdir -p "$APP_PATH/Contents/Resources/scripts"
cp "$PROJECT_DIR/scripts/start-tts-server.sh" "$APP_PATH/Contents/Resources/scripts/start-tts-server.sh"
chmod +x "$APP_PATH/Contents/Resources/scripts/start-tts-server.sh"

echo "🧩 Pinning local VLM model id: $LOCAL_VLM_MODEL_ID"
/usr/libexec/PlistBuddy -c "Set :LocalVLMModelIdentifier $LOCAL_VLM_MODEL_ID" \
    "$APP_PATH/Contents/Info.plist"

echo "🔐 Signing frameworks + app with the stable cert ..."
find "$APP_PATH/Contents/Frameworks" -maxdepth 2 -name "*.framework" -type d 2>/dev/null \
    | while read -r fw; do
        codesign --force --sign "$CERT_HASH" --keychain "$KEYCHAIN" "$fw" >/dev/null 2>&1
    done
codesign --force --deep --sign "$CERT_HASH" --keychain "$KEYCHAIN" "$APP_PATH" >/dev/null 2>&1
codesign --verify --deep --strict "$APP_PATH" && echo "✅ Codesign verify passed"
echo "   designated requirement:"
codesign -d -r- "$APP_PATH" 2>&1 | grep -i designated | sed 's/^/   /'

echo "🚪 Quitting running Pace ..."
osascript -e 'quit app "Pace"' 2>/dev/null || true
sleep 2
pgrep -x Pace >/dev/null && { pkill -x Pace || true; sleep 2; } || true

echo "📥 Installing to /Applications/Pace.app ..."
rm -rf /Applications/Pace.app
ditto "$APP_PATH" /Applications/Pace.app

# Deliberately NO `tccutil reset` here: the whole point is that the stable
# cert keeps the grants. Resetting would re-trigger the permission prompts
# we're trying to eliminate.

echo "🚀 Relaunching ..."
open /Applications/Pace.app
sleep 2
if pgrep -x Pace >/dev/null; then
    echo "✅ Pace rebuilt + reinstalled (cert-signed). TCC grants should be intact."
else
    echo "⚠️  Pace did not relaunch — open it manually."
fi
