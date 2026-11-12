// swift-tools-version: 6.0

import Foundation
import PackageDescription

// MDBX 原生绑定以预编译 xcframework 形式交付，产物不入库（体积约 70MB）。
// 生成方式见 Scripts/bootstrap.sh 或 README 的「MDBX UniFFI」一节。
//
// 关键点：SwiftPM 在 .binaryTarget(path:) 指向的路径不存在时会直接 fatalError，
// 连带 xcodebuild -list、IDE 打开工程、以及所有包测试全部失败。这里改为
// 「产物存在才声明 binaryTarget」，让缺产物时工程仍可解析与编译——
// MonicaMDBX 源码用 `#if canImport(mdbx_ffiFFI)` 守卫，缺失时回落到
// 抛 unavailableOnCurrentPlatform 的 stub 实现。
let mdbxArtifactRelativePath = "../../Artifacts/MDBX/MonicaMDBXGenerated.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let mdbxArtifactURL = packageDirectory
    .appendingPathComponent(mdbxArtifactRelativePath)
    .standardizedFileURL
let hasMDBXArtifact = FileManager.default.fileExists(atPath: mdbxArtifactURL.path)

var targets: [Target] = [
    .target(
        name: "MonicaMDBX",
        dependencies: hasMDBXArtifact ? ["mdbx_ffiFFI"] : []
    ),
    .testTarget(name: "MonicaMDBXTests", dependencies: ["MonicaMDBX"])
]

if hasMDBXArtifact {
    targets.append(
        .binaryTarget(
            name: "mdbx_ffiFFI",
            path: mdbxArtifactRelativePath
        )
    )
}

let package = Package(
    name: "MonicaMDBX",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MonicaMDBX", targets: ["MonicaMDBX"])
    ],
    targets: targets
)
