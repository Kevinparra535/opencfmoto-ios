// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 — integration: where the app model, the projection port and the engine API meet.
// The scene phases SwiftUI delivers when the rider locks and unlocks the phone (the same calls the E2E
// harness makes for `-e2eBackgroundCycle`) go through the real AppModel → RideModel path of an own-UI
// session that STREAMS over a real EasyConnLink, and must reach the projection port as exactly the
// engine calls ProjectionAdapter forwards them to (one to one), in order, between the app's own lines:
// L14 first (AppModel logs it before the sub-models react), then the calls; L15 from the projection's
// stats summary while locked; the unclean-background-exit marker set and cleared around them.
// VideoEngineLockSeamTests (macOS) drives the real engine with the call sequences pinned here.
// NOTE (Linux): main-actor tests must be `async` (swift-corelibs-xctest).

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

/// The projection port as one timeline: every lifecycle call, named as the engine call
/// ProjectionAdapter forwards it to, interleaved with the `APP` scene / `[lock]` lines and the `RIDE`
/// GPS-restart line (log subscribers run synchronously on the logging thread, here the main actor).
/// Everything else is delegated to a PreviewProjection.
final class LockTimelineProjection: DashProjecting, @unchecked Sendable {
    let inner: PreviewProjection
    private let events = Locked<[String]>([])
    private var token: UUID?

    init(inner: PreviewProjection) {
        self.inner = inner
        token = Log.shared.subscribe { [events] line in
            let keep = (line.tag == "APP" && (line.message.hasPrefix("scene ") || line.message.hasPrefix("[lock]")))
                || (line.tag == "RIDE" && line.message.hasPrefix("GPS restarted"))
            if keep { events.withLock { $0.append("\(line.tag): \(line.message)") } }
        }
    }

    deinit { stopRecording() }

    func stopRecording() {
        if let token { Log.shared.unsubscribe(token) }
        token = nil
    }

    var timeline: [String] { events.current }
    /// The engine calls only.
    var engineCalls: [String] { timeline.filter { $0.hasPrefix("engine.") } }
    func reset() { events.set([]) }

    private func engine(_ call: String) { events.withLock { $0.append("engine.\(call)") } }

    // MARK: lifecycle (ProjectionAdapter: one engine call each)

    func prepareHoldPicture() {
        engine("prepareHoldPicture()")
        inner.prepareHoldPicture()
    }

    func prepareHoldPicture(expectedCanvas: VideoCanvas) {
        engine("prepareHoldPicture(expectedCanvas: \(expectedCanvas.width)x\(expectedCanvas.height))")
        inner.prepareHoldPicture(expectedCanvas: expectedCanvas)
    }

    func prepareBackgroundEncoder() {
        engine("prepareBackgroundEncoder()")
        inner.prepareBackgroundEncoder()
    }

    func enterBackground() {
        engine("enterBackground()")
        inner.enterBackground()
    }

    func enterForeground() {
        engine("enterForeground()")
        inner.enterForeground()
    }

    func stop() {
        engine("stop()")
        inner.stop()
    }

    func setLockedStreamPolicy(_ policy: LockedStreamPolicy) {
        engine("lockedStreamPolicy = \(policy.rawValue)")
        inner.setLockedStreamPolicy(policy)
    }

    // MARK: delegated

