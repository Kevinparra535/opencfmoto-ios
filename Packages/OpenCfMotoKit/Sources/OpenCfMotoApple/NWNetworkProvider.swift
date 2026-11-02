// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (listeners on 10922/10921/10920, the :10930
// probe socket, TCP_NODELAY on accepted sockets).
//
// Network.framework implementation of the transport contract (OpenCfMotoCore Link/Transport.swift).
// NOT the bike-link transport any more: on a dash AP without internet the Wi-Fi path stays
// unsatisfied (first field test, iOS 27) and these connections wait until they time out, so the app
// uses `POSIXNetworkProvider` (OpenCfMotoCore). Kept for its tests and as the reference error
// mapping; `NWByteStream` also carries the cellular HTTP client.
// - `listen(port:)`: an NWListener on a FIXED port, `allowLocalEndpointReuse` (SO_REUSEADDR), TCP
//   noDelay, optionally restricted to the Wi-Fi interface (DTS: bind listeners to the interface, not
//   to an IP). No Bonjour advertising (that would itself be a Local Network operation).
// - `connect(host:port:timeout:)`: an NWConnection with `requiredInterfaceType = .wifi` and IPv4
//   forced, so the probe leaves from the Wi-Fi IPv4 the dash calls back (session-network.md §4.5).
// - Accepted / outbound connections are wrapped in `NWByteStream` (exact-length reads, ordered
//   writes, prompt wake-up on close or task cancellation).
//
// Error mapping (the link in OpenCfMotoCore cannot see Network.framework — it classifies by text):
// | Situation                                   | Thrown                                          | Link maps to                     |
// |---------------------------------------------|-------------------------------------------------|----------------------------------|
// | listen: port held by another process        | TransportError.failed("EADDRINUSE: …")          | LinkFailure.portInUse(port)      |
// | listen: any other bind failure              | TransportError.failed("listen :<port> failed …")| LinkFailure.portInUse(port) (Android parity: every bind error) |
// | connect/accept blocked by Local Network     | TransportError.failed("localNetworkDenied")     | LinkFailure.localNetworkDenied   |
// | connect: no answer within `timeout`         | TransportError.timeout                          | probe attempt failed             |
// | connect: refused / host unreachable         | TransportError.failed("ECONNREFUSED: …") etc.   | probe attempt failed             |
// | peer EOF / local close()                    | TransportError.closed                           | connection closed                |
// | awaiting task cancelled                     | TransportError.cancelled                        | —                                |
// `PlatformTransportErrors` (OpenCfMotoCore, shared with the POSIX provider) exposes the strings
// and classifiers.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// A thread-safe "first caller wins" flag (resume-exactly-once guards in callback code).
final class OCMOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    init() {}

    /// Returns true for the first caller only.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    var isClaimed: Bool { lock.lock(); defer { lock.unlock() }; return done }
}
#endif

#if canImport(Network)
import Network

// MARK: - Shared helpers (internal to OpenCfMotoApple)

/// Abstract readiness events fed into an `OCMReadyGate` (from NWConnection or NWListener states).
enum OCMNWEvent {
    case ready
    case waiting(NWError, NWPath.UnsatisfiedReason?)
    case failed(NWError, NWPath.UnsatisfiedReason?)
    case cancelled
}

/// Result of waiting for a connection / listener to become ready.
enum OCMReadyOutcome {
    case ready
    /// `.waiting` and the gate's policy decided to stop waiting.
    case waiting(NWError, NWPath.UnsatisfiedReason?)
    case failed(NWError, NWPath.UnsatisfiedReason?)
    case cancelled
    /// The deadline passed; carries the last `.waiting` error/reason seen, if any.
    case timedOut(NWError?, NWPath.UnsatisfiedReason?)
}

/// Resolves exactly once with the first decisive readiness event, the deadline, or task cancellation.
final class OCMReadyGate: @unchecked Sendable {
    typealias WaitingPolicy = (NWError, NWPath.UnsatisfiedReason?) -> Bool

