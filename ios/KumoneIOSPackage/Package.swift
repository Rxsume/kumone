// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KumoneIOSFeature",
    defaultLocalization: "zh-Hans",
    // iOS 26.1: the vendored CiliCiliKit module (Bilibili video client)
    // uses unguarded iOS 26 APIs, so the whole iOS app targets 26.1.
    platforms: [.iOS("26.1")],
    products: [
        .library(
            name: "KumoneIOSFeature",
            targets: ["KumoneIOSFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
        // Vendored Bilibili client (GPL-3.0-only); see Modules/CiliCili/PORTING.md.
        .package(path: "../../Modules/CiliCili"),
    ],
    targets: [
        .target(
            name: "KumoneIOSFeature",
            dependencies: [
                .product(name: "KumoneCore", package: "kumone"),
                .product(name: "CiliCiliKit", package: "CiliCiliKit"),
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
