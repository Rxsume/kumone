// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KumoneIOSFeature",
    defaultLocalization: "zh-Hans",
    // iOS 26.1 floor (was 16.0): kept — later code uses unguarded
    // iOS 26 APIs.
    platforms: [.iOS("26.1")],
    products: [
        .library(
            name: "KumoneIOSFeature",
            targets: ["KumoneIOSFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "KumoneIOSFeature",
            dependencies: [
                .product(name: "KumoneCore", package: "kumone"),
            ],
            path: "Sources/KumoneIOSFeature"
        ),
        .testTarget(
            name: "KumoneIOSFeatureTests",
            dependencies: [
                "KumoneIOSFeature"
            ]
        ),
    ]
)