    private let lock = NSLock()
    private var outcome: OCMReadyOutcome?
    private var waiters: [CheckedContinuation<OCMReadyOutcome, Never>] = []
    private var lastWaitingError: NWError?
    private var lastWaitingReason: NWPath.UnsatisfiedReason?
    /// Returns true when a `.waiting` state should end the wait immediately.
    private let stopOnWaiting: WaitingPolicy

    init(stopOnWaiting: @escaping WaitingPolicy = { _, _ in false }) {
        self.stopOnWaiting = stopOnWaiting
    }

    var isResolved: Bool { lock.lock(); defer { lock.unlock() }; return outcome != nil }

    func observe(_ event: OCMNWEvent) {
        switch event {
        case .ready:
            resolve(.ready)
        case let .waiting(error, reason):
            lock.lock()
            lastWaitingError = error
            lastWaitingReason = reason
            lock.unlock()
            if stopOnWaiting(error, reason) { resolve(.waiting(error, reason)) }
        case let .failed(error, reason):
            resolve(.failed(error, reason))
        case .cancelled:
            resolve(.cancelled)
        }
    }

    func resolve(_ o: OCMReadyOutcome) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = o
        let ws = waiters
        waiters.removeAll()
        lock.unlock()
        for w in ws { w.resume(returning: o) }
    }

    private func resolveTimeout() {
        lock.lock()
        let e = lastWaitingError
        let r = lastWaitingReason
        lock.unlock()
        resolve(.timedOut(e, r))
    }

    /// Waits for the outcome (≤ `timeout` seconds; the timer runs on `queue`).
    func wait(timeout: TimeInterval, queue: DispatchQueue) async -> OCMReadyOutcome {
        queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in self?.resolveTimeout() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<OCMReadyOutcome, Never>) in
                lock.lock()
                if let o = outcome {
                    lock.unlock()
                    cont.resume(returning: o)
                    return
                }
                if Task.isCancelled {
                    // Same as onCancel: the caller abandons this connection.
                    lock.unlock()
                    resolve(.cancelled)
                    cont.resume(returning: .cancelled)
                    return
                }
                waiters.append(cont)
                lock.unlock()
            }
        } onCancel: { [weak self] in
            self?.resolve(.cancelled)
        }
    }
}

enum OCMNWSupport {
    /// The unsatisfied reason of a path, only when the path is actually unsatisfied.
    static func unsatisfiedReason(_ path: NWPath?) -> NWPath.UnsatisfiedReason? {
        guard let path, path.status != .satisfied else { return nil }
        return path.unsatisfiedReason
    }

    static func event(for state: NWConnection.State, path: NWPath?) -> OCMNWEvent? {
        switch state {
        case .ready: return .ready
        case let .waiting(e): return .waiting(e, unsatisfiedReason(path))
        case let .failed(e): return .failed(e, unsatisfiedReason(path))
        case .cancelled: return .cancelled
        default: return nil
        }
    }

    static func posixCode(_ error: NWError?) -> POSIXErrorCode? {
        guard let error, case let .posix(code) = error else { return nil }
        return code
    }

    /// Definitive "nobody is listening there" answers worth failing fast on.
    static func isRefusedOrUnreachable(_ error: NWError) -> Bool {
        guard let c = posixCode(error) else { return false }
        return c == .ECONNREFUSED || c == .EHOSTUNREACH || c == .EHOSTDOWN
    }

    static func isAddressInUse(_ error: NWError?) -> Bool { posixCode(error) == .EADDRINUSE }

    /// TransportError for an NWError on an established (or establishing) connection.
    static func transportError(_ error: NWError, reason: NWPath.UnsatisfiedReason? = nil) -> TransportError {
        if reason == .localNetworkDenied { return PlatformTransportErrors.localNetworkDeniedError }
        if let c = posixCode(error) {
            switch c {
            case .ECANCELED: return .closed
            case .ETIMEDOUT: return .timeout
            case .ECONNRESET, .EPIPE, .ENOTCONN, .ESHUTDOWN, .ECONNABORTED: return .closed
            case .ECONNREFUSED: return .failed("\(PlatformTransportErrors.connectionRefusedPrefix): connection refused")
            case .EADDRINUSE: return .failed("\(PlatformTransportErrors.addressInUsePrefix): address already in use")
            default: return .failed("\(c)")
            }
        }
        return .failed("\(error)")
    }

