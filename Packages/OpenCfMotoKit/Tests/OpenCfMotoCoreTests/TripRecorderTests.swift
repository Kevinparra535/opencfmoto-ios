// SPDX-License-Identifier: AGPL-3.0-or-later
// TripRecorder.kt port (app-features.md §5.3 walkthrough and constants) with fix-timestamp dt.

import XCTest
@testable import OpenCfMotoCore

final class TripRecorderTests: XCTestCase {

    /// Distance oracle: fix i has lat = i; the distance from the previous fix is `table[i]`.
    private final class Oracle: @unchecked Sendable {
        var table: [Int: Float] = [:]
        func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Float { table[Int(lat2)] ?? 0 }
    }

    private func fix(_ i: Int, at t: Int64, speed: Double?) -> LocationFix {
        LocationFix(lat: Double(i), lon: 0, speedMps: speed, timeMs: t)
    }

    func testConstants() {
        XCTAssertEqual(TripRecorder.minMovingSpeedMs, 0.8)
        XCTAssertEqual(TripRecorder.idleSplitMs, 180_000)
        XCTAssertEqual(TripRecorder.minSaveDistanceM, 100)
        XCTAssertEqual(TripRecorder.minSaveTimeMs, 15_000)
        XCTAssertEqual(TripRecorder.segmentWindowMs, 1 ... 5000)
    }

    /// The §5.3 walkthrough table, row by row.
    func testWalkthroughTable() {
        let o = Oracle()
        let r = TripRecorder(wallClockMs: { 500 }, distance: { o.distance($0, $1, $2, $3) })
        XCTAssertTrue(r.start())
        // (now, gps speed, d, expected speedMs, distance, movingTime, max, points)
        let rows: [(Int64, Double?, Float, Float, Double, Int64, Float, Int)] = [
            (1000, 0.0, 0, 0, 0, 0, 0, 1),
            (2000, 5.0, 5.2, 5, 5.2, 1000, 5, 2),
            (3000, 12.0, 11.8, 12, 17.0, 2000, 12, 3),
            (9500, 13.0, 80.0, 13, 17.0, 2000, 13, 4),          // 6.5 s gap: not accumulated
            (10500, nil, 14.0, 14, 31.0, 3000, 14, 5),          // derived speed d/dt
            (11500, 0.5, 0.4, 0.5, 31.0, 3000, 14, 6),
            (190_500, 0.0, 0.3, 0, 31.0, 3000, 14, 7),          // exactly 180 000 ms: no split
            (191_500, 0.0, 0.2, 0, 0, 0, 0, 1),                 // split; 31 m leg discarded
            (192_500, 9.0, 9.1, 9, 9.1, 1000, 9, 2),            // new leg
        ]
        for (i, row) in rows.enumerated() {
            o.table[i] = row.2
            let saved = r.ingest(fix(i, at: row.0, speed: row.1))
            XCTAssertNil(saved, "row \(i)")
            let s = r.snapshot()
            XCTAssertEqual(r.currentPoints.last?.speedMs ?? -1, row.3, accuracy: 1e-6, "speed row \(i)")
            XCTAssertEqual(s.distanceMeters, row.4, accuracy: 1e-4, "distance row \(i)")
            XCTAssertEqual(s.movingTimeMs, row.5, "moving row \(i)")
            XCTAssertEqual(s.maxSpeedMs, row.6, accuracy: 1e-6, "max row \(i)")
            XCTAssertEqual(r.currentPoints.count, row.7, "points row \(i)")
            XCTAssertTrue(s.hasFix)
        }
        XCTAssertEqual(r.snapshot().speedKmh, 32)   // 9 m/s × 3.6 = 32.4 → 32
    }

