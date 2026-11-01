// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE (wave 2) — in-memory fakes of every port. Do not edit; logic agents may ADD new
// fake types in other files under Testing/ (e.g. a demo GPS route player).
//
// Used by unit tests (Linux + macOS), SwiftUI previews (`AppModel.preview()`) and the simulator
// demo mode. Everything is offline and deterministic: no sockets, no network, no GPS.

import Foundation
import OpenCfMotoCore

// MARK: - System

@MainActor
public final class PreviewSystem: SystemControlling {
    public var flavor: BuildFlavor = .full
    public var appVersion = "0.1.0"
    public var buildNumber = "1"
    public var deviceModel = "iPhone-Preview"
    public var systemVersion = "iOS 18.0"
    public var preferredLanguageCode = NavLanguage.preferred.rawValue
    public var isIdleTimerDisabled = false
    public var isLowPowerModeEnabled = false
    public var thermalLevel: ThermalLevel = .none
    public var onPowerStateChange: (() -> Void)?
    public var localNetwork: LocalNetworkAccessState = .granted
    /// ADDITION (fix-media, SPEC:CL-10): the simulated system appearance (tests flip it and call
    /// `onPowerStateChange`).
    public var isSystemDarkMode = false
    public private(set) var openedSettingsCount = 0
    public private(set) var hapticCount = 0

    public init() {}

    public func openAppSettings() { openedSettingsCount += 1 }
    public func hapticTap() { hapticCount += 1 }
    public func checkLocalNetworkAccess() async -> LocalNetworkAccessState { localNetwork }
    public func requestLocalNetworkAccess() async -> LocalNetworkAccessState { localNetwork }
}

// MARK: - Wi-Fi

public final class PreviewWifi: WifiJoining, @unchecked Sendable {
    private let lock = NSLock()
    private var network: WifiNetworkInfo
    private var continuations: [UUID: AsyncStream<WifiNetworkInfo>.Continuation] = [:]
    public var supportsAutomaticJoin: Bool
    /// Result of the next `join`.
    public var nextJoinResult: Result<WifiJoinResult, WifiJoinFailure> = .success(.joined)
    public private(set) var joinedSSIDs: [String] = []
    public private(set) var forgottenSSIDs: [String] = []

    public init(supportsAutomaticJoin: Bool = true, network: WifiNetworkInfo = .unavailable) {
        self.supportsAutomaticJoin = supportsAutomaticJoin
        self.network = network
    }

    public func join(ssid: String, passphrase: String?) async throws -> WifiJoinResult {
        let result = lock.withLock { () -> Result<WifiJoinResult, WifiJoinFailure> in
            joinedSSIDs.append(ssid)
            return nextJoinResult
        }
        switch result {
        case .success(let r):
            if r != .manualJoinRequired {
                setNetwork(WifiNetworkInfo(isWifiAvailable: true, ssid: ssid, interfaceName: "en0",
                                           phoneIPv4: "192.168.0.2", gateway: "192.168.0.1",
                                           dashHostCandidates: ["192.168.0.1"]))
            }
            return r
        case .failure(let f):
            throw f
        }
    }

    public func forget(ssid: String) {
        lock.lock(); forgottenSSIDs.append(ssid); lock.unlock()
    }

    public func currentNetwork() async -> WifiNetworkInfo {
        lock.withLock { network }
    }

    public func networkUpdates() -> AsyncStream<WifiNetworkInfo> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let current = network
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
            }
        }
    }

    /// Simulates a Wi-Fi change (tests).
    public func setNetwork(_ info: WifiNetworkInfo) {
        lock.lock()
        network = info
        let targets = Array(continuations.values)
        lock.unlock()
        for c in targets { c.yield(info) }
    }
}

// MARK: - Location / speech / handlebar

@MainActor
public final class PreviewLocation: LocationProviding {
    public var permission: LocationPermission = .whenInUse
    public var isPrecise = true
    public private(set) var isUpdating = false
    public private(set) var isRideActive = false
    public private(set) var lastFix: LocationFix?
    public var onFix: ((LocationFix) -> Void)?
    public var onRawHeading: ((Double) -> Void)?
    public var onPermissionChange: ((LocationPermission) -> Void)?

    public init() {}

