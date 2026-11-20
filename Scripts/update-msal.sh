#!/usr/bin/env bash
#
# 维护 vendored 的 MSAL（Artifacts/MSAL/MSAL.xcframework）。
#
# MSAL 以 binaryTarget 形式内置在仓库里（SwiftPackages/MSAL/Package.swift 直接指向
# Artifacts/MSAL/MSAL.xcframework），没有 SwiftPM 版本号可 pin，所以版本 / 校验和
# 统一由本脚本声明，供升级与 CI 校验共用。
#
# 用法：
#   Scripts/update-msal.sh --print     # 打印当前 pin 的版本与来源
#   Scripts/update-msal.sh --verify    # 校验 Artifacts/MSAL 是否仍与 pin 一致（CI 用）
#   Scripts/update-msal.sh --update    # 下载官方 release、校验 sha256、重新打包
#
# 只保留 iOS 设备 / iOS 模拟器 / macOS 三个 slice：App 只构建这两个平台，
# 官方包里的 visionOS slice 从未被链接，纳入仓库只会让二进制体积翻倍。
# 官方 zip 的 _CodeSignature 封印覆盖全部 5 个 slice，重新打包后必然失效，
# 因此 --update 会用 ad-hoc 签名重新封装一次，保证 codesign --verify 通过。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/mdbx-common.sh
source "$SCRIPT_DIR/mdbx-common.sh"

MSAL_VERSION="2.18.1"
MSAL_SHA256="980223874c4a432a1bc2fd52d5e98621d8c0898ab18893a9f23b0bfa940a8a75"
MSAL_URL="https://github.com/AzureAD/microsoft-authentication-library-for-objc/releases/download/${MSAL_VERSION}/MSAL.zip"
MSAL_SLICES=(ios-arm64 ios-arm64_x86_64-simulator macos-arm64_x86_64)
DEST_DIR="$REPO_DIR/Artifacts/MSAL"
DEST_XCFRAMEWORK="$DEST_DIR/MSAL.xcframework"

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    monica_fail "找不到 shasum / sha256sum，无法校验 MSAL 下载包。"
  fi
}