    /// TransportError for a failed readiness wait.
    static func transportError(for outcome: OCMReadyOutcome) -> TransportError {
        switch outcome {
        case .ready:
            return .failed("unexpected ready")
        case let .waiting(e, r), let .failed(e, r):
            return transportError(e, reason: r)
        case .cancelled:
            return .cancelled
        case let .timedOut(_, r):
            return r == .localNetworkDenied ? PlatformTransportErrors.localNetworkDeniedError : .timeout
        }
    }

    /// "192.168.0.1" for IPv4 (and IPv4-mapped IPv6), the textual form otherwise.
    static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(a):
            return WiFiIPv4(bytes: [UInt8](a.rawValue))?.description ?? "\(a)"
        case let .ipv6(a):
            let b = [UInt8](a.rawValue)
            if b.count == 16, b[0 ..< 10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF,
               let v4 = WiFiIPv4(bytes: Array(b[12 ..< 16])) {
                return v4.description
            }
            return "\(a)"
        case let .name(n, _):
            return n
        default:
            return "\(host)"
        }
    }

    static func hostPort(_ endpoint: NWEndpoint?) -> (host: String, port: UInt16)? {
        guard let endpoint, case let .hostPort(host, port) = endpoint else { return nil }
        return (hostString(host), port.rawValue)
    }

    /// TCP parameters for the dash link.
    static func tcpParameters(interface: NWInterface.InterfaceType?, noDelay: Bool, connectionTimeout: TimeInterval?,
                              forceIPv4: Bool, allowLocalEndpointReuse: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = noDelay
        if let t = connectionTimeout { tcp.connectionTimeout = max(1, Int(t.rounded(.up))) }
        let params = NWParameters(tls: nil, tcp: tcp)
        if let interface { params.requiredInterfaceType = interface }
        params.allowLocalEndpointReuse = allowLocalEndpointReuse
        if forceIPv4, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return params
    }
}

// MARK: - NWByteStream

/// `ByteStream` over an `NWConnection`.
///
/// - Reads go through an internal buffer fed by `receive(minimumIncompleteLength:maximumLength:)`
///   calls issued only while a reader is waiting (back-pressure). `read(exactly:)` loops over
///   partial deliveries until exactly `count` bytes are available.
/// - A reader whose task is cancelled is woken with `TransportError.cancelled`; bytes that arrive
///   later stay buffered for the next read (no desynchronisation).
/// - Writes are issued to Network.framework in call order (one `send` per `write`, so frames never
///   interleave) and complete on `.contentProcessed`.
/// - `close()` cancels the connection and wakes every pending read/write exactly once with
///   `TransportError.closed`.
///
/// Thread-safety: `final class` guarded by NSLocks (`lock` for state, `sendLock` for send order).
public final class NWByteStream: ByteStream, @unchecked Sendable {
    /// The underlying connection (advanced use / diagnostics only).
    public let connection: NWConnection

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let sendLock = NSLock()
    private let gate: OCMReadyGate

    private struct Reader {
        let id: UInt64
        let exact: Bool
        let count: Int
        let cont: CheckedContinuation<Data, Error>
    }

    // State (guarded by `lock`).
    private var buffer: [UInt8] = []
    private var head = 0
    private var readers: [Reader] = []
    private var writers: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var receiving = false
    private var eof = false
    private var terminal: TransportError?
    private var closedLocally = false
    private var started = false
    private var nextID: UInt64 = 1
    private var _localPort: UInt16
    private var _localHost: String?
    private var _remoteHost: String?
    private var _remotePort: UInt16?

