// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import OpenCfMotoCore

final class DashMapProjectionTests: XCTestCase {
    let vp = DashSize(width: 800, height: 384)

    func testWorldPointsAndKnownTile() {
        let o = MapProjection.worldPoint(GeoPoint(lat: 0, lon: 0), zoom: 0)
        XCTAssertEqual(o.x, 128, accuracy: 1e-9)
        XCTAssertEqual(o.y, 128, accuracy: 1e-9)
        // Bucharest at z15 → slippy tile 18759/11860
        let w = MapProjection.worldPoint(GeoPoint(lat: 44.4268, lon: 26.1025), zoom: 15)
        XCTAssertEqual(w.x, 4_802_536.334222222, accuracy: 1e-6)
        XCTAssertEqual(w.y, 3_036_387.7574397214, accuracy: 1e-6)
        XCTAssertEqual(Int(w.x / 256), 18759)
        XCTAssertEqual(Int(w.y / 256), 11860)
        // latitude is clamped to the Mercator limit
        let top = MapProjection.worldPoint(GeoPoint(lat: 89.9, lon: 0), zoom: 1)
        XCTAssertEqual(top.y, 0, accuracy: 1e-6)
        // tileSize scales the world (isTilesScaledToDpi on a 1280-wide dash)
        let big = MapProjection.worldPoint(GeoPoint(lat: 0, lon: 0), zoom: 0, tileSize: 256 * 1.425)
        XCTAssertEqual(big.x, 128 * 1.425, accuracy: 1e-9)
    }

    func testGeoRoundTrip() {
        for p in [GeoPoint(lat: 44.4268, lon: 26.1025), GeoPoint(lat: -33.86, lon: 151.21), GeoPoint(lat: 4.65, lon: -74.08)] {
            for z in [5.0, 13.37, 20.0] {
                let back = MapProjection.geoPoint(world: MapProjection.worldPoint(p, zoom: z), zoom: z)
                XCTAssertEqual(back.lat, p.lat, accuracy: 1e-9)
                XCTAssertEqual(back.lon, p.lon, accuracy: 1e-9)
            }
        }
        // longitude normalisation past the antimeridian
        let wrapped = MapProjection.geoPoint(world: DashPoint(256 + 64, 128), zoom: 0)
        XCTAssertEqual(wrapped.lon, -90, accuracy: 1e-9)
    }

    func testMetersPerPixel() {
        XCTAssertEqual(MapProjection.metersPerPixel(latitude: 0, zoom: 0), 156_543.033_928_040_97, accuracy: 1e-6)
        // navigation-dash.md §4.9 worked example: 45° N, zoom 18.1 → 0.394 m/px, 40 m ≈ 102 px
        let mpp = MapProjection.metersPerPixel(latitude: 45, zoom: 18.1)
        XCTAssertEqual(mpp, 0.3939814980400838, accuracy: 1e-12)
        XCTAssertEqual(40 / mpp, 101.53, accuracy: 0.01)
        // density-scaled tiles halve…scale the resolution
        XCTAssertEqual(MapProjection.metersPerPixel(latitude: 45, zoom: 18.1, tileSize: 512), mpp / 2, accuracy: 1e-12)
    }

    func testCenterMapsToAnchorAndBack() {
        let c = GeoPoint(lat: 45.1, lon: 24.5)
        let p = MapProjection(center: c, zoom: 16.4, bearingDeg: 37, viewport: vp)
        let s = p.screenPoint(c)
        XCTAssertEqual(s.x, 400, accuracy: 1e-6)
        XCTAssertEqual(s.y, 192, accuracy: 1e-6)
        for q in [DashPoint(0, 0), DashPoint(799, 383), DashPoint(123.4, 56.7)] {
            let g = p.geoPoint(atScreen: q)
            let back = p.screenPoint(g)
            XCTAssertEqual(back.x, q.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, q.y, accuracy: 1e-6)
        }
        let anchored = MapProjection(center: c, zoom: 16, viewport: vp, anchor: DashPoint(400, 203))
        XCTAssertEqual(anchored.screenPoint(c).y, 203, accuracy: 1e-6)
    }

