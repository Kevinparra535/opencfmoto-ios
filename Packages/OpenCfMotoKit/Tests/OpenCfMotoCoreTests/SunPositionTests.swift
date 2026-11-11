// SPDX-License-Identifier: AGPL-3.0-or-later
// The sun's elevation (SunPosition) and the iOS AUTO night rule built on it (P0, D06): night from sunset
// to sunrise at the rider's fix, the clock rule only without a position, the phone's dark mode never.
// Reference elevations come from an independent algorithm (NOAA's solar calculator, geometric, no
// refraction), not from the Almanac formula under test.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class SunPositionTests: XCTestCase {
    private struct Spot { var lat: Double; var lon: Double }
    private static let bogota = Spot(lat: 4.711, lon: -74.072)
    private static let madrid = Spot(lat: 40.4168, lon: -3.7038)
    private static let tromso = Spot(lat: 69.6496, lon: 18.956)
    private static let buenosAires = Spot(lat: -34.6037, lon: -58.3816)
    private static let utc = TimeZone(identifier: "UTC")!

    private static func at(_ unix: TimeInterval) -> Date { Date(timeIntervalSince1970: unix) }

    private func elevation(_ s: Spot, _ unix: TimeInterval, file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard let e = SunPosition.elevationDeg(latitude: s.lat, longitude: s.lon, date: Self.at(unix)) else {
            XCTFail("no elevation", file: file, line: line)
            return .nan
        }
        return e
    }

    func testElevationMatchesAnIndependentReference() {
        // (place, instant, NOAA elevation in degrees)
        let cases: [(String, Spot, TimeInterval, Double)] = [
            ("Bogotá, local noon", Self.bogota, 1_768_496_400, 64.221), // 2026-01-15 17:00 UTC
            ("Bogotá, 22:00", Self.bogota, 1_768_532_400, -55.400), // 2026-01-16 03:00 UTC
            ("Madrid, June solstice noon", Self.madrid, 1_782_043_200, 72.664), // 2026-06-21 12:00 UTC
            ("Madrid, December 18:30", Self.madrid, 1_797_874_200, -7.329), // 2026-12-21 17:30 UTC
            ("Tromsø, polar night noon", Self.tromso, 1_797_849_900, -3.088), // 2026-12-21 10:45 UTC
            ("Tromsø, midnight sun", Self.tromso, 1_782_082_800, 3.120), // 2026-06-21 23:00 UTC
            ("Buenos Aires, December 20:30", Self.buenosAires, 1_797_895_800, -5.035), // 2026-12-21 23:30 UTC
            ("Equator, March equinox noon", Spot(lat: 0, lon: 0), 1_774_008_420, 89.884), // 2026-03-20 12:07 UTC
            ("Sydney, July noon", Spot(lat: -33.8688, lon: 151.2093), 1_782_871_200, 33.018), // 2026-07-01 02:00 UTC
            ("Near the date line", Spot(lat: 10, lon: 179.9), 1_788_220_800, 88.341), // 2026-09-01 00:00 UTC
        ]
        for (name, spot, unix, expected) in cases {
            XCTAssertEqual(elevation(spot, unix), expected, accuracy: 0.3, name)
        }
    }

    func testOutOfRangeOrNonFiniteInputsHaveNoElevation() {
        let d = Self.at(1_768_496_400)
        XCTAssertNil(SunPosition.elevationDeg(latitude: 91, longitude: 0, date: d))
        XCTAssertNil(SunPosition.elevationDeg(latitude: -90.5, longitude: 0, date: d))
        XCTAssertNil(SunPosition.elevationDeg(latitude: 0, longitude: 180.1, date: d))
        XCTAssertNil(SunPosition.elevationDeg(latitude: .nan, longitude: 0, date: d))
        XCTAssertNil(SunPosition.elevationDeg(latitude: 0, longitude: .infinity, date: d))
        XCTAssertNil(SunPosition.elevationDeg(latitude: 0, longitude: 0, date: Date(timeIntervalSince1970: .nan)))
        for lat in [-90.0, 90.0] { // the poles are valid
            let e = SunPosition.elevationDeg(latitude: lat, longitude: 0, date: d)
            XCTAssertNotNil(e)
            XCTAssertTrue((-90 ... 90).contains(e ?? .nan))
        }
    }

    // MARK: AUTO night at the fix

    private func night(_ s: Spot, _ unix: TimeInterval, theme: MapTheme = .auto, tz: TimeZone = TimeZone(identifier: "UTC")!) -> Bool {
        NightModePolicy.isNight(theme: theme, position: GeoPoint(lat: s.lat, lon: s.lon), date: Self.at(unix), timeZone: tz)
    }

    func testAutoIsNightFromSunsetToSunrise() {
        // Bogotá, 2026-01-15: sunset ≈ 23:02:30 UTC (18:02 local), sunrise ≈ 11:10 UTC the next day (06:10).
        XCTAssertFalse(night(Self.bogota, 1_768_517_700)) // 22:55 UTC, +0.84°
        XCTAssertTrue(night(Self.bogota, 1_768_518_600)) // 23:10 UTC, −2.65°
        XCTAssertTrue(night(Self.bogota, 1_768_561_500)) // 11:05 UTC, −1.92°
        XCTAssertFalse(night(Self.bogota, 1_768_562_400)) // 11:20 UTC, +1.57°
        XCTAssertFalse(night(Self.bogota, 1_768_496_400)) // noon
        // The threshold: sunset / sunrise with standard refraction (the upper edge on the horizon).
        XCTAssertEqual(NightModePolicy.sunsetElevationDeg, -0.833, accuracy: 1e-9)
    }

    func testAWinterDuskBefore19IsNightAndAPolarDayIsNot() {
        let cet = TimeZone(secondsFromGMT: 3600)!
        // Madrid 2026-12-21 18:30 local: the sun set at ≈ 17:51. The old clock rule said day until 19:00.
        XCTAssertTrue(night(Self.madrid, 1_797_874_200, tz: cet))
        XCTAssertFalse(NightModePolicy.isNight(theme: .auto, phoneDarkMode: false, date: Self.at(1_797_874_200), timeZone: cet))
        // Tromsø: night at noon in the polar night, day at 01:00 under the midnight sun.
        XCTAssertTrue(night(Self.tromso, 1_797_849_900))
        XCTAssertFalse(night(Self.tromso, 1_782_082_800))
        // Southern summer: Buenos Aires 20:30 local, the sun already set.
        XCTAssertTrue(night(Self.buenosAires, 1_797_895_800, tz: TimeZone(secondsFromGMT: -3 * 3600)!))
    }

    func testDayAndNightThemesWinAndNoPositionFallsBackToTheClock() {
        XCTAssertFalse(night(Self.bogota, 1_768_532_400, theme: .day)) // 22:00 local, forced day
        XCTAssertTrue(night(Self.bogota, 1_768_496_400, theme: .night)) // noon, forced night
        let bogotaTZ = TimeZone(secondsFromGMT: -5 * 3600)!
        // No fix yet: 19:00–06:59 local.
        XCTAssertTrue(NightModePolicy.isNight(theme: .auto, position: nil, date: Self.at(1_768_532_400), timeZone: bogotaTZ)) // 22:00
        XCTAssertFalse(NightModePolicy.isNight(theme: .auto, position: nil, date: Self.at(1_768_496_400), timeZone: bogotaTZ)) // 12:00
        // A corrupt position counts as none.
        XCTAssertFalse(NightModePolicy.isNight(theme: .auto, position: GeoPoint(lat: .nan, lon: 0), date: Self.at(1_768_496_400),
                                               timeZone: bogotaTZ))
    }

    func testTheMonitorFollowsTheSunAndReevaluatesOnAPositionOrAThemeChange() {
        let p = GeoPoint(lat: Self.bogota.lat, lon: Self.bogota.lon)
        var m = NightModeMonitor()
        // Noon at the fix: day.
        XCTAssertFalse(m.evaluate(theme: .auto, position: p, date: Self.at(1_768_496_400), now: 0, timeZone: Self.utc))
        // 22:00 at the fix but only 30 s of the monotonic clock later: the cached value.
        XCTAssertFalse(m.evaluate(theme: .auto, position: p, date: Self.at(1_768_532_400), now: 30, timeZone: Self.utc))
        // 60 s later: re-evaluated.
        XCTAssertTrue(m.evaluate(theme: .auto, position: p, date: Self.at(1_768_532_400), now: 61, timeZone: Self.utc))
        // A theme change re-evaluates at once.
        XCTAssertFalse(m.evaluate(theme: .day, position: p, date: Self.at(1_768_532_400), now: 62, timeZone: Self.utc))
        // So does a position appearing (the clock rule before it, the sun after).
        var n = NightModeMonitor()
        let cet = TimeZone(secondsFromGMT: 3600)!
        XCTAssertFalse(n.evaluate(theme: .auto, position: nil, date: Self.at(1_797_874_200), now: 0, timeZone: cet)) // 18:30, clock: day
        XCTAssertTrue(n.evaluate(theme: .auto, position: GeoPoint(lat: Self.madrid.lat, lon: Self.madrid.lon),
                                 date: Self.at(1_797_874_200), now: 1, timeZone: cet)) // the sun has set
        // The Android rule (phone dark mode) and the sun rule never reuse each other's cached value.
        var mixed = NightModeMonitor()
        XCTAssertTrue(mixed.evaluate(theme: .auto, phoneDarkMode: true, date: Self.at(1_768_496_400), now: 0, timeZone: Self.utc))
        XCTAssertFalse(mixed.evaluate(theme: .auto, position: p, date: Self.at(1_768_496_400), now: 1, timeZone: Self.utc))
    }
}
