// SPDX-License-Identifier: AGPL-3.0-or-later
// Smooth follow camera (iOS addition, navigation-dash.md §4.9 / §15.3): the drawn map eases from the
// previous picture to the follow targets over `Options.followEaseDuration`; 0 = osmdroid's jump.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class DashFollowEaseTests: XCTestCase {
    // MARK: Helpers

    /// The model with its rider moved by (north, east) metres (new fix + snapped puck).
    static func moved(_ m0: DashModel, north: Double, east: Double, kmh: Double, course: Double?) -> DashModel {
        var m = m0
        let base = m0.riderPosition ?? DashFixtures.rider
        let mLat = 111_320.0, mLon = 111_320.0 * cos(base.lat * .pi / 180)
        let p = GeoPoint(lat: base.lat + north / mLat, lon: base.lon + east / mLon)
        m.fix = DashFixtures.fix(p, kmh: kmh, course: course)
        m.nav.puck = p
        return m
    }

    static func options(duration: TimeInterval) -> DashUIController.Options {
        var o = DashUIController.Options()
        o.followEaseDuration = duration
        return o
    }

    /// Centre of the drawn puck (its shadow disc, r 15 dp) in a display list. The disc's control
    /// points are point-symmetric, so their bounds stay centred on the puck when it is rotated
    /// (they only grow, up to 30·√2).
    static func drawnPuck(_ list: DashDisplayList) -> DashPoint? {
        for cmd in list.commands.reversed() {
            if case let .fill(p, c, _) = cmd, c == DashPalette.puckShadow, let b = p.controlPointBounds,
               b.width > 29.5, b.width < 46 {
                return b.center
            }
        }
        return nil
    }

    /// The blue chevron of the puck points straight up on screen.
    static func puckIsUpright(_ list: DashDisplayList, file: StaticString = #filePath, line: UInt = #line) {
        let chevron = list.commands.compactMap { cmd -> DashPath? in
            if case let .fill(p, c, _) = cmd, c == DashPalette.puckBlue { return p }
            return nil
        }.last
        guard let chevron, case let .move(tip)? = chevron.elements.first, let b = chevron.controlPointBounds else {
            return XCTFail("no puck chevron", file: file, line: line)
        }
        XCTAssertEqual(tip.x, b.midX, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(tip.y, b.minY, accuracy: 1e-6, file: file, line: line)
    }

    private func touch(_ ui: DashUIController, _ a: DashTouch.Action, _ p: DashPoint, _ t: TimeInterval) -> [DashIntent] {
        ui.handle(.touch(DashTouch(action: a, pointerId: 0, x: Int(p.x), y: Int(p.y), time: t)), now: t)
    }

    /// `m0` (default: free ride at the fixture rider, 42 km/h, course 20 → heading-up, zoom 16.5,
    /// 70 m look-ahead) drawn one second before `start`, then the model `m1`; the ease is started by
    /// the frame at `start`.
    private func easing(from m0: DashModel = DashFixtures.freeRide(), to m1: DashModel, options: DashUIController.Options = .init(),
                        start: TimeInterval = 101) -> DashUIController {
        let ui = DashUIController(options: options)
        ui.update(m0)
        _ = ui.displayList(now: start - 1)
        ui.update(m1)
        _ = ui.displayList(now: start)
        return ui
    }

    // MARK: Curve, bearings, projection helpers

    func testEaseOutCurve() {
        XCTAssertEqual(DashEasing.easeOut(0), 0)
        XCTAssertEqual(DashEasing.easeOut(1), 1)
        XCTAssertEqual(DashEasing.easeOut(0.5), 0.875) // 1 − 0.5³
        XCTAssertEqual(DashEasing.easeOut(-3), 0)
        XCTAssertEqual(DashEasing.easeOut(7), 1)
        var last = 0.0
        for i in 1 ... 100 {
            let v = DashEasing.easeOut(Double(i) / 100)
            XCTAssertGreaterThan(v, last)
            XCTAssertGreaterThanOrEqual(v, Double(i) / 100) // ease-out: always ahead of linear
            last = v
        }
    }

    func testBearingsTurnTheShortWay() {
        XCTAssertEqual(DashEasing.shortestTurnDeg(from: 359, to: 1), 2, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.shortestTurnDeg(from: 1, to: 359), -2, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.shortestTurnDeg(from: 10, to: 190), 180, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.shortestTurnDeg(from: 0, to: 720 + 30), 30, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.shortestTurnDeg(from: -30, to: 30), 60, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.interpolateBearing(359, 1, 0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.interpolateBearing(359, 1, 0.875), 0.75, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.interpolateBearing(350, 20, 0.5), 5, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.interpolateBearing(20, 350, 0.5), 5, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.interpolateBearing(90, 270, 0), 90)
        XCTAssertEqual(DashEasing.normalizedBearing(-10), 350, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.normalizedBearing(360), 0)
        XCTAssertEqual(DashEasing.normalizedBearing(720.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(DashEasing.normalizedBearing(-1e-17), 0) // never 360
        XCTAssertEqual(DashEasing.normalizedBearing(.nan), 0)
    }

    func testMercatorInterpolation() {
        let a = GeoPoint(lat: 45.1, lon: 25.7), b = GeoPoint(lat: 45.2, lon: 25.9)
        XCTAssertEqual(MapProjection.interpolate(a, b, fraction: 0), a)
        XCTAssertEqual(MapProjection.interpolate(a, b, fraction: 1), b)
        let mid = MapProjection.interpolate(a, b, fraction: 0.5)
        let wa = MapProjection.worldPoint(a, zoom: 10), wb = MapProjection.worldPoint(b, zoom: 10)
        let wm = MapProjection.worldPoint(mid, zoom: 10)
        XCTAssertEqual(wm.x, (wa.x + wb.x) / 2, accuracy: 1e-6) // straight on the Mercator plane
        XCTAssertEqual(wm.y, (wa.y + wb.y) / 2, accuracy: 1e-6)
        XCTAssertEqual(mid.lon, 25.8, accuracy: 1e-12)
        // across the antimeridian the short way
        let e = MapProjection.interpolate(GeoPoint(lat: 0, lon: 179.9), GeoPoint(lat: 0, lon: -179.9), fraction: 0.25)
        XCTAssertEqual(e.lon, 179.95, accuracy: 1e-9)
        let w = MapProjection.interpolate(GeoPoint(lat: 0, lon: 179.9), GeoPoint(lat: 0, lon: -179.9), fraction: 0.75)
        XCTAssertEqual(w.lon, -179.95, accuracy: 1e-9)
    }

    func testCenterPlacingAPointAtAScreenOffset() {
        let p = GeoPoint(lat: 45.127, lon: 25.734)
        let vp = DashSize(width: 800, height: 384)
        for bearing in [0.0, 37, 200, 359] {
            for offset in [DashPoint(0, 0), DashPoint(0, 102), DashPoint(-40, 75.5)] {
                let c = MapProjection.center(placing: p, atScreenOffset: offset, zoom: 17.3, bearingDeg: bearing)
                let s = MapProjection(center: c, zoom: 17.3, bearingDeg: bearing, viewport: vp).screenPoint(p)
                XCTAssertEqual(s.x, 400 + offset.x, accuracy: 1e-6, "\(bearing) \(offset)")
                XCTAssertEqual(s.y, 192 + offset.y, accuracy: 1e-6, "\(bearing) \(offset)")
            }
        }
    }

    func testEaseClockStartsOnFirstFrameAndNeverRewinds() throws {
        let from = DashMapView(center: DashFixtures.rider, zoom: 16, bearingDeg: 10, puck: DashFixtures.rider, puckBearingDeg: 10)
        var to = from
        to.zoom = 17
        XCTAssertNil(DashFollowEase(from: from, to: to, duration: 0, tileSize: 256, movesCamera: true))
        var noPuck = to
        noPuck.puck = nil
        XCTAssertNil(DashFollowEase(from: from, to: noPuck, duration: 1, tileSize: 256, movesCamera: true))
        var e = try XCTUnwrap(DashFollowEase(from: from, to: to, duration: 1, tileSize: 256, movesCamera: true))
        XCTAssertNil(e.start)
        XCTAssertEqual(e.view(base: to), from) // not started: the previous picture
        XCTAssertTrue(e.advance(to: 50))
        XCTAssertEqual(e.start, 50)
        XCTAssertEqual(e.view(base: to), from)
        XCTAssertTrue(e.advance(to: 50.5))
        XCTAssertEqual(e.progress, 0.5)
        XCTAssertEqual(e.view(base: to).zoom, 16.875, accuracy: 1e-12)
        XCTAssertTrue(e.advance(to: 50.2)) // an older `now` (another thread) does not rewind
        XCTAssertEqual(e.progress, 0.5)
        XCTAssertFalse(e.advance(to: 51))
        XCTAssertEqual(e.view(base: to), to)
    }

    // MARK: Controller — follow updates ease

    func testFollowUpdateEasesCentreBearingZoomAndPuckTogether() throws {
        let m1 = Self.moved(DashFixtures.freeRide(), north: 12, east: 8, kmh: 25, course: 35) // zoom 16.5 → 17.3
        let ui = DashUIController()
        ui.update(DashFixtures.freeRide())
        let before = ui.displayList(now: 100)
        let p0 = try XCTUnwrap(ui.mapProjection(now: 100))
        let y0 = try XCTUnwrap(Self.drawnPuck(before)).y
        ui.update(m1)
        // the targets jump (osmdroid policy) …
        let target = try XCTUnwrap(ui.mapProjection())
        XCTAssertEqual(target.zoom, 17.3, accuracy: 1e-9)
        XCTAssertEqual(target.bearingDeg, 35, accuracy: 1e-9)
        XCTAssertEqual(ui.state.camera.zoom, 17.3, accuracy: 1e-9)
        let puck1 = try XCTUnwrap(m1.riderPosition)
        let y1 = target.screenPoint(puck1).y
        // … the picture does not: the frame that starts the ease still shows the previous one
        let first = ui.displayList(now: 101)
        XCTAssertEqual(ui.mapProjection(now: 101), p0)
        XCTAssertEqual(try XCTUnwrap(Self.drawnPuck(first)).y, y0, accuracy: 1e-9)
        XCTAssertTrue(ui.isAnimating(now: 101))
        // half the duration = 87.5 % of the way (cubic ease-out)
        let t = 101 + 0.35 / 2
        let k = DashEasing.easeOut(0.5)
        let mid = try XCTUnwrap(ui.mapProjection(now: t))
        XCTAssertEqual(mid.zoom, 16.5 + (17.3 - 16.5) * k, accuracy: 1e-9)
        XCTAssertEqual(mid.bearingDeg, 20 + 15 * k, accuracy: 1e-9)
        let puckMid = MapProjection.interpolate(DashFixtures.rider, puck1, fraction: k)
        let s = mid.screenPoint(puckMid)
        XCTAssertEqual(s.x, 400, accuracy: 0.01) // heading-up: on the vertical centre line
        XCTAssertEqual(s.y, y0 + (y1 - y0) * k, accuracy: 0.01) // look-ahead offset eased on screen
        let list = ui.displayList(now: t)
        let drawn = try XCTUnwrap(Self.drawnPuck(list))
        XCTAssertEqual(drawn.x, s.x, accuracy: 1e-6)
        XCTAssertEqual(drawn.y, s.y, accuracy: 1e-6)
        Self.puckIsUpright(list)
        // the tiles drawn are the ones of the drawn camera
        let tiles = list.commands.compactMap { cmd -> DashMapTile? in
            if case let .tile(z, x, y, r, _) = cmd { return DashMapTile(z: z, x: x, y: y, rect: r) }
            return nil
        }
        XCTAssertEqual(tiles, ui.visibleTiles(now: t))
        XCTAssertEqual(ui.visibleTiles(now: t), mid.visibleTiles())
    }

    func testEaseEndsExactlyAtTheDurationOnTheJumpPicture() throws {
        let m1 = Self.moved(DashFixtures.freeRide(), north: 12, east: 8, kmh: 25, course: 35)
        let ui = easing(to: m1, start: 51)
        XCTAssertTrue(ui.isAnimating(now: 51 + 0.349))
        XCTAssertNotEqual(ui.mapProjection(now: 51 + 0.349), ui.mapProjection())
        XCTAssertFalse(ui.isAnimating(now: 51 + 0.35))
        XCTAssertEqual(ui.mapProjection(now: 51 + 0.35), ui.mapProjection())
        // the final frame is exactly what the jump (osmdroid parity) draws
        let jump = DashUIController(options: Self.options(duration: 0))
        jump.update(DashFixtures.freeRide())
        jump.update(m1)
        XCTAssertEqual(ui.displayList(now: 52), jump.displayList(now: 52))
    }

    func testListIsStableOnceTheEaseIsOver() {
        let ui = easing(to: Self.moved(DashFixtures.freeRide(), north: 10, east: 4, kmh: 42, course: 26), start: 20)
        let during = (0 ... 6).map { ui.displayList(now: 20 + Double($0) * 0.05) }
        for (i, (a, b)) in zip(during, during.dropFirst()).enumerated() {
            XCTAssertNotEqual(a, b, "frame \(i + 1) of the ease changes the picture")
        }
        let end = ui.displayList(now: 20.35)
        XCTAssertNotEqual(end, during.last)
        XCTAssertFalse(ui.isAnimating(now: 20.36))
        XCTAssertEqual(ui.displayList(now: 20.4), end) // no extra frames while still
        XCTAssertEqual(ui.displayList(now: 60), end)
        XCTAssertEqual(ui.displayList(now: 60), ui.displayList(now: 60))
    }

    func testRetargetMidEaseContinuesFromTheDrawnPicture() throws {
        let m0 = DashFixtures.freeRide()
        let ui = easing(to: Self.moved(m0, north: 15, east: 5, kmh: 42, course: 30), start: 10)
        let shown = try XCTUnwrap(ui.mapProjection(now: 10.1))
        let target1 = try XCTUnwrap(ui.mapProjection())
        XCTAssertNotEqual(shown, target1)
        ui.update(Self.moved(m0, north: 30, east: 12, kmh: 42, course: 40))
        let target2 = try XCTUnwrap(ui.mapProjection())
        // no snap back and no jump ahead: the next frame shows exactly what was on screen …
        XCTAssertEqual(ui.mapProjection(now: 10.15), shown)
        // … then it heads for the new targets over a full duration
        let mid = try XCTUnwrap(ui.mapProjection(now: 10.15 + 0.175))
        let k = DashEasing.easeOut(0.5)
        XCTAssertEqual(mid.bearingDeg, shown.bearingDeg + (40 - shown.bearingDeg) * k, accuracy: 1e-6)
        XCTAssertGreaterThan(mid.bearingDeg, shown.bearingDeg)
        XCTAssertTrue(ui.isAnimating(now: 10.15 + 0.34))
        XCTAssertEqual(ui.mapProjection(now: 10.15 + 0.35), target2)
        XCTAssertFalse(ui.isAnimating(now: 10.5))
    }

    func testModelChangesThatKeepTheTargetsDoNotRestartTheEase() throws {
        let m1 = Self.moved(DashFixtures.freeRide(), north: 15, east: 5, kmh: 42, course: 30)
        let ui = easing(to: m1, start: 10)
        let at = try XCTUnwrap(ui.mapProjection(now: 10.2))
        var same = m1
        same.toastText = "Routing…"
        same.recording = true
        ui.update(same) // same fix: same targets
        XCTAssertEqual(ui.mapProjection(now: 10.2), at)
        XCTAssertTrue(ui.isAnimating(now: 10.3))
        XCTAssertFalse(ui.isAnimating(now: 10.35)) // still on the original schedule
        XCTAssertEqual(ui.mapProjection(now: 10.35), ui.mapProjection())
    }

    func testBearingEasesTheShortWayAcrossNorth() throws {
        let m0 = Self.moved(DashFixtures.freeRide(), north: 0, east: 0, kmh: 42, course: 359)
        let ui = DashUIController()
        ui.update(m0)
        _ = ui.displayList(now: 0)
        XCTAssertEqual(try XCTUnwrap(ui.mapProjection(now: 0)).bearingDeg, 359, accuracy: 1e-9)
        ui.update(Self.moved(m0, north: 10, east: 0, kmh: 42, course: 1))
        _ = ui.displayList(now: 1)
        for i in 0 ... 7 {
            let b = try XCTUnwrap(ui.mapProjection(now: 1 + Double(i) * 0.05)).bearingDeg
            XCTAssertTrue(b >= 0 && b < 360, "\(b)")
            XCTAssertLessThanOrEqual(min(b, 360 - b), 1 + 1e-9, "step \(i): \(b) must stay within 1° of north")
        }
        let ui2 = DashUIController()
        ui2.update(m0)
        _ = ui2.displayList(now: 0)
        ui2.update(Self.moved(m0, north: 10, east: 0, kmh: 42, course: 1))
        _ = ui2.displayList(now: 1)
        XCTAssertEqual(try XCTUnwrap(ui2.mapProjection(now: 1.175)).bearingDeg, 0.75, accuracy: 1e-6) // 359 + 2·0.875
        let list = ui2.displayList(now: 1.175)
        Self.puckIsUpright(list) // puck and map turn together
    }

    func testZoomOnlyChangeEasesTheZoom() throws {
        // same place and course, slower: speed zoom 16.5 → 17.3 (|Δ| ≥ 0.35), look-ahead 70 m → 40 m
        let m1 = Self.moved(DashFixtures.freeRide(), north: 0, east: 0, kmh: 25, course: 20)
        let ui = easing(to: m1, start: 5)
        for (i, p) in [0.25, 0.5, 0.75].enumerated() {
            let proj = try XCTUnwrap(ui.mapProjection(now: 5 + 0.35 * p))
            XCTAssertEqual(proj.zoom, 16.5 + 0.8 * DashEasing.easeOut(p), accuracy: 1e-9, "step \(i)")
            XCTAssertEqual(proj.bearingDeg, 20, accuracy: 1e-9)
            XCTAssertEqual(proj.screenPoint(DashFixtures.rider).x, 400, accuracy: 0.01)
        }
        XCTAssertEqual(try XCTUnwrap(ui.mapProjection(now: 5.35)).zoom, 17.3, accuracy: 1e-9)
        XCTAssertEqual(ui.mapProjection(now: 5.35), ui.mapProjection())
    }

    func testPuckStaysOnTheCentreLineDuringATurnWithLookAhead() throws {
        // heading-up, moving: a 90° turn plus 30 m of travel; the puck must stay exactly below the
        // anchor (never swing sideways) while the map rotates under it
        let m0 = DashFixtures.freeRide()
        let m1 = Self.moved(m0, north: 20, east: 22, kmh: 42, course: 110)
        let ui = easing(to: m1, start: 3)
        let y0 = 192 + 70 / MapProjection.metersPerPixel(latitude: DashFixtures.rider.lat, zoom: 16.5)
        var lastY = -Double.infinity
        var lastB = -Double.infinity
        for i in 0 ... 14 {
            let t = 3 + Double(i) * 0.025
            let list = ui.displayList(now: t)
            let puck = try XCTUnwrap(Self.drawnPuck(list), "step \(i)")
            XCTAssertEqual(puck.x, 400, accuracy: 0.01, "step \(i)")
            XCTAssertEqual(puck.y, y0, accuracy: 0.05, "step \(i)") // same look-ahead at both ends
            Self.puckIsUpright(list)
            let b = try XCTUnwrap(ui.mapProjection(now: t)).bearingDeg
            XCTAssertGreaterThanOrEqual(b, lastB)
            lastB = b
            lastY = puck.y
        }
        XCTAssertEqual(lastY, y0, accuracy: 0.05)
        XCTAssertFalse(ui.isAnimating(now: 3.35))
    }

    func testPuckGlidesWhileTheCameraIsNotFollowing() throws {
        let ui = DashUIController()
        ui.update(DashFixtures.freeRide())
        _ = ui.displayList(now: 0)
        _ = ui.perform(.zoomIn, now: 0.5) // free pan: the camera stays put
        let cam = try XCTUnwrap(ui.mapProjection())
        let m1 = Self.moved(DashFixtures.freeRide(), north: 15, east: 10, kmh: 42, course: 40)
        ui.update(m1)
        XCTAssertEqual(ui.mapProjection(), cam)
        _ = ui.displayList(now: 1)
        let k = DashEasing.easeOut(0.5)
        let list = ui.displayList(now: 1.175)
        XCTAssertEqual(ui.mapProjection(now: 1.175), cam)
        let expected = cam.screenPoint(MapProjection.interpolate(DashFixtures.rider, try XCTUnwrap(m1.riderPosition), fraction: k))
        let drawn = try XCTUnwrap(Self.drawnPuck(list))
        XCTAssertEqual(drawn.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(drawn.y, expected.y, accuracy: 1e-6)
        XCTAssertFalse(ui.isAnimating(now: 1.35))
        let end = try XCTUnwrap(Self.drawnPuck(ui.displayList(now: 1.35)))
        let target = cam.screenPoint(try XCTUnwrap(m1.riderPosition))
        XCTAssertEqual(end.x, target.x, accuracy: 1e-9)
        XCTAssertEqual(end.y, target.y, accuracy: 1e-9)
    }

    // MARK: Controller — what does not ease

    func testSensorNoiseBelowTwoPixelsJumps() throws {
        // stopped in heading-up: the smoothed compass drives the map bearing at ≤ 8 Hz
        var m0 = DashFixtures.freeRide()
        m0.fix = DashFixtures.fix(kmh: 0, course: nil)
        m0.compassHeadingDeg = 18
        let ui = DashUIController()
        ui.update(m0)
        _ = ui.displayList(now: 0)
        XCTAssertEqual(ui.state.camera.zoom, 18.6, accuracy: 1e-9)
        var jitter = m0
        jitter.compassHeadingDeg = 18.1 // ≈ 0.8 px at the canvas corners
        ui.update(jitter)
        XCTAssertFalse(ui.isAnimating(now: 0.1))
        XCTAssertEqual(try XCTUnwrap(ui.mapProjection(now: 0.1)).bearingDeg, 18.1, accuracy: 1e-9)
        // 20 cm of GPS noise at zoom 18.6 (≈ 0.27 m/px): jump as well
        ui.update(Self.moved(jitter, north: 0.2, east: 0, kmh: 0, course: nil))
        XCTAssertFalse(ui.isAnimating(now: 0.2))
        XCTAssertEqual(ui.mapProjection(now: 0.2), ui.mapProjection())
        // turning the parked bike by 12°: eased
        var turn = jitter
        turn.compassHeadingDeg = 30
        ui.update(turn)
        XCTAssertTrue(ui.isAnimating(now: 0.3))
        XCTAssertEqual(try XCTUnwrap(ui.mapProjection(now: 0.3)).bearingDeg, 18.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ui.mapProjection(now: 0.65)).bearingDeg, 30, accuracy: 1e-9)
    }

    func testZeroDurationJumpsLikeOsmdroid() throws {
        let ui = DashUIController(options: Self.options(duration: 0))
        ui.update(DashFixtures.freeRide())
        _ = ui.displayList(now: 1)
        ui.update(Self.moved(DashFixtures.freeRide(), north: 12, east: 8, kmh: 25, course: 35))
        XCTAssertFalse(ui.isAnimating(now: 1))
        XCTAssertEqual(ui.mapProjection(now: 1), ui.mapProjection())
        let a = ui.displayList(now: 1.1)
        XCTAssertEqual(ui.displayList(now: 1.2), a)
    }

    func testFirstPositioningFarJumpsPreviewAndNavigationStartDoNotEase() throws {
        // first fix: nothing on screen yet
        let fresh = DashUIController()
        fresh.update(DashFixtures.freeRide())
        XCTAssertFalse(fresh.isAnimating(now: 0))
        // a 5 km GPS jump is not animated
        let far = easing(to: Self.moved(DashFixtures.freeRide(), north: 5_000, east: 0, kmh: 42, course: 20))
        XCTAssertFalse(far.isAnimating(now: 101))
        XCTAssertEqual(far.mapProjection(now: 101), far.mapProjection())
        // preview fit (explicit camera action)
        let preview = easing(to: DashFixtures.preview())
        XCTAssertFalse(preview.isAnimating(now: 101))
        XCTAssertEqual(preview.mapProjection(now: 101), preview.mapProjection())
        // navigation start from the preview overview
        preview.update(DashFixtures.navigating())
        XCTAssertFalse(preview.isAnimating(now: 102))
        XCTAssertEqual(preview.mapProjection(now: 102), preview.mapProjection())
        // a canvas change jumps
        let canvas = easing(to: Self.moved(DashFixtures.freeRide(DashFixtures.port), north: 10, east: 0, kmh: 42, course: 20))
        XCTAssertFalse(canvas.isAnimating(now: 101))
    }

    func testExplicitCameraActionsMidEase() throws {
        let m1 = Self.moved(DashFixtures.freeRide(), north: 12, east: 8, kmh: 25, course: 35)
        // Recenter jumps to the targets
        let r = easing(to: m1, start: 10)
        _ = r.displayList(now: 10.1)
        XCTAssertEqual(r.perform(.recenter, now: 10.1), [.recenter])
        XCTAssertFalse(r.isAnimating(now: 10.1))
        XCTAssertEqual(r.mapProjection(now: 10.1), r.mapProjection())
        // Zoom in: +1 from the zoom on screen; the camera then stays put while the puck lands
        let z = easing(to: m1, start: 10)
        let shown = try XCTUnwrap(z.mapProjection(now: 10.1))
        _ = z.perform(.zoomIn, now: 10.1)
        let cam = try XCTUnwrap(z.mapProjection())
        XCTAssertEqual(cam.zoom, shown.zoom + 1, accuracy: 1e-9)
        XCTAssertEqual(cam.center, shown.center)
        XCTAssertEqual(cam.bearingDeg, shown.bearingDeg)
        XCTAssertFalse(z.state.camera.follow)
        XCTAssertTrue(z.isAnimating(now: 10.2)) // the puck is still gliding …
        XCTAssertEqual(z.mapProjection(now: 10.2), cam) // … the camera is not
        XCTAssertFalse(z.isAnimating(now: 10.35))
        XCTAssertEqual(z.mapProjection(now: 10.4), cam)
        // Overview fits north-up at once
        let nav = DashFixtures.navigating()
        let o = easing(from: nav, to: Self.moved(nav, north: 10, east: 3, kmh: 47, course: 25))
        XCTAssertTrue(o.isAnimating(now: 101.1))
        _ = o.perform(.overview, now: 101.1)
        XCTAssertFalse(o.isAnimating(now: 101.1))
        XCTAssertEqual(o.mapProjection(now: 101.1)?.bearingDeg, 0)
        // Compass toggle jumps
        let c = easing(to: m1, start: 10)
        _ = c.perform(.toggleCompass, now: 10.1)
        XCTAssertFalse(c.isAnimating(now: 10.1))
        XCTAssertEqual(c.mapProjection(now: 10.1), c.mapProjection())
        XCTAssertEqual(c.mapProjection(now: 10.1)?.bearingDeg, 0)
        // Follow off from the menu: the map stays where it is drawn
        let f = easing(to: m1, start: 10)
        let onScreen = try XCTUnwrap(f.mapProjection(now: 10.1))
        _ = f.perform(.toggleFollow, now: 10.1)
        XCTAssertEqual(f.mapProjection(), onScreen)
        XCTAssertEqual(f.mapProjection(now: 10.3), onScreen)
    }

    func testAutoRecenterAfterFreePanJumps() throws {
        let ui = DashUIController()
        ui.update(DashFixtures.freeRide())
        _ = ui.perform(.zoomIn, now: 1)
        ui.update(Self.moved(DashFixtures.freeRide(), north: 12, east: 0, kmh: 42, course: 20))
        _ = ui.tick(now: 13.01) // 12 s later: follow again
        XCTAssertTrue(ui.state.camera.follow)
        XCTAssertFalse(ui.isAnimating(now: 13.01))
        XCTAssertEqual(ui.mapProjection(now: 13.01), ui.mapProjection())
    }

    // MARK: Controller — input on the drawn picture

    func testHitRegionsDoNotMoveWithTheMap() {
        let m1 = Self.moved(DashFixtures.freeRide(), north: 12, east: 8, kmh: 25, course: 35)
        let ui = easing(to: m1, start: 10)
        let jump = DashUIController(options: Self.options(duration: 0))
        jump.update(DashFixtures.freeRide())
        jump.update(m1)
        let mid = ui.displayList(now: 10.15)
        XCTAssertTrue(ui.isAnimating(now: 10.15))
        XCTAssertFalse(mid.hitRegions.isEmpty)
        XCTAssertEqual(mid.hitRegions, jump.displayList(now: 10.15).hitRegions)
        XCTAssertEqual(mid.hitTest(DashPoint(771, 31))?.id, "fab.recenter")
        XCTAssertEqual(touch(ui, .down, DashPoint(771, 31), 10.16) + touch(ui, .up, DashPoint(771, 31), 10.2), [.recenter])
    }

    func testLongPressDropsThePinUnderTheFingerInTheDrawnPicture() throws {
        let m1 = Self.moved(DashFixtures.freeRide(), north: 40, east: 25, kmh: 25, course: 60)
        let ui = easing(to: m1, options: Self.options(duration: 2), start: 10) // long enough for a long-press mid-ease
        let p = DashPoint(300, 150)
        XCTAssertEqual(touch(ui, .down, p, 10.5), [])
        let out = ui.tick(now: 10.96)
        guard case let .dropPin(g)? = out.first, out.count == 1 else { return XCTFail("expected dropPin, got \(out)") }
        XCTAssertTrue(ui.isAnimating(now: 10.96))
        let drawn = try XCTUnwrap(ui.mapProjection(now: 10.96)).geoPoint(atScreen: p)
        XCTAssertEqual(g.lat, drawn.lat, accuracy: 1e-12)
        XCTAssertEqual(g.lon, drawn.lon, accuracy: 1e-12)
        let resting = try XCTUnwrap(ui.mapProjection()).geoPoint(atScreen: p)
        XCTAssertGreaterThan(DashGeo.distanceM(g, resting), 1) // not the target camera's point
    }

    func testPanMidEaseDragsTheDrawnPicture() throws {
        let m1 = Self.moved(DashFixtures.freeRide(), north: 40, east: 25, kmh: 25, course: 60)
        let ui = easing(to: m1, options: Self.options(duration: 2), start: 10)
        let start = DashPoint(300, 200)
        _ = touch(ui, .down, start, 10.4)
        let g = try XCTUnwrap(ui.mapProjection(now: 10.45)).geoPoint(atScreen: start) // on screen when the drag starts
        _ = touch(ui, .move, DashPoint(330, 220), 10.45)
        _ = touch(ui, .move, DashPoint(360, 230), 10.5)
        _ = touch(ui, .up, DashPoint(360, 230), 10.55)
        XCTAssertFalse(ui.state.camera.follow)
        for t in [10.55, 11.0, 13.0] {
            let s = try XCTUnwrap(ui.mapProjection(now: t)).screenPoint(g)
            XCTAssertEqual(s.x, 360, accuracy: 1e-6, "\(t)")
            XCTAssertEqual(s.y, 230, accuracy: 1e-6, "\(t)")
        }
    }

    func testConcurrentUpdatesAndFrames() {
        let ui = DashUIController()
        let models = (0 ..< 8).map { Self.moved(DashFixtures.freeRide(), north: Double($0) * 6, east: Double($0) * 2, kmh: 42, course: 20 + Double($0)) }
        ui.update(models[0])
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let t = Double(i) * 0.01
            switch i % 5 {
            case 0: ui.update(models[(i / 5) % models.count])
            case 1: _ = ui.displayList(now: t)
            case 2: _ = ui.isAnimating(now: t)
            case 3: _ = ui.mapProjection(now: t)
            default: _ = ui.tick(now: t)
            }
        }
        _ = ui.displayList(now: 999) // starts an ease the last update may have left pending
        XCTAssertFalse(ui.isAnimating(now: 1_000))
        XCTAssertEqual(ui.mapProjection(now: 1_000), ui.mapProjection())
        XCTAssertEqual(ui.displayList(now: 1_001), ui.displayList(now: 1_002))
    }
}
