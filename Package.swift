// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Xue",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "Xue", targets: ["Xue"]),
    ],
    dependencies: [
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
    ],
    targets: [
        .target(
            name: "Xue",
            dependencies: [.product(name: "libzstd", package: "zstd")]
        ),
        .testTarget(
            name: "XueTests",
            dependencies: ["Xue"],
            resources: [.copy("tmp2m.xue"), .copy("expected.tmp2m.f000.bin")]
        ),
    ]
)
