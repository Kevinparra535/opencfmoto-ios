// SPDX-License-Identifier: AGPL-3.0-or-later
// ReplayKit mirror relay transport (docs/spec/ios-platform-facts.md §f, design recommendation 14):
// the Broadcast Upload Extension (MirrorRelayClient) sends encoded access units to the host app
// (MirrorRelayServer), which owns the dash link and serves them as a VideoFrameSource. The host
// sends the negotiated canvas / encoder settings and keyframe requests back. Transport: a Unix
// domain stream socket inside the App Group container (path ≤ 100 bytes; sun_path holds 104 on
// Darwin). Framing: OpenCfMotoCore/Video/MirrorRelayProtocol.swift.
//
// Plain POSIX sockets on dedicated threads (Darwin; also builds on Glibc so the relay is tested
// end-to-end on Linux CI).

import Foundation
import OpenCfMotoCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Socket path

public enum MirrorRelaySocket {
    /// Longest accepted socket path in bytes (Darwin sun_path = 104 incl. NUL; keep a margin).
    public static let maxPathBytes = 100
    /// Info.plist key holding the App Group identifier (app and extension, see project.yml).
    public static let appGroupInfoKey = "OCMAppGroupIdentifier"

    /// `<directory>/<fileName>` if it fits in a sockaddr_un, else nil.
    public static func path(inDirectory directory: URL, fileName: String = MirrorRelayProtocol.socketFileName) -> String? {
        let p = directory.appendingPathComponent(fileName).path
        return isUsable(path: p) ? p : nil
    }

    public static func isUsable(path: String) -> Bool {
        let n = path.utf8.count
        return n > 0 && n <= maxPathBytes
    }

#if canImport(Darwin)
    /// Socket path inside the App Group container shared by the app and the extension.
    public static func path(appGroupIdentifier: String, fileName: String = MirrorRelayProtocol.socketFileName) -> String? {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return nil }
        return path(inDirectory: dir, fileName: fileName)
    }

    /// Socket path for the App Group named by `OCMAppGroupIdentifier` in `bundle`'s Info.plist.
    public static func defaultPath(bundle: Bundle = .main) -> String? {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty,
              !group.contains("$(") else { return nil }
        return path(appGroupIdentifier: group)
    }
#endif
}

// MARK: - Send-side flow control (platform-neutral, unit-tested)

/// Bounded frame sending for the extension (its memory budget is tiny): at most `maxPending`
/// frames queued for the socket. When full, P-frames are dropped and — because a dropped
/// P-frame breaks the reference chain — further P-frames too until the next keyframe, which is
/// requested once.
struct RelaySendGate: Equatable {
    enum Verdict: Equatable {
        case send
        case drop(requestKeyframe: Bool)
    }

    let maxPending: Int
    private(set) var pending = 0
    private(set) var awaitingKeyframe = false
    private(set) var dropped = 0

    init(maxPending: Int) { self.maxPending = max(1, maxPending) }

    mutating func offer(isKeyframe: Bool) -> Verdict {
        if awaitingKeyframe, !isKeyframe {
            dropped += 1
            return .drop(requestKeyframe: false)
        }
        // A keyframe restarts the GOP: it may use a little headroom.
        let limit = isKeyframe ? maxPending * 2 : maxPending
        if pending >= limit {
            dropped += 1
            let first = !awaitingKeyframe
            awaitingKeyframe = true
            return .drop(requestKeyframe: first)
        }
        if isKeyframe { awaitingKeyframe = false }
        pending += 1
        return .send
    }

    mutating func sent() { pending = max(0, pending - 1) }

    /// New connection: nothing pending, start with a keyframe.
    mutating func reset() {
        pending = 0
        awaitingKeyframe = true
    }
}

// MARK: - Placeholder picture (platform-neutral, unit-tested)

/// What the dash shows while the mirror relay has no picture of its own for the negotiated canvas
/// (the broadcast extension is not running, or has not sent an IDR for this canvas yet): a card
/// asking the rider to start the screen broadcast. The mirror flow links the dash FIRST (step 1)
/// and the ReplayKit picker + countdown follow (step 2), so the dash's first 114 usually comes
/// before any screen frame — and the dash pulls in lock-step: a pull left unanswered ends the
/// session (MP-1).
public enum MirrorPlaceholderPicture {
    public static func title(_ l: NavLanguage) -> String {
        l == .es ? "Inicia la transmisión de pantalla en tu iPhone" : "Start the screen broadcast on your iPhone"
    }

    public static func hint(_ l: NavLanguage) -> String {
        l == .es ? "OpenCfMoto ▸ Espejo ▸ paso 2" : "OpenCfMoto ▸ Mirror ▸ step 2"
    }

