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
    /// ADDITION (fix-media, SPEC:CL-10): the phone's SYSTEM appearance is dark (Settings ▸
    /// Display & Brightness, including "Automatic" after sunset) — read from the screen traits,
    /// unaffected by the app's own forced dark scheme. Map theme AUTO = this OR 19:00–06:59
    /// (navigation-dash §10.3). Implementations should call `onPowerStateChange` when it changes
    /// (the ride re-evaluates night mode then; it also re-reads it at least once a minute).
    /// Default (protocol extension): false.
    var isSystemDarkMode: Bool { get }
    /// ADDITION (field follow-up, review POSIX-2): the Local Network check after the bike link's
    /// connect() was dropped by the system (EHOSTUNREACH: Local Network privacy, or a VPN / Wi-Fi data
    /// restriction / filter, which look the same to a BSD socket). That connect already brought up the
    /// system alert if it was due, so unlike `checkLocalNetworkAccess` this may probe without an earlier
    /// explicit request. Default (protocol extension): `checkLocalNetworkAccess()`.
    func checkLocalNetworkAccessAfterBlockedConnect() async -> LocalNetworkAccessState
    /// ADDITION (locked iPhone, Phase 0, P0-12): the battery level and state (UIDevice battery
    /// monitoring, cached by the app's BatteryMonitor), for the `[lock]` status line. nil = unknown.
    /// Default (protocol extension): nil.
    var batteryStatus: BatteryStatus? { get }
}

public extension SystemControlling {
    /// Conformers that cannot tell report a light system appearance (AUTO = clock only).
    var isSystemDarkMode: Bool { false }

    /// Conformers without a separate post-block check answer with the quiet one.
    func checkLocalNetworkAccessAfterBlockedConnect() async -> LocalNetworkAccessState {
        await checkLocalNetworkAccess()
    }

    /// Conformers without battery monitoring report nothing.
    var batteryStatus: BatteryStatus? { nil }
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
    /// Wi-Fi is up: the Wi-Fi path is satisfied, or the Wi-Fi interface holds a usable IPv4 (a
    /// network without internet, like the dash's, that iOS reports unsatisfied: `isLocalOnly`).
    public var isWifiAvailable: Bool
    /// Current SSID; nil when unknown (free flavor / no entitlement / no Wi-Fi).
    public var ssid: String?
    /// The Wi-Fi interface name from NWPath (never assume "en0").
    public var interfaceName: String?
    public var phoneIPv4: String?
    /// First IPv4 gateway of the Wi-Fi path; the subnet .1 when the path lists none (local-only).
    public var gateway: String?
    /// Ordered dash host guesses: gateways → subnet .1 → 192.168.0.1 → 192.168.49.1.
    public var dashHostCandidates: [String]
    /// NWPath reported `.localNetworkDenied`.
    public var isLocalNetworkDenied: Bool
    /// Up through the interface address only: iOS reports the Wi-Fi path unsatisfied (no internet).
    /// The bike link then uses the interface directly.
    public var isLocalOnly: Bool
    /// `NWPath.unsatisfiedReason` of the Wi-Fi path when it is not satisfied, e.g. "notAvailable".
    public var pathUnsatisfiedReason: String?