    func testHeadingUpRotation() {
        let c = GeoPoint(lat: 0, lon: 0)
        let east = GeoPoint(lat: 0, lon: 0.001)
        let north = GeoPoint(lat: 0.001, lon: 0)
        // north-up: east is to the right, north is up
        let nu = MapProjection(center: c, zoom: 16, bearingDeg: 0, viewport: vp)
        XCTAssertGreaterThan(nu.screenPoint(east).x, 400)
        XCTAssertEqual(nu.screenPoint(east).y, 192, accuracy: 1e-6)
        XCTAssertLessThan(nu.screenPoint(north).y, 192)
        // travelling east (bearing 90): east points up, north points left
        let hu = MapProjection(center: c, zoom: 16, bearingDeg: 90, viewport: vp)
        XCTAssertEqual(hu.screenPoint(east).x, 400, accuracy: 1e-6)
        XCTAssertLessThan(hu.screenPoint(east).y, 192)
        XCTAssertLessThan(hu.screenPoint(north).x, 400)
        XCTAssertEqual(hu.screenPoint(north).y, 192, accuracy: 1e-6)
        // map transform rotates by −bearing
        let t = hu.mapToScreen
        let unitX = t.apply(DashPoint(1, 0))
        XCTAssertEqual(unitX.x - 400, 0, accuracy: 1e-12)
        XCTAssertEqual(unitX.y - 192, -1, accuracy: 1e-12)
    }

    func testVisibleTilesNorthUpOnTileCorner() {
        // Centre exactly on a tile corner at z16: 4 columns × 2 rows cover 800×384.
        let corner = MapProjection.geoPoint(world: DashPoint(37228 * 256, 23549 * 256), zoom: 16)
        let p = MapProjection(center: corner, zoom: 16, viewport: vp)
        let tiles = p.visibleTiles()
        XCTAssertEqual(tiles.count, 8)
        XCTAssertEqual(Set(tiles.map(\.z)), [16])
        XCTAssertEqual(Set(tiles.map(\.x)), [37226, 37227, 37228, 37229])
        XCTAssertEqual(Set(tiles.map(\.y)), [23548, 23549])
        let first = tiles[0]
        XCTAssertEqual(first.x, 37226)
        XCTAssertEqual(first.y, 23548)
        XCTAssertEqual(first.rect.minX, -512, accuracy: 1e-6)
        XCTAssertEqual(first.rect.minY, -256, accuracy: 1e-6)
        XCTAssertEqual(first.rect.width, 256, accuracy: 1e-9)
    }

    func testFractionalAndOverZoom() {
        let c = GeoPoint(lat: 45.1, lon: 24.5)
        let half = MapProjection(center: c, zoom: 16.5, viewport: vp).visibleTiles()
        XCTAssertTrue(half.allSatisfy { $0.z == 16 })
        XCTAssertEqual(half[0].rect.width, 256 * pow(2, 0.5), accuracy: 1e-9)
        let over = MapProjection(center: c, zoom: 20, viewport: vp).visibleTiles()
        XCTAssertTrue(over.allSatisfy { $0.z == 19 })
        XCTAssertEqual(over[0].rect.width, 512, accuracy: 1e-9)
        XCTAssertEqual(MapProjection.tileZoom(for: 16.9999), 16)
        XCTAssertEqual(MapProjection.tileZoom(for: 16.999999999999996), 17) // FP noise tolerated
        XCTAssertEqual(MapProjection.tileZoom(for: 17), 17)
        XCTAssertEqual(MapProjection.tileZoom(for: 20, maxTileZoom: 18), 18)
    }