    /// The card at exactly `canvas` (black around it, dash palette, density-scaled sizes).
    public static func displayList(canvas: VideoCanvas, language: NavLanguage = .preferred) -> DashDisplayList {
        let w = Double(max(1, canvas.width)), h = Double(max(1, canvas.height))
        let k = DashDensity.scale(canvasWidth: w)
        let pad = 24 * k
        let cardW = max(64, min(w - 48 * k, 520 * k))
        let titleFont = DashFont(size: 24 * k, weight: .bold)
        let hintFont = DashFont(size: 17 * k)
        let titleH = 3 * titleFont.size * 1.25
        let hintH = hintFont.size * 1.4
        let gap = 10 * k
        let cardH = pad + titleH + gap + hintH + pad
        let card = DashRect(x: (w - cardW) / 2, y: max(0, (h - cardH) / 2), width: cardW, height: cardH)
        let textW = cardW - 2 * pad
        return DashDisplayList(size: DashSize(width: w, height: h), background: DashColor(rgb: 0x000000), commands: [
            .fill(DashPath.roundedRect(card, radius: DashPalette.cardRadius * k), DashPalette.cardFill, .nonZero),
            .text(title(language), DashRect(x: card.minX + pad, y: card.minY + pad, width: textW, height: titleH),
                  DashTextStyle(font: titleFont, color: DashPalette.primaryText, alignment: .center, maxLines: 3)),
            .text(hint(language), DashRect(x: card.minX + pad, y: card.minY + pad + titleH + gap, width: textW, height: hintH),
                  DashTextStyle(font: hintFont, color: DashPalette.secondaryText, alignment: .center, maxLines: 1)),
        ])
    }
}

// MARK: - POSIX helpers

#if canImport(Darwin) || canImport(Glibc)
enum RelaySocketIO {
    enum Failure: Error, CustomStringConvertible {
        case pathTooLong(String)
        case syscall(String, Int32)

        var description: String {
            switch self {
            case let .pathTooLong(p): return "socket path too long (\(p.utf8.count) bytes): \(p)"
            case let .syscall(name, err): return "\(name) failed: errno \(err) (\(String(cString: strerror(err))))"
            }
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity, bytes.count <= MirrorRelaySocket.maxPathBytes else {
            throw Failure.pathTooLong(path)
        }
        addr.sun_family = sa_family_t(AF_UNIX)
#if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
#endif
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func newSocket() throws -> Int32 {
#if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
#else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
#endif
        guard fd >= 0 else { throw Failure.syscall("socket", errno) }
        return fd
    }

    /// Device + inode of a socket file: tells "the socket I bound" from a newer one at the same path.
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    /// A listening socket and the identity of the file it bound.
    struct Listener {
        let fd: Int32
        let identity: FileIdentity
    }

    /// Serializes every bind / identity check / unlink of relay socket paths in this process: a
    /// server can never check "is this still my socket file?" while another one replaces it.
    private static let pathLock = NSLock()

    /// Identity of the directory entry at `path` itself (a symlink is not followed); nil if none.
    private static func identity(ofPath path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(device: UInt64(truncatingIfNeeded: st.st_dev), inode: UInt64(truncatingIfNeeded: st.st_ino))
    }

    /// Bound + listening socket at `path` (a stale socket file is removed first) and the identity
    /// of the socket file it created, captured right after bind().
    static func makeListener(path: String, backlog: Int32 = 4) throws -> Listener {
        var addr = try address(path)
        let fd = try newSocket()
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        pathLock.lock()
        defer { pathLock.unlock() }
        unlink(path)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw Failure.syscall("bind", e)
        }
        guard let identity = identity(ofPath: path) else {
            let e = errno
            close(fd)
            throw Failure.syscall("lstat", e)
        }
        guard listen(fd, backlog) == 0 else {
            let e = errno
            unlink(path) // ours: bound just above, under the path lock
            close(fd)
            throw Failure.syscall("listen", e)
        }
        return Listener(fd: fd, identity: identity)
    }

    /// Removes `path` only while it still names the socket file `identity`. The caller keeps the
    /// listening descriptor open until this returns, so the inode cannot have been recycled for a
    /// newer file. Returns false when the path is gone or now belongs to a newer socket.
    @discardableResult
    static func unlinkIfOwned(path: String, identity: FileIdentity) -> Bool {
        pathLock.lock()
        defer { pathLock.unlock() }
        guard self.identity(ofPath: path) == identity else { return false }
        return unlink(path) == 0
    }

    static func makeConnection(path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = try newSocket()
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw Failure.syscall("connect", e)
        }
        configure(fd)
        return fd
    }

