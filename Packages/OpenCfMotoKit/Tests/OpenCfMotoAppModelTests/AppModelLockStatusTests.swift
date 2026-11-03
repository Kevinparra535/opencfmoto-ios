// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §2.2 P0-9, §4, §6.1; contract §6.2, §7, §9 P): what AppModel logs
// while the phone is locked — L14 at every scene change with the session context, L15 (`[lock]`) every
// `sessionLogInterval` only while backgrounded with an own-UI session (exact text from a stubbed
// projection summary), the unclean-background-exit marker (`ios.bg_session_marker`: set at
// `.background` during a session; cleared at `.active`, at the session end and at launch) and L16 when a
// launch finds it; `ConnectionModel.isBikeWifiLost`.
// NOTE (Linux): main-actor tests must be `async` (swift-corelibs-xctest).

import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class AppModelLockStatusTests: XCTestCase {
    private let markerKey = "ios.bg_session_marker"

    private func sceneLines(_ log: LogCapture) -> [String] {
        log.messages(tag: "APP").filter { $0.hasPrefix("scene ") }
    }

    private func lockLines(_ log: LogCapture) -> [String] {
        log.messages(tag: "APP").filter { $0.hasPrefix("[lock]") }
    }

    /// A Connect session over a REAL EasyConnLink (in-memory network, the scripted CFDL16 dash of
    /// ConnectionEndToEndTests) brought to STREAMING. The returned objects keep the dash side open.
    @MainActor
    private func streamingHarness(clock: MusicTestClock, now: @escaping @Sendable () -> Date) async throws
        -> (h: AppTestHarness, keep: [AnyObject]) {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let h = AppTestHarness(network: net, frameSource: TestFrameSource()) { services in
            services.clock = clock
            services.now = now
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
        let streaming = await eventually { h.connection.phase == .streaming }
        XCTAssertTrue(streaming, "phase \(h.connection.phase)")
        return (h, [dash, ctrl, data, mctl, mdata])
    }

    // MARK: L14 — scene changes

    @MainActor
    func testSceneLinesWithoutASession() async {
        let clock = MusicTestClock(1_000)
        let h = AppTestHarness { $0.clock = clock }
        let log = LogCapture()
        defer { log.stop() }
        h.model.scenePhaseChanged(.active) // the launch phase: no change, not logged
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        clock.advance(723)
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        h.model.scenePhaseChanged(.active) // no change
        h.model.scenePhaseChanged(.background) // SwiftUI may skip `.inactive`
        clock.advance(45.4)
        h.model.scenePhaseChanged(.active)
        XCTAssertEqual(sceneLines(log), [
            "scene active \u{2192} inactive (no session)",
            "scene inactive \u{2192} background (no session)",
            "scene background \u{2192} inactive after 12m03s (no session)",
            "scene inactive \u{2192} active (no session)",
            "scene active \u{2192} background (no session)",
            "scene background \u{2192} active after 45s (no session)",
        ])
    }

    @MainActor
    func testSceneLinesDuringAnOwnUIStreamingSession() async throws {
        let clock = MusicTestClock(1_000)
        let (h, keep) = try await streamingHarness(clock: clock, now: { Date() })
        let log = LogCapture()
        defer { log.stop() }
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        clock.advance(723)
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        XCTAssertEqual(sceneLines(log), [
            "scene active \u{2192} inactive (own UI session, streaming)",
            "scene inactive \u{2192} background (own UI session, streaming)",
            "scene background \u{2192} inactive after 12m03s (own UI session, streaming)",
            "scene inactive \u{2192} active (own UI session, streaming)",
        ])
        XCTAssertFalse(keep.isEmpty)
        h.connection.stop()
    }

    @MainActor
    func testSceneLinesDuringAMirrorSession() async {
        let h = AppTestHarness()
        h.addBike()
        h.connection.startMirror()
        XCTAssertEqual(h.connection.phase, .mirroring)
        let log = LogCapture()
        defer { log.stop() }
        h.model.scenePhaseChanged(.inactive)
        XCTAssertEqual(sceneLines(log), ["scene active \u{2192} inactive (mirror session, mirroring)"])
        h.model.scenePhaseChanged(.active)
        h.connection.stop()
    }

    // MARK: L15 — the `[lock]` line

    @MainActor
    func testLockLineReportsTheLinkTheProjectionGPSHeadingAndPower() async throws {
        let clock = MusicTestClock(1_000)
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let (h, keep) = try await streamingHarness(clock: clock, now: { wall })
        h.system.batteryStatus = BatteryStatus(level: 0.63, state: .charging)
        h.projection.statsSummary = ProjectionStatsSummary(mode: "background-software", framesPerSecond: 5.2,
                                                           encoder: "vt-sw", pullRate: 5.1)
        h.location.emit(LocationFix(lat: 45.1, lon: 25.0, timeMs: 1_800_000_000_000 - 1_000)) // 1 s old
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        clock.advance(298)
        h.location.emitHeading(180) // 2 s before the line
        clock.advance(2)
        let log = LogCapture()
        defer { log.stop() }
        h.model.logLockStatus()
        XCTAssertEqual(lockLines(log), [
            "[lock] 5m00s locked link=streaming wifi=up pulls=5.1/s dash=backgroundSoftware vt-sw 5.2fps gps=1s "
                + "heading=2s batt=63% charging thermal=none lowPower=false",
        ])
        // Hold, no encoder name, no battery reading, heat and Low Power Mode.
        h.projection.statsSummary = ProjectionStatsSummary(mode: "hold", framesPerSecond: 0, pullRate: 1.04)
        h.system.batteryStatus = nil
        h.system.thermalLevel = .severe
        h.system.isLowPowerModeEnabled = true
        clock.advance(60)
        h.model.logLockStatus()
        XCTAssertEqual(lockLines(log).last,
                       "[lock] 6m00s locked link=streaming wifi=up pulls=1.0/s dash=hold - 0.0fps gps=1s heading=1m02s "
                           + "batt=- thermal=severe lowPower=true")
        XCTAssertFalse(keep.isEmpty)
        h.connection.stop()
    }

    @MainActor
    func testLockLineBeforeAnyFixOrHeadingAndWhileTheBikeWifiIsGone() async {
        let clock = MusicTestClock(1_000)
        let h = AppTestHarness { $0.clock = clock }
        h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        h.wifi.setNetwork(.unavailable)
        let lost = await eventually { h.connection.isBikeWifiLost }
        XCTAssertTrue(lost)
        clock.advance(31)
        let log = LogCapture()
        defer { log.stop() }
        // The 0.3 s park grace may already have parked the session (projection stopped): read both now.
        let phase = h.connection.phase
        let mode = h.projection.stats.mode
        h.model.logLockStatus()
        XCTAssertEqual(lockLines(log), [
            "[lock] 31s locked link=\(phase.rawValue) wifi=down pulls=0.0/s dash=\(mode) - 0.0fps gps=- heading=- "
                + "batt=- thermal=none lowPower=false",
        ])
        XCTAssertTrue(phase == .reconnecting || phase == .waitingForBike, "\(phase)")
        XCTAssertTrue(mode == "hold" || mode == "stopped", mode)
        h.connection.stop()
    }

    @MainActor
    func testLockLineEveryIntervalOnlyWhileBackgroundedWithAnOwnUISession() async {
        XCTAssertEqual(AppTestHarness().model.sessionLogInterval, 30, "the saver loop's cadence: 30 s")
        let h = AppTestHarness()
        h.model.sessionLogInterval = 0.05
        h.model.start()
        h.addBike()
        let log = LogCapture()
        defer { log.stop() }

        // No session, backgrounded: nothing.
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        await settle(0.3)
        XCTAssertEqual(lockLines(log), [], "no session")
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)

        // An own-UI session in the foreground: nothing.
        h.connection.connect()
        await settle(0.3)
        XCTAssertEqual(lockLines(log), [], "foreground")

        // Backgrounded: one line per interval.
        h.model.scenePhaseChanged(.inactive)
        await settle(0.2)
        XCTAssertEqual(lockLines(log), [], "inactive is not locked")
        h.model.scenePhaseChanged(.background)
        let repeated = await eventually(timeout: 5) { self.lockLines(log).count >= 3 }
        XCTAssertTrue(repeated, "\(lockLines(log))")
        XCTAssertTrue(h.connection.isSessionActive)

        // Back in the foreground: no more lines.
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        await settle(0.1)
        let count = lockLines(log).count
        await settle(0.3)
        XCTAssertEqual(lockLines(log).count, count, "foreground again")

        // A mirror session in the background (the rider uses other apps): not an own-UI session.
        h.connection.stop()
        h.connection.startMirror()
        XCTAssertEqual(h.connection.mode, .mirror)
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        await settle(0.3)
        XCTAssertEqual(lockLines(log).count, count, "mirror session")
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)
        h.connection.stop()
    }

    // MARK: The unclean-background-exit marker and L16

    @MainActor
    func testTheMarkerIsSetAtBackgroundDuringASessionAndClearedAtActive() async {
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        let h = AppTestHarness { $0.now = { wall } }
        let store = h.core.services.keyValueStore
        h.addBike()
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        XCTAssertNil(store.double(forKey: markerKey), "no session: no marker")
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)

        h.connection.connect()
        h.model.scenePhaseChanged(.inactive)
        XCTAssertNil(store.double(forKey: markerKey), "inactive is not the background")
        h.model.scenePhaseChanged(.background)
        XCTAssertEqual(store.double(forKey: markerKey), 1_800_000_000, "seconds since 1970 of the .background")
        h.model.scenePhaseChanged(.inactive)
        XCTAssertEqual(store.double(forKey: markerKey), 1_800_000_000, "kept until .active")
        h.model.scenePhaseChanged(.active)
        XCTAssertNil(store.double(forKey: markerKey), "cleared at .active")
        h.connection.stop()
    }

    @MainActor
    func testTheMarkerIsClearedWhenTheSessionEnds() async {
        let h = AppTestHarness()
        let store = h.core.services.keyValueStore
        h.addBike()
        h.connection.connect()
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        XCTAssertNotNil(store.double(forKey: markerKey))
        h.connection.stop() // the session ends while backgrounded
        XCTAssertNil(store.double(forKey: markerKey), "no session any more: a later kill is not 'during a session'")
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.active)

        // Any session counts (a mirror session lives in the background).
        h.connection.startMirror()
        h.model.scenePhaseChanged(.inactive)
        h.model.scenePhaseChanged(.background)
        XCTAssertNotNil(store.double(forKey: markerKey))
        h.connection.stop()
        XCTAssertNil(store.double(forKey: markerKey))
    }

    @MainActor
    func testStartReportsTheMarkerOfThePreviousRunFirstThenClearsIt() async throws {
        let store = InMemoryKeyValueStore()
        store.set(1_800_021_192.4, forKey: markerKey) // 2027-01-15 13:53:12 UTC
        let h = AppTestHarness { $0.keyValueStore = store }
        h.model.logs.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let log = LogCapture()
        defer { log.stop() }
        h.model.start()
        let app = log.all.filter { $0.tag == "APP" }
        let warnings = app.filter { $0.level == .warn }.map(\.message)
        XCTAssertEqual(warnings, ["previous run ended in the background during a dash session (backgrounded 13:53:12): "
                + "iOS stopped the app, or it was swiped away"])
        XCTAssertNil(store.double(forKey: markerKey), "cleared at launch")
        // Right after the build banner, before the rest of the launch.
        let banner = try XCTUnwrap(app.firstIndex { $0.message.hasPrefix("OpenCfMoto iOS ") })
        XCTAssertEqual(app[banner + 1].message, warnings.first)
        XCTAssertEqual(app.last?.message, "Ready. Tap Connect to project the map to your dash.")

        // A clean previous run: nothing.
        let clean = AppTestHarness()
        let log2 = LogCapture()
        defer { log2.stop() }
        clean.model.start()
        XCTAssertFalse(log2.messages(tag: "APP").contains { $0.hasPrefix("previous run ended") })
    }

    @MainActor
    func testTheL16TimeIsTheLocalTimeOfTheBackground() async throws {
        let at = Date(timeIntervalSince1970: 1_800_021_192)
        let madrid = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid")) // UTC+1 in January
        XCTAssertEqual(LockDiagnostics.uncleanBackgroundExit(backgroundedAt: at, timeZone: madrid),
                       "previous run ended in the background during a dash session (backgrounded 14:53:12): "
                           + "iOS stopped the app, or it was swiped away")
    }

    // MARK: ConnectionModel.isBikeWifiLost

    @MainActor
    func testIsBikeWifiLostFollowsTheLossTheParkAndTheReturn() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        XCTAssertFalse(h.connection.isBikeWifiLost, "no session")
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        XCTAssertFalse(h.connection.isBikeWifiLost)
        h.wifi.setNetwork(.unavailable)
        let lost = await eventually { h.connection.phase == .reconnecting }
        XCTAssertTrue(lost)
        XCTAssertTrue(h.connection.isBikeWifiLost)
        let parked = await eventually { h.connection.phase == .waitingForBike }
        XCTAssertTrue(parked)
        XCTAssertTrue(h.connection.isBikeWifiLost, "still gone while parked")
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        let back = await eventually { !h.connection.isBikeWifiLost }
        XCTAssertTrue(back)
        h.connection.stop()
        XCTAssertFalse(h.connection.isBikeWifiLost)
    }
}
