// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MonicaWidgetShared",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "MonicaWidgetShared", targets: ["MonicaWidgetShared"])
    ],
    targets: [
        .target(name: "MonicaWidgetShared"),
        .testTarget(name: "MonicaWidgetSharedTests", dependencies: ["MonicaWidgetShared"])
    ]
)