    /// Waits up to `timeoutMs` for a connection; nil on timeout or error.
    static func acceptClient(_ listenFD: Int32, timeoutMs: Int32) -> Int32? {
        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let r = poll(&pfd, 1, timeoutMs)
        guard r > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return nil }
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return nil }
        configure(fd)
        return fd
    }

    static func configure(_ fd: Int32) {
#if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
#endif
        var size: Int32 = 1 << 20
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Blocking write of every byte; false on error (peer gone).
    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        let count = data.count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return count == 0 }
            var offset = 0
            while offset < count {
#if canImport(Darwin)
                let n = send(fd, base + offset, count - offset, 0)
#else
                let n = send(fd, base + offset, count - offset, Int32(MSG_NOSIGNAL))
#endif
                if n > 0 { offset += n; continue }
                if n < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Bytes read (> 0), 0 at EOF, < 0 on error.
    static func receiveSome(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        while true {
            let n = recv(fd, buffer.baseAddress, buffer.count, 0)
            if n < 0, errno == EINTR { continue }
            return n
        }
    }

    /// Wakes a blocked reader / writer of `fd` (the owning thread then closes it).
    static func shutdownBoth(_ fd: Int32) {
        _ = shutdown(fd, Int32(SHUT_RDWR))
    }

    static func closeFD(_ fd: Int32) {
        _ = close(fd)
    }
}

/// One accepted / connected socket. Writes are serialized; the fd is closed exactly once, by
/// the thread that reads it, under the write lock (so no write can hit a reused descriptor).
final class RelayConnection: @unchecked Sendable {
    let fd: Int32
    let id: UInt64
    private let writeLock = NSLock()
    private var closed = false

    init(fd: Int32, id: UInt64) {
        self.fd = fd
        self.id = id
    }

    @discardableResult
    func write(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return false }
        return RelaySocketIO.sendAll(fd, data)
    }

    /// Unblocks the reader (any thread).
    func shutdown() {
        RelaySocketIO.shutdownBoth(fd)
    }

    /// Closes the descriptor (reader thread, after its loop ended).
    func closeFromReader() {
        writeLock.lock()
        if !closed {
            closed = true
            RelaySocketIO.shutdownBoth(fd)
            RelaySocketIO.closeFD(fd)
        }
        writeLock.unlock()
    }

    /// Reads and decodes messages until EOF / error / protocol error.
    func readMessages(_ handle: (MirrorRelayMessage) -> Void) -> Error? {
        var decoder = MirrorRelayDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { RelaySocketIO.receiveSome(fd, into: $0) }
            if n <= 0 { return nil }
            buffer.withUnsafeBytes { raw in decoder.append(UnsafeRawBufferPointer(rebasing: raw[0 ..< n])) }
            do {
                while let m = try decoder.nextMessage() { handle(m) }
            } catch {
                return error
            }
        }
    }
}

// MARK: - Host side

public struct MirrorRelayServerStats: Sendable, Equatable {
    public var connections = 0
    public var framesReceived = 0
    public var keyframesReceived = 0
    public var bytesReceived: Int64 = 0
    public var keyframeRequestsSent = 0
    public var fallbackKeyframesServed = 0
    /// Extension frames dropped because their IDR was encoded for another canvas (SPS size ≠ the
    /// negotiated canvas), including the P-frames that depend on it.
    public var wrongCanvasFramesDropped = 0
    /// Pulls answered with the "start the screen broadcast" placeholder.
    public var placeholderFramesServed = 0
    public var peerAgent: String?
    public init() {}
}

/// Host-app end of the mirror relay: listens on the App-Group socket, receives the extension's
/// access units into a FrameQueue and serves them to the dash link as a `VideoFrameSource`.
/// Thread-safe.
public final class MirrorRelayServer: VideoFrameSource, @unchecked Sendable {
    public let socketPath: String
    /// Frames from the extension (capacity 3, keyframe gate, GOP-safe overflow).
    public let frameQueue: FrameQueue
    private let lock = NSLock()
    private var running = false
    private var listenGeneration: UInt64 = 0
    /// The socket file this instance bound and still owns (cleared once it was released).
    private var bound: BoundSocket?
    private struct BoundSocket {
        let generation: UInt64
        let identity: RelaySocketIO.FileIdentity
    }
    private var connection: RelayConnection?
    private var nextConnectionId: UInt64 = 0
    private var _config: MirrorRelayConfig?
    private var _fit: ScreenFit = .fit
    private var _margins: ScreenMargins = .zero
    private var _stats = MirrorRelayServerStats()
    private var _onClientChange: (@Sendable (Bool) -> Void)?
    /// The extension's last IDR had the wrong size: drop its frames until a matching IDR.
    private var awaitingCanvasKeyframe = false
    // Placeholder picture (guarded by `lock`), built off the caller's thread per canvas.
    private var _placeholderProvider: (@Sendable (VideoCanvas, EncoderParameters) -> [EncodedFrame])?
    /// Placeholder IDRs per canvas ("WxH"); a few entries at most (one per bike / canvas).
    private var placeholders: [String: [EncodedFrame]] = [:]
    private var placeholderIndex = 0
    private var placeholderBuilding: (width: Int, height: Int)?
    private let placeholderQueue = DispatchQueue(label: "ocm.mirror.placeholder", qos: .userInitiated)
    /// Records the served access units (diagnostics, MP-7).
    private var dump: H264WireDump?

