#!/usr/bin/env bash
# 在 Mac 上执行：签名编译并安装到已配对的真机（局域网无线即可）
# 用法：DEVICE=<设备名或UDID> scripts/install-device.sh [Debug|Release]
# - Team ID 与 Bundle ID 读取 Config/Signing.xcconfig（scripts/setup-signing.sh 生成）；TEAM=<Team ID> 可临时覆盖 Team
# - 描述文件过期或第一次安装时，先在 Xcode 中点一次 Run 生成描述文件；或加 PROVISION_UPDATES=1 让命令行自动更新
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/bin:$PATH"
CONFIG=${1:-Release}
DEVICE=${DEVICE:?需要 DEVICE（设备名或 UDID，可用 xcrun devicectl list devices 查看）}
TEAM=${TEAM:-}
if [[ ! -f Config/Signing.xcconfig ]]; then
  echo "还没有设置签名：先运行 scripts/setup-signing.sh <Bundle ID>（见 README）" >&2
  exit 1
fi
UDID=$(xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE" | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
UDID=${UDID:-$DEVICE}
xcodegen generate --quiet
xcodebuild -project EhViewer.xcodeproj -scheme EhViewer -configuration "$CONFIG" \
  -destination "id=$UDID" -derivedDataPath build/DeviceData \
  ${PROVISION_UPDATES:+-allowProvisioningUpdates -allowProvisioningDeviceRegistration} \
  ${TEAM:+DEVELOPMENT_TEAM=$TEAM} CODE_SIGN_STYLE=Automatic \
  -skipPackagePluginValidation build -quiet 2>&1 | grep -vE "^\s*$" | tail -25
APP="build/DeviceData/Build/Products/${CONFIG}-iphoneos/EhViewer.app"
xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | tail -5
echo "签名到期：$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || echo 未知)"
