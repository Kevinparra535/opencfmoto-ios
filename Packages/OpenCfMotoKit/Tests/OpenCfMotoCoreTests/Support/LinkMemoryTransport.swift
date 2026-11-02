// SPDX-License-Identifier: AGPL-3.0-or-later
// In-memory `NetworkProvider` for link tests: TCP-like ordered byte pipes, listeners on fixed
// ports, outbound connects routed to registered fake endpoints (the dash's :10930), and `dial` for
// the fake dash to connect back to the phone's listeners. Reads support task cancellation, so the
// contract's `withTimeout` works on them; `close()` makes pending reads throw `.closed`.

import Foundation
@testable import OpenCfMotoCore

/// One direction of a connection.
final class LinkMemoryPipe: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let exact: Int?
        let max: Int
        let cont: CheckedContinuation<Data, Error>
    }

    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var writerClosed = false
    private var readerClosed = false
    private var waiter: Waiter?
    private var nextId: UInt64 = 0

    func write(_ data: Data) throws {
        lock.lock()
        if readerClosed || writerClosed {
            lock.unlock()
            throw TransportError.closed
        }
        buffer.append(contentsOf: data)
        let resume = satisfyLocked()
        lock.unlock()
        resume?()
    }

    /// Writer side closed: the reader gets the buffered bytes, then EOF.
    func closeWriter() {
        lock.lock()
        writerClosed = true
        let resume = satisfyLocked()
        lock.unlock()
        resume?()
    }

    /// Reader side closed: pending and future reads throw, writes fail.
    func closeReader() {
        lock.lock()
        readerClosed = true
        buffer.removeAll()
        let resume = satisfyLocked()
        lock.unlock()
        resume?()
    }

    var bufferedCount: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }

    private func makeId() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        return nextId
    }

    func read(exact: Int?, max: Int) async throws -> Data {
        if exact == 0 { return Data() }
        let id = makeId()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                lock.lock()
                if let result = takeLocked(exact: exact, max: max) {
                    lock.unlock()
                    cont.resume(with: result)
                    return
                }
                if waiter != nil {
                    lock.unlock()
                    cont.resume(throwing: TransportError.failed("concurrent reads on one stream"))
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                waiter = Waiter(id: id, exact: exact, max: max, cont: cont)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let w = waiter, w.id == id {
                waiter = nil
                lock.unlock()
                w.cont.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    /// Result for a read request if it can complete now (lock held).
    private func takeLocked(exact: Int?, max: Int) -> Result<Data, Error>? {
        if readerClosed { return .failure(TransportError.closed) }
        if let exact {
            if buffer.count >= exact {
                let d = Data(buffer.prefix(exact))
                buffer.removeFirst(exact)
                return .success(d)
            }
            return writerClosed ? .failure(TransportError.closed) : nil
        }
        if !buffer.isEmpty {
            let n = Swift.min(max, buffer.count)
            let d = Data(buffer.prefix(n))
            buffer.removeFirst(n)
            return .success(d)
        }
        return writerClosed ? .failure(TransportError.closed) : nil
    }

    private func satisfyLocked() -> (() -> Void)? {
        guard let w = waiter, let result = takeLocked(exact: w.exact, max: w.max) else { return nil }
        waiter = nil
        return { w.cont.resume(with: result) }
    }
}

/// One end of an in-memory TCP connection.
final class LinkMemoryStream: ByteStream, @unchecked Sendable {
    let remoteEndpoint: String
    let remoteHost: String?
    let localPort: UInt16
    private let inbound: LinkMemoryPipe
    private let outbound: LinkMemoryPipe
    private let closedFlag = Locked(false)
    /// Every byte written by this end (for assertions).
    let written = Locked(Data())

    init(remoteHost: String, remotePort: UInt16, localPort: UInt16, inbound: LinkMemoryPipe, outbound: LinkMemoryPipe) {
        self.remoteHost = remoteHost
        remoteEndpoint = "\(remoteHost):\(remotePort)"
        self.localPort = localPort
        self.inbound = inbound
        self.outbound = outbound
    }

    /// A connected pair: `a` talks to `b`.
    static func pair(aHost: String, aPort: UInt16, bHost: String, bPort: UInt16) -> (a: LinkMemoryStream, b: LinkMemoryStream) {
        let aToB = LinkMemoryPipe()
        let bToA = LinkMemoryPipe()
        let a = LinkMemoryStream(remoteHost: bHost, remotePort: bPort, localPort: aPort, inbound: bToA, outbound: aToB)
        let b = LinkMemoryStream(remoteHost: aHost, remotePort: aPort, localPort: bPort, inbound: aToB, outbound: bToA)
        return (a, b)
    }

    var isClosed: Bool { closedFlag.current }

    func read(exactly count: Int) async throws -> Data { try await inbound.read(exact: count, max: count) }

    func readSome(maxCount: Int) async throws -> Data { try await inbound.read(exact: nil, max: maxCount) }

    func write(_ data: Data) async throws {
        if isClosed { throw TransportError.closed }
        try outbound.write(data)
        written.withLock { $0.append(data) }
    }

    func close() {
        closedFlag.set(true)
        inbound.closeReader()
        outbound.closeWriter()
    }
}

final class LinkMemoryListener: StreamListener, @unchecked Sendable {
    let port: UInt16
    private let lock = NSLock()
    private var queue: [any ByteStream] = []
    private var waiter: (id: UInt64, cont: CheckedContinuation<any ByteStream, Error>)?
    private var nextId: UInt64 = 0
    private var closed = false
    private var pendingFailure: Error?

    init(port: UInt16) { self.port = port }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// The pending (else the next) accept throws `error` while the listener stays open and keeps its
    /// port: a socket iOS reclaimed while the app was suspended (POSIX-1).
    func failAccept(with error: Error) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.cont.resume(throwing: error)
            return
        }
        pendingFailure = error
        lock.unlock()
    }

    func enqueue(_ s: any ByteStream) -> Bool {
        lock.lock()
        if closed {
            lock.unlock()
            return false
        }
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.cont.resume(returning: s)
            return true
        }
        queue.append(s)
        lock.unlock()
        return true
    }

    private func makeId() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextId += 1
        return nextId
    }

    func accept() async throws -> any ByteStream {
        let id = makeId()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<any ByteStream, Error>) in
                lock.lock()
                if closed {
                    lock.unlock()
                    cont.resume(throwing: TransportError.closed)
                } else if let failure = pendingFailure {
                    pendingFailure = nil
                    lock.unlock()
                    cont.resume(throwing: failure)
                } else if !queue.isEmpty {
                    let s = queue.removeFirst()
                    lock.unlock()
                    cont.resume(returning: s)
                } else if Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                } else {
                    waiter = (id, cont)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let w = waiter, w.id == id {
                waiter = nil
                lock.unlock()
                w.cont.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let w = waiter
        waiter = nil
        let pending = queue
        queue.removeAll()
        lock.unlock()
        w?.cont.resume(throwing: TransportError.closed)
        pending.forEach { $0.close() }
    }
}

