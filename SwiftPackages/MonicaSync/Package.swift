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
    dependencies: [
        .package(url: "https://github.com/P-H-C/phc-winner-argon2.git", revision: "f57e61e19229e23c4445b85494dbf7c07de721cb")
    ],
    targets: [
        .target(
            name: "MonicaSync",
            dependencies: [
                .product(name: "argon2", package: "phc-winner-argon2")
            ]
        ),
        .testTarget(name: "MonicaSyncTests", dependencies: ["MonicaSync"])
    ]
)
