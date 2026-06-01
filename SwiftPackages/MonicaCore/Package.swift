// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MonicaCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MonicaCore", targets: ["MonicaCore"])
    ],
    targets: [
        .target(name: "MonicaCore"),
        .testTarget(name: "MonicaCoreTests", dependencies: ["MonicaCore"])
    ]
)
