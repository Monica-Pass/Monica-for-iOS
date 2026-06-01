// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MonicaUI",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MonicaUI", targets: ["MonicaUI"])
    ],
    targets: [
        .target(name: "MonicaUI"),
        .testTarget(name: "MonicaUITests", dependencies: ["MonicaUI"])
    ]
)