    /// Chunk size of each receive (read-ahead is bounded by this while a reader waits).
    private static let receiveChunk = 64 * 1024

    /// - Parameters:
    ///   - localPort: the listener's port for accepted connections (0 = learn it when ready).
    ///   - stopOnWaiting: readiness policy used by `waitUntilReady` (outbound connections).
    init(connection: NWConnection, queue: DispatchQueue, localPort: UInt16 = 0,
         stopOnWaiting: @escaping OCMReadyGate.WaitingPolicy = { _, _ in false }) {
        self.connection = connection
        self.queue = queue
        self._localPort = localPort
        self.gate = OCMReadyGate(stopOnWaiting: stopOnWaiting)
        if let hp = OCMNWSupport.hostPort(connection.endpoint) {
            _remoteHost = hp.host
            _remotePort = hp.port
        }
        connection.stateUpdateHandler = { [weak self] state in self?.handleState(state) }
    }

    deinit {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: ByteStream

    public var remoteEndpoint: String {
        lock.lock(); defer { lock.unlock() }
        let h = _remoteHost ?? "?"
        return _remotePort.map { "\(h):\($0)" } ?? h
    }

    public var remoteHost: String? { lock.lock(); defer { lock.unlock() }; return _remoteHost }

    public var localPort: UInt16 { lock.lock(); defer { lock.unlock() }; return _localPort }

    /// Local IPv4/IPv6 of this connection once ready (for the probe: the phone's Wi-Fi address the
    /// dash will call back). Not part of the `ByteStream` contract.
    public var localHost: String? { lock.lock(); defer { lock.unlock() }; return _localHost }

    /// True once `close()` was called or the connection failed / was cancelled.
    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return terminal != nil }

    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await enqueueRead(exact: true, count: count)
    }

    public func readSome(maxCount: Int) async throws -> Data {
        try await enqueueRead(exact: false, count: max(1, maxCount))
    }

    public func write(_ data: Data) async throws {
        let id = allocateID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // `sendLock` keeps Network.framework's send order identical to the call order even
                // when several tasks write concurrently (heartbeat timer + replies).
                sendLock.lock()
                lock.lock()
                if let t = terminal {
                    lock.unlock()
                    sendLock.unlock()
                    cont.resume(throwing: t)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    sendLock.unlock()
                    cont.resume(throwing: TransportError.cancelled)
                    return
                }
                if data.isEmpty {
                    lock.unlock()
                    sendLock.unlock()
                    cont.resume()
                    return
                }
                writers[id] = cont
                lock.unlock()
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    self?.didSend(id: id, error: error)
                })
                sendLock.unlock()
            }
        } onCancel: { [weak self] in
            self?.cancelWriter(id)
        }
    }

    public func close() {
        lock.lock()
        if closedLocally {
            lock.unlock()
            return
        }
        closedLocally = true
        if terminal == nil { terminal = .closed }
        let rs = readers
        readers.removeAll()
        let ws = Array(writers.values)
        writers.removeAll()
        lock.unlock()
        connection.cancel()
        gate.resolve(.cancelled)
        for r in rs { r.cont.resume(throwing: TransportError.closed) }
        for w in ws { w.resume(throwing: TransportError.closed) }
    }

    // MARK: Lifecycle (internal)

    /// Starts the connection on its queue (idempotent).
    func start() {
        lock.lock()
        let already = started
        started = true
        lock.unlock()
        if !already { connection.start(queue: queue) }
    }

    /// Waits until the connection is ready, a decisive failure, `timeout`, or task cancellation.
    func waitUntilReady(timeout: TimeInterval) async -> OCMReadyOutcome {
        start()
        return await gate.wait(timeout: timeout, queue: queue)
    }

    // MARK: Private

    private func allocateID() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let v = nextID
        nextID &+= 1
        return v
    }

    private func handleState(_ state: NWConnection.State) {
        let path = connection.currentPath
        if let ev = OCMNWSupport.event(for: state, path: path) { gate.observe(ev) }
        switch state {
        case .ready:
            lock.lock()
            if let local = OCMNWSupport.hostPort(path?.localEndpoint) {
                _localHost = local.host
                if _localPort == 0 { _localPort = local.port }
            }
            if let remote = OCMNWSupport.hostPort(path?.remoteEndpoint) {
                _remoteHost = remote.host
                _remotePort = remote.port
            }
            lock.unlock()
        case let .failed(error):
            fail(with: OCMNWSupport.transportError(error, reason: OCMNWSupport.unsatisfiedReason(path)))
        case .cancelled:
            fail(with: .closed)
        default:
            break
        }
    }

    private func fail(with error: TransportError) {
        lock.lock()
        if terminal == nil { terminal = error }
        let t = terminal ?? error
        let rs = readers
        readers.removeAll()
        let ws = Array(writers.values)
        writers.removeAll()
        lock.unlock()
        for r in rs { r.cont.resume(throwing: t) }
        for w in ws { w.resume(throwing: t) }
    }

    private func enqueueRead(exact: Bool, count: Int) async throws -> Data {
        let id = allocateID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                var immediate: Result<Data, Error>?
                var issue: (min: Int, max: Int)?
                lock.lock()
                if let t = terminal {
                    immediate = .failure(t)
                } else if readers.isEmpty, let d = takeLocked(exact: exact, count: count) {
                    immediate = .success(d)
                } else if eof {
                    immediate = .failure(TransportError.closed)
                } else if Task.isCancelled {
                    immediate = .failure(TransportError.cancelled)
                } else {
                    readers.append(Reader(id: id, exact: exact, count: count, cont: cont))
                    issue = nextReceiveLocked()
                }
                lock.unlock()
                if let r = immediate {
                    cont.resume(with: r)
                    return
                }
                if let i = issue { receive(min: i.min, max: i.max) }
            }
        } onCancel: { [weak self] in
            self?.cancelReader(id)
        }
    }

    /// Takes bytes from the buffer for one reader (caller holds `lock`).
    private func takeLocked(exact: Bool, count: Int) -> Data? {
        let available = buffer.count - head
        let n: Int
        if exact {
            guard available >= count else { return nil }
            n = count
        } else {
            guard available > 0 else { return nil }
            n = min(count, available)
        }
        let d = Data(buffer[head ..< head + n])
        head += n
        if head == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 65536, head * 2 > buffer.count {
            buffer.removeFirst(head)
            head = 0
        }
        return d
    }

    /// Decides whether a receive must be issued now (caller holds `lock`).
    private func nextReceiveLocked() -> (min: Int, max: Int)? {
        guard !receiving, terminal == nil, !eof, let first = readers.first else { return nil }
        let available = buffer.count - head
        let need = first.exact ? max(1, first.count - available) : 1
        receiving = true
        return (need, max(need, Self.receiveChunk))
    }

    private func receive(min: Int, max: Int) {
        connection.receive(minimumIncompleteLength: min, maximumLength: max) { [weak self] data, _, isComplete, error in
            self?.didReceive(data: data, isComplete: isComplete, error: error)
        }
    }

    private func didReceive(data: Data?, isComplete: Bool, error: NWError?) {
        var completions: [(CheckedContinuation<Data, Error>, Result<Data, Error>)] = []
        lock.lock()
        receiving = false
        if let data, !data.isEmpty { buffer.append(contentsOf: data) }
        if isComplete { eof = true }
        if let error, terminal == nil {
            terminal = OCMNWSupport.transportError(error, reason: OCMNWSupport.unsatisfiedReason(connection.currentPath))
        }
        while let r = readers.first {
            if let d = takeLocked(exact: r.exact, count: r.count) {
                readers.removeFirst()
                completions.append((r.cont, .success(d)))
            } else if let t = terminal {
                readers.removeFirst()
                completions.append((r.cont, .failure(t)))
            } else if eof {
                readers.removeFirst()
                completions.append((r.cont, .failure(TransportError.closed)))
            } else {
                break
            }
        }
        let issue = nextReceiveLocked()
        lock.unlock()
        for (c, r) in completions { c.resume(with: r) }
        if let i = issue { receive(min: i.min, max: i.max) }
    }

    private func cancelReader(_ id: UInt64) {
        lock.lock()
        guard let idx = readers.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let r = readers.remove(at: idx)
        lock.unlock()
        r.cont.resume(throwing: TransportError.cancelled)
    }

    private func didSend(id: UInt64, error: NWError?) {
        lock.lock()
        let c = writers.removeValue(forKey: id)
        let t = terminal
        lock.unlock()
        guard let c else { return }
        if let error {
            c.resume(throwing: t ?? OCMNWSupport.transportError(error))
        } else {
            c.resume()
        }
    }

    private func cancelWriter(_ id: UInt64) {
        lock.lock()
        let c = writers.removeValue(forKey: id)
        lock.unlock()
        // The bytes may still go out (Network.framework cannot unsend); only the waiter is released.
        c?.resume(throwing: TransportError.cancelled)
    }
}

