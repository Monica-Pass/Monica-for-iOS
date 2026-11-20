// swift-tools-version:5.9

import PackageDescription

// MSAL 以 vendored binary target 的形式内置在仓库里（没有 SwiftPM 版本号可 pin）。
// 版本、下载来源与 sha256 统一由 Scripts/update-msal.sh 声明，CI 用它的 --verify
// 校验 Artifacts/MSAL 未与 pin 漂移。平台下限来自 MSAL.framework 的
// MinimumOSVersion / LSMinimumSystemVersion，升级 MSAL 时需同步这里。
let package = Package(
    name: "MSAL",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "MSAL",
            targets: ["MSAL"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "MSAL",
            path: "../../Artifacts/MSAL/MSAL.xcframework"
        )
    ]
)