    public func requestPermission() {
        if permission == .notDetermined {
            permission = .whenInUse
            onPermissionChange?(permission)
        }
    }
    public func start(rideActive: Bool) { isUpdating = true; isRideActive = rideActive }
    public func setRideActive(_ active: Bool) { isRideActive = active }
    public func stop() { isUpdating = false; isRideActive = false }

    /// Feeds a fix as if CoreLocation produced it (tests / demo).
    public func emit(_ fix: LocationFix) {
        lastFix = fix
        onFix?(fix)
    }

    public func emitHeading(_ degrees: Double) { onRawHeading?(degrees) }
}

@MainActor
public final class PreviewSpeech: SpeechProviding {
    public var isMuted = false
    public private(set) var isSpeaking = false
    public private(set) var spoken: [String] = []

    public init() {}

    public func speak(_ text: String) {
        guard !isMuted else { return }
        spoken.append(text)
    }

    public func stop() { isSpeaking = false }
}

@MainActor
public final class PreviewHandlebar: HandlebarRemoteProviding {
    public var isAvailable = true
    public private(set) var isEnabled = false
    public var volumeButtonsEnabled = false
    public var onSignal: ((HandlebarSignal) -> Void)?

    public init() {}

    public func enable() { isEnabled = true }
    public func disable() { isEnabled = false }

    /// Simulates a handlebar button (tests / demo).
    public func emit(_ signal: HandlebarSignal) {
        guard isEnabled else { return }
        onSignal?(signal)
    }
}

// MARK: - Video

/// A frame source that never produces frames (previews / tests that do not stream).
public final class PreviewFrameSource: VideoFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var preparedCanvas: VideoCanvas?
    public private(set) var resyncCount = 0
    public private(set) var stoppedCount = 0

    public init() {}

    public func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {
        lock.lock(); preparedCanvas = canvas; lock.unlock()
    }
    public func resynchronize() { lock.lock(); resyncCount += 1; lock.unlock() }
    public func nextFrame(timeout: TimeInterval) async -> EncodedFrame? { nil }
    public func mediaStopped() { lock.lock(); stoppedCount += 1; lock.unlock() }
}

public final class PreviewProjection: DashProjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var provider: (@Sendable (TimeInterval) -> DashDisplayList)?
    private var holdProvider: (@Sendable (TimeInterval) -> DashDisplayList)?
    private var _onTileLoaded: (@Sendable () -> Void)?
    public let frameSource: VideoFrameSource
    public let textMeasurer: DashTextMeasurer = ApproximateTextMeasurer()
    public private(set) var parameters: EncoderParameters?
    public private(set) var invalidations = 0
    public private(set) var requestedTiles: [DashMapTile] = []
    public private(set) var mode = "idle"
    public private(set) var tileURLTemplate = ""

    public init(frameSource: VideoFrameSource = PreviewFrameSource()) {
        self.frameSource = frameSource
    }

    public var stats: ProjectionStatsSummary {
        lock.lock(); defer { lock.unlock() }
        return ProjectionStatsSummary(mode: mode, bitrate: parameters?.bitrate ?? 0)
    }

    public var onTileLoaded: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onTileLoaded }
        set { lock.lock(); _onTileLoaded = newValue; lock.unlock() }
    }

    public func setDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?) {
        lock.lock(); self.provider = provider; lock.unlock()
    }
    public func setHoldDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?) {
        lock.lock(); holdProvider = provider; lock.unlock()
    }
    /// Renders the current provider (tests): what the engine would draw at `now`.
    public func currentDisplayList(now: TimeInterval) -> DashDisplayList? {
        lock.lock(); let p = provider; lock.unlock()
        return p?(now)
    }
    public func currentHoldDisplayList(now: TimeInterval) -> DashDisplayList? {
        lock.lock(); let p = holdProvider; lock.unlock()
        return p?(now)
    }
    public func setEncoderParameters(_ parameters: EncoderParameters) {
        lock.lock(); self.parameters = parameters; lock.unlock()
    }
    public func setThermalCapsEnabled(_ enabled: Bool) {}
    public func invalidate() { lock.lock(); invalidations += 1; lock.unlock() }
    public func prepareHoldPicture() {}
    public func enterBackground() { lock.lock(); mode = "hold"; lock.unlock() }
    public func enterForeground() { lock.lock(); mode = "foreground"; lock.unlock() }
    public func stop() { lock.lock(); mode = "stopped"; lock.unlock() }
    public func requestTiles(_ tiles: [DashMapTile]) { lock.lock(); requestedTiles = tiles; lock.unlock() }
    public func prefetchCorridor(_ points: [GeoPoint]) {}
    public func setTileURLTemplate(_ template: String) { lock.lock(); tileURLTemplate = template; lock.unlock() }
    public func clearTileCache() {}
}

