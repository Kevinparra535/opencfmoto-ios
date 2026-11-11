// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) LapTimer.kt, NightPrefs.kt
//
// Flying start/finish lap timer (docs/spec/navigation-dash.md §13) and the day/night map policy
// (§10.3).

import Foundation

/// Flying-start / flying-finish lap timer: arm at the rider's position, ride out (> 55 m), every
/// later pass within 25 m of the gate (≥ 15 s after the previous crossing) closes a lap.
public struct LapTimer: Sendable, Equatable {
    public struct Gate: Sendable, Equatable {
        public var lat: Double
        public var lon: Double
    }

    public struct Hud: Sendable, Equatable {
        public var on: Bool
        /// Armed but the clock has not started yet ("Pass start/finish").
        public var waiting: Bool
        public var lap: Int
        public var currentMs: Int64
        public var lastMs: Int64?
        public var bestMs: Int64?
        public var finished: Int
    }

    public static let crossM = 25.0
    public static let exitM = 55.0
    public static let minLapMs: Int64 = 15_000

    public private(set) var gate: Gate?
    private var away = false
    private var lapStartMs: Int64 = 0
    private var lap = 0
    private var lastMs: Int64?
    private var bestMs: Int64?
    private var finished = 0
    private var lastCrossMs: Int64 = 0

    public init() {}

    public var isOn: Bool { gate != nil }

    public mutating func arm(lat: Double, lon: Double) {
        self = LapTimer()
        gate = Gate(lat: lat, lon: lon)
    }

    public mutating func stop() { self = LapTimer() }

    /// Call on each GPS fix (`nowMs` = fix time if > 0 else wall clock). Returns true when a lap
    /// just finished.
    public mutating func onFix(lat: Double, lon: Double, nowMs: Int64) -> Bool {
        guard let g = gate else { return false }
        let d = Self.meters(lat, lon, g.lat, g.lon)
        if d > Self.exitM {
            away = true
            return false
        }
        if !away || d > Self.crossM { return false }
        if lastCrossMs > 0 && nowMs - lastCrossMs < Self.minLapMs { return false }
        away = false
        lastCrossMs = nowMs
        if lapStartMs == 0 {
            lapStartMs = nowMs
            lap = 1
            return false
        }
        let elapsed = max(nowMs - lapStartMs, 0)
        lastMs = elapsed
        bestMs = min(bestMs ?? elapsed, elapsed)
        finished += 1
        lapStartMs = nowMs
        lap = finished + 1
        return true
    }

    public func hud(nowMs: Int64) -> Hud {
        guard gate != nil else {
            return Hud(on: false, waiting: false, lap: 0, currentMs: 0, lastMs: nil, bestMs: nil, finished: 0)
        }
        let waiting = lapStartMs == 0
        let current = waiting ? 0 : max(nowMs - lapStartMs, 0)
        return Hud(on: true, waiting: waiting, lap: lap, currentMs: current, lastMs: lastMs, bestMs: bestMs, finished: finished)
    }

    /// `"%d:%02d.%02d"` (minutes, seconds, centiseconds), negative clamped to 0.
    public static func formatMs(_ ms: Int64) -> String {
        let total = max(ms, 0)
        let m = total / 60_000
        let s = (total % 60_000) / 1000
        let cs = (total % 1000) / 10
        return "\(m):" + NavNumberFormat.padded(Int(s), width: 2) + "." + NavNumberFormat.padded(Int(cs), width: 2)
    }

    /// Lap-timer haversine (`LapTimer.meters`, evaluated with Android's operator order).
    public static func meters(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let r = 6_371_000.0
        let p1 = GeoMath.toRadians(aLat)
        let p2 = GeoMath.toRadians(bLat)
        let dp = GeoMath.toRadians(bLat - aLat)
        let dl = GeoMath.toRadians(bLon - aLon)
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1.0, sqrt(h)))
    }

    /// Lap card lines: line 1 "Pass start/finish" or "LAP <n>  <m:ss.cc>", line 2
    /// "LAST <…|—>   BEST <…|—>"; nil when the timer is off.
    public func cardLines(nowMs: Int64, strings: NavStrings = .english) -> (current: String, meta: String)? {
        let h = hud(nowMs: nowMs)
        guard h.on else { return nil }
        let current = h.waiting ? strings.lapPassStartFinish : strings.lapCurrent(h.lap, Self.formatMs(h.currentMs))
        let last = h.lastMs.map(Self.formatMs) ?? "—"
        let best = h.bestMs.map(Self.formatMs) ?? "—"
        return (current, strings.lapMeta(last: last, best: best))
    }
}

