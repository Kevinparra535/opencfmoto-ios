// SPDX-License-Identifier: AGPL-3.0-or-later
// H264Encoder and DashProjectionEngine against the real VideoToolbox (macOS CI). Tests skip when
// the machine has no usable H.264 encoder (e.g. a VM without one); wrong output still fails.
#if canImport(VideoToolbox) && canImport(CoreGraphics) && canImport(CoreText)
import CoreGraphics
import CoreVideo
import VideoToolbox
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

/// Waits for a condition on the main test thread (polling).
private func pollUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

private func requireEncoder(width: Int = 320, height: Int = 240) throws {
    let probe = H264Encoder(label: "probe")
    defer { probe.invalidate() }
    do {
        try probe.configure(width: width, height: height, parameters: .default)
    } catch {
        throw XCTSkip("No usable VideoToolbox H.264 encoder on this machine: \(error)")
    }
}

/// A frame with a moving square so consecutive pictures differ.
private func picture(_ w: Int, _ h: Int, step: Int) -> CVPixelBuffer? {
    guard let pb = PixelBufferFactory.makeStandaloneBuffer(width: w, height: h) else { return nil }
    let list = DashDisplayList(size: DashSize(width: Double(w), height: Double(h)), background: DashColor(rgb: 0x203040), commands: [
        .fill(.rect(DashRect(x: Double(10 + step * 8), y: 40, width: 60, height: 60)), DashColor(rgb: 0xFFCC00), .nonZero),
        .text("frame \(step)", DashRect(x: 0, y: 0, width: Double(w), height: 40),
              DashTextStyle(font: DashFont(size: 24, weight: .bold), color: .white, alignment: .center)),
    ])
    DashRenderer().render(list, into: pb)
    return pb
}

private func nalTypes(_ au: Data) -> [UInt8] {
    AnnexB.nalUnits(annexB: au).compactMap { AnnexB.nalType($0) }
}

final class VideoEncoderTests: XCTestCase {
    func testFirstFrameIsSPSPPSIDRThenPFrames() throws {
        try requireEncoder()
        let frames = Locked<[EncodedFrame]>([])
        let enc = H264Encoder(label: "test")
        defer { enc.invalidate() }
        enc.onFrame = { f in frames.withLock { $0.append(f) } }
        try enc.configure(width: 320, height: 240, parameters: EncoderParameters(bitrate: 1_000_000, frameRate: 24))
        for i in 0 ..< 6 {
            let pb = try XCTUnwrap(picture(320, 240, step: i))
            XCTAssertTrue(enc.encode(pixelBuffer: pb, pts: Double(i) / 24))
        }
        enc.completeFrames()
        XCTAssertTrue(pollUntil { frames.current.count >= 6 }, "got \(frames.current.count) frames")
        let out = frames.current
        let first = try XCTUnwrap(out.first)
        XCTAssertTrue(first.isKeyframe)
        XCTAssertEqual(Array(nalTypes(first.accessUnit).prefix(3)), [7, 8, 5], "SPS, PPS, IDR with 4-byte start codes")
        XCTAssertEqual(Array(first.accessUnit.prefix(4)), [0, 0, 0, 1])
        XCTAssertFalse(nalTypes(first.accessUnit).contains(6), "no SEI")
        XCTAssertFalse(nalTypes(first.accessUnit).contains(9), "no AUD")
        // SPS: profile_idc 66 = Baseline (media-video.md §7.6).
        let sps = try XCTUnwrap(AnnexB.nalUnits(annexB: first.accessUnit).first)
        XCTAssertEqual(sps[sps.startIndex + 1], 66)
        XCTAssertTrue(out.dropFirst().contains { !$0.isKeyframe }, "P-frames follow")
        for f in out where !f.isKeyframe {
            XCTAssertFalse(nalTypes(f.accessUnit).contains(7), "no SPS on P-frames")
            XCTAssertTrue(nalTypes(f.accessUnit).allSatisfy { $0 == 1 })
        }
        XCTAssertEqual(out.map(\.sequence), Array(1 ... UInt64(out.count)))
        let stats = enc.stats
        XCTAssertEqual(stats.sessionsCreated, 1)
        XCTAssertEqual(stats.framesSubmitted, 6)
        XCTAssertEqual(enc.framesInFlight, 0)
        XCTAssertFalse(enc.lastParameterSets.sps.isEmpty)
    }

