// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE (wave 2). Do not edit; report a contract change request instead.
//
// Ports: the platform services the app model needs, described WITHOUT Apple frameworks so the
// whole model layer (OpenCfMotoAppModel) compiles and is unit-tested on Linux.
//
// - The iOS app implements every port in App/Sources/Services/ on top of OpenCfMotoApple
//   (NWNetworkProvider, WifiJoiner, LocationService, SpeechAnnouncer, HandlebarRemote,
//   DashProjectionEngine + DashRenderer + TileImageCache + ThermalMonitor, MirrorRelayServer, …).
// - `PreviewServices` (Testing/PreviewServices.swift) provides in-memory fakes for unit tests,
//   SwiftUI previews and the simulator demo mode.

import Foundation
import OpenCfMotoCore

// MARK: - Build / device

/// `full` has the Hotspot Configuration + Wi-Fi Information entitlements (paid team); `free`
/// (Personal Team) joins the bike Wi-Fi manually through Settings.
public enum BuildFlavor: String, Sendable, Equatable, CaseIterable {
    case full
    case free
}

/// Local Network privacy state (iOS 14+ prompt).
public enum LocalNetworkAccessState: String, Sendable, Equatable {
    case granted
    case denied
    case undetermined
    case unavailable
}

/// Process / device facilities. Main-actor bound (UIKit underneath).
@MainActor
public protocol SystemControlling: AnyObject {
    var flavor: BuildFlavor { get }
    /// CFBundleShortVersionString, e.g. "0.1.0".
    var appVersion: String { get }
    /// CFBundleVersion, e.g. "1".
    var buildNumber: String { get }
    /// e.g. "iPhone15,2" (for problem reports).
    var deviceModel: String { get }
    /// e.g. "iOS 18.1".
    var systemVersion: String { get }
    /// First preferred language code, lower-cased ("es", "en", …).
    var preferredLanguageCode: String { get }
    /// UIApplication.isIdleTimerDisabled.
    var isIdleTimerDisabled: Bool { get set }
    var isLowPowerModeEnabled: Bool { get }
    var thermalLevel: ThermalLevel { get }
    /// Called (on the main actor) when the thermal level or Low Power Mode changes.
    var onPowerStateChange: (() -> Void)? { get set }
    /// Opens this app's page in the Settings app.
    func openAppSettings()
    /// Light haptic (Android's 40 ms vibration).
    func hapticTap()
    /// Best-effort probe of the Local Network permission (never shows the prompt by itself).
    func checkLocalNetworkAccess() async -> LocalNetworkAccessState
    /// Triggers the Local Network prompt if needed and waits for the answer (bounded).
    func requestLocalNetworkAccess() async -> LocalNetworkAccessState
}

/// Where the app keeps its files.
public struct AppFileLocations: Sendable, Equatable {
    /// Saved trips (TripStore directory).
    public var tripsDirectory: URL
    /// Garage photos (file names only are persisted).
    public var photosDirectory: URL
    /// Scratch space for share-sheet exports (GPX, settings JSON, logs).
    public var exportsDirectory: URL

    public init(tripsDirectory: URL, photosDirectory: URL, exportsDirectory: URL) {
        self.tripsDirectory = tripsDirectory
        self.photosDirectory = photosDirectory
        self.exportsDirectory = exportsDirectory
    }
}

// MARK: - Wi-Fi

/// Snapshot of the phone's Wi-Fi path (NWPath + getifaddrs + NEHotspotNetwork on iOS).
public struct WifiNetworkInfo: Sendable, Equatable {
    /// A Wi-Fi path is satisfied.
    public var isWifiAvailable: Bool
    /// Current SSID; nil when unknown (free flavor / no entitlement / no Wi-Fi).
    public var ssid: String?
    /// The Wi-Fi interface name from NWPath (never assume "en0").
    public var interfaceName: String?
    public var phoneIPv4: String?
    /// First IPv4 gateway of the Wi-Fi path.
    public var gateway: String?
    /// Ordered dash host guesses: gateways → subnet .1 → 192.168.0.1 → 192.168.49.1.
    public var dashHostCandidates: [String]
    /// NWPath reported `.localNetworkDenied`.
    public var isLocalNetworkDenied: Bool

    public init(isWifiAvailable: Bool = false, ssid: String? = nil, interfaceName: String? = nil,
                phoneIPv4: String? = nil, gateway: String? = nil, dashHostCandidates: [String] = [],
                isLocalNetworkDenied: Bool = false) {
        self.isWifiAvailable = isWifiAvailable
        self.ssid = ssid
        self.interfaceName = interfaceName
        self.phoneIPv4 = phoneIPv4
        self.gateway = gateway
        self.dashHostCandidates = dashHostCandidates
        self.isLocalNetworkDenied = isLocalNetworkDenied
    }

