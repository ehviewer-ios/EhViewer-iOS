#!/usr/bin/env bash
# 在 Mac 上执行：在模拟器上运行 UI 测试，截图导出到 build/shots/ui/。
# 用法：[CONFIG=Release] [SIM_DEVICE=<模拟器名>] scripts/ui-test.sh [测试名 ...]，测试名如 EhViewerUITests/BrowseUITests/testSearchSubmitShowsToolbar
# 测试会访问 E-Hentai（需要网络）。使用单独生成的工程（project-uitests.yml），会覆盖 EhViewer.xcodeproj，
# 与日常编译放在不同的目录中运行更方便
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/bin:$PATH"
DEVICE=${SIM_DEVICE:-"iPhone 18 Pro"}
xcodegen generate --quiet --spec project-uitests.yml
ONLY=()
for t in "$@"; do ONLY+=("-only-testing:$t"); done
rm -rf build/UITests.xcresult build/shots/ui
xcodebuild test -project EhViewer.xcodeproj -scheme EhViewerUITests -configuration "${CONFIG:-Debug}" \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath build/DerivedData \
  -resultBundlePath build/UITests.xcresult CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation \
  ${ONLY[@]+"${ONLY[@]}"} 2>&1 \
  | grep -E "error:|Test Case .*(passed|failed)|XCTAssert|Executed|TEST (SUCCEEDED|FAILED)|\*\* TEST" | head -${MAX_LINES:-80}
STATUS=${PIPESTATUS[0]}
mkdir -p build/shots/ui
xcrun xcresulttool export attachments --path build/UITests.xcresult --output-path build/shots/ui >/dev/null 2>&1 || true
ls build/shots/ui 2>/dev/null | grep -c png | sed 's/^/attachments: /'
exit $STATUS