    var frameSource: VideoFrameSource { inner.frameSource }
    var textMeasurer: DashTextMeasurer { inner.textMeasurer }
    var stats: ProjectionStatsSummary { inner.stats }
    var onTileLoaded: (@Sendable () -> Void)? {
        get { inner.onTileLoaded }
        set { inner.onTileLoaded = newValue }
    }
    var onCanvasPrepared: (@Sendable (VideoCanvas) -> Void)? {
        get { inner.onCanvasPrepared }
        set { inner.onCanvasPrepared = newValue }
    }
    func setDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?) {
        inner.setDisplayListProvider(provider)
    }
    func setHoldDisplayListProvider(_ provider: (@Sendable (TimeInterval) -> DashDisplayList)?) {
        inner.setHoldDisplayListProvider(provider)
    }
    func setEncoderParameters(_ parameters: EncoderParameters) { inner.setEncoderParameters(parameters) }
    func setThermalCapsEnabled(_ enabled: Bool) { inner.setThermalCapsEnabled(enabled) }
    func invalidate() { inner.invalidate() }
    func requestTiles(_ tiles: [DashMapTile]) { inner.requestTiles(tiles) }
    func prefetchCorridor(_ points: [GeoPoint]) { inner.prefetchCorridor(points) }
    func setTileURLTemplate(_ template: String) { inner.setTileURLTemplate(template) }
    func clearTileCache() { inner.clearTileCache() }
    func startWireDump(to url: URL, maxFrames: Int) throws { try inner.startWireDump(to: url, maxFrames: maxFrames) }
    func stopWireDump() { inner.stopWireDump() }
    func setDashImage(id: String, data: Data?) { inner.setDashImage(id: id, data: data) }
}

final class LockSeamIntegrationTests: XCTestCase {
    private let markerKey = "ios.bg_session_marker"
    private let streaming = "own UI session, streaming"

    /// An own-UI Connect session over a REAL EasyConnLink (in-memory network, the scripted CFDL16 dash of
    /// ConnectionEndToEndTests: REQ 16 at 800×386 → canvas 800×384) brought to STREAMING, with the
    /// timeline projection as the app's projection port. The returned objects keep the dash side open.
    @MainActor
    private func streamingSession(clock: MusicTestClock, now: @escaping @Sendable () -> Date,
                                  storedPolicy: String? = nil) async throws
        -> (h: AppTestHarness, projection: LockTimelineProjection, keep: [AnyObject]) {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let projection = LockTimelineProjection(inner: PreviewProjection(frameSource: TestFrameSource()))
        let h = AppTestHarness(network: net) { services in
            services.clock = clock
            services.now = now
            services.projection = projection
            if let storedPolicy { services.keyValueStore.set(storedPolicy, forKey: "ios.locked_stream_policy") }
        }
        h.addBike()
        h.connection.connect()
        let probed = await eventually { dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed, "the app probed the fake dash")
        let ctrl = try dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        try await ctrl.send(cmd: 0x10010, json: LinkDashSamples.cfdl16ClientInfo)
        _ = try await ctrl.next()
        try await ctrl.send(cmd: 0x10690, json: LinkDashSamples.querySpeed)
        _ = try await ctrl.nextRaw()
        let data = try dash.openControl()
        try await data.send(PxcFrame(cmd: 0x20000))
        _ = try await data.nextRaw()
        try await data.send(cmd: 0x103E0, json: LinkDashSamples.checkSn)
        _ = try await data.nextRaw()
        _ = try await data.nextRaw()
        let mctl = try dash.openMedia(port: 10921)
        try await mctl.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        _ = try await mctl.reply()
        try await mctl.send(cmd: 112)
        _ = try await mctl.reply()
        let mdata = try dash.openMedia(port: 10920)
        for _ in 1 ... 3 {
            try await mdata.send(cmd: 114)
            _ = try await mdata.frame()
        }
        let isStreaming = await eventually { h.connection.phase == .streaming }
        XCTAssertTrue(isStreaming, "phase \(h.connection.phase)")
        return (h, projection, [dash, ctrl, data, mctl, mdata])
    }

    /// What ProjectionAdapter maps from the engine's `DashProjectionStats` while a VideoToolbox software
    /// session feeds the dash (VideoEngineLockSeamTests pins those engine fields on macOS).
    private static let backgroundSoftwareSummary = ProjectionStatsSummary(
        mode: "background-software", renderedFrames: 812, encodedFrames: 3412, framesPerSecond: 5.2, bitrate: 3_375_000,
        lastError: nil, encoder: "vt-sw", pullRate: 5.1, pullsServed: 4210, holdFramesServed: 4,
        fallbackKeyframesServed: 2, encoderErrors: 0, cpuPercent: 14, backgroundFpsCap: 8)

