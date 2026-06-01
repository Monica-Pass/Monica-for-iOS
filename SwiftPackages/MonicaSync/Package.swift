// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MonicaSync",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "MonicaSync", targets: ["MonicaSync"])
    ],
    targets: [
        .target(name: "MonicaSync"),
        .testTarget(name: "MonicaSyncTests", dependencies: ["MonicaSync"])
    ]
)