    public init(isWifiAvailable: Bool = false, ssid: String? = nil, interfaceName: String? = nil,
                phoneIPv4: String? = nil, gateway: String? = nil, dashHostCandidates: [String] = [],
                isLocalNetworkDenied: Bool = false, isLocalOnly: Bool = false, pathUnsatisfiedReason: String? = nil) {
        self.isWifiAvailable = isWifiAvailable
        self.ssid = ssid
        self.interfaceName = interfaceName
        self.phoneIPv4 = phoneIPv4
        self.gateway = gateway
        self.dashHostCandidates = dashHostCandidates
        self.isLocalNetworkDenied = isLocalNetworkDenied
        self.isLocalOnly = isLocalOnly
        self.pathUnsatisfiedReason = pathUnsatisfiedReason
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
    /// ADDITION (music): capture is enabled but another app took Now Playing (the rider started Apple
    /// Music, then paused it with ★): claim it back NOW. Only in the foreground, never while other
    /// audio plays (that would pause the rider's music again). Default: `.refused`.
    func reclaimIfPossible() -> HandlebarReclaimResult
}

/// ADDITION (music): what `HandlebarRemoteProviding.reclaimIfPossible()` did.
public enum HandlebarReclaimResult: String, Sendable, Equatable {
    /// Capture was enabled but not holding Now Playing; the handlebar buttons are ours again now.
    case reclaimed
    /// Nothing to do: capture already holds Now Playing.
    case alreadyClaimed
    /// Not now: capture is off, the app is not in the foreground, or another app's audio plays.
    case refused
}

public extension HandlebarRemoteProviding {
    func reclaimIfPossible() -> HandlebarReclaimResult { .refused }
}

// MARK: - Apple Music (the system Music app) — ADDITION (music)
//
// iOS gives third-party apps the now-playing data and the transport controls of the system Music
// app only (MediaPlayer `MPMusicPlayerController.systemMusicPlayer`, MusicKit `SystemMusicPlayer`);
// nothing of Spotify, YouTube Music… The iOS adapter lives in the APP TARGET
// (App/Sources/Services/MusicAdapter.swift), never in OpenCfMotoApple: the ReplayKit extension links
// OpenCfMotoApple, and App Store Connect checks NSAppleMusicUsageDescription bundle by bundle
// (ITMS-90683, tools/testflight/lint_bundle.py).
// Privacy: song titles, artists, albums, track / store / image ids and artwork URLs never go to logs,
// problem reports or any server of ours; log states, artwork sources and the keyed per-run token of
// a track id only (`MusicTrackID.logToken`, review fix F4: a catalog id names the song).

/// The media-library permission (Settings ▸ "Media & Apple Music"; MPMediaLibrary and MusicKit share
/// it and the NSAppleMusicUsageDescription purpose string).
public enum MusicAuthorizationState: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
    /// No system music player here (Linux / macOS, the null port, the Simulator without a fake).
    case unavailable
}

/// `MPMusicPlaybackState` without MediaPlayer.
public enum MusicPlaybackState: String, Sendable, Equatable {
    case stopped
    case playing
    case paused
    case interrupted
    case seekingForward
    case seekingBackward
}

/// The song the Music app has loaded.
public struct MusicTrack: Sendable, Equatable {
    /// Stable per song; only letters, digits, "-" and "_" (it becomes part of the dash image id
    /// "music.art.<id>"). The adapter uses "p" + MPMediaItem.persistentID in lower-case hex, else
    /// "s" + playbackStoreID, else "h" + a hash of title / artist / album / duration.
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; ≤ 0 or non-finite = unknown (radio, live streams).
    public var duration: TimeInterval
    /// Apple Music catalog id (`playbackStoreID`, digits only); nil for library-only items ("0" / "").
    public var storeID: String?

    public init(id: String, title: String, artist: String = "", album: String = "", duration: TimeInterval = 0,
                storeID: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.storeID = storeID
    }
}

/// One reading of the Music app.
public struct MusicSnapshot: Sendable, Equatable {
    /// nil = nothing loaded, a Home Sharing item (iOS hides it) or not observing.
    public var track: MusicTrack?
    public var state: MusicPlaybackState
    /// Seconds into the song when sampled (finite, ≥ 0; the player's NaN reads as 0).
    public var position: TimeInterval
    /// Monotonic time of the sample, on `AppServices.clock` (the dash UI's `now`).
    public var sampledAt: TimeInterval
    /// Playback rate when sampled (1 while playing, 0 otherwise).
    public var rate: Double
    /// Another app's audio is playing (`AVAudioSession.isOtherAudioPlaying`; the Music app itself counts
    /// as "other" for us, also for a moment after it paused). Only meaningful while the Music app makes
    /// no sound: a paused Music song is stale while Spotify plays, so the dash hides it — once that
    /// lasted MusicModel's 3 s grace (F1).
    public var otherAudioPlaying: Bool

    public init(track: MusicTrack?, state: MusicPlaybackState, position: TimeInterval, sampledAt: TimeInterval,
                rate: Double, otherAudioPlaying: Bool = false) {
        self.track = track
        self.state = state
        self.position = position
        self.sampledAt = sampledAt
        self.rate = rate
        self.otherAudioPlaying = otherAudioPlaying
    }

    public static let empty = MusicSnapshot(track: nil, state: .stopped, position: 0, sampledAt: 0, rate: 0)
}

/// Where a song's artwork came from (logs and diagnostics only; never log the URL).
public enum MusicArtworkSource: String, Sendable, Equatable {
    /// `MPMediaItem.artwork.image(at:)`: local, no network.
    case mediaItem = "mp"
    /// MusicKit `SystemMusicPlayer.shared.queue.currentEntry.artwork`, loaded through `URLSession.shared`.
    case musicKit = "musickit"
}