    func testRotatedViewportIsFullyCovered() {
        let c = GeoPoint(lat: 45.1, lon: 24.5)
        for bearing in [0.0, 30, 45, 90, 137, 270] {
            let p = MapProjection(center: c, zoom: 17.3, bearingDeg: bearing, viewport: vp)
            let tiles = p.visibleTiles()
            // every sample point of the canvas falls inside some tile
            for sx in stride(from: 0.0, through: 800, by: 50) {
                for sy in stride(from: 0.0, through: 384, by: 48) {
                    let m = p.screenToMap.apply(DashPoint(sx, sy))
                    XCTAssertTrue(tiles.contains { t in
                        m.x >= t.rect.minX - 1e-6 && m.x <= t.rect.maxX + 1e-6 && m.y >= t.rect.minY - 1e-6 && m.y <= t.rect.maxY + 1e-6
                    }, "bearing \(bearing) point (\(sx),\(sy))")
                }
            }
            // no duplicates
            XCTAssertEqual(Set(tiles.map { "\($0.x)/\($0.y)/\($0.rect.minX)" }).count, tiles.count)
        }
        // rotation needs more tiles than north-up
        let nu = MapProjection(center: c, zoom: 17.3, bearingDeg: 0, viewport: vp).visibleTiles().count
        let r45 = MapProjection(center: c, zoom: 17.3, bearingDeg: 45, viewport: vp).visibleTiles().count
        XCTAssertGreaterThan(r45, nu)
    }

    func testAntimeridianWrapsTileColumns() {
        let p = MapProjection(center: GeoPoint(lat: 0, lon: 179.999), zoom: 10, viewport: vp)
        let xs = Set(p.visibleTiles().map(\.x))
        XCTAssertTrue(xs.contains(0))
        XCTAssertTrue(xs.contains(1023))
        // map-local stays continuous across the antimeridian
        let west = p.mapLocal(GeoPoint(lat: 0, lon: -179.999))
        XCTAssertGreaterThan(west.x, 0)
        XCTAssertLessThan(west.x, 10)
    }

    func testRowsOutsideTheWorldAreSkipped() {
        let p = MapProjection(center: GeoPoint(lat: 85, lon: 0), zoom: 5, viewport: vp)
        XCTAssertTrue(p.visibleTiles().allSatisfy { $0.y >= 0 && $0.y < 32 })
    }

    func testFittingTwoPoints() throws {
        let a = GeoPoint(lat: 45.10, lon: 24.40), b = GeoPoint(lat: 45.20, lon: 24.60)
        let rect = DashRect(x: 8, y: 64, width: 732, height: 146)
        let p = try XCTUnwrap(MapProjection.fitting([a, b], in: rect, viewport: vp))
        XCTAssertEqual(p.bearingDeg, 0)
        for g in [a, b] {
            let s = p.screenPoint(g)
            XCTAssertGreaterThanOrEqual(s.x, rect.minX - 1e-6)
            XCTAssertLessThanOrEqual(s.x, rect.maxX + 1e-6)
            XCTAssertGreaterThanOrEqual(s.y, rect.minY - 1e-6)
            XCTAssertLessThanOrEqual(s.y, rect.maxY + 1e-6)
        }
        // the limiting axis touches the rect edges (here: height)
        let sa = p.screenPoint(a), sb = p.screenPoint(b)
        XCTAssertEqual(abs(sa.y - sb.y), rect.height, accuracy: 1e-6)
        // box centred on the rect centre
        XCTAssertEqual((sa.x + sb.x) / 2, rect.midX, accuracy: 1e-6)
        XCTAssertEqual((sa.y + sb.y) / 2, rect.midY, accuracy: 1e-6)
    }

    func testFittingSinglePointAndClamp() throws {
        let a = GeoPoint(lat: 4.65, lon: -74.08)
        let one = try XCTUnwrap(MapProjection.fitting([a], in: DashRect(x: 0, y: 0, width: 800, height: 384), viewport: vp))
        XCTAssertEqual(one.zoom, 16)
        XCTAssertEqual(one.center.lat, a.lat, accuracy: 1e-9)
        XCTAssertEqual(one.center.lon, a.lon, accuracy: 1e-9)
        // continent-scale box clamps to the minimum zoom
        let far = try XCTUnwrap(MapProjection.fitting([GeoPoint(lat: -40, lon: -70), GeoPoint(lat: 60, lon: 100)],
                                                      in: DashRect(x: 0, y: 0, width: 800, height: 384), viewport: vp))
        XCTAssertEqual(far.zoom, 5)
        XCTAssertNil(MapProjection.fitting([], in: DashRect(x: 0, y: 0, width: 10, height: 10), viewport: vp))
        XCTAssertNil(MapProjection.fitting([a], in: .zero, viewport: vp))
    }