/// The in-memory network seen by the phone (`NetworkProvider`) plus the dash-side helpers.
final class LinkMemoryNetwork: NetworkProvider, @unchecked Sendable {
    typealias EndpointHandler = @Sendable (LinkMemoryStream) -> Void

    let phoneHost: String
    private let lock = NSLock()
    private var listeners: [UInt16: LinkMemoryListener] = [:]
    private var blockedPorts: Set<UInt16> = []
    private var endpoints: [String: EndpointHandler] = [:]
    private var silentEndpoints: Set<String> = []
    private var _connectLog: [String] = []
    private var _listenLog: [UInt16] = []
    private var nextEphemeral: UInt16 = 40000

    init(phoneHost: String = "192.168.0.50") {
        self.phoneHost = phoneHost
    }

    /// Every outbound connect attempt "host:port", in order.
    var connectLog: [String] { lock.lock(); defer { lock.unlock() }; return _connectLog }
    /// Every successful listen, in order.
    var listenLog: [UInt16] { lock.lock(); defer { lock.unlock() }; return _listenLog }

    /// Ports with an open (not closed) listener.
    var openListenerPorts: [UInt16] {
        lock.lock(); defer { lock.unlock() }
        return listeners.filter { !$0.value.isClosed }.map(\.key).sorted()
    }

