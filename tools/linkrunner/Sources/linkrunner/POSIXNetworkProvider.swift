// SPDX-License-Identifier: AGPL-3.0-or-later
// POSIX (BSD sockets) implementation of the OpenCfMotoCore transport contract
// (Packages/OpenCfMotoKit/Sources/OpenCfMotoCore/Link/Transport.swift) for linkrunner. Linux (Glibc)
// and macOS (Darwin).
//
// Design
// - Every socket is non-blocking. One reactor thread (`PosixPollReactor`) sleeps in poll(2) over the
//   descriptors that have a parked operation, plus a self-pipe used to wake it. An operation always
//   tries its syscall first and parks (a CheckedContinuation) only on EAGAIN, so there is no busy
//   loop and no thread per connection.
// - Timeouts: `connect` parks with a deadline; the reactor sizes its poll timeout to the nearest
//   deadline and fails the operation with `TransportError.timeout`.
// - Cancellation: a parked operation of a cancelled Task resumes with `TransportError.cancelled`.
//   A write that already put part of a frame on the wire ignores cancellation and finishes the
//   frame, so the peer never sees a torn frame.
// - close() is idempotent and thread-safe: it marks the socket closed, shutdown(SHUT_RDWR)s it and
//   fails every parked operation with `TransportError.closed`. The descriptor itself is released
//   only when no syscall or parked operation still uses it, so a recycled fd number can never be
//   touched by a stale operation.
// - Accepted streams report the LISTENER port as `localPort` (EasyConnLink chooses the framing by it).
// - SIGPIPE: MSG_NOSIGNAL (Linux) / SO_NOSIGPIPE (Darwin); main.swift also ignores SIGPIPE.

import Foundation
import OpenCfMotoCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Platform shims (file scope, so method names such as close()/listen() never shadow them)

#if canImport(Darwin)
private let sysSockStream: Int32 = SOCK_STREAM
private let sysSendFlags: Int32 = 0
#else
private let sysSockStream: Int32 = Int32(SOCK_STREAM.rawValue)
private let sysSendFlags: Int32 = Int32(MSG_NOSIGNAL)
#endif

private let pollIn = Int16(POLLIN)
private let pollOut = Int16(POLLOUT)
private let pollFailure = Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)

private func sysClose(_ fd: Int32) { _ = close(fd) }
private func sysShutdown(_ fd: Int32) { _ = shutdown(fd, Int32(SHUT_RDWR)) }
private func sysRead(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { read(fd, p, n) }
private func sysRecv(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { recv(fd, p, n, 0) }
private func sysSend(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { send(fd, p, n, sysSendFlags) }
private func sysAccept(_ fd: Int32, _ a: UnsafeMutablePointer<sockaddr>?, _ l: UnsafeMutablePointer<socklen_t>?) -> Int32 {
    accept(fd, a, l)
}
private func sysConnect(_ fd: Int32, _ a: UnsafePointer<sockaddr>?, _ l: socklen_t) -> Int32 { connect(fd, a, l) }
private func sysBind(_ fd: Int32, _ a: UnsafePointer<sockaddr>?, _ l: socklen_t) -> Int32 { bind(fd, a, l) }
private func sysListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
private func sysSocket() -> Int32 { socket(AF_INET, sysSockStream, 0) }

/// `strerror` text plus the symbolic errno, e.g. "Connection refused (errno 111)".
func posixErrorText(_ code: Int32) -> String {
    let text = strerror(code).map { String(cString: $0) } ?? "error"
    return "\(text) (errno \(code))"
}

private func setNonBlockingCloExec(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    let fdFlags = fcntl(fd, F_GETFD, 0)
    if fdFlags >= 0 { _ = fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC) }
}

private func setIntOption(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
    var v = value
    _ = setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
}

/// Non-blocking + close-on-exec + TCP_NODELAY (like NWNetworkProvider's default) + no SIGPIPE.
private func configureStreamSocket(_ fd: Int32, noDelay: Bool) {
    setNonBlockingCloExec(fd)
    if noDelay { setIntOption(fd, Int32(IPPROTO_TCP), Int32(TCP_NODELAY), 1) }
    #if canImport(Darwin)
    setIntOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
    #endif
}

private func monotonicNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// IPv4 socket address for a dotted quad (or a host name resolved with getaddrinfo, IPv4 only).
func posixIPv4Address(host: String, port: UInt16) -> sockaddr_in? {
    var addr = sockaddr_in()
    #if canImport(Darwin)
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    if host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 { return addr }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = sysSockStream
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
    defer { freeaddrinfo(result) }
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let entry = cursor {
        if entry.pointee.ai_family == AF_INET, let sa = entry.pointee.ai_addr {
            let resolved = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
            addr.sin_addr = resolved.sin_addr
            return addr
        }
        cursor = entry.pointee.ai_next
    }
    return nil
}

/// Host and port of a socket address (IPv4 or IPv6).
private func describeAddress(_ storage: sockaddr_storage) -> (host: String?, port: UInt16) {
    var s = storage
    return withUnsafePointer(to: &s) { raw -> (String?, UInt16) in
        let family = Int32(raw.pointee.ss_family)
        if family == AF_INET {
            return raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> (String?, UInt16) in
                var a = sin.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN) + 1)
                let ok = inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil
                return (ok ? String(cString: buf) : nil, UInt16(bigEndian: sin.pointee.sin_port))
            }
        }
        if family == AF_INET6 {
            return raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 -> (String?, UInt16) in
                var a = sin6.pointee.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
                let ok = inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil
                return (ok ? String(cString: buf) : nil, UInt16(bigEndian: sin6.pointee.sin6_port))
            }
        }
        return (nil, 0)
    }
}

