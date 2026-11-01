// SPDX-License-Identifier: AGPL-3.0-or-later
// ControlChannelHandler / MediaChannelHandler: frame in → exact frames out + events.
// Vectors: control-plane.md §2.3, §8.4, §10, §11, §13; media-video.md §4, §14.2.
import XCTest
@testable import OpenCfMotoCore

final class LinkControlHandlerTests: XCTestCase {
    private let now: Int64 = 1_786_272_219_244

    private func context(initial: BikeProfile = .legacy, override: BikeProfileID? = nil, forceTouch: Bool = false,
                         forceNonTouch: Bool = false, forcePhone: Bool = false) -> LinkSessionContext {
        LinkSessionContext(phone: LinkTestKeys.examplePhone, signer: LinkTestKeys.fixtureSigner, initialProfile: initial,
                           profileOverride: override, forceTouch: forceTouch, forceNonTouch: forceNonTouch,
                           timeSyncForcePhone: forcePhone, wallClockMillis: { [now] in now },
                           timeZone: { TimeZone(identifier: "Europe/Rome")! })
    }

    private func bytes(_ r: ControlChannelResponse) -> [Data] { r.replies.map { $0.encoded() } }

    func testChannelSelectsAckAndStartOneHeartbeatPerConnection() {
        let h = ControlChannelHandler(context: context())
        let r1 = h.handle(PxcFrame(cmd: 0x10000))
        XCTAssertEqual(bytes(r1), [linkHex("01 00 01 00 10 00 00 00 11 00 01 00 00 00 00 00")])
        XCTAssertEqual(r1.events, [.channelSelected(.carCtrl, startHeartbeat: true)])
        XCTAssertEqual(h.channel, .carCtrl)
        // A duplicated select is acked again but does not start a second heartbeat (iOS dedupe).
        XCTAssertEqual(h.handle(PxcFrame(cmd: 0x10000)).events, [.channelSelected(.carCtrl, startHeartbeat: false)])
        XCTAssertEqual(h.handle(PxcFrame(cmd: 0x20000)).events, [.channelSelected(.carData, startHeartbeat: false)])
        let data = ControlChannelHandler(context: context())
        let r2 = data.handle(PxcFrame(cmd: 0x20000))
        XCTAssertEqual(bytes(r2), [linkHex("01 00 02 00 10 00 00 00 11 00 02 00 00 00 00 00")])
        XCTAssertEqual(r2.events, [.channelSelected(.carData, startHeartbeat: true)])
    }

    func testClientInfoCFDL16RepliesWithTheWorkedExample() throws {
        let ctx = context()
        let h = ControlChannelHandler(context: ctx)
        let r = h.handle(PxcFrame(cmd: PxcCmd.clientInfo, text: LinkDashSamples.cfdl16ClientInfo))
        XCTAssertEqual(r.replies.count, 1)
        XCTAssertEqual(r.replies[0].cmd, PxcCmd.clientInfoReply)
        XCTAssertEqual(r.replies[0].payloadText, ProtocolClientInfoTests.workedExampleJSON)
        XCTAssertEqual(r.replies[0].encoded().prefix(16), linkHex("11 00 01 00 30 03 00 00 21 03 01 00 00 00 00 00"))
        guard case let .dashIdentified(info, profile)? = r.events.first else { return XCTFail("no event") }
        XCTAssertEqual(profile, .legacy)
        XCTAssertEqual(info.huid, "6GUVA2C00100055")
        XCTAssertEqual(info.huName, "CFDL16-6GUV")
        XCTAssertEqual(info.channel, "37416")
        XCTAssertEqual(info.socketTimeoutSeconds, 9)
        XCTAssertEqual(ctx.carHuid, "6GUVA2C00100055")
        XCTAssertEqual(ctx.dashInfo, info)
    }

