// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MonicaSecurity",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MonicaSecurity", targets: ["MonicaSecurity"])
    ],
    targets: [
        .target(name: "MonicaSecurity"),
        .testTarget(name: "MonicaSecurityTests", dependencies: ["MonicaSecurity"])
    ]
)
