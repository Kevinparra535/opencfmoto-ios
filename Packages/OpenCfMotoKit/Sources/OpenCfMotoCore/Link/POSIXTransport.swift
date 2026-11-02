// SPDX-License-Identifier: AGPL-3.0-or-later
// BSD-sockets implementation of the transport contract (Link/Transport.swift): the bike link's
// transport in the iOS app, and the transport of tools/linkrunner and of the loopback tests (Linux,
// macOS). First written and self-tested in tools/linkrunner.
//
// Why not Network.framework: on a dash access point without internet the Wi-Fi NWPath stays
// unsatisfied (`notAvailable`, first field test, iOS 27) and every NWConnection pinned to Wi-Fi waits
// until it times out, although the kernel has the connected route of the Wi-Fi subnet. A BSD socket
// uses that route.
//
// - Outbound: pinned with IP_BOUND_IF (Apple platforms) to the interface whose IPv4 subnet contains
//   the destination (`InterfaceAddresses.outboundInterface`), so the probe leaves from the address the
//   dash calls back (session-network.md §4.5). Loopback destinations, our own addresses and
//   destinations outside every local subnet connect unbound. Linux has no unprivileged equivalent
//   (SO_BINDTODEVICE needs CAP_NET_RAW): the choice is only logged there.
// - Listeners: 0.0.0.0:<port> with SO_REUSEADDR (NWNetworkProvider's allowLocalEndpointReuse).
// - Every stream: non-blocking, close-on-exec, TCP_NODELAY, SO_NOSIGPIPE (Darwin) / MSG_NOSIGNAL.
// - One reactor thread sleeps in poll(2) over the descriptors with a parked operation (plus a wake
//   pipe). An operation tries its syscall first and parks only on EAGAIN: no busy loop, no thread per
//   connection. `connect` parks with a deadline. A parked operation of a cancelled task resumes with
//   `.cancelled`, except a write that already sent part of its frame (it finishes the frame).
// - close() is idempotent: shutdown(SHUT_RDWR), fail every parked operation with `.closed`; the
//   descriptor is released only once no syscall or parked operation uses it (no recycled-fd races).
// - Accepted streams report the LISTENER port as `localPort` (the link picks the framing by it).
//
// Error mapping (NWNetworkProvider's table; strings in `PlatformTransportErrors`):
// | Situation                                   | Thrown                                     | Link maps to                   |
// |---------------------------------------------|--------------------------------------------|--------------------------------|
// | listen: port held by another process        | .failed("EADDRINUSE: …")                   | LinkFailure.portInUse(port)    |
// | listen: any other failure                   | .failed("listen :<port> failed: …")        | LinkFailure.portInUse(port)    |
// | connect: Local Network privacy denial (*)   | .failed("localNetworkDenied")              | LinkFailure.localNetworkDenied |
// | connect: no answer within `timeout`         | .timeout                                   | probe attempt failed           |
// | connect: refused                            | .failed("ECONNREFUSED: …")                 | probe attempt failed           |
// | connect: any other errno                    | .failed("<ERRNO>: …") e.g. EHOSTUNREACH    | probe attempt failed           |
// | read/write: ECONNRESET, EPIPE, ENOTCONN, …  | .closed (ETIMEDOUT → .timeout)             | connection closed              |
// | peer EOF / local close()                    | .closed                                    | connection closed              |
// | awaiting task cancelled                     | .cancelled                                 | —                              |
// (*) BSD sockets have no errno of their own for it. XNU drops the SYN of a socket that an NECP
// policy (Local Network privacy) denies while still inside connect(2) and returns EHOSTUNREACH
// synchronously (bsd/netinet/tcp_output.c); Apple DTS saw EHOSTUNREACH for such BSD-sockets
// connects (developer.apple.com/forums/thread/778457, /765285), while an absent neighbour fails
// later, through SO_ERROR. So only a synchronous EHOSTUNREACH towards a local subnet on an Apple
// platform counts. It is retried until the deadline (TN3179: the system "may deny the operation
// immediately, before the user has responded to the alert") and then thrown as localNetworkDenied.

