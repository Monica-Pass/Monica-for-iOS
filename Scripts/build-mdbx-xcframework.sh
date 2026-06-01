#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
MDBX_DIR="$REPO_ROOT/mdbx"
GENERATED_DIR="$IOS_DIR/Generated/MDBXUniFFI"
BUILD_DIR="$IOS_DIR/Build/MDBX"
HEADERS_DIR="$BUILD_DIR/Headers"
ARTIFACTS_DIR="$IOS_DIR/Artifacts/MDBX"
XCFRAMEWORK_PATH="$ARTIFACTS_DIR/MonicaMDBXGenerated.xcframework"
SWIFTPM_BINDINGS_DIR="$IOS_DIR/SwiftPackages/MonicaMDBX/Sources/MonicaMDBX/Generated"

DEVICE_TARGET="aarch64-apple-ios"
SIM_ARM64_TARGET="aarch64-apple-ios-sim"
SIM_X86_64_TARGET="x86_64-apple-ios"
MIN_IOS_VERSION="17.0"

find_tool() {
  local name="$1"
  if [ -x "/opt/homebrew/opt/rustup/bin/$name" ]; then
    echo "/opt/homebrew/opt/rustup/bin/$name"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  if [ -x "$HOME/.cargo/bin/$name" ]; then
    echo "$HOME/.cargo/bin/$name"
    return 0
  fi
  return 1
}

CARGO="$(find_tool cargo || true)"
RUSTC="$(find_tool rustc || true)"

if [ -z "$CARGO" ] || [ -z "$RUSTC" ]; then
  echo "cargo and rustc are required to build MonicaMDBXGenerated.xcframework." >&2
  exit 1
fi

export PATH="$(dirname "$CARGO"):$PATH"

for tool in xcrun xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required to build MonicaMDBXGenerated.xcframework." >&2
    exit 1
  fi
done

target_has_std() {
  local target="$1"
  local rustlib_dir
  rustlib_dir="$("$RUSTC" --print sysroot)/lib/rustlib/$target/lib"
  compgen -G "$rustlib_dir/libcore-*.rlib" >/dev/null
}

missing_targets=()
for target in "$DEVICE_TARGET" "$SIM_ARM64_TARGET" "$SIM_X86_64_TARGET"; do
  if ! target_has_std "$target"; then
    missing_targets+=("$target")
  fi
done

if [ "${#missing_targets[@]}" -gt 0 ]; then
  echo "Rust standard library is missing for: ${missing_targets[*]}" >&2
  echo "Install a rustup-managed toolchain and run:" >&2
  echo "  rustup target add ${missing_targets[*]}" >&2
  echo "Then re-run: Monica for iOS/Scripts/build-mdbx-xcframework.sh" >&2
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

cp "$GENERATED_DIR/mdbx_ios_ffiFFI.h" "$HEADERS_DIR/"
cat > "$HEADERS_DIR/module.modulemap" <<'EOF'
module mdbx_ios_ffiFFI {
    header "mdbx_ios_ffiFFI.h"
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
  "$CARGO" build -p mdbx-ios-ffi --target "$DEVICE_TARGET" --release

env \
  SDKROOT="$SIMULATOR_SDK" \
  RUSTC="$RUSTC" \
  CC_aarch64_apple_ios_sim="$SIMULATOR_CLANG" \
  AR_aarch64_apple_ios_sim="$SIMULATOR_AR" \
  CFLAGS_aarch64_apple_ios_sim="-isysroot $SIMULATOR_SDK -mios-simulator-version-min=$MIN_IOS_VERSION" \
  CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER="$SIMULATOR_CLANG" \
  RUSTFLAGS="-C link-arg=-isysroot -C link-arg=$SIMULATOR_SDK -C link-arg=-mios-simulator-version-min=$MIN_IOS_VERSION" \
  "$CARGO" build -p mdbx-ios-ffi --target "$SIM_ARM64_TARGET" --release

env \
  SDKROOT="$SIMULATOR_SDK" \
  RUSTC="$RUSTC" \
  CC_x86_64_apple_ios="$SIMULATOR_CLANG" \
  AR_x86_64_apple_ios="$SIMULATOR_AR" \
  CFLAGS_x86_64_apple_ios="-isysroot $SIMULATOR_SDK -mios-simulator-version-min=$MIN_IOS_VERSION" \
  CARGO_TARGET_X86_64_APPLE_IOS_LINKER="$SIMULATOR_CLANG" \
  RUSTFLAGS="-C link-arg=-isysroot -C link-arg=$SIMULATOR_SDK -C link-arg=-mios-simulator-version-min=$MIN_IOS_VERSION" \
  "$CARGO" build -p mdbx-ios-ffi --target "$SIM_X86_64_TARGET" --release

mkdir -p "$BUILD_DIR/Simulator"
lipo -create \
  "$MDBX_DIR/target/$SIM_ARM64_TARGET/release/libmdbx_ios_ffi.a" \
  "$MDBX_DIR/target/$SIM_X86_64_TARGET/release/libmdbx_ios_ffi.a" \
  -output "$BUILD_DIR/Simulator/libmdbx_ios_ffi.a"

xcodebuild -create-xcframework \
  -library "$MDBX_DIR/target/$DEVICE_TARGET/release/libmdbx_ios_ffi.a" \
  -headers "$HEADERS_DIR" \
  -library "$BUILD_DIR/Simulator/libmdbx_ios_ffi.a" \
  -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK_PATH"

echo "Created XCFramework: $XCFRAMEWORK_PATH"
echo "Swift binding source: $GENERATED_DIR/mdbx_ios_ffi.swift"

mkdir -p "$SWIFTPM_BINDINGS_DIR"
{
  echo "#if os(iOS)"
  cat "$GENERATED_DIR/mdbx_ios_ffi.swift"
  printf "\n#endif\n"
} > "$SWIFTPM_BINDINGS_DIR/mdbx_ios_ffi.swift"
echo "Synced SwiftPM binding source: $SWIFTPM_BINDINGS_DIR/mdbx_ios_ffi.swift"
