// SPDX-License-Identifier: AGPL-3.0-or-later
// End-to-end: EasyConnLink over the in-memory network against a scripted dash.
// Sequences: control-plane.md §6.1 (CFDL16) and §6.2 (CFDL26 + notify burst), media-video.md §4.11,
// session-network.md §5–§6 (listeners before probe, connect-back, reconnect loop, watchdog).
// Timers are shortened so the suite runs in seconds.
import XCTest
@testable import OpenCfMotoCore

final class LinkEndToEndTests: XCTestCase {
    struct Harness {
        let net: LinkMemoryNetwork
        let dash: LinkFakeDash
        let source: LinkFakeFrameSource
        let link: EasyConnLink
        let recorder: LinkEventRecorder
    }

    static var fastTimings: LinkTimings {
        var t = LinkTimings()
        t.probeConnectTimeout = 0.3
        t.probeReadTimeout = 0.5
        t.probeRetryUnit = 0.01
        t.bonjourBrowseTimeout = 0.2
        t.portScanConnectTimeout = 0.02
        t.heartbeatInterval = 0.2
        t.reconnectBackoffBase = 0.02
        t.reconnectBackoffStep = 0.02
        t.reconnectBackoffCap = 0.1
        t.reconnectSettle = 0.4
        t.watchdogTick = 0.1
        t.errorRearmInterval = 0.4
        t.statsWindow = 1
        return t
    }

    private func makeHarness(qr: BikeQR? = nil, localHost: String? = "192.168.0.50", gateway: String? = "192.168.0.1",
                             connectBackTimeout: TimeInterval = 2, stallTimeout: TimeInterval = 8,
                             cooldown: TimeInterval = 20, maxReconnects: Int = 20, discovery: DashDiscovery? = nil,
                             installProbe: Bool = true, configure: (inout LinkOptions) -> Void = { _ in }) -> Harness {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.50")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        if installProbe { dash.installProbeServer() }
        let source = LinkFakeFrameSource()
        let config = LinkConfiguration(qr: qr, phone: LinkTestKeys.examplePhone, localHost: localHost,
                                       connectBackTimeout: connectBackTimeout, stallTimeout: stallTimeout,
                                       stallReconnectCooldown: cooldown, maxReconnectAttempts: maxReconnects,
                                       framePullTimeout: 0.3)
        var options = LinkOptions()
        options.timings = Self.fastTimings
        options.interfaceProvider = { [] }
        options.wallClockMillis = { 1_786_272_219_244 }
        options.timeZone = { TimeZone(identifier: "Europe/Rome")! }
        configure(&options)
        let link = EasyConnLink(configuration: config, network: net, frameSource: source, signer: LinkTestKeys.fixtureSigner,
                                discovery: discovery, gateway: gateway, options: options)
        return Harness(net: net, dash: dash, source: source, link: link, recorder: LinkEventRecorder(link))
    }

    private func waitState(_ h: Harness, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ match: @escaping (LinkState) -> Bool) async {
        let ok = await linkEventually(timeout: timeout) { match(h.link.state) }
        XCTAssertTrue(ok, "state is \(h.link.state)", file: file, line: line)
    }

    private func isReconnecting(_ s: LinkState) -> Bool { if case .reconnecting = s { return true } else { return false } }

    /// Events reach the recorder asynchronously: wait for the condition instead of asserting at once.
    private func recorded(_ h: Harness, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                          _ what: String = "", _ condition: @escaping (LinkEventRecorder) -> Bool) async {
        let ok = await linkEventually(timeout: timeout) { condition(h.recorder) }
        XCTAssertTrue(ok, "not recorded: \(what) — states \(h.recorder.states)", file: file, line: line)
    }

    /// Fixed acks of the CFDL26 burst (cmd + 1, empty).
    private func ack(_ cmd: UInt32) -> Data { PxcFrame(cmd: cmd + 1).encoded() }

    // MARK: - CFDL16 (BIKE A) full session + touch + disconnect/reconnect