    func testSaveRequiresDistanceTimeAndPoints() {
        let o = Oracle()
        var now: Int64 = 0
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("trips-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = TripStore(directory: tmp)
        let clock = Locked<Int64>(1_700_000_000_000)
        let r = TripRecorder(store: store, wallClockMs: { clock.current }, distance: { o.distance($0, $1, $2, $3) })
        let savedBox = Locked<[Trip]>([])
        r.onTripSaved = { t in savedBox.withLock { $0.append(t) } }
        r.start()
        // 16 fixes 1 s apart at 10 m/s, 10 m each → 150 m, 15 000 ms moving
        for i in 0 ..< 16 {
            o.table[i] = i == 0 ? 0 : 10
            now = 1_700_000_001_000 + Int64(i) * 1000
            r.ingest(fix(i, at: now, speed: 10))
        }
        XCTAssertEqual(r.snapshot().distanceMeters, 150, accuracy: 1e-9)
        XCTAssertEqual(r.snapshot().movingTimeMs, 15_000)
        clock.set(1_700_000_020_000)
        let trip = r.stopAndSave()
        XCTAssertNotNil(trip)
        XCTAssertEqual(trip?.id, "1700000000000")
        XCTAssertEqual(trip?.start, 1_700_000_000_000)
        XCTAssertEqual(trip?.end, 1_700_000_020_000)
        XCTAssertEqual(trip?.points.count, 16)
        XCTAssertEqual(trip?.points.first?.timeMs, 1_700_000_001_000)   // fix timestamps
        XCTAssertEqual(savedBox.current.count, 1)
        XCTAssertTrue(Log.shared.lines().contains { $0.tag == "trip" && $0.message == "saved ride 0.15 km in 00:00:15" })
        XCTAssertEqual(store.list().map(\.id), ["1700000000000"])
        XCTAssertFalse(r.isRecording)
        XCTAssertNil(r.stopAndSave())          // not recording
        XCTAssertFalse(r.snapshot().hasFix)
        XCTAssertEqual(r.snapshot().speedKmh, 0)

        // 14 s of moving is not enough
        r.start()
        for i in 0 ..< 15 {
            o.table[i] = i == 0 ? 0 : 10
            r.ingest(fix(i, at: 1_700_001_000_000 + Int64(i) * 1000, speed: 10))
        }
        XCTAssertEqual(r.snapshot().movingTimeMs, 14_000)
        XCTAssertNil(r.stopAndSave())
    }

    func testIdleSplitSavesLegAndContinues() {
        let o = Oracle()
        let r = TripRecorder(wallClockMs: { 1_000 }, distance: { o.distance($0, $1, $2, $3) })
        r.start()
        var t: Int64 = 10_000
        var i = 0
        for _ in 0 ..< 20 {  // 19 moving segments of 20 m
            o.table[i] = i == 0 ? 0 : 20
            r.ingest(fix(i, at: t, speed: 20))
            i += 1; t += 1000
        }
        let lastMove = t - 1000
        o.table[i] = 0
        XCTAssertNil(r.ingest(fix(i, at: lastMove + 180_000, speed: 0)))  // = 180 s: no split
        i += 1
        o.table[i] = 0
        let saved = r.ingest(fix(i, at: lastMove + 180_001, speed: 0))
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.start, 1_000)
        XCTAssertEqual(saved?.end, lastMove + 180_001)                 // split at the fix time
        XCTAssertEqual(saved?.distanceMeters ?? 0, 380, accuracy: 1e-9)
        XCTAssertEqual(saved?.movingTimeMs, 19_000)
        XCTAssertEqual(saved?.points.count, 21)                        // stationary points included
        XCTAssertTrue(r.isRecording)
        XCTAssertEqual(r.currentPoints.count, 1)                       // new leg starts with the triggering fix
        XCTAssertEqual(r.snapshot().distanceMeters, 0)
    }

    func testNoSplitWithoutAnyMovementOrDistance() {
        let r = TripRecorder(wallClockMs: { 0 }, distance: { _, _, _, _ in 0 })
        r.start()
        for k in 0 ..< 5 { r.ingest(LocationFix(lat: 1, lon: 1, speedMps: 0, timeMs: 1000 + Int64(k) * 100_000)) }
        XCTAssertEqual(r.currentPoints.count, 5)  // never moved since reset: points keep accumulating
    }

    func testBatchedFixesUseFixTimestamps() {
        // Fixes delivered in one burst: dt comes from timestamps, not delivery time.
        let r = TripRecorder(wallClockMs: { 0 }, distance: { _, _, _, _ in 10 })
        r.start()
        for k in 0 ..< 3 { r.ingest(LocationFix(lat: 0, lon: 0, speedMps: 10, timeMs: 5_000 + Int64(k) * 1000)) }
        XCTAssertEqual(r.snapshot().movingTimeMs, 2000)
        XCTAssertEqual(r.snapshot().distanceMeters, 20)
        // out-of-order / duplicate timestamps do not accumulate
        r.ingest(LocationFix(lat: 0, lon: 0, speedMps: 10, timeMs: 7_000))
        r.ingest(LocationFix(lat: 0, lon: 0, speedMps: 10, timeMs: 6_500))
        XCTAssertEqual(r.snapshot().movingTimeMs, 2000)
    }