private func localAddress(of fd: Int32) -> (host: String?, port: UInt16) {
    var storage = sockaddr_storage()
    var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let rc = withUnsafeMutablePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return rc == 0 ? describeAddress(storage) : (nil, 0)
}

// MARK: - Reactor

/// One poll(2) thread for every socket of the process. Operations park here on EAGAIN.
final class PosixPollReactor: @unchecked Sendable {
    static let shared = PosixPollReactor()

    enum Interest { case read, write }

    /// One parked operation. Mutable fields are guarded by the reactor lock.
    private final class Parked {
        enum Phase { case initial, registered, done, cancelledEarly }
        let id: UInt64
        let socket: UInt64
        let fd: Int32
        let events: Int16
        let deadline: UInt64?
        var phase: Phase = .initial
        var continuation: CheckedContinuation<Void, Error>?
        init(id: UInt64, socket: UInt64, fd: Int32, events: Int16, deadline: UInt64?) {
            self.id = id
            self.socket = socket
            self.fd = fd
            self.events = events
            self.deadline = deadline
        }
    }

    private let lock = NSLock()
    private var parked: [UInt64: Parked] = [:]
    private var closedSockets: Set<UInt64> = []
    private var nextParkedId: UInt64 = 1
    private var nextSocketId: UInt64 = 1
    private let wakeRead: Int32
    private let wakeWrite: Int32

    private init() {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { fatalError("linkrunner: pipe() failed: \(posixErrorText(errno))") }
        wakeRead = fds[0]
        wakeWrite = fds[1]
        setNonBlockingCloExec(wakeRead)
        setNonBlockingCloExec(wakeWrite)
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "linkrunner.poll"
        thread.start()
    }

