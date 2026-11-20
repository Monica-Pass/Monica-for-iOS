#!/usr/bin/env bash
#
# 供 MDBX/UniFFI 各构建脚本 source 的公共函数（本文件不被直接执行）。
#
# 两条约定：
#   1. 仓库路径一律从**本文件位置**推导，绝不依赖当前工作目录——这些脚本会被
#      Xcode Run Script、CI、以及任意 cwd 下的 agent 调用。
#   2. UniFFI 版本由上游 MDBX crate 决定，不由本仓库臆测：`uniffi` 会把接口
#      checksum 与 contract version 写进生成的 Swift/C 头文件，Swift 生成器必须
#      与 `crates/mdbx-ffi` 编译时使用的 uniffi 版本**完全一致**。只升一侧会得到
#      链接失败或运行时 contract 校验失败的绑定。
#
# 调用方必须先 `set -euo pipefail` 再 source 本文件。

MONICA_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 脚本目录即 <repo>/Scripts，因此仓库根 = 上两级。
REPO_DIR="$(cd "$MONICA_COMMON_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REPO_DIR/.." && pwd)"
UNIFFI_VERSION_FALLBACK_FILE="$MONICA_COMMON_DIR/uniffi-version.txt"

monica_info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
monica_warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
monica_error() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
monica_fail() {
  monica_error "$*"
  exit 1
}

# 上游 MDBX workspace 定位：
#   1. MONICA_MDBX_DIR 环境变量（CI 用；checkout 到任意位置）
#   2. 同级目录 $REPO_ROOT/mdbx（本地开发的默认布局）
#   3. 仓库内子目录 $REPO_DIR/mdbx（CI 单次 checkout 的默认布局）
# 注意：macOS 默认大小写不敏感，所以 $REPO_ROOT/mdbx 会命中本机上的 `Mdbx/`；
# Linux（区分大小写）上必须显式设置 MONICA_MDBX_DIR 或使用小写目录名。
resolve_mdbx_dir() {
  if [ -n "${MONICA_MDBX_DIR:-}" ]; then
    printf '%s\n' "$MONICA_MDBX_DIR"
  elif [ -d "$REPO_ROOT/mdbx/crates/mdbx-ffi" ]; then
    printf '%s\n' "$REPO_ROOT/mdbx"
  elif [ -d "$REPO_DIR/mdbx/crates/mdbx-ffi" ]; then
    printf '%s\n' "$REPO_DIR/mdbx"
  else
    printf '%s\n' "$REPO_ROOT/mdbx"
  fi
}

MDBX_DIR="$(resolve_mdbx_dir)"

# xcframework 覆盖的三个平台所需的四个 Rust target。bootstrap.sh 用这份列表
# 校验 std，build-mdbx-xcframework.sh 用同名的 MDBX_* 逐个构建——单一来源，
# 避免「构建脚本加了 target、bootstrap 忘了校验」。
MDBX_DEVICE_TARGET="aarch64-apple-ios"
MDBX_SIM_ARM64_TARGET="aarch64-apple-ios-sim"
MDBX_SIM_X86_64_TARGET="x86_64-apple-ios"
MDBX_MACOS_ARM64_TARGET="aarch64-apple-darwin"
# shellcheck disable=SC2034 # 由 source 本文件的脚本使用。
MDBX_TARGETS=(
  "$MDBX_DEVICE_TARGET"
  "$MDBX_SIM_ARM64_TARGET"
  "$MDBX_SIM_X86_64_TARGET"
  "$MDBX_MACOS_ARM64_TARGET"
)

# 校验上游 workspace 存在且是我们认识的结构；失败时打印可执行的修复提示。
require_mdbx_workspace() {
  local dir="${1:-$MDBX_DIR}"
  if [ ! -d "$dir" ]; then
    monica_error "找不到上游 MDBX workspace：$dir"
    cat >&2 <<EOF

默认约定是「MDBX 与本仓库同级」：

  $(basename "$REPO_ROOT")/
  ├── $(basename "$REPO_DIR")/   ← 本仓库
  └── mdbx/            ← 上游 MDBX workspace

获取方式：
  git clone https://github.com/Monica-Pass/Mdbx.git "$dir"

如果本仓库是 git worktree（目录不在上述位置），用环境变量显式指定：
  MONICA_MDBX_DIR=/path/to/Mdbx Scripts/bootstrap.sh
EOF
    return 1
  fi
  if [ ! -d "$dir/crates/mdbx-ffi" ]; then
    monica_error "上游 MDBX workspace 不完整（缺 crates/mdbx-ffi）：$dir"
    return 1
  fi
}

