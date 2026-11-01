// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class VideoMirrorRelayTests: XCTestCase {
    // MARK: send gate

    func testSendGateDropsUntilKeyframeAfterOverflow() {
        var g = RelaySendGate(maxPending: 2)
        XCTAssertEqual(g.offer(isKeyframe: false), .send, "a fresh gate does not wait")
        g.reset()
        XCTAssertEqual(g.offer(isKeyframe: false), .drop(requestKeyframe: false), "new connection starts with an IDR")
        XCTAssertEqual(g.offer(isKeyframe: true), .send)
        XCTAssertEqual(g.offer(isKeyframe: false), .send)
        XCTAssertEqual(g.pending, 2)
        XCTAssertEqual(g.offer(isKeyframe: false), .drop(requestKeyframe: true), "full: drop and ask for an IDR once")
        XCTAssertEqual(g.offer(isKeyframe: false), .drop(requestKeyframe: false))
        g.sent(); g.sent()
        XCTAssertEqual(g.offer(isKeyframe: false), .drop(requestKeyframe: false), "chain broken until the IDR")
        XCTAssertEqual(g.offer(isKeyframe: true), .send)
        XCTAssertEqual(g.offer(isKeyframe: false), .send)
        XCTAssertEqual(g.dropped, 4)
    }

    func testSendGateGivesKeyframesHeadroom() {
        var g = RelaySendGate(maxPending: 2)
        XCTAssertEqual(g.offer(isKeyframe: true), .send)
        XCTAssertEqual(g.offer(isKeyframe: false), .send)
        XCTAssertEqual(g.offer(isKeyframe: true), .send) // 2 pending < 4
        XCTAssertEqual(g.offer(isKeyframe: true), .send)
        XCTAssertEqual(g.offer(isKeyframe: true), .drop(requestKeyframe: true))
        XCTAssertEqual(g.pending, 4)
        g.sent()
        XCTAssertEqual(g.pending, 3)
        for _ in 0 ..< 10 { g.sent() }
        XCTAssertEqual(g.pending, 0)
    }

    // MARK: socket path

    func testSocketPathLimit() {
        let shortDir = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/0D5C5E7E-5F21-4C1F-9B53-0B3E2B9C1A77")
        let p = MirrorRelaySocket.path(inDirectory: shortDir)
        XCTAssertEqual(p, shortDir.path + "/ocm.sock")
        XCTAssertLessThanOrEqual(p!.utf8.count, 100)
        // "/" + 90 × "x" + "/ocm.sock" = 100 bytes: the longest accepted path.
        let limitDir = URL(fileURLWithPath: "/" + String(repeating: "x", count: 90))
        XCTAssertEqual(MirrorRelaySocket.path(inDirectory: limitDir)?.utf8.count, 100)
        let longDir = URL(fileURLWithPath: "/" + String(repeating: "x", count: 91))
        XCTAssertNil(MirrorRelaySocket.path(inDirectory: longDir))
        XCTAssertFalse(MirrorRelaySocket.isUsable(path: ""))
    }

    // MARK: end-to-end over a real Unix socket

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func socketPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try XCTUnwrap(MirrorRelaySocket.path(inDirectory: dir, fileName: "r.sock"))
    }

    private func socketFileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Longer than the accept loop's 250 ms poll: a stopped server's accept thread has woken up.
    private func letStoppedAcceptThreadsExit() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    private func key(_ seq: UInt64) -> EncodedFrame {
        EncodedFrame(accessUnit: Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, UInt8(seq & 0xFF)]),
                     isKeyframe: true, presentationTime: Double(seq) / 8, sequence: seq)
    }

    private func pFrame(_ seq: UInt64) -> EncodedFrame {
        EncodedFrame(accessUnit: Data([0, 0, 0, 1, 0x41, UInt8(seq & 0xFF)]), isKeyframe: false,
                     presentationTime: Double(seq) / 8, sequence: seq)
    }

    func testRelayEndToEnd() async throws {
        let path = try socketPath()
        let server = MirrorRelayServer(socketPath: path)
        try server.start()
        let configs = Locked<[MirrorRelayConfig]>([])
        let keyRequests = Locked(0)
        let stops = Locked<[String]>([])
        let client = MirrorRelayClient(socketPath: path, agent: "test-extension")
        client.retryInterval = 0.05
        client.onConfig = { cfg in configs.withLock { $0.append(cfg) } }
        client.onKeyframeRequest = { keyRequests.withLock { $0 += 1 } }
        client.onStop = { reason in stops.withLock { $0.append(reason) } }
        client.start()

        // The host re-closes its gate and asks for an IDR on every new connection.
        var ok = await waitUntil { client.isConnected && server.stats.keyframeRequestsSent >= 1 }
        XCTAssertTrue(ok, "connected")
        ok = await waitUntil { server.stats.peerAgent == "test-extension" }
        XCTAssertTrue(ok, "hello received")

        let canvas = VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386)
        server.setFit(.fit, margins: ScreenMargins(customised: true, top: 22))
        server.prepare(canvas: canvas, parameters: .default)
        ok = await waitUntil { configs.current.last?.canvas == canvas }
        XCTAssertTrue(ok, "config delivered")
        XCTAssertEqual(configs.current.last?.fit, .fit)
        XCTAssertEqual(configs.current.last?.margins.top, 22)

        client.send(frame: key(1))
        client.send(frame: pFrame(2))
        let f1 = await server.nextFrame(timeout: 3)
        let f2 = await server.nextFrame(timeout: 3)
        XCTAssertEqual(f1?.sequence, 1)
        XCTAssertEqual(f1?.isKeyframe, true)
        XCTAssertEqual(f1?.accessUnit, key(1).accessUnit)
        XCTAssertEqual(f2?.sequence, 2)
        XCTAssertEqual(f2?.isKeyframe, false)

        // REQ 112: gate + flush on the host, keyframe request to the extension.
        let before = keyRequests.current
        server.resynchronize()
        ok = await waitUntil { keyRequests.current > before }
        XCTAssertTrue(ok, "keyframe request delivered")
        client.send(frame: pFrame(3)) // gated on the host
        client.send(frame: key(4))
        let f4 = await server.nextFrame(timeout: 3)
        XCTAssertEqual(f4?.sequence, 4)

        // Nothing arrives: the host answers with the cached IDR instead of leaving the pull open.
        let fallback = await server.nextFrame(timeout: 0.4)
        XCTAssertEqual(fallback?.sequence, 4)
        XCTAssertEqual(fallback?.isKeyframe, true)
        XCTAssertEqual(server.stats.fallbackKeyframesServed, 1)

        // Extension log lines land in the host log.
        client.send(log: .warn, tag: "VT", message: "hello from the extension")
        ok = await waitUntil { Log.shared.lines().contains { $0.tag == "EXT/VT" && $0.message == "hello from the extension" } }
        XCTAssertTrue(ok, "log forwarded")

        XCTAssertGreaterThanOrEqual(server.stats.framesReceived, 4)
        XCTAssertGreaterThanOrEqual(client.stats.framesSent, 4)

        // Host stop → STOP message + disconnect; pending pulls return nil.
        server.stop()
        ok = await waitUntil { stops.current.contains("host stopped") && !client.isConnected }
        XCTAssertTrue(ok, "stop delivered")
        let none = await server.nextFrame(timeout: 0.3)
        XCTAssertNil(none)
        client.stop()
    }

    func testClientReconnectsWhenTheHostRestarts() async throws {
        // Generous timeouts: CI machines under load can stall threads for seconds; every wait
        // returns as soon as its condition holds.
        let path = try socketPath()
        let client = MirrorRelayClient(socketPath: path)
        client.retryInterval = 0.05
        defer { client.stop() }
        client.start() // host not listening yet: keeps retrying
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(client.isConnected)

        let first = MirrorRelayServer(socketPath: path)
        try first.start()
        var ok = await waitUntil(15) { client.isConnected && first.isClientConnected }
        XCTAssertTrue(ok, "first connection")
        first.stop()
        XCTAssertFalse(socketFileExists(path), "stop() removes its socket file at once")
        ok = await waitUntil(15) { !client.isConnected }
        XCTAssertTrue(ok, "disconnected")

        // The restarted host binds the same path while the first one's accept thread may still be
        // waking up (≤ 250 ms): that thread must not delete the new socket file (it used to, and
        // the extension then could never reconnect).
        let second = MirrorRelayServer(socketPath: path)
        defer { second.stop() }
        try second.start()
        await letStoppedAcceptThreadsExit()
        XCTAssertTrue(socketFileExists(path), "the stopped host deleted the new host's socket")
        ok = await waitUntil(15) { client.isConnected && second.isClientConnected }
        XCTAssertTrue(ok, "reconnected")
        XCTAssertGreaterThanOrEqual(client.stats.connects, 2)

        client.send(frame: key(9))
        let f = await second.nextFrame(timeout: 10)
        XCTAssertEqual(f?.sequence, 9)
    }

    func testStopRemovesOnlyItsOwnSocketFile() async throws {
        let path = try socketPath()
        let first = MirrorRelayServer(socketPath: path)
        try first.start()
        XCTAssertTrue(socketFileExists(path))
        first.stop()
        XCTAssertFalse(socketFileExists(path), "removed synchronously by stop()")
        first.stop() // idempotent
        XCTAssertFalse(socketFileExists(path))

        // Another server takes the path over while this one is still running (it replaces the
        // file): stopping the older one must leave the newer socket in place — now and when its
        // accept thread exits.
        let older = MirrorRelayServer(socketPath: path)
        try older.start()
        let newer = MirrorRelayServer(socketPath: path)
        defer { newer.stop() }
        try newer.start()
        older.stop()
        XCTAssertTrue(socketFileExists(path), "stop() removed a socket file it no longer owns")
        await letStoppedAcceptThreadsExit()
        XCTAssertTrue(socketFileExists(path), "the accept thread removed a socket file it no longer owns")

        // The extension reaches the live server through that path.
        let client = MirrorRelayClient(socketPath: path)
        client.retryInterval = 0.05
        defer { client.stop() }
        client.start()
        let ok = await waitUntil(15) { client.isConnected && newer.isClientConnected }
        XCTAssertTrue(ok, "connected to the newer server")
        XCTAssertFalse(older.isClientConnected)

        // A server restarted on the same instance owns the path again; its old accept thread
        // (previous generation) leaves the new file alone.
        newer.stop()
        XCTAssertFalse(socketFileExists(path))
        try newer.start()
        XCTAssertTrue(socketFileExists(path))
        await letStoppedAcceptThreadsExit()
        XCTAssertTrue(socketFileExists(path), "the previous generation's accept thread removed the new file")
        newer.stop()
        XCTAssertFalse(socketFileExists(path))
    }

    func testSecondExtensionConnectionReplacesTheFirst() async throws {
        let path = try socketPath()
        let server = MirrorRelayServer(socketPath: path)
        try server.start()
        let a = MirrorRelayClient(socketPath: path, agent: "A")
        a.retryInterval = 0.05
        a.start()
        var ok = await waitUntil { a.isConnected && server.stats.peerAgent == "A" }
        XCTAssertTrue(ok)
        a.stop() // A finishes its broadcast
        let b = MirrorRelayClient(socketPath: path, agent: "B")
        b.retryInterval = 0.05
        b.start()
        ok = await waitUntil { b.isConnected && server.stats.peerAgent == "B" }
        XCTAssertTrue(ok)
        b.send(frame: key(5))
        let f = await server.nextFrame(timeout: 3)
        XCTAssertEqual(f?.sequence, 5)
        XCTAssertGreaterThanOrEqual(server.stats.connections, 2)
        b.stop()
        server.stop()
    }

    // MARK: canvas hygiene (MP-3)

    /// Baseline L3.1 SPS NAL units (Exp-Golomb built, no cropping) for a few dash canvases.
    private static let sps800x384 = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x03, 0x20, 0xC6, 0x40])
    private static let sps800x944 = Data([0x67, 0x42, 0xC0, 0x1F, 0xDA, 0x03, 0x20, 0x77, 0x90])

    private func idr(_ sps: Data, seq: UInt64) -> EncodedFrame {
        EncodedFrame(accessUnit: AnnexB.join([sps, Data([0x68, 0xCE, 0x3C, 0x80]), Data([0x65, 0x88, 0x80, UInt8(seq & 0xFF)])]),
                     isKeyframe: true, presentationTime: Double(seq) / 8, sequence: seq)
    }

    func testSPSVectorsDecodeToTheirCanvas() {
        XCTAssertEqual(H264SPS.parse(nal: Self.sps800x384).map { [$0.width, $0.height] }, [800, 384])
        XCTAssertEqual(H264SPS.parse(nal: Self.sps800x944).map { [$0.width, $0.height] }, [800, 944])
    }

    func testCanvasVerdict() {
        let tall = VideoCanvas(width: 800, height: 944)
        let wide = idr(Self.sps800x384, seq: 1), right = idr(Self.sps800x944, seq: 2), p = pFrame(3)
        var v = MirrorRelayServer.canvasVerdict(for: wide, canvas: tall, awaitingKeyframe: false)
        XCTAssertFalse(v.accept)
        XCTAssertTrue(v.awaitingKeyframe)
        XCTAssertEqual(v.wrongSize.map { [$0.width, $0.height] }, [800, 384], "ask for a new IDR once")
        v = MirrorRelayServer.canvasVerdict(for: p, canvas: tall, awaitingKeyframe: true)
        XCTAssertFalse(v.accept, "P-frames of a dropped IDR are dropped too")
        v = MirrorRelayServer.canvasVerdict(for: wide, canvas: tall, awaitingKeyframe: true)
        XCTAssertFalse(v.accept)
        XCTAssertNil(v.wrongSize, "no second request in the same episode")
        v = MirrorRelayServer.canvasVerdict(for: right, canvas: tall, awaitingKeyframe: true)
        XCTAssertTrue(v.accept)
        XCTAssertFalse(v.awaitingKeyframe)
        XCTAssertTrue(MirrorRelayServer.canvasVerdict(for: p, canvas: tall, awaitingKeyframe: false).accept)
        XCTAssertTrue(MirrorRelayServer.canvasVerdict(for: wide, canvas: nil, awaitingKeyframe: false).accept, "before any 16")
        XCTAssertTrue(MirrorRelayServer.canvasVerdict(for: key(4), canvas: tall, awaitingKeyframe: false).accept,
                      "an unparseable SPS is not judged")
    }

    /// The extension encoded its 800×384 default before CONFIG (or the previous canvas is still in
    /// flight): that IDR and its P-frames never reach an 800×944 dash; a matching IDR does.
    func testWrongCanvasIDRsAreDroppedUntilAMatchingOne() async throws {
        let path = try socketPath()
        let server = MirrorRelayServer(socketPath: path)
        try server.start()
        defer { server.stop() }
        let configs = Locked<[MirrorRelayConfig]>([])
        let keyRequests = Locked(0)
        let client = MirrorRelayClient(socketPath: path)
        client.retryInterval = 0.05
        client.onConfig = { cfg in configs.withLock { $0.append(cfg) } }
        client.onKeyframeRequest = { keyRequests.withLock { $0 += 1 } }
        defer { client.stop() }
        client.start()
        var ok = await waitUntil { client.isConnected && server.isClientConnected }
        XCTAssertTrue(ok)
        let tall = VideoCanvas(width: 800, height: 944, requestedWidth: 800, requestedHeight: 951)
        server.prepare(canvas: tall, parameters: .default)
        ok = await waitUntil { configs.current.last?.canvas == tall }
        XCTAssertTrue(ok)
        let before = keyRequests.current
        client.send(frame: idr(Self.sps800x384, seq: 1))
        client.send(frame: pFrame(2))
        ok = await waitUntil { server.stats.framesReceived >= 2 }
        XCTAssertTrue(ok)
        XCTAssertEqual(server.stats.wrongCanvasFramesDropped, 2)
        ok = await waitUntil { keyRequests.current > before }
        XCTAssertTrue(ok, "the host asked for an IDR at the negotiated canvas")
        let nothing = await server.nextFrame(timeout: 0.4)
        XCTAssertNil(nothing, "never the wrong-size IDR, not even as the fallback")
        client.send(frame: idr(Self.sps800x944, seq: 3))
        client.send(frame: pFrame(4))
        let f3 = await server.nextFrame(timeout: 3)
        let f4 = await server.nextFrame(timeout: 3)
        XCTAssertEqual(f3?.sequence, 3)
        XCTAssertEqual(f4?.sequence, 4)
    }

    /// A stop / start or a canvas change never serves the previous IDR as the 114 fallback.
    func testStaleKeyframeIsNotServedAcrossSessionsOrCanvases() async throws {
        let path = try socketPath()
        let server = MirrorRelayServer(socketPath: path)
        try server.start()
        defer { server.stop() }
        let client = MirrorRelayClient(socketPath: path)
        client.retryInterval = 0.05
        defer { client.stop() }
        client.start()
        var ok = await waitUntil { client.isConnected && server.isClientConnected }
        XCTAssertTrue(ok)
        let wide = VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386)
        server.prepare(canvas: wide, parameters: .default)
        client.send(frame: idr(Self.sps800x384, seq: 1))
        let first = await server.nextFrame(timeout: 3)
        XCTAssertEqual(first?.sequence, 1)
        let fallback = await server.nextFrame(timeout: 0.4)
        XCTAssertEqual(fallback?.sequence, 1, "same session and canvas: the cached IDR keeps the dash alive")

        // New canvas (another bike): the cached 800×384 IDR is gone.
        server.prepare(canvas: VideoCanvas(width: 800, height: 944, requestedWidth: 800, requestedHeight: 951), parameters: .default)
        let afterCanvas = await server.nextFrame(timeout: 0.4)
        XCTAssertNil(afterCanvas)

        // Stop / start (next Mirror session in the same process): nothing stale either.
        server.prepare(canvas: wide, parameters: .default)
        client.send(frame: idr(Self.sps800x384, seq: 5))
        let five = await server.nextFrame(timeout: 3)
        XCTAssertEqual(five?.sequence, 5)
        server.stop()
        try server.start()
        server.prepare(canvas: wide, parameters: .default)
        let afterRestart = await server.nextFrame(timeout: 0.4)
        XCTAssertNil(afterRestart)
        ok = await waitUntil(15) { client.isConnected && server.isClientConnected }
        XCTAssertTrue(ok, "the extension reconnects to the restarted host")
    }

    // MARK: placeholder before the broadcast (MP-1)

    func testPlaceholderPictureIsLocalizedAndFitsTheCanvas() {
        for canvas in [VideoCanvas(width: 800, height: 384), VideoCanvas(width: 800, height: 944), VideoCanvas(width: 1280, height: 576)] {
            let list = MirrorPlaceholderPicture.displayList(canvas: canvas, language: .en)
            XCTAssertEqual(list.size, DashSize(width: Double(canvas.width), height: Double(canvas.height)))
            let texts = list.commands.compactMap { c -> (String, DashRect)? in if case let .text(t, r, _) = c { return (t, r) }; return nil }
            XCTAssertEqual(texts.map(\.0), [MirrorPlaceholderPicture.title(.en), MirrorPlaceholderPicture.hint(.en)])
            for (_, r) in texts {
                XCTAssertGreaterThanOrEqual(r.minX, 0)
                XCTAssertLessThanOrEqual(r.maxX, Double(canvas.width))
                XCTAssertGreaterThanOrEqual(r.minY, 0)
                XCTAssertLessThanOrEqual(r.maxY, Double(canvas.height))
            }
        }
        XCTAssertEqual(MirrorPlaceholderPicture.title(.es), "Inicia la transmisión de pantalla en tu iPhone")
        XCTAssertTrue(MirrorPlaceholderPicture.displayList(canvas: VideoCanvas(width: 800, height: 384), language: .es).commands
            .contains { if case let .text(t, _, _) = $0 { return t == MirrorPlaceholderPicture.hint(.es) }; return false })
    }

    /// The mirror flow links the dash first; the broadcast starts seconds later. The dash's first
    /// 114 used to wait 2.85 s and get nothing — and the dash never pulled again. Now the pull is
    /// answered with the placeholder at the keep-alive cadence until the extension's IDR arrives.
    func testPlaceholderAnswersPullsUntilTheBroadcastStarts() async throws {
        let path = try socketPath()
        let server = MirrorRelayServer(socketPath: path)
        let tallPlaceholder = [idr(Self.sps800x944, seq: 100), idr(Self.sps800x944, seq: 101)]
        let widePlaceholder = [idr(Self.sps800x384, seq: 200), idr(Self.sps800x384, seq: 201)]
        let built = Locked<[VideoCanvas]>([])
        server.placeholderProvider = { canvas, _ in
            built.withLock { $0.append(canvas) }
            return canvas.height == 944 ? tallPlaceholder : widePlaceholder
        }
        try server.start()
        defer { server.stop() }
        let tall = VideoCanvas(width: 800, height: 944, requestedWidth: 800, requestedHeight: 951)
        server.prepare(canvas: tall, parameters: .default)
        server.resynchronize()
        let t0 = Date()
        let a = await server.nextFrame(timeout: 3)
        XCTAssertEqual(a?.sequence, 100)
        XCTAssertTrue(a?.isKeyframe ?? false)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0, "answered at the 0.9 s cadence, not after the pull timeout")
        let b = await server.nextFrame(timeout: 3)
        XCTAssertEqual(b?.sequence, 101, "the two placeholder IDRs alternate")
        XCTAssertEqual(server.stats.placeholderFramesServed, 2)
        XCTAssertEqual(built.current, [tall])

        // The broadcast starts: its IDR replaces the placeholder at once…
        let client = MirrorRelayClient(socketPath: path)
        client.retryInterval = 0.05
        defer { client.stop() }
        client.start()
        var ok = await waitUntil { client.isConnected && server.isClientConnected }
        XCTAssertTrue(ok)
        client.send(frame: idr(Self.sps800x944, seq: 7))
        let live = await server.nextFrame(timeout: 3)
        XCTAssertEqual(live?.sequence, 7)
        // …and from then on a late frame is answered with the live IDR, never the placeholder.
        let fallback = await server.nextFrame(timeout: 0.4)
        XCTAssertEqual(fallback?.sequence, 7)

        // Another canvas: a new placeholder for it; the old one is never served for it.
        let wide = VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386)
        server.prepare(canvas: wide, parameters: .default)
        ok = await waitUntil { built.current.count == 2 }
        XCTAssertTrue(ok)
        let w1 = await server.nextFrame(timeout: 3)
        XCTAssertEqual(w1?.sequence ?? 0, 200, "placeholder of the new canvas")

        // The broadcast ends: the dash is asked to start it again (no frozen last screen).
        server.prepare(canvas: tall, parameters: .default)
        client.send(frame: idr(Self.sps800x944, seq: 9))
        let nine = await server.nextFrame(timeout: 3)
        XCTAssertEqual(nine?.sequence, 9)
        client.stop()
        ok = await waitUntil { !server.isClientConnected }
        XCTAssertTrue(ok)
        let after = await server.nextFrame(timeout: 3)
        XCTAssertTrue([100, 101].contains(after?.sequence ?? 0), "\(String(describing: after?.sequence))")
        XCTAssertEqual(built.current, [tall, wide], "each canvas is rendered once")
    }

    func testWithoutAPlaceholderPullsStillWaitForTheExtension() async throws {
        let path = try socketPath()
        let server = MirrorRelayServer(socketPath: path)
        try server.start()
        defer { server.stop() }
        server.prepare(canvas: VideoCanvas(width: 800, height: 384), parameters: .default)
        let none = await server.nextFrame(timeout: 0.4)
        XCTAssertNil(none)
        XCTAssertEqual(server.stats.placeholderFramesServed, 0)
    }
}