    func testClientInfo1000MTXPortraitAndForceTouch() {
        let ctx = context(initial: .cfdl26Portrait)
        let r = ControlChannelHandler(context: ctx).handle(PxcFrame(cmd: PxcCmd.clientInfo, text: LinkDashSamples.mtxClientInfo))
        let reply = r.replies[0].payloadText
        XCTAssertTrue(reply.contains("\"supportFunction\":128"))
        XCTAssertFalse(reply.contains("supportScreenTouch"))
        XCTAssertEqual(ctx.activeProfile, .cfdl26Portrait)
        let forced = ControlChannelHandler(context: context(forceTouch: true))
            .handle(PxcFrame(cmd: PxcCmd.clientInfo, text: LinkDashSamples.mtxClientInfo))
        XCTAssertTrue(forced.replies[0].payloadText.hasSuffix(",\"supportScreenTouch\":true}"))
        let disabled = ControlChannelHandler(context: context(override: .cfdl26Landscape, forceTouch: true, forceNonTouch: true))
            .handle(PxcFrame(cmd: PxcCmd.clientInfo, text: LinkDashSamples.mtxClientInfo))
        XCTAssertFalse(disabled.replies[0].payloadText.contains("supportScreenTouch"))
        guard case let .dashIdentified(_, p)? = disabled.events.first else { return XCTFail() }
        XCTAssertEqual(p, .cfdl26Landscape) // manual override
    }

    func testUnparsableClientInfoGetsNoReply() {
        let r = ControlChannelHandler(context: context()).handle(PxcFrame(cmd: PxcCmd.clientInfo, text: "{broken"))
        XCTAssertTrue(r.replies.isEmpty)
        XCTAssertEqual(r.events, [.clientInfoUnparsable("{broken")])
    }

    func testQuerySpeedCheckSnHeartbeats() {
        let h = ControlChannelHandler(context: context())
        XCTAssertEqual(bytes(h.handle(PxcFrame(cmd: 0x10690, text: LinkDashSamples.querySpeed))),
                       [linkHex("91 06 01 00 10 00 00 00 81 06 01 00 00 00 00 00")])
        let sn = h.handle(PxcFrame(cmd: 0x103E0, text: LinkDashSamples.checkSn))
        XCTAssertEqual(bytes(sn), CheckSn.replies(to: Data(LinkDashSamples.checkSn.utf8)).map { $0.encoded() })
        XCTAssertEqual(sn.events, [.checkSnCompleted(serial: "DSXXZMHNFV3DEXEBB3PZ2")])
        XCTAssertEqual(bytes(h.handle(PxcFrame(cmd: 0x7000_0000))), [linkHex("01 00 00 70 10 00 00 00 11 00 00 70 00 00 00 00")])
        XCTAssertEqual(h.handle(PxcFrame(cmd: 0x7000_0001)), ControlChannelResponse())
        XCTAssertEqual(h.handle(PxcFrame(cmd: 0x201C1)), ControlChannelResponse())
    }

    /// Review SEC-5: the CHECK_SN reply echoes the serial under "id" (no redaction rule matches it)
    /// and an HUID that is not purely alphanumeric escapes the bare-serial rule: both are logged
    /// masked, while the wire payload still carries the full serial.
    func testSerialsNeverReachTheRedactedLog() {
        LogRedactor.install(on: .shared, includeSecrets: false)
        let before = Log.shared.lines().last?.id ?? 0
        let h = ControlChannelHandler(context: context())
        let sn = h.handle(PxcFrame(cmd: 0x103E0, text: LinkDashSamples.checkSn))
        XCTAssertTrue(sn.replies.contains { String(decoding: $0.payload, as: UTF8.self).contains("\"id\":\"DSXXZMHNFV3DEXEBB3PZ2\"") })
        let info = LinkDashSamples.cfdl16ClientInfo.replacingOccurrences(of: "6GUVA2C00100055", with: "6GUV-A2C00100055")
        _ = ControlChannelHandler(context: context()).handle(PxcFrame(cmd: PxcCmd.clientInfo, text: info))
        let logged = Log.shared.lines().filter { $0.id > before && $0.tag == "LINK" }
            .map { $0.formatted(redactor: Log.shared.redactor) }.joined(separator: "\n")
        XCTAssertTrue(logged.contains("CHECK_SN_RESULT"), logged)
        XCTAssertTrue(logged.contains("\"id\":\"DSXX\u{2026}********\""), logged)
        XCTAssertFalse(logged.contains("DSXXZMHNFV3DEXEBB3PZ2"), logged)
        XCTAssertFalse(logged.contains("A2C00100055"), logged)
    }