import Foundation
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
private func sysWrite(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { write(fd, p, n) }
private func sysRecv(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int { recv(fd, p, n, 0) }
private func sysSend(_ fd: Int32, _ p: UnsafeRawPointer?, _ n: Int) -> Int { send(fd, p, n, sysSendFlags) }
private func sysAccept(_ fd: Int32, _ a: UnsafeMutablePointer<sockaddr>?, _ l: UnsafeMutablePointer<socklen_t>?) -> Int32 {
    accept(fd, a, l)
}
private func sysConnect(_ fd: Int32, _ a: UnsafePointer<sockaddr>?, _ l: socklen_t) -> Int32 { connect(fd, a, l) }
private func sysBind(_ fd: Int32, _ a: UnsafePointer<sockaddr>?, _ l: socklen_t) -> Int32 { bind(fd, a, l) }
private func sysListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
private func sysSocket() -> Int32 { socket(AF_INET, sysSockStream, 0) }

/// errno names and texts for logs and error messages.
public enum POSIXErrno {
    /// Symbolic name ("ECONNREFUSED"); "errno <n>" for values not listed.
    public static func name(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED: return "ECONNREFUSED"
        case ETIMEDOUT: return "ETIMEDOUT"
        case EHOSTUNREACH: return "EHOSTUNREACH"
        case ENETUNREACH: return "ENETUNREACH"
        case EHOSTDOWN: return "EHOSTDOWN"
        case ENETDOWN: return "ENETDOWN"
        case EADDRINUSE: return "EADDRINUSE"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
        case ECONNRESET: return "ECONNRESET"
        case ECONNABORTED: return "ECONNABORTED"
        case ENETRESET: return "ENETRESET"
        case EPIPE: return "EPIPE"
        case ENOTCONN: return "ENOTCONN"
        case ESHUTDOWN: return "ESHUTDOWN"
        case EINPROGRESS: return "EINPROGRESS"
        case EALREADY: return "EALREADY"
        case EAGAIN: return "EAGAIN"
        case EINTR: return "EINTR"
        case EPERM: return "EPERM"
        case EACCES: return "EACCES"
        case EBADF: return "EBADF"
        case EINVAL: return "EINVAL"
        case EMFILE: return "EMFILE"
        case ENFILE: return "ENFILE"
        case ENOBUFS: return "ENOBUFS"
        case ENOMEM: return "ENOMEM"
        case EAFNOSUPPORT: return "EAFNOSUPPORT"
        case EPROTO: return "EPROTO"
        case EOPNOTSUPP: return "EOPNOTSUPP"
        default: return "errno \(code)"
        }
    }

    /// strerror text, e.g. "Connection refused".
    public static func text(_ code: Int32) -> String {
        strerror(code).map { String(cString: $0) } ?? "error \(code)"
    }

    /// "ECONNREFUSED (Connection refused)".
    public static func describe(_ code: Int32) -> String { "\(name(code)) (\(text(code)))" }
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

/// Non-blocking + close-on-exec + TCP_NODELAY + no SIGPIPE.
private func configureStreamSocket(_ fd: Int32, noDelay: Bool) {
    setNonBlockingCloExec(fd)
    if noDelay { setIntOption(fd, Int32(IPPROTO_TCP), Int32(TCP_NODELAY), 1) }
    #if canImport(Darwin)
    setIntOption(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
    #endif
}

private func monotonicNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

/// Seconds → ns, clamped to [0, 10^6 s].
private func nanos(_ seconds: TimeInterval) -> UInt64 { UInt64(min(max(0, seconds), 1_000_000) * 1_000_000_000) }

private func millis(since start: UInt64) -> Int { Int((monotonicNanos() &- start) / 1_000_000) }

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

/// Dotted quad of an IPv4 socket address.
private func dottedQuad(_ addr: sockaddr_in) -> String {
    InterfaceAddresses.format(UInt32(bigEndian: addr.sin_addr.s_addr))
}

/// Host and port of a socket address (IPv4 or IPv6).
private func describeAddress(_ storage: sockaddr_storage) -> (host: String?, port: UInt16) {
    var s = storage
    return withUnsafePointer(to: &s) { raw -> (String?, UInt16) in
        let family = Int32(raw.pointee.ss_family)
        if family == AF_INET {
            return raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> (String?, UInt16) in
                (dottedQuad(sin.pointee), UInt16(bigEndian: sin.pointee.sin_port))
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

/// True once a non-blocking connect has completed (getpeername succeeds).
private func isConnected(_ fd: Int32) -> Bool {
    var storage = sockaddr_storage()
    var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
    return withUnsafeMutablePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
    } == 0
}

/// Socket options that only exist on Apple platforms.
enum POSIXInterfaceBinding {
    #if canImport(Darwin)
    static let isSupported = true

    /// Interface index of a BSD interface name (0 = unknown).
    static func index(of name: String) -> UInt32 { if_nametoindex(name) }

    /// IP_BOUND_IF: the socket only uses that interface. Returns 0 or the errno.
    static func bind(_ fd: Int32, toInterface index: UInt32) -> Int32 {
        var value = Int32(truncatingIfNeeded: index)
        return setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 ? 0 : errno
    }

    /// The IP_BOUND_IF index of a socket (0 = unbound), nil if it cannot be read.
    static func boundIndex(_ fd: Int32) -> UInt32? {
        var value: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &value, &len) == 0 else { return nil }
        return UInt32(truncatingIfNeeded: value)
    }
    #else
    static let isSupported = false
    static func index(of name: String) -> UInt32 { 0 }
    static func bind(_ fd: Int32, toInterface index: UInt32) -> Int32 { EOPNOTSUPP }
    static func boundIndex(_ fd: Int32) -> UInt32? { nil }
    #endif
}

// MARK: - Reactor

/// One poll(2) thread for every socket of the process. Operations park here on EAGAIN.
final class POSIXPollReactor: @unchecked Sendable {
    static let shared = POSIXPollReactor()

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
    /// Wake pipe; -1 if pipe() failed (the loop then polls every 20 ms instead of sleeping).
    private let wakeRead: Int32
    private let wakeWrite: Int32

    private init() {
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            wakeRead = fds[0]
            wakeWrite = fds[1]
            setNonBlockingCloExec(wakeRead)
            setNonBlockingCloExec(wakeWrite)
        } else {
            let e = errno
            wakeRead = -1
            wakeWrite = -1
            Log.e("NET", "poll reactor: pipe() failed: \(POSIXErrno.describe(e)) — polling every 20 ms")
        }
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "ocm.posix.poll"
        // It only wakes parked operations: top QoS keeps socket latency low when the CPU is busy.
        thread.qualityOfService = .userInteractive
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
            op.phase = .cancelledEarly // register() resumes with .cancelled
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
        guard wakeWrite >= 0 else { return }
        var b: UInt8 = 1
        _ = sysWrite(wakeWrite, &b, 1) // EAGAIN (pipe full) is fine: a wake-up is already pending
    }

    private func run() {
        var pfds: [pollfd] = []
        var drain = [UInt8](repeating: 0, count: 256)
        var interest: [Int32: Int16] = [:]
        while true {
            pfds.removeAll(keepingCapacity: true)
            interest.removeAll(keepingCapacity: true)
            if wakeRead >= 0 { pfds.append(pollfd(fd: wakeRead, events: pollIn, revents: 0)) }
            let first = pfds.count
            var nearest: UInt64?
            lock.lock()
            for op in parked.values {
                interest[op.fd, default: 0] |= op.events
                if let d = op.deadline { nearest = min(nearest ?? d, d) }
            }
            lock.unlock()
            for (fd, events) in interest { pfds.append(pollfd(fd: fd, events: events, revents: 0)) }
            var timeoutMs: Int32 = wakeRead >= 0 ? -1 : 20
            if let d = nearest {
                let now = monotonicNanos()
                let untilDeadline = d <= now ? 0 : Int32(min((d - now + 999_999) / 1_000_000, 60_000))
                timeoutMs = timeoutMs < 0 ? untilDeadline : min(timeoutMs, untilDeadline)
            }
            let rc = poll(&pfds, nfds_t(pfds.count), timeoutMs)
            if rc < 0 {
                let e = errno
                if e != EINTR {
                    // EINVAL / ENOMEM: never expected; back off instead of spinning.
                    Log.shared.throttled("posix.poll", interval: 10, .error, "NET", "poll failed: \(POSIXErrno.describe(e))")
                    usleep(20_000)
                }
                continue
            }
            if wakeRead >= 0, pfds[0].revents != 0 {
                while drain.withUnsafeMutableBytes({ sysRead(wakeRead, $0.baseAddress, $0.count) }) > 0 {}
            }
            var ready: [Int32: Int16] = [:]
            for p in pfds[first...] where p.revents != 0 { ready[p.fd] = p.revents }
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
final class POSIXSocket: @unchecked Sendable {
    let id: UInt64
    private let fd: Int32
    private let reactor: POSIXPollReactor
    private let lock = NSLock()
    private var closed = false
    private var busy = 0
    private var released = false

    init(fd: Int32, reactor: POSIXPollReactor = .shared) {
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

    /// Parks until the descriptor is ready (see `POSIXPollReactor.wait`).
    func park(_ interest: POSIXPollReactor.Interest, deadline: UInt64? = nil, cancellable: Bool = true) async throws {
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
final class POSIXWriteLock: @unchecked Sendable {
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

    /// Held, and how many writers wait (tests).
    var state: (held: Bool, waiting: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (held, queue.count)
    }
}

/// TransportError for a recv/send failure on an established connection (NWNetworkProvider parity).
func posixStreamError(_ code: Int32, _ operation: String) -> TransportError {
    switch code {
    case ECONNRESET, EPIPE, ENOTCONN, ESHUTDOWN, ECONNABORTED, ENETRESET, EBADF: return .closed
    case ETIMEDOUT: return .timeout
    default: return .failed("\(POSIXErrno.name(code)): \(operation) failed (\(POSIXErrno.text(code)))")
    }
}

// MARK: - Stream

/// `ByteStream` over a connected TCP socket.
public final class POSIXByteStream: ByteStream, @unchecked Sendable {
    public let remoteEndpoint: String
    public let remoteHost: String?
    public let localPort: UInt16
    /// Local IPv4 of this connection (for the probe: the address the dash calls back).
    public let localHost: String?
    private let socket: POSIXSocket
    private let writeLock = POSIXWriteLock()
    private let onClose: (@Sendable (POSIXByteStream) -> Void)?
    /// Bytes received by a `read(exactly:)` that was cancelled before completing, delivered first by
    /// the next read (one reader at a time, per the contract).
    private let carry = Locked(Data())

    init(socket: POSIXSocket, remoteHost: String?, remotePort: UInt16, localPort: UInt16, localHost: String?,
         onClose: (@Sendable (POSIXByteStream) -> Void)? = nil) {
        self.socket = socket
        self.remoteHost = remoteHost
        remoteEndpoint = "\(remoteHost ?? "?"):\(remotePort)"
        self.localPort = localPort
        self.localHost = localHost
        self.onClose = onClose
    }

    deinit { socket.close() }

    /// True once `close()` was called.
    public var isClosed: Bool { socket.isClosed }

    /// The write lock's state (tests).
    var writeQueue: (held: Bool, waiting: Int) { writeLock.state }

    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var out = takeCarry(max: count)
        out.reserveCapacity(min(count, 1 << 20))
        do {
            while out.count < count {
                out.append(try await receive(maxCount: count - out.count))
            }
        } catch {
            if !out.isEmpty, error as? TransportError == .cancelled {
                let partial = out
                carry.withLock { $0 = partial + $0 }
            }
            throw error
        }
        return out
    }

    public func readSome(maxCount: Int) async throws -> Data {
        let carried = takeCarry(max: max(1, maxCount))
        if !carried.isEmpty { return carried }
        return try await receive(maxCount: maxCount)
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        await writeLock.acquire()
        defer { writeLock.release() }
        var offset = 0
        while offset < data.count {
            let start = offset
            let (n, e) = try socket.syscall { fd in
                data.withUnsafeBytes { p in sysSend(fd, p.baseAddress! + start, p.count - start) }
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
                throw posixStreamError(e, "send")
            }
        }
    }

    public func close() {
        let wasOpen = !socket.isClosed
        socket.close()
        if wasOpen { onClose?(self) }
    }

    private func takeCarry(max count: Int) -> Data {
        carry.withLock { buffered -> Data in
            guard !buffered.isEmpty else { return Data() }
            let n = Swift.min(count, buffered.count)
            let head = Data(buffered.prefix(n))
            buffered = Data(buffered.dropFirst(n))
            return head
        }
    }

    private func receive(maxCount: Int) async throws -> Data {
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
                throw posixStreamError(e, "recv")
            }
        }
    }
}

// MARK: - Listener

/// `StreamListener` over a listening TCP socket; the kernel backlog queues unaccepted connections.
public final class POSIXStreamListener: StreamListener, @unchecked Sendable {
    public let port: UInt16
    private let socket: POSIXSocket
    private let noDelay: Bool
    private let onAccept: (@Sendable (POSIXByteStream) -> Void)?
    private let onStreamClose: (@Sendable (POSIXByteStream) -> Void)?

    init(socket: POSIXSocket, port: UInt16, noDelay: Bool, onAccept: (@Sendable (POSIXByteStream) -> Void)?,
         onStreamClose: (@Sendable (POSIXByteStream) -> Void)?) {
        self.socket = socket
        self.port = port
        self.noDelay = noDelay
        self.onAccept = onAccept
        self.onStreamClose = onStreamClose
    }

    deinit { socket.close() }

    public func accept() async throws -> any ByteStream {
        var aborted = 0
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
                let stream = POSIXByteStream(socket: POSIXSocket(fd: cfd), remoteHost: peer.host, remotePort: peer.port,
                                             localPort: port, localHost: local.host, onClose: onStreamClose)
                onAccept?(stream)
                return stream
            }
            switch e {
            case EAGAIN, EWOULDBLOCK:
                aborted = 0
                try await socket.park(.read)
            case EINTR:
                continue
            case ECONNABORTED, EPROTO:
                // A client gave up before accept; endless repeats mean a dead (defunct) listener:
                // fail so the link listens again.
                aborted += 1
                if aborted >= 32 { throw TransportError.failed("accept :\(port) failed: \(POSIXErrno.describe(e)), repeatedly") }
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                // Out of descriptors / memory: keep the listener, retry shortly (no spinning).
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { throw TransportError.cancelled }
            default:
                if socket.isClosed { throw TransportError.closed }
                throw TransportError.failed("accept :\(port) failed: \(POSIXErrno.describe(e))")
            }
        }
    }

    public func close() { socket.close() }
}

// MARK: - Provider

/// `NetworkProvider` over BSD sockets (see the file header for the design and the error mapping).
public final class POSIXNetworkProvider: NetworkProvider, @unchecked Sendable {
    /// Apple platforms enforce Local Network privacy (iOS 14, macOS 15).
    #if canImport(Darwin)
    public static let platformHasLocalNetworkPrivacy = true
    #else
    public static let platformHasLocalNetworkPrivacy = false
    #endif

    public struct Options: Sendable {
        /// Listener bind address (nil = 0.0.0.0, every interface, like Android's ServerSocket).
        public var bindHost: String?
        /// TCP_NODELAY on every stream (NWNetworkProvider's default).
        public var noDelay: Bool
        public var backlog: Int32
        /// Pin outbound sockets to the interface whose subnet contains the destination (IP_BOUND_IF,
        /// Apple platforms only).
        public var bindToInterface: Bool
        /// Local IPv4 addresses for that choice (getifaddrs; tests inject lists).
        public var interfaceProvider: @Sendable () -> [InterfaceAddress]
        /// Treat a synchronous EHOSTUNREACH towards a local subnet as a Local Network privacy denial.
        public var detectLocalNetworkDenial: Bool
        /// Pause between connect attempts while that denial lasts (the alert may still be open).
        public var localNetworkRetryInterval: TimeInterval

        public init(bindHost: String? = nil, noDelay: Bool = true, backlog: Int32 = 16, bindToInterface: Bool = true,
                    interfaceProvider: @escaping @Sendable () -> [InterfaceAddress] = { InterfaceAddresses.current() },
                    detectLocalNetworkDenial: Bool = POSIXNetworkProvider.platformHasLocalNetworkPrivacy,
                    localNetworkRetryInterval: TimeInterval = 0.25) {
            self.bindHost = bindHost
            self.noDelay = noDelay
            self.backlog = backlog
            self.bindToInterface = bindToInterface
            self.interfaceProvider = interfaceProvider
            self.detectLocalNetworkDenial = detectLocalNetworkDenial
            self.localNetworkRetryInterval = localNetworkRetryInterval
        }
    }

    /// Extra transport lines (stream closes) for tools/linkrunner `--net-trace`; the main lines go
    /// to `Log` ("NET").
    public typealias Trace = @Sendable (String) -> Void

    public struct Counters: Sendable {
        public var listens = 0
        public var connectAttempts = 0
        public var connectsOK = 0
        public var connectRefused = 0
        public var connectTimeouts = 0
        public var connectDenied = 0
        public var accepted = 0
        public var acceptedByPort: [UInt16: Int] = [:]
    }

    /// The outbound decision for one destination.
    struct Route: Sendable, Equatable {
        let choice: OutboundInterfaceChoice
        /// IP_BOUND_IF index (nil = connect unbound).
        let index: UInt32?

        /// " via en0#9 (192.168.0.51)" / " unbound (loopback destination)" — for log lines.
        var label: String {
            guard let a = choice.interface else { return " \(choice)" }
            if let index { return " via \(a.name)#\(index) (\(a.ipv4))" }
            return " via \(a.name) (\(a.ipv4), routing table)"
        }
    }

    /// Test seam replacing connect(2): returns its result and errno.
    typealias ConnectCall = @Sendable (_ fd: Int32, _ address: sockaddr_in) -> (rc: Int32, errno: Int32)

    public let options: Options
    private let trace: Trace?
    private let connectCall: ConnectCall?
    private let counters = Locked(Counters())
    /// Last route logged per destination (logged again only when it changes).
    private let loggedRoutes = Locked([String: Route]())

    public convenience init(options: Options = Options(), trace: Trace? = nil) {
        self.init(options: options, trace: trace, connectCall: nil)
    }

    init(options: Options, trace: Trace?, connectCall: ConnectCall?) {
        self.options = options
        self.trace = trace
        self.connectCall = connectCall
    }

    public var snapshot: Counters { counters.current }

    // MARK: Listen

    public func listen(port: UInt16) async throws -> any StreamListener {
        try openListener(port: port)
    }

    /// Typed variant of `listen(port:)` (port 0 = kernel-chosen, read `port`).
    public func openListener(port: UInt16) throws -> POSIXStreamListener {
        let host = options.bindHost ?? "0.0.0.0"
        let fd = sysSocket()
        guard fd >= 0 else { throw listenFailure(port, "socket", errno) }
        let sock = POSIXSocket(fd: fd)
        setNonBlockingCloExec(fd)
        setIntOption(fd, SOL_SOCKET, SO_REUSEADDR, 1)
        guard var addr = posixIPv4Address(host: host, port: port) else {
            sock.close()
            throw TransportError.failed("listen :\(port) failed: bad bind address \(host)")
        }
        let (bound, bindErr) = try sock.syscall { fd in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysBind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard bound == 0 else {
            sock.close()
            throw listenFailure(port, "bind \(host)", bindErr)
        }
        let (listening, listenErr) = try sock.syscall { sysListen($0, options.backlog) }
        guard listening == 0 else {
            sock.close()
            throw listenFailure(port, "listen", listenErr)
        }
        counters.withLock { $0.listens += 1 }
        // Port 0 (tests): report the port the kernel picked.
        let boundPort = port == 0 ? sock.localEndpoint().port : port
        Log.d("NET", "listening on \(host):\(boundPort)")
        let tr = trace
        let ctr = counters
        return POSIXStreamListener(
            socket: sock, port: boundPort, noDelay: options.noDelay,
            onAccept: { s in
                ctr.withLock {
                    $0.accepted += 1
                    $0.acceptedByPort[s.localPort, default: 0] += 1
                }
                Log.d("NET", "[:\(s.localPort)] accepted \(s.remoteEndpoint) (local \(s.localHost ?? "?"))")
            },
            onStreamClose: { s in tr?("[net] :\(s.localPort) closed \(s.remoteEndpoint) (local)") })
    }

    private func listenFailure(_ port: UInt16, _ step: String, _ code: Int32) -> TransportError {
        Log.w("NET", "listen :\(port) failed: \(step): \(POSIXErrno.describe(code))")
        if code == EADDRINUSE { return PlatformTransportErrors.addressInUse(port: port) }
        return .failed("listen :\(port) failed: \(step): \(POSIXErrno.describe(code))")
    }

    // MARK: Connect

    public func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream {
        try await openStream(host: host, port: port, timeout: timeout)
    }

    /// Typed variant of `connect`: the stream exposes `localHost` (the source address the dash calls
    /// back after an accepted probe). Throws `.timeout` after `timeout` seconds; a Local Network
    /// denial is retried until then (see the file header).
    public func openStream(host: String, port: UInt16, timeout: TimeInterval) async throws -> POSIXByteStream {
        counters.withLock { $0.connectAttempts += 1 }
        guard port != 0 else { throw TransportError.failed("invalid port 0") }
        guard let addr = posixIPv4Address(host: host, port: port) else {
            Log.d("NET", "connect \(host):\(port) failed: cannot resolve \(host) (IPv4)")
            throw TransportError.failed("cannot resolve \(host) (IPv4)")
        }
        let target = "\(host):\(port)"
        let started = monotonicNanos()
        let deadline = started + nanos(timeout)
        let route = self.route(to: dottedQuad(addr))
        var denials = 0
        while true {
            let attempt: Attempt
            do {
                attempt = try await attemptConnect(addr, route: route, deadline: deadline)
            } catch let error as TransportError {
                if error == .timeout {
                    counters.withLock { $0.connectTimeouts += 1 }
                    Log.d("NET", "connect \(target)\(route.label) timed out after \(millis(since: started)) ms (no answer)")
                } else {
                    Log.d("NET", "connect \(target)\(route.label) \(error) after \(millis(since: started)) ms")
                }
                throw error
            }
            switch attempt {
            case let .connected(sock):
                counters.withLock { $0.connectsOK += 1 }
                let local = sock.localEndpoint()
                Log.d("NET", "connect \(target)\(route.label): connected in \(millis(since: started)) ms from \(local.host ?? "?"):\(local.port)")
                let tr = trace
                return POSIXByteStream(socket: sock, remoteHost: host, remotePort: port, localPort: local.port,
                                       localHost: local.host,
                                       onClose: { s in tr?("[net] outbound \(s.remoteEndpoint) closed (local)") })
            case let .failed(code, synchronous):
                let error = Self.connectError(code, synchronous: synchronous, towardsLocalSubnet: route.choice.interface != nil,
                                              detectLocalNetworkDenial: options.detectLocalNetworkDenial, target: target)
                guard PlatformTransportErrors.isLocalNetworkDenied(error) else {
                    counters.withLock {
                        if code == ECONNREFUSED { $0.connectRefused += 1 }
                        if error == .timeout { $0.connectTimeouts += 1 }
                    }
                    Log.d("NET", "connect \(target)\(route.label) failed: \(POSIXErrno.describe(code))\(synchronous ? "" : " (SO_ERROR)") after \(millis(since: started)) ms")
                    throw error
                }
                denials += 1
                if denials == 1 {
                    Log.w("NET", "connect \(target)\(route.label): EHOSTUNREACH straight from connect() = dropped by a system policy, normally Local Network privacy (else a VPN or per-app data rule); retrying until the \(String(format: "%.1f", timeout)) s deadline")
                }
                let pause = nanos(options.localNetworkRetryInterval)
                if monotonicNanos() + pause < deadline {
                    do { try await Task.sleep(nanoseconds: pause) } catch { throw TransportError.cancelled }
                    continue
                }
                counters.withLock { $0.connectDenied += 1 }
                Log.w("NET", "connect \(target)\(route.label): EHOSTUNREACH on all \(denials) attempt(s) in \(millis(since: started)) ms — Local Network access denied")
                throw error
            }
        }
    }

    /// TransportError for a failed connect attempt. A synchronous EHOSTUNREACH towards a local
    /// subnet is Local Network privacy's signature (Apple platforms, see the file header).
    static func connectError(_ code: Int32, synchronous: Bool, towardsLocalSubnet: Bool, detectLocalNetworkDenial: Bool,
                             target: String) -> TransportError {
        if code == EHOSTUNREACH, synchronous, towardsLocalSubnet, detectLocalNetworkDenial {
            return PlatformTransportErrors.localNetworkDeniedError
        }
        switch code {
        case ETIMEDOUT: return .timeout
        case ECONNREFUSED: return .failed("\(PlatformTransportErrors.connectionRefusedPrefix): connection refused (\(target))")
        default: return .failed("\(POSIXErrno.name(code)): \(POSIXErrno.text(code)) (\(target))")
        }
    }

    private enum Attempt {
        case connected(POSIXSocket)
        /// `synchronous`: returned by connect(2) itself rather than later through SO_ERROR.
        case failed(Int32, synchronous: Bool)
    }

    private func attemptConnect(_ address: sockaddr_in, route: Route, deadline: UInt64) async throws -> Attempt {
        let fd = sysSocket()
        guard fd >= 0 else {
            let e = errno
            throw TransportError.failed("\(POSIXErrno.name(e)): socket failed (\(POSIXErrno.text(e)))")
        }
        configureStreamSocket(fd, noDelay: options.noDelay)
        let sock = POSIXSocket(fd: fd)
        if let index = route.index {
            let e = POSIXInterfaceBinding.bind(fd, toInterface: index)
            if e != 0 {
                Log.shared.throttled("posix.boundif.\(index).\(e)", interval: 30, .warn, "NET",
                                     "IP_BOUND_IF \(route.choice) #\(index) failed: \(POSIXErrno.describe(e)) — connecting unbound")
            }
        }
        let rc: Int32
        let e: Int32
        if let connectCall {
            let r = try sock.syscall { fd in connectCall(fd, address) }.result
            (rc, e) = (r.rc, r.errno)
        } else {
            var addr = address
            let r = try sock.syscall { fd in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            (rc, e) = (r.result, r.errno)
        }
        if rc == 0 { return .connected(sock) }
        // EINTR: the connection continues asynchronously. (EAGAIN from a TCP connect = no free port.)
        guard e == EINPROGRESS || e == EINTR else {
            sock.close()
            return .failed(e, synchronous: true)
        }
        do {
            try await sock.park(.write, deadline: deadline)
        } catch {
            sock.close()
            throw error
        }
        let soErr = sock.pendingError()
        if soErr != 0 {
            sock.close()
            return .failed(soErr, synchronous: false)
        }
        guard (try? sock.syscall({ isConnected($0) }).result) == true else {
            sock.close()
            return .failed(ENOTCONN, synchronous: false)
        }
        return .connected(sock)
    }

    /// The outbound decision for `ip`, logged when it changes for that destination.
    func route(to ip: String) -> Route {
        let choice = InterfaceAddresses.outboundInterface(for: ip, among: options.interfaceProvider())
        var index: UInt32?
        if options.bindToInterface, POSIXInterfaceBinding.isSupported, let a = choice.interface {
            let i = POSIXInterfaceBinding.index(of: a.name)
            index = i == 0 ? nil : i
        }
        let route = Route(choice: choice, index: index)
        let changed: Bool = loggedRoutes.withLock { logged in
            guard logged[ip] != route else { return false }
            logged[ip] = route
            return true
        }
        if changed {
            switch choice {
            case let .subnet(a) where index != nil:
                Log.i("NET", "route to \(ip): \(choice) — socket bound to \(a.name) (index \(index ?? 0), IP_BOUND_IF)")
            case let .subnet(a):
                let why = !POSIXInterfaceBinding.isSupported ? "no IP_BOUND_IF here"
                    : !options.bindToInterface ? "binding off" : "no index for \(a.name)"
                Log.i("NET", "route to \(ip): \(choice) — not bound (\(why), routing table)")
            default:
                Log.i("NET", "route to \(ip): \(choice)")
            }
        }
        return route
    }
}