public final class PreviewMirror: MirrorHosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _running = false
    private var _connected = false
    private var _onChange: (@Sendable (Bool) -> Void)?
    public let frameSource: VideoFrameSource = PreviewFrameSource()

    public init() {}

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    public var isExtensionConnected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }
    public var onExtensionConnectionChange: (@Sendable (Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChange }
        set { lock.lock(); _onChange = newValue; lock.unlock() }
    }
    public func start() throws { lock.lock(); _running = true; lock.unlock() }
    public func stop() { lock.lock(); _running = false; _connected = false; lock.unlock() }
    public func setFit(_ fit: ScreenFit, margins: ScreenMargins) {}

    /// Simulates the broadcast extension connecting / leaving (tests).
    public func setExtensionConnected(_ connected: Bool) {
        lock.lock(); _connected = connected; let cb = _onChange; lock.unlock()
        cb?(connected)
    }
}

// MARK: - Network

/// Offline HTTP: every request fails with 503 (or a canned response per URL prefix).
public final class PreviewHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var canned: [(prefix: String, response: HTTPResponse)] = []
    public private(set) var requests: [HTTPRequest] = []

    public init() {}

    public func respond(toPrefix prefix: String, with response: HTTPResponse) {
        lock.lock(); canned.append((prefix, response)); lock.unlock()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let hit = lock.withLock { () -> HTTPResponse? in
            requests.append(request)
            let url = request.url.absoluteString
            return canned.first { url.hasPrefix($0.prefix) }?.response
        }
        return hit ?? HTTPResponse(status: 503)
    }
}

/// No sockets: listening succeeds (a listener that never accepts), connecting times out.
public final class PreviewNetwork: NetworkProvider, @unchecked Sendable {
    public init() {}

    public func listen(port: UInt16) async throws -> any StreamListener { PreviewListener(port: port) }

    public func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
        throw TransportError.timeout
    }
}

final class PreviewListener: StreamListener, @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var closed = false
    init(port: UInt16) { self.port = port }

    func accept() async throws -> any ByteStream {
        while true {
            let c = lock.withLock { closed }
            if c || Task.isCancelled { throw TransportError.closed }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func close() { lock.lock(); closed = true; lock.unlock() }
}

// MARK: - Bundle

public extension AppServices {
    /// Offline services for previews, demo mode and tests. Files go to a fresh temp directory.
    @MainActor
    static func preview(flavor: BuildFlavor = .full, clock: MonotonicClock = SystemMonotonicClock()) -> AppServices {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCfMotoPreview-\(UUID().uuidString)", isDirectory: true)
        let files = AppFileLocations(tripsDirectory: root.appendingPathComponent("trips", isDirectory: true),
                                     photosDirectory: root.appendingPathComponent("photos", isDirectory: true),
                                     exportsDirectory: root.appendingPathComponent("exports", isDirectory: true))
        for dir in [files.tripsDirectory, files.photosDirectory, files.exportsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let system = PreviewSystem()
        system.flavor = flavor
        return AppServices(
            keyValueStore: InMemoryKeyValueStore(),
            secretStore: InMemorySecretStore(),
            http: PreviewHTTPClient(),
            setPreferCellular: { _ in },
            network: PreviewNetwork(),
            discovery: nil,
            makeSigner: { PureSwiftHuidSigner.generate() },
            wifi: PreviewWifi(supportsAutomaticJoin: flavor == .full),
            location: PreviewLocation(),
            speech: PreviewSpeech(),
            handlebar: PreviewHandlebar(),
            projection: PreviewProjection(),
            mirror: PreviewMirror(),
            system: system,
            files: files,
            clock: clock
        )
    }
}

public extension AppModel {
    /// A fully offline model for SwiftUI previews.
    static func preview(flavor: BuildFlavor = .full) -> AppModel {
        AppModel(services: .preview(flavor: flavor))
    }
}