    func newSocketId() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextSocketId
        nextSocketId += 1
        return id
    }

    /// Parks until `fd` is ready for `interest`. Throws `TransportError.timeout` at `deadline`
    /// (monotonic ns), `.closed` once the socket is closed, `.cancelled` if the task is cancelled
    /// (only when `cancellable`).
    func wait(socket: UInt64, fd: Int32, interest: Interest, deadline: UInt64?, cancellable: Bool) async throws {
        let op: Parked = {
            lock.lock()
            defer { lock.unlock() }
            let id = nextParkedId
            nextParkedId += 1
            return Parked(id: id, socket: socket, fd: fd, events: interest == .read ? pollIn : pollOut, deadline: deadline)
        }()
        if cancellable {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in self.register(op, c) }
            } onCancel: {
                self.cancel(op)
            }
        } else {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in self.register(op, c) }
        }
    }

    private func register(_ op: Parked, _ c: CheckedContinuation<Void, Error>) {
        lock.lock()
        if op.phase == .cancelledEarly {
            op.phase = .done
            lock.unlock()
            c.resume(throwing: TransportError.cancelled)
            return
        }
        if closedSockets.contains(op.socket) {
            op.phase = .done
            lock.unlock()
            c.resume(throwing: TransportError.closed)
            return
        }
        op.phase = .registered
        op.continuation = c
        parked[op.id] = op
        lock.unlock()
        wake()
    }

    private func cancel(_ op: Parked) {
        lock.lock()
        switch op.phase {
        case .initial:
            op.phase = .cancelledEarly // register() will resume with .cancelled
            lock.unlock()
        case .registered:
            parked[op.id] = nil
            op.phase = .done
            let c = op.continuation
            op.continuation = nil
            lock.unlock()
            c?.resume(throwing: TransportError.cancelled)
            wake()
        case .done, .cancelledEarly:
            lock.unlock()
        }
    }

    /// The socket is closing: fail its parked operations and refuse new ones.
    func socketClosing(_ socket: UInt64) {
        lock.lock()
        closedSockets.insert(socket)
        let victims = parked.values.filter { $0.socket == socket }
        var conts: [CheckedContinuation<Void, Error>] = []
        for v in victims {
            parked[v.id] = nil
            v.phase = .done
            if let c = v.continuation { conts.append(c) }
            v.continuation = nil
        }
        lock.unlock()
        conts.forEach { $0.resume(throwing: TransportError.closed) }
        wake()
    }

    /// The descriptor was released: forget the closed mark (no operation can park on it any more).
    func socketReleased(_ socket: UInt64) {
        lock.lock()
        closedSockets.remove(socket)
        lock.unlock()
    }

    private func wake() {
        var b: UInt8 = 1
        _ = write(wakeWrite, &b, 1) // EAGAIN (pipe full) is fine: a wake-up is already pending
    }

    private func run() {
        var pfds: [pollfd] = []
        var drain = [UInt8](repeating: 0, count: 256)
        var interest: [Int32: Int16] = [:]
        while true {
            pfds.removeAll(keepingCapacity: true)
            interest.removeAll(keepingCapacity: true)
            pfds.append(pollfd(fd: wakeRead, events: pollIn, revents: 0))
            var nearest: UInt64?
            lock.lock()
            for op in parked.values {
                interest[op.fd, default: 0] |= op.events
                if let d = op.deadline { nearest = min(nearest ?? d, d) }
            }
            lock.unlock()
            for (fd, events) in interest { pfds.append(pollfd(fd: fd, events: events, revents: 0)) }
            var timeoutMs: Int32 = -1
            if let d = nearest {
                let now = monotonicNanos()
                timeoutMs = d <= now ? 0 : Int32(min((d - now + 999_999) / 1_000_000, 60_000))
            }
            let rc = poll(&pfds, nfds_t(pfds.count), timeoutMs)
            if rc < 0 {
                let e = errno
                if e != EINTR {
                    // EINVAL/ENOMEM: never expected; back off instead of spinning.
                    FileHandle.standardError.write(Data("linkrunner: poll failed: \(posixErrorText(e))\n".utf8))
                    usleep(20_000)
                }
                continue
            }
            if pfds[0].revents != 0 {
                while drain.withUnsafeMutableBytes({ sysRead(wakeRead, $0.baseAddress, $0.count) }) > 0 {}
            }
            var ready: [Int32: Int16] = [:]
            for p in pfds.dropFirst() where p.revents != 0 { ready[p.fd] = p.revents }
            let now = monotonicNanos()
            var resumes: [(CheckedContinuation<Void, Error>, Error?)] = []
            lock.lock()
            for op in Array(parked.values) {
                var outcome: Error?? = nil
                if let rev = ready[op.fd], rev & (op.events | pollFailure) != 0 {
                    outcome = .some(nil) // ready (or error/hang-up: the retried syscall reports it)
                } else if let d = op.deadline, now >= d {
                    outcome = .some(TransportError.timeout)
                }
                guard let result = outcome else { continue }
                parked[op.id] = nil
                op.phase = .done
                if let c = op.continuation { resumes.append((c, result)) }
                op.continuation = nil
            }
            lock.unlock()
            for (c, error) in resumes {
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
}

// MARK: - Socket handle

/// Owns one descriptor: in-flight accounting so close() never races a syscall on a recycled fd.
final class PosixSocket: @unchecked Sendable {
    let id: UInt64
    private let fd: Int32
    private let reactor: PosixPollReactor
    private let lock = NSLock()
    private var closed = false
    private var busy = 0
    private var released = false

    init(fd: Int32, reactor: PosixPollReactor = .shared) {
        self.fd = fd
        self.reactor = reactor
        id = reactor.newSocketId()
    }

    deinit {
        if !released { sysClose(fd) }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func enter() throws {
        lock.lock()
        defer { lock.unlock() }
        if closed { throw TransportError.closed }
        busy += 1
    }

    private func leave() {
        lock.lock()
        busy -= 1
        let release = closed && busy == 0 && !released
        if release { released = true }
        lock.unlock()
        if release { releaseDescriptor() }
    }

    private func releaseDescriptor() {
        reactor.socketReleased(id)
        sysClose(fd)
    }

    /// Runs a non-blocking syscall on the descriptor; returns its result and errno.
    func syscall<R>(_ body: (Int32) -> R) throws -> (result: R, errno: Int32) {
        try enter()
        defer { leave() }
        errno = 0
        let r = body(fd)
        return (r, errno)
    }

    /// Parks until the descriptor is ready (see `PosixPollReactor.wait`).
    func park(_ interest: PosixPollReactor.Interest, deadline: UInt64? = nil, cancellable: Bool = true) async throws {
        try enter()
        defer { leave() }
        try await reactor.wait(socket: id, fd: fd, interest: interest, deadline: deadline, cancellable: cancellable)
    }

    /// Reads SO_ERROR (pending connect result).
    func pendingError() -> Int32 {
        guard let r = try? syscall({ fd -> Int32 in
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 ? err : errno
        }) else { return EBADF }
        return r.result
    }

    func localEndpoint() -> (host: String?, port: UInt16) {
        (try? syscall({ localAddress(of: $0) }).result) ?? (nil, 0)
    }

    /// Idempotent: shutdown (EOF for readers and the peer), fail parked operations, release the fd
    /// as soon as nothing uses it.
    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let release = busy == 0
        if release { released = true }
        lock.unlock()
        sysShutdown(fd)
        reactor.socketClosing(id)
        if release { releaseDescriptor() }
    }
}

/// FIFO async mutex (writes are serialized in call order, per the ByteStream contract).
final class PosixWriteLock: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if held {
                queue.append(c)
                lock.unlock()
            } else {
                held = true
                lock.unlock()
                c.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if queue.isEmpty {
            held = false
            lock.unlock()
        } else {
            let next = queue.removeFirst() // ownership passes to the next writer
            lock.unlock()
            next.resume()
        }
    }
}

// MARK: - Stream

final class PosixByteStream: ByteStream, @unchecked Sendable {
    let remoteEndpoint: String
    let remoteHost: String?
    let localPort: UInt16
    let localHost: String?
    private let socket: PosixSocket
    private let writeLock = PosixWriteLock()
    private let onClose: (@Sendable (PosixByteStream) -> Void)?

    init(socket: PosixSocket, remoteHost: String?, remotePort: UInt16, localPort: UInt16, localHost: String?,
         onClose: (@Sendable (PosixByteStream) -> Void)? = nil) {
        self.socket = socket
        self.remoteHost = remoteHost
        remoteEndpoint = "\(remoteHost ?? "?"):\(remotePort)"
        self.localPort = localPort
        self.localHost = localHost
        self.onClose = onClose
    }

    deinit { socket.close() }

    func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            out.append(try await readSome(maxCount: count - out.count))
        }
        return out
    }

    func readSome(maxCount: Int) async throws -> Data {
        let want = Swift.min(Swift.max(1, maxCount), 256 * 1024)
        var buffer = [UInt8](repeating: 0, count: want)
        while true {
            let (n, e) = try socket.syscall { fd in
                buffer.withUnsafeMutableBytes { sysRecv(fd, $0.baseAddress, $0.count) }
            }
            if n > 0 { return Data(buffer[0 ..< n]) }
            if n == 0 { throw TransportError.closed }
            switch e {
            case EAGAIN, EWOULDBLOCK:
                try await socket.park(.read)
            case EINTR:
                continue
            default:
                if socket.isClosed { throw TransportError.closed }
                throw TransportError.failed("recv: \(posixErrorText(e))")
            }
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        await writeLock.acquire()
        defer { writeLock.release() }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let start = offset
            let (n, e) = try socket.syscall { fd in
                bytes.withUnsafeBytes { p in sysSend(fd, p.baseAddress! + start, p.count - start) }
            }
            if n > 0 {
                offset += n
                continue
            }
            switch e {
            case EAGAIN, EWOULDBLOCK, 0:
                // Once part of the frame is on the wire, finish it even if the task is cancelled.
                try await socket.park(.write, cancellable: offset == 0)
            case EINTR:
                continue
            default:
                if socket.isClosed { throw TransportError.closed }
                throw TransportError.failed("send: \(posixErrorText(e))")
            }
        }
    }

    func close() {
        let wasOpen = !socket.isClosed
        socket.close()
        if wasOpen { onClose?(self) }
    }
}