    public init(socketPath: String, queueCapacity: Int = 3) {
        self.socketPath = socketPath
        frameQueue = FrameQueue(capacity: queueCapacity)
        frameQueue.onKeyframeNeeded = { [weak self] in self?.sendKeyframeRequest() }
    }

    deinit { stop() }

    /// Called with true / false when the extension connects / disconnects (socket threads).
    public var onClientChange: (@Sendable (Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onClientChange }
        set { lock.lock(); _onClientChange = newValue; lock.unlock() }
    }

    /// Builds the "start the screen broadcast" IDRs for a canvas (the host app renders
    /// `MirrorPlaceholderPicture` and pre-encodes it: `MirrorRelayPlaceholder.frames`). Called on a
    /// private queue when a canvas is prepared. While no extension IDR exists for the negotiated
    /// canvas, pulls are answered with these at the keep-alive cadence instead of being left open
    /// (MP-1). nil = no placeholder (pulls wait for the extension).
    public var placeholderProvider: (@Sendable (VideoCanvas, EncoderParameters) -> [EncodedFrame])? {
        get { lock.lock(); defer { lock.unlock() }; return _placeholderProvider }
        set { lock.lock(); _placeholderProvider = newValue; lock.unlock() }
    }

    /// Records every access unit served to the dash to `url` (raw Annex-B), up to `maxFrames`
    /// (media-video.md §15.8 wire dump, the mirror counterpart of DashProjectionEngine's).
    public func startWireDump(to url: URL, maxFrames: Int = 600) throws {
        let d = try H264WireDump(url: url, maxFrames: maxFrames)
        lock.lock()
        let old = dump
        dump = d
        lock.unlock()
        old?.close()
        Log.i("DUMP", "recording mirror H.264 → \(url.lastPathComponent) (first \(maxFrames) frames)")
    }

    public func stopWireDump() {
        lock.lock()
        let old = dump
        dump = nil
        lock.unlock()
        old?.close()
    }

    /// True once the recording `startWireDump` opened closed itself (`maxFrames` written, or a write
    /// failed); false while it records and after `stopWireDump()`.
    public var isWireDumpFinished: Bool {
        let d = lock.withLock { dump }
        return d?.isFinished ?? false
    }

    public var isClientConnected: Bool { lock.lock(); defer { lock.unlock() }; return connection != nil }
    /// `start()` succeeded and `stop()` was not called.
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public var stats: MirrorRelayServerStats { lock.lock(); defer { lock.unlock() }; return _stats }
    public var configuration: MirrorRelayConfig? { lock.lock(); defer { lock.unlock() }; return _config }

    /// How the phone screen is fitted into the canvas (mirror default FIT) and the screen
    /// margins; changes are sent to the extension immediately.
    public func setFit(_ fit: ScreenFit, margins: ScreenMargins) {
        lock.lock()
        _fit = fit
        _margins = margins
        _config?.fit = fit
        _config?.margins = margins
        let cfg = _config
        lock.unlock()
        if let cfg { send(.config(cfg)) }
    }

