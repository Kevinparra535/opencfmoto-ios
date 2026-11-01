// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (start, discoverAndProbe, probeTarget,
// spawnAccept, onAllConnectionsClosed, readLoop, mediaLoop, startCtrlHeartbeat,
// startHeartbeatLog) and AndroidAutoService.kt (watchdog)
//
// One link session (created by `EasyConnLink.start()`, destroyed by `stop()`). Every task it
// spawns is registered and cancelled on shutdown; every socket/listener is closed; callbacks to the
// owner carry the session generation so a stale session can never touch a new one.
// Locking: one NSLock (`withLock`), never held across an `await`. Lock order: session → owner.

import Foundation

final class LinkSession: @unchecked Sendable {
    private final class Connection: @unchecked Sendable {
        let id: Int
        let stream: any ByteStream
        let port: UInt16
        let isControl: Bool
        /// The peer's address (`LinkPeerHost.normalize`), checked against the dash candidates.
        let peer: String
        /// Serializes the reply path and the heartbeat task on this socket.
        let writeLock = LinkWriteLock()
        /// Guarded by the session lock.
        var heartbeat: Task<Void, Never>?
        init(id: Int, stream: any ByteStream, port: UInt16, isControl: Bool, peer: String) {
            self.id = id
            self.stream = stream
            self.port = port
            self.isControl = isControl
            self.peer = peer
        }
    }

    /// Outcome of registering an accepted socket.
    private enum Registration {
        case accepted(Connection)
        /// The peer is not the dash (SEC-3): closed, the accept loop goes on.
        case rejected(host: String?)
        /// The session is shutting down: the accept loop ends.
        case dead
    }

    private enum DiscoveryResult { case accepted, notFound, denied, aborted }

    static let controlPort: UInt16 = 10922
    static let mediaControlPort: UInt16 = 10921
    static let mediaDataPort: UInt16 = 10920
    /// Creation order of the listeners (Android `LISTEN_PORTS`).
    static let listenPorts: [UInt16] = [controlPort, mediaControlPort, mediaDataPort]

    let generation: UInt64
    private weak var owner: EasyConnLink?
    private let config: LinkConfiguration
    private let options: LinkOptions
    private let timings: LinkTimings
    private let network: NetworkProvider
    private let frameSource: VideoFrameSource
    private let discovery: DashDiscovery?
    private let injectedGateway: String?
    private let clock: MonotonicClock
    let context: LinkSessionContext
    let stats: LinkStatsTracker
    // Set once at the end of init (they capture `self` weakly), read-only afterwards.
    private var touchFilterStorage: GhostTouchFilter?
    private var probeClientStorage: DashProbeClient?

    private let lock = NSLock()
    private var alive = true
    private var state: LinkState = .idle
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextTaskId = 0
    private var listeners: [UInt16: any StreamListener] = [:]
    private var connections: [Int: Connection] = [:]
    private var nextConnectionId = 0
    private var auxStreams: [ObjectIdentifier: any ByteStream] = [:]
    private var everConnected = false
    private var reconnectAttempts = 0
    private var reprobing = false
    private var discovering = false
    private var probeAttemptCounter = 0
    /// A probe was accepted since the last (re)probe started (Android `probed`; logs only).
    private var probeAccepted = false
    private var lastRecoveryAt: TimeInterval = -.infinity
    private var mediaConnectionCount = 0
    private var mediaActive = false
    private var gatewayCandidates: [String] = []
    /// Hosts allowed to connect back (SEC-3): the dash candidates of this session plus every host
    /// that accepted a probe (gateway, Bonjour result, scanned port). Normalized.
    private var allowedPeers: Set<String> = []
    /// Hosts that spoke the PXC control handshake on :10922 (a channel select or CLIENT_INFO) in
    /// this session: only they are served video frames on the media plane.
    private var controlPeers: Set<String> = []
    /// Foreign connections closed so far (the log line is throttled).
    private var rejectedPeers = 0
    /// Log lines produced while holding `lock` (flushed by `withLock`).
    private var pendingLogs: [String] = []