    func testClockFrames() {
        let h = ControlChannelHandler(context: context())
        let req = PxcFrame(cmd: 0x10600, payload: LinkDashSamples.timeSyncRequest())
        let r = h.handle(req)
        XCTAssertEqual(bytes(r), [linkHex("""
            01 06 01 00 3d 00 00 00 3c 06 01 00 00 00 00 00
            fe ff ff ff 32 92 00 00 07 00 00 00 00 00 00 00
            32 30 32 36 2d 30 37 2d 32 34 20 31 37 3a 30 39
            3a 32 30 2e 31 39 30 30 30 30 30 30 30
            """)])
        XCTAssertEqual(r.events, [.timeSync(.echo)])
        let phone = ControlChannelHandler(context: context(forcePhone: true)).handle(req)
        XCTAssertEqual(phone.replies[0].payload, ClockTimeSyncTests.forcePhonePayload)
        XCTAssertEqual(bytes(h.handle(PxcFrame(cmd: 0x10450))), [linkHex("51 04 01 00 10 00 00 00 41 04 01 00 00 00 00 00")])
    }

    func testEveryOtherFrameIsAckedCmdPlusOneEmpty() {
        let h = ControlChannelHandler(context: context())
        let burst: [(UInt32, String)] = [
            (0x10780, "{\"log\":\"mdns success\"}"), (0x103A0, "{\"port\":11021,\"userName\":\"carbit_ec_ftp_ota\",\"pwd\":\"x\"}"),
            (0x10020, "{\"music\":1,\"talkie\":0,\"tts\":1,\"vr\":0,\"autoChangeToBT\":0}"),
            (0x10040, "{\"maxNaviIcon\":161,\"supportFunction\":0}"), (0x10750, ""), (0x10430, ""),
            (0x10460, "{\"bluetooth\":4129}"), (0x10470, "{\"cnt\":9}"), (0x104A0, "{\"ctrlPort\":11026}"),
            (0x30040, "{}"), (0x30000, ""), (0x40000, ""), (0x10751, ""), (0x0108_0000, ""), (0x6003_0050, "x"),
        ]
        for (cmd, body) in burst {
            let r = h.handle(PxcFrame(cmd: cmd, text: body))
            XCTAssertEqual(r.replies, [PxcFrame(cmd: cmd + 1)], PxcCmd.hex(cmd))
            XCTAssertEqual(r.events, [.acked(request: cmd)])
        }
        XCTAssertEqual(h.handle(PxcFrame(cmd: 0x103A0)).replies[0].encoded(), linkHex("a1 03 01 00 10 00 00 00 b1 03 01 00 00 00 00 00"))
        XCTAssertEqual(h.handle(PxcFrame(cmd: 0x10780)).replies[0].encoded(), linkHex("81 07 01 00 10 00 00 00 91 07 01 00 00 00 00 00"))
        // Universal before CLIENT_INFO too (initial Legacy profile).
        XCTAssertNil(h.channel)
    }
}

final class LinkMediaHandlerTests: XCTestCase {
    private final class Writes: @unchecked Sendable {
        let data = Locked<[Data]>([])
        var all: [Data] { data.current }
    }

    private func makeHandler(source: LinkFakeFrameSource, ctx: LinkSessionContext? = nil, timeout: TimeInterval = 0.2,
                             resyncOn128: Bool = true, touches: Locked<[PxcTouchFrame]> = Locked([]),
                             params: (@Sendable (BikeProfile, VideoCanvas) -> EncoderParameters)? = nil,
                             stats: LinkStatsTracker = LinkStatsTracker()) -> MediaChannelHandler {
        MediaChannelHandler(context: ctx ?? LinkSessionContext(phone: LinkTestKeys.examplePhone, signer: LinkTestKeys.fixtureSigner),
                            frameSource: source, stats: stats, framePullTimeout: timeout, tag: ":10921",
                            resynchronizeOnStartH264: resyncOn128, encoderParameters: params) { t in touches.withLock { $0.append(t) } }
    }

    private func send(_ h: MediaChannelHandler, _ cmd: Int16, body: Data = Data(), token: Int32 = 0x55AA_55AA,
                      into w: Writes) async throws -> [MediaChannelEvent] {
        try await h.handle(MediaMessage(cmdType: cmd, token: token, body: body)) { d in w.data.withLock { $0.append(d) } }
    }