// MARK: - Listener

final class PosixStreamListener: StreamListener, @unchecked Sendable {
    let port: UInt16
    private let socket: PosixSocket
    private let noDelay: Bool
    private let onAccept: (@Sendable (PosixByteStream) -> Void)?
    private let onStreamClose: (@Sendable (PosixByteStream) -> Void)?

    init(socket: PosixSocket, port: UInt16, noDelay: Bool, onAccept: (@Sendable (PosixByteStream) -> Void)?,
         onStreamClose: (@Sendable (PosixByteStream) -> Void)?) {
        self.socket = socket
        self.port = port
        self.noDelay = noDelay
        self.onAccept = onAccept
        self.onStreamClose = onStreamClose
    }

    deinit { socket.close() }

    func accept() async throws -> any ByteStream {
        while true {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let (cfd, e) = try socket.syscall { fd in
                withUnsafeMutablePointer(to: &storage) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysAccept(fd, $0, &len) }
                }
            }
            if cfd >= 0 {
                configureStreamSocket(cfd, noDelay: noDelay)
                let peer = describeAddress(storage)
                let local = localAddress(of: cfd)
                // localPort = the LISTENER port (the engine routes framing by it).
                let stream = PosixByteStream(socket: PosixSocket(fd: cfd), remoteHost: peer.host, remotePort: peer.port,
                                             localPort: port, localHost: local.host, onClose: onStreamClose)
                onAccept?(stream)
                return stream
            }
            switch e {
            case EAGAIN, EWOULDBLOCK:
                try await socket.park(.read)
            case EINTR, ECONNABORTED, EPROTO:
                continue
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                // Out of descriptors/memory: keep the listener alive, retry shortly (no spinning).
                try await Task.sleep(nanoseconds: 100_000_000)
            default:
                if socket.isClosed { throw TransportError.closed }
                throw TransportError.failed("accept :\(port): \(posixErrorText(e))")
            }
        }
    }

    func close() { socket.close() }
}

