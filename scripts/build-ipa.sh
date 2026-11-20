#!/usr/bin/env bash
# 在 Mac 上执行：生成 Xcode 工程并打出未签名 IPA（再用 Sideloadly / AltStore 等签名工具签名安装）
# 用法：[BUNDLE_ID=<Bundle ID>] scripts/build-ipa.sh [Debug|Release]
# Bundle ID 默认取 xcconfig 中的值（有 Config/Signing.xcconfig 时用其中的值），BUNDLE_ID 可临时指定
set -euo pipefail
CONFIG=${1:-Release}
cd "$(dirname "$0")/.."
export PATH="$HOME/bin:$PATH"
xcodegen generate --quiet
xcodebuild -project EhViewer.xcodeproj -scheme EhViewer -configuration "$CONFIG" \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  ${BUNDLE_ID:+PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID} \
  -skipPackagePluginValidation build -quiet
APP="build/DerivedData/Build/Products/${CONFIG}-iphoneos/EhViewer.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")
IPA="build/EhViewer-$VERSION-unsigned.ipa"
rm -rf build/ipa "$IPA" && mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qry "../$(basename "$IPA")" Payload)
echo "IPA: $(pwd)/$IPA"
echo "Bundle ID: $(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")"