    /// …and in hold (no encoder: the pre-encoded "Phone locked" IDRs, about one pull per second).
    private static let holdSummary = ProjectionStatsSummary(
        mode: "hold", renderedFrames: 812, encodedFrames: 3412, framesPerSecond: 0, bitrate: 3_375_000, lastError: nil,
        encoder: "hold", pullRate: 1.04, pullsServed: 4290, holdFramesServed: 84, fallbackKeyframesServed: 0,
        encoderErrors: 0, cpuPercent: 13, backgroundFpsCap: nil)

    // MARK: the lock cycle of the E2E harness (and of a real side-button lock)

    /// `.inactive`, 0.5 s later `.background`, then at the unlock `.inactive` and `.active`: L14 first, then
    /// prepareHoldPicture(expectedCanvas:) → prepareBackgroundEncoder() at `.inactive` (the engine runs both
    /// on its render queue in this order), enterBackground() at `.background`, nothing at the unlock's
    /// `.inactive`, enterForeground() at `.active`. While locked, L15 reports what the projection
    /// summary says; the marker is set at `.background` and gone at `.active`.
    @MainActor
    func testTheLockCycleReachesTheEngineInTheAdaptersOrderBetweenTheSceneLines() async throws {
        let clock = MusicTestClock(1_000)
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let (h, projection, keep) = try await streamingSession(clock: clock, now: { wall })
        defer { projection.stopRecording() }
        let store = h.core.services.keyValueStore
        h.system.batteryStatus = BatteryStatus(level: 0.63, state: .charging)
        h.location.emit(LocationFix(lat: 45.1, lon: 25.0, timeMs: 1_800_000_000_000 - 1_000)) // 1 s old
        XCTAssertFalse(projection.engineCalls.contains("engine.enterBackground()"), "nothing before the lock")
        projection.reset()

        h.model.scenePhaseChanged(.inactive)
        XCTAssertEqual(projection.timeline, [
            "APP: scene active \u{2192} inactive (\(streaming))",
            "engine.prepareHoldPicture(expectedCanvas: 800x384)",
            "engine.prepareBackgroundEncoder()",
        ], "the side button: the hold picture at the negotiated canvas, then the pre-warm")
        XCTAssertNil(store.double(forKey: markerKey), "inactive is not locked yet")

        clock.advance(0.5)
        h.model.scenePhaseChanged(.background)
        XCTAssertEqual(Array(projection.timeline.dropFirst(3)), [
            "APP: scene inactive \u{2192} background (\(streaming))",
            "engine.enterBackground()",
        ])
        XCTAssertEqual(store.double(forKey: markerKey), wall.timeIntervalSince1970, "the marker of an unclean exit")

        // The session-log saver loop's tick while locked (its body): L15 from the projection's summary.
        projection.inner.statsSummary = Self.backgroundSoftwareSummary
        clock.advance(28)
        h.location.emitHeading(90)
        clock.advance(2)
        h.model.logLockStatus()
        projection.inner.statsSummary = Self.holdSummary
        clock.advance(30)
        h.model.logLockStatus()
        XCTAssertEqual(Array(projection.timeline.dropFirst(5)), [
            "APP: [lock] 30s locked link=streaming wifi=up pulls=5.1/s dash=backgroundSoftware vt-sw 5.2fps gps=1s "
                + "heading=2s batt=63% charging thermal=none lowPower=false",
            "APP: [lock] 1m00s locked link=streaming wifi=up pulls=1.0/s dash=hold hold 0.0fps gps=1s "
                + "heading=32s batt=63% charging thermal=none lowPower=false",
        ], "`dash=` names the engine mode as its `[bg]` line does (`mode=backgroundSoftware`, `mode=hold`)")

        // The unlock: `.inactive` changes nothing, `.active` brings the hardware encoder back.
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        XCTAssertEqual(Array(projection.timeline.dropFirst(7)), [
            "APP: scene background \u{2192} inactive after 1m00s (\(streaming))",
            "APP: scene inactive \u{2192} active (\(streaming))",
            "engine.enterForeground()",
        ])
        XCTAssertNil(store.double(forKey: markerKey), "cleared at .active")
        XCTAssertEqual(projection.engineCalls, ["engine.prepareHoldPicture(expectedCanvas: 800x384)",
                                                "engine.prepareBackgroundEncoder()", "engine.enterBackground()",
                                                "engine.enterForeground()"],
                       "exactly one call per transition (no policy push: nothing stored)")
        XCTAssertFalse(keep.isEmpty)
        h.connection.stop()
    }

