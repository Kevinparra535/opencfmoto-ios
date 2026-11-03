// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §6.2, P0-4 … P0-8): the background ladder of DashProjectionEngine —
// pre-warm, acceptance, fallback order, encoder tags, demotion and retry, canvas changes, the status
// line and the dry run — with FakeDashVideoEncoder injected through the engine's test seams, so no
// VideoToolbox is needed and nothing skips on a VM. The log lines are captured with
// `Log.shared.subscribe` and compared with their exact texts.
#if canImport(VideoToolbox) && canImport(CoreGraphics) && canImport(CoreText)
import CoreVideo
import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

/// Waits for a condition (polling).
private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// Real time plus a jump the test controls (the 60 s retry delay, the 600 s dry run).
private final class SteppedClock: MonotonicClock, @unchecked Sendable {
    private let offset = Locked<TimeInterval>(0)
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime + offset.current }
    func advance(_ seconds: TimeInterval) { offset.withLock { $0 += seconds } }
}

/// The `VIDEO` log lines logged while it is subscribed.
private final class LogCapture: @unchecked Sendable {
    private let captured = Locked<[(level: LogLevel, message: String)]>([])
    private var token: UUID?

    init() {
        token = Log.shared.subscribe { [captured] line in
            guard line.tag == "VIDEO" else { return }
            captured.withLock { $0.append((line.level, line.message)) }
        }
    }

    func stop() {
        if let token { Log.shared.unsubscribe(token) }
        token = nil
    }

    var messages: [String] { captured.current.map(\.message) }
    func lines(_ prefix: String) -> [String] { messages.filter { $0.hasPrefix(prefix) } }
    func count(_ prefix: String) -> Int { lines(prefix).count }
    func level(_ message: String) -> LogLevel? { captured.current.first { $0.message == message }?.level }
    @discardableResult
    func wait(_ prefix: String, count: Int = 1, timeout: TimeInterval = 5) -> Bool {
        waitUntil(timeout) { self.count(prefix) >= count }
    }
}

