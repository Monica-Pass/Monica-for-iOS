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
        .package(url: "https://github.com/P-H-C/phc-winner-argon2.git", revision: "f57e61e19229e23c4445b85494dbf7c07de721cb"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")
    ],
    targets: [
        .target(
            name: "MonicaStorage",
            dependencies: [
                "MonicaMDBX",
                "MonicaStorageTwofish",
                "ZIPFoundation",
                .product(name: "argon2", package: "phc-winner-argon2")
            ]
        ),
        .target(
            name: "MonicaStorageTwofish",
            publicHeadersPath: "include"
        ),
        .testTarget(name: "MonicaStorageTests", dependencies: ["MonicaStorage"])
    ]
)