    /// Control Center, a banner, the app switcher: `.inactive` then straight back to `.active`. The engine
    /// gets the same preparations, then enterForeground() — never enterBackground() (it then drops the
    /// pre-warmed session, VideoEngineBackgroundTests). A lock that SwiftUI delivers without the
    /// `.inactive` step gets enterBackground() alone (the ladder then starts with a fresh session).
    @MainActor
    func testAnInactiveBlipAndACoalescedLock() async throws {
        let clock = MusicTestClock(1_000)
        let (h, projection, keep) = try await streamingSession(clock: clock, now: { Date() })
        defer { projection.stopRecording() }
        projection.reset()

        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        XCTAssertEqual(projection.timeline, [
            "APP: scene active \u{2192} inactive (\(streaming))",
            "engine.prepareHoldPicture(expectedCanvas: 800x384)",
            "engine.prepareBackgroundEncoder()",
            "APP: scene inactive \u{2192} active (\(streaming))",
            "engine.enterForeground()",
        ])

        projection.reset()
        h.model.scenePhaseChanged(.background)
        clock.advance(5)
        h.model.scenePhaseChanged(.active)
        XCTAssertEqual(projection.timeline, [
            "APP: scene active \u{2192} background (\(streaming))",
            "engine.enterBackground()",
            "APP: scene background \u{2192} active after 5s (\(streaming))",
            "engine.enterForeground()",
        ], "no hold picture and no pre-warm without the .inactive step")
        XCTAssertFalse(keep.isEmpty)
        h.connection.stop()
    }

    /// The session ends while the phone is locked (Stop from the lock screen's controls, or the dash
    /// goes away): the engine is stopped, the marker goes (the next launch must not report an unclean
    /// exit for it) and no `[lock]` line follows.
    @MainActor
    func testASessionThatEndsWhileLockedStopsTheEngineAndClearsTheMarker() async throws {
        let clock = MusicTestClock(1_000)
        let (h, projection, keep) = try await streamingSession(clock: clock, now: { Date() })
        defer { projection.stopRecording() }
        let store = h.core.services.keyValueStore
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        XCTAssertNotNil(store.double(forKey: markerKey))
        projection.reset()

        h.connection.stop()
        let stopped = await eventually { projection.engineCalls.contains("engine.stop()") }
        XCTAssertTrue(stopped, "\(projection.timeline)")
        XCTAssertFalse(h.connection.isSessionActive)
        XCTAssertNil(store.double(forKey: markerKey), "a session that ended is not an unclean exit")
        h.model.logLockStatus()
        XCTAssertFalse(projection.timeline.contains { $0.hasPrefix("APP: [lock]") }, "no session: no [lock] line")
        XCTAssertFalse(projection.engineCalls.contains("engine.enterBackground()"), "\(projection.timeline)")
        XCTAssertFalse(keep.isEmpty)
    }

    /// A stored locked-phone policy (the Phase 1 setting's key) reaches the engine once, at start, before
    /// any lock; the lock cycle then makes the same calls as without it.
    @MainActor
    func testAStoredPolicyReachesTheEngineBeforeTheFirstLock() async throws {
        let clock = MusicTestClock(1_000)
        let (h, projection, keep) = try await streamingSession(clock: clock, now: { Date() }, storedPolicy: "hold")
        defer { projection.stopRecording() }
        XCTAssertEqual(projection.engineCalls.first, "engine.lockedStreamPolicy = hold", "\(projection.engineCalls)")
        XCTAssertEqual(projection.engineCalls.filter { $0.hasPrefix("engine.lockedStreamPolicy") }.count, 1)
        projection.reset()
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        XCTAssertEqual(projection.engineCalls, ["engine.prepareHoldPicture(expectedCanvas: 800x384)",
                                                "engine.prepareBackgroundEncoder()", "engine.enterBackground()",
                                                "engine.enterForeground()"])
        XCTAssertFalse(keep.isEmpty)
        h.connection.stop()
    }
}
