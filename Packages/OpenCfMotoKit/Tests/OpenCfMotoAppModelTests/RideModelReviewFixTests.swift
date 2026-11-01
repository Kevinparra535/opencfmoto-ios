// SPDX-License-Identifier: AGPL-3.0-or-later
// RideModel fixes from the multi-lens review (fix-media): untrusted route coordinates never reach
// the tile maths unfiltered (SEC-1), plus the idle-timer, night-mode, hold-picture, canvas and
// wire-dump wiring added by the same change set.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

/// Forwards to `inner` and reports every `prepare` like DashProjectionEngine.onPrepared does.
final class RideNotifyingFrameSource: VideoFrameSource, @unchecked Sendable {
    let inner: VideoFrameSource
    let onPrepare: Locked<(@Sendable (VideoCanvas) -> Void)?> = Locked(nil)
    init(_ inner: VideoFrameSource) { self.inner = inner }
    func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {
        inner.prepare(canvas: canvas, parameters: parameters)
        onPrepare.current?(canvas)
    }
    func resynchronize() { inner.resynchronize() }
    func nextFrame(timeout: TimeInterval) async -> EncodedFrame? { await inner.nextFrame(timeout: timeout) }
    func mediaStopped() { inner.mediaStopped() }
}

/// A `DashProjecting` that records what the model asks of it (everything else is the preview fake).
final class RideSpyProjection: DashProjecting, @unchecked Sendable {
    let base: PreviewProjection
    let source: RideNotifyingFrameSource
    /// Every `prefetchCorridor` call, in order.
    let corridors = Locked<[[GeoPoint]]>([])

    init(frameSource: VideoFrameSource = PreviewFrameSource()) {
        source = RideNotifyingFrameSource(frameSource)
        base = PreviewProjection(frameSource: source)
    }

