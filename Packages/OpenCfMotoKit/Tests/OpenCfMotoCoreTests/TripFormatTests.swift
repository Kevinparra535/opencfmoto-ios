// SPDX-License-Identifier: AGPL-3.0-or-later
// Trip stats / formatting (app-features.md §5.2), GPX export (§5.9, TripGpxTest.kt), trip files (§5.5),
// day grouping (§5.7) and route thumbnail geometry (§5.10).

import XCTest
@testable import OpenCfMotoCore

final class TripFormatTests: XCTestCase {

    static let repoTrip = Trip(id: "1", start: 1_700_000_000_000, end: 1_700_000_360_000, distanceMeters: 12_500,
                               movingTimeMs: 360_000, maxSpeedMs: 25,
                               points: [TripPoint(lat: 45.0, lon: 25.0, timeMs: 1_700_000_000_000, speedMs: 10),
                                        TripPoint(lat: 45.01, lon: 25.01, timeMs: 1_700_000_180_000, speedMs: 12)])
    let utc = TimeZone(identifier: "UTC")!
    let enUS = Locale(identifier: "en_US")

    func testRepoTripStats() {
        let t = Self.repoTrip
        XCTAssertEqual(t.distanceText, "12.50 km")
        XCTAssertEqual(t.durationText, "00:06:00")
        XCTAssertEqual(t.avgKmh, 125)
        XCTAssertEqual(t.maxKmh, 90)
        XCTAssertEqual(t.distanceKm, 12.5)
    }

    func testTruncationExample() {
        let t = Trip(id: "x", start: 0, end: 0, distanceMeters: 12_345.6, movingTimeMs: 1_234_567, maxSpeedMs: 33.4, points: [])
        XCTAssertEqual(t.distanceText, "12.35 km")
        XCTAssertEqual(t.durationText, "00:20:34")
        XCTAssertEqual(t.avgKmh, 35)        // 35.9998 truncated
        XCTAssertEqual(t.maxKmh, 120)       // 33.4f × 3.6f = 120.240005
    }

    func testDurationAndEdgeCases() {
        XCTAssertEqual(TripFormat.durationText(movingTimeMs: 90_061_000), "25:01:01")
        XCTAssertEqual(TripFormat.durationText(movingTimeMs: -5), "00:00:00")
        XCTAssertEqual(TripFormat.durationText(movingTimeMs: 999), "00:00:00")
        XCTAssertEqual(TripFormat.durationText(movingTimeMs: 360_000_000), "100:00:00")
        let none = Trip(id: "", start: 0, end: 0, distanceMeters: 50, movingTimeMs: 0, maxSpeedMs: 0, points: [])
        XCTAssertEqual(none.avgKmh, 0)
        XCTAssertEqual(TripFormat.distanceText(meters: 12_345), "12.35 km")   // Java HALF_UP (C printf: 12.34)
        XCTAssertEqual(TripFormat.distanceText(meters: 0), "0.00 km")
        XCTAssertEqual(TripFormat.kmhText(42), "42 km/h")
        XCTAssertEqual(TripFormat.liveSpeedKmh(speedMs: -1), 0)
        XCTAssertEqual(TripFormat.liveSpeedKmh(speedMs: 25), 90)
        XCTAssertEqual(TripFormat.distanceTextImperial(meters: 1609.344), "1.00 mi")
        XCTAssertEqual(TripFormat.mph(speedMs: 25), 55)
    }

    func testDateTexts() {
        let t = Self.repoTrip
        XCTAssertEqual(t.dateText(locale: enUS, timeZone: utc), "Tue 14 Nov 2023")
        XCTAssertEqual(t.timeRangeText(locale: enUS, timeZone: utc), "22:13 \u{2013} 22:19")
        XCTAssertEqual(TripFormat.timeText(epochMs: 1_700_000_000_999, locale: enUS, timeZone: utc), "22:13")
    }

    // MARK: GPX

    static let repoGpx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="OpenCfMoto" xmlns="http://www.topografix.com/GPX/1/1">
      <metadata>
        <name>OpenCfMoto Tue 14 Nov 2023 22:13 \u{2013} 22:19</name>
        <time>2023-11-14T22:13:20Z</time>
      </metadata>
      <trk>
        <name>OpenCfMoto Tue 14 Nov 2023 22:13 \u{2013} 22:19</name>
        <type>motorcycle</type>
        <trkseg>
          <trkpt lat="45.000000" lon="25.000000">
            <time>2023-11-14T22:13:20Z</time>
          </trkpt>
          <trkpt lat="45.010000" lon="25.010000">
            <time>2023-11-14T22:16:20Z</time>
          </trkpt>
        </trkseg>
      </trk>
    </gpx>