/// Day / night map policy. DAY → day, NIGHT → night. AUTO:
/// - Android (`NightPrefs.isNightNow`, kept for parity and its tests): phone dark mode OR local hour < 7 OR
///   hour ≥ 19 (`isNight(theme:phoneDarkMode:…)`);
/// - iOS (P0, D06): the sun at the rider's position — night from sunset to sunrise (the sun's upper edge
///   below the horizon, so civil twilight is already night on the dash), computed on the phone from the GPS
///   fix and the clock (`SunPosition`); without any position yet, the clock rule 19:00–06:59. The phone's
///   dark mode never decides: a phone in dark mode no longer gets a dark map at noon, and a winter dusk
///   before 19:00 no longer stays on the day map (`isNight(theme:position:…)`).
public enum NightModePolicy {
    /// iOS re-evaluates AUTO at least this often (Android's built-in map never flips by itself).
    public static let reevaluationInterval: TimeInterval = 60
    /// Sun elevation (degrees) below which AUTO is night: sunset / sunrise (the upper edge of the disc
    /// on the horizon with standard refraction).
    public static let sunsetElevationDeg = -0.833

    public static func isNight(theme: MapTheme, phoneDarkMode: Bool, hour: Int) -> Bool {
        switch theme {
        case .day: return false
        case .night: return true
        case .auto: return phoneDarkMode || hour < 7 || hour >= 19
        }
    }

    public static func isNight(theme: MapTheme, phoneDarkMode: Bool, date: Date, timeZone: TimeZone = .current) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return isNight(theme: theme, phoneDarkMode: phoneDarkMode, hour: cal.component(.hour, from: date))
    }

    /// iOS AUTO (P0, D06): the sun at `position` (the rider's last GPS fix) at `date`; with no usable
    /// position, the clock rule (local hour < 7 or ≥ 19 in `timeZone`). The phone's dark mode plays no part.
    public static func isNight(theme: MapTheme, position: GeoPoint?, date: Date, timeZone: TimeZone = .current) -> Bool {
        switch theme {
        case .day: return false
        case .night: return true
        case .auto:
            if let p = position, let e = SunPosition.elevationDeg(latitude: p.lat, longitude: p.lon, date: date) {
                return e < sunsetElevationDeg
            }
            return isNight(theme: .auto, phoneDarkMode: false, date: date, timeZone: timeZone)
        }
    }

    /// One-tap cycle AUTO → DAY → NIGHT → AUTO.
    public static func cycle(_ theme: MapTheme) -> MapTheme {
        switch theme {
        case .auto: return .day
        case .day: return .night
        case .night: return .auto
        }
    }
}

/// Re-evaluates `NightModePolicy` when the inputs change or at least every 60 s.
/// Thread-safe value semantics: keep one per renderer and call `evaluate` from any timer / frame.
public struct NightModeMonitor: Sendable, Equatable {
    public private(set) var isNight: Bool?
    private var lastEvaluatedAt: TimeInterval?
    private var lastTheme: MapTheme?
    private var lastDark: Bool?
    /// Whether the last evaluation had a position (the sun) or not (the clock rule).
    private var lastHadPosition: Bool?

    public init() {}

    /// Android rule (parity): returns the current night flag, recomputing it when the theme / dark mode
    /// changed or `interval` seconds elapsed since the last evaluation (monotonic `now`).
    @discardableResult
    public mutating func evaluate(theme: MapTheme, phoneDarkMode: Bool, date: Date, now: TimeInterval,
                                  timeZone: TimeZone = .current,
                                  interval: TimeInterval = NightModePolicy.reevaluationInterval) -> Bool {
        if let cur = isNight, let at = lastEvaluatedAt, lastTheme == theme, lastDark == phoneDarkMode, lastHadPosition == nil,
           now - at < interval {
            return cur
        }
        let v = NightModePolicy.isNight(theme: theme, phoneDarkMode: phoneDarkMode, date: date, timeZone: timeZone)
        isNight = v
        lastEvaluatedAt = now
        lastTheme = theme
        lastDark = phoneDarkMode
        lastHadPosition = nil
        return v
    }

    /// iOS rule (P0, D06): the sun at `position` (`NightModePolicy.isNight(theme:position:…)`), recomputed
    /// when the theme changed, a position appeared or went away, or `interval` seconds elapsed (the sun moves
    /// ¼° a minute: a 60-s step is a 1-minute late switch at most).
    @discardableResult
    public mutating func evaluate(theme: MapTheme, position: GeoPoint?, date: Date, now: TimeInterval,
                                  timeZone: TimeZone = .current,
                                  interval: TimeInterval = NightModePolicy.reevaluationInterval) -> Bool {
        let hasPosition = position != nil
        if let cur = isNight, let at = lastEvaluatedAt, lastTheme == theme, lastDark == nil, lastHadPosition == hasPosition,
           now - at < interval {
            return cur
        }
        let v = NightModePolicy.isNight(theme: theme, position: position, date: date, timeZone: timeZone)
        isNight = v
        lastEvaluatedAt = now
        lastTheme = theme
        lastDark = nil
        lastHadPosition = hasPosition
        return v
    }
}