    func testCFDL16SessionThenTouchThenReconnect() async throws {
        let h = makeHarness()
        h.link.start()

        // Listeners are up BEFORE the probe, then exactly the 86 probe bytes.
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        XCTAssertEqual(h.net.listenLog, [10922, 10921, 10920])
        XCTAssertEqual(h.dash.probesReceived.current, [PxcProbe.frameBytes])
        XCTAssertEqual(h.net.connectLog, ["192.168.0.1:10930"])
        await waitState(h) { $0 == .awaitingCallback }

        // :10922 #1 — CAR_CTRL, CLIENT_INFO, QUERY_SPEED.
        let ctrl = try h.dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        let carCtrlAck = try await ctrl.nextRaw()
        XCTAssertEqual(carCtrlAck, linkHex("01 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00"))
        await waitState(h) { $0 == .handshaking }
        try await ctrl.send(cmd: 0x10010, json: LinkDashSamples.cfdl16ClientInfo)
        let clientInfoReply = try await ctrl.next()
        XCTAssertEqual(clientInfoReply.raw.prefix(16), linkHex("11 00 01 00 30 03 00 00 21 03 01 00 00 00 00 00"))
        XCTAssertEqual(clientInfoReply.frame.payloadText, ProtocolClientInfoTests.workedExampleJSON)
        try await ctrl.send(cmd: 0x10690, json: LinkDashSamples.querySpeed)
        let speedReply = try await ctrl.nextRaw()
        XCTAssertEqual(speedReply, linkHex("91 06 01 00 10 00 00 00 81 06 01 00 00 00 00 00"))

        // :10922 #2 — CAR_DATA, CHECK_SN.
        let data = try h.dash.openControl()
        try await data.send(PxcFrame(cmd: 0x20000))
        let carDataAck = try await data.nextRaw()
        XCTAssertEqual(carDataAck, linkHex("01 00 02 00 10 00 00 00 11 00 02 00 00 00 00 00"))
        try await data.send(cmd: 0x103E0, json: LinkDashSamples.checkSn)
        let snAck = try await data.nextRaw()
        let snResult = try await data.nextRaw()
        XCTAssertEqual(snAck, linkHex("e1 03 01 00 10 00 00 00 f1 03 01 00 00 00 00 00"))
        XCTAssertEqual(snResult, linkHex("c0 01 02 00 6b 00 00 00 ab 01 02 00 00 00 00 00 7b 22 69 73 4f 6b 22 3a 74 72 75 65 2c 22 65 72 72 43 6f 64 65 22 3a 30 2c 22 65 72 72 4d 73 67 22 3a 22 22 2c 22 69 64 22 3a 22 44 53 58 58 5a 4d 48 4e 46 56 33 44 45 58 45 42 42 33 50 5a 32 22 2c 22 63 6c 69 65 6e 74 5f 73 65 74 22 3a 22 65 61 73 79 5f 63 6f 6e 6e 22 7d"))
        try await data.send(PxcFrame(cmd: 0x201C1)) // ignored
        await waitState(h) { $0 == .awaitingMedia }

        // Heartbeats both ways: the dash's is answered, the phone beats every interval on BOTH sockets.
        try await ctrl.send(PxcFrame(cmd: 0x7000_0000))
        let hbAck = try await ctrl.nextRaw()
        XCTAssertEqual(hbAck, linkHex("01 00 00 70 10 00 00 00 11 00 00 70 00 00 00 00"))
        await ctrl.expectSilence(for: 0.5)
        await data.expectSilence(for: 0.5)
        XCTAssertGreaterThanOrEqual(ctrl.heartbeats.current, 2)
        XCTAssertGreaterThanOrEqual(data.heartbeats.current, 2)
        XCTAssertEqual(ctrl.lastHeartbeatRaw.current, linkHex("00 00 00 70 10 00 00 00 10 00 00 70 00 00 00 00"))

        // :10921 media control — 16, 48, 96, 64, 112.
        let mctl = try h.dash.openMedia(port: 10921)
        try await mctl.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        let rly17 = try await mctl.reply()
        XCTAssertEqual(rly17.raw, linkHex("11 00 09 00 00 00 00 00 02 00 00 00 20 03 80 01 00"))
        try await mctl.send(cmd: 48)
        let rly49 = try await mctl.reply()
        XCTAssertEqual(rly49.raw, linkHex("31 00 08 00 00 00 00 00 03 00 00 00 01 00 00 00"))
        try await mctl.send(cmd: 96, body: Data("{}".utf8))
        let rly97 = try await mctl.reply()
        XCTAssertEqual(rly97.raw, linkHex("61 00 0b 00 00 00 00 00 7b 22 73 74 61 74 65 22 3a 30 7d"))
        try await mctl.send(cmd: 64)
        let rly65 = try await mctl.reply()
        XCTAssertEqual(rly65.raw, linkHex("41 00 00 00 00 00 00 00"))
        try await mctl.send(cmd: 112)
        let rly113 = try await mctl.reply()
        XCTAssertEqual(rly113.raw, linkHex("71 00 00 00 00 00 00 00"))
        let canvas = VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386, requestedFps: 30)
        XCTAssertEqual(h.source.calls, [.prepare(canvas, BikeProfile.legacy.encoderDefaults), .resynchronize])

