// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-session. Composition root of the iOS app. The UI layer relies on
// exactly these members: `AppPlatform.shared`, `model`, `dashRenderer`, `broadcastExtensionBundleID`,
// `isDemoMode`, `now()`. Implement the private construction; do not rename or remove members.
//
// Builds `AppServices` from the OpenCfMotoApple adapters (one adapter per port, in this folder):
//   keyValueStore = UserDefaultsKeyValueStore.appGroup(), secretStore = KeychainSecretStore(),
//   http = SmartHTTPClient (+ setPreferCellular), network = POSIXNetworkProvider (OpenCfMotoCore; BSD
//   sockets, because the Wi-Fi NWPath of a dash AP without internet stays unsatisfied),
//   discovery = BonjourDashDiscovery(), makeSigner = SecKeyHuidSigner.generate (fallback
//   PureSwiftHuidSigner.generate), wifi = WifiJoiner (+ WiFiInfo; free flavor → hotspotEnabled:false,
//   `#if OCM_NO_HOTSPOT`), location = LocationService, speech = SpeechAnnouncer,
//   handlebar = HandlebarRemote, projection = DashProjectionEngine + DashRenderer(tileCache:) +
//   TileImageCache + ThermalMonitor, mirror = MirrorRelayServer(socketPath: AppGroup.socketPath()),
//   system = UIKit (idle timer, thermal/low power notifications, open settings, haptics,
//   LocalNetworkPermission), files = Application Support/Caches folders, music = MusicAdapter (the
//   system Music app; Apple Music on the dash, app target only).
// Demo mode (launch argument `-demo`, or the simulator when no real services make sense): use
// `AppServices.preview()` plus a demo GPS route player so the dash preview moves.
//
// Demo mode keeps the REAL dash renderer (CoreGraphics + CoreText metrics + map tiles) and the real
// internet client (routing / search / tiles work in the Simulator); only the bike side (Wi-Fi,
// sockets, GPS, speech, handlebar, mirror) is simulated, with a GPS loop replayed at 45 km/h.
//
// Test launch arguments (AppLaunchOptions.swift; the CI simulator job uses them): `-demoSeed` seeds
// demo content (DemoSeed.swift), `-e2eFakeDash` runs the REAL link stack against the Python fake
// dash on 127.0.0.1 (E2EFakeDash.swift), `-uiScreen` / `-uiOrientation` are applied by RootView.

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
    /// Test / demo launch arguments (`-demoSeed`, `-e2eFakeDash`, `-uiScreen`, …).
    let launchOptions: AppLaunchOptions

    /// Monotonic seconds on the model's clock (pass to `RideModel.displayList(now:)` and DashTouch).
    func now() -> TimeInterval { clock.now() }

    private let clock: MonotonicClock
    private let projection: ProjectionAdapter
    private let demoPlayer: DemoRoutePlayer?
    private let e2eHarness: E2EFakeDashHarness?

    private init() {
        let clock = SystemMonotonicClock()
        self.clock = clock
        let bundle = Bundle.main
        broadcastExtensionBundleID = (bundle.bundleIdentifier ?? "com.example.opencfmoto") + ".mirror"
        AppHTTPIdentity.appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppHTTPIdentity.appVersion
        #if DEBUG
        Log.shared.echoToConsole = true
        #endif

        let options = AppLaunchOptions.current
        launchOptions = options
        if !options.logDescription.isEmpty {
            Log.i("APP", "launch arguments: \(options.logDescription)")
        }
        for warning in options.warnings { Log.w("APP", "launch arguments: \(warning)") }
        // Locked iPhone (P0-12): the battery reading for the engine's background lines and `[lock]`.
        BatteryMonitor.shared.start()

        #if targetEnvironment(simulator)
        let demo = !options.e2eFakeDash
        #else
        let demo = options.demo && !options.e2eFakeDash
        #endif
        isDemoMode = demo

        #if OCM_NO_HOTSPOT
        let flavor = BuildFlavor.free
        #else
        let flavor = BuildFlavor.full
        #endif

        let http = SmartHTTPClient(preferCellular: false)
        let projection = ProjectionAdapter(http: http, tileURLTemplate: BikeSettings().tileURLTemplate, clock: clock,
                                           lockedStreamPolicyOverride: options.e2eBackgroundEncoder)
        self.projection = projection
        dashRenderer = projection.renderer

        if options.e2eFakeDash {
            let harness = E2EFakeDashHarness(options: options, flavor: flavor, clock: clock, http: http,
                                             projection: projection)
            let e2eModel = AppModel(services: harness.services)
            harness.attach(to: e2eModel)
            model = e2eModel
            e2eHarness = harness
            demoPlayer = nil
        } else if demo {
            var services = AppServices.preview(flavor: flavor, clock: clock)
            let location = PreviewLocation()
            services.location = location
            services.projection = projection
            services.http = http
            services.setPreferCellular = { [http] on in http.preferCellular = on }
            // The Simulator has no music library: a fake Music app (seeded: three songs with covers).
            services.music = options.demoSeed ? DemoSeed.music(clock: clock, store: services.keyValueStore)
                : DemoSeed.emptyMusic(clock: clock)
            if options.demoSeed { DemoSeed.apply(to: services) }
            model = AppModel(services: services)
            let player = DemoRoutePlayer(location: location, now: services.now)
            player.start()
            demoPlayer = player
            e2eHarness = nil
            Log.i("APP", "demo mode: simulated bike, Wi-Fi and GPS (route loop at 45 km/h)")
        } else {
            model = AppModel(services: Self.realServices(flavor: flavor, clock: clock, http: http, projection: projection))
            demoPlayer = nil
            e2eHarness = nil
        }
        CrashReporter.shared.start(model: model)
    }

    private static func realServices(flavor: BuildFlavor, clock: MonotonicClock, http: SmartHTTPClient,
                                     projection: ProjectionAdapter) -> AppServices {
        let store = UserDefaultsKeyValueStore.appGroup()
        return AppServices(
            keyValueStore: store,
            secretStore: KeychainSecretStore(thisDeviceOnly: true),
            http: http,
            setPreferCellular: { [http] on in http.preferCellular = on },
            network: POSIXNetworkProvider(),
            discovery: BonjourDashDiscovery(),
            makeSigner: {
                do {
                    return try await SecKeyHuidSigner.generate()
                } catch {
                    Log.w("APP", "SecKey RSA unavailable (\(error)) \u{2014} using the pure-Swift signer")
                    return PureSwiftHuidSigner.generate()
                }
            },
            wifi: WifiAdapter(flavor: flavor),
            location: LocationAdapter(clock: clock),
            speech: SpeechAdapter(),
            handlebar: HandlebarAdapter(clock: clock),
            projection: projection,
            mirror: MirrorAdapter(),
            system: IOSSystem(flavor: flavor, store: store),
            files: fileLocations(),
            clock: clock,
            music: MusicAdapter(clock: clock))
    }

    /// Trips and bike photos in Application Support (backed up), share-sheet exports in Caches.
    private static func fileLocations() -> AppFileLocations {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let files = AppFileLocations(tripsDirectory: support.appendingPathComponent("trips", isDirectory: true),
                                     photosDirectory: support.appendingPathComponent("photos", isDirectory: true),
                                     exportsDirectory: caches.appendingPathComponent("exports", isDirectory: true))
        for dir in [files.tripsDirectory, files.photosDirectory, files.exportsDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return files
    }
}
