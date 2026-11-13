// swift-tools-version:5.10
// Auto Applicator: a native macOS app (Apple silicon) that finds jobs on LinkedIn and fills in applications with an
// on-device AI. `Engine` is everything that isn't UI (browser automation, answers, email codes, AI); the app target is
// the SwiftUI interface. Build the .app with scripts/build_app.sh.
import PackageDescription

let package = Package(
    name: "AutoApplicator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AutoApplicator", targets: ["AutoApplicator"]),
    ],
    targets: [
        .target(
            name: "Engine",
            path: "Sources/Engine",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // Apple's on-device model exists on macOS 26+; older systems run without it.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        .executableTarget(
            name: "AutoApplicator",
            dependencies: ["Engine"],
            path: "Sources/AutoApplicator"
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine"],
            path: "tests/EngineTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
