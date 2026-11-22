#!/usr/bin/env bash
#
# 在 iOS 模拟器上跑 Monica 的 XCTest（App target + MonicaTests）。
#
# 为什么需要这个脚本：
#   本机同时装了两套 Xcode。`xcode-select` 指向的 Xcode-beta 27.0 在 macOS 27.3 上
#   跑测试会失败于
#       DTServiceHubClient failed to bless service hub for simulator ...
#   而 /Applications/Xcode.app（27.2）可以正常执行。脚本因此默认优先使用
#   /Applications/Xcode.app，找不到时才退回 `xcode-select -p`。
#
# 用法：
#   Scripts/run-ios-tests.sh                       # 构建并跑全量 MonicaTests
#   Scripts/run-ios-tests.sh --skip-build          # 复用上次的 DerivedData
#   Scripts/run-ios-tests.sh --device "iPhone 17"
#   Scripts/run-ios-tests.sh --only MonicaTests/MDBXRoundTripTests
#   Scripts/run-ios-tests.sh --xcode /Applications/Xcode-beta.app
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCODE_APP="${XCODE_APP:-/Applications/Xcode.app}"
DEVICE=""
ONLY=""
SKIP_BUILD=0
DERIVED="${DERIVED_DATA:-/tmp/dd-ios-tests}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --xcode) XCODE_APP="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --derived-data) DERIVED="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$XCODE_APP/Contents/Developer" ]]; then
  echo "找不到 $XCODE_APP，改用 xcode-select -p" >&2
  XCODE_APP="$(dirname "$(dirname "$(xcode-select -p)")")"
fi
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"

echo "==> Xcode：$(DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -version | tr '\n' ' ')"

if [[ -z "$DEVICE" ]]; then
  # 优先选已启动的 iPhone，其次选最新的 iPhone 设备
  DEVICE="$(xcrun simctl list devices booted | awk -F'[()]' '/iPhone/ {print $2; exit}')"
  if [[ -z "$DEVICE" ]]; then
    DEVICE="$(xcrun simctl list devices available | awk -F'[()]' '/iPhone/ {print $2; exit}')"
  fi
fi
if [[ -z "$DEVICE" ]]; then
  echo "没有可用的 iPhone 模拟器，请先在 Xcode 或 simctl 里创建。" >&2
  exit 1
fi
echo "==> 设备：$DEVICE"

DEST="platform=iOS Simulator,id=$DEVICE"
COMMON=(-project Monica.xcodeproj -scheme Monica -destination "$DEST"
        -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)

if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "==> build-for-testing"
  xcodebuild build-for-testing "${COMMON[@]}" | tail -3
fi

echo "==> test-without-building"
ARGS=(test-without-building "${COMMON[@]}")
if [[ -n "$ONLY" ]]; then
  ARGS+=(-only-testing:"$ONLY")
fi
set +e
xcodebuild "${ARGS[@]}" 2>&1 | tee /tmp/monica-ios-tests.log | grep -E "Test Suite '.*' (passed|failed)|Executed [0-9]+ tests|error:|\*\* TEST (SUCCEEDED|FAILED) \*\*" | tail -40
STATUS=${PIPESTATUS[0]}
set -e

echo "==> 完整日志：/tmp/monica-ios-tests.log"
exit "$STATUS"