    public static let unavailable = WifiNetworkInfo()
}

public enum WifiJoinResult: Sendable, Equatable {
    /// iOS joined the network (association confirmed).
    case joined
    /// Already on that network.
    case alreadyJoined
    /// The rider must join in Settings ▸ Wi-Fi (free flavor, or iOS refused in a way that a manual
    /// join can fix). The UI shows the SSID + password and waits for `networkUpdates()`.
    case manualJoinRequired
}

/// A failed join, already localized for the UI.
public struct WifiJoinFailure: Error, Sendable, Equatable {
    public var message: String
    public var suggestsManualJoin: Bool
    /// The rider tapped "Cancel" on the system join alert.
    public var userCancelled: Bool

    public init(message: String, suggestsManualJoin: Bool = false, userCancelled: Bool = false) {
        self.message = message
        self.suggestsManualJoin = suggestsManualJoin
        self.userCancelled = userCancelled
    }
}

public protocol WifiJoining: AnyObject, Sendable {
    /// false in the free flavor: `join` returns `.manualJoinRequired` without calling iOS.
    var supportsAutomaticJoin: Bool { get }
    /// Joins the bike Wi-Fi (NEHotspotConfiguration, joinOnce = false). Throws `WifiJoinFailure`.
    func join(ssid: String, passphrase: String?) async throws -> WifiJoinResult
    /// Removes the configuration so iOS stops auto-joining (Stop without "keep Wi-Fi").
    func forget(ssid: String)
    func currentNetwork() async -> WifiNetworkInfo
    /// Network changes (first value = current state). Cancel the consuming task to stop.
    func networkUpdates() -> AsyncStream<WifiNetworkInfo>
}

// MARK: - Location / heading

public enum LocationPermission: String, Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case whenInUse
    case always

    public var isAuthorized: Bool { self == .whenInUse || self == .always }
}

/// CoreLocation (When-In-Use only; background updates only while a ride is active).
@MainActor
public protocol LocationProviding: AnyObject {
    var permission: LocationPermission { get }
    var isPrecise: Bool { get }
    var isUpdating: Bool { get }
    var lastFix: LocationFix? { get }
    var onFix: ((LocationFix) -> Void)? { get set }
    /// Every RAW compass sample (degrees). `NavigationSession.updateHeading` filters it itself.
    var onRawHeading: ((Double) -> Void)? { get set }
    var onPermissionChange: ((LocationPermission) -> Void)? { get set }
    func requestPermission()
    /// Starts fixes + heading. `rideActive` enables background location (needs the UIBackgroundModes entry).
    func start(rideActive: Bool)
    func setRideActive(_ active: Bool)
    func stop()
}

// MARK: - Speech

/// AVSpeechSynthesizer: stop-then-speak (Android QUEUE_FLUSH), voice from the app language.
@MainActor
public protocol SpeechProviding: AnyObject {
    var isMuted: Bool { get set }
    var isSpeaking: Bool { get }
    func speak(_ text: String)
    func stop()
}

// MARK: - Handlebar (AVRCP via MPRemoteCommandCenter) — opt-in experiment

public struct HandlebarSignal: Sendable, Equatable {
    public var event: HandlebarRawEvent
    /// Monotonic seconds (same clock as `AppServices.clock`).
    public var time: TimeInterval
    /// Volume jump size (≥ 3 = a forced double); 1 for every other event.
    public var steps: Int

    public init(event: HandlebarRawEvent, time: TimeInterval, steps: Int = 1) {
        self.event = event
        self.time = time
        self.steps = steps
    }
}

@MainActor
public protocol HandlebarRemoteProviding: AnyObject {
    /// false where the platform cannot claim the remote commands.
    var isAvailable: Bool { get }
    var isEnabled: Bool { get }
    /// Also observe volume up/down as buttons (off by default).
    var volumeButtonsEnabled: Bool { get set }
    var onSignal: ((HandlebarSignal) -> Void)? { get set }
    /// Claims Now Playing + remote commands (silent audio loop). Only after an explicit opt-in.
    func enable()
    func disable()
}

// MARK: - Own dash UI projection (render → encode)

public struct ProjectionStatsSummary: Sendable, Equatable {
    /// "idle", "foreground", "background-software", "hold", "stopped".
    public var mode: String
    public var renderedFrames: Int
    public var encodedFrames: Int
    public var framesPerSecond: Double
    public var bitrate: Int
    public var lastError: String?

    public init(mode: String = "idle", renderedFrames: Int = 0, encodedFrames: Int = 0,
                framesPerSecond: Double = 0, bitrate: Int = 0, lastError: String? = nil) {
        self.mode = mode
        self.renderedFrames = renderedFrames
        self.encodedFrames = encodedFrames
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.lastError = lastError
    }
}

