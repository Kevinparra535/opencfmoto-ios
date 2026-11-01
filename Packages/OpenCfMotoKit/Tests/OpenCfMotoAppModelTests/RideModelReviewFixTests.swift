// SPDX-License-Identifier: AGPL-3.0-or-later
// RideModel fixes from the multi-lens review (fix-media): untrusted route coordinates never reach
// the tile maths unfiltered (SEC-1), plus the idle-timer, night-mode, hold-picture, canvas and
// wire-dump wiring added by the same change set.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

/// A `DashProjecting` that records what the model asks of it (everything else is the preview fake).
final class RideSpyProjection: DashProjecting, @unchecked Sendable {
    let base: PreviewProjection
    /// Every `prefetchCorridor` call, in order.
    let corridors = Locked<[[GeoPoint]]>([])

    init(frameSource: VideoFrameSource = PreviewFrameSource()) {
        base = PreviewProjection(frameSource: frameSource)
    }

    var frameSource: VideoFrameSource { base.frameSource }
    var textMeasurer: DashTextMeasurer { base.textMeasurer }
    var stats: ProjectionStatsSummary { base.stats }
    var onTileLoaded: (@Sendable () -> Void)? {
        get { base.onTileLoaded }
        set { base.onTileLoaded = newValue }
    }
    func setDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?) { base.setDisplayListProvider(provider) }
    func setHoldDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?) { base.setHoldDisplayListProvider(provider) }
    func setEncoderParameters(_ parameters: EncoderParameters) { base.setEncoderParameters(parameters) }
    func setThermalCapsEnabled(_ enabled: Bool) { base.setThermalCapsEnabled(enabled) }
    func invalidate() { base.invalidate() }
    func prepareHoldPicture() { base.prepareHoldPicture() }
    func enterBackground() { base.enterBackground() }
    func enterForeground() { base.enterForeground() }
    func stop() { base.stop() }
    func requestTiles(_ tiles: [DashMapTile]) { base.requestTiles(tiles) }
    func prefetchCorridor(_ points: [GeoPoint]) { corridors.withLock { $0.append(points) } }
    func setTileURLTemplate(_ template: String) { base.setTileURLTemplate(template) }
    func clearTileCache() { base.clearTileCache() }
}

final class RideModelReviewFixTests: XCTestCase {
    // MARK: SEC-1 — untrusted coordinates

    /// A GPX whose points carry NaN, ±∞, 1e300 or lat 200 (crafted or from a buggy exporter) used to
    /// crash the app in the tile-corridor prefetch the moment the route was applied.
    @MainActor
    func testCorruptGpxRouteNeverReachesTheTileMathsUnfiltered() async throws {
        let spy = RideSpyProjection()
        let h = AppTestHarness { $0.projection = spy }
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="evil"><trk><name>Evil</name><trkseg>
        <trkpt lat="45.1000" lon="25.0000"/>
        <trkpt lat="45.1" lon="1e300"/>
        <trkpt lat="NaN" lon="25.0100"/>
        <trkpt lat="45.1100" lon="inf"/>
        <trkpt lat="200" lon="25.0200"/>
        <trkpt lat="45.1200" lon="1e20"/>
        <trkpt lat="45.1300" lon="25.0300"/>
        <trkpt lat="45.1400" lon="25.0400"/>
        </trkseg></trk></gpx>
        """
        h.model.navigation.loadGpx(data: Data(gpx.utf8), fileName: "evil.gpx")
        let prefetched = await eventually { !spy.corridors.current.isEmpty }
        XCTAssertTrue(prefetched, "the good points of the route are still prefetched")
        for corridor in spy.corridors.current {
            XCTAssertGreaterThanOrEqual(corridor.count, 2)
            XCTAssertTrue(corridor.allSatisfy(MapProjection.isUsable), "\(corridor)")
        }
        // The dash picture, its tiles and the route identity are computed without trapping.
        h.ride.flushModel()
        _ = h.ride.displayList(now: h.core.services.clock.now())
        _ = h.ride.ui.visibleTiles()
        XCTAssertNotNil(RideModel.routeKey(h.core.navigation.snapshot.route))
    }

    func testCorridorPointsAndRouteKeyAreSafeOnCorruptRoutes() {
        let points = [TrackPoint(lat: 45.1, lon: 25.0), TrackPoint(lat: .nan, lon: 25.0), TrackPoint(lat: 45.2, lon: .infinity),
                      TrackPoint(lat: 45.3, lon: 1e300), TrackPoint(lat: -95, lon: 25.0), TrackPoint(lat: 45.4, lon: 25.4)]
        let route = Route(points: points, distanceM: .nan, durationSec: 0, label: "bad")
        XCTAssertEqual(RideModel.corridorPoints(route), [GeoPoint(lat: 45.1, lon: 25.0), GeoPoint(lat: 45.4, lon: 25.4)])
        for d in [Double.nan, .infinity, -.infinity, 1e300, -1e300, 12_345.9] {
            let key = RideModel.routeKey(Route(points: points, distanceM: d, durationSec: 0, label: "bad"))
            XCTAssertNotNil(key, "\(d)")
        }
        XCTAssertTrue(RideModel.routeKey(Route(points: points, distanceM: 12_345.9, durationSec: 0, label: "x"))?.contains("|12345|") ?? false)
        XCTAssertNil(RideModel.routeKey(nil))
    }

    // MARK: SPEC:CL-8 — no screen kept awake while parked

    @MainActor
    func testKeepScreenOnFollowsTheLinkPhase() async {
        let h = AppTestHarness()
        h.ride.sessionChanged(active: true, mirror: false)
        h.ride.linkPhaseChanged(.streaming)
        XCTAssertTrue(h.system.isIdleTimerDisabled)
        // Bike out of range → the iOS park: rendering stopped, the screen may lock again.
        h.ride.linkPhaseChanged(.waitingForBike)
        XCTAssertFalse(h.system.isIdleTimerDisabled)
        // Ride Mode still keeps it awake (the rider asked for it explicitly).
        h.ride.enterRideMode()
        XCTAssertTrue(h.system.isIdleTimerDisabled)
        h.ride.exitRideMode()
        XCTAssertFalse(h.system.isIdleTimerDisabled)
        // The bike is back: linking / reconnecting / streaming keep it awake again.
        h.ride.linkPhaseChanged(.linking)
        XCTAssertTrue(h.system.isIdleTimerDisabled)
        h.ride.linkPhaseChanged(.error)
        XCTAssertFalse(h.system.isIdleTimerDisabled, "an error does not hold the screen on either")
        h.ride.linkPhaseChanged(.reconnecting)
        XCTAssertTrue(h.system.isIdleTimerDisabled)
        h.ride.sessionChanged(active: false, mirror: false)
        XCTAssertFalse(h.system.isIdleTimerDisabled)
    }

    @MainActor
    func testParkedSessionReleasesTheIdleTimerAndTheResumeTakesItBack() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        XCTAssertTrue(h.system.isIdleTimerDisabled, "keepScreenOn (default) while the dash is linked")
        h.wifi.setNetwork(.unavailable)
        let parked = await eventually { h.connection.phase == .waitingForBike }
        XCTAssertTrue(parked)
        XCTAssertFalse(h.system.isIdleTimerDisabled, "parked: the phone may auto-lock")
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        let resumed = await eventually { h.connection.link != nil && h.system.isIdleTimerDisabled }
        XCTAssertTrue(resumed)
        h.connection.stop()
        XCTAssertFalse(h.system.isIdleTimerDisabled)
    }
}
