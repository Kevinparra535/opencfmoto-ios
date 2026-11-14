// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the per-bike GPS km counter behind the range estimate (`fuel_odo_v1#<bikeId>`). The dash link
// carries no vehicle data (no fuel level, no odometer), so the app counts the km it SEES and the estimate
// says so («El indicador de la moto manda»). It is fed with every fix of a countable Connect / Mirror
// session (FuelModel), independently of trip logging and of TripRecorder's callbacks.
//
// Plausibility filter, bridge and gap (`ingest`), with d = TripGeodesy.androidDistance (metres), dt (ms):
// 1. coordinates finite, |lat| ≤ 90, |lon| ≤ 180, not (0, 0) — else rejected (invalidCoordinate);
// 2. accuracy known, finite, 0…50 m — else rejected (inaccurate: FuelModel opens a blind spell);
// 3. in-stream (the previous fix of the same stream is in memory):
//    dt ≤ 0 → rejected (outOfOrder: duplicates and late batched fixes never double-count);
//    dt ≤ 120 s and v > 70 m/s → rejected (implausibleJump);
//    1 ≤ dt ≤ 5 s (TripRecorder's window): moving (speed ?? v) ≥ 0.8 m/s → add d, else stationary;
//    5 s < dt ≤ 120 s (iOS batching, a short tunnel): v ≥ 0.8 → add the chord, else stationary
//      (TripRecorder drops these; the counter must not lose km to batching);
//    dt > 120 s → rule G;
// 4. resume (first fix of a stream: session start, after `endStream`, a relaunch), against the persisted
//    anchor rounded to 3 decimals (~110 m): none → started; not newer → rejected (outOfOrder: iOS often hands
//    a stale cached fix first); dt ≤ 120 s and v ≤ 70 → add d when v ≥ 0.8 (else resumed); otherwise rule G;
// 5. rule G (the bike may have moved unseen): v > 70 → rejected (implausibleJump); d < 1 km → resumed;
//    else the chord is ALWAYS added (a lower bound of the unseen ride) and it is a quiet bridge (not aged)
//    when dt ≤ 15 min, 33 m/s × dt − d ≤ 10 km, and (same stream or v ≤ 40 m/s); otherwise a gap (aged).
// 3-strike re-anchor: the 3rd consecutive outOfOrder / implausibleJump rejection is accepted as `resumed`
// (nothing added), so one bad fix or a phone clock stepping back cannot freeze the counter.
// Every accepted fix becomes the stream's previous fix and the anchor, and closes an open blind spell.
// The counter only grows.

import Foundation

/// The last accepted fix, rounded to 3 decimals (≈ 110 m): gap detection only.
public struct FuelOdometerAnchor: Sendable, Equatable, Codable {
    public var lat: Double
    public var lon: Double
    public var atMs: Int64
    public init(lat: Double, lon: Double, atMs: Int64) {
        self.lat = lat
        self.lon = lon
        self.atMs = atMs
    }
}

public struct FuelOdometerState: Sendable, Equatable, Codable {
    public static let version = 1
    public var v: Int
    /// Monotonic per bike, never reset.
    public var totalKm: Double
    /// Last accepted fix (rounded).
    public var last: FuelOdometerAnchor?
    /// Fix times of gaps that age the estimate (rule G), oldest first, ≤ 20.
    public var gapsMs: [Int64]
    /// Chord km added by rule G, aged or bridged (diagnostic).
    public var gapKm: Double
    /// Start times of blind spells closed without a resolving fix, ≤ 20.
    public var noGpsMs: [Int64]
    /// A blind spell in progress (no usable fix since then), nil = none.
    public var openBlindSinceMs: Int64?

    public init() {
        v = Self.version
        totalKm = 0
        last = nil
        gapsMs = []
        gapKm = 0
        noGpsMs = []
        openBlindSinceMs = nil
    }

    public var lastGapAtMs: Int64? { gapsMs.last }
    public var lastNoGpsAtMs: Int64? { noGpsMs.last }
    /// The newest gap or closed noGps mark (refuel entries are stamped with it).
    public var lastUnseenAtMs: Int64? { [lastGapAtMs, lastNoGpsAtMs].compactMap { $0 }.max() }

