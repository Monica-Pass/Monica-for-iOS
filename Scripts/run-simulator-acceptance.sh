#!/usr/bin/env bash
#
# 在 iOS 模拟器里跑 Monica 的端到端验收自检（不依赖 XCTest）。
#
# 背景：本仓库的开发机可能没有完整 Xcode / 未开启 Developer Mode，此时
# `xcodebuild test` 会卡在 `DTServiceHubClient failed to bless service hub`。
# App 内置了 `--monica-simulator-acceptance` 自检入口，用真实 App 代码 + 真实
# MDBX + 真实 Keychain 在模拟器里跑一遍主要功能，输出结构化报告并退出。
#
# 用法：
#   Scripts/run-simulator-acceptance.sh                  # 自动挑一台 iPhone，构建并运行
#   Scripts/run-simulator-acceptance.sh --skip-build     # 复用 /tmp/dd-acceptance 的产物
#   Scripts/run-simulator-acceptance.sh --device <UDID>  # 指定模拟器
#   Scripts/run-simulator-acceptance.sh --keep-running   # 跑完不卸载，便于继续截图/排查
#
# 产物：
#   docs/acceptance/acceptance-report.json   （最近一次运行的报告）
#   docs/acceptance/screenshots/*.png        （启动态截图）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.monicapass.monica"
DERIVED="/tmp/dd-acceptance"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Monica.app"
OUT_DIR="$ROOT/docs/acceptance"
UDID=""
SKIP_BUILD=0
KEEP_RUNNING=0

while [ $# -gt 0 ]; do
  case "$1" in
    --device) UDID="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep-running) KEEP_RUNNING=1; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

cd "$ROOT"
mkdir -p "$OUT_DIR/screenshots"

if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl list devices available \
    | grep -E "iPhone [0-9]" \
    | grep -oE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}" \
    | head -1)"
fi
if [ -z "$UDID" ]; then
  echo "找不到可用的 iPhone 模拟器，请先安装 iOS Simulator runtime。" >&2
  exit 1
fi
echo "==> 设备：$UDID"

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "==> 构建 App（build-for-testing，模拟器）"
  xcodebuild build-for-testing \
    -project Monica.xcodeproj \
    -scheme Monica \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
fi
if [ ! -d "$APP" ]; then
  echo "缺少构建产物：$APP（去掉 --skip-build 重试）" >&2
  exit 1
fi

echo "==> 启动模拟器"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

echo "==> 安装"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

echo "==> 截图：启动态"
xcrun simctl io "$UDID" screenshot "$OUT_DIR/screenshots/01-launch.png" >/dev/null 2>&1 || true

echo "==> 运行验收自检（--monica-simulator-acceptance）"
LOG="/tmp/monica-acceptance.log"
set +e
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" --monica-simulator-acceptance \
  >"$LOG" 2>&1
LAUNCH_STATUS=$?
set -e

# 等 App 写报告并退出；最多 10 分钟。
for _ in $(seq 1 60); do
  DATA_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
  if [ -n "$DATA_DIR" ] && [ -f "$DATA_DIR/Documents/acceptance-report.json" ]; then
    break
  fi
  sleep 10
done

DATA_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
REPORT="$DATA_DIR/Documents/acceptance-report.json"
if [ -f "$REPORT" ]; then
  cp "$REPORT" "$OUT_DIR/acceptance-report.json"
  echo "==> 报告：$OUT_DIR/acceptance-report.json"
  python3 - "$OUT_DIR/acceptance-report.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(f"    passed={data.get('passed')} failed={data.get('failed')}")
for step in data.get("steps", []):
    mark = "PASS" if step.get("passed") else "FAIL"
    if step.get("skipped"):
        mark = "SKIP"
    print(f"    [{mark}] {step.get('id')}: {step.get('title')} — {step.get('detail')}")
PY
else
  echo "!! 没有拿到验收报告，App 可能提前退出。运行日志：$LOG" >&2
  tail -40 "$LOG" >&2 || true
fi

if [ "$KEEP_RUNNING" -eq 0 ]; then
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
fi

echo "==> 日志：$LOG"
if [ "$LAUNCH_STATUS" -ne 0 ]; then
  echo "注意：simctl launch 返回 $LAUNCH_STATUS（App 以非零状态退出通常表示有验收步骤失败）" >&2
fi
