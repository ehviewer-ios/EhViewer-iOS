#!/usr/bin/env bash
# 在 Mac 上执行：编译到模拟器、安装、启动并截图
# 用法：scripts/sim-run.sh <截图文件名> [等待秒数] [额外启动参数...]
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/bin:$PATH"
SHOT=${1:-shot.png}; WAIT=${2:-8}; shift 2 || true
DEVICE=${SIM_DEVICE:-"iPhone 18 Pro"}
UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
APP=build/DerivedData/Build/Products/Debug-iphonesimulator/EhViewer.app
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  xcodegen generate --quiet
  xcodebuild -project EhViewer.xcodeproj -scheme EhViewer -configuration Debug -sdk iphonesimulator \
    -destination "id=$UDID" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build -quiet 2>&1 | grep -E "error:" | head -20
fi
xcrun simctl install "$UDID" "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null
xcrun simctl launch "$UDID" "$BUNDLE_ID" -EHDisableImages YES "$@"
sleep "$WAIT"
mkdir -p build/shots
xcrun simctl io "$UDID" screenshot "build/shots/$SHOT" >/dev/null 2>&1
echo "shot: build/shots/$SHOT"
# 崩溃检测
if ! xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -qF "$BUNDLE_ID"; then echo "APP NOT RUNNING (crashed?)"; fi
