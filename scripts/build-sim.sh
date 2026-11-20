#!/usr/bin/env bash
# 在 Mac 上执行：为模拟器编译（用于验证 App 层能否编译），输出精简错误
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/bin:$PATH"
xcodegen generate --quiet
xcodebuild -project EhViewer.xcodeproj -scheme EhViewer -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation build 2>&1 \
  | grep -E "error:|warning: .*deprecated|BUILD (SUCCEEDED|FAILED)" | sort -u | head -${MAX_ERRORS:-80}
