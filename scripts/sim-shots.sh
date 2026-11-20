#!/usr/bin/env bash
# 在 Mac 上批量截图：scripts/sim-shots.sh <名称> <等待秒> [启动参数...]，可重复调用；设置 SIM_DEVICE / APPEARANCE=dark
set -uo pipefail
cd "$(dirname "$0")/.."
NAME=$1; WAIT=$2; shift 2
DEVICE=${SIM_DEVICE:-"iPhone 18 Pro"}
UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
xcrun simctl ui "$UDID" appearance "${APPEARANCE:-light}"
APP=build/DerivedData/Build/Products/Debug-iphonesimulator/EhViewer.app
xcrun simctl install "$UDID" "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null
xcrun simctl launch "$UDID" "$BUNDLE_ID" -EHDisableImages YES "$@" >/dev/null
sleep "$WAIT"
mkdir -p build/shots
xcrun simctl io "$UDID" screenshot "build/shots/$NAME.png" >/dev/null 2>&1
sips -Z 1100 "build/shots/$NAME.png" --out "build/shots/s-$NAME.png" >/dev/null