    enum CodingKeys: String, CodingKey { case v, totalKm, last, gapsMs, gapKm, noGpsMs, openBlindSinceMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        guard v == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "unsupported fuel odometer version \(v)")
        }
        totalKm = try c.decode(Double.self, forKey: .totalKm)
        last = try c.decodeIfPresent(FuelOdometerAnchor.self, forKey: .last)
        gapsMs = try c.decodeIfPresent([Int64].self, forKey: .gapsMs) ?? []
        gapKm = try c.decodeIfPresent(Double.self, forKey: .gapKm) ?? 0
        noGpsMs = try c.decodeIfPresent([Int64].self, forKey: .noGpsMs) ?? []
        openBlindSinceMs = try c.decodeIfPresent(Int64.self, forKey: .openBlindSinceMs)
        guard totalKm.isFinite, totalKm >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .totalKm, in: c, debugDescription: "bad fuel odometer total")
        }
    }
}

public enum FuelFixRejection: String, Sendable, Equatable { case invalidCoordinate, inaccurate, outOfOrder, implausibleJump }

public enum FuelOdometerStep: Sendable, Equatable {
    case rejected(FuelFixRejection), started, resumed, stationary, added(metres: Double)
    /// Rule G: the chord was added, NOT aged.
    case bridged(chordMetres: Double)
    /// Rule G: the chord was added and the estimate is aged until the next anchor.
    case gap(chordMetres: Double)

    public var isAccepted: Bool {
        if case .rejected = self { return false }
        return true
    }
}

public struct FuelOdometer: Sendable, Equatable {
    public static let minMovingSpeedMs: Double = Double(TripRecorder.minMovingSpeedMs)
    public static let segmentWindowMs: ClosedRange<Int64> = TripRecorder.segmentWindowMs
    public static let maxBridgeMs: Int64 = 120_000
    public static let maxAccuracyM = 50.0
    /// 252 km/h.
    public static let maxPlausibleSpeedMs = 70.0
    public static let gapMinM = 1_000.0
    /// 15 min: longer unseen spells always age.
    public static let quietBridgeMaxMs: Int64 = 900_000
    /// ≈ 120 km/h: the most the bike plausibly did unseen.
    public static let unseenSpeedMs = 33.0
    /// Aged when 33 m/s × dt − chord exceeds 10 km.
    public static let maxUnseenExcessM = 10_000.0
    /// A resume (no in-memory fix) bridges only up to 144 km/h.
    public static let resumeBridgeMaxSpeedMs = 40.0
    /// An open blind spell ages the estimate after 2 min.
    public static let blindAfterMs: Int64 = 120_000
    public static let reanchorAfterRejections = 3
    public static let maxStoredGaps = 20
    /// FuelModel persists a changed counter at most this often (fix time).
    public static let persistIntervalMs: Int64 = 15_000

    public private(set) var state: FuelOdometerState
    /// The previous accepted fix of the current stream (in memory only).
    private var previous: LocationFix?
    /// Consecutive outOfOrder / implausibleJump rejections (the 3-strike re-anchor).
    private var strikes = 0

    public init(state: FuelOdometerState = FuelOdometerState()) {
        self.state = state
    }

    /// True while a stream is running (a previous fix is in memory).
    public var isStreaming: Bool { previous != nil }

    /// Every accepted fix (any step but `.rejected`) also closes an open blind spell.
    @discardableResult
    public mutating func ingest(_ fix: LocationFix) -> FuelOdometerStep {
        guard fix.lat.isFinite, fix.lon.isFinite, abs(fix.lat) <= 90, abs(fix.lon) <= 180,
              !(fix.lat == 0 && fix.lon == 0) else { return .rejected(.invalidCoordinate) }
        guard let acc = fix.accuracyM, acc.isFinite, acc >= 0, acc <= Self.maxAccuracyM else {
            return .rejected(.inaccurate)
        }
        let step: FuelOdometerStep
        if let p = previous {
            step = inStream(fix, from: p)
        } else {
            step = resume(fix)
        }
        if case let .rejected(why) = step {
            guard why == .outOfOrder || why == .implausibleJump else { return step }
            strikes += 1
            guard strikes >= Self.reanchorAfterRejections else { return step }
            accept(fix)
            return .resumed
        }
        accept(fix)
        return step
    }

