// SPDX-License-Identifier: AGPL-3.0-or-later
// ConnectionModel regressions from the wave-3 review (uids in each test's comment): stale link
// events, the manual-join baseline race, Stop / Local Network issue in a re-arming error, parking,
// the bike-network fingerprint (SSID unknown), auto-connect gating and retry, phone-hotspot QRs,
// mirror location / fit / margins, dash serial redaction.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class ConnectionReviewFixTests: XCTestCase {
    // MARK: CON:CL-6 — stale events of a replaced link

    @MainActor
    func testAStaleEventOfTheReplacedLinkIsIgnoredAfterAWifiBackRestart() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        let oldSerial = h.connection.linkSerial
        let gen = h.connection.generation
        h.wifi.setNetwork(.unavailable)
        _ = await eventually { h.connection.phase == .reconnecting }
        h.wifi.setNetwork(AppTestHarness.bikeNetwork(ssid: qr.ssid))
        let restarted = await eventually { h.connection.link != nil && h.connection.linkSerial != oldSerial }
        XCTAssertTrue(restarted)
        XCTAssertEqual(h.connection.generation, gen) // a Wi-Fi-back restart keeps the session generation

        // Events the old link's consumer had already dequeued: no effect on the new link's session.
        let phase = h.connection.phase
        let state = h.connection.linkState
        h.connection.handleLinkEvent(.state(.failed(.lostLink)), gen: gen, serial: oldSerial)
        h.connection.handleLinkEvent(.state(.streaming), gen: gen, serial: oldSerial)
        XCTAssertEqual(h.connection.phase, phase)
        XCTAssertEqual(h.connection.linkState, state)
        XCTAssertFalse(h.ride.isProjecting)
        XCTAssertNotNil(h.connection.session)

        // The current link's events still pass.
        h.connection.handleLinkEvent(.state(.reconnecting(attempt: 1)), gen: gen, serial: h.connection.linkSerial)
        XCTAssertEqual(h.connection.phase, .reconnecting)
        h.connection.stop()
    }

    @MainActor
    func testStopLinkInvalidatesTheSerial() async {
        let h = AppTestHarness()
        h.addBike()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        let serial = h.connection.linkSerial
        let gen = h.connection.generation
        h.connection.stop()
        XCTAssertNotEqual(h.connection.linkSerial, serial)
        h.connection.handleLinkEvent(.state(.streaming), gen: gen, serial: serial)
        XCTAssertEqual(h.connection.phase, .stopped)
    }
}
