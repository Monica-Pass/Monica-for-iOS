#!/usr/bin/env bash
#
# 从上游 MDBX workspace 生成 UniFFI Swift 绑定（Generated/MDBXUniFFI/）。
#
# 只做「宿主机构建 + 生成绑定」：cargo 用当前 toolchain 编译 mdbx-ffi 的
# debug dylib（macOS host），uniffi-bindgen-swift 从中读取接口元数据。
# iOS/macOS 各架构的静态库与 xcframework 打包见 build-mdbx-xcframework.sh。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/mdbx-common.sh
source "$SCRIPT_DIR/mdbx-common.sh"

require_mdbx_workspace
UNIFFI_VERSION="$(resolve_uniffi_version)"
UNIFFI_BIN="$(require_uniffi_cli "$UNIFFI_VERSION")"
if ! CARGO="$(find_tool cargo)"; then
  monica_fail "找不到 cargo，无法编译 mdbx-ffi。请安装 Rust：https://rustup.rs"
fi

OUT_DIR="$REPO_DIR/Generated/MDBXUniFFI"
LIB_PATH="$MDBX_DIR/target/debug/libmdbx_ffi.dylib"

monica_info "上游 workspace：$MDBX_DIR"
monica_info "UniFFI：${UNIFFI_VERSION}（${UNIFFI_BIN}）"

cd "$MDBX_DIR"
"$CARGO" build -p mdbx-ffi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

"$UNIFFI_BIN" --swift-sources "$LIB_PATH" "$OUT_DIR"
"$UNIFFI_BIN" --headers "$LIB_PATH" "$OUT_DIR"
"$UNIFFI_BIN" \
  --modulemap \
  --xcframework \
  --module-name MonicaMDBXGenerated \
  "$LIB_PATH" \
  "$OUT_DIR"

# 生成器在接口变化/参数不兼容时可能只产出部分文件，这里显式断言，
# 避免下游拿到半套绑定后在编译期才报错。
for artifact in mdbx_ffi.swift mdbx_ffiFFI.h mdbx_ffi.modulemap; do
  if [ ! -f "$OUT_DIR/$artifact" ]; then
    monica_fail "uniffi-bindgen-swift $UNIFFI_VERSION 未产出 $OUT_DIR/$artifact"
  fi
done

cat > "$OUT_DIR/README.md" <<'EOF'
# Generated UniFFI Bindings

本目录由 `Scripts/generate-mdbx-swift-bindings.sh` 生成，对应上游 MDBX workspace 的
`crates/mdbx-ffi`。Swift / 头文件 / modulemap 都不要手工修改。

产物去向：

- `Generated/MDBXUniFFI/` 是构建中间产物，已被 `.gitignore` 排除。
- 同一份 Swift 绑定会被复制到
  `SwiftPackages/MonicaMDBX/Sources/MonicaMDBX/Generated/mdbx_ffi.swift` 并**入库**，
  外层包 `#if canImport(mdbx_ffiFFI)`：缺少 xcframework 的 checkout 仍能解析并编译
  `MonicaMDBX`，运行时走 `MonicaMDBX.swift` 的 stub 实现。

重新生成（同时会刷新入库的那份 Swift 绑定）：

```bash
Scripts/bootstrap.sh --force
```
EOF

echo "Generated Swift bindings in: $OUT_DIR"
