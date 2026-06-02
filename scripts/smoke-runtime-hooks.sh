#!/usr/bin/env bash
#
# App-level smoke checks for Pace runtime behavior that is brittle to drive
# through SwiftUI Accessibility. Requires a built Debug Pace.app and launches it
# with PACE_ENABLE_SMOKE_HOOKS=1.

set -euo pipefail

APP_PATH="${PACE_APP_PATH:-}"
if [[ -z "$APP_PATH" ]]; then
    APP_PATH="$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug/Pace.app 2>/dev/null | head -1)"
fi

if [[ -z "$APP_PATH" || ! -x "$APP_PATH/Contents/MacOS/Pace" ]]; then
    echo "missing Debug Pace.app; build from Xcode first" >&2
    exit 1
fi

post_notification() {
    local notification_name="$1"
    swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name(\"${notification_name}\"), object: nil, userInfo: nil, deliverImmediately: true)"
}

read_default() {
    local key="$1"
    defaults read com.pace.app "$key" 2>/dev/null || true
}

wait_for_default() {
    local key="$1"
    local expected_value="$2"
    for _attempt in {1..30}; do
        local actual_value
        actual_value="$(read_default "$key")"
        if [[ "$actual_value" == "$expected_value" ]]; then
            return 0
        fi
        sleep 0.2
    done
    echo "expected $key=$expected_value, got $(read_default "$key")" >&2
    return 1
}

send_escape() {
    swift -e 'import CoreGraphics; import Foundation; let keyCode: CGKeyCode = 0x35; CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.05); CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)'
}

cleanup() {
    launchctl unsetenv PACE_ENABLE_SMOKE_HOOKS 2>/dev/null || true
    pkill -x Pace 2>/dev/null || true
}
trap cleanup EXIT

defaults delete com.pace.app PaceSmoke.lastPanelCommand 2>/dev/null || true
defaults delete com.pace.app PaceSmoke.lastCursorAnnotationsEnabled 2>/dev/null || true
defaults delete com.pace.app PaceSmoke.lastApprovalAllowed 2>/dev/null || true
defaults delete com.pace.app PaceSmoke.ready 2>/dev/null || true

pkill -x Pace 2>/dev/null || true
sleep 1
launchctl setenv PACE_ENABLE_SMOKE_HOOKS 1
open "$APP_PATH"

wait_for_default PaceSmoke.ready 1

post_notification "com.pace.smoke.showPanel"
wait_for_default PaceSmoke.lastPanelCommand show

post_notification "com.pace.smoke.cursorAnnotationsOff"
wait_for_default PaceSmoke.lastCursorAnnotationsEnabled 0

post_notification "com.pace.smoke.cursorAnnotationsOn"
wait_for_default PaceSmoke.lastCursorAnnotationsEnabled 1

post_notification "com.pace.smoke.requestApproval"
sleep 0.7
send_escape
wait_for_default PaceSmoke.lastApprovalAllowed 0

post_notification "com.pace.smoke.hidePanel"
wait_for_default PaceSmoke.lastPanelCommand hide

echo "runtime smoke hooks passed"