    func testGeoHelpers() {
        // GpxNavTest vectors: 0.01° of latitude ≈ 1111.95 m
        XCTAssertEqual(DashGeo.distanceM(GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 0.01, lon: 0)), 1111.9493, accuracy: 0.001)
        XCTAssertEqual(DashGeo.bearingDeg(from: GeoPoint(lat: 0, lon: 0), to: GeoPoint(lat: 0, lon: 1)), 90, accuracy: 1e-9)
        XCTAssertEqual(DashGeo.bearingDeg(from: GeoPoint(lat: 0, lon: 0), to: GeoPoint(lat: -1, lon: 0)), 180, accuracy: 1e-9)
        XCTAssertEqual(DashGeo.bearingDeg(from: GeoPoint(lat: 0, lon: 0), to: GeoPoint(lat: 0, lon: -1)), 270, accuracy: 1e-9)
        // offsetMeters: 40 m north at 45° N
        let o = DashGeo.offset(GeoPoint(lat: 45, lon: 7), bearingDeg: 0, meters: 40)
        XCTAssertEqual(o.lat, 45 + 40 / 111_320.0, accuracy: 1e-12)
        XCTAssertEqual(o.lon, 7, accuracy: 1e-12)
        // east offset uses max(cos(lat), 0.2)
        let e = DashGeo.offset(GeoPoint(lat: 89, lon: 0), bearingDeg: 90, meters: 111_320 * 0.2)
        XCTAssertEqual(e.lon, 1, accuracy: 1e-9)
    }
}

final class DashCameraTests: XCTestCase {
    let vp = DashSize(width: 800, height: 384)

    func testZoomForSpeedVectors() {
        // GpxNavTest.zoomForSpeed
        XCTAssertEqual(DashCamera.zoomForSpeedKmh(10), 17.0, accuracy: 0.01)
        XCTAssertEqual(DashCamera.zoomForSpeedKmh(80), 13.8, accuracy: 0.01)
        // boundaries (strict <)
        XCTAssertEqual(DashCamera.zoomForSpeedKmh(7.99), 17.8)
        XCTAssertEqual(DashCamera.zoomForSpeedKmh(8), 17.0)
        XCTAssertEqual(DashCamera.zoomForSpeedKmh(20), 16.2)
        XCTAssertEqual(DashCamera.zoomForSpeedKmh(35), 15.4)
        XCTAssertEqual(DashCamera.zoomForSpeedKmh(55), 14.6)
        XCTAssertEqual(DashCamera.zoomForSpeedKmh(110), 13.0)
    }

    func testBikeLadderTable() {
        // navigation-dash.md §4.6 table: bike zoom 18.6 / 18.1 / 17.3 / 16.5 / 15.7 / 14.9 / 14.1
        let speeds = [0.0, 10, 25, 40, 60, 90, 120]
        let expected = [18.6, 18.1, 17.3, 16.5, 15.7, 14.9, 14.1]
        for (v, z) in zip(speeds, expected) {
            XCTAssertEqual(DashCamera.bikeFollowZoom(speedKmh: v), z, accuracy: 1e-9, "\(v) km/h")
        }
        var cam = DashCamera()
        XCTAssertEqual(cam.targetFollowZoom(speedKmh: 10), 18.1, accuracy: 1e-9)
        cam.speedZoom = false
        XCTAssertEqual(cam.targetFollowZoom(speedKmh: 10), 17.2)
    }

