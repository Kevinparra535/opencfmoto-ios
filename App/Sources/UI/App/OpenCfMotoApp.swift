// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) OpenCfMotoApp.kt + MainActivity.kt (launch / resume wiring).
//
// The app entry point: one window showing `RootView`, the one `AppModel` from the platform
// composition root injected into the environment, the dark "cockpit" look, scene-phase forwarding
// (Android onResume / onPause) and files / URLs opened with the app (GPX, pairing links, settings
// packs).

import SwiftUI
import OpenCfMotoAppModel

@main
struct OpenCfMotoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Exactly once per process (Android: Application.onCreate + the first MainActivity.onCreate).
        AppPlatform.shared.model.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppPlatform.shared.model)
                .preferredColorScheme(.dark)
                .tint(Theme.brand)
                .onOpenURL { url in
                    let model = AppPlatform.shared.model
                    if let message = model.handleOpenURL(url), !message.isEmpty {
                        model.showBanner(message)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            AppPlatform.shared.model.scenePhaseChanged(AppScenePhase(launchPhase: phase))
        }
    }
}

private extension AppScenePhase {
    /// SwiftUI → model (the model layer has no SwiftUI dependency).
    init(launchPhase phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        case .inactive: self = .inactive
        @unknown default: self = .inactive
        }
    }
}
