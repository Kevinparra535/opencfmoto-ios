// swift-tools-version:5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
import PackageDescription

// OpenCfMotoKit
// - OpenCfMotoCore: pure Swift + Foundation (no Apple-only frameworks). Builds and tests on Linux,
//   macOS and iOS. Protocol, link orchestration, bike/QR/profiles, navigation, trips, dash layout.
// - OpenCfMotoApple: Apple-framework adapters (Network.framework, VideoToolbox, CoreGraphics,
//   Security, CoreLocation...). Every file is wrapped in `#if canImport(...)` so the target
//   compiles (empty) on Linux.
let package = Package(
    name: "OpenCfMotoKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OpenCfMotoCore", targets: ["OpenCfMotoCore"]),
        .library(name: "OpenCfMotoApple", targets: ["OpenCfMotoApple"]),
    ],
    targets: [
        .target(
            name: "OpenCfMotoCore",
            path: "Sources/OpenCfMotoCore"
        ),
        .target(
            name: "OpenCfMotoApple",
            dependencies: ["OpenCfMotoCore"],
            path: "Sources/OpenCfMotoApple"
        ),
        .testTarget(
            name: "OpenCfMotoCoreTests",
            dependencies: ["OpenCfMotoCore"],
            path: "Tests/OpenCfMotoCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OpenCfMotoAppleTests",
            dependencies: ["OpenCfMotoApple", "OpenCfMotoCore"],
            path: "Tests/OpenCfMotoAppleTests"
        ),
    ]
)