// MARK: - Provider

/// `NetworkProvider` over BSD sockets.
final class PosixNetworkProvider: NetworkProvider, @unchecked Sendable {
    struct Options: Sendable {
        /// Listener bind address (nil = 0.0.0.0, i.e. all interfaces like Android's ServerSocket).
        var bindHost: String?
        /// TCP_NODELAY on every stream (NWNetworkProvider's default).
        var noDelay = true
        var backlog: Int32 = 16
    }

    /// Transport-level trace lines (connect/accept/close), nil = silent.
    typealias Trace = @Sendable (String) -> Void

    let options: Options
    private let trace: Trace?
    private let counters = Locked(Counters())

    struct Counters: Sendable {
        var listens = 0
        var connectAttempts = 0
        var connectsOK = 0
        var connectRefused = 0
        var connectTimeouts = 0
        var accepted = 0
        var acceptedByPort: [UInt16: Int] = [:]
    }

    init(options: Options = Options(), trace: Trace? = nil) {
        self.options = options
        self.trace = trace
    }

    var snapshot: Counters { counters.current }

    func listen(port: UInt16) async throws -> any StreamListener {
        let fd = sysSocket()
        guard fd >= 0 else { throw TransportError.failed("socket: \(posixErrorText(errno))") }
        let sock = PosixSocket(fd: fd)
        setNonBlockingCloExec(fd)
        setIntOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
        let host = options.bindHost ?? "0.0.0.0"
        guard var addr = posixIPv4Address(host: host, port: port) else {
            sock.close()
            throw TransportError.failed("bad bind address \(host)")
        }
        let (bound, bindErr) = try sock.syscall { fd in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0 else {
            sock.close()
            trace?("[net] bind \(host):\(port) failed: \(posixErrorText(bindErr))")
            throw TransportError.failed("bind \(host):\(port): \(posixErrorText(bindErr))")
        }
        let (listening, listenErr) = try sock.syscall { sysListen($0, options.backlog) }
        guard listening == 0 else {
            sock.close()
            throw TransportError.failed("listen :\(port): \(posixErrorText(listenErr))")
        }
        counters.withLock { $0.listens += 1 }
        // Port 0 (self-tests): report the port the kernel picked.
        let boundPort = port == 0 ? sock.localEndpoint().port : port
        trace?("[net] listening \(host):\(boundPort)")
        let tr = trace
        let ctr = counters
        return PosixStreamListener(
            socket: sock, port: boundPort, noDelay: options.noDelay,
            onAccept: { s in
                ctr.withLock {
                    $0.accepted += 1
                    $0.acceptedByPort[s.localPort, default: 0] += 1
                }
                tr?("[net] :\(s.localPort) accepted \(s.remoteEndpoint) (local \(s.localHost ?? "?"))")
            },
            onStreamClose: { s in tr?("[net] :\(s.localPort) closed \(s.remoteEndpoint) (local)") })
    }

    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
        counters.withLock { $0.connectAttempts += 1 }
        guard var addr = posixIPv4Address(host: host, port: port) else {
            throw TransportError.failed("cannot resolve \(host) (IPv4)")
        }
        let fd = sysSocket()
        guard fd >= 0 else { throw TransportError.failed("socket: \(posixErrorText(errno))") }
        configureStreamSocket(fd, noDelay: options.noDelay)
        let sock = PosixSocket(fd: fd)
        let deadline = monotonicNanos() + UInt64(max(0, timeout) * 1_000_000_000)
        let (rc, e) = try sock.syscall { fd in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if rc != 0 {
            guard e == EINPROGRESS || e == EINTR || e == EAGAIN else {
                sock.close()
                throw connectFailure(host, port, e)
            }
            do {
                try await sock.park(.write, deadline: deadline)
            } catch {
                sock.close()
                if case TransportError.timeout? = error as? TransportError {
                    counters.withLock { $0.connectTimeouts += 1 }
                    trace?("[net] connect \(host):\(port) timed out after \(timeout)s")
                }
                throw error
            }
            let soErr = sock.pendingError()
            if soErr != 0 {
                sock.close()
                throw connectFailure(host, port, soErr)
            }
        }
        counters.withLock { $0.connectsOK += 1 }
        let local = sock.localEndpoint()
        trace?("[net] connected \(host):\(port) from \(local.host ?? "?"):\(local.port)")
        let tr = trace
        return PosixByteStream(socket: sock, remoteHost: host, remotePort: port, localPort: local.port, localHost: local.host,
                               onClose: { s in tr?("[net] outbound \(s.remoteEndpoint) closed (local)") })
    }

    private func connectFailure(_ host: String, _ port: UInt16, _ code: Int32) -> TransportError {
        if code == ECONNREFUSED { counters.withLock { $0.connectRefused += 1 } }
        trace?("[net] connect \(host):\(port) failed: \(posixErrorText(code))")
        return TransportError.failed("connect \(host):\(port): \(posixErrorText(code))")
    }
}
