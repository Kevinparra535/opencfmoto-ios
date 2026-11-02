// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt and the watchdog of AndroidAutoService.kt
//
// The PXC session engine (docs/spec/session-network.md §5–§6, control-plane.md §4–§5):
//   listen :10922/:10921/:10920 (BEFORE probing) → discovery ladder (Bonjour raced with the
//   gateway :10930 probe, then fallback gateways, then the 10915–10935 scan) → the dash connects
//   back → control/media handlers → frames. Recovery: connect-back timeout (iOS addition),
//   reconnect loop after every bike socket closed, 5 s watchdog for stalls and error re-arms.
//
// Concurrency: `EasyConnLink` is the thread-safe public facade (NSLock). Each `start()` creates a
// `LinkSession` with a new generation; `stop()` shuts it down (cancels every task, closes every
// socket and listener) and bumps the generation so late callbacks from the old session are
// ignored — nothing leaks across stop/start (fixes Android's stale-thread race, §6.9).

import Foundation

/// The PXC link to one dash.
///
/// ```swift
/// let link = EasyConnLink(configuration: LinkConfiguration(qr: qr, profileOverride: settings.profileOverride,
///                                                          learnedCanvas: memory.canvas(for: qr.ssid),
///                                                          forceTouchscreen: settings.forceTouch),
///                         network: POSIXNetworkProvider(), frameSource: projectionEngine, signer: signer,
///                         discovery: BonjourDashDiscovery(), gateway: path.gateways.first,
///                         options: { var o = LinkOptions(); o.forceNonTouch = settings.forceNonTouch; return o }())
/// Task { for await event in link.events { … } }   // single consumer
/// link.start()   // binds :10922/:10921/:10920, then probes; restarts cleanly if already running
/// link.stop()
/// ```
///
/// Transport expectations (`NetworkProvider`): `listen` throws when the port is taken (→
/// `.failed(.portInUse)`); accepted streams report the LISTENER port as `localPort` (framing is
/// chosen by it); `close()` makes pending reads throw; `connect` may throw
/// `LinkFailure.localNetworkDenied` (→ `.failed(.localNetworkDenied)`, re-armed by the watchdog).
/// Each `write` carries one complete frame; the engine serializes its own writers per socket.
public final class EasyConnLink: @unchecked Sendable {
    public let configuration: LinkConfiguration
    public let options: LinkOptions
    private let network: NetworkProvider
    private let frameSource: VideoFrameSource
    private let signer: HuidSigner
    private let discovery: DashDiscovery?
    private let gateway: String?
    private let clock: MonotonicClock

    /// Link events (single consumer). Buffers the newest 1024 events if nobody listens.
    public let events: AsyncStream<LinkEvent>
    private let continuation: AsyncStream<LinkEvent>.Continuation

    private let lock = NSLock()
    private var _state: LinkState = .idle
    private var _lastStats = LinkStats()
    private var _profile: BikeProfile
    private var _dashInfo: DashInfo?
    private var _canvas: VideoCanvas?
    private var generation: UInt64 = 0
    private var session: LinkSession?

    /// - Parameters:
    ///   - network: sockets (`POSIXNetworkProvider` in the app, in-memory in tests).
    ///   - frameSource: the encoder side (dash projection engine or mirror).
    ///   - signer: RSA identity for CLIENT_INFO (`SecKeyHuidSigner` or `PureSwiftHuidSigner`).
    ///   - discovery: Bonjour `_EasyConn._tcp` browser, raced with the gateway probe (optional).
    ///   - gateway: Wi-Fi default gateway (NWPath.gateways) if known.
    ///   - clock: monotonic time for stall detection and stats.
    ///   - options: timers and engine knobs not in `LinkConfiguration`.
    public init(configuration: LinkConfiguration, network: NetworkProvider, frameSource: VideoFrameSource,
                signer: HuidSigner, discovery: DashDiscovery? = nil, gateway: String? = nil,
                clock: MonotonicClock = SystemMonotonicClock(), options: LinkOptions = LinkOptions()) {
        self.configuration = configuration
        self.options = options
        self.network = network
        self.frameSource = frameSource
        self.signer = signer
        self.discovery = discovery
        self.gateway = gateway
        self.clock = clock
        var cont: AsyncStream<LinkEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { cont = $0 }
        continuation = cont
        _profile = BikeProfiles.selectByQR(configuration.qr, override: configuration.profileOverride,
                                           learnedCanvas: configuration.learnedCanvas)
    }

