// SPDX-License-Identifier: AGPL-3.0-or-later
// Compass smoothing (navigation-dash.md §4.9: α = 0.15 on sin/cos, 120 ms processing ticks) and the
// CLLocation → LocationFix conversion rules (runs on Linux too).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PlatformLocationTests: XCTestCase {
    func testFirstSampleIsTakenAsIs() {
        var s = HeadingSmoother()
        XCTAssertEqual(s.update(rawDegrees: 123.4, now: 0)!, 123.4, accuracy: 1e-9)
        XCTAssertEqual(s.heading!, 123.4, accuracy: 1e-9)
    }

    func testOneAlphaStepFrom0To90() {
        var s = HeadingSmoother()
        _ = s.update(rawDegrees: 0, now: 0)
        // s = 0.15, c = 0.85 → atan2(0.15, 0.85) = 10.00797980144134°
        let h = s.update(rawDegrees: 90, now: 1)
        XCTAssertEqual(h!, 10.00797980144134, accuracy: 1e-9)
    }

    func testWrapAroundNorthDoesNotSwingThrough180() {
        var s = HeadingSmoother()
        _ = s.update(rawDegrees: 350, now: 0)
        let h = s.update(rawDegrees: 10, now: 1)!
        // s = sin350 + 0.15(sin10 − sin350), c ≈ cos350 → ≈ 352.96°
        XCTAssertEqual(h, 352.9636340004461, accuracy: 1e-9)
        for i in 2 ..< 80 { _ = s.update(rawDegrees: 10, now: Double(i)) }
        XCTAssertEqual(s.heading!, 10, accuracy: 0.01, "converges to the new heading through north")
    }

    func testConstantInputStaysPutAndResultIsNormalised() {
        var s = HeadingSmoother()
        for i in 0 ..< 20 {
            let h = s.update(rawDegrees: 270, now: Double(i))
            XCTAssertEqual(h!, 270, accuracy: 1e-9)
        }
        var t = HeadingSmoother()
        XCTAssertEqual(t.update(rawDegrees: 360, now: 0)!, 0, accuracy: 1e-9)
        // One α-step from north towards 270° (= −90°): atan2(−0.15, 0.85) → 349.992…°
        XCTAssertEqual(t.update(rawDegrees: -90, now: 1)!, 360 - 10.00797980144134, accuracy: 1e-9)
    }

    func testThrottleTo120ms() {
        var s = HeadingSmoother()
        XCTAssertNotNil(s.update(rawDegrees: 10, now: 0))
        XCTAssertNil(s.update(rawDegrees: 20, now: 0.050))
        XCTAssertNil(s.update(rawDegrees: 30, now: 0.119))
        XCTAssertNotNil(s.update(rawDegrees: 40, now: 0.120))
        XCTAssertNil(s.update(rawDegrees: 50, now: 0.200))
        XCTAssertNotNil(s.update(rawDegrees: 60, now: 0.245))
        // The filter keeps integrating throttled samples (Android updates deviceHeading every sample).
        var u = HeadingSmoother()
        _ = u.update(rawDegrees: 0, now: 0)
        XCTAssertNil(u.update(rawDegrees: 90, now: 0.01))
        XCTAssertEqual(u.heading!, 10.00797980144134, accuracy: 1e-9)
        u.reset()
        XCTAssertNil(u.heading)
        XCTAssertEqual(u.update(rawDegrees: 45, now: 0.02)!, 45, accuracy: 1e-9)
    }

    func testCustomParameters() {
        var s = HeadingSmoother(alpha: 1.0, minInterval: 0)
        _ = s.update(rawDegrees: 0, now: 0)
        XCTAssertEqual(s.update(rawDegrees: 90, now: 0)!, 90, accuracy: 1e-9)
        XCTAssertEqual(HeadingSmoother.defaultAlpha, 0.15)
        XCTAssertEqual(HeadingSmoother.defaultMinInterval, 0.120)
    }

    func testRawHeadingSelection() {
        XCTAssertEqual(HeadingSmoother.rawHeading(trueHeading: 90, magneticHeading: 80, accuracy: 5), 90)
        XCTAssertEqual(HeadingSmoother.rawHeading(trueHeading: -1, magneticHeading: 80, accuracy: 5), 80)
        XCTAssertNil(HeadingSmoother.rawHeading(trueHeading: 90, magneticHeading: 80, accuracy: -1))
        XCTAssertNil(HeadingSmoother.rawHeading(trueHeading: -1, magneticHeading: -1, accuracy: 3))
        XCTAssertEqual(HeadingSmoother.rawHeading(trueHeading: 360, magneticHeading: 0, accuracy: 3), 0)
    }

    func testLocationFixConversion() {
        let t = Date(timeIntervalSince1970: 1_700_000_000.1234)
        let fix = LocationFixConversion.fix(latitude: 4.65, longitude: -74.05, speed: 13.9, course: 271.5,
                                            horizontalAccuracy: 4.2, altitude: 2600, verticalAccuracy: 3, timestamp: t)
        XCTAssertEqual(fix, LocationFix(lat: 4.65, lon: -74.05, speedMps: 13.9, courseDeg: 271.5, accuracyM: 4.2,
                                        altitudeM: 2600, timeMs: 1_700_000_000_123))
        XCTAssertTrue(fix.isMoving)

        let unknown = LocationFixConversion.fix(latitude: 1, longitude: 2, speed: -1, course: -1, horizontalAccuracy: 30,
                                                altitude: 55, verticalAccuracy: -1, timestamp: Date(timeIntervalSince1970: 1))
        XCTAssertNil(unknown.speedMps)
        XCTAssertNil(unknown.courseDeg)
        XCTAssertNil(unknown.altitudeM)
        XCTAssertEqual(unknown.accuracyM, 30)
        XCTAssertEqual(unknown.timeMs, 1000)
        XCTAssertFalse(unknown.isMoving)

        let stopped = LocationFixConversion.fix(latitude: 1, longitude: 2, speed: 0, course: 0, horizontalAccuracy: -1,
                                                altitude: 0, verticalAccuracy: 0, timestamp: Date(timeIntervalSince1970: 2.0007))
        XCTAssertEqual(stopped.speedMps, 0)
        XCTAssertEqual(stopped.courseDeg, 0, "course 0 = due north, valid")
        XCTAssertNil(stopped.accuracyM)
        XCTAssertEqual(stopped.altitudeM, 0)
        XCTAssertEqual(stopped.timeMs, 2001, "2000.7 ms rounds to the nearest millisecond")
    }

    func testFixValidity() {
        XCTAssertTrue(LocationFixConversion.isValid(latitude: 4.6, longitude: -74.1, horizontalAccuracy: 5))
        XCTAssertFalse(LocationFixConversion.isValid(latitude: 4.6, longitude: -74.1, horizontalAccuracy: -1))
        XCTAssertFalse(LocationFixConversion.isValid(latitude: 91, longitude: 0, horizontalAccuracy: 5))
        XCTAssertFalse(LocationFixConversion.isValid(latitude: 0, longitude: 181, horizontalAccuracy: 5))
    }

    func testAuthorization() {
        XCTAssertTrue(LocationAuthorization.whenInUse.isAuthorized)
        XCTAssertTrue(LocationAuthorization.always.isAuthorized)
        XCTAssertFalse(LocationAuthorization.denied.isAuthorized)
        XCTAssertFalse(LocationAuthorization.notDetermined.isAuthorized)
        XCTAssertFalse(LocationAuthorization.restricted.isAuthorized)
    }
}
