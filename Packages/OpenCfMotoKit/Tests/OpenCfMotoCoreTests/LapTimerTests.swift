// SPDX-License-Identifier: AGPL-3.0-or-later
// LapTimer (upstream LapTimerTest vectors) and the day/night policy.

import XCTest
@testable import OpenCfMotoCore

final class LapTimerTests: XCTestCase {
    func testFlyingStartThenLap() {
        var t = LapTimer()
        t.arm(lat: 45.0, lon: 7.0)
        XCTAssertTrue(t.hud(nowMs: 0).waiting)
        XCTAssertFalse(t.onFix(lat: 45.0, lon: 7.0, nowMs: 0))
        XCTAssertFalse(t.onFix(lat: 45.00072, lon: 7.0, nowMs: 5_000)) // ~80 m north
        XCTAssertFalse(t.onFix(lat: 45.0, lon: 7.0, nowMs: 10_000))   // clock starts, lap 1
        let started = t.hud(nowMs: 10_000)
        XCTAssertFalse(started.waiting)
        XCTAssertEqual(started.lap, 1)
        XCTAssertFalse(t.onFix(lat: 45.00072, lon: 7.0, nowMs: 20_000))
        XCTAssertTrue(t.onFix(lat: 45.0, lon: 7.0, nowMs: 40_000))
        let done = t.hud(nowMs: 40_000)
        XCTAssertEqual(done.finished, 1)
        XCTAssertEqual(done.lastMs, 30_000)
        XCTAssertEqual(done.bestMs, 30_000)
        XCTAssertEqual(done.lap, 2)
        XCTAssertEqual(t.hud(nowMs: 41_500).currentMs, 1_500)
        XCTAssertEqual(t.cardLines(nowMs: 41_500)?.current, "LAP 2  0:01.50")
        XCTAssertEqual(t.cardLines(nowMs: 41_500)?.meta, "LAST 0:30.00   BEST 0:30.00")
    }

    func testBounceAtGateDoesNotCount() {
        var t = LapTimer()
        t.arm(lat: 45.0, lon: 7.0)
        _ = t.onFix(lat: 45.00072, lon: 7.0, nowMs: 1_000)
        _ = t.onFix(lat: 45.0, lon: 7.0, nowMs: 2_000)
        _ = t.onFix(lat: 45.00072, lon: 7.0, nowMs: 3_000)
        XCTAssertFalse(t.onFix(lat: 45.0, lon: 7.0, nowMs: 4_000))
        XCTAssertEqual(t.hud(nowMs: 4_000).finished, 0)
    }

    func testBestLapAndStop() {
        var t = LapTimer()
        t.arm(lat: 45.0, lon: 7.0)
        let away = 45.00072
        _ = t.onFix(lat: away, lon: 7, nowMs: 1_000)
        _ = t.onFix(lat: 45, lon: 7, nowMs: 2_000)          // start
        _ = t.onFix(lat: away, lon: 7, nowMs: 10_000)
        XCTAssertTrue(t.onFix(lat: 45, lon: 7, nowMs: 62_000)) // 60 s
        _ = t.onFix(lat: away, lon: 7, nowMs: 70_000)
        XCTAssertTrue(t.onFix(lat: 45, lon: 7, nowMs: 112_000)) // 50 s
        let h = t.hud(nowMs: 112_000)
        XCTAssertEqual(h.lastMs, 50_000)
        XCTAssertEqual(h.bestMs, 50_000)
        XCTAssertEqual(h.finished, 2)
        XCTAssertEqual(h.lap, 3)
        t.stop()
        XCTAssertFalse(t.isOn)
        XCTAssertNil(t.cardLines(nowMs: 0))
        XCTAssertFalse(t.onFix(lat: 45, lon: 7, nowMs: 200_000))
        var w = LapTimer()
        w.arm(lat: 1, lon: 1)
        XCTAssertEqual(w.cardLines(nowMs: 5)?.current, "Pass start/finish")
        XCTAssertEqual(w.cardLines(nowMs: 5)?.meta, "LAST —   BEST —")
        XCTAssertEqual(w.cardLines(nowMs: 5, strings: NavStrings(language: .es))?.current, "Pasa por salida/meta")
    }

    func testFormatMs() {
        XCTAssertEqual(LapTimer.formatMs(1_500), "0:01.50")
        XCTAssertEqual(LapTimer.formatMs(62_030), "1:02.03")
        XCTAssertEqual(LapTimer.formatMs(-10), "0:00.00")
        XCTAssertEqual(LapTimer.formatMs(3_600_000), "60:00.00")
    }

    // MARK: Night mode

    func testNightPolicy() {
        XCTAssertFalse(NightModePolicy.isNight(theme: .day, phoneDarkMode: true, hour: 23))
        XCTAssertTrue(NightModePolicy.isNight(theme: .night, phoneDarkMode: false, hour: 12))
        XCTAssertTrue(NightModePolicy.isNight(theme: .auto, phoneDarkMode: true, hour: 12))
        XCTAssertFalse(NightModePolicy.isNight(theme: .auto, phoneDarkMode: false, hour: 7))
        XCTAssertFalse(NightModePolicy.isNight(theme: .auto, phoneDarkMode: false, hour: 18))
        XCTAssertTrue(NightModePolicy.isNight(theme: .auto, phoneDarkMode: false, hour: 19))
        XCTAssertTrue(NightModePolicy.isNight(theme: .auto, phoneDarkMode: false, hour: 6))
        XCTAssertEqual(NightModePolicy.cycle(.auto), .day)
        XCTAssertEqual(NightModePolicy.cycle(.day), .night)
        XCTAssertEqual(NightModePolicy.cycle(.night), .auto)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertTrue(NightModePolicy.isNight(theme: .auto, phoneDarkMode: false, date: Date(timeIntervalSince1970: 1_700_000_000), timeZone: utc)) // 22:13
    }

    func testNightMonitorReevaluatesEverySixtySeconds() {
        var m = NightModeMonitor()
        let utc = TimeZone(identifier: "UTC")!
        let evening = Date(timeIntervalSince1970: 1_699_988_399) // 18:59:59 UTC
        XCTAssertFalse(m.evaluate(theme: .auto, phoneDarkMode: false, date: evening, now: 0, timeZone: utc))
        // 19:00 passed, but less than 60 s since the last evaluation → cached.
        XCTAssertFalse(m.evaluate(theme: .auto, phoneDarkMode: false, date: evening.addingTimeInterval(30), now: 30, timeZone: utc))
        XCTAssertTrue(m.evaluate(theme: .auto, phoneDarkMode: false, date: evening.addingTimeInterval(61), now: 61, timeZone: utc))
        // Input changes are applied immediately.
        XCTAssertFalse(m.evaluate(theme: .day, phoneDarkMode: false, date: evening, now: 62, timeZone: utc))
        XCTAssertTrue(m.evaluate(theme: .day, phoneDarkMode: true, date: evening, now: 63, timeZone: utc) == false)
        XCTAssertTrue(m.evaluate(theme: .auto, phoneDarkMode: true, date: evening, now: 64, timeZone: utc))
    }
}