// MARK: - NWStreamListener

/// `StreamListener` over an `NWListener` on a fixed port. Accepted connections are started
/// immediately (TCP_NODELAY inherited from the listener parameters) and queued until `accept()`.
///
/// Thread-safety: `final class` guarded by an NSLock.
public final class NWStreamListener: StreamListener, @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let gate: OCMReadyGate
    private var _port: UInt16
    private var pending: [NWByteStream] = []
    private var waiters: [(id: UInt64, cont: CheckedContinuation<any ByteStream, Error>)] = []
    private var terminal: TransportError?
    private var nextID: UInt64 = 1
    private var acceptedCount = 0
    /// Unaccepted connections beyond this are closed (oldest first).
    private let maxPending = 16

    init(listener: NWListener, port: UInt16, queue: DispatchQueue) {
        self.listener = listener
        self.queue = queue
        self._port = port
        // A listener that waits because the port is in use will not recover by itself.
        self.gate = OCMReadyGate(stopOnWaiting: { error, _ in OCMNWSupport.isAddressInUse(error) })
        listener.stateUpdateHandler = { [weak self] state in self?.handleState(state) }
        listener.newConnectionHandler = { [weak self] conn in self?.didAccept(conn) }
    }

    deinit {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    /// The listening port (the system-assigned one when created with port 0).
    public var port: UInt16 { lock.lock(); defer { lock.unlock() }; return _port }

    /// Number of connections accepted so far (diagnostics).
    public var acceptedConnections: Int { lock.lock(); defer { lock.unlock() }; return acceptedCount }

    public func accept() async throws -> any ByteStream {
        let id = allocateWaiterID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<any ByteStream, Error>) in
                lock.lock()
                if !pending.isEmpty {
                    let s = pending.removeFirst()
                    lock.unlock()
                    cont.resume(returning: s)
                    return
                }
                if let t = terminal {
                    lock.unlock()
                    cont.resume(throwing: t)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: TransportError.cancelled)
                    return
                }
                waiters.append((id, cont))
                lock.unlock()
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(id)
        }
    }

    public func close() {
        lock.lock()
        if terminal == nil { terminal = .closed }
        let ws = waiters
        waiters.removeAll()
        let ps = pending
        pending.removeAll()
        lock.unlock()
        listener.cancel()
        gate.resolve(.cancelled)
        for w in ws { w.cont.resume(throwing: TransportError.closed) }
        for p in ps { p.close() }
    }

    // MARK: Internal

    func startAndWaitReady(timeout: TimeInterval) async -> OCMReadyOutcome {
        listener.start(queue: queue)
        return await gate.wait(timeout: timeout, queue: queue)
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            lock.lock()
            if let p = listener.port?.rawValue, p != 0 { _port = p }
            lock.unlock()
            gate.observe(.ready)
        case let .waiting(error):
            gate.observe(.waiting(error, nil))
        case let .failed(error):
            gate.observe(.failed(error, nil))
            let t: TransportError = OCMNWSupport.isAddressInUse(error)
                ? PlatformTransportErrors.addressInUse(port: port)
                : .failed("listener :\(port) failed: \(error)")
            failAll(t)
        case .cancelled:
            gate.observe(.cancelled)
            failAll(.closed)
        default:
            break
        }
    }

    private func failAll(_ error: TransportError) {
        lock.lock()
        if terminal == nil { terminal = error }
        let t = terminal ?? error
        let ws = waiters
        waiters.removeAll()
        lock.unlock()
        for w in ws { w.cont.resume(throwing: t) }
    }

    private func didAccept(_ conn: NWConnection) {
        let p = port
        let stream = NWByteStream(connection: conn, queue: DispatchQueue(label: "ocm.nw.accepted.\(p)"), localPort: p)
        stream.start()
        var deliverTo: CheckedContinuation<any ByteStream, Error>?
        var dropped: NWByteStream?
        var rejected = false
        lock.lock()
        if terminal != nil {
            rejected = true
        } else if !waiters.isEmpty {
            deliverTo = waiters.removeFirst().cont
            acceptedCount += 1
        } else {
            pending.append(stream)
            acceptedCount += 1
            if pending.count > maxPending { dropped = pending.removeFirst() }
        }
        lock.unlock()
        if rejected {
            stream.close()
            return
        }
        Log.d("NET", "[:\(p)] accepted \(stream.remoteEndpoint)")
        deliverTo?.resume(returning: stream)
        if let dropped {
            Log.w("NET", "[:\(p)] too many unaccepted connections — dropping \(dropped.remoteEndpoint)")
            dropped.close()
        }
    }

    private func allocateWaiterID() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let v = nextID
        nextID &+= 1
        return v
    }

    private func cancelWaiter(_ id: UInt64) {
        lock.lock()
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let w = waiters.remove(at: idx)
        lock.unlock()
        w.cont.resume(throwing: TransportError.cancelled)
    }
}

