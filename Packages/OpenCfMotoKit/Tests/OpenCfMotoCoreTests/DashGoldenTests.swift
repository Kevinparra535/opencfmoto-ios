// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden vectors produced by running the ORIGINAL Kotlin (verbatim copies of GpxNav.formatSpeed,
// GpxNav.zoomForSpeedKmh, GpxDashUi.followZoom, VideoPipeline density rule and
// DashMapController.offsetMeters) on the JVM — real String.format HALF_UP and Float maths.
import XCTest
@testable import OpenCfMotoCore

final class DashGoldenTests: XCTestCase {
    func testFormatSpeedMatchesKotlin() {
        // (m/s, metric, imperial) — speed = loc.speed (Float) * 3.6f
        let vectors: [(Double, String, String)] = [
            (0.0, "0", "0"), (0.5, "2", "1"), (1.2, "4", "3"), (2.7777, "10", "6"), (3.4722223, "13", "8"),
            (4.0277777, "14", "9"), (9.7222, "35", "22"), (12.5, "45", "28"), (13.888889, "50", "31"),
            (27.777779, "100", "62"), (33.3, "120", "74"), (41.666668, "150", "93"), (55.55, "200", "124"),
        ]
        for (mps, metric, imperial) in vectors {
            XCTAssertEqual(DashFormat.speed(mps: mps, units: .metric), metric, "\(mps) m/s")
            XCTAssertEqual(DashFormat.speed(mps: mps, units: .imperial), imperial, "\(mps) m/s")
        }
    }

    func testZoomLadderMatchesKotlin() {
        // (km/h, zoomForSpeedKmh, bike followZoom)
        let vectors: [(Double, Double, Double)] = [
            (0, 17.8, 18.6), (7.99, 17.8, 18.6), (8, 17.0, 18.1), (19.99, 17.0, 18.1), (20, 16.2, 17.3), (34.9, 16.2, 17.3),
            (35, 15.4, 16.5), (54.9, 15.4, 16.5), (55, 14.6, 15.7), (79.9, 14.6, 15.7), (80, 13.8, 14.9),
            (109.9, 13.8, 14.9), (110, 13.0, 14.1), (200, 13.0, 14.1),
        ]
        for (kmh, z, f) in vectors {
            XCTAssertEqual(DashCamera.zoomForSpeedKmh(kmh), z, "\(kmh)")
            XCTAssertEqual(DashCamera.bikeFollowZoom(speedKmh: kmh), f, accuracy: 1e-12, "\(kmh)")
        }
    }

    func testDensityMatchesKotlin() {
        let vectors: [(Double, Int)] = [(544, 160), (720, 160), (800, 160), (1001, 178), (1024, 182), (1280, 228), (1920, 341), (5000, 640)]
        for (w, dpi) in vectors { XCTAssertEqual(DashDensity.densityDpi(canvasWidth: w), dpi, "\(w)") }
    }

    func testOffsetMetersMatchesKotlin() {
        // offsetMeters(lat, 7.0, bearing, 70 m)
        let vectors: [(Double, Double, Double, Double)] = [
            (45.0, 0, 45.000628817822, 7.000000000000),
            (45.0, 90, 45.000000000000, 7.000889282693),
            (4.65, 137, 4.649540111758, 7.000430268949),
            (89.0, 90, 89.000000000000, 7.003144089112),
            (-33.9, 271.5, -33.899983539468, 6.999242658990),
        ]
        for (lat, b, eLat, eLon) in vectors {
            let o = DashGeo.offset(GeoPoint(lat: lat, lon: 7), bearingDeg: b, meters: 70)
            XCTAssertEqual(o.lat, eLat, accuracy: 1e-11, "\(lat) \(b)")
            XCTAssertEqual(o.lon, eLon, accuracy: 1e-11, "\(lat) \(b)")
        }
    }
}
