// SPDX-License-Identifier: AGPL-3.0-or-later
// Bounded hand-off between an encoder (producer) and the :10920 pull loop (consumer).
//
// Policy (docs/spec/media-video.md, iOS recommendations):
// - Small capacity (default 3). On overflow the queue does NOT drop the oldest P-frame (that
//   corrupts decoding until the next IDR, Android's flaw): it flushes everything, closes the
//   keyframe gate and asks the producer for an IDR (`onKeyframeNeeded`).
// - Keyframe gate: after `resynchronize()` (REQ 112) or an overflow, non-keyframes are dropped
//   until the next keyframe arrives, so the first frame the dash decodes is always an IDR.
// - The most recent keyframe is cached (`lastKeyframe`) so a background "hold" can re-send a
//   complete picture when the encoder is unavailable (never re-send P-frames). The cache belongs
//   to one media session and one canvas: `reopen()` clears it and producers call
//   `invalidateKeyframe()` when the canvas changes, so a stale or wrong-size IDR is never re-sent
//   (MP-3; RLY 17 and the encoded size must agree, media-video.md §9.2).

import Foundation

public final class FrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EncodedFrame] = []
    private var gateClosed = true
    private var waiters: [(id: UInt64, cont: CheckedContinuation<EncodedFrame?, Never>)] = []
    private var nextWaiterId: UInt64 = 1
    private var closed = false
    private var _lastKeyframe: EncodedFrame?
    private var _overflowCount = 0
    private var _gatedDrops = 0

    public let capacity: Int
    /// Called (outside the lock) when the queue needs an IDR from the producer.
    public var onKeyframeNeeded: (@Sendable () -> Void)?

    public init(capacity: Int = 3) {
        self.capacity = max(1, capacity)
    }

    /// Number of overflows since creation (link-quality signal for the adaptive policy).
    public var overflowCount: Int { lock.lock(); defer { lock.unlock() }; return _overflowCount }
    /// Frames dropped while the keyframe gate was closed.
    public var gatedDropCount: Int { lock.lock(); defer { lock.unlock() }; return _gatedDrops }
    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    public var lastKeyframe: EncodedFrame? { lock.lock(); defer { lock.unlock() }; return _lastKeyframe }
    public var isGateClosed: Bool { lock.lock(); defer { lock.unlock() }; return gateClosed }

    /// Producer side.
    public func push(_ frame: EncodedFrame) {
        var needKey = false
        var deliver: (CheckedContinuation<EncodedFrame?, Never>, EncodedFrame)?
        lock.lock()
        if closed { lock.unlock(); return }
        if frame.isKeyframe { _lastKeyframe = frame }
        if gateClosed {
            if frame.isKeyframe {
                gateClosed = false
            } else {
                _gatedDrops += 1
                lock.unlock()
                return
            }
        }
        if !waiters.isEmpty, items.isEmpty {
            let w = waiters.removeFirst()
            deliver = (w.cont, frame)
        } else if items.count >= capacity {
            // GOP-safe overflow: flush, gate, ask for an IDR. A keyframe itself restarts the GOP.
            _overflowCount += 1
            items.removeAll()
            if frame.isKeyframe {
                items.append(frame)
            } else {
                gateClosed = true
                needKey = true
            }
        } else {
            items.append(frame)
        }
        lock.unlock()
        if let (cont, f) = deliver { cont.resume(returning: f) }
        if needKey { onKeyframeNeeded?() }
    }

    /// REQ_RV_DATA_START: close the gate BEFORE flushing (so a P-frame racing in is dropped),
    /// flush, then ask for an IDR.
    public func resynchronize() {
        lock.lock()
        gateClosed = true
        items.removeAll()
        lock.unlock()
        onKeyframeNeeded?()
    }

    public func flush() {
        lock.lock(); items.removeAll(); lock.unlock()
    }

    /// Consumer side: next frame, or nil after `timeout` seconds (or when closed).
    public func next(timeout: TimeInterval) async -> EncodedFrame? {
        let id: UInt64 = lock.withLock { () -> UInt64 in
            let v = nextWaiterId
            nextWaiterId &+= 1
            return v
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<EncodedFrame?, Never>) in
            lock.lock()
            if !items.isEmpty {
                let f = items.removeFirst()
                lock.unlock()
                cont.resume(returning: f)
                return
            }
            if closed {
                lock.unlock()
                cont.resume(returning: nil)
                return
            }
            waiters.append((id, cont))
            lock.unlock()
            let nanos = UInt64(max(0, timeout) * 1_000_000_000)
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                self?.expireWaiter(id)
            }
        }
    }

    private func expireWaiter(_ id: UInt64) {
        lock.lock()
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        let w = waiters.remove(at: idx)
        lock.unlock()
        w.cont.resume(returning: nil)
    }

    /// Wakes all waiters with nil and rejects further frames.
    public func close() {
        lock.lock()
        closed = true
        items.removeAll()
        let ws = waiters
        waiters.removeAll()
        lock.unlock()
        for w in ws { w.cont.resume(returning: nil) }
    }

    /// Re-opens a closed queue (new media session) with the gate closed and no cached keyframe.
    public func reopen() {
        lock.lock()
        closed = false
        gateClosed = true
        items.removeAll()
        _lastKeyframe = nil
        lock.unlock()
    }

    /// Forgets the cached keyframe (canvas change, session end): it must never be re-sent.
    public func invalidateKeyframe() {
        lock.lock(); _lastKeyframe = nil; lock.unlock()
    }
}