// MARK: - NWNetworkProvider

/// Production `NetworkProvider` (Network.framework). See the file header for the error mapping.
///
/// Use `NWNetworkProvider()` (Wi-Fi only) for the bike link; `NWNetworkProvider(options: .anyInterface)`
/// for loopback tests or the iPhone-hotspot bridge.
public final class NWNetworkProvider: NetworkProvider, @unchecked Sendable {
    public struct Options: @unchecked Sendable { // value type; NWInterface.InterfaceType is a plain enum
        /// Interface the listeners and outbound connections are pinned to (`nil` = any).
        public var requiredInterfaceType: NWInterface.InterfaceType?
        /// SO_REUSEADDR on the listeners (rebind quickly after a restart).
        public var allowLocalEndpointReuse: Bool
        /// TCP_NODELAY on listeners (inherited by accepted connections) and outbound connections.
        public var noDelay: Bool
        /// Force IPv4 on outbound connections (the probe's source must be the Wi-Fi IPv4).
        public var forceIPv4ForConnect: Bool
        /// How long `listen(port:)` waits for the listener to become ready.
        public var listenReadyTimeout: TimeInterval

        public init(requiredInterfaceType: NWInterface.InterfaceType? = .wifi, allowLocalEndpointReuse: Bool = true,
                    noDelay: Bool = true, forceIPv4ForConnect: Bool = true, listenReadyTimeout: TimeInterval = 5) {
            self.requiredInterfaceType = requiredInterfaceType
            self.allowLocalEndpointReuse = allowLocalEndpointReuse
            self.noDelay = noDelay
            self.forceIPv4ForConnect = forceIPv4ForConnect
            self.listenReadyTimeout = listenReadyTimeout
        }