# 读取 xcframework 与各 slice 的 Info.plist，校验版本、slice 集合与 privacy manifest。
# 用 python3/plistlib 而非 plutil：CI 的 lint job 跑在 ubuntu 上，也要能校验。
verify_artifact() {
  if [ ! -d "$DEST_XCFRAMEWORK" ]; then
    monica_fail "缺少 vendored MSAL：${DEST_XCFRAMEWORK}（运行 Scripts/update-msal.sh --update）"
  fi
  python3 - "$DEST_XCFRAMEWORK" "$MSAL_VERSION" "${MSAL_SLICES[@]}" <<'PY'
import glob
import os
import plistlib
import sys

root = sys.argv[1]
expected_version = sys.argv[2]
expected_slices = sorted(sys.argv[3:])
problems = []


def framework_plist(framework_dir):
    """返回 framework 的 Info.plist 路径。

    iOS slice 是平铺 layout（MSAL.framework/Info.plist），macOS slice 是
    versioned layout（MSAL.framework/Versions/A/Resources/Info.plist）。
    """
    candidates = [os.path.join(framework_dir, "Info.plist")]
    candidates.extend(sorted(glob.glob(os.path.join(framework_dir, "Versions", "*", "Resources", "Info.plist"))))
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    return None


with open(os.path.join(root, "Info.plist"), "rb") as handle:
    xcframework = plistlib.load(handle)
libraries = xcframework.get("AvailableLibraries", [])
identifiers = sorted(library.get("LibraryIdentifier", "") for library in libraries)
if identifiers != expected_slices:
    problems.append(f"slice 集合为 {identifiers}，期望 {expected_slices}")

for library in libraries:
    identifier = library.get("LibraryIdentifier", "?")
    framework = library.get("LibraryPath", "")
    framework_dir = os.path.join(root, identifier, framework)
    plist_path = framework_plist(framework_dir)
    if plist_path is None:
        problems.append(f"{identifier}: {framework_dir} 里找不到 Info.plist")
        continue
    with open(plist_path, "rb") as handle:
        info = plistlib.load(handle)
    version = info.get("CFBundleShortVersionString")
    if version != expected_version:
        problems.append(f"{identifier}: CFBundleShortVersionString={version}，期望 {expected_version}")
    if identifier.startswith("ios-"):
        privacy = os.path.join(os.path.dirname(plist_path), "PrivacyInfo.xcprivacy")
        if not os.path.isfile(privacy):
            problems.append(f"{identifier}: 缺少 PrivacyInfo.xcprivacy")
        minimum = info.get("MinimumOSVersion")
        if minimum != "17.0":
            problems.append(f"{identifier}: MinimumOSVersion={minimum}，期望 17.0")

seal = os.path.join(root, "_CodeSignature", "CodeResources")
if not os.path.isfile(seal):
    problems.append("缺少 xcframework 级别的 _CodeSignature/CodeResources（在 macOS 上重跑 --update 会重新签名）")

for problem in problems:
    print(f"::error::MSAL {expected_version}: {problem}")
print(f"MSAL {expected_version}: checked {len(identifiers)} slices, {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
PY
}

update_artifact() {
  for tool in curl unzip xcodebuild; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      monica_fail "$tool 是更新 MSAL 产物的必需项（xcodebuild 需要完整 Xcode）。"
    fi
  done

  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/msal-update.XXXXXX")"
  # 用 trap 内联绝对路径：local 变量在函数返回后即失效，set -u 下再引用会报错。
  # shellcheck disable=SC2064
  trap "rm -rf '$work_dir'" EXIT

  monica_info "下载 MSAL $MSAL_VERSION"
  curl --fail --location --silent --show-error --output "$work_dir/MSAL.zip" "$MSAL_URL"

  local actual_sha
  actual_sha="$(sha256_of "$work_dir/MSAL.zip")"
  if [ "$actual_sha" != "$MSAL_SHA256" ]; then
    monica_fail "MSAL.zip sha256 不匹配：实际 ${actual_sha}，脚本 pin 的是 $MSAL_SHA256"
  fi
  monica_info "sha256 校验通过：$actual_sha"

  unzip -q "$work_dir/MSAL.zip" -d "$work_dir/unpacked"
  local source_xcframework="$work_dir/unpacked/MSAL.xcframework"
  [ -d "$source_xcframework" ] || monica_fail "MSAL.zip 里没有 MSAL.xcframework"

  local slice_args=()
  local slice
  for slice in "${MSAL_SLICES[@]}"; do
    [ -d "$source_xcframework/$slice/MSAL.framework" ] \
      || monica_fail "MSAL.zip 缺少 slice：$slice"
    slice_args+=(-framework "$source_xcframework/$slice/MSAL.framework")
  done

  local staged="$work_dir/MSAL.xcframework"
  xcodebuild -create-xcframework "${slice_args[@]}" -output "$staged" >/dev/null

  # 官方 zip 的封印覆盖 5 个 slice 与旧的 Info.plist，sha 校验必然失败；
  # 重新打包后用 ad-hoc 签名封一次，得到的才是与当前 3 slice 布局匹配的有效封印。
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$staged" >/dev/null 2>&1 \
      || monica_fail "ad-hoc 重新签名失败：$staged"
    monica_info "已用 ad-hoc 签名重新封装 xcframework"
  else
    monica_warn "未找到 codesign，跳过重新签名（仅 macOS 提供 codesign）。"
  fi

  mkdir -p "$DEST_DIR"
  rm -rf "$DEST_XCFRAMEWORK"
  mv "$staged" "$DEST_XCFRAMEWORK"
  monica_info "已写入 $DEST_XCFRAMEWORK"
  verify_artifact
}

case "${1:---help}" in
  --print)
    echo "MSAL $MSAL_VERSION"
    echo "  url:    $MSAL_URL"
    echo "  sha256: $MSAL_SHA256"
    echo "  slices: ${MSAL_SLICES[*]}"
    ;;
  --verify)
    verify_artifact
    if command -v codesign >/dev/null 2>&1; then
      codesign --verify --strict "$DEST_XCFRAMEWORK" >/dev/null 2>&1 \
        || monica_warn "codesign --verify 未通过：${DEST_XCFRAMEWORK}"
    fi
    ;;
  --update)
    update_artifact
    ;;
  -h|--help)
    usage
    ;;
  *)
    monica_fail "未知参数：$1（可用：--print、--verify、--update、--help）"
    ;;
esac
