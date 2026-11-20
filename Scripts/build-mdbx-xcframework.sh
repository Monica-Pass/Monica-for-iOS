#!/usr/bin/env bash
#
# 为 iOS 设备 / iOS 模拟器 / macOS 三个平台编译 mdbx-ffi 静态库，并打包成
# Artifacts/MDBX/MonicaMDBXGenerated.xcframework；同时把 Swift 绑定同步进
# SwiftPackages/MonicaMDBX/Sources/MonicaMDBX/Generated/（入库副本）。
#
# 上游 workspace 定位见 Scripts/mdbx-common.sh（MONICA_MDBX_DIR 优先）。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/mdbx-common.sh
source "$SCRIPT_DIR/mdbx-common.sh"

require_mdbx_workspace

GENERATED_DIR="$REPO_DIR/Generated/MDBXUniFFI"
BUILD_DIR="$REPO_DIR/Build/MDBX"
HEADERS_DIR="$BUILD_DIR/Headers"
ARTIFACTS_DIR="$REPO_DIR/Artifacts/MDBX"
XCFRAMEWORK_PATH="$ARTIFACTS_DIR/MonicaMDBXGenerated.xcframework"
SWIFTPM_BINDINGS_DIR="$REPO_DIR/SwiftPackages/MonicaMDBX/Sources/MonicaMDBX/Generated"

# target 列表定义在 Scripts/mdbx-common.sh（bootstrap.sh 的 std 校验共用同一份）。
DEVICE_TARGET="$MDBX_DEVICE_TARGET"
SIM_ARM64_TARGET="$MDBX_SIM_ARM64_TARGET"
SIM_X86_64_TARGET="$MDBX_SIM_X86_64_TARGET"
MACOS_ARM64_TARGET="$MDBX_MACOS_ARM64_TARGET"
MIN_IOS_VERSION="17.0"
# macOS slice 让 MonicaStorage / MonicaMDBX 能在 macOS 上直接 swift test。
# 缺它时新版 SwiftPM 会因 binaryTarget 无此平台而在解析/构建阶段报错。
MACOS_DEPLOYMENT_VERSION="13.0"

if ! CARGO="$(find_tool cargo)"; then
  monica_fail "找不到 cargo，无法构建 MonicaMDBXGenerated.xcframework。请安装 Rust：https://rustup.rs"
fi
if ! RUSTC="$(find_tool rustc)"; then
  monica_fail "找不到 rustc，无法构建 MonicaMDBXGenerated.xcframework。请安装 Rust：https://rustup.rs"
fi

cargo_dir="$(dirname "$CARGO")"
export PATH="$cargo_dir:$PATH"

for tool in xcrun xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    monica_fail "$tool 是构建 MonicaMDBXGenerated.xcframework 的必需项（需要完整 Xcode）。"
  fi
done

if ! require_std_targets \
  "$RUSTC" \
  "$SCRIPT_DIR/build-mdbx-xcframework.sh" \
  "${MDBX_TARGETS[@]}"; then
  exit 2
fi

"$SCRIPT_DIR/generate-mdbx-swift-bindings.sh"

IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
IPHONEOS_CLANG="$(xcrun --sdk iphoneos -f clang)"
SIMULATOR_CLANG="$(xcrun --sdk iphonesimulator -f clang)"
IPHONEOS_AR="$(xcrun --sdk iphoneos -f ar)"
SIMULATOR_AR="$(xcrun --sdk iphonesimulator -f ar)"

rm -rf "$BUILD_DIR" "$XCFRAMEWORK_PATH"
mkdir -p "$HEADERS_DIR" "$ARTIFACTS_DIR"

cp "$GENERATED_DIR/mdbx_ffiFFI.h" "$HEADERS_DIR/"
cat > "$HEADERS_DIR/module.modulemap" <<'EOF'
module mdbx_ffiFFI {
    header "mdbx_ffiFFI.h"
    export *
}
EOF

cd "$MDBX_DIR"