/// Encoded artwork of the current song.
public struct MusicArtwork: Sendable, Equatable {
    /// JPEG or PNG bytes, longest side ≤ the requested `maxPixelSize`.
    public var data: Data
    public var source: MusicArtworkSource

    public init(data: Data, source: MusicArtworkSource) {
        self.data = data
        self.source = source
    }
}

/// The system Music app (Apple Music and the music library). Main-actor bound: MediaPlayer's music
/// players must only be used on the main thread, and MusicKit's `SystemMusicPlayer` on the main actor.
/// Implementations never touch the system player before `authorization == .authorized` (no prompt
/// can appear during a ride; a missing purpose string would even terminate the app).
@MainActor
public protocol MusicPlaying: AnyObject {
    /// false where there is no system music player (`authorization` is then `.unavailable`).
    var isAvailable: Bool { get }
    var authorization: MusicAuthorizationState { get }
    /// Shows the system prompt when undetermined and returns the answer. Only from an explicit rider
    /// action on the phone (the Settings toggle), never from the dash or during a ride.
    func requestAuthorization() async -> MusicAuthorizationState
    /// Latest reading (`.empty` while not observing).
    var snapshot: MusicSnapshot { get }
    /// Main actor: the song, the playback state, `otherAudioPlaying` or the position (a seek, or a
    /// drift ≥ 1.5 s from the extrapolation) changed — NOT the steady advance of the position.
    var onChange: ((MusicSnapshot) -> Void)? { get set }
    /// Starts following the Music app (playback notifications + a light re-sync poll). Needs
    /// `.authorized`; otherwise does nothing. Idempotent.
    func startObserving()
    /// Stops following; `snapshot` becomes `.empty` (without an `onChange`).
    func stopObserving()
    /// Re-reads the player now (after a command, when the app becomes active); fires `onChange` only
    /// when the reading differs meaningfully. No-op while not observing.
    func refresh()
    /// Artwork of the CURRENT song: one attempt (≤ 10 s), nil when `trackID` is not the current song
    /// any more or no artwork is available right now (the caller retries later).
    func artwork(trackID: String, maxPixelSize: Int) async -> MusicArtwork?
    func play()
    func pause()
    func skipToNext()
    func skipToPrevious()
    /// Restarts the current song.
    func skipToBeginning()
}

/// The null music port (platforms without a system music player, services that do not set one).
public final class UnavailableMusic: MusicPlaying {
    nonisolated public init() {}
    public var isAvailable: Bool { false }
    public var authorization: MusicAuthorizationState { .unavailable }
    public func requestAuthorization() async -> MusicAuthorizationState { .unavailable }
    public var snapshot: MusicSnapshot { .empty }
    public var onChange: ((MusicSnapshot) -> Void)? {
        get { nil }
        set {}
    }
    public func startObserving() {}
    public func stopObserving() {}
    public func refresh() {}
    public func artwork(trackID: String, maxPixelSize: Int) async -> MusicArtwork? { nil }
    public func play() {}
    public func pause() {}
    public func skipToNext() {}
    public func skipToPrevious() {}
    public func skipToBeginning() {}
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
    // ADDITION (locked iPhone, Phase 0): what the `[lock]` status line and the diagnostics need.
    /// The encoder now feeding the dash: "vt-hw", "vt-sw", "cpu-<backend>", "hold"; nil when idle /
    /// stopped or unknown.
    public var encoder: String?
    /// REQ 114 pulls per second (the dash's demand).
    public var pullRate: Double
    /// Pulls answered with a frame, of which hold IDRs and fallback IDRs (counters since the engine
    /// was created).
    public var pullsServed: Int
    public var holdFramesServed: Int
    public var fallbackKeyframesServed: Int
    public var encoderErrors: Int
    /// Process CPU % of one core (100 = one core busy), latest background measurement; nil when not
    /// measured.
    public var cpuPercent: Double?
    /// The background frame-rate cap in effect while a background encoder runs; nil otherwise.
    public var backgroundFpsCap: Int?

