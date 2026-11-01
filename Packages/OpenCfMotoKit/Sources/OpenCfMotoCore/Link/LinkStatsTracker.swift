// SPDX-License-Identifier: AGPL-3.0-or-later
// Media-plane counters (Android `framesSent`, `lastFrameAt`, plus iOS diagnostics:
// bytes, keyframes, missed pulls, pull rate). Shared by every media connection of a session.

import Foundation

public final class LinkStatsTracker: @unchecked Sendable {
    private let clock: MonotonicClock
    private let window: TimeInterval
    private let lock = NSLock()
    private var stats = LinkStats()
    private var framesSinceReset = 0
    private var pullTimes: [TimeInterval] = []
    /// When the oldest 114 that got no frame since the last frame sent (or reset) was given up.
    private var firstUnansweredAt: TimeInterval?

    /// - Parameter window: seconds over which `pullRate` is computed.
    public init(clock: MonotonicClock = SystemMonotonicClock(), window: TimeInterval = 5) {
        self.clock = clock
        self.window = max(0.001, window)
    }

    /// A REQ_RV_DATA_NEXT (114) arrived.
    public func recordPull() {
        let now = clock.now()
        lock.lock()
        pullTimes.append(now)
        trim(now)
        lock.unlock()
    }

    /// A frame was written to the dash. Returns the frame number since the last reset (Android
    /// `framesSent`, which restarts at 1 after every reconnect).
    @discardableResult
    public func recordFrameSent(wireBytes: Int, keyframe: Bool) -> Int {
        let now = clock.now()
        lock.lock()
        defer { lock.unlock() }
        stats.framesSent += 1
        stats.bytesSent += wireBytes
        if keyframe { stats.keyframesSent += 1 }
        stats.lastFrameAt = now
        framesSinceReset += 1
        firstUnansweredAt = nil
        return framesSinceReset
    }

    /// A 114 got no frame within the pull timeout (nothing was sent).
    public func recordMissedPull() {
        let now = clock.now()
        lock.lock()
        stats.missedPulls += 1
        if firstUnansweredAt == nil { firstUnansweredAt = now }
        lock.unlock()
    }

    /// Restart the per-(re)connection frame numbering (Android `framesSent = 0`).
    public func resetConnectionFrameCount() {
        lock.lock(); framesSinceReset = 0; firstUnansweredAt = nil; lock.unlock()
    }

    /// Monotonic time of the first 114 left without a frame since the last frame sent (or the last
    /// reset); nil while every pull got one. The watchdog's "never got a first frame" check: the
    /// dash pulls in lock-step, so after an unanswered 114 it may never pull again (MP-1).
    public var firstUnansweredPullAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return firstUnansweredAt }

    /// Frames sent since the last `resetConnectionFrameCount()`.
    public var framesSinceLastReset: Int { lock.lock(); defer { lock.unlock() }; return framesSinceReset }

    /// Monotonic time of the last frame sent.
    public var lastFrameAt: TimeInterval? { lock.lock(); defer { lock.unlock() }; return stats.lastFrameAt }

    /// Current counters with the pull rate over the window.
    public func snapshot() -> LinkStats {
        let now = clock.now()
        lock.lock()
        defer { lock.unlock() }
        trim(now)
        var s = stats
        s.pullRate = Double(pullTimes.count) / window
        return s
    }

    private func trim(_ now: TimeInterval) {
        let cutoff = now - window
        if let idx = pullTimes.firstIndex(where: { $0 > cutoff }) {
            if idx > 0 { pullTimes.removeFirst(idx) }
        } else {
            pullTimes.removeAll()
        }
    }
}