    /// Binds the socket and starts accepting the extension.
    public func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        lock.unlock()
        let listener = try RelaySocketIO.makeListener(path: socketPath)
        frameQueue.reopen() // a new session never serves the previous one's IDR (MP-3)
        lock.lock()
        awaitingCanvasKeyframe = false
        running = true
        listenGeneration &+= 1
        let generation = listenGeneration
        bound = BoundSocket(generation: generation, identity: listener.identity)
        lock.unlock()
        let fd = listener.fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd, generation: generation) }
        thread.name = "ocm.mirror.accept"
        thread.start()
        Log.i("MIRROR", "relay listening on \(socketPath.split(separator: "/").last ?? "")")
    }

    /// Stops accepting, tells the extension, closes everything and wakes pending pulls. The
    /// socket file is removed before this returns — unless a newer server owns the path now.
    public func stop() {
        // First, while the accept thread still holds the listener open (so the file's inode
        // cannot have been recycled): remove the socket file iff the path still names it.
        releaseSocketFile(generation: nil)
        lock.lock()
        let wasRunning = running
        running = false
        let conn = connection
        lock.unlock()
        if let conn {
            conn.write(MirrorRelayMessage.stop(reason: "host stopped").encoded())
            conn.shutdown()
        }
        frameQueue.close()
        frameQueue.invalidateKeyframe()
        if wasRunning { Log.i("MIRROR", "relay stopped") }
    }

    // MARK: VideoFrameSource

    public func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {
        lock.lock()
        let old = _config?.canvas
        let cfg = MirrorRelayConfig(canvas: canvas, parameters: parameters, fit: _fit, margins: _margins)
        _config = cfg
        lock.unlock()
        let sizeChanged = old.map { $0.width != canvas.width || $0.height != canvas.height } ?? true
        if sizeChanged {
            // An IDR of the previous (or the extension's default) canvas must never answer a pull
            // for this one (RLY 17 = encoded size, MP-3).
            frameQueue.invalidateKeyframe()
        }
        send(.config(cfg))
        if sizeChanged, old != nil {
            // Frames of the old size may still be queued or in flight: gate + flush, and the
            // extension (which just got the CONFIG) re-encodes an IDR at the new size.
            frameQueue.resynchronize()
        }
        buildPlaceholderIfNeeded(canvas: canvas, parameters: parameters)
    }

    public func resynchronize() {
        frameQueue.resynchronize() // → onKeyframeNeeded → keyframe request to the extension
    }

    public func nextFrame(timeout: TimeInterval) async -> EncodedFrame? {
        let started = ProcessInfo.processInfo.systemUptime
        if isRunning, frameQueue.lastKeyframe == nil, let interval = placeholderInterval() {
            // No broadcast picture for this canvas yet: answer at the keep-alive cadence with the
            // placeholder instead of leaving the dash's lock-step pull open (MP-1).
            let wait = min(max(0.05, timeout - FramePull.safetyMargin), interval)
            if let f = await frameQueue.next(timeout: wait) { return served(f) }
            if isRunning, let p = nextPlaceholder() {
                frameQueue.resynchronize() // the decoder's reference is the placeholder: next live frame = IDR
                lock.withLock { _stats.placeholderFramesServed += 1 }
                Log.shared.throttled("mirror-placeholder", interval: 10, .info, "MIRROR",
                                     "no screen broadcast picture for this canvas yet → placeholder")
                return served(p)
            }
        }
        let remaining = max(0.01, timeout - (ProcessInfo.processInfo.systemUptime - started))
        let r = await FramePull.next(from: frameQueue, timeout: remaining) { [weak self] in
            guard let self, self.isRunning else { return nil } // a stopped relay serves nothing
            return self.frameQueue.lastKeyframe ?? self.nextPlaceholder()
        }
        if r.usedFallback {
            lock.withLock { _stats.fallbackKeyframesServed += 1 }
            Log.shared.throttled("mirror-fallback", interval: 5, .warn, "MIRROR", "no mirror frame in time → re-sent the last IDR")
        }
        return r.frame.map { served($0) }
    }

    /// A frame handed to the link (wire dump).
    private func served(_ f: EncodedFrame) -> EncodedFrame {
        let d = lock.withLock { dump }
        d?.write(f)
        return f
    }

    public func mediaStopped() {
        frameQueue.flush()
    }

    // MARK: private

    private func sendKeyframeRequest() {
        if send(.keyframeRequest) {
            lock.lock(); _stats.keyframeRequestsSent += 1; lock.unlock()
        }
    }

    /// The keep-alive cadence for placeholder answers; nil when no placeholder can exist.
    private func placeholderInterval() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard _placeholderProvider != nil || !placeholders.isEmpty else { return nil }
        let repeatAfter = _config?.parameters.repeatLastFrameAfter ?? 0.9
        return min(max(repeatAfter, 0.1), 2)
    }

    /// Starts building the placeholder IDRs for `canvas` unless they exist / are being built.
    private func buildPlaceholderIfNeeded(canvas: VideoCanvas, parameters: EncoderParameters) {
        lock.lock()
        let provider = _placeholderProvider
        let have = placeholders[Self.placeholderKey(canvas)] != nil
        let building = placeholderBuilding.map { $0.width == canvas.width && $0.height == canvas.height } ?? false
        guard let provider, !have, !building else { lock.unlock(); return }
        placeholderBuilding = (canvas.width, canvas.height)
        lock.unlock()
        placeholderQueue.async { [weak self] in
            let frames = provider(canvas, parameters).filter { $0.isKeyframe && !$0.accessUnit.isEmpty }
            guard let self else { return }
            self.lock.lock()
            if self.placeholderBuilding.map({ $0.width == canvas.width && $0.height == canvas.height }) ?? false {
                self.placeholderBuilding = nil
            }
            if !frames.isEmpty {
                if self.placeholders.count >= 4 { self.placeholders.removeAll() }
                self.placeholders[Self.placeholderKey(canvas)] = frames
            }
            self.lock.unlock()
            Log.i("MIRROR", frames.isEmpty ? "placeholder picture unavailable (no encoder)"
                : "placeholder picture ready for \(canvas.width)x\(canvas.height) (\(frames.count) IDR)")
        }
    }

    /// Round-robin over the placeholder IDRs of the negotiated canvas (nil if none).
    private func nextPlaceholder() -> EncodedFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let canvas = _config?.canvas, let frames = placeholders[Self.placeholderKey(canvas)], !frames.isEmpty else { return nil }
        let f = frames[placeholderIndex % frames.count]
        placeholderIndex &+= 1
        return f
    }

    private static func placeholderKey(_ c: VideoCanvas) -> String { "\(c.width)x\(c.height)" }

    @discardableResult
    private func send(_ message: MirrorRelayMessage) -> Bool {
        lock.lock()
        let conn = connection
        lock.unlock()
        guard let conn else { return false }
        let ok = conn.write(message.encoded())
        if !ok { conn.shutdown() }
        return ok
    }

    private func acceptLoop(_ fd: Int32, generation: UInt64) {
        while true {
            lock.lock()
            let keepGoing = running && generation == listenGeneration
            lock.unlock()
            guard keepGoing else { break }
            guard let client = RelaySocketIO.acceptClient(fd, timeoutMs: 250) else { continue }
            attach(client)
        }
        // stop() normally released the file already. This loop may wake up to 250 ms later, when
        // a newer server (this instance restarted, or another one) can own the path: only this
        // generation's own, still-present socket file is removed — before closing the listener.
        releaseSocketFile(generation: generation)
        RelaySocketIO.closeFD(fd)
    }

    /// Removes the socket file this instance bound (`generation` nil = whatever it still owns),
    /// once, and only if the path still names that very socket (device + inode).
    private func releaseSocketFile(generation: UInt64?) {
        lock.lock()
        var owned: BoundSocket?
        if let b = bound, generation == nil || b.generation == generation {
            owned = b
            bound = nil
        }
        lock.unlock()
        guard let owned else { return }
        if !RelaySocketIO.unlinkIfOwned(path: socketPath, identity: owned.identity) {
            Log.i("MIRROR", "relay socket file left alone (already gone, or a newer listener owns the path)")
        }
    }

    private func attach(_ fd: Int32) {
        lock.lock()
        nextConnectionId &+= 1
        let conn = RelayConnection(fd: fd, id: nextConnectionId)
        let old = connection
        connection = conn
        _stats.connections += 1
        let cfg = _config
        let handler = _onClientChange
        lock.unlock()
        old?.shutdown()
        Log.i("MIRROR", "extension connected (#\(conn.id))")
        if let cfg { conn.write(MirrorRelayMessage.config(cfg).encoded()) }
        // Gate + flush + keyframe request BEFORE reading: the first frame served from the new
        // extension must be an IDR, and an early one must not be flushed.
        frameQueue.resynchronize()
        let reader = Thread { [weak self] in self?.readLoop(conn) }
        reader.name = "ocm.mirror.read"
        reader.start()
        handler?(true)
    }

    private func readLoop(_ conn: RelayConnection) {
        let error = conn.readMessages { [weak self] message in self?.handle(message) }
        conn.closeFromReader()
        lock.lock()
        let current = connection?.id == conn.id
        if current { connection = nil }
        let handler = _onClientChange
        lock.unlock()
        if let error { Log.w("MIRROR", "relay protocol error: \(error)") }
        if current {
            Log.i("MIRROR", "extension disconnected (#\(conn.id))")
            // The broadcast ended: no frozen last screen on the dash — the placeholder (if any)
            // asks for the broadcast again; a reconnecting extension starts with an IDR anyway.
            frameQueue.invalidateKeyframe()
            handler?(false)
        }
    }

    private func handle(_ message: MirrorRelayMessage) {
        switch message {
        case let .frame(f):
            guard !f.accessUnit.isEmpty else { return }
            lock.lock()
            _stats.framesReceived += 1
            if f.isKeyframe { _stats.keyframesReceived += 1 }
            _stats.bytesReceived += Int64(f.accessUnit.count)
            let verdict = Self.canvasVerdict(for: f, canvas: _config?.canvas, awaitingKeyframe: awaitingCanvasKeyframe)
            awaitingCanvasKeyframe = verdict.awaitingKeyframe
            if !verdict.accept { _stats.wrongCanvasFramesDropped += 1 }
            lock.unlock()
            if let size = verdict.wrongSize {
                Log.shared.throttled("mirror-wrong-canvas", interval: 5, .warn, "MIRROR",
                                     "dropped an extension IDR encoded at \(size.width)x\(size.height) — asked for one at the negotiated canvas")
                sendKeyframeRequest()
            }
            if verdict.accept { frameQueue.push(f) }
        case let .hello(version, agent):
            lock.lock(); _stats.peerAgent = agent; lock.unlock()
            Log.i("MIRROR", "extension hello v\(version) \(agent)")
        case let .log(level, tag, text):
            Log.shared.log(level, "EXT/" + tag, text)
        case let .stop(reason):
            Log.i("MIRROR", "extension stopping: \(reason)")
        case .config, .keyframeRequest:
            break // host → extension messages; ignore if echoed
        }
    }

    /// Whether an extension frame may reach the dash: an IDR whose SPS size differs from the
    /// negotiated canvas is dropped — and every P-frame after it until a matching IDR — because
    /// the dash must decode exactly the RLY 17 size (MP-3: the extension encodes its 800×384
    /// default before CONFIG arrives, or a frame of the previous canvas is still in flight).
    /// An IDR without a parseable SPS, or any frame before the first `prepare`, is accepted.
    static func canvasVerdict(for f: EncodedFrame, canvas: VideoCanvas?, awaitingKeyframe: Bool)
        -> (accept: Bool, awaitingKeyframe: Bool, wrongSize: (width: Int, height: Int)?) {
        guard f.isKeyframe else { return (!awaitingKeyframe, awaitingKeyframe, nil) }
        if let canvas, let sps = H264SPS.parse(accessUnit: f.accessUnit),
           sps.width != canvas.width || sps.height != canvas.height {
            // Ask for a fresh IDR once per wrong-size episode.
            return (false, true, awaitingKeyframe ? nil : (sps.width, sps.height))
        }
        return (true, false, nil)
    }
}

