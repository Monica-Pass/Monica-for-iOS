#!/usr/bin/env bash
#
# 打印 / 校验 / 安装本仓库所需的 UniFFI CLI 版本。
#
# 版本来源（优先级从高到低）：
#   1. MONICA_UNIFFI_VERSION（跨仓库协同升级时的显式覆盖，必须与上游 Cargo.lock 一致）
#   2. 上游 workspace 的 Cargo.lock（权威：crates/mdbx-ffi 实际编译用的 uniffi）
#   3. Scripts/uniffi-version.txt（最后一次验证过的配对，仅在上游 checkout 缺失时生效）
#
# 用法：
#   Scripts/uniffi-version.sh            打印所需版本（CI 取缓存 key 用）
#   Scripts/uniffi-version.sh --check    确认已安装的 uniffi-bindgen-swift 版本匹配
#   Scripts/uniffi-version.sh --install  缺失或版本不符时安装（幂等，已装对则跳过）
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/mdbx-common.sh
source "$SCRIPT_DIR/mdbx-common.sh"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

mode="${1:---print}"
case "$mode" in
  --print|"")
    resolve_uniffi_version
    ;;
  --check)
    version="$(resolve_uniffi_version)"
    bin="$(require_uniffi_cli "$version")"
    printf 'uniffi-bindgen-swift %s (%s)\n' "$version" "$bin"
    printf 'PATH 候选：%s\n' "$(command -v uniffi-bindgen-swift 2>/dev/null || echo '<无>')"
    printf 'CARGO_HOME：%s\n' "${CARGO_HOME:-<未设置，默认 $HOME/.cargo>}"
    ;;
  --install)
    version="$(resolve_uniffi_version)"
    if bin="$(uniffi_cli_path)" && [ "$(uniffi_cli_version "$bin" || true)" = "$version" ]; then
      monica_info "uniffi-bindgen-swift $version 已就绪：$bin"
      exit 0
    fi
    install_uniffi_cli "$version"
    bin="$(require_uniffi_cli "$version")"
    monica_info "uniffi-bindgen-swift $version 已安装：$bin"
    ;;
  -h|--help)
    usage
    ;;
  *)
    monica_error "未知参数：$mode"
    usage >&2
    exit 2
    ;;
esac