    deinit {
        session?.shutdown()
        continuation.finish()
    }

    // MARK: Public state

    public var state: LinkState { lock.lock(); defer { lock.unlock() }; return _state }

    /// Live media counters (fresh snapshot while running, last known after stop).
    public var stats: LinkStats {
        lock.lock()
        let s = session
        let last = _lastStats
        lock.unlock()
        return s?.stats.snapshot() ?? last
    }

    /// Active bike profile: the QR / learned / override guess until CLIENT_INFO, then authoritative.
    public var currentProfile: BikeProfile { lock.lock(); defer { lock.unlock() }; return _profile }

    /// The dash's CLIENT_INFO summary (nil until it arrives).
    public var dashInfo: DashInfo? { lock.lock(); defer { lock.unlock() }; return _dashInfo }

    /// The negotiated canvas of this session (nil until REQ 16).
    public var canvas: VideoCanvas? { lock.lock(); defer { lock.unlock() }; return _canvas }

    /// Profile margins until the rider customises them (800NK Advanced: top 22).
    public var defaultMargins: ScreenMargins { currentProfile.defaultMargins }

    // MARK: Control

    /// Starts (or restarts) the link: binds the listeners, then discovers and probes the dash.
    /// Calling it while running forces a clean restart (Android mode-switch behaviour).
    public func start() {
        lock.lock()
        let old = session
        generation &+= 1
        let gen = generation
        let initial = BikeProfiles.selectByQR(configuration.qr, override: configuration.profileOverride,
                                              learnedCanvas: configuration.learnedCanvas)
        _profile = initial
        _dashInfo = nil
        _canvas = nil
        _lastStats = LinkStats()
        let s = LinkSession(generation: gen, owner: self, configuration: configuration, options: options,
                            network: network, frameSource: frameSource, signer: signer, discovery: discovery,
                            gateway: gateway, clock: clock, initialProfile: initial)
        session = s
        lock.unlock()
        if let old {
            Log.i("LINK", "already running — forcing PXC restart for clean mode switch")
            old.shutdown()
        }
        let qrDesc = configuration.qr.map { "QR ssid=\($0.ssid) modelId=\($0.modelId ?? "-")" } ?? "no QR"
        Log.i("LINK", "→ bike profile (\(qrDesc)): \(initial.name)")
        s.begin()
    }

    /// Stops everything (listeners, sockets, timers) and moves to `.stopped`.
    public func stop() {
        lock.lock()
        let s = session
        session = nil
        generation &+= 1
        if let s { _lastStats = s.stats.snapshot() }
        let changed = _state != .stopped
        _state = .stopped
        if changed { continuation.yield(.state(.stopped)) }
        lock.unlock()
        if let s {
            s.shutdown()
            Log.i("LINK", "stopped")
        }
    }

    /// Drops every live bike socket so the reconnect loop re-probes (app-level recovery).
    public func forceReconnect() {
        lock.lock()
        let s = session
        lock.unlock()
        s?.forceReconnect(reason: "requested")
    }

    // MARK: Session callbacks (internal; ignored for stale generations)

    func sessionStateChanged(_ s: LinkState, generation g: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard g == generation, _state != s else { return }
        _state = s
        continuation.yield(.state(s))
    }

    func sessionIdentified(_ info: DashInfo, profile: BikeProfile, generation g: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard g == generation else { return }
        _dashInfo = info
        _profile = profile
        continuation.yield(.dashIdentified(info))
    }

    func sessionCanvas(_ c: VideoCanvas, generation g: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard g == generation else { return }
        _canvas = c
        continuation.yield(.canvas(c))
    }

    func sessionEvent(_ e: LinkEvent, generation g: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard g == generation else { return }
        if case let .stats(s) = e { _lastStats = s }
        continuation.yield(e)
    }
}

