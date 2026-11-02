// swift-tools-version:5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
import PackageDescription

// linkrunner: runs the real OpenCfMotoCore `EasyConnLink` over `POSIXNetworkProvider` (the app's own
// BSD-sockets transport) against a PXC dash (the fake dash in tools/fakedash, or a real bike from a
// Mac) with a synthetic H.264 frame source. Verification tool only; nothing in the app depends on it.
let package = Package(
    name: "linkrunner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/OpenCfMotoKit"),
    ],
    targets: [
        .executableTarget(
            name: "linkrunner",
            dependencies: [.product(name: "OpenCfMotoCore", package: "OpenCfMotoKit")],
            path: "Sources/linkrunner"
        ),
    ]
)