    init(generation: UInt64, owner: EasyConnLink, configuration: LinkConfiguration, options: LinkOptions,
         network: NetworkProvider, frameSource: VideoFrameSource, signer: HuidSigner, discovery: DashDiscovery?,
         gateway: String?, clock: MonotonicClock, initialProfile: BikeProfile) {
        self.generation = generation
        self.owner = owner
        config = configuration
        self.options = options
        timings = options.timings
        self.network = network
        self.frameSource = frameSource
        self.discovery = discovery
        injectedGateway = gateway
        self.clock = clock
        context = LinkSessionContext(phone: configuration.phone, signer: signer, initialProfile: initialProfile,
                                     profileOverride: configuration.profileOverride,
                                     forceTouch: configuration.forceTouchscreen, forceNonTouch: options.forceNonTouch,
                                     timeSyncForcePhone: options.timeSyncForcePhone, clock: clock,
                                     wallClockMillis: options.wallClockMillis, timeZone: options.timeZone,
                                     initialCanvas: LinkSession.initialCanvas(configuration.learnedCanvas))
        stats = LinkStatsTracker(clock: clock, window: options.timings.statsWindow)
        touchFilterStorage = GhostTouchFilter(configuration: options.ghostFilter, clock: clock,
                                              scheduler: options.touchScheduler ?? DispatchTouchStitchScheduler(),
                                              tag: ":\(LinkSession.mediaControlPort)") { [weak self] touch in
            self?.deliverTouch(touch)
        }
        probeClientStorage = DashProbeClient(
            network: network, connectTimeout: options.timings.probeConnectTimeout,
            readTimeout: options.timings.probeReadTimeout,
            track: { [weak self] stream in self?.trackAux(stream) ?? false },
            untrack: { [weak self] stream in self?.untrackAux(stream) })
    }

    /// The canvas assumed before the first REQ 16: the learned one (rounded) if plausible, else
    /// Android's 800×384 default. REQ 16 always overrides it.
    static func initialCanvas(_ learned: VideoCanvas?) -> VideoCanvas {
        guard let l = learned, (16 ... 8192).contains(l.requestedWidth), (16 ... 8192).contains(l.requestedHeight) else {
            return .defaultLandscape
        }
        return .rounded(requestedWidth: l.requestedWidth, requestedHeight: l.requestedHeight, requestedFps: l.requestedFps)
    }

    private var touchFilter: GhostTouchFilter { touchFilterStorage! }
    private var probeClient: DashProbeClient { probeClientStorage! }

