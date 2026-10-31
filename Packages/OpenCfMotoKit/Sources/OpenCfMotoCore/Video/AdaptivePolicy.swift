// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AdaptiveVideoController.kt (AdaptivePolicy + controller)
//
// Power mode AUTO (media-video.md §8.2, §15.6): once per 5 s tick, thermal pressure and link
// congestion (encoder-queue overflows per tick) pull bitrate and fps down; the harsher of the two
// bitrate factors wins (not a product); fps follows thermal only. The link factor is AIMD:
// ×0.8 (floor 0.4) on ≥ 8 drops per tick, +0.05 (ceiling 1.0) otherwise. Bitrate floor 600 kbit/s
// (never above the base). Float32 arithmetic exactly like the Kotlin code.

import Foundation

/// Output of one `AdaptivePolicy.decide` step.
public struct AdaptiveDecision: Sendable, Equatable {
    public var bitrate: Int
    public var fps: Int
    public var linkFactor: Float
    public init(bitrate: Int, fps: Int, linkFactor: Float) {
        self.bitrate = bitrate
        self.fps = fps
        self.linkFactor = linkFactor
    }
}

public enum AdaptivePolicy {
    /// AIMD bounds and steps for the link factor.
    public static let linkMin: Float = 0.4
    public static let linkMax: Float = 1.0
    public static let linkDecrease: Float = 0.8
    public static let linkIncreaseStep: Float = 0.05
    /// Queue-overflow drops within one tick at/above which the link counts as congested.
    public static let dropCongestionThreshold = 8
    /// Absolute bitrate floor (bit/s).
    public static let minBitrate = 600_000
    /// The controller runs once per watchdog tick.
    public static let tickInterval: TimeInterval = 5

    /// Bitrate multiplier: none/light 1.0, moderate 0.8, severe 0.6, critical and above 0.5.
    public static func thermalBitrateFactor(_ level: ThermalLevel) -> Float {
        thermalBitrateFactor(status: level.rawValue)
    }

    /// Same, for a raw Android `PowerManager.THERMAL_STATUS_*` value (0 NONE … 6 SHUTDOWN).
    public static func thermalBitrateFactor(status: Int) -> Float {
        if status <= ThermalLevel.light.rawValue { return 1.0 }
        if status == ThermalLevel.moderate.rawValue { return 0.8 }
        if status == ThermalLevel.severe.rawValue { return 0.6 }
        return 0.5
    }

    /// fps cap: base when none/light, else min(base, 20 / 15 / 12) for moderate / severe / critical+.
    public static func thermalFpsCap(_ level: ThermalLevel, baseFps: Int) -> Int {
        thermalFpsCap(status: level.rawValue, baseFps: baseFps)
    }

    public static func thermalFpsCap(status: Int, baseFps: Int) -> Int {
        if status <= ThermalLevel.light.rawValue { return baseFps }
        if status == ThermalLevel.moderate.rawValue { return min(baseFps, 20) }
        if status == ThermalLevel.severe.rawValue { return min(baseFps, 15) }
        return min(baseFps, 12)
    }

    /// AIMD step: shrink hard on congestion, grow gently when clean.
    public static func nextLinkFactor(_ prev: Float, dropsThisTick: Int) -> Float {
        if dropsThisTick >= dropCongestionThreshold {
            return max(prev * linkDecrease, linkMin)
        }
        return min(prev + linkIncreaseStep, linkMax)
    }

    /// One deterministic adaptation step.
    public static func decide(baseBitrate: Int, baseFps: Int, thermal: ThermalLevel, prevLinkFactor: Float,
                              dropsThisTick: Int) -> AdaptiveDecision {
        decide(baseBitrate: baseBitrate, baseFps: baseFps, thermalStatus: thermal.rawValue,
               prevLinkFactor: prevLinkFactor, dropsThisTick: dropsThisTick)
    }

    public static func decide(baseBitrate: Int, baseFps: Int, thermalStatus: Int, prevLinkFactor: Float,
                              dropsThisTick: Int) -> AdaptiveDecision {
        let link = nextLinkFactor(prevLinkFactor, dropsThisTick: dropsThisTick)
        let factor = min(thermalBitrateFactor(status: thermalStatus), link)
        let raw = Int(AppJavaNumber.f2i(Float(baseBitrate) * factor))
        let floor = min(minBitrate, baseBitrate)
        let bitrate = min(max(raw, floor), baseBitrate)
        return AdaptiveDecision(bitrate: bitrate, fps: thermalFpsCap(status: thermalStatus, baseFps: baseFps), linkFactor: link)
    }
}

