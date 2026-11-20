#!/usr/bin/env bash
#
# 一键准备 MDBX 原生产物（Artifacts/MDBX/MonicaMDBXGenerated.xcframework）。
#
# 全新 clone 后运行本脚本，即可让 Monica.xcodeproj 正常构建。
# 产物已存在且未指定 --force 时直接跳过（此时不需要 Rust 工具链）。
#
# 用法：
#   Scripts/bootstrap.sh            # 产物存在则跳过，否则构建
#   Scripts/bootstrap.sh --force    # 强制重新构建
#
# 上游 workspace 定位、UniFFI 版本与 Rust target 校验统一实现在
# Scripts/mdbx-common.sh，本脚本只负责编排。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/mdbx-common.sh
source "$SCRIPT_DIR/mdbx-common.sh"

XCFRAMEWORK_PATH="$REPO_DIR/Artifacts/MDBX/MonicaMDBXGenerated.xcframework"


FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      monica_fail "未知参数：${arg}（可用：--force、--help）"
      ;;
  esac
done

# ---------- 1. 产物已存在 ----------
if [ -d "$XCFRAMEWORK_PATH" ] && [ "$FORCE" = "0" ]; then
  monica_info "MDBX 产物已存在，跳过：$XCFRAMEWORK_PATH"
  monica_info "如需重新生成，请运行：Scripts/bootstrap.sh --force"
  exit 0
fi

# ---------- 2. 前置检查 ----------
monica_info "检查上游 MDBX workspace"
require_mdbx_workspace

monica_info "检查 Rust 工具链"
if ! find_tool cargo >/dev/null; then
  monica_fail "找不到 cargo。请安装 Rust：https://rustup.rs"
fi
if ! RUSTC="$(find_tool rustc)"; then
  monica_fail "找不到 rustc。请安装 Rust：https://rustup.rs"
fi

# 先尽力自动补 target（rustup 缺失或指向别的 toolchain 时忽略失败），
# 再由 require_std_targets 以 sysroot 为准做权威校验。
missing_targets="$(missing_std_targets "$RUSTC" "${MDBX_TARGETS[@]}")"
if [ -n "$missing_targets" ] && RUSTUP="$(find_tool rustup)"; then
  # shellcheck disable=SC2086
  monica_info "尝试安装缺失的 Rust target：${missing_targets//$'\n'/ }"
  # shellcheck disable=SC2086
  "$RUSTUP" target add $missing_targets || monica_warn "rustup target add 未成功，继续以 sysroot 校验"
fi
if ! require_std_targets "$RUSTC" "$SCRIPT_DIR/bootstrap.sh" "${MDBX_TARGETS[@]}"; then
  exit 2
fi

monica_info "检查 UniFFI CLI"
"$SCRIPT_DIR/uniffi-version.sh" --install

# ---------- 3. 构建 ----------
monica_info "开始生成 MDBX xcframework（首次约 1-2 分钟）"
"$SCRIPT_DIR/build-mdbx-xcframework.sh"

[ -d "$XCFRAMEWORK_PATH" ] || monica_fail "构建结束但未找到产物：$XCFRAMEWORK_PATH"

monica_info "完成：$XCFRAMEWORK_PATH"
monica_info "入库的 Swift 绑定也已同步：SwiftPackages/MonicaMDBX/Sources/MonicaMDBX/Generated/mdbx_ffi.swift"
monica_warn "若上游接口有变化，请把该文件一起提交（此前生成的是同一份绑定的旧版本）。"
cat <<'EOF'

现在可以构建工程了：

  xcodebuild -project Monica.xcodeproj -scheme Monica \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build

EOF
