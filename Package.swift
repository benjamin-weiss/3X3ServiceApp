// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ThreeByThreeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ThreeByThreeKit", targets: ["ThreeByThreeKit"]),
    ],
    targets: [
        .target(name: "ThreeByThreeKit"),
        .testTarget(
            name: "ThreeByThreeKitTests",
            dependencies: ["ThreeByThreeKit"]
        ),
    ]
)