/// The own-UI video pipeline: DashDisplayList → CoreGraphics → VideoToolbox → `frameSource`.
/// Thread-safe; providers are called on the render queue.
public protocol DashProjecting: AnyObject, Sendable {
    /// Give this to `EasyConnLink` as its frame source.
    var frameSource: VideoFrameSource { get }
    /// The measurer the renderer draws with (CoreText); give it to `DashUIController`.
    var textMeasurer: DashTextMeasurer { get }
    var stats: ProjectionStatsSummary { get }
    /// Called (any thread) when a map tile finished loading — re-render.
    var onTileLoaded: (@Sendable () -> Void)? { get set }
    func setDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?)
    /// Picture served while the app cannot render (locked / background).
    func setHoldDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?)
    /// Live encoder parameters (EncoderPlanner output; AdaptivePolicy adjustments).
    func setEncoderParameters(_ parameters: EncoderParameters)
    /// Engine-side thermal caps (turn off when AUTO power mode's AdaptivePolicy handles heat).
    func setThermalCapsEnabled(_ enabled: Bool)
    /// The scene changed: render on the next pull.
    func invalidate()
    /// App will resign active: pre-encode the hold picture.
    func prepareHoldPicture()
    func enterBackground()
    func enterForeground()
    /// Ride/link ended: release the encoder.
    func stop()
    /// Ask the tile cache for these tiles (no-op when cached).
    func requestTiles(_ tiles: [DashMapTile])
    /// Capped corridor prefetch along the route (OSM tile policy).
    func prefetchCorridor(_ points: [GeoPoint])
    func setTileURLTemplate(_ template: String)
    func clearTileCache()
}

// MARK: - Mirror (ReplayKit broadcast extension → App Group socket → host)

public protocol MirrorHosting: AnyObject, Sendable {
    /// Give this to `EasyConnLink` while mirroring.
    var frameSource: VideoFrameSource { get }
    var isRunning: Bool { get }
    var isExtensionConnected: Bool { get }
    var onExtensionConnectionChange: (@Sendable (Bool) -> Void)? { get set }
    /// Opens the App Group Unix socket server.
    func start() throws
    func stop()
    func setFit(_ fit: ScreenFit, margins: ScreenMargins)
}

// MARK: - The bundle

/// Everything the model layer needs from the platform. Build once at launch.
public struct AppServices: @unchecked Sendable {
    public var keyValueStore: KeyValueStore
    public var secretStore: SecretStore
    /// Internet for routing / search / tiles / Overpass (cellular-pinned while on the bike Wi-Fi).
    public var http: HTTPClient
    /// Flip the HTTP client's cellular preference (true while joined to the bike Wi-Fi or linked).
    public var setPreferCellular: @Sendable (Bool) -> Void
    /// Sockets for the PXC link (Wi-Fi pinned).
    public var network: NetworkProvider
    /// Bonjour `_EasyConn._tcp` (nil = gateway probe only).
    public var discovery: DashDiscovery?
    /// RSA identity for CLIENT_INFO; called once per process (expensive: run off the main actor).
    public var makeSigner: @Sendable () async throws -> HuidSigner
    public var wifi: WifiJoining
    public var location: LocationProviding
    public var speech: SpeechProviding
    public var handlebar: HandlebarRemoteProviding
    public var projection: DashProjecting
    public var mirror: MirrorHosting
    public var system: SystemControlling
    public var files: AppFileLocations
    public var clock: MonotonicClock
    public var now: @Sendable () -> Date

    public init(keyValueStore: KeyValueStore, secretStore: SecretStore, http: HTTPClient,
                setPreferCellular: @escaping @Sendable (Bool) -> Void, network: NetworkProvider,
                discovery: DashDiscovery?, makeSigner: @escaping @Sendable () async throws -> HuidSigner,
                wifi: WifiJoining, location: LocationProviding, speech: SpeechProviding,
                handlebar: HandlebarRemoteProviding, projection: DashProjecting, mirror: MirrorHosting,
                system: SystemControlling, files: AppFileLocations,
                clock: MonotonicClock = SystemMonotonicClock(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.keyValueStore = keyValueStore
        self.secretStore = secretStore
        self.http = http
        self.setPreferCellular = setPreferCellular
        self.network = network
        self.discovery = discovery
        self.makeSigner = makeSigner
        self.wifi = wifi
        self.location = location
        self.speech = speech
        self.handlebar = handlebar
        self.projection = projection
        self.mirror = mirror
        self.system = system
        self.files = files
        self.clock = clock
        self.now = now
    }
}