# 查找工具的可执行文件。优先 rustup 管理的 toolchain：Homebrew 的 rust 只带 host
# std，如果用它的 rustc 构建 iOS 目标会缺 std；rustup toolchain 才带 `rustup target
# add` 装好的 iOS/macOS std。找不到 rustup 时退回 PATH 与 ~/.cargo/bin。
find_tool() {
  local name="$1" rustup_bin tool_path cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  if rustup_bin="$(command -v rustup 2>/dev/null)"; then
    if tool_path="$("$rustup_bin" which "$name" 2>/dev/null)" && [ -x "$tool_path" ]; then
      printf '%s\n' "$tool_path"
      return 0
    fi
  fi
  # cargo install 的产物固定在 CARGO_HOME/bin（CI 是 ~/.cargo/bin）。
  # 放在 PATH 之前，避免 runner 镜像预装的旧版本抢先命中。
  if [ -x "$cargo_home/bin/$name" ]; then
    printf '%s\n' "$cargo_home/bin/$name"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  if [ -x "$HOME/.cargo/bin/$name" ]; then
    printf '%s\n' "$HOME/.cargo/bin/$name"
    return 0
  fi
  return 1
}

# 从上游 Cargo.lock 读取 `uniffi` crate 的版本（权威来源）。
uniffi_version_from_lock() {
  local dir="${1:-$MDBX_DIR}"
  local lock="$dir/Cargo.lock"
  [ -f "$lock" ] || return 1
  awk '
    /^\[\[package\]\]/ { in_package = 0 }
    /^name = "uniffi"$/ { in_package = 1; next }
    in_package && /^version = "/ {
      gsub(/^version = "|"$/, "")
      print
      exit
    }
  ' "$lock"
}

uniffi_version_from_fallback() {
  [ -f "$UNIFFI_VERSION_FALLBACK_FILE" ] || return 1
  sed -n 's/^[[:space:]]*\([0-9][0-9]*\(\.[0-9][0-9]*\)*\)[[:space:]]*$/\1/p' \
    "$UNIFFI_VERSION_FALLBACK_FILE" | head -n 1
}

# 解析本仓库必须使用的 UniFFI 版本。
#   MONICA_UNIFFI_VERSION 覆盖值必须与上游 Cargo.lock 一致——故意不提供"只升
#   Swift 生成器"的开关，那正是跨仓库升级最容易踩的坑。
resolve_uniffi_version() {
  local from_lock="" fallback="" override="${MONICA_UNIFFI_VERSION:-}"

  from_lock="$(uniffi_version_from_lock "$MDBX_DIR" || true)"
  fallback="$(uniffi_version_from_fallback || true)"

  if [ -n "$override" ]; then
    if [ -n "$from_lock" ] && [ "$override" != "$from_lock" ]; then
      monica_error "MONICA_UNIFFI_VERSION=$override 与上游 workspace 的 uniffi $from_lock 不一致。"
      cat >&2 <<EOF
UniFFI 的 Swift 生成器必须与 crates/mdbx-ffi 编译时使用的 uniffi 版本完全一致，
否则生成的绑定会链接失败或在运行时 contract 校验失败。

正确顺序：先在上游仓库把 crates/mdbx-ffi/Cargo.toml 的 uniffi 升到 $override
并更新 Cargo.lock，合并后再回本仓库重新生成绑定。
EOF
      return 1
    fi
    printf '%s\n' "$override"
    return 0
  fi

  if [ -n "$from_lock" ]; then
    printf '%s\n' "$from_lock"
    return 0
  fi
  if [ -n "$fallback" ]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  monica_error "无法确定 UniFFI 版本：既没有 $MDBX_DIR/Cargo.lock，也没有 $UNIFFI_VERSION_FALLBACK_FILE"
  return 1
}

uniffi_cli_path() {
  find_tool uniffi-bindgen-swift
}

uniffi_cli_version() {
  local bin="$1" output
  output="$("$bin" --version 2>/dev/null)" || return 1
  # 形如 "uniffi 0.31.1"
  printf '%s\n' "${output##* }"
}