    func testLookAheadLadder() {
        XCTAssertEqual(DashCamera.lookAheadMeters(zoom: 18.6, moving: true, headingUp: true), 40)
        XCTAssertEqual(DashCamera.lookAheadMeters(zoom: 17, moving: true, headingUp: true), 40)
        XCTAssertEqual(DashCamera.lookAheadMeters(zoom: 16.9, moving: true, headingUp: true), 70)
        XCTAssertEqual(DashCamera.lookAheadMeters(zoom: 15.5, moving: true, headingUp: true), 70)
        XCTAssertEqual(DashCamera.lookAheadMeters(zoom: 15.4, moving: true, headingUp: true), 110)
        XCTAssertEqual(DashCamera.lookAheadMeters(zoom: 14, moving: true, headingUp: true), 110)
        XCTAssertEqual(DashCamera.lookAheadMeters(zoom: 13.9, moving: true, headingUp: true), 160)
        XCTAssertEqual(DashCamera.lookAheadMeters(zoom: 18, moving: false, headingUp: true), 0)
        XCTAssertEqual(DashCamera.lookAheadMeters(zoom: 18, moving: true, headingUp: false), 0)
    }

    func testFollowHeadingUpPutsPuckBelowCentre() throws {
        // §4.9 worked example: 45° N, zoom 18.1, 40 m look-ahead ≈ 102 px below the anchor.
        var cam = DashCamera()
        let me = GeoPoint(lat: 45, lon: 7)
        cam.applyFollow(me: me, bearingDeg: 0, targetZoom: 18.1, moving: true)
        XCTAssertEqual(cam.zoom, 18.1)
        XCTAssertEqual(cam.bearingDeg, 0)
        let proj = try XCTUnwrap(cam.projection(viewport: vp))
        let puck = proj.screenPoint(me)
        XCTAssertEqual(puck.x, 400, accuracy: 1e-6)
        XCTAssertEqual(puck.y - 192, 101.53, accuracy: 0.05)
        // travelling east: still straight below the anchor (heading-up)
        cam.applyFollow(me: me, bearingDeg: 90, targetZoom: 18.1, moving: true)
        XCTAssertEqual(cam.bearingDeg, 90)
        let p2 = try XCTUnwrap(cam.projection(viewport: vp)).screenPoint(me)
        XCTAssertEqual(p2.x, 400, accuracy: 0.05)
        XCTAssertGreaterThan(p2.y, 280)
    }

    func testFollowStoppedOrNorthUpHasNoLookAhead() throws {
        var cam = DashCamera()
        let me = GeoPoint(lat: 45, lon: 7)
        cam.applyFollow(me: me, bearingDeg: 30, targetZoom: 18.6, moving: false)
        XCTAssertEqual(cam.center, me)
        XCTAssertEqual(cam.bearingDeg, 30)
        cam.headingUp = false
        cam.applyFollow(me: me, bearingDeg: 30, targetZoom: 18.6, moving: true)
        XCTAssertEqual(cam.center, me)
        XCTAssertEqual(cam.bearingDeg, 0)
    }

    func testZoomHysteresis() {
        var cam = DashCamera(center: GeoPoint(lat: 1, lon: 1), zoom: 17.3)
        let me = GeoPoint(lat: 1, lon: 1)
        cam.applyFollow(me: me, bearingDeg: 0, targetZoom: 17.5, moving: false)
        XCTAssertEqual(cam.zoom, 17.3) // |Δ| = 0.2 < 0.35
        // 17.65 − 17.3 is 0.3499999… in binary floating point: not applied (same as the Kotlin double maths)
        cam.applyFollow(me: me, bearingDeg: 0, targetZoom: 17.65, moving: false)
        XCTAssertEqual(cam.zoom, 17.3)
        cam.applyFollow(me: me, bearingDeg: 0, targetZoom: 17.7, moving: false)
        XCTAssertEqual(cam.zoom, 17.7) // |Δ| = 0.4
        // first positioning always applies the zoom
        var fresh = DashCamera(zoom: 18.5)
        fresh.applyFollow(me: me, bearingDeg: 0, targetZoom: 18.6, moving: false)
        XCTAssertEqual(fresh.zoom, 18.6)
    }

