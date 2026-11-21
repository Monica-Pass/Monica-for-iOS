// swift-tools-version:5.9

import PackageDescription

// MSAL 以本地 binaryTarget 的形式引用 Artifacts/MSAL（不入库，由
// Scripts/update-msal.sh --update 按 pin 的版本下载并重新打包）。
// 版本、下载来源与 sha256 统一由该脚本声明。平台下限来自 MSAL.framework 的
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