uniffi_install_hint() {
  local version="$1"
  cat >&2 <<EOF

安装与本仓库匹配的生成器：
  cargo install uniffi --version $version --locked --features cli

或直接运行（幂等，已装对版本时不做任何事）：
  Scripts/uniffi-version.sh --install
EOF
}

# 返回可用的 uniffi-bindgen-swift 绝对路径；版本不符时失败，绝不静默使用旧版本。
require_uniffi_cli() {
  local required="$1" bin version
  if ! bin="$(uniffi_cli_path)"; then
    monica_error "找不到 uniffi-bindgen-swift（本仓库需要 uniffi ${required}）。"
    uniffi_install_hint "$required"
    return 1
  fi
  if ! version="$(uniffi_cli_version "$bin")"; then
    monica_error "无法读取 $bin 的版本（本仓库需要 uniffi ${required}）。"
    uniffi_install_hint "$required"
    return 1
  fi
  if [ "$version" != "$required" ]; then
    monica_error "uniffi-bindgen-swift 版本是 ${version}，但上游 workspace 需要 ${required}。"
    monica_error "用不匹配的生成器产出的绑定无法与 Rust 侧 ABI 对齐。"
    monica_error "实际使用：$bin"
    monica_error "PATH 上的候选：$(command -v uniffi-bindgen-swift 2>/dev/null || echo '<无>')"
    monica_error "CARGO_HOME/bin：${CARGO_HOME:-$HOME/.cargo}/bin/uniffi-bindgen-swift"
    uniffi_install_hint "$required"
    return 1
  fi
  printf '%s\n' "$bin"
}

# 安装（或替换成本仓库所需的）uniffi CLI。
install_uniffi_cli() {
  local required="$1" cargo
  if ! cargo="$(find_tool cargo)"; then
    monica_error "找不到 cargo，无法安装 uniffi CLI。请先安装 Rust：https://rustup.rs"
    return 1
  fi
  monica_info "安装 uniffi CLI ${required}（可能需要几分钟）"
  "$cargo" install uniffi --version "$required" --locked --features cli
  # cargo 装到 $CARGO_HOME/bin（默认 ~/.cargo/bin），确保本进程能找到。
  export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
  export PATH="$HOME/.cargo/bin:$PATH"
}

# Rust 的 iOS/macOS std 是否已安装。Homebrew 版 rust 只带 host std，
# 且 `rustup target list --installed` 会给出与实际 sysroot 不符的结果，
# 所以这里直接检查 sysroot 里的 rlib。
target_has_std() {
  local target="$1" rustc_bin="$2" rustlib_dir
  rustlib_dir="$("$rustc_bin" --print sysroot)/lib/rustlib/$target/lib"
  compgen -G "$rustlib_dir/libcore-*.rlib" >/dev/null
}

missing_std_targets() {
  local rustc_bin="$1" target
  shift
  for target in "$@"; do
    if ! target_has_std "$target" "$rustc_bin"; then
      printf '%s\n' "$target"
    fi
  done
}

# 校验 rustc 带齐指定目标的 std；缺失时打印可执行修复指引并返回 1。
# 第三个参数是调用方脚本路径（用于提示重跑命令）。
require_std_targets() {
  local rustc_bin="$1" caller="$2" target
  local missing=()
  shift 2
  # 不用 mapfile：macOS 自带的 bash 3.2 没有这个内建命令。
  while IFS= read -r target; do
    missing+=("$target")
  done < <(missing_std_targets "$rustc_bin" "$@")
  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi
  monica_error "当前 rustc（$("$rustc_bin" -V)）缺少这些目标的 std：${missing[*]}"
  monica_error "sysroot：$("$rustc_bin" --print sysroot)"
  cat >&2 <<EOF

Homebrew 版 rust 只带 host std；\`rustup target list --installed\` 会声称这些目标已装，
但 sysroot 里并没有——所以这里直接检查 sysroot。修复方式：

  # 用 rustup 管理的 toolchain（推荐）
  rustup toolchain install stable
  rustup target add ${missing[*]}

  # 若继续使用 Homebrew rust，需让 rustup 接管该 toolchain 后同样执行
  # rustup target add ${missing[*]}

补齐后重跑：
  $caller
EOF
  return 1
}
