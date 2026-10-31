// SPDX-License-Identifier: AGPL-3.0-or-later
// Temporary entry point so the Xcode project builds in CI before the SwiftUI app lands (wave 2
// replaces this file).

import SwiftUI
import OpenCfMotoCore
import OpenCfMotoApple

@main
struct OpenCfMotoApp: App {
    var body: some Scene {
        WindowGroup {
            Text(verbatim: "OpenCfMoto — \(BikeProfileID.allCases.count) dash profiles")
        }
    }
}
