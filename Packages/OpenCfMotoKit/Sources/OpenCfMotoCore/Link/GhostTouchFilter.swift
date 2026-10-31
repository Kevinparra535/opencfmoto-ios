// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (handleTouch / isGhost / emit / holdUp /
// commitPendingUp / cancelPendingUp, lines 835-964)
//
// Ghost-touch filter and contact re-acquisition ("stitch") for dash touches
// (docs/spec/input-controls.md §4). The 800NK digitizer can report one finger as two contacts and
// drops a finger mid-drag, re-acquiring it within ~0–14 ms and < 150 px. Every UP is therefore held
// for 80 ms; a DOWN close to it within that window continues the drag as a MOVE.
//
// `androidCompat = true` reproduces Android bug-for-bug (the §4.5(b) traces). The default applies
// the recommended fixes:
//  F1 a held UP of ANOTHER pointer is committed (not discarded) when a new UP is held;
//  F2 pointers evicted as stale or trimmed above MAX_POINTERS get an UP downstream;
//  F3 a stitch with a new dash id transfers the identity (the old id leaves the pointer table).

import Foundation

/// Cancellation handle returned by a `TouchStitchScheduler`.
public protocol TouchStitchCancellable: Sendable {
    func cancel()
}

/// Runs the 80 ms "held UP" timers. Inject a virtual scheduler in tests.
public protocol TouchStitchScheduler: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TouchStitchCancellable
}

/// Production scheduler on a private serial Dispatch queue.
public final class DispatchTouchStitchScheduler: TouchStitchScheduler, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String = "opencfmoto.touch-stitch") {
        queue = DispatchQueue(label: label)
    }

    private final class Token: TouchStitchCancellable, @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    public func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> TouchStitchCancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return Token(item)
    }
}

