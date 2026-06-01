// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MonicaStorage",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "MonicaStorage", targets: ["MonicaStorage"])
    ],
    dependencies: [
        .package(path: "../MonicaMDBX")
    ],
    targets: [
        .target(name: "MonicaStorage", dependencies: ["MonicaMDBX"]),
        .testTarget(name: "MonicaStorageTests", dependencies: ["MonicaStorage"])
    ]
)