        // :10920 media data — pulls answered with exactly one raw [size][AU] each, IDR first.
        let mdata = try h.dash.openMedia(port: 10920)
        for seq in 1 ... 4 {
            try await mdata.send(cmd: 114)
            let f = try await mdata.frame()
            XCTAssertEqual(f.raw, LinkFakeFrameSource.frame(seq: UInt64(seq), key: seq == 1).wireBytes, "pull \(seq)")
        }
        await waitState(h) { $0 == .streaming }
        // Counters are updated right after each write completes (the dash may observe the bytes first).
        let counted = await linkEventually { h.link.stats.framesSent == 4 }
        XCTAssertTrue(counted, "framesSent \(h.link.stats.framesSent)")
        XCTAssertEqual(h.link.stats.keyframesSent, 1)

        // Touch on :10921: never answered, delivered (after the 80 ms hold for the UP).
        try await mctl.send(cmd: 32, body: PxcTouchFrame(rawAction: 2, x: 400, y: 200).encodedBody())
        try await mctl.send(cmd: 32, body: PxcTouchFrame(rawAction: 1, x: 400, y: 200).encodedBody())
        await mctl.expectSilence(for: 0.15)
        let touched = await linkEventually { h.recorder.touches.count == 2 }
        XCTAssertTrue(touched)
        XCTAssertEqual(h.recorder.touches.map(\.action), [.down, .up])
        XCTAssertEqual(h.recorder.touches.map { [$0.x, $0.y, $0.pointerId] }, [[400, 200, 0], [400, 200, 0]])

        // Events and public state.
        await recorded(h, "dashIdentified") { $0.identified.map(\.huid) == ["6GUVA2C00100055"] }
        await recorded(h, "canvas") { $0.canvases == [canvas] }
        await recorded(h, "mediaStarted") { $0.mediaStartedCount == 1 }
        XCTAssertEqual(h.link.dashInfo?.profile, .legacy)
        XCTAssertEqual(h.link.currentProfile, .legacy)
        XCTAssertEqual(h.link.canvas, canvas)
        for expected: LinkState in [.startingServers, .probing(attempt: 1), .awaitingCallback, .handshaking, .awaitingMedia, .streaming] {
            await recorded(h, "\(expected)") { $0.states.contains(expected) }
        }

        // The dash drops every socket → reconnect loop re-probes :10930; media stopped.
        for c in [ctrl, data] { c.close() }
        mctl.close()
        mdata.close()
        await waitState(h) { self.isReconnecting($0) }
        let mediaStopped = await linkEventually { h.source.calls.contains(.mediaStopped) }
        XCTAssertTrue(mediaStopped)
        let reprobed = await linkEventually { h.dash.acceptedCount.current >= 2 }
        XCTAssertTrue(reprobed)
        await recorded(h, "reconnecting(1)") { $0.states.contains(.reconnecting(attempt: 1)) }

        // The dash calls back: a new session on the same listeners, IDR first again.
        let ctrl2 = try h.dash.openControl()
        try await ctrl2.send(PxcFrame(cmd: 0x10000))
        let ack2 = try await ctrl2.nextRaw()
        XCTAssertEqual(ack2, linkHex("01 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00"))
        await waitState(h) { $0 == .handshaking }
        let mctl2 = try h.dash.openMedia(port: 10921)
        try await mctl2.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        _ = try await mctl2.reply()
        try await mctl2.send(cmd: 112)
        _ = try await mctl2.reply()
        let mdata2 = try h.dash.openMedia(port: 10920)
        try await mdata2.send(cmd: 114)
        let first = try await mdata2.frame()
        XCTAssertTrue(AnnexB.containsIDR(annexB: first.accessUnit))
        await waitState(h) { $0 == .streaming }