    private mutating func inStream(_ fix: LocationFix, from p: LocationFix) -> FuelOdometerStep {
        let dt = fix.timeMs - p.timeMs
        guard dt > 0 else { return .rejected(.outOfOrder) }
        let d = Self.distance(p.lat, p.lon, fix.lat, fix.lon)
        let v = d / (Double(dt) / 1000)
        if dt <= Self.maxBridgeMs, v > Self.maxPlausibleSpeedMs { return .rejected(.implausibleJump) }
        if Self.segmentWindowMs.contains(dt) {
            guard (fix.speedMps ?? v) >= Self.minMovingSpeedMs else { return .stationary }
            add(d)
            return .added(metres: d)
        }
        if dt <= Self.maxBridgeMs {
            guard v >= Self.minMovingSpeedMs else { return .stationary }
            add(d)
            return .added(metres: d)
        }
        return ruleG(fix, d: d, dt: dt, sameStream: true)
    }

    private mutating func resume(_ fix: LocationFix) -> FuelOdometerStep {
        guard let a = state.last else { return .started }
        guard fix.timeMs > a.atMs else { return .rejected(.outOfOrder) }
        let dt = fix.timeMs - a.atMs
        let d = Self.distance(a.lat, a.lon, fix.lat, fix.lon)
        let v = d / (Double(dt) / 1000)
        if dt <= Self.maxBridgeMs, v <= Self.maxPlausibleSpeedMs {
            guard v >= Self.minMovingSpeedMs else { return .resumed }
            add(d)
            return .added(metres: d)
        }
        return ruleG(fix, d: d, dt: dt, sameStream: false)
    }

    private mutating func ruleG(_ fix: LocationFix, d: Double, dt: Int64, sameStream: Bool) -> FuelOdometerStep {
        let v = d / (Double(dt) / 1000)
        if v > Self.maxPlausibleSpeedMs { return .rejected(.implausibleJump) }
        if d < Self.gapMinM { return .resumed }
        add(d)
        state.gapKm += d / 1000
        let excess = Self.unseenSpeedMs * Double(dt) / 1000 - d
        if dt <= Self.quietBridgeMaxMs, excess <= Self.maxUnseenExcessM, sameStream || v <= Self.resumeBridgeMaxSpeedMs {
            return .bridged(chordMetres: d)
        }
        state.gapsMs.append(fix.timeMs)
        if state.gapsMs.count > Self.maxStoredGaps { state.gapsMs.removeFirst(state.gapsMs.count - Self.maxStoredGaps) }
        return .gap(chordMetres: d)
    }

    private mutating func add(_ metres: Double) {
        guard metres.isFinite, metres > 0 else { return }
        state.totalKm += metres / 1000
    }

    private mutating func accept(_ fix: LocationFix) {
        previous = fix
        strikes = 0
        state.last = Self.anchor(fix)
        state.openBlindSinceMs = nil
    }

    /// Opens a blind spell at `atMs` unless one is open.
    public mutating func noteBlind(atMs: Int64) {
        if state.openBlindSinceMs == nil { state.openBlindSinceMs = atMs }
    }

    /// The stream of fixes stopped (session ended, parked, bike switched, removal): the next fix resumes
    /// against the anchor. An open blind spell at least `blindAfterMs` old at `atMs` is recorded in
    /// `noGpsMs`; any open spell is cleared.
    public mutating func endStream(atMs: Int64) {
        previous = nil
        strikes = 0
        if let open = state.openBlindSinceMs {
            if atMs - open >= Self.blindAfterMs {
                state.noGpsMs.append(open)
                if state.noGpsMs.count > Self.maxStoredGaps { state.noGpsMs.removeFirst(state.noGpsMs.count - Self.maxStoredGaps) }
            }
            state.openBlindSinceMs = nil
        }
    }

    /// Raises the total (counter consistency on load: never below the newest refuel entry) and records a gap
    /// at `atMs`, so the estimate shows aged instead of a silently full tank.
    public mutating func raiseTotal(to km: Double, gapAtMs atMs: Int64) {
        guard km.isFinite, km > state.totalKm else { return }
        state.totalKm = km
        state.gapsMs.append(atMs)
        if state.gapsMs.count > Self.maxStoredGaps { state.gapsMs.removeFirst(state.gapsMs.count - Self.maxStoredGaps) }
    }

    /// 3-decimal rounding (half away from zero).
    public static func anchor(_ fix: LocationFix) -> FuelOdometerAnchor {
        FuelOdometerAnchor(lat: round3(fix.lat), lon: round3(fix.lon), atMs: fix.timeMs)
    }

    private static func round3(_ x: Double) -> Double { (x * 1000).rounded(.toNearestOrAwayFromZero) / 1000 }

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let d = Double(TripGeodesy.androidDistance(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2))
        return d.isFinite ? d : 0
    }
}
