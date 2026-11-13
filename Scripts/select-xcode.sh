#!/usr/bin/env bash
#
# 选择要用于构建的 Xcode，并注入 GITHUB_ENV（本地运行时只打印）。
#
# 设计目标：不硬编码 Xcode 路径，让 CI 自动跟随 runner 上已安装的最新版本，
# 避免每次 Xcode 升级都要改 workflow。
#
# 用法：
#   select-xcode.sh                 # 选已安装的最新正式版；没有正式版则取最新任意版本
#   select-xcode.sh --include-beta  # 连 beta/preview 一起比较版本号
#   select-xcode.sh 26.5            # 固定版本（找不到就失败）
#   select-xcode.sh --list          # 只列出探测到的版本
#
# 环境变量：
#   MONICA_XCODE_VERSION  与位置参数等价，供 workflow 直接传入
#
set -euo pipefail

INCLUDE_BETA=0
WANTED=""
LIST_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --include-beta) INCLUDE_BETA=1 ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) WANTED="$1" ;;
  esac
  shift
done

[ -n "${MONICA_XCODE_VERSION:-}" ] && WANTED="$MONICA_XCODE_VERSION"

# 收集候选：/Applications 下的 Xcode*.app
candidates=()
shopt -s nullglob
for app in /Applications/Xcode*.app; do
  candidates+=("$app")
done

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "::error::No Xcode installation found under /Applications." >&2
  exit 1
fi

# 从 app 里读实际版本号，而不是靠文件名猜。
version_of() {
  local app="$1"
  local plist="$app/Contents/version.plist"
  if [ -f "$plist" ]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null && return 0
  fi
  # 退路：从 Info.plist 读 DTXcode / 直接从目录名提取
  plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist" 2>/dev/null && return 0
  basename "$app" .app | sed 's/^Xcode[-_]//; s/^$//'
}

is_prerelease() {
  local app="$1" ver="$2"
  case "$app" in
    *[Bb]eta*|*[Pp]review*) return 0 ;;
  esac
  # 形如 27.0 但 SDK 是 27 → 仍可能是正式版；这里只按名字判断，保守处理
  return 1
}

# 用 sort -V 做版本排序：把 "<version> <path>" 逐行喂进去
ranked() {
  local line
  for app in "${candidates[@]}"; do
    local ver
    ver="$(version_of "$app" || true)"
    [ -n "$ver" ] || continue
    if [ "$INCLUDE_BETA" = "0" ] && is_prerelease "$app" "$ver"; then
      continue
    fi
    printf '%s\t%s\n' "$ver" "$app"
  done | sort -V
}

if [ "$LIST_ONLY" = "1" ]; then
  echo "Detected Xcode installations:"
  ranked | while IFS=$'\t' read -r ver app; do
    printf '  %-10s %s\n' "$ver" "$app"
  done
  exit 0
fi

CHOSEN_APP=""
CHOSEN_VER=""

if [ -n "$WANTED" ]; then
  # 精确匹配版本号，前缀匹配兜底（26.5 匹配 26.5.1）
  while IFS=$'\t' read -r ver app; do
    if [ "$ver" = "$WANTED" ]; then
      CHOSEN_APP="$app"; CHOSEN_VER="$ver"; break
    fi
  done < <(printf '%s\n' "$(for app in "${candidates[@]}"; do
      ver="$(version_of "$app" || true)"; [ -n "$ver" ] || continue
      printf '%s\t%s\n' "$ver" "$app"
    done | sort -V)")

  if [ -z "$CHOSEN_APP" ]; then
    while IFS=$'\t' read -r ver app; do
      case "$ver" in
        "$WANTED"*) CHOSEN_APP="$app"; CHOSEN_VER="$ver"; break ;;
      esac
    done < <(for app in "${candidates[@]}"; do
      ver="$(version_of "$app" || true)"; [ -n "$ver" ] || continue
      printf '%s\t%s\n' "$ver" "$app"
    done | sort -V)
  fi

  if [ -z "$CHOSEN_APP" ]; then
    echo "::error::Requested Xcode $WANTED not found. Available:" >&2
    ranked >&2 || true
    exit 1
  fi
else
  # 取最新一条
  last="$(ranked | tail -1)"
  if [ -z "$last" ]; then
    echo "::error::No usable Xcode found (try --include-beta)." >&2
    exit 1
  fi
  CHOSEN_VER="${last%%$'\t'*}"
  CHOSEN_APP="${last##*$'\t'}"
fi

DEVELOPER_DIR="$CHOSEN_APP/Contents/Developer"
if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "::error::$DEVELOPER_DIR does not exist." >&2
  exit 1
fi

echo "Selected Xcode $CHOSEN_VER ($CHOSEN_APP)"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "DEVELOPER_DIR=$DEVELOPER_DIR"
    echo "MONICA_XCODE_VERSION=$CHOSEN_VER"
  } >> "$GITHUB_ENV"
  # 立即生效，供同一 step 内使用
  export DEVELOPER_DIR
fi

xcodebuild -version
xcrun --sdk iphonesimulator --show-sdk-version
