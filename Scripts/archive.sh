#!/usr/bin/env bash
#
# 归档并（可选）上传到 App Store Connect。
#
# 注意：iOS 应用不涉及「公证」（notarization）——那是 macOS 分发的要求。
# iOS 的分发链路是：签名 → archive → 导出 .ipa → 上传 App Store Connect。
#
# 关于 uploadSymbols=false：
# macOS 26 的 /usr/bin/rsync 是 openrsync，不支持 -E；Xcode 打包 IPA 时会用
# 它拷 dSYM 目录，必然报 "rsync: unknown option" → "Copy failed"。
# 因此 ExportOptions.plist 里关掉了符号上传，dSYM 仍留在
# $ARCHIVE_PATH/Products/dSYMs，需要时可单独上传。
#
# 前置条件：
#   1. Apple Developer Program 有效（team ID 见 $MONICA_TEAM_ID）
#   2. Xcode 已登录该账号（Settings → Accounts），或设置 App Store Connect API Key
#   3. 门户中已为该 team 创建下列 App ID 与 App Group：
#        com.monicapass.monica
#        com.monicapass.monica.autofill
#        com.monicapass.monica.share
#        com.monicapass.monica.widget
#        App Group: group.com.monicapass.monica
#      且已为 App ID 开启对应 Capability（App Groups / Keychain Sharing /
#      AutoFill Credential Provider）。
#
# 用法：
#   Scripts/archive.sh                       # 只归档 + 导出 ipa
#   Scripts/archive.sh --upload              # 归档 + 导出 + 上传
#   Scripts/archive.sh --version 0.2.0 --build 12
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$IOS_DIR"

MONICA_TEAM_ID="${MONICA_TEAM_ID:-X84WC7J5JH}"
BUILD_DIR="$IOS_DIR/Build"
ARCHIVE_PATH="$BUILD_DIR/Monica.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

DO_UPLOAD=0
VERSION=""
BUILD_NUMBER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --upload) DO_UPLOAD=1 ;;
    --version) shift; VERSION="${1:-}" ;;
    --build) shift; BUILD_NUMBER="${1:-}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "Artifacts/MDBX/MonicaMDBXGenerated.xcframework" ] \
  || fail "缺少 MDBX 产物，先运行 Scripts/bootstrap.sh"

[ -n "$MONICA_TEAM_ID" ] || fail "未设置 MONICA_TEAM_ID"

info "选择 Xcode"
"$SCRIPT_DIR/select-xcode.sh"

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

VERSION_ARGS=()
[ -n "$VERSION" ] && VERSION_ARGS+=("MARKETING_VERSION=$VERSION")
[ -n "$BUILD_NUMBER" ] && VERSION_ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")

info "归档（team $MONICA_TEAM_ID）"
xcodebuild archive \
  -project Monica.xcodeproj \
  -scheme Monica \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$MONICA_TEAM_ID" \
  ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
  | tail -20

[ -d "$ARCHIVE_PATH" ] || fail "归档产物不存在（自动签名失败？检查是否已注册至少一台设备）"

info "导出 ipa"
# ExportOptions.plist 里 destination 是 upload；不打算上传时改成 export，
# 否则 -exportArchive 会直接尝试连 App Store Connect 并因缺 App 记录而失败。
EXPORT_OPTS="$BUILD_DIR/ExportOptions.effective.plist"
cp ExportOptions.plist "$EXPORT_OPTS"
if [ "$DO_UPLOAD" = "1" ]; then
  plutil -replace destination -string upload "$EXPORT_OPTS"
else
  plutil -replace destination -string export "$EXPORT_OPTS"
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTS" \
  -allowProvisioningUpdates \
  | tail -15

info "产物：$EXPORT_PATH"
ls -la "$EXPORT_PATH"
info "dSYM（未随包上传）：$ARCHIVE_PATH/Products/dSYMs"

if [ "$DO_UPLOAD" = "1" ]; then
  IPA="$(find "$EXPORT_PATH" -name '*.ipa' | head -1)"
  [ -n "$IPA" ] || fail "未找到 .ipa"
  info "上传 App Store Connect"
  # 需要 App Store Connect API Key：APP_STORE_CONNECT_API_KEY_ID / ISSUER_ID / KEY_PATH
  if [ -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]; then
    xcrun altool --upload-app \
      --file "$IPA" \
      --type ios \
      --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
      --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID"
  else
    fail "上传需要 APP_STORE_CONNECT_API_KEY_PATH / _KEY_ID / _ISSUER_ID，或直接在 Xcode Organizer 里分发"
  fi
fi