/// Dash touch filter. Thread-safe (one NSLock; outputs are delivered while holding it, in order —
/// the sink must not call back into the filter synchronously).
public final class GhostTouchFilter: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        /// A contact within this distance (per axis, inclusive) of ANOTHER pointer is a ghost.
        public var ghostMergePx: Int = 48
        /// A pointer not updated for longer than this is evicted (covers a lost UP).
        public var pointerStaleMs: Int64 = 300
        /// Extra contacts beyond this are noise.
        public var maxPointers: Int = 2
        /// Every UP is held this long in case the finger comes back.
        public var stitchMs: Int64 = 80
        /// A re-acquired contact must land within this distance (per axis) of where it left.
        public var stitchPx: Int = 150
        /// Bug-for-bug Android behaviour (fixes F1–F3 off).
        public var androidCompat: Bool = false

        public init(androidCompat: Bool = false) {
            self.androidCompat = androidCompat
        }

        public static let `default` = Configuration()
        public static let androidCompatible = Configuration(androidCompat: true)
    }

    private struct Pointer {
        var x: Int
        var y: Int
        var lastSeenMs: Int64
    }

    public let configuration: Configuration
    private let clock: MonotonicClock
    private let scheduler: TouchStitchScheduler
    private let output: @Sendable (DashTouch) -> Void
    /// Log prefix, e.g. ":10921".
    public let tag: String

    private let lock = NSLock()
    // Insertion-ordered pointer table (Java LinkedHashMap semantics).
    private var order: [Int] = []
    private var pointers: [Int: Pointer] = [:]
    private var pendingUpId = -1
    private var pendingUpX = 0
    private var pendingUpY = 0
    private var pendingUpAt: Int64 = 0
    private var pendingUpToken: TouchStitchCancellable?
    private var pendingGeneration: UInt64 = 0
    /// dash id → id already delivered downstream (a dropped contact that came back as a new id).
    private var outIdOf: [Int: Int] = [:]
    private var ghostsDropped = 0
    private var stitches = 0
    /// Log lines produced under `lock`, emitted after unlocking (Log subscribers are synchronous).
    private var pendingLogs: [(LogLevel, String)] = []

    /// - Parameters:
    ///   - clock: monotonic seconds (DashTouch.time and all thresholds).
    ///   - output: receives filtered touches (outId, canvas px).
    public init(configuration: Configuration = .default, clock: MonotonicClock = SystemMonotonicClock(),
                scheduler: TouchStitchScheduler = DispatchTouchStitchScheduler(), tag: String = ":10921",
                output: @escaping @Sendable (DashTouch) -> Void) {
        self.configuration = configuration
        self.clock = clock
        self.scheduler = scheduler
        self.tag = tag
        self.output = output
    }

    /// Android `near`: Chebyshev (per-axis) distance, inclusive.
    public static func near(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int, tolerance: Int = 48) -> Bool {
        abs(ax - bx) <= tolerance && abs(ay - by) <= tolerance
    }

    /// Currently tracked dash pointer ids (for diagnostics/tests).
    public var trackedPointerIds: [Int] { lock.lock(); defer { lock.unlock() }; return order }

    /// Feeds a decoded wire frame.
    public func handle(_ frame: PxcTouchFrame) {
        handle(rawAction: frame.rawAction, x: frame.x, y: frame.y, pointerId: frame.pointerId)
    }

    /// Feeds one raw touch (2 = DOWN, 3 = MOVE, 1 = UP; others are dropped).
    public func handle(rawAction: UInt16, x: Int, y: Int, pointerId id: Int) {
        guard let action = PxcTouchFrame.normalize(rawAction) else {
            Log.w("LINK", "[\(tag)] touch: unknown action=\(rawAction) x=\(x) y=\(y)")
            return
        }
        if action == .move {
            Log.shared.throttled("touch-move-\(tag)", interval: 0.4, .debug, "LINK",
                                 "[\(tag)] TOUCH MOVE bike=(\(x),\(y)) ptr=\(id)")
        }
        lock.lock()
        defer { unlockAndFlushLogs() }
        let now = nowMs()
        // (1) Stale eviction (Android: silent; F2: delivered as UP).
        let stale = order.filter { $0 != id && now - (pointers[$0]?.lastSeenMs ?? now) > configuration.pointerStaleMs }
        for k in stale { evict(k, now: now, reason: "stale") }

        switch action {
        case .up:
            guard pointers[id] != nil else { return } // UP of a filtered ghost / untracked pointer
            holdUp(id, x, y, now)
            return
        case .down:
            if pendingUpId >= 0, now - pendingUpAt <= configuration.stitchMs,
               GhostTouchFilter.near(pendingUpX, pendingUpY, x, y, tolerance: configuration.stitchPx) {
                let held = pendingUpId
                let original = outIdOf[held] ?? held
                let gap = now - pendingUpAt
                cancelPendingUp()
                if !configuration.androidCompat, held != id {
                    // F3: transfer the identity — the old dash id no longer exists.
                    removePointer(held)
                    outIdOf[held] = nil
                }
                if id != original { outIdOf[id] = original }
                if stitches % 10 == 0 {
                    log("[\(tag)] touch: contact came back \(gap)ms later, keeping the drag alive instead of ending it (#\(stitches + 1))")
                }
                stitches += 1
                emit(.move, id, x, y, now)
                return
            }
            commitPendingUp(now)
            if isGhost(id, x, y) {
                if ghostsDropped % 20 == 0 {
                    log("[\(tag)] touch: ignoring ghost contact at (\(x),\(y)) near an existing finger")
                }
                ghostsDropped += 1
                return
            }
        case .move:
            if isGhost(id, x, y) { return }
        }
        emit(action, id, x, y, now)
    }

    /// Clears all state and cancels a held UP (Android `stop()`); nothing is delivered.
    public func reset() {
        lock.lock()
        defer { unlockAndFlushLogs() }
        cancelPendingUp()
        order.removeAll()
        pointers.removeAll()
        outIdOf.removeAll()
    }

    // MARK: - Internals (lock held)

    private func log(_ message: String, _ level: LogLevel = .info) {
        pendingLogs.append((level, message))
    }

    private func unlockAndFlushLogs() {
        let logs = pendingLogs
        pendingLogs.removeAll()
        lock.unlock()
        for (level, message) in logs { Log.shared.log(level, "LINK", message) }
    }

    private func nowMs() -> Int64 { Int64((clock.now() * 1000).rounded()) }

    private func isGhost(_ id: Int, _ x: Int, _ y: Int) -> Bool {
        order.contains { k in
            guard k != id, let p = pointers[k] else { return false }
            return GhostTouchFilter.near(p.x, p.y, x, y, tolerance: configuration.ghostMergePx)
        }
    }

    private func removePointer(_ k: Int) {
        pointers[k] = nil
        order.removeAll { $0 == k }
    }

    /// Removes a pointer outside the normal UP path (stale or trimmed).
    private func evict(_ k: Int, now: Int64, reason: String) {
        guard let p = pointers[k] else { return }
        removePointer(k)
        guard !configuration.androidCompat else { return }
        // F2: tell downstream the pointer is gone. A held UP of this pointer is delivered now instead.
        var x = p.x, y = p.y
        if pendingUpId == k {
            x = pendingUpX
            y = pendingUpY
            cancelPendingUp()
        }
        let out = outIdOf[k] ?? k
        outIdOf[k] = nil
        log("[\(tag)] touch: pointer \(k) evicted (\(reason)) → UP")
        output(DashTouch(action: .up, pointerId: out, x: x, y: y, time: Double(now) / 1000))
    }

    private func emit(_ action: DashTouch.Action, _ id: Int, _ x: Int, _ y: Int, _ now: Int64) {
        if pointers[id] == nil { order.append(id) }
        pointers[id] = Pointer(x: x, y: y, lastSeenMs: now)
        if order.count > configuration.maxPointers {
            // Keep the current pointer + the most recently seen others (stable sort, Kotlin parity).
            let byRecency = order.enumerated()
                .sorted { a, b in
                    let la = pointers[a.element]!.lastSeenMs, lb = pointers[b.element]!.lastSeenMs
                    return la != lb ? la > lb : a.offset < b.offset
                }
                .map(\.element)
            var keep: [Int] = []
            for k in [id] + byRecency where !keep.contains(k) { keep.append(k) }
            let keepSet = Set(keep.prefix(configuration.maxPointers))
            for k in order where !keepSet.contains(k) { evict(k, now: now, reason: "trim") }
        }
        let out = outIdOf[id] ?? id
        switch action {
        case .move:
            break // MOVE lines are throttled in `handle` (Android: one per 400 ms)
        case .down, .up:
            log("[\(tag)] TOUCH \(action == .down ? "DOWN" : "UP") bike=(\(x),\(y)) ptr=\(id) of \(order.count)")
        }
        output(DashTouch(action: action, pointerId: out, x: x, y: y, time: Double(now) / 1000))
        if action == .up {
            removePointer(id)
            outIdOf[id] = nil
        }
    }

    private func holdUp(_ id: Int, _ x: Int, _ y: Int, _ now: Int64) {
        if !configuration.androidCompat, pendingUpId >= 0, pendingUpId != id {
            commitPendingUp(now) // F1: never lose the other finger's UP
        }
        cancelPendingUp()
        pendingUpId = id
        pendingUpX = x
        pendingUpY = y
        pendingUpAt = now
        pendingGeneration &+= 1
        let generation = pendingGeneration
        pendingUpToken = scheduler.schedule(after: Double(configuration.stitchMs) / 1000) { [weak self] in
            self?.fireHeldUp(id: id, x: x, y: y, generation: generation)
        }
    }

    private func fireHeldUp(id: Int, x: Int, y: Int, generation: UInt64) {
        lock.lock()
        defer { unlockAndFlushLogs() }
        guard pendingGeneration == generation, pendingUpId == id else { return }
        pendingUpId = -1
        pendingUpToken = nil
        emit(.up, id, x, y, nowMs())
    }

    private func commitPendingUp(_ now: Int64) {
        let id = pendingUpId
        guard id >= 0 else { return }
        let x = pendingUpX, y = pendingUpY
        cancelPendingUp()
        emit(.up, id, x, y, now)
    }

    private func cancelPendingUp() {
        pendingUpToken?.cancel()
        pendingUpToken = nil
        pendingUpId = -1
        pendingGeneration &+= 1
    }
}
