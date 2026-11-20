#!/usr/bin/env bash
# 设置签名用的 Bundle ID（包名）与 Team ID，写入 Config/Signing.xcconfig（不纳入版本控制）。
# 用法：scripts/setup-signing.sh <Bundle ID> [Team ID]
#   例：scripts/setup-signing.sh com.yourname.ehviewer
# 不填 Team ID 时从钥匙串中的 Apple Development 证书读取（在 Xcode 中登录 Apple ID 并创建证书后才有）。
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=${1:-}
TEAM=${2:-}
OUT=Config/Signing.xcconfig

if [[ -z "$BUNDLE_ID" ]]; then
  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

# Bundle ID：字母、数字、连字符，用点分成至少两段
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "Bundle ID 格式不对：只能用字母、数字和连字符（-），用点分成至少两段，如 com.yourname.ehviewer" >&2
  exit 1
fi
case "$BUNDLE_ID" in
  com.example.*|com.yourname.*)
    echo "请换成你自己的 Bundle ID，不要用示例值" >&2
    exit 1 ;;
esac

if [[ -z "$TEAM" ]]; then
  # 证书主题中的 OU 就是 Team ID，O 是账号名称
  subjects=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl crl2pkcs7 -nocrl -certfile /dev/stdin 2>/dev/null \
    | openssl pkcs7 -print_certs -noout 2>/dev/null | grep '^subject' || true)
  teams=$(printf '%s\n' "$subjects" | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p' | sort -u)
  count=$(printf '%s\n' "$teams" | grep -c . || true)
  if [[ $count -eq 0 ]]; then
    echo "钥匙串中没有 Apple Development 证书，读不到 Team ID。" >&2
    echo "在 Xcode → Settings → Accounts 中登录 Apple ID，选中账号后点 Manage Certificates…，按 + 选 Apple Development 创建证书，然后重新运行本脚本；" >&2
    echo "也可以直接指定 Team ID：scripts/setup-signing.sh $BUNDLE_ID <Team ID>" >&2
    exit 1
  fi
  if [[ $count -gt 1 ]]; then
    echo "钥匙串中有多个 Team，请在命令末尾指定一个：" >&2
    for t in $teams; do
      name=$(printf '%s\n' "$subjects" | grep -m1 -E "OU ?= ?$t" | sed -nE 's/.*[/,] ?O ?= ?([^/,]+).*/\1/p')
      echo "  $t  $name" >&2
    done
    echo "例：scripts/setup-signing.sh $BUNDLE_ID $(printf '%s\n' "$teams" | head -1)" >&2
    exit 1
  fi
  TEAM=$teams
fi
if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Team ID 应为 10 位大写字母与数字" >&2
  exit 1
fi

old=$(sed -nE 's/^PRODUCT_BUNDLE_IDENTIFIER *= *([^ ]+).*/\1/p' "$OUT" 2>/dev/null || true)
if [[ -n "$old" && "$old" != "$BUNDLE_ID" ]]; then
  echo "注意：Bundle ID 由 ${old} 改为 ${BUNDLE_ID}，装好后是另一个 App，原来那个 App 的数据不会带过来。"
fi

cat > "$OUT" <<EOF
// 本机签名设置（scripts/setup-signing.sh 生成，不纳入版本控制）
DEVELOPMENT_TEAM = $TEAM
PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID
EOF
echo "已写入 ${OUT}：Team ID ${TEAM}，Bundle ID ${BUNDLE_ID}"
echo "下一步：xcodegen generate && open EhViewer.xcodeproj"
