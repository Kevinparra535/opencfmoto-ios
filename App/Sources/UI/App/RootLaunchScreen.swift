// SPDX-License-Identifier: AGPL-3.0-or-later
// `-uiScreen <name>` (see App/Sources/Services/AppLaunchOptions.swift): the screen RootView opens
// right after launch, so the CI simulator job can screenshot every screen without UI automation
// (tools/ci/e2e/screenshots.sh). Harmless in normal use: iOS never passes the argument.

import SwiftUI
import UIKit
import OpenCfMotoAppModel
import OpenCfMotoCore

enum RootLaunchScreen: Equatable {
    /// Home (nothing to open).
    case home
    /// A pushed root destination.
    case route(MainRoute)
    /// Settings ▸ "Show onboarding again".
    case onboarding
    /// The root QR scanner sheet.
    case scan
    /// The pocket-mode («Modo bolsillo») cover.
    case ride
    /// The Map hub with a demo GPX track opened as a preview over a route to Home (UI/UX P0, UX-17).
    case gpxPreview
    /// Home with the «Modo bolsillo» countdown card, held at its full count (UX-01; review PH-5).
    case pocketOffer

    /// The names accepted by `-uiScreen` (lower-case).
    static let names = ["home", "dash", "navigate", "trips", "settings", "controls", "logs", "garage", "about",
                        "mirror", "onboarding", "scan", "ride", "gpx", "pocketoffer"]

    init?(name: String?) {
        guard let name else { return nil }
        switch name.lowercased() {
        case "home": self = .home
        case "dash", "dashpreview": self = .route(.dashPreview)
        case "navigate", "map": self = .route(.navigate)
        case "trips": self = .route(.trips)
        case "settings": self = .route(.settings)
        case "controls": self = .route(.controls)
        case "logs": self = .route(.logs)
        case "garage": self = .route(.garage)
        case "about": self = .route(.about)
        case "mirror": self = .route(.mirror)
        case "onboarding": self = .onboarding
        case "scan": self = .scan
        case "ride": self = .ride
        case "gpx": self = .gpxPreview
        case "pocketoffer", "pocket_offer": self = .pocketOffer
        default: return nil
        }
    }
}

enum RootLaunchOrientation {
    /// Rotates the interface to landscape (the Simulator keeps its portrait framebuffer, so a
    /// screenshot shows the landscape UI sideways; the CI job rotates the PNG back).
    @MainActor
    static func applyLandscape() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            Log.w("UI", "-uiOrientation landscape: no window scene")
            return
        }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { @Sendable error in
            Log.w("UI", "-uiOrientation landscape refused: \(error.localizedDescription)")
        }
        Log.i("UI", "-uiOrientation landscape requested")
    }
}
