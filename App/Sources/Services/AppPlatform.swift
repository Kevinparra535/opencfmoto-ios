// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-session. Composition root of the iOS app. The UI layer relies on
// exactly these members: `AppPlatform.shared`, `model`, `dashRenderer`, `broadcastExtensionBundleID`,
// `isDemoMode`, `now()`. Implement the private construction; do not rename or remove members.
//
// Builds `AppServices` from the OpenCfMotoApple adapters (one adapter per port, in this folder):
//   keyValueStore = UserDefaultsKeyValueStore.appGroup(), secretStore = KeychainSecretStore(),
//   http = SmartHTTPClient (+ setPreferCellular), network = NWNetworkProvider(.bikeWiFi),
//   discovery = BonjourDashDiscovery(), makeSigner = SecKeyHuidSigner.generate (fallback
//   PureSwiftHuidSigner.generate), wifi = WifiJoiner (+ WiFiInfo; free flavor → hotspotEnabled:false,
//   `#if OCM_NO_HOTSPOT`), location = LocationService, speech = SpeechAnnouncer,
//   handlebar = HandlebarRemote, projection = DashProjectionEngine + DashRenderer(tileCache:) +
//   TileImageCache + ThermalMonitor, mirror = MirrorRelayServer(socketPath: AppGroup.socketPath()),
//   system = UIKit (idle timer, thermal/low power notifications, open settings, haptics,
//   LocalNetworkPermission), files = Application Support/Caches folders.
// Demo mode (launch argument `-demo`, or the simulator when no real services make sense): use
// `AppServices.preview()` plus a demo GPS route player so the dash preview moves.

import Foundation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

@MainActor
final class AppPlatform {
    static let shared = AppPlatform()

    /// The one app model (inject with `.environment(AppPlatform.shared.model)`).
    let model: AppModel
    /// Renderer shared with the projection engine (same tile cache) — draws the phone preview of
    /// the dash (`makeImage(_:scale:)` / `draw(_:in:pixelWidth:pixelHeight:)`).
    let dashRenderer: DashRenderer
    /// Bundle identifier of the ReplayKit broadcast upload extension
    /// (`RPSystemBroadcastPickerView.preferredExtension`).
    let broadcastExtensionBundleID: String
    /// Running on fake services (no Wi-Fi / dash / real GPS).
    let isDemoMode: Bool

    /// Monotonic seconds on the model's clock (pass to `RideModel.displayList(now:)` and DashTouch).
    func now() -> TimeInterval { clock.now() }

    private let clock: MonotonicClock

    private init() {
        // TODO(logic-session): real services + demo mode; keep these members.
        clock = SystemMonotonicClock()
        isDemoMode = ProcessInfo.processInfo.arguments.contains("-demo")
        dashRenderer = DashRenderer()
        broadcastExtensionBundleID = (Bundle.main.bundleIdentifier ?? "com.example.opencfmoto") + ".mirror"
        model = AppModel(services: .preview(clock: clock))
    }
}