    var onCanvasPrepared: (@Sendable (VideoCanvas) -> Void)? {
        get { source.onPrepare.current }
        set { source.onPrepare.set(newValue) }
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

    // MARK: MED:MP-6 — the layout follows the canvas the encoder was prepared at

    @MainActor
    func testUnusableReq16LaysTheDashOutForTheKeptCanvas() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let frames = TestFrameSource()
        let spy = RideSpyProjection(frameSource: frames)
        let h = AppTestHarness(network: net) { $0.projection = spy }
        let (_, qr) = h.addBike()
        h.core.dashMemory.observe(ssid: qr.ssid, width: 800, height: 951) // a CFDL26 learned earlier
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 800, height: 384), "preview canvas before the link")
        h.connection.connect()
        let probed = await eventually { dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        let ctrl = try dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        let mctl = try dash.openMedia(port: 10921)
        // REQ 16 without a usable size: the link keeps (and replies) the learned 800×944 canvas.
        try await mctl.send(cmd: 16, body: Data())
        let rly = try await mctl.reply()
        XCTAssertEqual(rly.message.cmdType, 17)
        XCTAssertEqual(Array(rly.message.body.dropFirst(4).prefix(4)), [0x20, 0x03, 0xB0, 0x03], "RLY 17 800×944")
        let laidOut = await eventually { h.ride.canvasSize == DashSize(width: 800, height: 944) }
        XCTAssertTrue(laidOut, "the dash UI is laid out for the replied / encoded canvas, not the preview")
        XCTAssertEqual(h.ride.displayList(now: h.core.services.clock.now()).size, DashSize(width: 800, height: 944))
        h.connection.stop()
        let back = await eventually { h.ride.canvasSize == DashSize(width: 800, height: 384) }
        XCTAssertTrue(back, "link ended → preview canvas again")
        ctrl.close()
        mctl.close()
    }

    @MainActor
    func testPreparedCanvasIsIgnoredOutsideAnOwnUISession() async {
        let spy = RideSpyProjection()
        let h = AppTestHarness { $0.projection = spy }
        spy.onCanvasPrepared?(VideoCanvas(width: 1280, height: 576))
        await settle()
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 800, height: 384), "no session: preview canvas")
        h.ride.sessionChanged(active: true, mirror: true)
        spy.onCanvasPrepared?(VideoCanvas(width: 1280, height: 576))
        await settle()
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 800, height: 384), "mirror: the own UI is not projected")
        h.ride.sessionChanged(active: true, mirror: false)
        spy.onCanvasPrepared?(VideoCanvas(width: 1280, height: 576))
        let applied = await eventually { h.ride.canvasSize == DashSize(width: 1280, height: 576) }
        XCTAssertTrue(applied)
    }

    // MARK: MED:MP-2 — a hold picture exists before the dash negotiates

    /// Tap Connect, pocket the phone: the dash's REQ 16 comes while the app is in the background,
    /// where the hardware encoder is gone. The hold picture must already exist at the canvas the
    /// dash will most likely negotiate (the learned one), laid out for it.
    @MainActor
    func testHoldPictureIsPreEncodedAtTheExpectedCanvasBeforeREQ16() async throws {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.core.dashMemory.observe(ssid: qr.ssid, width: 800, height: 951)
        let tall = VideoCanvas.rounded(requestedWidth: 800, requestedHeight: 951)
        h.ride.sessionChanged(active: true, mirror: false)
        XCTAssertEqual(h.projection.holdPictureRequests, [tall], "pre-encoded at once, in the foreground")
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 800, height: 944), "laid out for the expected canvas")
        let hold = try XCTUnwrap(h.projection.currentHoldDisplayList(now: h.core.services.clock.now()))
        XCTAssertEqual(hold.size, DashSize(width: 800, height: 944), "the hold picture is not stretched")
        // Leaving the foreground refreshes it (current map) while the encoder is still available…
        h.ride.scenePhaseChanged(.inactive)
        XCTAssertEqual(h.projection.holdPictureRequests, [tall, tall])
        h.ride.scenePhaseChanged(.background)
        // …and coming back from the background does not (the hardware encoder is back).
        h.ride.scenePhaseChanged(.inactive)
        XCTAssertEqual(h.projection.holdPictureRequests.count, 2)
        h.ride.scenePhaseChanged(.active)
        // The dash negotiates another size: the hold picture follows the negotiated canvas.
        h.ride.canvasNegotiated(VideoCanvas(width: 1280, height: 576))
        h.ride.scenePhaseChanged(.inactive)
        XCTAssertEqual(h.projection.holdPictureRequests.last, VideoCanvas(width: 1280, height: 576))
        h.ride.scenePhaseChanged(.active)
        // Session over: back to the preview canvas, no more hold pictures.
        h.ride.sessionChanged(active: false, mirror: false)
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 800, height: 384))
        let count = h.projection.holdPictureRequests.count
        h.ride.scenePhaseChanged(.inactive)
        XCTAssertEqual(h.projection.holdPictureRequests.count, count)
    }

    @MainActor
    func testHoldPictureDefaultsTo800x384AndIsNotMadeForMirroring() async {
        let h = AppTestHarness()
        h.addBike() // no learned canvas
        h.ride.sessionChanged(active: true, mirror: true)
        h.ride.scenePhaseChanged(.inactive)
        XCTAssertEqual(h.projection.holdPictureRequests, [], "mirror: the own UI is not projected")
        h.ride.scenePhaseChanged(.active)
        h.ride.sessionChanged(active: true, mirror: false)
        XCTAssertEqual(h.projection.holdPictureRequests, [.defaultLandscape])
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 800, height: 384))
    }

    // MARK: SPEC:CL-10 — theme AUTO follows the phone's dark mode

    private func fix(lat: Double = 4.6584, lon: Double = -74.0930) -> LocationFix {
        LocationFix(lat: lat, lon: lon, speedMps: 0, courseDeg: nil, accuracyM: 5, altitudeM: 2600, timeMs: 1_790_000_000_000)
    }

    /// The invert flags of the map tiles in a display list (night = inverted tiles).
    private func tileInverts(_ list: DashDisplayList) -> Set<Bool> {
        Set(list.commands.compactMap { if case let .tile(_, _, _, _, invert) = $0 { return invert }; return nil })
    }

    @MainActor
    func testThemeAutoFollowsTheSystemDarkMode() async throws {
        var noonParts = DateComponents()
        noonParts.year = 2026; noonParts.month = 1; noonParts.day = 15; noonParts.hour = 12
        let noon = try XCTUnwrap(Calendar.current.date(from: noonParts)) // local time: the clock says day
        let h = AppTestHarness { $0.now = { noon } }
        XCTAssertEqual(h.core.currentSettings.map.theme, .auto)
        h.location.emit(fix())
        h.ride.flushModel()
        let clock = h.core.services.clock
        let day = await eventually { self.tileInverts(h.ride.displayList(now: clock.now())) == [false] }
        XCTAssertTrue(day, "noon, light appearance: day tiles")
        // Appearance → Dark (or Automatic after sunset): the system port reports it.
        h.system.isSystemDarkMode = true
        h.system.onPowerStateChange?()
        let night = await eventually { self.tileInverts(h.ride.displayList(now: clock.now())) == [true] }
        XCTAssertTrue(night, "AUTO = dark mode OR 19:00–06:59")
        // An explicit DAY theme ignores the phone appearance.
        h.core.settings.update(forBike: nil) { $0.map.theme = .day }
        let forcedDay = await eventually { self.tileInverts(h.ride.displayList(now: clock.now())) == [false] }
        XCTAssertTrue(forcedDay)
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