    func testForcedKeyframeCarriesParameterSets() throws {
        try requireEncoder()
        let frames = Locked<[EncodedFrame]>([])
        let enc = H264Encoder(label: "test")
        defer { enc.invalidate() }
        enc.onFrame = { f in frames.withLock { $0.append(f) } }
        try enc.configure(width: 320, height: 240, parameters: EncoderParameters(bitrate: 1_000_000, frameRate: 24,
                                                                                keyframeIntervalSeconds: 10))
        for i in 0 ..< 4 { enc.encode(pixelBuffer: try XCTUnwrap(picture(320, 240, step: i)), pts: Double(i) / 24) }
        enc.encode(pixelBuffer: try XCTUnwrap(picture(320, 240, step: 4)), pts: 4.0 / 24, forceKeyframe: true)
        enc.completeFrames()
        XCTAssertTrue(pollUntil { frames.current.count >= 5 })
        let last = try XCTUnwrap(frames.current.last)
        XCTAssertTrue(last.isKeyframe)
        XCTAssertEqual(Array(nalTypes(last.accessUnit).prefix(3)), [7, 8, 5])
        // requestKeyframe() applies to the next encode.
        enc.requestKeyframe()
        enc.encode(pixelBuffer: try XCTUnwrap(picture(320, 240, step: 5)), pts: 5.0 / 24)
        enc.completeFrames()
        XCTAssertTrue(pollUntil { frames.current.count >= 6 })
        XCTAssertTrue(frames.current.last?.isKeyframe ?? false)
    }

    func testRepeatedPictureAndNonMonotonicPTSStillEncode() throws {
        try requireEncoder()
        let frames = Locked<[EncodedFrame]>([])
        let enc = H264Encoder(label: "test")
        defer { enc.invalidate() }
        enc.onFrame = { f in frames.withLock { $0.append(f) } }
        try enc.configure(width: 320, height: 240, parameters: .default)
        let pb = try XCTUnwrap(picture(320, 240, step: 0))
        for _ in 0 ..< 3 { XCTAssertTrue(enc.encode(pixelBuffer: pb, pts: 1.0)) } // same picture, same pts
        enc.completeFrames()
        XCTAssertTrue(pollUntil { frames.current.count >= 3 })
        let pts = frames.current.map(\.presentationTime)
        XCTAssertEqual(pts, pts.sorted())
        XCTAssertEqual(Set(pts).count, pts.count, "PTS strictly increasing")
    }

    func testLiveUpdatesDoNotRecreateTheSession() throws {
        try requireEncoder()
        let enc = H264Encoder(label: "test")
        defer { enc.invalidate() }
        try enc.configure(width: 320, height: 240, parameters: .default)
        enc.updateBitrate(800_000)
        enc.updateFrameRate(15)
        enc.update(parameters: EncoderParameters(bitrate: 600_000, frameRate: 10))
        XCTAssertEqual(enc.stats.sessionsCreated, 1)
        XCTAssertEqual(enc.parameters?.bitrate, 600_000)
        XCTAssertEqual(enc.parameters?.frameRate, 10)
        XCTAssertTrue(enc.isSessionValid)
    }

    func testInvalidSizeIsRejected() {
        XCTAssertThrowsError(try H264Encoder().configure(width: 8, height: 240, parameters: .default))
        XCTAssertFalse(H264Encoder().encode(pixelBuffer: PixelBufferFactory.makeStandaloneBuffer(width: 32, height: 32)!, pts: 0))
    }

    func testEncodeStillProducesIndependentIDRs() throws {
        try requireEncoder()
        let pb = try XCTUnwrap(picture(320, 240, step: 1))
        let idrs = H264Encoder.encodeStill(pixelBuffer: pb, width: 320, height: 240, parameters: .default, count: 2, timeout: 3)
        XCTAssertEqual(idrs.count, 2)
        for f in idrs {
            XCTAssertTrue(f.isKeyframe)
            XCTAssertEqual(Array(nalTypes(f.accessUnit).prefix(3)), [7, 8, 5])
        }
    }

