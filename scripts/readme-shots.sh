#!/usr/bin/env bash
# 在 Mac 上执行：生成 README 的功能截图，输出到 docs/screenshots/（iPhone 宽 600、iPad 宽 1200 的 JPEG）。
# 用法：scripts/readme-shots.sh [测试名 ...]   只重拍部分截图时指定测试名，如 test01Browse、testPadBrowse
#
# - 截图由 AppUITests/ReadmeScreenshots.swift 拍摄，只打开 Non-H 分类的风景类画廊，不出现成人内容
# - 使用单独的模拟器“EhViewer README”和“EhViewer README iPad”（没有就新建）：未登录、没有其他下载与历史；状态栏固定为 9:41
# - 会访问 E-Hentai；阅读与下载演示会消耗少量图片额度。保留这两个模拟器，重拍时已下载的内容不会重复下载
# - 删除模拟器：xcrun simctl delete "EhViewer README" "EhViewer README iPad"
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/bin:$PATH"
PHONE="EhViewer README"
PAD="EhViewer README iPad"
PHONE_SHOTS=(01-browse 02-search 03-detail 04-detail-more 05-reader 07-downloads 08-me 09-network 10-transfer
  11-grid 12-context-menu 13-dark 14-vertical 15-reader-settings 16-download-settings)
PAD_SHOTS=(pad-browse pad-detail)
RUNTIME=$(xcrun simctl list runtimes available | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+$' | tail -1)

# 准备模拟器：没有就新建，启动后固定外观与状态栏
prepare() {  # 名称 机型
  local udid stamp
  udid=$(xcrun simctl list devices | grep -F "$1 (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)
  if [[ -z "$udid" ]]; then
    udid=$(xcrun simctl create "$1" "$2" "$RUNTIME")
    echo "新建模拟器：${1}（${2}）"
  fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance light
  # 时间固定为 1 月 9 日 9:41（iPad 状态栏还会显示日期）。simctl 只接受带毫秒的 UTC 时间，按本机时区换算
  stamp=$(date -u -r "$(date -j -f '%Y-%m-%d %H:%M:%S' '2007-01-09 09:41:00' +%s)" '+%Y-%m-%dT%H:%M:%S.000Z')
  xcrun simctl status_bar "$udid" override --time "$stamp" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
}

# 按附件名挑出截图，缩小后保存
export_shots() {  # 宽度 截图名...
  local width=$1 manifest=build/shots/ui/manifest.json i=0 j name file s
  shift
  while plutil -extract "$i" json -o /dev/null "$manifest" 2>/dev/null; do
    j=0
    while name=$(plutil -extract "$i.attachments.$j.suggestedHumanReadableName" raw -o - "$manifest" 2>/dev/null); do
      file=$(plutil -extract "$i.attachments.$j.exportedFileName" raw -o - "$manifest")
      name=${name%%_0_*}
      for s in "$@"; do
        if [[ "$name" == "$s" ]]; then
          sips -s format jpeg -s formatOptions 88 --resampleWidth "$width" "build/shots/ui/$file" --out "docs/screenshots/$s.jpg" >/dev/null
          echo "docs/screenshots/$s.jpg"
        fi
      done
      j=$((j + 1))
    done
    i=$((i + 1))
  done
}

# 测试名以 testPad 开头的在 iPad 上拍，其余在 iPhone 上拍；不指定时全部重拍
PHONE_TESTS=()
PAD_TESTS=()
for t in "$@"; do
  if [[ "$t" == testPad* ]]; then
    PAD_TESTS+=("EhViewerUITests/ReadmeScreenshots/$t")
  else
    PHONE_TESTS+=("EhViewerUITests/ReadmeScreenshots/$t")
  fi
done
if [[ $# -eq 0 ]]; then
  PHONE_TESTS=(EhViewerUITests/ReadmeScreenshots)
  PAD_TESTS=(EhViewerUITests/ReadmeScreenshots)
fi

mkdir -p docs/screenshots
STATUS=0
if [[ ${#PHONE_TESTS[@]} -gt 0 ]]; then
  TYPE=$(xcrun simctl list devicetypes | grep -oE '^iPhone [0-9]+ Pro \(' | sed -E 's/ \($//' | sort -t' ' -k2 -n | tail -1)
  prepare "$PHONE" "$TYPE"
  TEST_RUNNER_README_SHOTS=1 SIM_DEVICE="$PHONE" scripts/ui-test.sh "${PHONE_TESTS[@]}" || STATUS=$?
  export_shots 600 "${PHONE_SHOTS[@]}"
fi
if [[ ${#PAD_TESTS[@]} -gt 0 ]]; then
  TYPE=$(xcrun simctl list devicetypes | grep -oE '^iPad Pro 11-inch \(M[0-9]+\) \(com' | sed -E 's/ \(com$//' | sort -t'M' -k2 -n | tail -1)
  prepare "$PAD" "$TYPE"
  TEST_RUNNER_README_SHOTS=1 SIM_DEVICE="$PAD" scripts/ui-test.sh "${PAD_TESTS[@]}" || STATUS=$?
  export_shots 1200 "${PAD_SHOTS[@]}"
fi
exit $STATUS
