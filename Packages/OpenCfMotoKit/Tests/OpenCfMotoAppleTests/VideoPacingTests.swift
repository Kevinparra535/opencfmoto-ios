// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class VideoPacingTests: XCTestCase {
    private func input(now: TimeInterval = 10, ready: Bool = true, changed: Bool = false, key: Bool = false,
                       queued: Int = 0, inFlight: Int = 0, lastEncode: TimeInterval? = 9.9, picture: Bool = true,
                       notEncoded: Bool = false, previewDue: Bool = false) -> ProjectionPacer.Input {
        .init(now: now, encoderReady: ready, contentChanged: changed, keyframeRequested: key, queuedFrames: queued,
              framesInFlight: inFlight, lastEncodeAt: lastEncode, hasPicture: picture, pictureNotEncoded: notEncoded,
              repeatAfter: 0.9, previewDue: previewDue)
    }

    func testFirstTickRendersAndEncodes() {
        let d = ProjectionPacer.decide(input(lastEncode: nil, picture: false))
        XCTAssertEqual(d, .init(render: true, encode: true, forceKeyframe: false, isRepeat: false))
    }

    func testKeyframeRequestEncodesCurrentPictureWithoutRendering() {
        let d = ProjectionPacer.decide(input(key: true))
        XCTAssertEqual(d, .init(render: false, encode: true, forceKeyframe: true, isRepeat: false))
    }

    func testKeyframeRequestBypassesFramesInFlight() {
        let d = ProjectionPacer.decide(input(key: true, inFlight: 2))
        XCTAssertTrue(d.encode)
        XCTAssertTrue(d.forceKeyframe)
    }

    func testKeyframeWithChangedContentRendersFirst() {
        let d = ProjectionPacer.decide(input(changed: true, key: true))
        XCTAssertEqual(d, .init(render: true, encode: true, forceKeyframe: true, isRepeat: false))
    }

    func testPullPacingHoldsRenderingWhileAFrameWaits() {
        XCTAssertEqual(ProjectionPacer.decide(input(changed: true, queued: 1)), .idle)
        XCTAssertEqual(ProjectionPacer.decide(input(changed: true, inFlight: 1)), .idle)
    }

    func testPreviewStillRendersWhileGated() {
        let d = ProjectionPacer.decide(input(changed: true, queued: 1, previewDue: true))
        XCTAssertEqual(d, .init(render: true, encode: false, forceKeyframe: false, isRepeat: false))
    }

    func testChangedContentIsRenderedAndEncoded() {
        let d = ProjectionPacer.decide(input(changed: true))
        XCTAssertEqual(d, .init(render: true, encode: true, forceKeyframe: false, isRepeat: false))
    }

    func testRenderedButNotEncodedPictureIsEncodedWhenTheGateOpens() {
        let d = ProjectionPacer.decide(input(notEncoded: true))
        XCTAssertEqual(d, .init(render: false, encode: true, forceKeyframe: false, isRepeat: false))
    }

    func testStaticScreenRepeatsAfter900ms() {
        XCTAssertEqual(ProjectionPacer.decide(input(now: 10.0, lastEncode: 9.5)), .idle)
        XCTAssertEqual(ProjectionPacer.decide(input(now: 10.0, lastEncode: 9.11)), .idle)
        XCTAssertEqual(ProjectionPacer.decide(input(now: 10.0, lastEncode: 9.1)),
                       .init(render: false, encode: true, forceKeyframe: false, isRepeat: true))
        XCTAssertEqual(ProjectionPacer.decide(input(now: 10.0, lastEncode: 5)),
                       .init(render: false, encode: true, forceKeyframe: false, isRepeat: true))
    }

    func testRepeatWaitsForTheQueueToDrain() {
        XCTAssertEqual(ProjectionPacer.decide(input(now: 10, queued: 1, lastEncode: 5)), .idle)
    }

    func testEncoderNotReady() {
        XCTAssertEqual(ProjectionPacer.decide(input(ready: false, changed: true)), .idle)
        XCTAssertEqual(ProjectionPacer.decide(input(ready: false, changed: true, previewDue: true)),
                       .init(render: true, encode: false, forceKeyframe: false, isRepeat: false))
        XCTAssertEqual(ProjectionPacer.decide(input(ready: false, key: true)), .idle)
    }

    func testNoPictureAndGatedRendersNothing() {
        XCTAssertEqual(ProjectionPacer.decide(input(queued: 1, picture: false)), .idle)
    }

    // MARK: FramePull

    private func frame(_ seq: UInt64, key: Bool) -> EncodedFrame {
        EncodedFrame(accessUnit: Data([0, 0, 0, 1, key ? 0x65 : 0x41, UInt8(seq & 0xFF)]), isKeyframe: key, sequence: seq)
    }

    func testPullReturnsQueuedFrame() async {
        let q = FrameQueue()
        q.push(frame(1, key: true))
        let r = await FramePull.next(from: q, timeout: 1) { nil }
        XCTAssertEqual(r.frame?.sequence, 1)
        XCTAssertFalse(r.usedFallback)
    }

    func testPullFallsBackToKeyframeAndRecloses() async {
        let q = FrameQueue()
        let requests = Locked(0)
        q.onKeyframeNeeded = { requests.withLock { $0 += 1 } }
        q.push(frame(1, key: true))
        _ = await q.next(timeout: 0.1)
        let start = Date()
        let r = await FramePull.next(from: q, timeout: 0.3) { q.lastKeyframe }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3, "must answer within the caller's timeout")
        XCTAssertEqual(r.frame?.sequence, 1)
        XCTAssertTrue(r.usedFallback)
        XCTAssertTrue(q.isGateClosed, "next live frame must be an IDR")
        XCTAssertEqual(requests.current, 1)
        q.push(frame(2, key: false))
        XCTAssertEqual(q.pendingCount, 0, "P-frame after the fallback IDR is gated")
    }

    func testPullNeverFallsBackToAPFrame() async {
        let q = FrameQueue()
        let r = await FramePull.next(from: q, timeout: 0.2) { EncodedFrame(accessUnit: Data([1]), isKeyframe: false) }
        XCTAssertNil(r.frame)
        XCTAssertFalse(r.usedFallback)
    }

    func testPullWithNothingAtAll() async {
        let q = FrameQueue()
        let r = await FramePull.next(from: q, timeout: 0.2) { nil }
        XCTAssertNil(r.frame)
    }

    /// CL-5: after an inactive blip the "Phone locked" hold IDRs may still exist while the engine
    /// streams in the foreground; a late pull must fall back to the live IDR, never to them (and
    /// must not consume the hold round-robin).
    func testForegroundFallbackIsTheLiveKeyframeNeverTheHoldPicture() {
        let hold = frame(7, key: true), live = frame(9, key: true)
        let holdAsked = Locked(0)
        let holdPick: () -> EncodedFrame? = { holdAsked.withLock { $0 += 1 }; return hold }
        XCTAssertEqual(ProjectionFallback.keyframe(foreground: true, hold: holdPick, live: { live })?.sequence, 9)
        XCTAssertEqual(holdAsked.current, 0)
        XCTAssertNil(ProjectionFallback.keyframe(foreground: true, hold: holdPick, live: { nil }), "no live IDR: nothing")
        XCTAssertEqual(ProjectionFallback.keyframe(foreground: false, hold: holdPick, live: { live })?.sequence, 7)
        XCTAssertEqual(ProjectionFallback.keyframe(foreground: false, hold: { nil }, live: { live })?.sequence, 9)
    }

    // MARK: RateMeter

    func testRateMeterWindow() {
        var m = RateMeter(window: 2)
        for i in 0 ..< 48 { m.add(10 + Double(i) / 24) }
        XCTAssertEqual(m.rate(now: 12), 24, accuracy: 0.5)
        XCTAssertEqual(m.rate(now: 13), 12, accuracy: 0.6)
        XCTAssertEqual(m.rate(now: 20), 0)
    }

    // MARK: Thermal caps (ios-platform-facts.md recommendation 15)

    func testThermalCapsTable() {
        let base = EncoderParameters(bitrate: 2_500_000, frameRate: 30)
        func caps(_ l: ThermalLevel, _ lp: Bool = false) -> [Int] {
            let p = ThermalCaps.apply(to: base, level: l, lowPowerMode: lp)
            return [p.frameRate, p.bitrate]
        }
        XCTAssertEqual(caps(.none), [30, 2_500_000])
        XCTAssertEqual(caps(.light), [30, 2_500_000])
        XCTAssertEqual(caps(.moderate), [20, 2_500_000])
        XCTAssertEqual(caps(.severe), [15, 1_500_000])
        XCTAssertEqual(caps(.critical), [5, 1_250_000])
        XCTAssertEqual(caps(.shutdown), [5, 1_250_000])
        XCTAssertEqual(caps(.none, true), [15, 2_500_000])
        XCTAssertEqual(caps(.moderate, true), [15, 2_500_000])
        XCTAssertEqual(caps(.critical, true), [5, 1_250_000])
    }

    func testThermalCapsNeverRaiseAndKeepTheBitrateFloor() {
        let low = EncoderParameters(bitrate: 1_000_000, frameRate: 10)
        let p = ThermalCaps.apply(to: low, level: .critical, lowPowerMode: true)
        XCTAssertEqual(p.frameRate, 5)
        XCTAssertEqual(p.bitrate, 600_000) // 0.5 × 1 M = 500 k → floor 600 k
        let tiny = ThermalCaps.apply(to: EncoderParameters(bitrate: 400_000, frameRate: 24), level: .severe, lowPowerMode: false)
        XCTAssertEqual(tiny.bitrate, 400_000) // floor = min(600 k, requested)
        XCTAssertEqual(tiny.frameRate, 15)
        let saver = ThermalCaps.apply(to: EncoderParameters(bitrate: 2_500_000, frameRate: 12), level: .moderate, lowPowerMode: true)
        XCTAssertEqual(saver.frameRate, 12)
    }

    func testThermalCapsCanBeDisabled() {
        let base = EncoderParameters(bitrate: 2_500_000, frameRate: 30)
        let p = ThermalCaps.apply(to: base, level: .critical, lowPowerMode: true, thermal: false, lowPower: false)
        XCTAssertEqual(p, base)
        let onlyLP = ThermalCaps.apply(to: base, level: .critical, lowPowerMode: true, thermal: false)
        XCTAssertEqual(onlyLP.frameRate, 15)
        XCTAssertEqual(onlyLP.bitrate, 2_500_000)
    }

    // MARK: H.264 session settings (media-video.md §7.1, §7.6, §15.3)

    func testDefaultProfileIsBaseline31() {
        let s = H264EncoderSettings(width: 800, height: 384, parameters: .default)
        XCTAssertEqual(s.profileLevel, .baseline31)
        XCTAssertTrue(s.usesCAVLC)
        XCTAssertEqual(s.macroblocksPerFrame, 1_200)
        XCTAssertEqual(s.averageBitRate, 2_500_000)
        XCTAssertEqual(s.dataRateLimitBytes, 468_750) // 2.5 M × 1.5 / 8
        XCTAssertEqual(s.dataRateLimitSeconds, 1)
        XCTAssertEqual(s.expectedFrameRate, 24)
        XCTAssertEqual(s.maxKeyFrameInterval, 24)      // fps × 1 s
        XCTAssertEqual(s.maxKeyFrameIntervalDuration, 1)
    }

    func testKnownDashCanvasesStayAtLevel31() {
        let p30 = EncoderParameters(bitrate: 2_500_000, frameRate: 30)
        for (w, h, mbs) in [(800, 384, 1_200), (800, 944, 2_950), (1280, 576, 2_880), (720, 704, 1_980), (544, 512, 1_088)] {
            let s = H264EncoderSettings(width: w, height: h, parameters: p30)
            XCTAssertEqual(s.macroblocksPerFrame, mbs, "\(w)x\(h)")
            XCTAssertEqual(s.profileLevel, .baseline31, "\(w)x\(h)")
            XCTAssertEqual(s.maxKeyFrameInterval, 30)
        }
        // 1280×720 = 3600 MBs × 30 = 108 000 MB/s: exactly at the level 3.1 limits.
        XCTAssertEqual(H264EncoderSettings(width: 1280, height: 720, parameters: p30).profileLevel, .baseline31)
    }

    func testLargeCanvasesUseBaselineAutoLevel() {
        let p30 = EncoderParameters(bitrate: 2_500_000, frameRate: 30)
        XCTAssertEqual(H264EncoderSettings(width: 1920, height: 720, parameters: p30).profileLevel, .baselineAutoLevel)
        XCTAssertEqual(H264EncoderSettings(width: 1280, height: 736, parameters: p30).profileLevel, .baselineAutoLevel)
        // MaxMBPS exceeded at 60 fps although MaxFS is fine.
        let p60 = EncoderParameters(bitrate: 2_500_000, frameRate: 60)
        XCTAssertEqual(H264EncoderSettings(width: 1280, height: 576, parameters: p60).profileLevel, .baselineAutoLevel)
    }

    func testMoriniProfileUsesMainAutoLevelAndTwoSecondGOP() {
        let morini = EncoderParameters(bitrate: 2_000_000, frameRate: 10, keyframeIntervalSeconds: 2, forceBaseline: false)
        let s = H264EncoderSettings(width: 1024, height: 464, parameters: morini)
        XCTAssertEqual(s.profileLevel, .mainAutoLevel)
        XCTAssertFalse(s.usesCAVLC)
        XCTAssertEqual(s.maxKeyFrameInterval, 20)
        XCTAssertEqual(s.maxKeyFrameIntervalDuration, 2)
        XCTAssertEqual(s.dataRateLimitBytes, 375_000)
    }

    func testDegenerateParametersAreSanitised() {
        let s = H264EncoderSettings(width: 800, height: 384,
                                    parameters: EncoderParameters(bitrate: 0, frameRate: 0, keyframeIntervalSeconds: 0))
        XCTAssertEqual(s.expectedFrameRate, 1)
        XCTAssertEqual(s.averageBitRate, 1)
        XCTAssertEqual(s.maxKeyFrameIntervalDuration, 1)
        XCTAssertEqual(s.maxKeyFrameInterval, 1)
        XCTAssertEqual(H264EncoderSettings(width: 801, height: 385, parameters: .default).macroblocksPerFrame, 51 * 25)
    }

    func testRecreatableStatuses() {
        XCTAssertTrue(H264EncoderStatus.requiresSessionRecreation(-12903))
        XCTAssertTrue(H264EncoderStatus.requiresSessionRecreation(-12915))
        XCTAssertTrue(H264EncoderStatus.requiresSessionRecreation(-12912))
        XCTAssertFalse(H264EncoderStatus.requiresSessionRecreation(-12902))
        XCTAssertFalse(H264EncoderStatus.requiresSessionRecreation(0))
        XCTAssertEqual(H264EncoderStatus.describe(-12903), "kVTInvalidSessionErr")
        XCTAssertEqual(H264EncoderStatus.describe(-1), "OSStatus -1")
    }

    // MARK: Wire dump

    func testWireDumpWritesExactAccessUnitsUpToTheCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ocm-dump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opencfmoto-video-own.h264")
        let dump = try H264WireDump(url: url, maxFrames: 2)
        XCTAssertTrue(dump.write(EncodedFrame(accessUnit: Data([0, 0, 0, 1, 0x67, 1]), isKeyframe: true)))
        XCTAssertTrue(dump.write(EncodedFrame(accessUnit: Data([0, 0, 0, 1, 0x41, 2]), isKeyframe: false)))
        XCTAssertTrue(dump.isFinished)
        XCTAssertFalse(dump.write(EncodedFrame(accessUnit: Data([9]), isKeyframe: false)))
        XCTAssertEqual(dump.framesWritten, 2)
        XCTAssertEqual(try Data(contentsOf: url), Data([0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x41, 2]))
    }
}
