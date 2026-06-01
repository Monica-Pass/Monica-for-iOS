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
        .package(path: "../MonicaMDBX"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")
    ],
    targets: [
        .target(name: "MonicaStorage", dependencies: ["MonicaMDBX", "ZIPFoundation"]),
        .testTarget(name: "MonicaStorageTests", dependencies: ["MonicaStorage"])
    ]
)
