// SPDX-License-Identifier: AGPL-3.0-or-later
// End-to-end: ConnectionModel → a REAL EasyConnLink over the in-memory network against the
// scripted fake dash (control-plane.md §6.1 CFDL16 sequence, media-video.md §4.11), with the
// projection frame source served to the dash: Connect → STREAMING (frames pulled, IDR first),
// canvas learned, profile hint, encoder plan, trip auto-log, a dash touch on a hit region,
// a dash-side drop → RECONNECTING + dash banner → STREAMING again, Stop. Plus the mirror path.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class ConnectionEndToEndTests: XCTestCase {
    struct DashSockets {
        let ctrl: LinkFakeControl
        let data: LinkFakeControl
        let mctl: LinkFakeMedia
        let mdata: LinkFakeMedia
        func closeAll() {
            ctrl.close()
            data.close()
            mctl.close()
            mdata.close()
        }
    }

    /// CFDL16 control handshake (CAR_CTRL, CLIENT_INFO, QUERY_SPEED; CAR_DATA, CHECK_SN), then the
    /// media channels: REQ 16 (800×386) + 112 on :10921, and the :10920 data socket.
    private func handshake(_ dash: LinkFakeDash) async throws -> DashSockets {
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
        return DashSockets(ctrl: ctrl, data: data, mctl: mctl, mdata: mdata)
    }

    private func texts(_ list: DashDisplayList) -> [String] {
        list.commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
    }

    @MainActor
    func testConnectStreamsTheOwnDashUIToTheDash() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let frames = TestFrameSource()
        let h = AppTestHarness(network: net, frameSource: frames)
        let (bike, qr) = h.addBike()
        let l = h.language

        h.connection.connect()
        let probed = await eventually { dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        XCTAssertEqual(net.listenLog, [10922, 10921, 10920]) // listeners up before the probe
        XCTAssertEqual(net.connectLog.first, "192.168.0.1:10930")
        XCTAssertEqual(h.connection.phase, .linking)
        XCTAssertEqual(h.connection.detail, bike.name)

        let s = try await handshake(dash)
        for seq in 1 ... 3 {
            try await s.mdata.send(cmd: 114)
            let f = try await s.mdata.frame()
            XCTAssertEqual(f.raw, TestFrameSource.frame(seq: UInt64(seq), key: seq == 1).wireBytes, "pull \(seq)")
        }
        let streaming = await eventually { h.connection.phase == .streaming }
        XCTAssertTrue(streaming)
        XCTAssertEqual(h.connection.detail, bike.name)
        XCTAssertTrue(h.ride.isProjecting)
        XCTAssertEqual(h.ride.canvasSize, DashSize(width: 800, height: 384))
        XCTAssertEqual(h.ride.displayList(now: h.core.services.clock.now()).size, DashSize(width: 800, height: 384))
        XCTAssertEqual(h.core.dashMemory.learnedSize(forSSID: qr.ssid), LearnedDashSize(width: 800, height: 386))
        XCTAssertEqual(h.core.garage.bike(id: bike.id)?.profileHint, .legacy)
        XCTAssertEqual(h.connection.diagnostics.dashInfo?.huid, "6GUVA2C00100055")
        XCTAssertEqual(h.connection.diagnostics.canvas?.width, 800)
        XCTAssertEqual(h.connection.diagnostics.profileName, BikeProfile.legacy.name)
        // Encoder plan: profile × quality × power mode with the own-UI map boost.
        let plan = EncoderPlanner.plan(profile: RideEncoderPlan.values(.legacy), quality: .balanced, powerMode: .balanced, ownUI: true)
        XCTAssertEqual(frames.preparedParameters, plan)
        XCTAssertEqual(h.projection.parameters, plan)
        // Trip auto-log runs while the own UI is on the dash.
        XCTAssertTrue(h.core.tripRecorder.isRecording)
        XCTAssertTrue(h.location.isRideActive)

        // A dash touch on the search pill → "type on the phone".
        h.ride.flushModel()
        let list = h.ride.displayList(now: h.core.services.clock.now())
        let pill = try XCTUnwrap(list.hitRegions.first { $0.id == "pill" })
        let x = Int(pill.rect.midX)
        let y = Int(pill.rect.midY)
        try await s.mctl.send(cmd: 32, body: PxcTouchFrame(rawAction: 2, x: x, y: y).encodedBody())
        try await s.mctl.send(cmd: 32, body: PxcTouchFrame(rawAction: 1, x: x, y: y).encodedBody())
        let typed = await eventually { h.model.navigation.typeOnPhoneRequested }
        XCTAssertTrue(typed)
        XCTAssertEqual(h.ride.ui.state.sheet, .search)
        XCTAssertEqual(h.system.hapticCount, 1)
        XCTAssertEqual(h.speech.spoken.last, NavStrings(language: l).phrase(.typeSearchOnPhone))

        // The dash drops every socket → RECONNECTING "attempt N" and a banner on the dash picture.
        s.closeAll()
        let reconnecting = await eventually { h.connection.phase == .reconnecting }
        XCTAssertTrue(reconnecting)
        XCTAssertTrue(h.connection.detail.hasSuffix("1") || h.connection.detail.hasSuffix("2") || h.connection.detail.hasSuffix("3"),
                      h.connection.detail)
        let banner = await eventually {
            self.texts(h.ride.displayList(now: h.core.services.clock.now())).contains(SessionText.reconnectingBanner(l))
        }
        XCTAssertTrue(banner)
        let reprobed = await eventually { dash.acceptedCount.current >= 2 }
        XCTAssertTrue(reprobed)

        // The dash calls back: streaming again, IDR first, the bike name back in the detail line.
        let ctrl2 = try dash.openControl()
        try await ctrl2.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl2.nextRaw()
        let mctl2 = try dash.openMedia(port: 10921)
        try await mctl2.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        _ = try await mctl2.reply()
        try await mctl2.send(cmd: 112)
        _ = try await mctl2.reply()
        let mdata2 = try dash.openMedia(port: 10920)
        try await mdata2.send(cmd: 114)
        let first = try await mdata2.frame()
        XCTAssertTrue(AnnexB.containsIDR(annexB: first.accessUnit))
        let back = await eventually { h.connection.phase == .streaming }
        XCTAssertTrue(back)
        XCTAssertEqual(h.connection.detail, bike.name)
        let cleared = await eventually {
            !self.texts(h.ride.displayList(now: h.core.services.clock.now())).contains(SessionText.reconnectingBanner(l))
        }
        XCTAssertTrue(cleared)

        // Stop everything.
        h.connection.stop()
        XCTAssertEqual(h.connection.phase, .stopped)
        let closed = await linkEventually { net.openListenerPorts.isEmpty }
        XCTAssertTrue(closed)
        XCTAssertFalse(h.ride.isProjecting)
        XCTAssertEqual(h.projection.stats.mode, "stopped")
        XCTAssertFalse(h.core.tripRecorder.isRecording)
        XCTAssertEqual(h.wifi.forgottenSSIDs, [qr.ssid])
        XCTAssertEqual(h.cellular.current, [true, false])
        ctrl2.close()
        mctl2.close()
        mdata2.close()
    }

    @MainActor
    func testMirrorSessionServesTheRelayAndIgnoresDashTouches() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.2")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let mirror = TestMirrorHost()
        let h = AppTestHarness(network: net, mirror: mirror)
        let (bike, _) = h.addBike()

        h.connection.startMirror()
        XCTAssertEqual(h.connection.phase, .mirroring)
        let probed = await eventually { dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        let s = try await handshake(dash)
        try await s.mdata.send(cmd: 114)
        let f = try await s.mdata.frame()
        XCTAssertTrue(AnnexB.containsIDR(annexB: f.accessUnit))
        let live = await eventually { h.connection.phase == .mirroring && h.connection.linkState == .streaming }
        XCTAssertTrue(live)
        XCTAssertEqual(h.connection.detail, bike.name)
        XCTAssertFalse(h.ride.isProjecting) // the own UI is not on the dash
        // No map boost for mirrored content.
        let plan = EncoderPlanner.plan(profile: RideEncoderPlan.values(.legacy), quality: .balanced, powerMode: .balanced, ownUI: false)
        XCTAssertEqual(mirror.source.preparedParameters, plan)
        XCTAssertFalse(h.core.tripRecorder.isRecording) // mirror sessions are not auto-logged

        // A dash touch never reaches the own UI in mirror mode.
        try await s.mctl.send(cmd: 32, body: PxcTouchFrame(rawAction: 2, x: 780, y: 20).encodedBody())
        try await s.mctl.send(cmd: 32, body: PxcTouchFrame(rawAction: 1, x: 780, y: 20).encodedBody())
        await settle(0.3)
        XCTAssertEqual(h.ride.ui.state.sheet, .none)

        // A second Mirror tap while frames flow is ignored (15 s guard).
        _ = await eventually { h.connection.link?.stats.lastFrameAt != nil }
        let link = h.connection.link
        h.connection.startMirror()
        XCTAssertTrue(h.connection.link === link)
        XCTAssertEqual(h.connection.detail, SessionText.alreadyMirroring(h.language))
        XCTAssertTrue(mirror.isRunning)

        h.connection.stop()
        XCTAssertFalse(mirror.isRunning)
        let closed = await linkEventually { net.openListenerPorts.isEmpty }
        XCTAssertTrue(closed)
        s.closeAll()
    }
}