    func testLookAheadCapKeepsPuckAboveCards() throws {
        var cam = DashCamera()
        let me = GeoPoint(lat: 45, lon: 7)
        cam.applyFollow(me: me, bearingDeg: 0, targetZoom: 18.6, moving: true, maxLookAheadPx: 50)
        let puck = try XCTUnwrap(cam.projection(viewport: vp)).screenPoint(me)
        XCTAssertEqual(puck.y - 192, 50, accuracy: 0.05)
        // a cap larger than the natural look-ahead changes nothing
        cam.applyFollow(me: me, bearingDeg: 0, targetZoom: 18.6, moving: true, maxLookAheadPx: 10_000)
        let mpp = MapProjection.metersPerPixel(latitude: 45, zoom: 18.6)
        let natural = try XCTUnwrap(cam.projection(viewport: vp)).screenPoint(me)
        XCTAssertEqual(natural.y - 192, 40 / mpp, accuracy: 0.05)
    }

    func testFreePanAutoRecenter() {
        var cam = DashCamera()
        cam.bumpFreePan(now: 100)
        XCTAssertFalse(cam.follow)
        XCTAssertFalse(cam.advance(now: 111.9))
        XCTAssertFalse(cam.follow)
        XCTAssertTrue(cam.advance(now: 112))
        XCTAssertTrue(cam.follow)
        XCTAssertNil(cam.autoRecenterAt)
        cam.bumpFreePan(now: 200)
        cam.cancelAutoRecenter()
        XCTAssertFalse(cam.advance(now: 1000))
        XCTAssertFalse(cam.follow)
        // re-bumping restarts the 12 s window
        cam.bumpFreePan(now: 300)
        cam.bumpFreePan(now: 305)
        XCTAssertFalse(cam.advance(now: 313))
        XCTAssertTrue(cam.advance(now: 317))
    }

    func testZoomByClamps() {
        var cam = DashCamera(zoom: 19.5)
        cam.zoomBy(1)
        XCTAssertEqual(cam.zoom, 20)
        cam.zoom = 5.4
        cam.zoomBy(-1)
        XCTAssertEqual(cam.zoom, 5)
        cam.setCenter(GeoPoint(lat: 1, lon: 2), zoom: 30)
        XCTAssertEqual(cam.zoom, 20)
    }

    func testPanFollowsTheFinger() throws {
        for bearing in [0.0, 90, 211] {
            var cam = DashCamera(center: GeoPoint(lat: 45.1, lon: 24.5), zoom: 16, bearingDeg: bearing)
            let before = try XCTUnwrap(cam.projection(viewport: vp))
            let g = before.geoPoint(atScreen: DashPoint(400, 192))
            cam.pan(byScreenDelta: DashPoint(30, -12), viewport: vp)
            let after = try XCTUnwrap(cam.projection(viewport: vp)).screenPoint(g)
            XCTAssertEqual(after.x, 430, accuracy: 1e-6, "bearing \(bearing)")
            XCTAssertEqual(after.y, 180, accuracy: 1e-6, "bearing \(bearing)")
        }
    }

    func testZoomKeepingFocalPoint() throws {
        for bearing in [0.0, 63] {
            var cam = DashCamera(center: GeoPoint(lat: 45.1, lon: 24.5), zoom: 15.2, bearingDeg: bearing)
            let focal = DashPoint(612, 97)
            let g = try XCTUnwrap(cam.projection(viewport: vp)).geoPoint(atScreen: focal)
            cam.setZoom(16.7, keeping: focal, viewport: vp)
            XCTAssertEqual(cam.zoom, 16.7)
            let s = try XCTUnwrap(cam.projection(viewport: vp)).screenPoint(g)
            XCTAssertEqual(s.x, focal.x, accuracy: 1e-6)
            XCTAssertEqual(s.y, focal.y, accuracy: 1e-6)
        }
    }

    func testFitResetsNorth() throws {
        var cam = DashCamera(center: GeoPoint(lat: 45, lon: 24), zoom: 18, bearingDeg: 120)
        let pts = [GeoPoint(lat: 45.10, lon: 24.40), GeoPoint(lat: 45.20, lon: 24.60)]
        let rect = DashRect(x: 8, y: 64, width: 732, height: 146)
        cam.fit(pts, in: rect, viewport: vp)
        XCTAssertEqual(cam.bearingDeg, 0)
        let proj = try XCTUnwrap(cam.projection(viewport: vp))
        for g in pts {
            let s = proj.screenPoint(g)
            XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(s), "\(s)")
        }
    }
}