public extension ThermalLevel {
    /// iOS `ProcessInfo.ThermalState.rawValue` → Android level (media-video.md §15.6, cautious mapping):
    /// nominal(0) → none, fair(1) → moderate, serious(2) → severe, critical(3) → critical.
    static func fromProcessInfoThermalState(rawValue: Int) -> ThermalLevel {
        switch rawValue {
        case ..<1: return .none
        case 1: return .moderate
        case 2: return .severe
        default: return .critical
        }
    }

    /// Android log name (`none`, `light`, `moderate`, …).
    var androidName: String {
        switch self {
        case .none: return "none"
        case .light: return "light"
        case .moderate: return "moderate"
        case .severe: return "severe"
        case .critical: return "critical"
        case .emergency: return "emergency"
        case .shutdown: return "shutdown"
        }
    }
}

public extension PowerMode {
    /// Verbatim Android label (English, used in logs).
    var englishLabel: String {
        switch self {
        case .auto: return "Auto \u{2014} adapts to heat & signal"
        case .smooth: return "Smooth \u{2014} 30 fps (most battery)"
        case .balanced: return "Balanced \u{2014} 24 fps (recommended)"
        case .saver: return "Battery saver \u{2014} 20 fps (coolest)"
        }
    }
}

/// Stateful AUTO controller (`AdaptiveVideoController`): call `tick` every `AdaptivePolicy.tickInterval`
/// seconds with the live inputs and apply the returned changes (bitrate live via
/// `AverageBitRate`, fps as the render cap + `ExpectedFrameRate`). Thread-safe (`NSLock`).
public final class AdaptiveController: @unchecked Sendable {
    /// Changes to apply now (nil fields = unchanged).
    public struct Adjustment: Sendable, Equatable {
        public var bitrate: Int?
        public var fps: Int?
        public init(bitrate: Int? = nil, fps: Int? = nil) { self.bitrate = bitrate; self.fps = fps }
    }

    private let lock = NSLock()
    private var linkFactor = AdaptivePolicy.linkMax
    private var lastDropTotal = 0
    private var appliedBitrate = -1
    private var appliedFps = -1
    private var adapting = false
    private var last: AdaptiveDecision?

    public init() {}

    /// New session: forget link state, start fresh at the user's target.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        resetLocked()
    }

    private func resetLocked() {
        linkFactor = AdaptivePolicy.linkMax
        lastDropTotal = 0
        appliedBitrate = -1
        appliedFps = -1
        adapting = false
        last = nil
    }

    /// The current AIMD link factor.
    public var currentLinkFactor: Float { lock.lock(); defer { lock.unlock() }; return linkFactor }

    /// The last decision (nil before the first AUTO tick or after a reset).
    public var lastDecision: AdaptiveDecision? { lock.lock(); defer { lock.unlock() }; return last }

    /// One tick.
    /// - Parameters:
    ///   - powerMode: the bike's power mode. Not AUTO → if we were adapting, restore the base bitrate
    ///     and the mode's frame cap once, then stay out.
    ///   - baseBitrate: the bitrate the encoder was created with (quality multiplier included);
    ///     ≤ 0 (no encoder yet) → nothing.
    ///   - thermal: current thermal level.
    ///   - overflowTotal: cumulative queue-overflow count (e.g. `FrameQueue.overflowCount`).
    public func tick(powerMode: PowerMode, baseBitrate: Int, thermal: ThermalLevel, overflowTotal: Int) -> Adjustment? {
        lock.lock(); defer { lock.unlock() }
        if powerMode != .auto {
            guard adapting else { return nil }
            let restore = Adjustment(bitrate: baseBitrate > 0 ? baseBitrate : nil, fps: powerMode.frameCap)
            Log.i("adaptive", "AUTO off \u{2014} restored to \(powerMode.englishLabel)")
            resetLocked()
            return restore
        }
        guard baseBitrate > 0 else { return nil }
        let drops = max(overflowTotal - lastDropTotal, 0)
        lastDropTotal = overflowTotal
        let d = AdaptivePolicy.decide(baseBitrate: baseBitrate, baseFps: PowerMode.auto.frameCap, thermal: thermal,
                                      prevLinkFactor: linkFactor, dropsThisTick: drops)
        linkFactor = d.linkFactor
        last = d
        var adj = Adjustment()
        if d.bitrate != appliedBitrate {
            adj.bitrate = d.bitrate
            appliedBitrate = d.bitrate
            adapting = true
            let pct = Int(AppJavaNumber.f2i(linkFactor * 100))
            Log.i("adaptive", "thermal=\(thermal.androidName) drops/tick=\(drops) link=\(pct)% \u{2192} \(d.bitrate / 1000)kbps")
        }
        if d.fps != appliedFps {
            adj.fps = d.fps
            appliedFps = d.fps
            adapting = true
            Log.i("adaptive", "thermal=\(thermal.androidName) \u{2192} \(d.fps)fps")
        }
        return (adj.bitrate == nil && adj.fps == nil) ? nil : adj
    }
}