        /// Bike link defaults: Wi-Fi only, reuse, noDelay, IPv4 probe.
        public static var bikeWiFi: Options { Options() }
        /// No interface restriction (loopback tests, hotspot bridge experiments).
        public static var anyInterface: Options { Options(requiredInterfaceType: nil) }
    }

    public let options: Options

    public init(options: Options = .bikeWiFi) {
        self.options = options
    }

    /// Starts listening on `port` (0 = system-assigned, read `listener.port`). Throws
    /// `PlatformTransportErrors.addressInUse(port:)` when another process holds the port.
    public func listen(port: UInt16) async throws -> any StreamListener {
        try await openListener(port: port)
    }

    /// Typed variant of `listen(port:)`.
    public func openListener(port: UInt16) async throws -> NWStreamListener {
        let params = OCMNWSupport.tcpParameters(interface: options.requiredInterfaceType, noDelay: options.noDelay,
                                                connectionTimeout: nil, forceIPv4: false,
                                                allowLocalEndpointReuse: options.allowLocalEndpointReuse)
        let nwListener: NWListener
        do {
            if port == 0 {
                nwListener = try NWListener(using: params)
            } else {
                guard let p = NWEndpoint.Port(rawValue: port) else { throw TransportError.failed("invalid port \(port)") }
                nwListener = try NWListener(using: params, on: p)
            }
        } catch let e as NWError {
            Log.w("NET", "listen :\(port) failed: \(e)")
            throw OCMNWSupport.isAddressInUse(e) ? PlatformTransportErrors.addressInUse(port: port)
                : TransportError.failed("listen :\(port) failed: \(e)")
        }
        let listener = NWStreamListener(listener: nwListener, port: port, queue: DispatchQueue(label: "ocm.nw.listen.\(port)"))
        let outcome = await listener.startAndWaitReady(timeout: options.listenReadyTimeout)
        switch outcome {
        case .ready:
            Log.d("NET", "listening on :\(listener.port)")
            return listener
        case let .failed(e, _), let .waiting(e, _):
            listener.close()
            Log.w("NET", "listen :\(port) failed: \(e)")
            throw OCMNWSupport.isAddressInUse(e) ? PlatformTransportErrors.addressInUse(port: port)
                : TransportError.failed("listen :\(port) failed: \(e)")
        case let .timedOut(e, _):
            listener.close()
            Log.w("NET", "listen :\(port) not ready after \(options.listenReadyTimeout)s: \(e.map { "\($0)" } ?? "no state")")
            if OCMNWSupport.isAddressInUse(e) { throw PlatformTransportErrors.addressInUse(port: port) }
            throw TransportError.failed("listen :\(port) not ready: \(e.map { "\($0)" } ?? "timeout")")
        case .cancelled:
            listener.close()
            throw TransportError.cancelled
        }
    }

