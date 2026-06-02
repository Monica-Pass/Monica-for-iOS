// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MonicaMDBX",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MonicaMDBX", targets: ["MonicaMDBX"])
    ],
    targets: [
        .target(
            name: "MonicaMDBX",
            dependencies: ["mdbx_ffiFFI"]
        ),
        .binaryTarget(
            name: "mdbx_ffiFFI",
            path: "../../Artifacts/MDBX/MonicaMDBXGenerated.xcframework"
        ),
        .testTarget(name: "MonicaMDBXTests", dependencies: ["MonicaMDBX"])
    ]
)
