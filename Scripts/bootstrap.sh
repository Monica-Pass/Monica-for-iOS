#!/usr/bin/env bash
#
# 一键准备 MDBX 原生产物（Artifacts/MDBX/MonicaMDBXGenerated.xcframework）。
#
# 全新 clone 后运行本脚本，即可让 Monica.xcodeproj 正常构建。
# 若产物已存在且不是 --force，则直接跳过。
#
# 用法：
#   Scripts/bootstrap.sh            # 产物存在则跳过，否则构建
#   Scripts/bootstrap.sh --force    # 强制重新构建
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"

if [ -n "${MONICA_MDBX_DIR:-}" ]; then
  MDBX_DIR="$MONICA_MDBX_DIR"
elif [ -d "$REPO_ROOT/mdbx/crates/mdbx-ffi" ]; then
  MDBX_DIR="$REPO_ROOT/mdbx"
elif [ -d "$IOS_DIR/mdbx/crates/mdbx-ffi" ]; then
  MDBX_DIR="$IOS_DIR/mdbx"
else
  MDBX_DIR="$REPO_ROOT/mdbx"
fi
XCFRAMEWORK_PATH="$IOS_DIR/Artifacts/MDBX/MonicaMDBXGenerated.xcframework"
UNIFFI_VERSION="0.31.1"
IOS_TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin)

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. 产物已存在 ----------
if [ -d "$XCFRAMEWORK_PATH" ] && [ "$FORCE" = "0" ]; then
  info "MDBX 产物已存在，跳过：$XCFRAMEWORK_PATH"
  info "如需重新生成，请运行：Scripts/bootstrap.sh --force"
  exit 0
fi

# ---------- 2. 前置检查 ----------
info "检查上游 MDBX workspace"
if [ ! -d "$MDBX_DIR" ]; then
  fail "$(cat <<EOF
找不到上游 MDBX workspace：$MDBX_DIR

构建脚本要求目录结构如下（MDBX 必须与本仓库同级）：

  $(basename "$REPO_ROOT")/
  ├── Monica-for-iOS/   ← 本仓库
  └── mdbx/            ← 上游 MDBX workspace

获取方式：
  git clone https://github.com/Monica-Pass/Mdbx.git "$MDBX_DIR"
EOF
)"
fi
if [ ! -d "$MDBX_DIR/crates/mdbx-ffi" ]; then
  fail "上游 MDBX workspace 不完整（缺 crates/mdbx-ffi）：$MDBX_DIR"
fi

info "检查 Rust 工具链"
for tool in cargo rustc; do
  command -v "$tool" >/dev/null 2>&1 || fail "缺少 $tool，请安装 rustup：https://rustup.rs"
done
if ! command -v rustup >/dev/null 2>&1; then
  fail "缺少 rustup（无法自动添加 iOS target），请安装：https://rustup.rs"
fi

MISSING_TARGETS=()
for target in "${IOS_TARGETS[@]}"; do
  if ! rustup target list --installed 2>/dev/null | grep -qx "$target"; then
    MISSING_TARGETS+=("$target")
  fi
done
if [ "${#MISSING_TARGETS[@]}" -gt 0 ]; then
  info "安装缺失的 Rust iOS target：${MISSING_TARGETS[*]}"
  rustup target add "${MISSING_TARGETS[@]}"
fi

info "检查 UniFFI CLI（需要 $UNIFFI_VERSION）"
if ! command -v uniffi-bindgen-swift >/dev/null 2>&1 \
   && [ ! -x "$HOME/.cargo/bin/uniffi-bindgen-swift" ]; then
  warn "未找到 uniffi-bindgen-swift，开始安装（可能需要几分钟）"
  cargo install uniffi --version "$UNIFFI_VERSION" --locked --features cli
fi
export PATH="$HOME/.cargo/bin:$PATH"
command -v uniffi-bindgen-swift >/dev/null 2>&1 \
  || fail "uniffi-bindgen-swift 安装后仍不可用，请检查 PATH"

# ---------- 3. 构建 ----------
info "开始生成 MDBX xcframework（首次约 1-2 分钟）"
"$SCRIPT_DIR/build-mdbx-xcframework.sh"

[ -d "$XCFRAMEWORK_PATH" ] || fail "构建结束但未找到产物：$XCFRAMEWORK_PATH"

info "完成：$XCFRAMEWORK_PATH"
info "现在可以构建工程了："
cat <<EOF

  xcodebuild -project Monica.xcodeproj -scheme Monica \\
    -sdk iphonesimulator -destination 'id=<simulator-udid>' \\
    CODE_SIGNING_ALLOWED=NO build

EOF