    public func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
        try await openStream(host: host, port: port, timeout: timeout)
    }

    /// Typed variant of `connect`: the returned stream exposes `localHost` (the phone's Wi-Fi IPv4
    /// the dash will call back after an accepted probe).
    ///
    /// While Local Network access is undetermined iOS may deny the first attempt immediately and
    /// retry once the user allows it; the connection therefore keeps waiting until `timeout` and
    /// only then throws `TransportError.failed("localNetworkDenied")`. A refused / unreachable port
    /// fails fast (port scan).
    public func openStream(host: String, port: UInt16, timeout: TimeInterval) async throws -> NWByteStream {
        guard port != 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.failed("invalid port \(port)")
        }
        let params = OCMNWSupport.tcpParameters(interface: options.requiredInterfaceType, noDelay: options.noDelay,
                                                connectionTimeout: timeout, forceIPv4: options.forceIPv4ForConnect,
                                                allowLocalEndpointReuse: false)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let stream = NWByteStream(connection: conn, queue: DispatchQueue(label: "ocm.nw.connect.\(port)"),
                                  stopOnWaiting: { error, reason in
                                      if reason == .localNetworkDenied { return false }
                                      return OCMNWSupport.isRefusedOrUnreachable(error)
                                  })
        let outcome = await stream.waitUntilReady(timeout: timeout)
        if case .ready = outcome { return stream }
        stream.close()
        let error = OCMNWSupport.transportError(for: outcome)
        Log.d("NET", "connect \(host):\(port) failed: \(error)")
        throw error
    }
}
#endif