    /// Synchronous critical section (safe to call from async code: never spans an `await`).
    /// Log lines queued inside are emitted after unlocking (Log subscribers run synchronously and
    /// must never be able to re-enter the session while its lock is held).
    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        let result: R
        do {
            result = try body()
        } catch {
            let logs = pendingLogs
            pendingLogs.removeAll()
            lock.unlock()
            logs.forEach { Log.i("LINK", $0) }
            throw error
        }
        let logs = pendingLogs
        pendingLogs.removeAll()
        lock.unlock()
        logs.forEach { Log.i("LINK", $0) }
        return result
    }

    // MARK: Lifecycle

    func begin() {
        spawn { [self] in await self.run() }
    }

    func shutdown() {
        let snapshot: (tasks: [Task<Void, Never>], listeners: [any StreamListener], connections: [Connection],
                       aux: [any ByteStream], hadMedia: Bool)? = withLock {
            guard alive else { return nil }
            alive = false
            defer {
                tasks.removeAll()
                listeners.removeAll()
                connections.removeAll()
                auxStreams.removeAll()
                mediaActive = false
                mediaConnectionCount = 0
            }
            return (Array(tasks.values), Array(listeners.values), Array(connections.values),
                    Array(auxStreams.values), mediaActive)
        }
        guard let s = snapshot else { return }
        s.tasks.forEach { $0.cancel() }
        s.listeners.forEach { $0.close() }
        for c in s.connections {
            c.heartbeat?.cancel()
            c.stream.close()
        }
        s.aux.forEach { $0.close() }
        touchFilter.reset()
        if s.hadMedia { frameSource.mediaStopped() }
    }

    var isAlive: Bool { withLock { alive } }

    /// Alive and no bike socket connected (probing is only useful then).
    private var canProbe: Bool { withLock { alive && connections.isEmpty } }

    @discardableResult
    private func spawn(_ body: @escaping @Sendable () async -> Void) -> Bool {
        withLock {
            guard alive else { return false }
            let id = nextTaskId
            nextTaskId += 1
            tasks[id] = Task { [weak self] in
                await body()
                self?.taskFinished(id)
            }
            return true
        }
    }

    private func taskFinished(_ id: Int) {
        withLock { tasks[id] = nil }
    }

    private func trackAux(_ s: any ByteStream) -> Bool {
        withLock {
            guard alive else { return false }
            auxStreams[ObjectIdentifier(s)] = s
            return true
        }
    }

    private func untrackAux(_ s: any ByteStream) {
        withLock { auxStreams[ObjectIdentifier(s)] = nil }
    }

    // MARK: State

    /// Call with `lock` held.
    private func setStateLocked(_ s: LinkState) {
        guard alive, state != s else { return }
        state = s
        pendingLogs.append("[state] \(s)")
        owner?.sessionStateChanged(s, generation: generation)
    }

    private func setState(_ s: LinkState) {
        withLock { setStateLocked(s) }
    }

    /// Call with `lock` held.
    private func failLocked(_ f: LinkFailure) {
        lastRecoveryAt = clock.now()
        setStateLocked(.failed(f))
    }

    // MARK: Run

    private func run() async {
        setState(.startingServers)
        let addresses = options.interfaceProvider()
        Log.i("LINK", "---- environment ----")
        Log.i("LINK", "interfaces: \(addresses.map(\.description).joined(separator: ", "))")
        Log.i("LINK", "---------------------")
        // 1. Addresses: phone IPv4 on the bike Wi-Fi and the ordered dash candidates.
        let local: InterfaceAddress?
        if let configured = config.localHost {
            local = addresses.first { $0.ipv4 == configured }
                ?? InterfaceAddress(name: "configured", ipv4: configured, netmask: "255.255.255.0")
        } else {
            local = InterfaceAddresses.pickBikeIPv4(from: addresses, interfaceName: options.wifiInterfaceName,
                                                     subnetHint: config.dashHost ?? injectedGateway)
        }
        let candidates = InterfaceAddresses.gatewayCandidates(dashHost: config.dashHost, injectedGateway: injectedGateway,
                                                              local: local)
        guard local != nil || config.dashHost != nil || injectedGateway != nil, let primary = candidates.first else {
            Log.e("LINK", "could not resolve our IPv4 on the bike network; aborting")
            withLock { setStateLocked(.failed(.noWifiAddress)) }
            return
        }
        withLock {
            gatewayCandidates = candidates
            allowedPeers.formUnion(candidates.compactMap(LinkPeerHost.normalize))
        }
        let fallbacks = candidates.count > 1 ? " (fallbacks \(candidates.dropFirst().joined(separator: ", ")))" : ""
        Log.i("LINK", "our IP=\(local?.ipv4 ?? "?")  bike IP=\(primary)\(fallbacks)")

        // 2. Listen on all three ports BEFORE probing.
        for port in LinkSession.listenPorts {
            do {
                let listener = try await network.listen(port: port)
                let ok: Bool = withLock {
                    if alive { listeners[port] = listener }
                    return alive
                }
                if !ok {
                    listener.close()
                    return
                }
            } catch {
                Log.e("LINK", "bind :\(port) failed: \(error)")
                Log.e("LINK", "!! link ports are held by another app (usually the official CFMoto/EasyConnect app). Close it (swipe it away) and reconnect — OpenCfMoto needs ports [10922, 10921, 10920].")
                let (opened, ts): ([any StreamListener], [Task<Void, Never>]) = withLock {
                    setStateLocked(.failed(.portInUse(port)))
                    alive = false
                    defer {
                        listeners.removeAll()
                        tasks.removeAll()
                    }
                    return (Array(listeners.values), Array(tasks.values))
                }
                opened.forEach { $0.close() }
                ts.forEach { $0.cancel() }
                return
            }
        }
        let ls = withLock { listeners }
        Log.i("LINK", "listening on \(local?.ipv4 ?? "*") ports [10922, 10921, 10920] (\(ls.count) open)")
        for port in LinkSession.listenPorts {
            guard let l = ls[port] else { continue }
            spawn { [self] in await self.acceptLoop(port: port, listener: l) }
        }
        spawn { [self] in await self.watchdogLoop() }
        // 3. Discovery + probe; the dash then connects back to the listeners.
        await runDiscovery()
    }

    // MARK: Accept / connections

    private func acceptLoop(port: UInt16, listener initial: any StreamListener) async {
        var listener = initial
        var relistens = 0
        while isAlive {
            let stream: any ByteStream
            do {
                stream = try await listener.accept()
            } catch {
                guard isAlive else { return }
                // A listener dying mid-session would make every reconnect fail silently: re-listen.
                Log.e("LINK", "[:\(port)] accept ended: \(error)")
                guard relistens < 5, await LinkIO.sleep(max(0.05, timings.reconnectBackoffBase)) else { return }
                relistens += 1
                guard let fresh = try? await network.listen(port: port) else { continue }
                let ok: Bool = withLock {
                    if alive { listeners[port] = fresh }
                    return alive
                }
                if !ok {
                    fresh.close()
                    return
                }
                listener = fresh
                Log.i("LINK", "[:\(port)] listening again")
                continue
            }
            switch register(stream) {
            case let .accepted(conn):
                if !spawn({ [self] in await self.serve(conn) }) { stream.close() }
            case let .rejected(host):
                // Not the dash (SEC-3): close it and keep accepting — one foreign client must not
                // be able to stop the listener either.
                stream.close()
                let n: Int = withLock {
                    rejectedPeers += 1
                    return rejectedPeers
                }
                if n <= 5 || n % 50 == 0 {
                    Log.w("LINK", "[:\(port)] !! refused a connection from \(host ?? "an unknown address") — not the dash this session probed (#\(n))")
                }
            case .dead:
                stream.close()
                return
            }
        }
    }

    /// Accounting for an accepted bike socket (Android `spawnAccept`): everConnected, budget reset,
    /// live count, state. Android accepts any peer; the iOS link only accepts the dash (SEC-3): the
    /// session's dash candidates (explicit / NWPath gateway, subnet .1, known dash gateways) and
    /// every host that accepted a probe. A loopback e2e run (fake dash on 127.0.0.1 as the gateway)
    /// passes the same check.
    private func register(_ stream: any ByteStream) -> Registration {
        let peer = LinkPeerHost.normalize(stream.remoteHost)
        let result: Registration = withLock {
            guard alive else { return .dead }
            guard let peer, allowedPeers.contains(peer) else { return .rejected(host: peer) }
            let isControl = stream.localPort == LinkSession.controlPort
            let c = Connection(id: nextConnectionId, stream: stream, port: stream.localPort, isControl: isControl, peer: peer)
            nextConnectionId += 1
            connections[c.id] = c
            everConnected = true
            reconnectAttempts = 0 // a fresh connection resets the retry budget
            if !isControl {
                mediaConnectionCount += 1
                mediaActive = true
            }
            switch state {
            case .probing, .awaitingCallback, .reconnecting, .startingServers, .failed:
                // (a live session is only ever .failed for a recoverable reason)
                setStateLocked(isControl ? .handshaking : .awaitingMedia)
            case .handshaking where !isControl:
                setStateLocked(.awaitingMedia)
            default:
                break
            }
            return .accepted(c)
        }
        if case .accepted = result { Log.i("LINK", "[:\(stream.localPort)] <<< bike connected from \(stream.remoteEndpoint)") }
        return result
    }

    /// The peer completed the PXC control handshake on :10922 (channel select / CLIENT_INFO).
    private func markControlPeer(_ peer: String) {
        withLock { _ = controlPeers.insert(peer) }
    }

    /// Whether video frames may be served to `peer` (it spoke the control handshake first, as every
    /// dash family does — control-plane.md §5.5 S4–S9 precede S10).
    private func mayServeFrames(to peer: String) -> Bool {
        withLock { controlPeers.contains(peer) }
    }

    private func connectionEnded(_ conn: Connection) {
        let outcome: (stopMedia: Bool, allClosed: Bool)? = withLock {
            guard connections.removeValue(forKey: conn.id) != nil else { return nil }
            conn.heartbeat?.cancel()
            conn.heartbeat = nil
            var stopMedia = false
            if !conn.isControl {
                mediaConnectionCount -= 1
                if mediaConnectionCount <= 0, mediaActive {
                    mediaConnectionCount = 0
                    mediaActive = false
                    stopMedia = true
                }
            }
            return (stopMedia, alive && connections.isEmpty)
        }
        guard let outcome else { return }
        if outcome.stopMedia {
            context.markMediaPrepared(false)
            frameSource.mediaStopped()
        }
        if outcome.allClosed { onAllConnectionsClosed() }
    }

    private func isOpen(_ conn: Connection) -> Bool {
        withLock { alive && connections[conn.id] != nil }
    }

    private func serve(_ conn: Connection) async {
        if conn.isControl {
            await serveControl(conn)
        } else {
            await serveMedia(conn)
        }
        conn.stream.close()
        connectionEnded(conn)
    }

    /// :10922 read loop (Android `readLoop` control branch): frame error → close this socket;
    /// handler (write) error → log and keep reading.
    private func serveControl(_ conn: Connection) async {
        let tag = ":\(conn.port)"
        Log.i("LINK", "[\(tag)] framing=CmdBaseHead (PXC control)")
        let handler = ControlChannelHandler(context: context, tag: tag)
        while isOpen(conn) {
            let frame: PxcFrame
            do {
                frame = try await PxcFrame.read(from: conn.stream)
            } catch let e as PxcFrameError {
                Log.e("LINK", "[\(tag)] frame error: \(e)")
                return
            } catch TransportError.closed {
                Log.i("LINK", "[\(tag)] bike closed")
                return
            } catch {
                Log.i("LINK", "[\(tag)] read error: \(error)")
                return
            }
            let response = handler.handle(frame)
            // Publish first (profile / dash info are current by the time the dash reads the reply);
            // the heartbeat's first beat is one interval after the select, so it still follows the ack.
            for event in response.events {
                switch event {
                case let .channelSelected(channel, startHeartbeat):
                    markControlPeer(conn.peer)
                    if startHeartbeat { startHeartbeatTask(conn, label: channel.rawValue) }
                case let .dashIdentified(info, profile):
                    markControlPeer(conn.peer)
                    owner?.sessionIdentified(info, profile: profile, generation: generation)
                case .checkSnCompleted:
                    withLock { if state == .handshaking { setStateLocked(.awaitingMedia) } }
                default:
                    break
                }
            }
            for reply in response.replies {
                do {
                    try await conn.writeLock.write(reply.encoded(), to: conn.stream)
                } catch {
                    Log.w("LINK", "[\(tag)] handler error: \(error)")
                    break
                }
            }
        }
    }

    /// :10921 / :10920 read loop (Android `mediaLoop`, port-agnostic).
    private func serveMedia(_ conn: Connection) async {
        let tag = ":\(conn.port)"
        Log.i("LINK", "[\(tag)] framing=ReqBase (media plane) profile=\(context.activeProfile.name)")
        let peer = conn.peer
        let handler = MediaChannelHandler(context: context, frameSource: frameSource, stats: stats,
                                          framePullTimeout: config.framePullTimeout, tag: tag,
                                          resynchronizeOnStartH264: options.resynchronizeOnStartH264,
                                          encoderParameters: options.encoderParameters,
                                          mayServeFrames: { [weak self] in self?.mayServeFrames(to: peer) ?? false }) { [weak self] touch in
            self?.touchFilter.handle(touch)
        }
        let stream = conn.stream
        while isOpen(conn) {
            let message: MediaMessage
            do {
                message = try await MediaMessage.read(from: stream)
            } catch TransportError.closed {
                Log.i("LINK", "[\(tag)] media closed")
                return
            } catch {
                Log.i("LINK", "[\(tag)] \(error)")
                return
            }
            let events: [MediaChannelEvent]
            do {
                events = try await handler.handle(message) { data in try await stream.write(data) }
            } catch {
                Log.w("LINK", "[\(tag)] write error: \(error)")
                return
            }
            for event in events {
                switch event {
                case let .canvasNegotiated(canvas):
                    owner?.sessionCanvas(canvas, generation: generation)
                case .mediaStarted:
                    owner?.sessionEvent(.mediaStarted, generation: generation)
                    withLock { if state == .handshaking { setStateLocked(.awaitingMedia) } }
                case .frameSent:
                    // First frame of this (re)connection → STREAMING.
                    withLock { if state != .streaming { setStateLocked(.streaming) } }
                default:
                    break
                }
            }
        }
    }

    private func deliverTouch(_ touch: DashTouch) {
        var t = touch
        if options.clampTouchesToCanvas {
            let c = context.canvas
            if c.width > 0, c.height > 0 {
                t.x = min(max(0, t.x), c.width - 1)
                t.y = min(max(0, t.y), c.height - 1)
            }
        }
        owner?.sessionEvent(.touch(t), generation: generation)
    }

    // MARK: Heartbeats

    /// Phone heartbeat 0x70000000 every `heartbeatInterval` on a channel-selected :10922 socket
    /// (first beat one interval after the select; stops on the first send failure). One per
    /// connection (deduplicated by the handler).
    private func startHeartbeatTask(_ conn: Connection, label: String) {
        let interval = timings.heartbeatInterval
        let beat = PxcFrame(cmd: PxcCmd.heartbeat).encoded()
        let task = Task { [weak self] in
            Log.i("LINK", "[hb] PXC \(label) heartbeat started (0x70000000 every \(Int(interval * 1000))ms)")
            var beats = 0
            while true {
                guard await LinkIO.sleep(interval) else { return }
                guard let self, self.isOpen(conn) else { return }
                do {
                    try await conn.writeLock.write(beat, to: conn.stream)
                } catch {
                    Log.w("LINK", "[hb] PXC \(label) heartbeat send failed: \(error)")
                    return
                }
                beats += 1
                if beats <= 3 || beats % 15 == 0 { Log.i("LINK", "[hb] → PXC \(label) heartbeat #\(beats)") }
            }
        }
        let kept: Bool = withLock {
            guard alive, connections[conn.id] != nil else { return false }
            conn.heartbeat?.cancel()
            conn.heartbeat = task
            return true
        }
        if !kept { task.cancel() }
    }

    // MARK: Discovery ladder

    private func runDiscovery() async {
        let start: Bool = withLock {
            guard alive, !discovering else { return false }
            discovering = true
            probeAttemptCounter = 0
            return true
        }
        guard start else { return }
        let result = await discoveryLadder()
        enum Next { case none, connectBackTimer, logNotFound }
        let next: Next = withLock {
            discovering = false
            guard alive else { return .none }
            switch result {
            case .accepted:
                guard connections.isEmpty, !everConnected else { return .none }
                setStateLocked(.awaitingCallback)
                return config.connectBackTimeout > 0 ? .connectBackTimer : .none
            case .notFound:
                guard connections.isEmpty else { return .none }
                failLocked(.dashNotFound)
                return .logNotFound
            case .denied:
                if connections.isEmpty { failLocked(.localNetworkDenied) }
                return .none
            case .aborted:
                return .none
            }
        }
        switch next {
        case .connectBackTimer:
            spawn { [self] in await self.connectBackTimer() }
        case .logNotFound:
            Log.e("LINK", "!! Wi-Fi is up but EasyConn never answered (Bonjour empty, :10930 refused, nearby ports quiet). Keep the pairing QR open on the dash.")
        case .none:
            break
        }
    }

    /// Initial ladder (iOS order, control-plane.md §18.5): Bonjour raced with gateway:10930 ×5 → other
    /// gateway candidates ×2 → scan 10915–10935 and probe open ports ×2 (10930 first).
    private func discoveryLadder() async -> DiscoveryResult {
        let candidates = withLock { gatewayCandidates }
        guard let primary = candidates.first else { return .notFound }
        let gate = ProbeGate()
        let denied = Locked(false)

        // 1. Bonjour raced with the classic gateway :10930 probe; the first acceptance wins.
        var paths: [@Sendable () async -> Bool] = [
            { [self] in
                await self.probe(host: primary, port: PxcProbe.port, attempts: self.timings.gatewayProbeAttempts,
                                 gate: gate, denied: denied)
            },
        ]
        if let discovery {
            paths.append { [self] in await self.bonjourPath(discovery, gate: gate, denied: denied) }
        }
        if await LinkSession.firstTrue(paths) { return .accepted }
        if denied.current { return .denied }
        guard canProbe else { return .aborted }

        // 2. Other guessed gateways.
        for host in candidates.dropFirst() {
            if await probe(host: host, port: PxcProbe.port, attempts: timings.fallbackGatewayProbeAttempts,
                           gate: gate, denied: denied) {
                return .accepted
            }
            if denied.current { return .denied }
            guard canProbe else { return .aborted }
        }

        // 3. Last resort: connect-scan the gateway and probe what is open.
        let open = await probeClient.scanOpenPorts(host: primary, ports: timings.portScanRange,
                                                   timeout: timings.portScanConnectTimeout,
                                                   shouldContinue: { [weak self] in self?.canProbe ?? false })
        for port in open {
            if await probe(host: primary, port: port, attempts: timings.scannedPortProbeAttempts, gate: gate, denied: denied) {
                return .accepted
            }
            if denied.current { return .denied }
            guard canProbe else { return .aborted }
        }
        if denied.current { return .denied }
        return canProbe ? .notFound : .aborted
    }

    private func bonjourPath(_ discovery: DashDiscovery, gate: ProbeGate, denied: Locked<Bool>) async -> Bool {
        for round in 0 ..< 2 {
            guard canProbe, await !gate.accepted else { return false }
            Log.i("LINK", "[DISC] discovering _EasyConn._tcp.…")
            let found = await discovery.discover(timeout: timings.bonjourBrowseTimeout)
            guard let endpoint = found.first else {
                Log.i("LINK", "[DISC] NSD timed out / no usable EasyConn advertisement")
                return false
            }
            let pkg = endpoint.txt["packagename"] ?? endpoint.txt["packageName"] ?? endpoint.txt["package"]
            Log.i("LINK", "[DISC] NSD → \(endpoint.host):\(endpoint.port)\(pkg.map { " pkg=\($0)" } ?? "")")
            if await probe(host: endpoint.host, port: endpoint.port, attempts: timings.bonjourProbeAttempts,
                           gate: gate, denied: denied) {
                return true
            }
            if denied.current { return false }
            if round == 0 { Log.i("LINK", "[DISC] NSD endpoint did not accept probe — re-discovering…") }
        }
        return false
    }

    /// Up to `attempts` probe attempts with `retryUnit × n` sleeps (also after the last attempt,
    /// Android parity). Stops as soon as another path was accepted or a bike socket exists.
    private func probe(host: String, port: UInt16, attempts: Int, gate: ProbeGate, denied: Locked<Bool>,
                       reconnecting: Bool = false) async -> Bool {
        var attempt = 0
        while attempt < attempts {
            attempt += 1
            guard canProbe, !denied.current, !Task.isCancelled else { return false }
            guard await gate.acquire() else { return false } // another path was accepted
            if !reconnecting {
                withLock {
                    probeAttemptCounter += 1
                    if connections.isEmpty { setStateLocked(.probing(attempt: probeAttemptCounter)) }
                }
            }
            let outcome = await probeClient.probeOnce(host: host, port: port, attempt: attempt)
            await gate.release(accepted: outcome == .accepted)
            switch outcome {
            case .accepted:
                withLock {
                    probeAccepted = true
                    // The dash calls back from the address it was probed at (SEC-3 allowlist).
                    if let h = LinkPeerHost.normalize(host) { allowedPeers.insert(h) }
                }
                return true
            case .localNetworkDenied:
                denied.set(true)
                return false
            default:
                break
            }
            guard await LinkIO.sleep(timings.probeRetryUnit * Double(attempt)) else { return false }
        }
        return false
    }

    /// Runs the operations concurrently; true as soon as one returns true (the others are cancelled
    /// and NOT awaited, so a slow Bonjour browse cannot delay an accepted gateway probe), false when
    /// all returned false.
    static func firstTrue(_ ops: [@Sendable () async -> Bool]) async -> Bool {
        guard !ops.isEmpty else { return false }
        let shared = Locked<(remaining: Int, done: Bool, tasks: [Task<Void, Never>])>((ops.count, false, []))
        let pending = Locked<CheckedContinuation<Bool, Never>?>(nil)
        let finish: @Sendable (Bool) -> Void = { value in
            let c: CheckedContinuation<Bool, Never>? = pending.withLock { c in
                defer { c = nil }
                return c
            }
            c?.resume(returning: value)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                pending.set(c)
                for op in ops {
                    let t = Task {
                        let r = await op()
                        let decision: Bool? = shared.withLock { s in
                            if s.done { return nil }
                            s.remaining -= 1
                            if r {
                                s.done = true
                                return true
                            }
                            if s.remaining == 0 {
                                s.done = true
                                return false
                            }
                            return nil
                        }
                        guard let decision else { return }
                        if decision { shared.withLock { $0.tasks }.forEach { $0.cancel() } }
                        finish(decision)
                    }
                    shared.withLock { $0.tasks.append(t) }
                }
            }
        } onCancel: {
            shared.withLock { $0.tasks }.forEach { $0.cancel() }
        }
    }

    /// iOS addition (Android has no timeout here): an accepted probe with no call-back within
    /// `connectBackTimeout` re-runs discovery. Only before the first connection — afterwards the
    /// reconnect loop owns re-probing.
    private func connectBackTimer() async {
        guard await LinkIO.sleep(config.connectBackTimeout) else { return }
        let retry = withLock { alive && !everConnected && connections.isEmpty && !reprobing && !discovering }
        guard retry else { return }
        Log.w("LINK", "[PROBE] !! the dash accepted the probe but did not connect back within \(config.connectBackTimeout)s — re-probing")
        await runDiscovery()
    }

    // MARK: Reconnect loop

    /// Every bike socket closed (Android `onAllConnectionsClosed`).
    private func onAllConnectionsClosed() {
        enum Next { case none, gaveUp, loop }
        let next: Next = withLock {
            guard alive, everConnected, !reprobing else { return .none }
            if reconnectAttempts >= config.maxReconnectAttempts {
                failLocked(.lostLink)
                return .gaveUp
            }
            reprobing = true
            setStateLocked(.reconnecting(attempt: reconnectAttempts + 1))
            return .loop
        }
        switch next {
        case .gaveUp:
            Log.e("LINK", "[reconnect] gave up after \(config.maxReconnectAttempts) attempts — tap Connect to retry")
        case .loop:
            if !spawn({ [self] in await self.reconnectLoop() }) { withLock { reprobing = false } }
        case .none:
            break
        }
    }

    private func reconnectLoop() async {
        let max = config.maxReconnectAttempts
        while true {
            let step: (n: Int, candidates: [String])? = withLock {
                guard alive, connections.isEmpty, reconnectAttempts < max else { return nil }
                reconnectAttempts += 1
                setStateLocked(.reconnecting(attempt: reconnectAttempts))
                return (reconnectAttempts, gatewayCandidates)
            }
            guard let step else { break }
            let backoff = timings.reconnectBackoff(attempt: step.n)
            Log.i("LINK", "[reconnect] link lost — re-probing (attempt \(step.n)/\(max)) in \(Int(backoff * 1000))ms")
            guard await LinkIO.sleep(backoff), canProbe else { break }
            stats.resetConnectionFrameCount() // the first frame after reconnect re-signals STREAMING
            withLock { probeAccepted = false }
            let gate = ProbeGate()
            let denied = Locked(false)
            var accepted = false
            if let primary = step.candidates.first {
                accepted = await probe(host: primary, port: PxcProbe.port, attempts: timings.reconnectProbeAttempts,
                                       gate: gate, denied: denied, reconnecting: true)
            }
            if !accepted, canProbe, !denied.current, let discovery {
                Log.i("LINK", "[DISC] discovering _EasyConn._tcp.…")
                if let endpoint = await discovery.discover(timeout: timings.bonjourBrowseTimeout).first {
                    Log.i("LINK", "[DISC] NSD → \(endpoint.host):\(endpoint.port)")
                    accepted = await probe(host: endpoint.host, port: endpoint.port, attempts: timings.reconnectProbeAttempts,
                                           gate: gate, denied: denied, reconnecting: true)
                }
            }
            if accepted {
                Log.i("LINK", "[reconnect] probe accepted — waiting \(Int(timings.reconnectSettle * 1000))ms for the dash")
            }
            // Give the dash a moment to connect back before deciding to try again.
            guard await LinkIO.sleep(timings.reconnectSettle) else { break }
        }
        let exhausted: Bool = withLock {
            reprobing = false
            guard alive, connections.isEmpty, reconnectAttempts >= max else { return false }
            failLocked(.lostLink) // iOS: ERROR as soon as the budget is spent (Android waits for another close)
            return true
        }
        if exhausted { Log.e("LINK", "[reconnect] gave up after \(max) attempts — tap Connect to retry") }
    }

    /// Drops every live bike socket; the reconnect loop runs when the last one closes.
    func forceReconnect(reason: String) {
        let cs = withLock { Array(connections.values) }
        Log.w("LINK", "[watchdog] forcing reconnect (\(reason)) — dropping \(cs.count) live socket(s)")
        cs.forEach { $0.stream.close() }
    }

    // MARK: Watchdog

    /// 5 s tick: stats event + `hb#` health line; STREAMING with no frame for > stallTimeout → drop
    /// every bike socket (cooldown); AWAITING_MEDIA with media open and an unanswered 114 older than
    /// stallTimeout (no first frame, iOS addition) → the same; recoverable `.failed` → re-arm after
    /// `errorRearmInterval`.
    private func watchdogLoop() async {
        var tick = 0
        while true {
            guard await LinkIO.sleep(timings.watchdogTick), isAlive else { return }
            tick += 1
            let snap = stats.snapshot()
            let unansweredSince = stats.firstUnansweredPullAt
            owner?.sessionEvent(.stats(snap), generation: generation)
            let now = clock.now()
            let check: (state: LinkState, open: Int, probed: Bool, media: Bool, stall: Bool, noFirstFrame: Bool,
                        rearm: Bool) = withLock {
                var stall = false
                var noFirstFrame = false
                var rearm = false
                if state == .streaming, let last = snap.lastFrameAt, now - last > config.stallTimeout,
                   now - lastRecoveryAt > config.stallReconnectCooldown {
                    lastRecoveryAt = now
                    stall = true
                }
                // iOS addition (MP-1): media sockets open but this (re)connection never got its
                // first frame — e.g. the first 114 came before any picture existed. The dash pulls
                // in lock-step, so it may never pull again; if it also keeps :10922 open nothing
                // else would ever recover. Same threshold and cooldown as the stall check.
                if state == .awaitingMedia, mediaActive, let since = unansweredSince, now - since > config.stallTimeout,
                   now - lastRecoveryAt > config.stallReconnectCooldown {
                    lastRecoveryAt = now
                    noFirstFrame = true
                }
                if case let .failed(f) = state, f == .lostLink || f == .dashNotFound || f == .localNetworkDenied,
                   let interval = timings.errorRearmInterval, now - lastRecoveryAt > interval, connections.isEmpty {
                    lastRecoveryAt = now
                    rearm = true
                }
                return (state, listeners.count, probeAccepted, mediaActive, stall, noFirstFrame, rearm)
            }
            Log.i("LINK", "hb#\(tick) probed=\(check.probed) video=\(check.media) framesSent=\(stats.framesSinceLastReset) openServers=\(check.open) state=\(check.state) pulls/s=\(String(format: "%.1f", snap.pullRate))")
            if check.stall {
                let ms = snap.lastFrameAt.map { Int((now - $0) * 1000) } ?? -1
                Log.w("LINK", "[watchdog] streaming stalled (\(ms)ms, no frames) — recovering")
                forceReconnect(reason: "stall")
            }
            if check.noFirstFrame {
                let ms = unansweredSince.map { Int((now - $0) * 1000) } ?? -1
                Log.w("LINK", "[watchdog] media open but no first frame (\(ms)ms since an unanswered 114) — recovering")
                forceReconnect(reason: "no first frame")
            }
            if check.rearm {
                Log.i("LINK", "[watchdog] re-arming reconnect after error")
                rearmFromError()
            }
        }
    }

    /// Android `rearmFromError`, plus the iOS fix: retry discovery even if the dash never connected.
    private func rearmFromError() {
        let ever: Bool? = withLock {
            guard alive, connections.isEmpty else { return nil }
            reconnectAttempts = 0
            return everConnected
        }
        guard let ever else { return }
        if ever {
            onAllConnectionsClosed()
        } else {
            spawn { [self] in await self.runDiscovery() }
        }
    }
}

/// Canonical form of a peer address for the SEC-3 allowlist: brackets and an IPv6 zone
/// ("%en0") removed, an IPv4-mapped IPv6 address ("::ffff:192.168.0.1") reduced to its IPv4,
/// lower-cased. nil for a missing / empty address (such a peer is never allowed).
enum LinkPeerHost {
    static func normalize(_ raw: String?) -> String? {
        guard var h = raw?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let zone = h.firstIndex(of: "%") { h = String(h[..<zone]) }
        h = h.lowercased()
        if h.hasPrefix("::ffff:") {
            let v4 = String(h.dropFirst("::ffff:".count))
            if InterfaceAddresses.isValidIPv4(v4) { return v4 }
        }
        return h.isEmpty ? nil : h
    }
}