    func testSoftwareRequestIsReported() throws {
        try requireEncoder()
        let enc = H264Encoder(label: "sw")
        defer { enc.invalidate() }
        do {
            try enc.configure(width: 320, height: 240, parameters: .default, allowSoftware: true)
        } catch {
            throw XCTSkip("no software H.264 encoder: \(error)")
        }
        XCTAssertTrue(enc.stats.softwareRequested)
        XCTAssertTrue(H264Encoder.isSoftwareEncodingSupported)
    }
}

final class VideoEngineTests: XCTestCase {
    private let canvas = VideoCanvas(width: 320, height: 160, requestedWidth: 320, requestedHeight: 166)

    private func makeEngine(moving: Bool = false) -> DashProjectionEngine {
        let engine = DashProjectionEngine()
        engine.secondKeyframeDelay = nil
        engine.displayListProvider = { now in
            let x = moving ? (now * 200).truncatingRemainder(dividingBy: 200) : 40
            return DashDisplayList(size: DashSize(width: 320, height: 160), background: DashColor(rgb: 0x101418), commands: [
                .fill(.rect(DashRect(x: x, y: 40, width: 60, height: 60)), DashColor(rgb: 0x1A73E8), .nonZero),
            ])
        }
        return engine
    }

    func testResyncThenFirstPullIsAKeyframe() async throws {
        try requireEncoder(width: 320, height: 160)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.prepare(canvas: canvas, parameters: EncoderParameters(bitrate: 1_000_000, frameRate: 24))
        XCTAssertEqual(engine.mode, .foreground)
        engine.resynchronize()
        let first = await engine.nextFrame(timeout: 3)
        let f = try XCTUnwrap(first)
        XCTAssertTrue(f.isKeyframe)
        XCTAssertEqual(Array(nalTypes(f.accessUnit).prefix(3)), [7, 8, 5])
        // Static screen: the keep-alive repeat answers the next pull within ~1 s.
        let start = Date()
        let second = await engine.nextFrame(timeout: 3)
        XCTAssertNotNil(second)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        XCTAssertGreaterThanOrEqual(engine.stats.renderedFrames, 1)
        XCTAssertGreaterThanOrEqual(engine.stats.pullsServed, 2)
    }

    func testMovingContentStreamsAndPreviewIsDelivered() async throws {
        try requireEncoder(width: 320, height: 160)
        let engine = makeEngine(moving: true)
        defer { engine.stop() }
        let previews = Locked(0)
        engine.previewHandler = { image in
            if image.width == 320 { previews.withLock { $0 += 1 } }
        }
        engine.prepare(canvas: canvas, parameters: EncoderParameters(bitrate: 1_000_000, frameRate: 30))
        engine.resynchronize()
        var got: [EncodedFrame] = []
        for _ in 0 ..< 10 {
            if let f = await engine.nextFrame(timeout: 3) { got.append(f) }
        }
        XCTAssertEqual(got.count, 10)
        XCTAssertTrue(got.first?.isKeyframe ?? false)
        XCTAssertTrue(got.dropFirst().contains { !$0.isKeyframe })
        XCTAssertGreaterThan(previews.current, 0)
    }

    func testThermalAndLowPowerCapsAreApplied() throws {
        try requireEncoder(width: 320, height: 160)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.prepare(canvas: canvas, parameters: EncoderParameters(bitrate: 2_500_000, frameRate: 30))
        engine.setThermalState(level: .severe, lowPowerMode: false)
        XCTAssertEqual(engine.effectiveParameters.frameRate, 15)
        XCTAssertEqual(engine.effectiveParameters.bitrate, 1_500_000)
        engine.setThermalState(level: .none, lowPowerMode: true)
        XCTAssertEqual(engine.effectiveParameters.frameRate, 15)
        XCTAssertEqual(engine.effectiveParameters.bitrate, 2_500_000)
        engine.appliesLowPowerCap = false
        XCTAssertEqual(engine.effectiveParameters.frameRate, 30)
    }