/// Probe times vary: `IDR 50b in 3ms` → `IDR 50b in Nms`.
private func normalized(_ line: String) -> String {
    line.replacingOccurrences(of: #"(IDR \d+b) in \d+ms"#, with: "$1 in Nms", options: .regularExpression)
}

private func matches(_ line: String, _ pattern: String) -> Bool {
    line.range(of: pattern, options: .regularExpression) != nil
}

private let refused = H264EncoderStatus.failure(status: H264EncoderStatus.invalidSession,
                                                message: "VTCompressionSessionEncodeFrame failed: kVTInvalidSessionErr")
private let notCreated = H264EncoderStatus.failure(status: H264EncoderStatus.couldNotFindEncoder,
                                                   message: "VTCompressionSessionCreate failed: kVTCouldNotFindVideoEncoderErr")

final class VideoEngineBackgroundTests: XCTestCase {
    private let canvas = VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386)
    private let parameters = EncoderParameters(bitrate: 3_375_000, frameRate: 24)
    private var engines: [DashProjectionEngine] = []
    /// Bytes of a fake IDR access unit (SPS + PPS + IDR slice) at 800×384.
    private let idrBytes = FakeAU.idr(0).count

    override func tearDown() {
        for engine in engines { engine.stop() }
        engines = []
        super.tearDown()
    }

    private func makeEngine(_ factory: FakeEncoderFactory, policy: LockedStreamPolicy = .videoToolboxSoftwareOnly,
                            clock: any MonotonicClock = SystemMonotonicClock(),
                            encoderList: [BackgroundLog.EncoderListEntry] = []) -> DashProjectionEngine {
        let engine = DashProjectionEngine(clock: clock)
        engines.append(engine)
        engine.secondKeyframeDelay = nil
        engine.lockedStreamPolicy = policy
        engine.encoderFactory = { factory.make($0) }
        engine.encoderListProvider = { encoderList }
        engine.softwareEncodingAvailable = { true }
        engine.holdFramesEncoder = { _, _, _, _ in FakeAU.holdFrames() }
        engine.displayListProvider = { now in
            DashDisplayList(size: DashSize(width: 800, height: 384), background: DashColor(rgb: 0x101418), commands: [
                .fill(.rect(DashRect(x: (now * 300).truncatingRemainder(dividingBy: 700), y: 100, width: 80, height: 80)),
                      DashColor(rgb: 0x1A73E8), .nonZero),
            ])
        }
        return engine
    }

    /// The dash connects (REQ 16 + 112) and pulls the first frames in the foreground.
    private func streamInForeground(_ engine: DashProjectionEngine, pulls: Int = 4) async -> [EncodedFrame] {
        engine.prepare(canvas: canvas, parameters: parameters)
        engine.resynchronize()
        return await pull(engine, pulls)
    }

    private func pull(_ engine: DashProjectionEngine, _ count: Int, timeout: TimeInterval = 1.5) async -> [EncodedFrame] {
        var frames: [EncodedFrame] = []
        for _ in 0 ..< count {
            if let f = await engine.nextFrame(timeout: timeout) { frames.append(f) }
        }
        return frames
    }

    /// `.inactive` (hold picture, optionally the pre-warm), then `.background`; waits for the outcome.
    private func lock(_ engine: DashProjectionEngine, preWarm: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let built = Locked<Bool?>(nil)
        engine.prepareHoldPicture { ok in built.set(ok) }
        if preWarm { engine.prepareBackgroundEncoder() }
        XCTAssertTrue(waitUntil { built.current != nil }, file: file, line: line)
        XCTAssertEqual(built.current, true, "hold picture", file: file, line: line)
        engine.enterBackground()
        XCTAssertTrue(waitUntil { engine.mode == .hold || engine.mode == .backgroundSoftware }, "ladder outcome",
                      file: file, line: line)
    }

    private func unlock(_ engine: DashProjectionEngine, file: StaticString = #filePath, line: UInt = #line) {
        engine.enterForeground()
        XCTAssertTrue(waitUntil { engine.mode == .foreground }, file: file, line: line)
    }

    /// P0-6 invariant: wherever the encoder tag changes on the wire, the frame is an IDR.
    private func assertTagChangesOnlyAtIDRs(_ frames: [EncodedFrame], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(frames.first?.isKeyframe ?? false, "the first frame on the wire is an IDR", file: file, line: line)
        for (a, b) in zip(frames, frames.dropFirst()) where a.encoderTag != b.encoderTag {
            XCTAssertTrue(b.isKeyframe, "tag \(a.encoderTag) → \(b.encoderTag) on a non-IDR frame", file: file, line: line)
        }
    }

    private func distinctTags(_ frames: [EncodedFrame]) -> [UInt32] {
        var out: [UInt32] = []
        for f in frames where out.last != f.encoderTag { out.append(f.encoderTag) }
        return out
    }

    // MARK: §6.2 item 1 — ladder order and the logged reasons

    func testLadderTriesThePreWarmedSessionAFreshOneThenEverySoftwareEncoderIDAndLogsEachReason() async throws {
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            switch (r.label, r.encoderID) {
            case ("own-sw-pre", _): b.usesHardware = true // VideoToolbox says it is a hardware session
            case ("own-sw", _): b.configureFailure = notCreated; b.usesHardware = nil
            case ("own-sw-id", "com.example.sw.a"?): b.stall = true // no probe IDR
            case ("own-sw-id", "com.example.sw.b"?): b.usesHardware = nil // "?" with a probe IDR: accepted
            default: break
            }
            return b
        }
        let list = [BackgroundLog.EncoderListEntry(id: "com.example.hw", name: "HW", isHardwareAccelerated: true),
                    BackgroundLog.EncoderListEntry(id: "com.example.sw.a", name: "A", isHardwareAccelerated: nil),
                    BackgroundLog.EncoderListEntry(id: "com.example.sw.b", name: "B", isHardwareAccelerated: false)]
        let engine = makeEngine(factory, encoderList: list)
        let log = LogCapture()
        defer { log.stop() }
        let foreground = await streamInForeground(engine)
        let hardwareTag = try XCTUnwrap(foreground.first?.encoderTag)
        lock(engine, preWarm: true)
        XCTAssertEqual(engine.mode, .backgroundSoftware)

        XCTAssertEqual(log.lines("[bg] pre-warm").map(normalized),
                       ["[bg] pre-warm vt-sw at inactive: create=noErr hw=true probe=IDR \(idrBytes)b in Nms"])
        XCTAssertEqual(log.lines("[bg] enter"),
                       ["[bg] enter: canvas 800x384 policy=vtsw rungs=vt-sw,hold last-live-idr=\(idrBytes)b hold-idrs=2"])
        XCTAssertEqual(log.lines("[bg] try ").map(normalized), [
            "[bg] try vt-sw (pre-warmed): create=noErr hw=true probe=IDR \(idrBytes)b in Nms sps=ok \u{2192} rejected: hw=true",
            "[bg] try vt-sw (fresh): create=kVTCouldNotFindVideoEncoderErr(-12908) hw=? probe=- sps=- \u{2192} rejected: not created",
            "[bg] try vt-sw (id=com.example.sw.a): create=noErr hw=false probe=none in 500ms sps=- \u{2192} rejected: probe=none",
            "[bg] try vt-sw (id=com.example.sw.b): create=noErr hw=? probe=IDR \(idrBytes)b in Nms sps=ok \u{2192} accepted",
        ])
        XCTAssertTrue(log.messages.contains("[switch] vt-hw \u{2192} vt-sw: gate closed; next frame on the wire is an IDR"))
        XCTAssertEqual(log.lines("background \u{2192}"), ["background \u{2192} backgroundSoftware @8fps (encoder vt-sw, 3375kbps)"])
        // The hardware-marked entry is never tried; every rejected candidate was invalidated.
        XCTAssertEqual(factory.requests.map(\.label), ["own", "own-sw-pre", "own-sw", "own-sw-id", "own-sw-id"])
        XCTAssertEqual(factory.requests.compactMap(\.encoderID), ["com.example.sw.a", "com.example.sw.b"])
        let made = factory.encoders
        XCTAssertGreaterThanOrEqual(made[1].invalidateCount, 1)
        XCTAssertGreaterThanOrEqual(made[2].invalidateCount, 1)
        XCTAssertGreaterThanOrEqual(made[3].invalidateCount, 1)
        XCTAssertEqual(made[4].invalidateCount, 0)
        // The accepted encoder's probe IDR is the first frame after the lock; each rejected candidate
        // consumed a tag, and none of them ever reached the wire.
        let background = await pull(engine, 4)
        let tags = distinctTags(background)
        XCTAssertEqual(tags, [hardwareTag + 4], "own-sw-pre, own-sw, own-sw-id(a) took the tags in between")
        XCTAssertTrue(background.first?.isKeyframe ?? false)
        XCTAssertTrue(background.contains { !$0.isKeyframe }, "the accepted encoder streams P-frames")
    }

    func testEveryRungRejectedEndsInHoldWithTheReasonAndOnlyTheHoldIDRsAreServed() async throws {
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            if r.software { b.usesHardware = true }
            return b
        }
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .hold)
        XCTAssertEqual(log.lines("[bg] try ").map(normalized), [
            "[bg] try vt-sw (fresh): create=noErr hw=true probe=IDR \(idrBytes)b in Nms sps=ok \u{2192} rejected: hw=true",
        ])
        XCTAssertTrue(log.messages.contains("[switch] vt-hw \u{2192} hold: gate closed; next frame on the wire is an IDR"))
        XCTAssertEqual(log.lines("background \u{2192}"), ["background \u{2192} hold (2 hold IDR(s); reason: all rungs rejected)"])
        let held = await pull(engine, 3, timeout: 0.5)
        XCTAssertEqual(held.count, 3)
        XCTAssertTrue(held.allSatisfy { $0.encoderTag == DashProjectionEngine.holdTag && FakeAU.isHoldPicture($0) })
        XCTAssertTrue(log.wait("[switch] first hold IDR on the wire"))
        XCTAssertTrue(matches(try XCTUnwrap(log.lines("[switch] first hold IDR").first),
                              #"^\[switch\] first hold IDR on the wire: \#(idrBytes)b, \d+\.\d\ds after the switch$"#))
    }

    func testHoldReasonsPolicyAndNoEncoderRung() async {
        let log = LogCapture()
        defer { log.stop() }
        let holdOnly = makeEngine(FakeEncoderFactory(), policy: .holdOnly)
        _ = await streamInForeground(holdOnly)
        lock(holdOnly)
        XCTAssertEqual(holdOnly.mode, .hold)
        let cpuOnly = makeEngine(FakeEncoderFactory(), policy: .cpuOnly) // no cpuEncoderFactory: no encoder rung
        _ = await streamInForeground(cpuOnly)
        lock(cpuOnly)
        XCTAssertEqual(cpuOnly.mode, .hold)
        XCTAssertEqual(log.lines("[bg] enter"), [
            "[bg] enter: canvas 800x384 policy=hold rungs=hold last-live-idr=\(idrBytes)b hold-idrs=2",
            "[bg] enter: canvas 800x384 policy=cpu rungs=hold last-live-idr=\(idrBytes)b hold-idrs=2",
        ])
        XCTAssertEqual(log.lines("background \u{2192}"), [
            "background \u{2192} hold (2 hold IDR(s); reason: policy hold)",
            "background \u{2192} hold (2 hold IDR(s); reason: no encoder rung)",
        ])
        XCTAssertEqual(log.count("[bg] try "), 0)
    }

    // MARK: §6.2 item 2 — the encoder tag changes on the wire only at IDRs (fg → bg → fg)

    func testEncoderTagChangesOnlyAtIDRsAcrossLockAndUnlock() async throws {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        let foreground = await streamInForeground(engine, pulls: 8)
        await sleepSeconds(0.2) // P-frames queue up while nobody pulls
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        let background = await pull(engine, 8)
        await sleepSeconds(0.2)
        unlock(engine)
        let resumed = await pull(engine, 8)
        let served = foreground + background + resumed
        // The switch flushed what the old encoder had queued: right after it, the new encoder's IDR.
        XCTAssertTrue(background.first?.isKeyframe ?? false)
        XCTAssertNotEqual(background.first?.encoderTag, foreground.last?.encoderTag)
        XCTAssertTrue(resumed.first?.isKeyframe ?? false)
        XCTAssertNotEqual(resumed.first?.encoderTag, background.last?.encoderTag)

        assertTagChangesOnlyAtIDRs(served)
        let tags = distinctTags(served)
        XCTAssertEqual(tags.count, 3, "vt-hw, vt-sw, vt-hw again: \(tags)")
        XCTAssertEqual(tags, tags.sorted(), "tags are never reused")
        XCTAssertFalse(tags.contains(0), "every frame of the engine is stamped")
        XCTAssertTrue(served.contains { !$0.isKeyframe })

        let firsts = log.lines("[switch] first ")
        XCTAssertEqual(firsts.count, 3)
        XCTAssertEqual(firsts.first, "[switch] first vt-hw IDR on the wire: \(idrBytes)b", "no switch announced the first encoder")
        XCTAssertTrue(matches(firsts[1], #"^\[switch\] first vt-sw IDR on the wire: \#(idrBytes)b, \d+\.\d\ds after the switch$"#), firsts[1])
        XCTAssertTrue(matches(firsts[2], #"^\[switch\] first vt-hw IDR on the wire: \#(idrBytes)b, \d+\.\d\ds after the switch$"#), firsts[2])
        XCTAssertTrue(log.messages.contains("[switch] vt-sw \u{2192} vt-hw: gate closed; next frame on the wire is an IDR"))
        let summary = try XCTUnwrap(log.lines("foreground \u{2192}").first)
        XCTAssertTrue(matches(summary, #"^foreground → hardware encoder, IDR forced \(background \d+s: vt-sw \d+ frames \d+ IDR 0 errors enc 1\.0ms; hold served 0\)$"#), summary)
    }

    /// An output of the replaced encoder that comes out after the switch (VideoToolbox's output
    /// thread racing the invalidation) never reaches the wire: its route is dropped first.
    func testALateOutputOfAReplacedEncoderNeverReachesTheWire() async throws {
        let factory = FakeEncoderFactory { _ in
            var b = FakeDashVideoEncoder.Behavior()
            b.lateFrameAfterInvalidate = true
            return b
        }
        let engine = makeEngine(factory)
        var served = await streamInForeground(engine, pulls: 4)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        try await Task.sleep(nanoseconds: 150_000_000) // the late P-frame of `own` comes out now
        served += await pull(engine, 4)
        unlock(engine)
        try await Task.sleep(nanoseconds: 150_000_000) // … and the late P-frame of `own-sw`
        served += await pull(engine, 4)
        assertTagChangesOnlyAtIDRs(served)
        XCTAssertEqual(distinctTags(served).count, 3, "\(distinctTags(served))")
    }

    /// L7 / L8 name the wire-dump frame (1-based) when a dump is recording.
    func testSwitchLinesNameTheDumpFrame() async throws {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ocm-bg-dump-\(UUID().uuidString).h264")
        defer { try? FileManager.default.removeItem(at: url) }
        try engine.startWireDump(to: url, maxFrames: 100)
        let log = LogCapture()
        defer { log.stop() }
        let foreground = await streamInForeground(engine, pulls: 3)
        XCTAssertEqual(foreground.count, 3)
        lock(engine)
        _ = await pull(engine, 2)
        XCTAssertEqual(log.lines("[switch] vt-hw"),
                       ["[switch] vt-hw \u{2192} vt-sw: gate closed; next frame on the wire is an IDR (dump frame #4)"])
        let first = try XCTUnwrap(log.lines("[switch] first vt-sw").first)
        XCTAssertTrue(matches(first, #"^\[switch\] first vt-sw IDR on the wire: \d+b, \d+\.\d\ds after the switch \(dump frame #4\)$"#), first)
        XCTAssertEqual(log.lines("[switch] first vt-hw"), ["[switch] first vt-hw IDR on the wire: \(idrBytes)b (dump frame #1)"])
    }

    // MARK: §6.2 item 3 — the backgroundSoftware fallback is the live encoder's IDR

    func testBackgroundSoftwareFallbackServesTheLiveEncodersIDRNotTheHoldPicture() async throws {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory)
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        let live = await pull(engine, 3)
        let tag = try XCTUnwrap(live.first?.encoderTag)
        let software = try XCTUnwrap(factory.encoders(label: "own-sw").last)
        software.setBehavior { $0.stall = true } // the encoder stops producing output
        let before = engine.stats
        var fallback: EncodedFrame?
        for _ in 0 ..< 8 {
            guard let f = await engine.nextFrame(timeout: 0.6) else { continue }
            if engine.stats.fallbackKeyframesServed > before.fallbackKeyframesServed {
                fallback = f
                break
            }
        }
        let f = try XCTUnwrap(fallback, "a pull timed out and was answered from the cache")
        XCTAssertTrue(f.isKeyframe)
        XCTAssertEqual(f.encoderTag, tag, "the live background encoder's own IDR, not the hold picture")
        XCTAssertFalse(FakeAU.isHoldPicture(f))
        XCTAssertEqual(engine.stats.holdFramesServed, before.holdFramesServed)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
    }

    // MARK: §6.2 item 4 — three failures demote to hold (L12), hold IDRs are served

    func testThreeEncodeFailuresDemoteToHoldLogL12AndServeTheHoldIDRs() async throws {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        let software = try XCTUnwrap(factory.encoders(label: "own-sw").last)
        software.setBehavior { $0.refusal = refused }
        for _ in 0 ..< 20 where engine.mode != .hold {
            _ = await engine.nextFrame(timeout: 0.5)
        }
        XCTAssertTrue(waitUntil { engine.mode == .hold })
        let demotion = "[bg] vt-sw demoted: 3 encode errors in 10s (last VTCompressionSessionEncodeFrame failed: kVTInvalidSessionErr) \u{2192} hold"
        XCTAssertEqual(log.lines("[bg] vt-sw demoted"), [demotion])
        XCTAssertEqual(log.level(demotion), .warn)
        XCTAssertTrue(log.messages.contains("[switch] vt-sw \u{2192} hold: gate closed; next frame on the wire is an IDR"))
        XCTAssertEqual(log.lines("background \u{2192} hold"), ["background \u{2192} hold (2 hold IDR(s); reason: demoted)"])
        XCTAssertEqual(log.count("[bg] enter"), 1, "L4 is not repeated by a demotion")
        XCTAssertEqual(engine.stats.demotions, 1)
        XCTAssertEqual(engine.stats.encoder, "hold")
        XCTAssertGreaterThanOrEqual(engine.stats.encoderErrors, 3)
        XCTAssertGreaterThanOrEqual(software.invalidateCount, 1)
        let held = await pull(engine, 3, timeout: 0.5)
        XCTAssertEqual(held.count, 3)
        XCTAssertTrue(held.allSatisfy { $0.encoderTag == DashProjectionEngine.holdTag && FakeAU.isHoldPicture($0) })
    }

    /// The stall rule: frames submitted, no output for 3 s → demoted (`no output for 3s`).
    func testAnEncoderThatStopsOutputtingIsDemoted() async throws {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory)
        engine.backgroundStatusInterval = 0.25
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        try XCTUnwrap(factory.encoders(label: "own-sw").last).setBehavior { $0.stall = true }
        _ = await pull(engine, 3, timeout: 0.5)
        XCTAssertTrue(waitUntil(6) { engine.mode == .hold })
        XCTAssertEqual(log.lines("[bg] vt-sw demoted"), ["[bg] vt-sw demoted: no output for 3s \u{2192} hold"])
    }

    /// A synchronous encoder outputs inside `encode`: when the dash stops pulling (the queue is full,
    /// nothing more is encoded) that must not look like a stall.
    func testAHealthySynchronousEncoderIsNotDemotedWhileTheDashPausesPulling() async {
        let engine = makeEngine(FakeEncoderFactory())
        engine.backgroundStatusInterval = 0.25
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        _ = await pull(engine, 2)
        await sleepSeconds(3.6) // no pulls: the queue fills, the encoder idles
        XCTAssertEqual(log.count("[bg] vt-sw demoted"), 0)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        let resumed = await pull(engine, 3)
        XCTAssertEqual(resumed.count, 3)
    }

    // MARK: retry from a demoted hold (L12), at most 3 per background period

    func testRetryAfterADemotionAtMostThreeTimesPerBackgroundPeriod() async throws {
        let clock = SteppedClock()
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory, clock: clock)
        engine.backgroundStatusInterval = 0.1
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        factory.setBehavior { r in
            var b = FakeDashVideoEncoder.Behavior()
            if r.software { b.configureFailure = notCreated } // every retry is rejected
            return b
        }
        try XCTUnwrap(factory.encoders(label: "own-sw").last).setBehavior { $0.refusal = refused }
        for _ in 0 ..< 20 where engine.mode != .hold {
            _ = await engine.nextFrame(timeout: 0.5)
        }
        XCTAssertTrue(waitUntil { engine.mode == .hold })
        await sleepSeconds(0.4)
        XCTAssertEqual(log.count("[bg] retry ladder"), 0, "not before 60 s")
        for attempt in 1 ... 3 {
            clock.advance(61)
            XCTAssertTrue(log.wait("[bg] retry ladder", count: attempt), "attempt \(attempt)")
            XCTAssertTrue(log.wait("background \u{2192} hold", count: attempt + 1))
        }
        XCTAssertEqual(log.lines("[bg] retry ladder"), (1 ... 3).map { "[bg] retry ladder (60s after the demotion, attempt \($0)/3)" })
        XCTAssertEqual(log.count("[bg] enter"), 4, "L4 at the entry and at every retry")
        XCTAssertEqual(log.lines("background \u{2192} hold"), Array(repeating: "background \u{2192} hold (2 hold IDR(s); reason: demoted)", count: 4))
        clock.advance(61)
        await sleepSeconds(0.5)
        XCTAssertEqual(log.count("[bg] retry ladder"), 3, "at most 3 retries per background period")
        XCTAssertEqual(engine.mode, .hold)
    }

    func testARetryCanBringTheBackgroundEncoderBack() async throws {
        let clock = SteppedClock()
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory, clock: clock)
        engine.backgroundStatusInterval = 0.1
        engine.backgroundDryRun = true // runs in the demoted hold, ends when the encoder is back
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        try XCTUnwrap(factory.encoders(label: "own-sw").last).setBehavior { $0.refusal = refused }
        for _ in 0 ..< 20 where engine.mode != .hold {
            _ = await engine.nextFrame(timeout: 0.5)
        }
        XCTAssertTrue(waitUntil { engine.mode == .hold })
        clock.advance(61)
        XCTAssertTrue(waitUntil { engine.mode == .backgroundSoftware })
        XCTAssertEqual(log.lines("[bg] retry ladder"), ["[bg] retry ladder (60s after the demotion, attempt 1/3)"])
        XCTAssertTrue(log.messages.contains("[switch] hold \u{2192} vt-sw: gate closed; next frame on the wire is an IDR"))
        XCTAssertEqual(log.count("[bg-probe] dry run ended"), 1, "the dry run stops when the hold ends")
        let frames = await pull(engine, 3)
        XCTAssertTrue(frames.first?.isKeyframe ?? false)
        XCTAssertFalse(frames.contains(where: FakeAU.isHoldPicture))
    }

    /// A hold reached because every rung was rejected at the entry is not retried.
    func testAHoldOfRejectedRungsIsNotRetried() async {
        let clock = SteppedClock()
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            if r.software { b.usesHardware = true }
            return b
        }
        let engine = makeEngine(factory, clock: clock)
        engine.backgroundStatusInterval = 0.1
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .hold)
        clock.advance(61)
        await sleepSeconds(0.5)
        XCTAssertEqual(log.count("[bg] retry ladder"), 0)
        XCTAssertEqual(log.count("[bg] enter"), 1)
    }

    // MARK: §6.2 item 6 — a canvas change while backgrounded

    func testCanvasChangeWhileBackgroundedRebuildsTheCurrentRungAndNeverTheHardwareEncoder() async throws {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        let old = try XCTUnwrap(factory.encoders(label: "own-sw").last)
        let before = factory.requests.count
        engine.prepare(canvas: VideoCanvas(width: 1280, height: 576), parameters: parameters) // REQ 16 while locked
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        XCTAssertEqual(factory.requests.dropFirst(before).map(\.label), ["own-sw"], "the current rung, rebuilt")
        XCTAssertFalse(factory.requests.dropFirst(1).contains { !$0.software }, "never the hardware encoder in the background")
        XCTAssertGreaterThanOrEqual(old.invalidateCount, 1)
        XCTAssertEqual(factory.encoders(label: "own-sw").last?.configuredSize?.width, 1280)
        XCTAssertEqual(log.lines("[bg] enter").last,
                       "[bg] enter: canvas 1280x576 policy=vtsw rungs=vt-sw,hold last-live-idr=none hold-idrs=0")
        XCTAssertTrue(log.messages.contains("[switch] vt-sw \u{2192} vt-sw: gate closed; next frame on the wire is an IDR"))
        engine.resynchronize() // the dash's 112
        let frames = await pull(engine, 3)
        let idr = try XCTUnwrap(frames.first)
        XCTAssertTrue(idr.isKeyframe)
        XCTAssertEqual(H264SPS.parse(accessUnit: idr.accessUnit).map { [$0.width, $0.height] }, [1280, 576])
    }

    func testCanvasChangeInHoldRunsTheWholeLadderAndNeverTheHardwareEncoder() async throws {
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            if r.software { b.usesHardware = true }
            return b
        }
        let engine = makeEngine(factory)
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .hold)
        factory.setBehavior { _ in FakeDashVideoEncoder.Behavior() }
        engine.prepare(canvas: VideoCanvas(width: 1280, height: 576), parameters: parameters)
        XCTAssertEqual(engine.mode, .backgroundSoftware, "no rung was live: the whole ladder ran at the new size")
        XCTAssertFalse(factory.requests.dropFirst(1).contains { !$0.software })
        XCTAssertEqual(engine.stats.encoder, "vt-sw")
    }

    // MARK: §6.2 item 8 — a wrong-size SPS is rejected before anything is served

    func testWrongSizeSPSIsRejectedBeforeAnythingOfItIsServed() async throws {
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            if r.software { b.sps = FakeAU.sps1280x576 }
            return b
        }
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .hold)
        XCTAssertTrue(H264StreamCheck.check(accessUnit: FakeAU.idr(sps: FakeAU.sps1280x576, 0), canvas: canvas,
                                            requireKeyframe: true).contains(.size(width: 1280, height: 576)))
        let attempt = try XCTUnwrap(log.lines("[bg] try vt-sw (fresh)").first)
        XCTAssertTrue(attempt.contains(" sps=size-1280x576") || attempt.contains(",size-1280x576"), attempt)
        XCTAssertTrue(attempt.contains("\u{2192} rejected: sps: "), attempt)
        XCTAssertEqual(log.lines("background \u{2192}"), ["background \u{2192} hold (2 hold IDR(s); reason: all rungs rejected)"])
        let held = await pull(engine, 3, timeout: 0.5)
        XCTAssertEqual(held.count, 3)
        for f in held {
            XCTAssertEqual(f.encoderTag, DashProjectionEngine.holdTag)
            XCTAssertEqual(H264SPS.parse(accessUnit: f.accessUnit).map { [$0.width, $0.height] }, [800, 384])
        }
    }

    // MARK: §6.2 item 9 — hw=nil is accepted with a probe IDR (and only with one)

    func testUnknownHardwareFlagIsAcceptedWithAProbeIDR() async {
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            if r.software { b.usesHardware = nil }
            return b
        }
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        XCTAssertEqual(log.lines("[bg] try ").map(normalized),
                       ["[bg] try vt-sw (fresh): create=noErr hw=? probe=IDR \(idrBytes)b in Nms sps=ok \u{2192} accepted"])
        let first = await pull(engine, 1).first
        XCTAssertEqual(first?.isKeyframe, true)
        XCTAssertEqual(first?.sequence, 1, "the accepted probe IDR is the new encoder's first frame on the wire")
    }

    func testUnknownHardwareFlagWithoutAProbeIDRIsRejected() async {
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            if r.software { b.usesHardware = nil; b.stall = true }
            return b
        }
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .hold)
        XCTAssertEqual(log.lines("[bg] try "),
                       ["[bg] try vt-sw (fresh): create=noErr hw=? probe=none in 500ms sps=- \u{2192} rejected: probe=none"])
    }

    /// An asynchronous (VideoToolbox-like) encoder: the probe waits for the IDR.
    func testAnAsynchronousEncodersProbeIDRIsAwaited() async {
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            b.outputDelay = 0.03
            if r.software { b.usesHardware = nil }
            return b
        }
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        var served = await streamInForeground(engine, pulls: 5)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        XCTAssertEqual(log.lines("[bg] try ").map(normalized),
                       ["[bg] try vt-sw (fresh): create=noErr hw=? probe=IDR \(idrBytes)b in Nms sps=ok \u{2192} accepted"])
        served += await pull(engine, 5)
        assertTagChangesOnlyAtIDRs(served)
        XCTAssertEqual(distinctTags(served).count, 2)
    }

    // MARK: §6.2 item 11 — L9 every interval while backgrounded (also in hold)

    func testStatusLineEveryIntervalInHoldAndNotInTheForeground() async {
        let engine = makeEngine(FakeEncoderFactory(), policy: .holdOnly)
        engine.backgroundStatusInterval = 0.2
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .hold)
        XCTAssertEqual(log.count("[bg] +"), 0, "the first line comes one interval after the entry")
        await sleepSeconds(1.1)
        let lines = log.lines("[bg] +")
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        XCTAssertLessThanOrEqual(lines.count, 7)
        let pattern = #"^\[bg\] \+\d+s mode=hold enc=hold cap=- out=\d+\.\dfps pulls=\d+\.\d/s served=\d+ \(hold \d+, fallback \d+, none \d+\) errs=0 render=\d+\.\dms enc=- cpu=(\?|\d+%) thermal=none lowPower=false q=\d+$"#
        for line in lines { XCTAssertTrue(matches(line, pattern), line) }
        unlock(engine)
        let count = log.count("[bg] +")
        await sleepSeconds(0.6)
        XCTAssertEqual(log.count("[bg] +"), count, "no status line in the foreground")
        XCTAssertTrue(matches(try XCTUnwrap(log.lines("foreground \u{2192}").first),
                              #"^foreground → hardware encoder, IDR forced \(background \d+s: hold served \d+\)$"#))
    }

    func testStatusLineWithABackgroundEncoderAndItsCounters() async throws {
        let engine = makeEngine(FakeEncoderFactory())
        engine.backgroundStatusInterval = 0.3
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        _ = await pull(engine, 6)
        XCTAssertTrue(log.wait("[bg] +", count: 2))
        let line = try XCTUnwrap(log.lines("[bg] +").last)
        XCTAssertTrue(matches(line, #"^\[bg\] \+\d+s mode=backgroundSoftware enc=vt-sw cap=8fps out=\d+\.\dfps pulls=\d+\.\d/s served=\d+ \(hold 0, fallback \d+, none \d+\) errs=0 render=\d+\.\dms enc=1\.0ms cpu=(\?|\d+%) thermal=none lowPower=false q=\d+$"#), line)
        let served = try XCTUnwrap(line.range(of: #"served=\d+"#, options: .regularExpression).map { Int(line[$0].dropFirst(7)) ?? -1 })
        XCTAssertGreaterThanOrEqual(served, 1, "pulls of this background period only")
        XCTAssertLessThanOrEqual(served, 6 + 1)
        // Stats for the port summary.
        let stats = engine.stats
        XCTAssertEqual(stats.encoder, "vt-sw")
        XCTAssertEqual(stats.backgroundFpsCap, 8)
        XCTAssertGreaterThan(stats.backgroundSeconds, 0)
        XCTAssertEqual(stats.demotions, 0)
        unlock(engine)
        let foreground = engine.stats
        XCTAssertEqual(foreground.encoder, "vt-hw")
        XCTAssertNil(foreground.backgroundFpsCap)
        XCTAssertEqual(foreground.backgroundSeconds, 0)
    }

    func testStopEndsTheBackgroundWorkAndInvalidatesTheBackgroundEncoder() async throws {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory)
        engine.backgroundStatusInterval = 0.1
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        XCTAssertTrue(log.wait("[bg] +"))
        engine.stop()
        let software = try XCTUnwrap(factory.encoders(label: "own-sw").last)
        XCTAssertGreaterThanOrEqual(software.invalidateCount, 1)
        XCTAssertNil(engine.stats.encoder)
        let count = log.count("[bg] +")
        await sleepSeconds(0.4)
        XCTAssertEqual(log.count("[bg] +"), count, "no status line after stop()")
    }

    // MARK: pre-warm (P0-4, L3): the probe never reaches the frame queue

    func testPreWarmProbeNeverReachesTheFrameQueueAndTheLadderTakesTheSession() async throws {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        var served = await streamInForeground(engine)
        let hardwareTag = try XCTUnwrap(served.first?.encoderTag)
        engine.prepareBackgroundEncoder() // .inactive
        XCTAssertTrue(log.wait("[bg] pre-warm"))
        XCTAssertEqual(log.lines("[bg] pre-warm").map(normalized),
                       ["[bg] pre-warm vt-sw at inactive: create=noErr hw=false probe=IDR \(idrBytes)b in Nms"])
        let preWarmed = try XCTUnwrap(factory.encoders(label: "own-sw-pre").first)
        XCTAssertEqual(preWarmed.encodeCount, 1)
        XCTAssertEqual(preWarmed.forcedCount, 1, "the probe is a forced IDR")
        served += await pull(engine, 6) // still the foreground
        XCTAssertEqual(Set(served.map(\.encoderTag)), [hardwareTag], "nothing of the probe went to the dash")
        XCTAssertEqual(engine.frameQueue.lastKeyframe?.encoderTag, hardwareTag)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        XCTAssertEqual(log.lines("[bg] try ").map(normalized),
                       ["[bg] try vt-sw (pre-warmed): create=noErr hw=false probe=IDR \(idrBytes)b in Nms sps=ok \u{2192} accepted"])
        XCTAssertTrue(factory.encoders(label: "own-sw").isEmpty, "no fresh session was needed")
        XCTAssertGreaterThanOrEqual(preWarmed.forcedCount, 2, "probed again at .background")
        let background = await pull(engine, 3)
        XCTAssertEqual(distinctTags(background), [hardwareTag + 1], "the pre-warmed session's tag")
        XCTAssertTrue(background.first?.isKeyframe ?? false)
    }

    /// The `.inactive` probe's IDR comes out late, while the `.background` probe of the same session
    /// waits: it is not taken for it (it was encoded in the foreground); the background probe's own
    /// IDR decides and is the first frame on the wire.
    func testALateOutputOfThePreWarmProbeIsNotTakenForTheBackgroundProbe() async throws {
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            if r.label == "own-sw-pre" { b.outputDelays = [0.45, 0.2] }
            return b
        }
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        engine.prepareBackgroundEncoder()
        XCTAssertTrue(log.wait("[bg] pre-warm"))
        XCTAssertEqual(log.lines("[bg] pre-warm"), ["[bg] pre-warm vt-sw at inactive: create=noErr hw=false probe=none in 300ms"])
        lock(engine) // its probe waits up to 500 ms; the first probe's IDR comes out meanwhile
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        XCTAssertEqual(log.lines("[bg] try ").first.map(normalized),
                       "[bg] try vt-sw (pre-warmed): create=noErr hw=false probe=IDR \(idrBytes)b in Nms sps=ok \u{2192} accepted")
        let first = await pull(engine, 1).first
        XCTAssertEqual(first?.isKeyframe, true)
        XCTAssertEqual(first?.sequence, 2, "the IDR of the background probe, not the late .inactive one")
    }

    func testPreWarmedSessionIsDroppedWhenTheAppBecomesActiveFirst() async throws {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        engine.prepareBackgroundEncoder()
        XCTAssertTrue(log.wait("[bg] pre-warm"))
        engine.enterForeground() // Control Center closed: active again, never backgrounded
        let preWarmed = try XCTUnwrap(factory.encoders(label: "own-sw-pre").first)
        XCTAssertTrue(waitUntil { preWarmed.invalidateCount >= 1 })
        lock(engine)
        XCTAssertEqual(log.lines("[bg] try ").map { $0.prefix(23) }, ["[bg] try vt-sw (fresh):"])
        XCTAssertEqual(engine.mode, .backgroundSoftware)
    }

    func testNoPreWarmWithoutAVideoToolboxSoftwareRung() async {
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory, policy: .holdOnly)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        engine.prepareBackgroundEncoder()
        _ = await pull(engine, 2)
        XCTAssertEqual(log.count("[bg] pre-warm"), 0)
        XCTAssertTrue(factory.encoders(label: "own-sw-pre").isEmpty)
    }

    // MARK: dry run (P0-8, L10): only in hold, never served, ends after its duration

    func testDryRunRunsOnlyInHoldIsNeverServedAndEndsAfterTenMinutes() async throws {
        let clock = SteppedClock()
        let factory = FakeEncoderFactory()
        let engine = makeEngine(factory, policy: .holdOnly, clock: clock)
        engine.backgroundDryRun = true
        let lists = Locked(0)
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        engine.displayListProvider = { _ in
            lists.withLock { $0 += 1 }
            return DashDisplayList(size: DashSize(width: 800, height: 384), background: DashColor(rgb: 0x203040))
        }
        lock(engine)
        XCTAssertEqual(engine.mode, .hold)
        let callsAtLock = lists.current
        let rendered = engine.stats.renderedFrames
        await sleepSeconds(0.6)
        XCTAssertGreaterThanOrEqual(lists.current - callsAtLock, 2, "the live UI is rendered at 8 fps in hold")
        let held = await pull(engine, 2, timeout: 0.5)
        XCTAssertTrue(held.allSatisfy { $0.encoderTag == DashProjectionEngine.holdTag }, "the dash still gets the hold picture")
        XCTAssertEqual(engine.stats.renderedFrames, rendered, "dry-run renders are not counted as served pictures")
        XCTAssertEqual(log.count("[bg-probe]"), 0, "L10 every 60 s")
        clock.advance(60.5)
        XCTAssertTrue(log.wait("[bg-probe] render="))
        let report = try XCTUnwrap(log.lines("[bg-probe] render=").first)
        XCTAssertTrue(matches(report, #"^\[bg-probe\] render=\d+\.\dms convert=\d+\.\dms load=\d+ms n=\d+ cpu=(\?|\d+%)$"#), report)
        clock.advance(540)
        XCTAssertTrue(log.wait("[bg-probe] dry run ended"))
        let ended = log.lines("[bg-probe] dry run ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertTrue(matches(try XCTUnwrap(ended.first), #"^\[bg-probe\] dry run ended after 10m0\ds$"#), "\(ended)")
        let callsAtEnd = lists.current
        await sleepSeconds(0.4)
        XCTAssertLessThanOrEqual(lists.current - callsAtEnd, 1, "no more dry-run renders")
        XCTAssertEqual(engine.frameQueue.pendingCount, 0, "nothing of the dry run reached the frame queue")
    }

    func testDryRunNeverRunsWithABackgroundEncoderAndEndsAtUnlock() async throws {
        let log = LogCapture()
        defer { log.stop() }
        let live = makeEngine(FakeEncoderFactory())
        live.backgroundDryRun = true
        live.dryRunReportInterval = 0.2
        _ = await streamInForeground(live)
        lock(live)
        XCTAssertEqual(live.mode, .backgroundSoftware)
        await sleepSeconds(0.6)
        unlock(live)
        XCTAssertEqual(log.count("[bg-probe]"), 0, "no dry run while a background encoder feeds the dash")
        let held = makeEngine(FakeEncoderFactory(), policy: .holdOnly)
        held.backgroundDryRun = true
        held.dryRunReportInterval = 0.2
        _ = await streamInForeground(held)
        lock(held)
        XCTAssertEqual(held.mode, .hold)
        XCTAssertTrue(log.wait("[bg-probe] render="), "the hold engine runs it")
        unlock(held)
        XCTAssertTrue(log.wait("[bg-probe] dry run ended"))
        XCTAssertEqual(log.count("[bg-probe] dry run ended"), 1, "ended once, at unlock")
        XCTAssertTrue(matches(try XCTUnwrap(log.lines("[bg-probe] dry run ended").first), #"^\[bg-probe\] dry run ended after \d+s$"#))
    }

    // MARK: rung 2 through cpuEncoderFactory (Phase 1 seam; the Phase 0 app leaves it nil)

    func testCPUFactoryAddsTheSecondRung() async throws {
        let cpu = Locked<[FakeDashVideoEncoder]>([])
        let engine = makeEngine(FakeEncoderFactory(), policy: .cpuOnly)
        engine.cpuEncoderFactory = { label in
            let e = FakeDashVideoEncoder(label: label, kind: .cpu(backend: "fake"))
            cpu.withLock { $0.append(e) }
            return e
        }
        let log = LogCapture()
        defer { log.stop() }
        _ = await streamInForeground(engine)
        lock(engine)
        XCTAssertEqual(engine.mode, .backgroundSoftware)
        XCTAssertEqual(log.lines("[bg] enter"),
                       ["[bg] enter: canvas 800x384 policy=cpu rungs=cpu-fake,hold last-live-idr=\(idrBytes)b hold-idrs=2"])
        XCTAssertEqual(log.lines("[bg] try ").map(normalized),
                       ["[bg] try cpu-fake: configure=ok probe=IDR \(idrBytes)b in Nms sps=ok \u{2192} accepted"])
        XCTAssertEqual(log.lines("background \u{2192}"), ["background \u{2192} backgroundSoftware @8fps (encoder cpu-fake, 3375kbps)"])
        XCTAssertEqual(cpu.current.map(\.label), ["own-cpu"])
        XCTAssertEqual(engine.stats.encoder, "cpu-fake")
        engine.stop()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(cpu.current.first).invalidateCount, 1)
    }

    // MARK: L2 — the encoder list, once per run, at the first foreground prepare

    func testEncoderListIsLoggedOnceAtTheFirstForegroundPrepare() async {
        DashProjectionEngine.resetEncoderListLogForTesting()
        let list = [BackgroundLog.EncoderListEntry(id: "com.example.a", name: "A", isHardwareAccelerated: true),
                    BackgroundLog.EncoderListEntry(id: "com.example.b", name: "B", isHardwareAccelerated: nil)]
        let log = LogCapture()
        defer { log.stop() }
        let first = makeEngine(FakeEncoderFactory(), encoderList: list)
        _ = await streamInForeground(first, pulls: 1)
        XCTAssertTrue(log.wait("[vt-list]"))
        let second = makeEngine(FakeEncoderFactory(), encoderList: list)
        _ = await streamInForeground(second, pulls: 1)
        await sleepSeconds(0.3)
        XCTAssertEqual(log.lines("[vt-list]"), ["[vt-list] avc1 encoders: com.example.a name=A hw=true; com.example.b name=B hw=?"])
    }

    // MARK: the policy alias

    func testAllowsSoftwareEncodingInBackgroundIsAnAliasOfThePolicy() {
        let engine = DashProjectionEngine()
        XCTAssertEqual(engine.lockedStreamPolicy, .automatic)
        XCTAssertTrue(engine.allowsSoftwareEncodingInBackground)
        engine.allowsSoftwareEncodingInBackground = false
        XCTAssertEqual(engine.lockedStreamPolicy, .holdOnly)
        engine.allowsSoftwareEncodingInBackground = true
        XCTAssertEqual(engine.lockedStreamPolicy, .automatic)
        engine.lockedStreamPolicy = .videoToolboxSoftwareOnly
        engine.allowsSoftwareEncodingInBackground = true
        XCTAssertEqual(engine.lockedStreamPolicy, .videoToolboxSoftwareOnly, "true keeps a non-hold policy")
        XCTAssertTrue(engine.allowsSoftwareEncodingInBackground)
        engine.lockedStreamPolicy = .holdOnly
        XCTAssertFalse(engine.allowsSoftwareEncodingInBackground)
    }
}
#endif
