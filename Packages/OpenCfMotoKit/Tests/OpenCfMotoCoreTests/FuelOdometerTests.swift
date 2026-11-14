// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the GPS km counter — plausibility filter, bridge, gap (rule G), resume, 3-strike re-anchor,
// blind spells, rounding and monotonicity.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class FuelOdometerTests: XCTestCase {
    static let baseLat = 4.6
    static let baseLon = -74.08
    /// Metres per degree of latitude near the base (only used to place fixes; distances are measured).
    static let mPerDegLat = 110_574.0

    private func fix(_ timeMs: Int64, north: Double, speed: Double? = 10, acc: Double? = 5) -> LocationFix {
        LocationFix(lat: Self.baseLat + north / Self.mPerDegLat, lon: Self.baseLon, speedMps: speed, accuracyM: acc, timeMs: timeMs)
    }

    private func d(_ a: LocationFix, _ b: LocationFix) -> Double {
        Double(TripGeodesy.androidDistance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon))
    }

    private let t0: Int64 = 1_793_000_000_000

    func testStartAndOneSecondSteps() {
        var o = FuelOdometer()
        XCTAssertFalse(o.isStreaming)
        XCTAssertEqual(o.ingest(fix(t0, north: 0)), .started)
        XCTAssertTrue(o.isStreaming)
        var expected = 0.0
        var prev = fix(t0, north: 0)
        for i in 1 ... 10 {
            let f = fix(t0 + Int64(i) * 1000, north: Double(i) * 10)
            XCTAssertEqual(o.ingest(f), .added(metres: d(prev, f)))
            expected += d(prev, f)
            prev = f
        }
        XCTAssertEqual(o.state.totalKm, expected / 1000, accuracy: 1e-9)
        XCTAssertEqual(o.state.totalKm, 0.1, accuracy: 0.001)
        XCTAssertEqual(o.state.last, FuelOdometer.anchor(prev))
    }

    func testStationaryAndSpeedFallback() {
        var o = FuelOdometer()
        o.ingest(fix(t0, north: 0))
        XCTAssertEqual(o.ingest(fix(t0 + 1000, north: 0.5, speed: 0.3)), .stationary)
        XCTAssertEqual(o.state.totalKm, 0)
        // speed unknown: the measured v (10 m/s) decides
        let a = fix(t0 + 1000, north: 0.5, speed: 0.3)
        let b = fix(t0 + 2000, north: 10.5, speed: nil)
        XCTAssertEqual(o.ingest(b), .added(metres: d(a, b)))
        // speed unknown and a crawl of 0.5 m/s → stationary
        XCTAssertEqual(o.ingest(fix(t0 + 3000, north: 11, speed: nil)), .stationary)
    }

    func testInaccurateAndInvalidFixesAreRejected() {
        var o = FuelOdometer()
        o.ingest(fix(t0, north: 0))
        XCTAssertEqual(o.ingest(fix(t0 + 1000, north: 10, acc: nil)), .rejected(.inaccurate))
        XCTAssertEqual(o.ingest(fix(t0 + 1000, north: 10, acc: 60)), .rejected(.inaccurate))
        XCTAssertEqual(o.ingest(fix(t0 + 1000, north: 10, acc: 1500)), .rejected(.inaccurate))
        XCTAssertEqual(o.ingest(fix(t0 + 1000, north: 10, acc: .nan)), .rejected(.inaccurate))
        XCTAssertEqual(o.ingest(fix(t0 + 1000, north: 10, acc: -1)), .rejected(.inaccurate))
        XCTAssertEqual(o.ingest(LocationFix(lat: .nan, lon: 1, accuracyM: 5, timeMs: t0 + 1000)), .rejected(.invalidCoordinate))
        XCTAssertEqual(o.ingest(LocationFix(lat: 91, lon: 1, accuracyM: 5, timeMs: t0 + 1000)), .rejected(.invalidCoordinate))
        XCTAssertEqual(o.ingest(LocationFix(lat: 1, lon: 181, accuracyM: 5, timeMs: t0 + 1000)), .rejected(.invalidCoordinate))
        XCTAssertEqual(o.ingest(LocationFix(lat: 0, lon: 0, accuracyM: 5, timeMs: t0 + 1000)), .rejected(.invalidCoordinate))
        XCTAssertEqual(o.state.totalKm, 0)
        XCTAssertEqual(o.ingest(fix(t0 + 1000, north: 10, acc: 50)), .added(metres: d(fix(t0, north: 0), fix(t0 + 1000, north: 10))))
    }

    func testDuplicatesAndOutOfOrderFixesNeverDoubleCount() {
        var o = FuelOdometer()
        o.ingest(fix(t0, north: 0))
        let f = fix(t0 + 1000, north: 10)
        XCTAssertEqual(o.ingest(f), .added(metres: d(fix(t0, north: 0), f)))
        let total = o.state.totalKm
        XCTAssertEqual(o.ingest(f), .rejected(.outOfOrder), "the same fix again")
        XCTAssertEqual(o.ingest(fix(t0 + 500, north: 5)), .rejected(.outOfOrder))
        XCTAssertEqual(o.state.totalKm, total)
        // an accepted fix resets the strike count
        XCTAssertEqual(o.ingest(fix(t0 + 2000, north: 20)), .added(metres: d(f, fix(t0 + 2000, north: 20))))
        XCTAssertEqual(o.ingest(fix(t0 + 2000, north: 20)), .rejected(.outOfOrder))
        XCTAssertEqual(o.ingest(fix(t0 + 2000, north: 20)), .rejected(.outOfOrder))
        XCTAssertEqual(o.ingest(fix(t0 + 2000, north: 20)), .resumed, "the 3rd strike re-anchors, adding nothing")
    }

    func testBridgeWindow() {
        var o = FuelOdometer()
        let a = fix(t0, north: 0)
        o.ingest(a)
        let b = fix(t0 + 30_000, north: 600) // 30 s at 20 m/s
        XCTAssertEqual(o.ingest(b), .added(metres: d(a, b)))
        let c = fix(t0 + 60_000, north: 615) // 30 s at 0.5 m/s
        XCTAssertEqual(o.ingest(c), .stationary)
        XCTAssertEqual(o.state.totalKm, d(a, b) / 1000, accuracy: 1e-9)
    }

    func testImplausibleJumpsAndTheReAnchor() {
        var o = FuelOdometer()
        o.ingest(fix(t0, north: 0))
        XCTAssertEqual(o.ingest(fix(t0 + 2000, north: 5000)), .rejected(.implausibleJump))
        XCTAssertEqual(o.ingest(fix(t0 + 3000, north: 5010)), .rejected(.implausibleJump))
        XCTAssertEqual(o.ingest(fix(t0 + 4000, north: 5020)), .resumed, "3 in a row: re-anchor")
        XCTAssertEqual(o.state.totalKm, 0)
        let next = fix(t0 + 5000, north: 5030)
        XCTAssertEqual(o.ingest(next), .added(metres: d(fix(t0 + 4000, north: 5020), next)))
    }

    func testThePhoneClockSteppingBackReAnchorsInsteadOfFreezing() {
        var o = FuelOdometer()
        o.ingest(fix(t0, north: 0))
        o.ingest(fix(t0 + 1000, north: 10))
        let back = t0 - 3_600_000
        XCTAssertEqual(o.ingest(fix(back, north: 20)), .rejected(.outOfOrder))
        XCTAssertEqual(o.ingest(fix(back + 1000, north: 30)), .rejected(.outOfOrder))
        XCTAssertEqual(o.ingest(fix(back + 2000, north: 40)), .resumed)
        let before = o.state.totalKm
        XCTAssertEqual(o.ingest(fix(back + 3000, north: 50)), .added(metres: d(fix(back + 2000, north: 40), fix(back + 3000, north: 50))))
        XCTAssertGreaterThan(o.state.totalKm, before)
    }

    func testRuleGInStream() {
        // 3 min, 600 m: about where it was
        var a = FuelOdometer()
        a.ingest(fix(t0, north: 0))
        XCTAssertEqual(a.ingest(fix(t0 + 180_000, north: 600)), .resumed)
        XCTAssertEqual(a.state.totalKm, 0)
        // a 3 min tunnel with a 3 km chord: bridged, not aged
        var b = FuelOdometer()
        b.ingest(fix(t0, north: 0))
        let out = fix(t0 + 180_000, north: 3000)
        XCTAssertEqual(b.ingest(out), .bridged(chordMetres: d(fix(t0, north: 0), out)))
        XCTAssertEqual(b.state.gapsMs, [])
        XCTAssertEqual(b.state.totalKm, d(fix(t0, north: 0), out) / 1000, accuracy: 1e-9)
        XCTAssertEqual(b.state.gapKm, b.state.totalKm, accuracy: 1e-9)
        // 6 min / 1.5 km: up to 10.4 km unseen → gap
        var c = FuelOdometer()
        c.ingest(fix(t0, north: 0))
        let g = fix(t0 + 360_000, north: 1500)
        XCTAssertEqual(c.ingest(g), .gap(chordMetres: d(fix(t0, north: 0), g)))
        XCTAssertEqual(c.state.gapsMs, [t0 + 360_000])
        XCTAssertEqual(c.state.gapKm, d(fix(t0, north: 0), g) / 1000, accuracy: 1e-9)
        XCTAssertEqual(c.state.lastGapAtMs, t0 + 360_000)
        // 20 min / 10 km: always a gap
        var e = FuelOdometer()
        e.ingest(fix(t0, north: 0))
        if case .gap = e.ingest(fix(t0 + 1_200_000, north: 10_000)) {} else { XCTFail("20 min must age") }
    }

    func testResumeAfterEndStream() {
        // 5 min, 6 km later (v 20 m/s, excess 3.9 km): bridged
        var a = FuelOdometer()
        a.ingest(fix(t0, north: 0))
        a.endStream(atMs: t0 + 1000)
        XCTAssertFalse(a.isStreaming)
        let r = fix(t0 + 300_000, north: 6000)
        guard case let .bridged(chord) = a.ingest(r) else { return XCTFail("expected a bridge") }
        XCTAssertEqual(chord, 6000, accuracy: 120, "from the ROUNDED anchor")
        // 5 min, 13 km (v 43 m/s > 40 on a resume): gap
        var b = FuelOdometer()
        b.ingest(fix(t0, north: 0))
        b.endStream(atMs: t0)
        if case .gap = b.ingest(fix(t0 + 300_000, north: 13_000)) {} else { XCTFail("a fast resume must age") }
        // 30 s later, 500 m away: a resume bridge from the rounded anchor (±80 m)
        var c = FuelOdometer()
        c.ingest(fix(t0, north: 0))
        c.endStream(atMs: t0)
        guard case let .added(m) = c.ingest(fix(t0 + 30_000, north: 500)) else { return XCTFail("expected added") }
        XCTAssertEqual(m, 500, accuracy: 80)
        // no anchor at all → started
        var fresh = FuelOdometer()
        fresh.endStream(atMs: t0)
        XCTAssertEqual(fresh.ingest(fix(t0, north: 0)), .started)
        // a resume that did not move
        var still = FuelOdometer()
        still.ingest(fix(t0, north: 0))
        still.endStream(atMs: t0)
        XCTAssertEqual(still.ingest(fix(t0 + 60_000, north: 20)), .resumed)
    }

    func testARelaunchRejectsAStaleFirstFix() throws {
        var o = FuelOdometer()
        o.ingest(fix(t0, north: 0))
        o.ingest(fix(t0 + 1000, north: 10))
        let data = try JSONEncoder().encode(o.state)
        var relaunched = FuelOdometer(state: try JSONDecoder().decode(FuelOdometerState.self, from: data))
        XCTAssertEqual(relaunched.state, o.state)
        XCTAssertEqual(relaunched.ingest(fix(t0 + 500, north: 5)), .rejected(.outOfOrder), "iOS's cached fix")
        let next = fix(t0 + 2000, north: 20)
        guard case .added = relaunched.ingest(next) else { return XCTFail("a fresh fix resumes") }
    }

    func testBlindSpells() {
        var o = FuelOdometer()
        o.noteBlind(atMs: t0)
        o.noteBlind(atMs: t0 + 5000)
        XCTAssertEqual(o.state.openBlindSinceMs, t0, "opens once")
        XCTAssertEqual(o.ingest(fix(t0 + 6000, north: 0, acc: 1500)), .rejected(.inaccurate))
        XCTAssertEqual(o.state.openBlindSinceMs, t0, "a rejected fix keeps it open")
        o.ingest(fix(t0 + 7000, north: 0))
        XCTAssertNil(o.state.openBlindSinceMs, "an accepted fix closes it")
        XCTAssertEqual(o.state.noGpsMs, [])
        // ended ≥ 2 min after it opened → recorded
        o.noteBlind(atMs: t0 + 10_000)
        o.endStream(atMs: t0 + 10_000 + FuelOdometer.blindAfterMs)
        XCTAssertEqual(o.state.noGpsMs, [t0 + 10_000])
        XCTAssertNil(o.state.openBlindSinceMs)
        XCTAssertEqual(o.state.lastNoGpsAtMs, t0 + 10_000)
        // < 2 min → dropped
        o.noteBlind(atMs: t0 + 500_000)
        o.endStream(atMs: t0 + 500_000 + FuelOdometer.blindAfterMs - 1)
        XCTAssertEqual(o.state.noGpsMs, [t0 + 10_000])
        XCTAssertNil(o.state.openBlindSinceMs)
    }

    func testLastUnseenIsTheNewestMark() {
        var s = FuelOdometerState()
        XCTAssertNil(s.lastUnseenAtMs)
        s.gapsMs = [10, 30]
        s.noGpsMs = [20]
        XCTAssertEqual(s.lastUnseenAtMs, 30)
        s.noGpsMs = [40]
        XCTAssertEqual(s.lastUnseenAtMs, 40)
    }

    func testMarksAreCappedAt20() {
        var o = FuelOdometer()
        var t = t0
        o.ingest(fix(t, north: 0))
        for i in 1 ... 25 {
            t += 1_200_000
            _ = o.ingest(fix(t, north: Double(i) * 10_000))
            o.noteBlind(atMs: t)
            o.endStream(atMs: t + FuelOdometer.blindAfterMs)
            o.ingest(fix(t + FuelOdometer.blindAfterMs + 1, north: Double(i) * 10_000))
            t += FuelOdometer.blindAfterMs + 1
        }
        XCTAssertEqual(o.state.gapsMs.count, FuelOdometer.maxStoredGaps)
        XCTAssertEqual(o.state.noGpsMs.count, FuelOdometer.maxStoredGaps)
        XCTAssertEqual(o.state.gapsMs, o.state.gapsMs.sorted(), "oldest first")
    }

    func testTheTotalIsMonotonicOverARandomTrack() {
        var rng = FuelSplitMix64(seed: 42)
        var o = FuelOdometer()
        var t = t0
        var north = 0.0
        var last = 0.0
        for _ in 0 ..< 3000 {
            t += Int64(rng.next() % 9000) - 1500 // sometimes out of order
            north += Double(rng.next() % 400) - 50
            let acc = rng.next() % 10 == 0 ? 200.0 : 8.0
            let speed: Double? = rng.next() % 5 == 0 ? nil : Double(rng.next() % 30)
            o.ingest(fix(t, north: north, speed: speed, acc: acc))
            if rng.next() % 50 == 0 { o.endStream(atMs: t) }
            XCTAssertGreaterThanOrEqual(o.state.totalKm, last)
            XCTAssertTrue(o.state.totalKm.isFinite)
            last = o.state.totalKm
        }
        XCTAssertGreaterThan(o.state.totalKm, 0)
    }

    func testAnchorRounding() {
        let a = FuelOdometer.anchor(LocationFix(lat: 4.65125, lon: -74.09449, timeMs: 7))
        XCTAssertEqual(a.lat, 4.651, accuracy: 1e-12)
        XCTAssertEqual(a.lon, -74.094, accuracy: 1e-12)
        XCTAssertEqual(a.atMs, 7)
        // exact halves (0.0625 × 1000 = 62.5) round away from zero
        XCTAssertEqual(FuelOdometer.anchor(LocationFix(lat: 0.0625, lon: -0.0625, timeMs: 0)).lat, 0.063, accuracy: 1e-12)
        XCTAssertEqual(FuelOdometer.anchor(LocationFix(lat: 0.0625, lon: -0.0625, timeMs: 0)).lon, -0.063, accuracy: 1e-12)
    }

    func testRaiseTotalOnlyGrowsAndMarksAGap() {
        var o = FuelOdometer()
        o.raiseTotal(to: 1311.4, gapAtMs: t0)
        XCTAssertEqual(o.state.totalKm, 1311.4)
        XCTAssertEqual(o.state.gapsMs, [t0])
        o.raiseTotal(to: 1000, gapAtMs: t0 + 1)
        XCTAssertEqual(o.state.totalKm, 1311.4)
        XCTAssertEqual(o.state.gapsMs, [t0])
    }

    func testStateJSON() throws {
        var s = FuelOdometerState()
        s.totalKm = 1402.37
        s.gapKm = 3.1
        s.gapsMs = [1_793_200_000_000]
        s.last = FuelOdometerAnchor(lat: 4.659, lon: -74.094, atMs: 1_793_461_320_000)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let json = String(decoding: try e.encode(s), as: UTF8.self)
        XCTAssertEqual(json, #"{"gapKm":3.1,"gapsMs":[1793200000000],"last":{"atMs":1793461320000,"lat":4.659,"lon":-74.094},"noGpsMs":[],"totalKm":1402.37,"v":1}"#)
        XCTAssertEqual(try JSONDecoder().decode(FuelOdometerState.self, from: Data(json.utf8)), s)
        XCTAssertNil(try? JSONDecoder().decode(FuelOdometerState.self, from: Data(#"{"totalKm":1,"v":2}"#.utf8)))
        XCTAssertNil(try? JSONDecoder().decode(FuelOdometerState.self, from: Data(#"{"totalKm":-1,"v":1}"#.utf8)))
    }
}

/// Deterministic PRNG for the property tests.
struct FuelSplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