    func testConfigCapturePreparesAndRepliesRoundedCanvasWithTokenZero() async throws {
        let src = LinkFakeFrameSource()
        let ctx = LinkSessionContext(phone: LinkTestKeys.examplePhone, signer: LinkTestKeys.fixtureSigner, initialProfile: .cfdl26Portrait)
        let h = makeHandler(source: src, ctx: ctx)
        let w = Writes()
        let ev = try await send(h, 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 951, huid: "x"), into: w)
        XCTAssertEqual(w.all, [linkHex("11 00 09 00 00 00 00 00 02 00 00 00 20 03 b0 03 00")])
        let canvas = VideoCanvas(width: 800, height: 944, requestedWidth: 800, requestedHeight: 951, requestedFps: 30)
        XCTAssertEqual(ev, [.canvasNegotiated(canvas)])
        XCTAssertEqual(src.calls, [.prepare(canvas, BikeProfile.cfdl26Portrait.encoderDefaults)])
        XCTAssertEqual(ctx.canvas, canvas)
        XCTAssertTrue(ctx.canvasNegotiated)
    }

    func testConfigCaptureWithoutUsableSizeKeepsPreviousCanvas() async throws {
        let src = LinkFakeFrameSource()
        let h = makeHandler(source: src)
        let w = Writes()
        let ev = try await send(h, 16, body: linkHex("20 03"), into: w) // width only
        XCTAssertEqual(w.all, [linkHex("11 00 09 00 00 00 00 00 02 00 00 00 20 03 80 01 00")]) // default 800×384
        XCTAssertEqual(ev, [.canvasRejected(requestedWidth: 800, requestedHeight: 0, kept: .defaultLandscape)])
    }

    func testEncoderParametersHook() async throws {
        let src = LinkFakeFrameSource()
        let custom = EncoderParameters(bitrate: 1_750_000, frameRate: 24)
        let h = makeHandler(source: src, params: { _, _ in custom })
        _ = try await send(h, 16, body: LinkDashSamples.configCaptureBody(width: 1280, height: 576), into: Writes())
        XCTAssertEqual(src.calls, [.prepare(VideoCanvas(width: 1280, height: 576, requestedFps: 30), custom)])
    }

    func testFixedReplies() async throws {
        let h = makeHandler(source: LinkFakeFrameSource())
        let w = Writes()
        _ = try await send(h, 48, into: w)
        _ = try await send(h, 64, into: w)
        _ = try await send(h, 96, body: Data("{\"a\":1}".utf8), into: w)
        XCTAssertEqual(w.all, [
            linkHex("31 00 08 00 00 00 00 00 03 00 00 00 01 00 00 00"),
            linkHex("41 00 00 00 00 00 00 00"),
            linkHex("61 00 0b 00 00 00 00 00 7b 22 73 74 61 74 65 22 3a 30 7d"),
        ])
    }

    func testDataStartResynchronizesBeforeReplying113() async throws {
        let src = LinkFakeFrameSource()
        let h = makeHandler(source: src)
        let resyncBeforeWrite = Locked(false)
        let ev = try await h.handle(MediaMessage(cmdType: 112, token: 9)) { data in
            XCTAssertEqual(data, linkHex("71 00 00 00 00 00 00 00"))
            resyncBeforeWrite.set(src.calls.last == .resynchronize)
        }
        XCTAssertTrue(resyncBeforeWrite.current)
        XCTAssertEqual(ev, [.mediaStarted])
        // No REQ 16 first: prepared at the default 800×384 canvas (Android creates the encoder at 112).
        XCTAssertEqual(src.calls, [.prepare(.defaultLandscape, BikeProfile.legacy.encoderDefaults), .resynchronize])
        // A second 112 does not prepare again.
        _ = try await send(h, 112, into: Writes())
        XCTAssertEqual(src.calls.suffix(1), [.resynchronize])
        XCTAssertEqual(src.calls.count, 3)
    }

    func testDataNextSendsExactlyOneRawFramePerPull() async throws {
        let src = LinkFakeFrameSource()
        let stats = LinkStatsTracker()
        let h = makeHandler(source: src, stats: stats)
        _ = try await send(h, 112, into: Writes())
        let w = Writes()
        let e1 = try await send(h, 114, into: w)
        let e2 = try await send(h, 114, into: w)
        XCTAssertEqual(w.all.count, 2)
        let key = LinkFakeFrameSource.frame(seq: 1, key: true)
        XCTAssertEqual(w.all[0], key.wireBytes)
        XCTAssertEqual(w.all[0].prefix(4), Data([UInt8(key.accessUnit.count), 0, 0, 0]))
        XCTAssertEqual(w.all[0].dropFirst(4).prefix(5), linkHex("00 00 00 01 67")) // SPS first
        XCTAssertEqual(w.all[1], LinkFakeFrameSource.frame(seq: 2, key: false).wireBytes)
        XCTAssertEqual(e1, [.frameSent(number: 1, bytes: key.wireBytes.count, keyframe: true)])
        XCTAssertEqual(e2, [.frameSent(number: 2, bytes: w.all[1].count, keyframe: false)])
        let s = stats.snapshot()
        XCTAssertEqual(s.framesSent, 2)
        XCTAssertEqual(s.keyframesSent, 1)
        XCTAssertEqual(s.bytesSent, w.all[0].count + w.all[1].count)
        XCTAssertNotNil(s.lastFrameAt)
        XCTAssertGreaterThan(s.pullRate, 0)
    }

    func testMissedPullSendsNothing() async throws {
        let src = LinkFakeFrameSource()
        src.starve = true
        let stats = LinkStatsTracker()
        let h = makeHandler(source: src, timeout: 0.05, stats: stats)
        let w = Writes()
        let ev = try await send(h, 114, into: w)
        XCTAssertEqual(ev, [.pullMissed])
        XCTAssertTrue(w.all.isEmpty)
        XCTAssertEqual(stats.snapshot().missedPulls, 1)
        XCTAssertEqual(stats.snapshot().framesSent, 0)
    }

    func testEmptyAccessUnitIsNeverSent() async throws {
        final class EmptySource: VideoFrameSource, @unchecked Sendable {
            func prepare(canvas: VideoCanvas, parameters: EncoderParameters) {}
            func resynchronize() {}
            func nextFrame(timeout: TimeInterval) async -> EncodedFrame? { EncodedFrame(accessUnit: Data(), isKeyframe: false) }
            func mediaStopped() {}
        }
        let h = MediaChannelHandler(context: LinkSessionContext(phone: PhoneIdentity(), signer: LinkTestKeys.fixtureSigner),
                                    frameSource: EmptySource(), stats: LinkStatsTracker(), framePullTimeout: 0.1, tag: ":10920") { _ in }
        let w = Writes()
        let ev = try await send(h, 114, into: w)
        XCTAssertEqual(ev, [.pullMissed])
        XCTAssertTrue(w.all.isEmpty)
    }

    func testStartH264RepliesAndOptionallyResynchronizes() async throws {
        let src = LinkFakeFrameSource()
        let w = Writes()
        let ev = try await send(makeHandler(source: src), 128, into: w)
        XCTAssertEqual(w.all, [linkHex("81 00 00 00 00 00 00 00")])
        XCTAssertEqual(ev, [.mediaStarted])
        XCTAssertEqual(src.calls.last, .resynchronize)
        let plain = LinkFakeFrameSource()
        let ev2 = try await send(makeHandler(source: plain, resyncOn128: false), 128, into: Writes())
        XCTAssertEqual(ev2, [])
        XCTAssertEqual(plain.calls, [])
    }

    func testTouchIsDecodedForwardedAndNeverAnswered() async throws {
        let touches = Locked<[PxcTouchFrame]>([])
        let h = makeHandler(source: LinkFakeFrameSource(), touches: touches)
        let w = Writes()
        let body = linkHex("02 00 80 02 20 01 00 00 40 E2 01 00 00 00 00 00 00 00")
        let ev = try await send(h, 32, body: body, into: w)
        XCTAssertTrue(w.all.isEmpty)
        let t = PxcTouchFrame(rawAction: 2, x: 640, y: 288, pointerId: 0, timestamp: 123_456)
        XCTAssertEqual(ev, [.touch(t)])
        XCTAssertEqual(touches.current, [t])
        let short = try await send(h, 32, body: linkHex("02 00 80"), into: w)
        XCTAssertEqual(short, [.touchTooShort(3)])
        XCTAssertEqual(touches.current.count, 1)
        XCTAssertTrue(w.all.isEmpty)
    }

    func testUnknownCommandIsLoggedNotAnswered() async throws {
        let w = Writes()
        let ev = try await send(makeHandler(source: LinkFakeFrameSource()), 77, body: Data([1, 2, 3]), into: w)
        XCTAssertEqual(ev, [.unknown(77)])
        XCTAssertTrue(w.all.isEmpty)
    }

    func testWriteFailurePropagates() async {
        let h = makeHandler(source: LinkFakeFrameSource())
        do {
            _ = try await h.handle(MediaMessage(cmdType: 64)) { _ in throw TransportError.closed }
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? TransportError, .closed)
        }
    }
}