// MARK: - Extension side

public struct MirrorRelayClientStats: Sendable, Equatable {
    public var connects = 0
    public var framesSent = 0
    public var keyframesSent = 0
    public var framesDropped = 0
    public var bytesSent: Int64 = 0
    public var configsReceived = 0
    public var keyframeRequestsReceived = 0
    public init() {}
}

/// Extension end of the mirror relay: connects to the host (retrying every second until
/// `stop()`), sends frames with bounded buffering and delivers the host's configuration and
/// keyframe requests. Thread-safe.
public final class MirrorRelayClient: @unchecked Sendable {
    public let socketPath: String
    public let agent: String
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "ocm.mirror.client.write", qos: .userInteractive)
    private var running = false
    private var connection: RelayConnection?
    private var gate: RelaySendGate
    private var pendingLogs = 0
    private var logSubscription: UUID?
    private var _stats = MirrorRelayClientStats()
    private var _onConfig: (@Sendable (MirrorRelayConfig) -> Void)?
    private var _onKeyframeRequest: (@Sendable () -> Void)?
    private var _onStop: (@Sendable (String) -> Void)?
    private var _onConnectionChange: (@Sendable (Bool) -> Void)?

    /// Reconnect interval while the host is not listening.
    public var retryInterval: TimeInterval = 1.0

    public init(socketPath: String, agent: String = "OpenCfMotoMirror", maxPendingFrames: Int = 3) {
        self.socketPath = socketPath
        self.agent = agent
        gate = RelaySendGate(maxPending: maxPendingFrames)
    }

    deinit {
        if let id = logSubscription { Log.shared.unsubscribe(id) }
    }

    /// Host configuration (canvas, encoder parameters, fit, margins) — socket thread.
    public var onConfig: (@Sendable (MirrorRelayConfig) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onConfig }
        set { lock.lock(); _onConfig = newValue; lock.unlock() }
    }

    /// An IDR is needed: requested by the host, or after frames had to be dropped locally.
    public var onKeyframeRequest: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onKeyframeRequest }
        set { lock.lock(); _onKeyframeRequest = newValue; lock.unlock() }
    }

    /// The host is stopping (e.g. the ride ended) — finish the broadcast.
    public var onStop: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onStop }
        set { lock.lock(); _onStop = newValue; lock.unlock() }
    }

    public var onConnectionChange: (@Sendable (Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onConnectionChange }
        set { lock.lock(); _onConnectionChange = newValue; lock.unlock() }
    }

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connection != nil }
    public var stats: MirrorRelayClientStats { lock.lock(); defer { lock.unlock() }; return _stats }

    /// Connects in the background and keeps reconnecting until `stop()`.
    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in self?.connectionLoop() }
        thread.name = "ocm.mirror.client"
        thread.start()
    }

    /// Sends STOP (if connected) and closes the connection.
    public func stop(reason: String = "broadcast finished") {
        lock.lock()
        running = false
        let conn = connection
        lock.unlock()
        if let conn {
            writeQueue.async {
                conn.write(MirrorRelayMessage.stop(reason: reason).encoded())
                conn.shutdown()
            }
        }
    }

    /// Queues one access unit for the host (dropped with a keyframe request when the host lags).
    public func send(frame: EncodedFrame) {
        guard !frame.accessUnit.isEmpty else { return }
        lock.lock()
        guard let conn = connection else { lock.unlock(); return }
        let verdict = gate.offer(isKeyframe: frame.isKeyframe)
        if case .drop = verdict { _stats.framesDropped += 1 }
        let keyHandler = _onKeyframeRequest
        lock.unlock()
        switch verdict {
        case let .drop(requestKeyframe):
            if requestKeyframe { keyHandler?() }
        case .send:
            let data = MirrorRelayMessage.frame(frame).encoded()
            writeQueue.async { [weak self] in
                let ok = conn.write(data)
                guard let self else { return }
                self.lock.lock()
                self.gate.sent()
                if ok {
                    self._stats.framesSent += 1
                    if frame.isKeyframe { self._stats.keyframesSent += 1 }
                    self._stats.bytesSent += Int64(data.count)
                }
                self.lock.unlock()
                if !ok { conn.shutdown() }
            }
        }
    }

    /// Forwards a log line to the host's log (never logs itself; bounded).
    public func send(log level: LogLevel, tag: String, message: String) {
        lock.lock()
        guard let conn = connection, pendingLogs < 64 else { lock.unlock(); return }
        pendingLogs += 1
        lock.unlock()
        let data = MirrorRelayMessage.log(level: level, tag: tag, message: message).encoded()
        writeQueue.async { [weak self] in
            conn.write(data)
            self?.lock.lock()
            self?.pendingLogs -= 1
            self?.lock.unlock()
        }
    }

    /// Mirrors `Log.shared` lines at or above `minimumLevel` to the host (the extension has no
    /// log UI of its own).
    public func forwardLogs(minimumLevel: LogLevel = .info) {
        lock.lock()
        let existing = logSubscription
        lock.unlock()
        guard existing == nil else { return }
        let id = Log.shared.subscribe { [weak self] line in
            guard line.level >= minimumLevel else { return }
            self?.send(log: line.level, tag: line.tag, message: line.message)
        }
        lock.lock(); logSubscription = id; lock.unlock()
    }

    // MARK: private

    private func connectionLoop() {
        var lastFailureLogged: Int32 = 0
        while true {
            lock.lock()
            let keepGoing = running
            lock.unlock()
            guard keepGoing else { return }
            let fd: Int32
            do {
                fd = try RelaySocketIO.makeConnection(path: socketPath)
            } catch {
                if case let RelaySocketIO.Failure.syscall(_, err) = error, err != lastFailureLogged {
                    lastFailureLogged = err
                    Log.w("MIRROR", "relay connect: \(error)")
                }
                Thread.sleep(forTimeInterval: max(0.05, retryInterval))
                continue
            }
            lastFailureLogged = 0
            lock.lock()
            let conn = RelayConnection(fd: fd, id: UInt64(_stats.connects + 1))
            connection = conn
            gate.reset()
            _stats.connects += 1
            let changeHandler = _onConnectionChange
            let keyHandler = _onKeyframeRequest
            lock.unlock()
            conn.write(MirrorRelayMessage.hello(version: MirrorRelayProtocol.version, agent: agent).encoded())
            Log.i("MIRROR", "connected to host relay")
            changeHandler?(true)
            keyHandler?() // start the stream with an IDR
            let error = conn.readMessages { [weak self] message in self?.handle(message) }
            conn.closeFromReader()
            lock.lock()
            if connection === conn { connection = nil }
            let stillRunning = running
            let changed = _onConnectionChange
            lock.unlock()
            if let error { Log.w("MIRROR", "relay protocol error: \(error)") }
            changed?(false)
            if stillRunning { Thread.sleep(forTimeInterval: max(0.05, retryInterval)) }
        }
    }

    private func handle(_ message: MirrorRelayMessage) {
        switch message {
        case let .config(cfg):
            lock.lock(); _stats.configsReceived += 1; let h = _onConfig; lock.unlock()
            h?(cfg)
        case .keyframeRequest:
            lock.lock(); _stats.keyframeRequestsReceived += 1; let h = _onKeyframeRequest; lock.unlock()
            h?()
        case let .stop(reason):
            lock.lock(); let h = _onStop; lock.unlock()
            h?(reason)
        case .hello, .frame, .log:
            break
        }
    }
}
#endif

// MARK: - Placeholder encoding (Apple platforms)

#if canImport(VideoToolbox) && canImport(CoreGraphics) && canImport(CoreText) && canImport(CoreVideo)
import CoreVideo

public enum MirrorRelayPlaceholder {
    /// Renders `MirrorPlaceholderPicture` at exactly `canvas` and pre-encodes it as two IDRs with a
    /// temporary VideoToolbox session (`H264Encoder.encodeStill`). Blocks up to ~1 s: call off the
    /// main thread (MirrorRelayServer calls it on its placeholder queue). [] when no encoder.
    public static func frames(canvas: VideoCanvas, parameters: EncoderParameters,
                              renderer: DashRenderer = DashRenderer()) -> [EncodedFrame] {
        guard canvas.width >= 16, canvas.height >= 16,
              let buffer = PixelBufferFactory.makeStandaloneBuffer(width: canvas.width, height: canvas.height) else { return [] }
        guard renderer.render(MirrorPlaceholderPicture.displayList(canvas: canvas), into: buffer) else { return [] }
        return H264Encoder.encodeStill(pixelBuffer: buffer, width: canvas.width, height: canvas.height,
                                       parameters: parameters, count: 2, timeout: 1.0)
    }
}
#endif