        h.link.stop()
        XCTAssertEqual(h.link.state, .stopped)
        let closed = await linkEventually { h.net.openListenerPorts.isEmpty }
        XCTAssertTrue(closed)
        do {
            _ = try await ctrl2.next(timeout: 1)
            XCTFail("socket should be closed by stop()")
        } catch {
            XCTAssertFalse(error is TimeoutError)
        }
    }

    // MARK: - CFDL26 (1000 MT-X) with the notify burst on CAR_DATA

    func testCFDL26HandshakeWithNotifyBurstThenMedia() async throws {
        let qr = BikeQR(raw: "http://x?ssid=DIRECT-CF-CFMOTO-805120", ssid: "DIRECT-CF-CFMOTO-805120", password: "12345678",
                        action: 9, modelId: "37426")
        let h = makeHarness(qr: qr)
        XCTAssertEqual(h.link.currentProfile, .cfdl26Portrait) // early QR pick
        h.link.start()
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)

        let ctrl = try h.dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        try await ctrl.send(cmd: 0x10010, json: LinkDashSamples.mtxClientInfo)
        let reply = try await ctrl.next()
        let expected = PhoneClientInfoReply.build(phone: LinkTestKeys.examplePhone, huid: "6WX0AT231300200",
                                                  signer: LinkTestKeys.fixtureSigner, profile: .cfdl26Portrait,
                                                  forceTouch: false, forceNonTouch: false)
        XCTAssertEqual(reply.raw, PhoneClientInfoReply.frame(expected).encoded())
        XCTAssertTrue(reply.frame.payloadText.contains("\"supportFunction\":128"))
        XCTAssertFalse(reply.frame.payloadText.contains("supportScreenTouch")) // Portrait: only with Force touchscreen
        try await ctrl.send(cmd: 0x10690, json: LinkDashSamples.querySpeed)
        _ = try await ctrl.nextRaw()

        let data = try h.dash.openControl()
        try await data.send(PxcFrame(cmd: 0x20000))
        _ = try await data.nextRaw()
        // The burst: every frame must be answered or the dash never opens the media ports.
        try await data.send(cmd: 0x10780, json: "{\"log\":\"…mdns success…\"}")
        let logAck = try await data.nextRaw()
        XCTAssertEqual(logAck, linkHex("81 07 01 00 10 00 00 00 91 07 01 00 00 00 00 00"))
        try await data.send(cmd: 0x103E0, json: LinkDashSamples.checkSn)
        let snAck = try await data.nextRaw()
        let snResult = try await data.next()
        XCTAssertEqual(snAck, linkHex("e1 03 01 00 10 00 00 00 f1 03 01 00 00 00 00 00"))
        XCTAssertEqual(snResult.frame.cmd, 0x201C0)
        try await data.send(cmd: 0x103A0, json: "{\"port\":11021,\"userName\":\"carbit_ec_ftp_ota\",\"pwd\":\"secret\"}")
        let otaAck = try await data.nextRaw()
        XCTAssertEqual(otaAck, linkHex("a1 03 01 00 10 00 00 00 b1 03 01 00 00 00 00 00"))
        try await data.send(cmd: 0x10020, json: "{\"music\":1,\"talkie\":0,\"tts\":1,\"vr\":0,\"autoChangeToBT\":0}")
        let featAck = try await data.nextRaw()
        XCTAssertEqual(featAck, ack(0x10020))
        try await data.send(cmd: 0x10040, json: "{\"maxNaviIcon\":161,\"supportFunction\":0}")
        let naviAck = try await data.nextRaw()
        XCTAssertEqual(naviAck, ack(0x10040))
        try await data.send(PxcFrame(cmd: 0x10600, payload: LinkDashSamples.timeSyncRequest()))
        let timeAck = try await data.nextRaw()
        XCTAssertEqual(timeAck, linkHex("""
            01 06 01 00 3d 00 00 00 3c 06 01 00 00 00 00 00
            fe ff ff ff 32 92 00 00 07 00 00 00 00 00 00 00
            32 30 32 36 2d 30 37 2d 32 34 20 31 37 3a 30 39
            3a 32 30 2e 31 39 30 30 30 30 30 30 30
            """))
        try await data.send(PxcFrame(cmd: 0x10750))
        let periodicAck = try await data.nextRaw()
        XCTAssertEqual(periodicAck, ack(0x10750))
        try await data.send(PxcFrame(cmd: 0x10430))
        let ack10430 = try await data.nextRaw()
        XCTAssertEqual(ack10430, ack(0x10430))
        try await data.send(PxcFrame(cmd: 0x10450))
        let queryTimeAck = try await data.nextRaw()
        XCTAssertEqual(queryTimeAck, linkHex("51 04 01 00 10 00 00 00 41 04 01 00 00 00 00 00"))
        try await data.send(cmd: 0x10460, json: "{\"bluetooth\":4129}")
        let btAck = try await data.nextRaw()
        XCTAssertEqual(btAck, ack(0x10460))

        // Then the dash opens the media ports.
        let mctl = try h.dash.openMedia(port: 10921)
        let huid = String(repeating: "Q", count: 171) + "="
        try await mctl.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 951, huid: huid))
        let rly17 = try await mctl.reply()
        XCTAssertEqual(rly17.raw, linkHex("11 00 09 00 00 00 00 00 02 00 00 00 20 03 b0 03 00"))
        try await mctl.send(cmd: 112)
        _ = try await mctl.reply()
        let mdata = try h.dash.openMedia(port: 10920)
        for seq in 1 ... 3 {
            try await mdata.send(cmd: 114)
            let f = try await mdata.frame()
            XCTAssertEqual(f.raw, LinkFakeFrameSource.frame(seq: UInt64(seq), key: seq == 1).wireBytes)
        }
        await waitState(h) { $0 == .streaming }
        XCTAssertEqual(h.link.currentProfile, .cfdl26Portrait)
        XCTAssertEqual(h.link.dashInfo?.profile, .cfdl26Portrait)
        XCTAssertEqual(h.link.canvas?.height, 944)
        XCTAssertEqual(h.source.calls.first, .prepare(VideoCanvas(width: 800, height: 944, requestedWidth: 800,
                                                                  requestedHeight: 951, requestedFps: 30),
                                                      BikeProfile.cfdl26Portrait.encoderDefaults))
        h.link.stop()
    }

    // MARK: - Failure paths

    func testPortInUseFailsBeforeAnyProbe() async {
        let h = makeHarness()
        h.net.blockPort(10921)
        h.link.start()
        await waitState(h) { $0 == .failed(.portInUse(10921)) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.net.connectLog, []) // never probed
        XCTAssertEqual(h.net.openListenerPorts, []) // the 10922 listener was closed again
        XCTAssertEqual(h.link.state, .failed(.portInUse(10921)))
        h.link.stop()
    }

    func testNoAddressFailsWithNoWifiAddress() async {
        let h = makeHarness(localHost: nil, gateway: nil)
        h.link.start()
        await waitState(h) { $0 == .failed(.noWifiAddress) }
        XCTAssertEqual(h.net.listenLog, [])
        h.link.stop()
    }

    func testConnectBackTimeoutReprobes() async {
        let h = makeHarness(connectBackTimeout: 0.3)
        h.link.start()
        let reprobed = await linkEventually { h.dash.acceptedCount.current >= 2 }
        XCTAssertTrue(reprobed)
        await recorded(h, "awaitingCallback") { $0.states.contains(.awaitingCallback) }
        h.link.stop()
    }

    func testDashNotFoundScansThenRearmsWhenTheDashAppears() async {
        let h = makeHarness(installProbe: false)
        h.link.start()
        await waitState(h) { $0 == .failed(.dashNotFound) }
        // gateway:10930 ×5, then the 10915…10935 scan (21 connects).
        let log = h.net.connectLog
        XCTAssertEqual(log.prefix(5), Array(repeating: "192.168.0.1:10930", count: 5)[...])
        XCTAssertEqual(log.count, 5 + 21)
        XCTAssertEqual(log.last, "192.168.0.1:10935")
        // The dash shows its QR: the watchdog re-arms discovery and the probe is accepted.
        h.dash.installProbeServer()
        let accepted = await linkEventually { h.dash.acceptedCount.current >= 1 }
        XCTAssertTrue(accepted)
        await waitState(h) { $0 == .awaitingCallback }
        h.link.stop()
    }

    func testPortScanFindsNearbyProbePort() async {
        let h = makeHarness(installProbe: false)
        let nearby = LinkFakeDash(network: h.net, host: "192.168.0.1", probePort: 10925)
        nearby.installProbeServer()
        h.link.start()
        let accepted = await linkEventually { nearby.acceptedCount.current == 1 }
        XCTAssertTrue(accepted)
        await waitState(h) { $0 == .awaitingCallback }
        h.link.stop()
    }

    func testRejectedProbesRetryWithBackoffThenScan() async {
        let h = makeHarness()
        h.dash.probeBehavior.set(.reject)
        h.link.start()
        await waitState(h) { $0 == .failed(.dashNotFound) }
        XCTAssertEqual(h.dash.probesReceived.current.count, 5 + 2) // gateway ×5, then :10930 found by the scan ×2
        await recorded(h, "probing(7)") { $0.states.contains(.probing(attempt: 7)) }
        h.link.stop()
    }

    func testReconnectBudgetExhaustedFailsLostLink() async throws {
        let h = makeHarness(maxReconnects: 2)
        h.link.start()
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        let ctrl = try h.dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        h.dash.probeBehavior.set(.reject)
        ctrl.close()
        await waitState(h) { $0 == .failed(.lostLink) }
        await recorded(h, "reconnecting 1, 2") {
            $0.states.contains(.reconnecting(attempt: 1)) && $0.states.contains(.reconnecting(attempt: 2))
                && $0.states.contains(.failed(.lostLink))
        }
        XCTAssertFalse(h.recorder.states.contains(.reconnecting(attempt: 3)))
        // The watchdog re-arms after the error interval; a dash that accepts again gets probed.
        h.dash.probeBehavior.set(.accept)
        let again = await linkEventually { h.dash.acceptedCount.current >= 2 }
        XCTAssertTrue(again)
        h.link.stop()
    }

    func testWatchdogStallDropsSocketsAndReconnects() async throws {
        let h = makeHarness(stallTimeout: 0.4, cooldown: 0.2)
        h.link.start()
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        let ctrl = try h.dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        let mctl = try h.dash.openMedia(port: 10921)
        try await mctl.send(cmd: 112)
        _ = try await mctl.reply()
        let mdata = try h.dash.openMedia(port: 10920)
        try await mdata.send(cmd: 114)
        _ = try await mdata.frame()
        await waitState(h) { $0 == .streaming }
        // The encoder starves: pulls get nothing, no frame for > stallTimeout → every bike socket dropped.
        h.source.starve = true
        try await mdata.send(cmd: 114)
        await waitState(h, timeout: 5) { self.isReconnecting($0) }
        do {
            _ = try await ctrl.next(timeout: 1)
            XCTFail("expected the socket to be closed by the watchdog")
        } catch {
            XCTAssertFalse(error is TimeoutError)
        }
        XCTAssertGreaterThanOrEqual(h.link.stats.missedPulls, 1)
        let reprobed = await linkEventually { h.dash.acceptedCount.current >= 2 }
        XCTAssertTrue(reprobed)
        h.link.stop()
    }

    // MARK: - Discovery race, restart hygiene

    func testBonjourResultIsProbedWhenTheGatewayIsSilent() async {
        struct FakeBonjour: DashDiscovery {
            func discover(timeout: TimeInterval) async -> [DiscoveredDash] {
                try? await Task.sleep(nanoseconds: 30_000_000)
                return [DiscoveredDash(host: "192.168.0.1", port: 10930, txt: ["packagename": "com.cfmoto.easyconnect"])]
            }
        }
        // Gateway guess points at a host that does not answer at all (connect timeouts).
        let h = makeHarness(gateway: "192.168.0.254", discovery: FakeBonjour())
        h.net.blackhole(host: "192.168.0.254", port: 10930)
        h.link.start()
        let accepted = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(accepted)
        await waitState(h) { $0 == .awaitingCallback }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.dash.acceptedCount.current, 1) // never a second probe after an acceptance
        h.link.stop()
    }

    func testStopThenStartRebindsAndOldSessionStaysSilent() async throws {
        let h = makeHarness()
        h.link.start()
        let first = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(first)
        h.link.stop()
        XCTAssertEqual(h.link.state, .stopped)
        let closed = await linkEventually { h.net.openListenerPorts.isEmpty }
        XCTAssertTrue(closed)
        let probesAfterStop = h.net.connectLog.count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.net.connectLog.count, probesAfterStop) // nothing leaks after stop

        h.link.start()
        let second = await linkEventually { h.dash.acceptedCount.current == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(h.net.openListenerPorts, [10920, 10921, 10922])
        let ctrl = try h.dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        await waitState(h) { $0 == .handshaking }
        // start() while running forces a clean restart.
        h.link.start()
        let third = await linkEventually { h.dash.acceptedCount.current == 3 }
        XCTAssertTrue(third)
        do {
            _ = try await ctrl.next(timeout: 1)
            XCTFail("old session socket should be closed")
        } catch {
            XCTAssertFalse(error is TimeoutError)
        }
        h.link.stop()
        await recorded(h, "two stops") { $0.states.filter { $0 == .stopped }.count == 2 }
    }

    func testForceTouchscreenAndDisableTouchscreenReachTheReply() async throws {
        let h = makeHarness(configure: { $0.forceNonTouch = true })
        h.link.start()
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        let ctrl = try h.dash.openControl()
        try await ctrl.send(cmd: 0x10010, json: #"{"HUID":"6WWV1","package_name":"com.cfmoto.easyconnect","version_name":"CFDL26.2.3.0.5","sdkVersion":"1.1.2","enableSockServerAuth":true,"supportScreenTouch":true,"supportLandscapeAdaptive":true,"supportFunction":128}"#)
        let reply = try await ctrl.next()
        XCTAssertFalse(reply.frame.payloadText.contains("supportScreenTouch")) // Landscape, but touch disabled
        XCTAssertEqual(h.link.currentProfile, .cfdl26Landscape)
        h.link.stop()
    }

    func testCorruptFramesCloseOnlyTheirConnection() async throws {
        let h = makeHarness()
        h.link.start()
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        let ctrl = try h.dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        let bad = try h.dash.openControl()
        try await bad.send(PxcFrame(cmd: 0x20000))
        _ = try await bad.nextRaw()
        // Bad magic (control-plane.md §2.3 NEGATIVE) → that socket is closed…
        try await bad.sendRaw(linkHex("00 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00"))
        do {
            _ = try await bad.next(timeout: 1)
            XCTFail("expected the corrupt connection to be closed")
        } catch {
            XCTAssertFalse(error is TimeoutError)
        }
        // …the other keeps working.
        try await ctrl.send(cmd: 0x10690, json: LinkDashSamples.querySpeed)
        let speed = try await ctrl.nextRaw()
        XCTAssertEqual(speed, linkHex("91 06 01 00 10 00 00 00 81 06 01 00 00 00 00 00"))
        // A > 1 MiB announced payload is rejected the same way, before anything is buffered.
        let huge = try h.dash.openControl()
        var w = ByteWriter()
        let total = UInt32(16 + PxcFrame.maxPayloadSize + 1)
        w.u32le(0x10010); w.u32le(total); w.u32le(0x10010 ^ total); w.u32le(0)
        try await huge.sendRaw(w.data)
        do {
            _ = try await huge.next(timeout: 1)
            XCTFail("expected the oversized connection to be closed")
        } catch {
            XCTAssertFalse(error is TimeoutError)
        }
        try await ctrl.send(PxcFrame(cmd: 0x7000_0000))
        let hb = try await ctrl.nextRaw()
        XCTAssertEqual(hb, linkHex("01 00 00 70 10 00 00 00 11 00 00 70 00 00 00 00"))
        XCTAssertEqual(h.link.state, .handshaking)
        h.link.stop()
    }

    func testDataStartWithoutConfigCapturePreparesTheLearnedCanvas() async throws {
        let qr = BikeQR(raw: "http://x?ssid=CFMOTO1565", ssid: "CFMOTO1565", password: "12345678", action: 1, modelId: "37426")
        var config = LinkConfiguration(qr: qr, phone: LinkTestKeys.examplePhone, localHost: "192.168.0.50")
        config.learnedCanvas = .rounded(requestedWidth: 1280, requestedHeight: 576)
        let h = makeHarness(qr: qr)
        let link = EasyConnLink(configuration: config, network: h.net, frameSource: h.source, signer: LinkTestKeys.fixtureSigner,
                                gateway: "192.168.0.1", options: {
                                    var o = LinkOptions()
                                    o.timings = Self.fastTimings
                                    o.interfaceProvider = { [] }
                                    return o
                                }())
        link.start()
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        let mctl = try h.dash.openMedia(port: 10921)
        try await mctl.send(cmd: 112)
        _ = try await mctl.reply()
        XCTAssertEqual(h.source.calls, [.prepare(VideoCanvas(width: 1280, height: 576), BikeProfile.cfdl26Landscape.encoderDefaults),
                                        .resynchronize])
        link.stop()
    }

    func testLogSubscriberMayStopTheLinkSynchronously() async {
        // Log subscribers run synchronously: the engine must never log while holding its locks.
        let h = makeHarness()
        let link = h.link
        let token = Log.shared.subscribe { line in
            if line.message.hasPrefix("[state] waiting for dash") { link.stop() }
        }
        defer { Log.shared.unsubscribe(token) }
        h.link.start()
        await waitState(h) { $0 == .stopped }
        let closed = await linkEventually { h.net.openListenerPorts.isEmpty }
        XCTAssertTrue(closed)
    }

    func testTouchesAreClampedToTheCanvas() async throws {
        let h = makeHarness()
        h.link.start()
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        let mctl = try h.dash.openMedia(port: 10921)
        try await mctl.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        _ = try await mctl.reply()
        // y = 385 is inside the 386-px device height but outside the 384-px canvas.
        try await mctl.send(cmd: 32, body: PxcTouchFrame(rawAction: 2, x: 805, y: 385).encodedBody())
        let got = await linkEventually { h.recorder.touches.count == 1 }
        XCTAssertTrue(got)
        XCTAssertEqual(h.recorder.touches.first.map { [$0.x, $0.y] }, [799, 383])
        h.link.stop()
    }

    // MARK: - SEC-3: only the probed dash may connect back

    /// A connection that is closed by the phone: the next read fails with something other than a
    /// timeout.
    private func assertClosedByPhone(_ stream: LinkMemoryStream, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await linkWithin(1, "closed") { try await stream.readSome(maxCount: 64) }
            XCTFail("expected the phone to close the connection", file: file, line: line)
        } catch {
            XCTAssertFalse(error is TimeoutError, "still open", file: file, line: line)
        }
    }

    func testForeignPeerIsRefusedAndTheListenersKeepAccepting() async throws {
        let h = makeHarness()
        h.link.start()
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        // Another device on the bike Wi-Fi tries every port: closed at once, no state change.
        for port: UInt16 in [10922, 10921, 10920] {
            let foreign = try h.net.dial(port: port, fromHost: "192.168.0.77")
            await assertClosedByPhone(foreign)
        }
        XCTAssertEqual(h.link.state, .awaitingCallback)
        XCTAssertEqual(h.source.calls, [])
        // The probed dash still gets through on the same listeners and streams.
        let ctrl = try h.dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        try await ctrl.send(cmd: 0x10010, json: LinkDashSamples.cfdl16ClientInfo)
        _ = try await ctrl.next()
        let mctl = try h.dash.openMedia(port: 10921)
        try await mctl.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        _ = try await mctl.reply()
        try await mctl.send(cmd: 112)
        _ = try await mctl.reply()
        let mdata = try h.dash.openMedia(port: 10920)
        try await mdata.send(cmd: 114)
        let first = try await mdata.frame()
        XCTAssertTrue(AnnexB.containsIDR(annexB: first.accessUnit))
        await waitState(h) { $0 == .streaming }
        // A foreign media socket during the session is refused too and the stream goes on.
        let late = try h.net.dial(port: 10920, fromHost: "10.0.0.9")
        await assertClosedByPhone(late)
        try await mdata.send(cmd: 114)
        _ = try await mdata.frame()
        h.link.stop()
    }

    func testMediaPeerWithoutAControlHandshakeIsServedNoFrames() async throws {
        let h = makeHarness()
        h.link.start()
        let probed = await linkEventually { h.dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        // Media straight away from the dash address, no :10922 handshake: negotiation is answered
        // (order-agnostic) but no picture is served.
        let mctl = try h.dash.openMedia(port: 10921)
        try await mctl.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        _ = try await mctl.reply()
        try await mctl.send(cmd: 112)
        _ = try await mctl.reply()
        let mdata = try h.dash.openMedia(port: 10920)
        try await mdata.send(cmd: 114)
        await mdata.expectSilence(for: 0.6)
        XCTAssertEqual(h.link.stats.framesSent, 0)
        XCTAssertFalse(h.source.calls.contains(.nextFrame), "the frame source is not even asked")
        // Once that host spoke the control handshake, its pulls are served.
        let ctrl = try h.dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        try await mdata.send(cmd: 114)
        let f = try await mdata.frame()
        XCTAssertTrue(AnnexB.containsIDR(annexB: f.accessUnit))
        h.link.stop()
    }

    /// The CI e2e harness: phone and fake dash both on loopback (the phone presented as 127.0.0.2,
    /// the fake dash at 127.0.0.1 as the gateway, calling back from 127.0.0.1).
    func testLoopbackFakeDashIsAccepted() async throws {
        let net = LinkMemoryNetwork(phoneHost: "127.0.0.1")
        let dash = LinkFakeDash(network: net, host: "127.0.0.1")
        dash.installProbeServer()
        let source = LinkFakeFrameSource()
        let config = LinkConfiguration(phone: LinkTestKeys.examplePhone, localHost: "127.0.0.2", connectBackTimeout: 2,
                                       framePullTimeout: 0.3)
        var options = LinkOptions()
        options.timings = Self.fastTimings
        options.interfaceProvider = { [InterfaceAddress(name: "lo0", ipv4: "127.0.0.2", netmask: "255.0.0.0")] }
        let link = EasyConnLink(configuration: config, network: net, frameSource: source, signer: LinkTestKeys.fixtureSigner,
                                gateway: "127.0.0.1", options: options)
        link.start()
        let probed = await linkEventually { dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        XCTAssertEqual(net.connectLog.first, "127.0.0.1:10930")
        let ctrl = try dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        let mdata = try dash.openMedia(port: 10920)
        try await mdata.send(cmd: 112)
        _ = try await mdata.reply()
        try await mdata.send(cmd: 114)
        let f = try await mdata.frame()
        XCTAssertTrue(AnnexB.containsIDR(annexB: f.accessUnit))
        link.stop()
    }

    func testPeerHostNormalization() {
        XCTAssertEqual(LinkPeerHost.normalize("192.168.0.1"), "192.168.0.1")
        XCTAssertEqual(LinkPeerHost.normalize("::ffff:192.168.0.1"), "192.168.0.1")
        XCTAssertEqual(LinkPeerHost.normalize("::FFFF:192.168.49.1"), "192.168.49.1")
        XCTAssertEqual(LinkPeerHost.normalize("[fe80::1%en0]"), "fe80::1")
        XCTAssertEqual(LinkPeerHost.normalize("FE80::1%25en0"), "fe80::1")
        XCTAssertEqual(LinkPeerHost.normalize(" 127.0.0.1 "), "127.0.0.1")
        XCTAssertNil(LinkPeerHost.normalize(nil))
        XCTAssertNil(LinkPeerHost.normalize(""))
        XCTAssertNil(LinkPeerHost.normalize("%en0"))
    }
}
