// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (P0-7): the process CPU load the background diagnostics log (`cpu=14%` in the
// `[bg]` and `[bg-probe]` lines) and the background budget reads. iOS can kill a background app for
// CPU use (logged limits: 60 % over 15 s, 80 % over 60 s, once 15 % over 60 s), so the field logs must
// show how close the app runs. Percent = process CPU time / wall time × 100: 100 % is one core fully
// busy (a multi-threaded process can read above 100).
//
// `getrusage(RUSAGE_SELF)` works on Darwin and Glibc (on Glibc the `who` argument is
// `__rusage_who_t(RUSAGE_SELF.rawValue)`).

import Foundation

/// Samples of the process CPU time against a monotonic wall clock, and averages over a window.
/// A value type: the engine keeps one on its render queue.
public struct ProcessCPUMeter: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        /// Monotonic wall-clock seconds (the engine's clock).
        public var time: TimeInterval
        /// Process CPU time (user + system) in seconds at `time`.
        public var cpuSeconds: TimeInterval

        public init(time: TimeInterval, cpuSeconds: TimeInterval) {
            self.time = time
            self.cpuSeconds = cpuSeconds
        }
    }

    /// Samples older than this (relative to the newest) are dropped.
    public let horizon: TimeInterval
    public private(set) var samples: [Sample] = []

    public init(horizon: TimeInterval = 120) {
        self.horizon = horizon
    }

    /// User + system CPU time of this process, in seconds (`getrusage(RUSAGE_SELF)`); nil if the
    /// call fails.
    public static func processCPUSeconds() -> TimeInterval? {
        nil // step-0 placeholder: K implements
    }

    /// Records the process CPU time now (`processCPUSeconds()`) at monotonic `now`; does nothing when
    /// it is unavailable. Call it every few seconds and before reading `percent`.
    public mutating func sample(now: TimeInterval) {
        guard let cpu = Self.processCPUSeconds() else { return }
        record(Sample(time: now, cpuSeconds: cpu))
    }

    /// Records a sample (tests feed synthetic ones). Samples must come in time order; a sample older
    /// than the newest is ignored.
    public mutating func record(_ sample: Sample) {
        _ = sample // step-0 placeholder: K implements
    }

    /// Average CPU % of one core between the newest sample (at or before `now`) and the newest sample at
    /// least `window` seconds older — or the oldest sample when none is that old (a shorter span, e.g.
    /// just after the app went to the background). nil with fewer than two samples or a span ≤ 0.
    public func percent(window: TimeInterval, now: TimeInterval) -> Double? {
        _ = (window, now)
        return nil // step-0 placeholder: K implements
    }
}
