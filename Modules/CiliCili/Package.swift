// swift-tools-version: 6.2
import PackageDescription

// CiliCiliKit — vendored Bilibili client.
//
// Upstream: https://github.com/Rone89/cilicili, pinned revision
// c61b0d33966c5d8e87ea20527b8ba48c702c10c1, GPL-3.0-only.
// See PORTING.md in this directory for the integration boundary and
// the license terms. The module is the full upstream client minus the
// standalone app entry (Sources/App/JKBiliApp.swift), plus the
// Beans/Golia host bridge in Integration/.
//
// Build settings mirror Beans 2.0.3's CiliCiliKit XcodeGen target:
// Swift 5 language mode, MainActor default isolation (SE-0466),
// approachable concurrency (NonisolatedNonsendingByDefault +
// InferIsolatedConformances) and MemberImportVisibility.
// Deployment target iOS 26.1: the module uses unguarded iOS 26 APIs
// (GlassEffectContainer, ToolbarSpacer, .glass button style), so it
// cannot build against a lower target.
let package = Package(
    name: "CiliCili",
    platforms: [.iOS("26.1")],
    products: [
        .library(name: "CiliCiliKit", type: .dynamic, targets: ["CiliCiliKit"]),
    ],
    targets: [
        .target(
            name: "CiliCiliKit",
            path: ".",
            sources: ["Sources", "Integration"],
            exclude: ["Sources/App/JKBiliApp.swift"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "CiliCiliKitTests",
            dependencies: ["CiliCiliKit"],
            path: "Tests"
        ),
    ]
)