    """

    func testGpxExactTemplate() {
        let xml = TripGpx.toXML(Self.repoTrip, locale: enUS, timeZone: utc)
        XCTAssertEqual(xml, Self.repoGpx)
        XCTAssertTrue(xml.contains("<gpx"))
        XCTAssertTrue(xml.contains("trkpt lat=\"45.000000\""))
        XCTAssertTrue(xml.contains("<time>"))
        XCTAssertTrue(xml.hasSuffix("</gpx>\n"))
        XCTAssertEqual(TripGpx.suggestedFileName(Self.repoTrip, timeZone: utc), "opencfmoto_trip_20231114_2213.gpx")
        XCTAssertTrue(TripGpx.suggestedFileName(Self.repoTrip).hasSuffix(".gpx"))
    }

    func testGpxPointWithoutTimeAndEscaping() {
        var t = Self.repoTrip
        t.points = [TripPoint(lat: -33.8688197, lon: 151.2092955, timeMs: 0, speedMs: 0),
                    TripPoint(lat: 45.0078125, lon: -0.0000004, timeMs: 1_700_000_000_999, speedMs: 0)]
        let xml = TripGpx.toXML(t, locale: enUS, timeZone: utc)
        XCTAssertTrue(xml.contains("      <trkpt lat=\"-33.868820\" lon=\"151.209296\">\n      </trkpt>\n"))
        XCTAssertTrue(xml.contains("<trkpt lat=\"45.007813\" lon=\"-0.000000\">\n        <time>2023-11-14T22:13:20Z</time>"))
        XCTAssertEqual(TripGpx.escape("a&b<c>\"d'"), "a&amp;b&lt;c&gt;&quot;d'")
        XCTAssertEqual(TripGpx.escape("&lt;"), "&amp;lt;")
    }

    // MARK: Trip files

    func testTripFileMatchesAndroid() {
        var t = Self.repoTrip
        t.id = "1700000000000"
        let json = TripStore.encode(t)
        XCTAssertEqual(json, #"{"id":"1700000000000","start":1700000000000,"end":1700000360000,"distanceMeters":12500,"movingTimeMs":360000,"maxSpeedMs":25,"points":[[45,25,1700000000000,10],[45.01,25.01,1700000180000,12]]}"#)
        XCTAssertEqual(TripStore.decode(json!), t)
        var u = t
        u.maxSpeedMs = 12.3
        u.points[0].speedMs = 0.0001
        XCTAssertTrue(TripStore.encode(u)!.contains(#""maxSpeedMs":12.300000190734863"#))
        XCTAssertTrue(TripStore.encode(u)!.contains(#"[45,25,1700000000000,9.999999747378752E-5]"#))
        u.distanceMeters = .nan
        XCTAssertNil(TripStore.encode(u))
    }

    func testTripDecodeLeniency() {
        let t = TripStore.decode(#"{"id":7,"start":"5","points":[[1,2],"x",[3,4,"9",5]]}"#)
        XCTAssertEqual(t?.id, "7")
        XCTAssertEqual(t?.start, 5)
        XCTAssertEqual(t?.end, 0)
        XCTAssertTrue(t?.distanceMeters.isNaN ?? false)
        XCTAssertEqual(t?.points.count, 2)
        XCTAssertEqual(t?.points[0].timeMs, 0)
        XCTAssertTrue(t?.points[0].speedMs.isNaN ?? false)
        XCTAssertEqual(t?.points[1].timeMs, 9)
        XCTAssertNil(TripStore.decode("[]"))
        XCTAssertNil(TripStore.decode("garbage {"))
    }

    func testTripStoreFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trips-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TripStore(directory: dir)
        XCTAssertEqual(store.list(), [])
        var a = Self.repoTrip; a.id = "1700000000000"
        var b = Self.repoTrip; b.id = "1700000500000"; b.start = 1_700_000_500_000
        var c = Self.repoTrip; c.id = "../evil"; c.start = 1_600_000_000_000
        try store.save(a)
        try store.save(b)
        try store.save(c)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1700000000000.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("1600000000000.json").path))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("ignored.txt"))
        XCTAssertEqual(store.list().map(\.start), [1_700_000_500_000, 1_700_000_000_000, 1_600_000_000_000])
        XCTAssertEqual(store.trip(id: "1700000000000"), a)
        XCTAssertNil(store.trip(id: "nope"))
        XCTAssertNil(store.trip(id: "../etc/passwd"))
        store.delete(id: "1700000000000")
        XCTAssertNil(store.trip(id: "1700000000000"))
        XCTAssertEqual(store.list().count, 2)
        XCTAssertEqual(TripStore.fileName(for: c), "1600000000000.json")
        var bad = a; bad.maxSpeedMs = .infinity
        XCTAssertThrowsError(try store.save(bad))
    }

    // MARK: Days

    func testDayGroupingIsDSTSafe() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        // 2026-10-25 has 25 hours in Bucharest (EEST → EET at 04:00).
        let dayStart = TripDays.startOfDay(1_792_915_200_000, calendar: cal)      // 2026-10-25 10:00 local
        XCTAssertEqual(dayStart, 1_792_875_600_000)                                // 2026-10-24T21:00:00Z
        let next = TripDays.shiftDay(dayStart, by: 1, calendar: cal)
        XCTAssertEqual(next - dayStart, 25 * 3_600_000)
        // A ride at 23:30 local on Oct 25 (= 21:30Z) is 24.5 h after midnight: Android's 24 h window drops it.
        let late = Trip(id: "late", start: dayStart + 24 * 3_600_000 + 1_800_000, end: 0, distanceMeters: 1000,
                        movingTimeMs: 60_000, maxSpeedMs: 10, points: [])
        let early = Trip(id: "early", start: dayStart + 3_600_000, end: 0, distanceMeters: 2500,
                         movingTimeMs: 60_000, maxSpeedMs: 10, points: [])
        let nextDay = Trip(id: "next", start: next + 60_000, end: 0, distanceMeters: 1, movingTimeMs: 1, maxSpeedMs: 1, points: [])
        let day = TripDays.trips([early, late, nextDay], onDay: dayStart, calendar: cal)
        XCTAssertEqual(day.map(\.id), ["late", "early"])
        XCTAssertEqual(TripDays.summary(day), TripDaySummary(count: 2, distanceKm: 3.5))
        XCTAssertEqual(TripDays.shiftDay(next, by: -1, calendar: cal), dayStart)
    }

    func testInitialDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now: Int64 = 1_700_050_000_000                    // 2023-11-15 12:06Z
        let today = TripDays.startOfDay(now, calendar: cal)
        XCTAssertEqual(TripDays.initialDay(trips: [], nowMs: now, calendar: cal), today)
        let old = Self.repoTrip                                // 2023-11-14
        XCTAssertEqual(TripDays.initialDay(trips: [old], nowMs: now, calendar: cal), TripDays.startOfDay(old.start, calendar: cal))
        var fresh = old; fresh.start = now - 1000
        XCTAssertEqual(TripDays.initialDay(trips: [old, fresh], nowMs: now, calendar: cal), today)
    }

    // MARK: Thumbnail

    func testThumbnailWorkedExample() {
        let g = TripThumbnail.geometry(points: Self.repoTrip.points, widthPx: 240, heightPx: 112)
        XCTAssertEqual(g.polyline.count, 2)
        XCTAssertEqual(g.start!.x, 91.4919, accuracy: 1e-3)
        XCTAssertEqual(g.start!.y, 96.3200, accuracy: 1e-3)
        XCTAssertEqual(g.end!.x, 148.5081, accuracy: 1e-3)
        XCTAssertEqual(g.end!.y, 15.6800, accuracy: 1e-3)
        XCTAssertEqual(g.strokeWidth, 4.0)
        XCTAssertEqual(g.dotRadius, 5.04, accuracy: 1e-5)
        XCTAssertEqual(g.normalizedPolyline[1].x, 148.5081 / 240, accuracy: 1e-5)
        XCTAssertEqual(g.normalizedPolyline[1].y, 15.68 / 112, accuracy: 1e-5)
        let empty = TripThumbnail.geometry(points: [Self.repoTrip.points[0]], widthPx: 240, heightPx: 112)
        XCTAssertTrue(empty.polyline.isEmpty)
        XCTAssertNil(empty.start)
    }

    func testSubsample() {
        let idx = TripThumbnail.subsampleIndices(count: 1000)
        XCTAssertEqual(idx.count, 180)
        XCTAssertEqual(Array(idx.prefix(5)), [0, 5, 11, 16, 22])
        XCTAssertEqual(Array(idx.suffix(3)), [987, 993, 999])
        XCTAssertEqual(TripThumbnail.subsampleIndices(count: 180), Array(0 ..< 180))
        XCTAssertEqual(TripThumbnail.subsampleIndices(count: 3), [0, 1, 2])
    }

    func testThumbnailDegenerateTrack() {
        // all points identical: spans clamp to 1e-7 and the track sits in the middle
        let p = TripPoint(lat: 10, lon: 10, timeMs: 0, speedMs: 0)
        let g = TripThumbnail.geometry(points: [p, p, p], widthPx: 100, heightPx: 100)
        XCTAssertEqual(g.polyline.count, 3)
        XCTAssertEqual(g.start!.x, 14, accuracy: 1e-3)   // pad = 14, used span fills the draw area
        XCTAssertEqual(g.start!.y, 14, accuracy: 1e-3)
        XCTAssertEqual(g.strokeWidth, 4)
        XCTAssertEqual(g.dotRadius, 5)
    }
}