    /// Simulates another app holding a port (listen throws).
    func blockPort(_ port: UInt16) {
        lock.lock(); blockedPorts.insert(port); lock.unlock()
    }

    /// Registers a server reachable at host:port; the handler receives the server end.
    func registerEndpoint(host: String, port: UInt16, handler: @escaping EndpointHandler) {
        lock.lock(); endpoints["\(host):\(port)"] = handler; lock.unlock()
    }

    func removeEndpoint(host: String, port: UInt16) {
        lock.lock(); endpoints["\(host):\(port)"] = nil; lock.unlock()
    }

    /// Makes connects to host:port hang until the timeout (an unanswered SYN).
    func blackhole(host: String, port: UInt16) {
        lock.lock(); silentEndpoints.insert("\(host):\(port)"); lock.unlock()
    }

    /// The open listener on `port` fails its accept with `error` but keeps holding the port (a listener
    /// reclaimed by iOS while the app was suspended). false if no open listener is on that port.
    @discardableResult
    func failAccept(port: UInt16, with error: Error) -> Bool {
        lock.lock()
        let l = listeners[port]
        lock.unlock()
        guard let l, !l.isClosed else { return false }
        l.failAccept(with: error)
        return true
    }

    /// Successful listens on `port` so far.
    func listenCount(_ port: UInt16) -> Int { listenLog.filter { $0 == port }.count }

    // MARK: NetworkProvider (phone side)

    func listen(port: UInt16) async throws -> any StreamListener {
        try listenSync(port: port)
    }

    private func listenSync(port: UInt16) throws -> any StreamListener {
        lock.lock()
        defer { lock.unlock() }
        if blockedPorts.contains(port) { throw TransportError.failed("EADDRINUSE (port \(port))") }
        if let existing = listeners[port], !existing.isClosed { throw TransportError.failed("EADDRINUSE (port \(port))") }
        let l = LinkMemoryListener(port: port)
        listeners[port] = l
        _listenLog.append(port)
        return l
    }

    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
        let key = "\(host):\(port)"
        let (handler, silent, local) = routeSync(key)
        if silent {
            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            throw TransportError.timeout
        }
        guard let handler else { throw TransportError.failed("connection refused \(key)") }
        let (phoneSide, dashSide) = LinkMemoryStream.pair(aHost: phoneHost, aPort: local, bHost: host, bPort: port)
        handler(dashSide)
        return phoneSide
    }

    // MARK: Dash side

    private func routeSync(_ key: String) -> (EndpointHandler?, Bool, UInt16) {
        lock.lock()
        defer { lock.unlock() }
        _connectLog.append(key)
        nextEphemeral &+= 1
        return (endpoints[key], silentEndpoints.contains(key), nextEphemeral)
    }

    /// The dash connects back to the phone's listener on `port`.
    func dial(port: UInt16, fromHost host: String = "192.168.0.1") throws -> LinkMemoryStream {
        lock.lock()
        let l = listeners[port]
        nextEphemeral &+= 1
        let remotePort = nextEphemeral
        lock.unlock()
        guard let l, !l.isClosed else { throw TransportError.failed("connection refused :\(port)") }
        let (phoneSide, dashSide) = LinkMemoryStream.pair(aHost: phoneHost, aPort: port, bHost: host, bPort: remotePort)
        guard l.enqueue(phoneSide) else { throw TransportError.failed("connection refused :\(port)") }
        return dashSide
    }
}