    func testHoldModeServesPreEncodedIDRsAndForegroundResumes() async throws {
        try requireEncoder(width: 320, height: 160)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.holdDisplayListProvider = { _ in
            DashDisplayList(size: DashSize(width: 320, height: 160), background: DashColor(rgb: 0x000000), commands: [
                .text("Map paused", DashRect(x: 0, y: 0, width: 320, height: 160),
                      DashTextStyle(font: DashFont(size: 28, weight: .bold), color: .white, alignment: .center)),
            ])
        }
        engine.allowsSoftwareEncodingInBackground = false
        engine.prepare(canvas: canvas, parameters: .default)
        engine.resynchronize()
        _ = await engine.nextFrame(timeout: 3)
        let built = Locked<Bool?>(nil)
        engine.prepareHoldPicture { ok in built.set(ok) }
        XCTAssertTrue(pollUntil { built.current != nil })
        XCTAssertEqual(built.current, true)
        engine.enterBackground()
        XCTAssertTrue(pollUntil { engine.mode == .hold })
        let a = await engine.nextFrame(timeout: 2)
        let b = await engine.nextFrame(timeout: 2)
        XCTAssertTrue(a?.isKeyframe ?? false)
        XCTAssertTrue(b?.isKeyframe ?? false)
        XCTAssertNotEqual(a?.accessUnit, nil)
        XCTAssertGreaterThanOrEqual(engine.stats.holdFramesServed, 2)
        engine.enterForeground()
        XCTAssertTrue(pollUntil { engine.mode == .foreground })
        let resumed = await engine.nextFrame(timeout: 3)
        XCTAssertTrue(resumed?.isKeyframe ?? false, "first live frame after the hold is an IDR")
    }

    func testStopWakesPullsWithNil() async throws {
        try requireEncoder(width: 320, height: 160)
        let engine = makeEngine()
        engine.prepare(canvas: canvas, parameters: .default)
        engine.stop()
        XCTAssertEqual(engine.mode, .stopped)
        let f = await engine.nextFrame(timeout: 0.5)
        XCTAssertNil(f)
    }

    func testInvalidCanvasIsIgnored() {
        let engine = DashProjectionEngine()
        engine.prepare(canvas: VideoCanvas(width: 0, height: 384), parameters: .default)
        XCTAssertEqual(engine.mode, .idle)
    }

    func testPrepareWhileBackgroundedNeverStartsTheHardwareEncoder() throws {
        try requireEncoder(width: 320, height: 160)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.allowsSoftwareEncodingInBackground = false
        engine.enterBackground() // before any canvas exists
        engine.prepare(canvas: canvas, parameters: .default)
        XCTAssertEqual(engine.mode, .hold)
        XCTAssertEqual(engine.stats.mode, .hold)
    }

    func testBackgroundSoftwareEncodingKeepsStreamingAtReducedRate() async throws {
        try requireEncoder(width: 320, height: 160)
        let engine = makeEngine(moving: true)
        defer { engine.stop() }
        engine.backgroundFrameRate = 8
        engine.prepare(canvas: canvas, parameters: EncoderParameters(bitrate: 1_000_000, frameRate: 30))
        engine.resynchronize()
        _ = await engine.nextFrame(timeout: 3)
        engine.enterBackground()
        XCTAssertTrue(pollUntil { engine.mode != .foreground })
        guard engine.mode == .backgroundSoftware else {
            throw XCTSkip("no software H.264 encoder on this machine (mode \(engine.mode))")
        }
        XCTAssertEqual(engine.effectiveParameters.frameRate, 8)
        let first = await engine.nextFrame(timeout: 3)
        XCTAssertTrue(first?.isKeyframe ?? false, "first frame of the software session is an IDR")
        let next = await engine.nextFrame(timeout: 3)
        XCTAssertNotNil(next)
        engine.enterForeground()
        XCTAssertTrue(pollUntil { engine.mode == .foreground })
        XCTAssertEqual(engine.effectiveParameters.frameRate, 30)
    }

    func testWireDumpRecordsServedFrames() async throws {
        try requireEncoder(width: 320, height: 160)
        let engine = makeEngine()
        defer { engine.stop() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocm-dump-\(UUID().uuidString).h264")
        defer { try? FileManager.default.removeItem(at: url) }
        try engine.startWireDump(to: url, maxFrames: 2)
        engine.prepare(canvas: canvas, parameters: .default)
        engine.resynchronize()
        let f1 = await engine.nextFrame(timeout: 3)
        let f2 = await engine.nextFrame(timeout: 3)
        let dumped = try Data(contentsOf: url)
        XCTAssertEqual(dumped, (f1?.accessUnit ?? Data()) + (f2?.accessUnit ?? Data()))
    }
}
#endif