    func testDiscardIgnoredFixesAndAccuracy() {
        let r = TripRecorder(wallClockMs: { 42 }, distance: { _, _, _, _ in 5 })
        XCTAssertNil(r.ingest(LocationFix(lat: 0, lon: 0, timeMs: 1)))     // not recording
        XCTAssertFalse(r.snapshot().hasFix)
        r.start()
        r.ingest(LocationFix(lat: 0, lon: 0, speedMps: 3, accuracyM: 4.9, timeMs: 1000))
        XCTAssertEqual(r.snapshot().accuracyM, 4)
        XCTAssertEqual(r.snapshot().speedKmh, 10)  // 3 × 3.6 = 10.8 → 10
        r.ingest(LocationFix(lat: 0, lon: 0, speedMps: nil, timeMs: 1500))  // derived 5 / 0.5 = 10 m/s
        XCTAssertEqual(r.currentPoints.last?.speedMs, 10)
        XCTAssertEqual(r.snapshot().accuracyM, 0)
        r.discard()
        XCTAssertFalse(r.isRecording)
        XCTAssertEqual(r.currentPoints.count, 0)
        XCTAssertEqual(r.snapshot(), TripRecorder.Stats())
    }

    func testStatsCallback() {
        let r = TripRecorder(wallClockMs: { 0 }, distance: { _, _, _, _ in 0 })
        let seen = Locked<[TripRecorder.Stats]>([])
        r.onStats = { s in seen.withLock { $0.append(s) } }
        r.start()
        r.ingest(LocationFix(lat: 0, lon: 0, speedMps: 1, timeMs: 1))
        r.stopAndSave()
        XCTAssertEqual(seen.current.map(\.recording), [true, true, false])
    }

    func testAutoLogPolicy() {
        typealias P = TripAutoLogPolicy
        XCTAssertEqual(P.action(logTrips: true, streaming: true, dashUILive: false, recording: false, manualRecording: false), .start)
        XCTAssertEqual(P.action(logTrips: true, streaming: false, dashUILive: true, recording: false, manualRecording: false), .start)
        XCTAssertEqual(P.action(logTrips: true, streaming: false, dashUILive: false, recording: true, manualRecording: false), .stopAndSave)
        XCTAssertEqual(P.action(logTrips: false, streaming: true, dashUILive: true, recording: true, manualRecording: false), .stopAndSave)
        XCTAssertEqual(P.action(logTrips: false, streaming: true, dashUILive: true, recording: true, manualRecording: true), .none)
        XCTAssertEqual(P.action(logTrips: true, streaming: true, dashUILive: true, recording: true, manualRecording: false), .none)
        XCTAssertEqual(P.startLogMessage(streaming: true, dashUILive: true), "auto-logging this ride (dash + map)")
        XCTAssertEqual(P.startLogMessage(streaming: false, dashUILive: true), "auto-logging this ride (map)")
    }

    func testAndroidDistance() {
        // (45,25)→(45.01,25.01): WGS84 inverse formula = 1362.5724 m (independent Python port).
        let d = TripGeodesy.androidDistance(lat1: 45, lon1: 25, lat2: 45.01, lon2: 25.01)
        XCTAssertEqual(Double(d), 1362.5724, accuracy: 0.01)
        XCTAssertEqual(TripGeodesy.androidDistance(lat1: 10, lon1: 10, lat2: 10, lon2: 10), 0)
        // 1° of latitude at the equator: 110 574.4 m on WGS84
        XCTAssertEqual(Double(TripGeodesy.androidDistance(lat1: 0, lon1: 0, lat2: 1, lon2: 0)), 110_574.4, accuracy: 0.5)
        // 1° of longitude at the equator: 111 319.5 m
        XCTAssertEqual(Double(TripGeodesy.androidDistance(GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 0, lon: 1))), 111_319.5, accuracy: 0.5)
    }
}
