// SPDX-License-Identifier: AGPL-3.0-or-later
// «No link-lost alarm while stopped» (UI/UX P0): the stopped / moving rule, the notice for every
// link-down phase, and ConnectionModel through an ignition cycle at a stop (the bike Wi-Fi goes, the
// session parks, no dialog, calm words) versus a drop while moving (today's presentation), plus the
// "Lost the bike link" / "Dash not found" dialogs of an auto-recovery-off session.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class LinkLossAlarmTests: XCTestCase {
    // MARK: Rules

    func testStoppedMeansAtMostFiveKmhOrNoFreshSpeed() {
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(speedMps: 0, fixAgeSeconds: 1))
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(speedMps: 1.38, fixAgeSeconds: 1), "4.97 km/h")
        XCTAssertFalse(LinkLossAlarmPolicy.isStopped(speedMps: 1.5, fixAgeSeconds: 1), "5.4 km/h")
        XCTAssertFalse(LinkLossAlarmPolicy.isStopped(speedMps: 25, fixAgeSeconds: 0))
        // Not knowing counts as stopped: the rule only removes alarms.
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(speedMps: nil, fixAgeSeconds: 1))
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(speedMps: 25, fixAgeSeconds: nil))
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(speedMps: 25, fixAgeSeconds: 11), "stale fix")
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(speedMps: 25, fixAgeSeconds: -11), "fix from the future")
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(speedMps: .nan, fixAgeSeconds: 1))
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(speedMps: -1, fixAgeSeconds: 1))
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(speedMps: 25, fixAgeSeconds: .infinity))
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(lastFix: nil, now: Date()))
        let now = Date()
        let fresh = LocationFix(lat: 4.6, lon: -74.0, speedMps: 20, timeMs: Int64(now.timeIntervalSince1970 * 1000) - 2000)
        XCTAssertFalse(LinkLossAlarmPolicy.isStopped(lastFix: fresh, now: now))
        XCTAssertTrue(LinkLossAlarmPolicy.isStopped(lastFix: fresh, now: now.addingTimeInterval(30)))
    }

    func testTheNoticeForEveryPhase() {
        typealias P = LinkLossAlarmPolicy
        // Link up, or still connecting: nothing to say.
        for phase in ConnectionPhase.allCases where !P.isLinkDown(phase) {
            XCTAssertNil(P.notice(phase: phase, hasReachedDash: true, bikeWifiLost: true, stopped: true), phase.rawValue)
        }
        XCTAssertEqual(Set(ConnectionPhase.allCases.filter(P.isLinkDown)), [.reconnecting, .waitingForBike, .error])
        for phase in [ConnectionPhase.reconnecting, .waitingForBike, .error] {
            XCTAssertNil(P.notice(phase: phase, hasReachedDash: false, bikeWifiLost: true, stopped: true),
                         "a session that never reached the dash is connecting, not lost (\(phase))")
            XCTAssertEqual(P.notice(phase: phase, hasReachedDash: true, bikeWifiLost: true, stopped: false), .droppedWhileMoving)
            XCTAssertEqual(P.notice(phase: phase, hasReachedDash: true, bikeWifiLost: true, stopped: true), .bikeOffWhileStopped)
        }
        XCTAssertEqual(P.notice(phase: .reconnecting, hasReachedDash: true, bikeWifiLost: false, stopped: true), .dashAwayWhileStopped)
        XCTAssertEqual(P.notice(phase: .error, hasReachedDash: true, bikeWifiLost: false, stopped: true), .dashAwayWhileStopped)
        XCTAssertEqual(P.notice(phase: .waitingForBike, hasReachedDash: true, bikeWifiLost: false, stopped: true), .bikeOffWhileStopped)
        XCTAssertTrue(LinkLossNotice.bikeOffWhileStopped.isQuiet)
        XCTAssertTrue(LinkLossNotice.dashAwayWhileStopped.isQuiet)
        XCTAssertFalse(LinkLossNotice.droppedWhileMoving.isQuiet)

        XCTAssertFalse(P.allowsLinkLossDialog(hasReachedDash: true, stopped: true))
        XCTAssertTrue(P.allowsLinkLossDialog(hasReachedDash: true, stopped: false))
        XCTAssertTrue(P.allowsLinkLossDialog(hasReachedDash: false, stopped: true), "a failed connect still explains itself")
    }

    // MARK: ConnectionModel

    /// A fix taken just now at `speed` m/s.
    private func fix(speed: Double) -> LocationFix {
        LocationFix(lat: 4.6584, lon: -74.0930, speedMps: speed, accuracyM: 5,
                    timeMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// A session that reached the dash (the link reported STREAMING).
    @MainActor
    private func streamingSession(_ h: AppTestHarness) async -> BikeQR {
        let (_, qr) = h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        h.connection.handleLinkEvent(.state(.streaming), gen: h.connection.generation, serial: h.connection.linkSerial)
        XCTAssertEqual(h.connection.phase, .streaming)
        XCTAssertNil(h.connection.linkLossNotice)
        return qr
    }

    @MainActor
    func testAnIgnitionCycleAtAStopRaisesNoAlarm() async {
        let h = AppTestHarness()
        let qr = await streamingSession(h)
        h.location.emit(fix(speed: 0))
        // Ignition off: the bike Wi-Fi goes.
        h.wifi.setNetwork(.unavailable)
        let lost = await eventually { h.connection.phase == .reconnecting }
        XCTAssertTrue(lost)
        XCTAssertEqual(h.connection.linkLossNotice, .bikeOffWhileStopped)
        XCTAssertNil(h.connection.issue)
        // The session parks (the 180-s grace, shortened here): still calm, still no dialog.
        let parked = await eventually { h.connection.phase == .waitingForBike }
        XCTAssertTrue(parked)
        XCTAssertEqual(h.connection.linkLossNotice, .bikeOffWhileStopped)
        XCTAssertNil(h.connection.issue)
        XCTAssertTrue(h.connection.isSessionActive, "it reconnects by itself")
        // Ignition on: the Wi-Fi is back and a fresh link starts; the dash answers → nothing to say.
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        let relinked = await eventually { h.connection.link != nil && !h.connection.isParked }
        XCTAssertTrue(relinked)
        h.connection.handleLinkEvent(.state(.streaming), gen: h.connection.generation, serial: h.connection.linkSerial)
        XCTAssertNil(h.connection.linkLossNotice)
        h.connection.stop()
        XCTAssertNil(h.connection.linkLossNotice)
    }

    @MainActor
    func testADropWhileMovingKeepsTodaysPresentation() async {
        let h = AppTestHarness()
        _ = await streamingSession(h)
        h.location.emit(fix(speed: 16)) // 58 km/h
        h.connection.handleLinkEvent(.state(.reconnecting(attempt: 1)), gen: h.connection.generation,
                                     serial: h.connection.linkSerial)
        XCTAssertEqual(h.connection.phase, .reconnecting)
        XCTAssertEqual(h.connection.linkLossNotice, .droppedWhileMoving)
        // The rider pulls over: the same drop now reads calm.
        h.location.emit(fix(speed: 0))
        XCTAssertEqual(h.connection.linkLossNotice, .dashAwayWhileStopped)
        h.connection.stop()
    }

    @MainActor
    func testTheDashNotAnsweringAtTheReJoinIsCalmWhileStopped() async {
        let h = AppTestHarness()
        _ = await streamingSession(h)
        h.location.emit(fix(speed: 0))
        // Auto-recovery on (default): the link fails and re-arms → .error, but no alarm at a stop.
        h.connection.handleLinkEvent(.state(.failed(.dashNotFound)), gen: h.connection.generation,
                                     serial: h.connection.linkSerial)
        XCTAssertEqual(h.connection.phase, .error)
        XCTAssertTrue(h.connection.isSessionActive)
        XCTAssertEqual(h.connection.linkLossNotice, .dashAwayWhileStopped)
        XCTAssertNil(h.connection.issue)
        h.connection.stop()
    }

    @MainActor
    func testWithAutoRecoveryOffALostLinkEndsQuietlyAtAStopButExplainsItselfWhileMoving() async {
        for moving in [false, true] {
            let h = AppTestHarness()
            let (bike, _) = h.addBike()
            h.core.settings.update(forBike: bike.id) { $0.autoRecovery = false }
            h.connection.connect()
            _ = await eventually { h.connection.link != nil }
            h.connection.handleLinkEvent(.state(.streaming), gen: h.connection.generation, serial: h.connection.linkSerial)
            h.location.emit(fix(speed: moving ? 20 : 0))
            h.connection.handleLinkEvent(.state(.failed(.lostLink)), gen: h.connection.generation,
                                         serial: h.connection.linkSerial)
            XCTAssertEqual(h.connection.phase, .error)
            XCTAssertFalse(h.connection.isSessionActive)
            XCTAssertEqual(h.connection.detail, SessionText.lostLink(h.language))
            if moving {
                XCTAssertEqual(h.connection.issue, .lostLink, "moving: the dialog explains it")
            } else {
                XCTAssertNil(h.connection.issue, "stopped: no alarm, the status line says it")
            }
        }
    }

    @MainActor
    func testWithAutoRecoveryOffTheReJoinWithoutADashEndsQuietlyAtAStop() async {
        let h = AppTestHarness()
        let (bike, _) = h.addBike()
        h.core.settings.update(forBike: bike.id) { $0.autoRecovery = false }
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        h.connection.handleLinkEvent(.state(.streaming), gen: h.connection.generation, serial: h.connection.linkSerial)
        h.location.emit(fix(speed: 0))
        h.connection.handleLinkEvent(.state(.failed(.dashNotFound)), gen: h.connection.generation,
                                     serial: h.connection.linkSerial)
        XCTAssertEqual(h.connection.phase, .error)
        XCTAssertNil(h.connection.issue)
        XCTAssertEqual(h.connection.detail, SessionText.easyConnOffline(h.language))
    }

    @MainActor
    func testAConnectThatNeverReachedTheDashStillExplainsItself() async {
        // Stopped at home, Connect, the dash never answers: that is a failed connect, not a lost link.
        let h = AppTestHarness()
        let (bike, _) = h.addBike()
        h.core.settings.update(forBike: bike.id) { $0.autoRecovery = false }
        h.location.emit(fix(speed: 0))
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        h.connection.handleLinkEvent(.state(.failed(.lostLink)), gen: h.connection.generation,
                                     serial: h.connection.linkSerial)
        XCTAssertEqual(h.connection.issue, .lostLink)
        XCTAssertNil(h.connection.linkLossNotice)
    }
}