env \
  SDKROOT="$IPHONEOS_SDK" \
  RUSTC="$RUSTC" \
  CC_aarch64_apple_ios="$IPHONEOS_CLANG" \
  AR_aarch64_apple_ios="$IPHONEOS_AR" \
  CFLAGS_aarch64_apple_ios="-isysroot $IPHONEOS_SDK -miphoneos-version-min=$MIN_IOS_VERSION" \
  CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$IPHONEOS_CLANG" \
  RUSTFLAGS="-C link-arg=-isysroot -C link-arg=$IPHONEOS_SDK -C link-arg=-miphoneos-version-min=$MIN_IOS_VERSION" \
  "$CARGO" build -p mdbx-ffi --target "$DEVICE_TARGET" --release

env \
  SDKROOT="$SIMULATOR_SDK" \
  RUSTC="$RUSTC" \
  CC_aarch64_apple_ios_sim="$SIMULATOR_CLANG" \
  AR_aarch64_apple_ios_sim="$SIMULATOR_AR" \
  CFLAGS_aarch64_apple_ios_sim="-isysroot $SIMULATOR_SDK -mios-simulator-version-min=$MIN_IOS_VERSION" \
  CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER="$SIMULATOR_CLANG" \
  RUSTFLAGS="-C link-arg=-isysroot -C link-arg=$SIMULATOR_SDK -C link-arg=-mios-simulator-version-min=$MIN_IOS_VERSION" \
  "$CARGO" build -p mdbx-ffi --target "$SIM_ARM64_TARGET" --release

env \
  SDKROOT="$SIMULATOR_SDK" \
  RUSTC="$RUSTC" \
  CC_x86_64_apple_ios="$SIMULATOR_CLANG" \
  AR_x86_64_apple_ios="$SIMULATOR_AR" \
  CFLAGS_x86_64_apple_ios="-isysroot $SIMULATOR_SDK -mios-simulator-version-min=$MIN_IOS_VERSION" \
  CARGO_TARGET_X86_64_APPLE_IOS_LINKER="$SIMULATOR_CLANG" \
  RUSTFLAGS="-C link-arg=-isysroot -C link-arg=$SIMULATOR_SDK -C link-arg=-mios-simulator-version-min=$MIN_IOS_VERSION" \
  "$CARGO" build -p mdbx-ffi --target "$SIM_X86_64_TARGET" --release

# macOS slice：纯 Swift 包在 macOS 上 swift test 时需要它。
env \
  MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_VERSION" \
  "$CARGO" build -p mdbx-ffi --target "$MACOS_ARM64_TARGET" --release

mkdir -p "$BUILD_DIR/Simulator"
lipo -create \
  "$MDBX_DIR/target/$SIM_ARM64_TARGET/release/libmdbx_ffi.a" \
  "$MDBX_DIR/target/$SIM_X86_64_TARGET/release/libmdbx_ffi.a" \
  -output "$BUILD_DIR/Simulator/libmdbx_ffi.a"

xcodebuild -create-xcframework \
  -library "$MDBX_DIR/target/$DEVICE_TARGET/release/libmdbx_ffi.a" \
  -headers "$HEADERS_DIR" \
  -library "$BUILD_DIR/Simulator/libmdbx_ffi.a" \
  -headers "$HEADERS_DIR" \
  -library "$MDBX_DIR/target/$MACOS_ARM64_TARGET/release/libmdbx_ffi.a" \
  -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK_PATH"

echo "Created XCFramework: $XCFRAMEWORK_PATH"
echo "Swift binding source: $GENERATED_DIR/mdbx_ffi.swift"

mkdir -p "$SWIFTPM_BINDINGS_DIR"
tmp_binding="$(mktemp "$SWIFTPM_BINDINGS_DIR/.mdbx_ffi.swift.XXXXXX")"
{
  # 用 canImport 守卫而非 os(iOS)：守卫条件必须与 MonicaMDBX.swift 一致，
  # 否则 iOS 之外（如 macOS slice 存在时）会出现类型不可见的编译错误。
  # 缺产物时整个文件不参与编译，由 MonicaMDBX.swift 的 stub 回落。
  echo "#if canImport(mdbx_ffiFFI)"
  cat "$GENERATED_DIR/mdbx_ffi.swift"
  printf "\n#endif\n"
} > "$tmp_binding"
# 原子替换：Xcode 并行读取该文件时不会看到半个文件。
mv "$tmp_binding" "$SWIFTPM_BINDINGS_DIR/mdbx_ffi.swift"
echo "Synced SwiftPM binding source: $SWIFTPM_BINDINGS_DIR/mdbx_ffi.swift"