    public init(mode: String = "idle", renderedFrames: Int = 0, encodedFrames: Int = 0,
                framesPerSecond: Double = 0, bitrate: Int = 0, lastError: String? = nil, encoder: String? = nil,
                pullRate: Double = 0, pullsServed: Int = 0, holdFramesServed: Int = 0, fallbackKeyframesServed: Int = 0,
                encoderErrors: Int = 0, cpuPercent: Double? = nil, backgroundFpsCap: Int? = nil) {
        self.mode = mode
        self.renderedFrames = renderedFrames
        self.encodedFrames = encodedFrames
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.lastError = lastError
        self.encoder = encoder
        self.pullRate = pullRate
        self.pullsServed = pullsServed
        self.holdFramesServed = holdFramesServed
        self.fallbackKeyframesServed = fallbackKeyframesServed
        self.encoderErrors = encoderErrors
        self.cpuPercent = cpuPercent
        self.backgroundFpsCap = backgroundFpsCap
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
    /// ADDITION (fix-media, MED:MP-6): called (any thread) with the canvas the encoder was just
    /// prepared at by the link (`VideoFrameSource.prepare`: REQ 16, a REQ 16 without a usable size
    /// that keeps the previous canvas, or 112 without any 16). The dash UI must be laid out for
    /// exactly this canvas (RLY 17, encoder and layout agree). Default: never called.
    var onCanvasPrepared: (@Sendable (VideoCanvas) -> Void)? { get set }
    /// ADDITION (fix-media, MED:MP-2): pre-encode the hold picture NOW (the app is about to leave
    /// the foreground: the hardware encoder is still available) at the canvas the dash negotiated —
    /// or, before any REQ 16, at `expectedCanvas` (the session's learned / default canvas), so a
    /// dash that negotiates while the phone is locked still gets a picture. Default: forwards to
    /// `prepareHoldPicture()`.
    func prepareHoldPicture(expectedCanvas: VideoCanvas)
    /// ADDITION (fix-media, MED:MP-7): records every access unit served to the dash as a raw
    /// Annex-B `.h264` file (the first `maxFrames`) — the day-one diagnostic of media-video.md
    /// §15.8, "shareable from the app". Default: throws (unsupported).
    func startWireDump(to url: URL, maxFrames: Int) throws
    /// Closes the recording (the file keeps what was written).
    func stopWireDump()
    /// ADDITION (music): registers (`data` non-nil) or removes (nil) the raster image that display
    /// lists draw with `DashDrawCommand.image(id:…)` — encoded JPEG / PNG / HEIC bytes, decoded and
    /// downsampled once by the renderer side, then the picture is re-rendered (`invalidate`).
    /// Unknown ids draw nothing (the scene's placeholder shows). Any thread. Default: ignored.
    func setDashImage(id: String, data: Data?)
    /// ADDITION (locked iPhone, Phase 0, P0-4): the app is becoming inactive — call right after
    /// `prepareHoldPicture(expectedCanvas:)` (the engine runs both on its render queue, in call order):
    /// pre-warm the background encoder (rung 1) while the app is still in the foreground. Any thread.
    /// Default: no-op.
    func prepareBackgroundEncoder()
    /// ADDITION (locked iPhone, Phase 0): what the dash gets while the phone is locked (the ladder of
    /// background encoders). Takes effect at the next background entry. Any thread. Default: no-op.
    func setLockedStreamPolicy(_ policy: LockedStreamPolicy)
}

public extension DashProjecting {
    func setDashImage(id: String, data: Data?) {}
    func prepareBackgroundEncoder() {}
    func setLockedStreamPolicy(_ policy: LockedStreamPolicy) {}

    var onCanvasPrepared: (@Sendable (VideoCanvas) -> Void)? {
        get { nil }
        set {}
    }

    func prepareHoldPicture(expectedCanvas: VideoCanvas) { prepareHoldPicture() }
    func startWireDump(to url: URL, maxFrames: Int) throws { throw CocoaError(.featureUnsupported) }
    func stopWireDump() {}
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
    /// ADDITION (fix-media, MED:MP-7): records every access unit the relay serves to the dash (raw
    /// Annex-B `.h264`, the first `maxFrames`). Default: throws (unsupported).
    func startWireDump(to url: URL, maxFrames: Int) throws
    func stopWireDump()
}

public extension MirrorHosting {
    func startWireDump(to url: URL, maxFrames: Int) throws { throw CocoaError(.featureUnsupported) }
    func stopWireDump() {}
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
    /// ADDITION (music): the system music player (Apple Music); `UnavailableMusic` by default.
    public var music: MusicPlaying
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
                now: @escaping @Sendable () -> Date = { Date() }, music: MusicPlaying? = nil) {
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
        self.music = music ?? UnavailableMusic()
        self.files = files
        self.clock = clock
        self.now = now
    }
}
