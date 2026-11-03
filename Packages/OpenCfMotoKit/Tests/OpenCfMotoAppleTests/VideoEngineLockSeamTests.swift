// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 — integration on the engine side of the seams:
// - the engine driven by exactly the calls ProjectionAdapter forwards for a lock cycle (the sequences
//   LockSeamIntegrationTests pins on the app-model side: `.inactive` → prepareHoldPicture(expectedCanvas:)
//   then prepareBackgroundEncoder(); `.background` → enterBackground(); `.active` → enterForeground()) tells
//   the whole engine half of the Phase 0 log story in order (L8, L3, L4, L5, L7, L6, L8, L9, L7, L13, L8;
//   L10 in hold), and fills the `DashProjectionStats` fields the adapter maps into the `[lock]` line (L15);
// - the vImage BGRA → I420 converter (Apple) against Core's integer reference (`BGRAToI420.reference`),
//   within ±2 on every plane, also on IOSurface pool buffers with padded rows;
// - the real VideoToolbox encoders' first IDR against Core's `H264StreamCheck` at the 450MT canvas.
// No VideoToolbox is needed for the first group (FakeDashVideoEncoder through the engine's test seams).
#if canImport(VideoToolbox) && canImport(CoreGraphics) && canImport(CoreText)
import CoreVideo
import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

/// Every `VIDEO` line logged while it is subscribed, in order.
private final class VideoLines: @unchecked Sendable {
    private let captured = Locked<[String]>([])
    private var token: UUID?

    init() {
        token = Log.shared.subscribe { [captured] line in
            if line.tag == "VIDEO" { captured.withLock { $0.append(line.message) } }
        }
    }

    func stop() {
        if let token { Log.shared.unsubscribe(token) }
        token = nil
    }

    var all: [String] { captured.current }
    func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }

    /// The first line after `index` starting with each prefix in turn; nil (and a failure) when one is
    /// missing or out of order.
    func inOrder(_ prefixes: [String], file: StaticString = #filePath, line: UInt = #line) -> [String]? {
        var found: [String] = []
        var index = 0
        let lines = all
        for prefix in prefixes {
            guard let i = lines[index...].firstIndex(where: { $0.hasPrefix(prefix) }) else {
                XCTFail("no `\(prefix)` after line \(index) of:\n\(lines.joined(separator: "\n"))", file: file, line: line)
                return nil
            }
            found.append(lines[i])
            index = i + 1
        }
        return found
    }
}

final class VideoEngineLockSeamTests: XCTestCase {
    private let canvas = VideoCanvas(width: 800, height: 384, requestedWidth: 800, requestedHeight: 386)
    private let parameters = EncoderParameters(bitrate: 3_375_000, frameRate: 24)
    private var engines: [DashProjectionEngine] = []

    override func tearDown() {
        for engine in engines { engine.stop() }
        engines = []
        super.tearDown()
    }

    /// The Phase 0 app's engine (ProjectionAdapter): policy vtsw, the dry run on, no CPU encoder, a
    /// battery provider — with fake encoders behind the test seams.
    private func makeAppEngine(_ factory: FakeEncoderFactory,
                               encoderList: [BackgroundLog.EncoderListEntry]) -> DashProjectionEngine {
        let engine = DashProjectionEngine()
        engines.append(engine)
        engine.secondKeyframeDelay = nil
        engine.lockedStreamPolicy = .videoToolboxSoftwareOnly
        engine.backgroundDryRun = true
        engine.batteryProvider = { BatteryStatus(level: 0.63, state: .charging) }
        XCTAssertNil(engine.cpuEncoderFactory, "Phase 0: no rung 2")
        engine.encoderFactory = { factory.make($0) }
        engine.encoderListProvider = { encoderList }
        engine.softwareEncodingAvailable = { true }
        engine.holdFramesEncoder = { _, _, _, _ in FakeAU.holdFrames() }
        engine.backgroundStatusInterval = 0.25
        engine.dryRunReportInterval = 0.3
        engine.displayListProvider = { now in
            DashDisplayList(size: DashSize(width: 800, height: 384), background: DashColor(rgb: 0x101418), commands: [
                .fill(.rect(DashRect(x: (now * 300).truncatingRemainder(dividingBy: 700), y: 100, width: 80, height: 80)),
                      DashColor(rgb: 0x1A73E8), .nonZero),
            ])
        }
        return engine
    }

    private func pull(_ engine: DashProjectionEngine, _ count: Int) async -> [EncodedFrame] {
        var frames: [EncodedFrame] = []
        for _ in 0 ..< count {
            if let f = await engine.nextFrame(timeout: 1.5) { frames.append(f) }
        }
        return frames
    }

    /// RideModel at `.inactive` through ProjectionAdapter: the hold picture at the canvas, then the pre-warm.
    private func inactive(_ engine: DashProjectionEngine, file: StaticString = #filePath, line: UInt = #line) {
        let built = Locked<Bool?>(nil)
        engine.prepareHoldPicture(expectedCanvas: canvas) { ok in built.set(ok) }
        engine.prepareBackgroundEncoder()
        XCTAssertTrue(eventually { built.current != nil }, file: file, line: line)
        XCTAssertEqual(built.current, true, "hold picture", file: file, line: line)
    }

    // MARK: the engine half of the log story, and the `[lock]` line's stats

    func testTheAdaptersLockCycleTellsTheEngineStoryAndFillsTheLockLineStats() async throws {
        XCTAssertEqual([DashProjectionEngine.Mode.idle, .foreground, .backgroundSoftware, .hold, .stopped].map(\.rawValue),
                       ["idle", "foreground", "backgroundSoftware", "hold", "stopped"],
                       "the `mode=` of the [bg] line; ProjectionAdapter maps backgroundSoftware to background-software")
        DashProjectionEngine.resetEncoderListLogForTesting()
        let factory = FakeEncoderFactory()
        let engine = makeAppEngine(factory, encoderList: [
            BackgroundLog.EncoderListEntry(id: "com.example.hw.h264", name: "Example H.264 (HW)", isHardwareAccelerated: true),
            BackgroundLog.EncoderListEntry(id: "com.example.sw.h264", name: "Example H.264", isHardwareAccelerated: false),
        ])
        let log = VideoLines()
        defer { log.stop() }

        // Foreground: the dash connects and pulls (REQ 16, 112, 114 …).
        engine.prepare(canvas: canvas, parameters: parameters)
        engine.resynchronize()
        var wire = await pull(engine, 4)
        XCTAssertTrue(eventually { log.count("[vt-list] ") == 1 }, "L2 once, at the first foreground prepare")
        let foreground = engine.stats
        XCTAssertEqual(foreground.mode, .foreground)
        XCTAssertEqual(foreground.encoder, "vt-hw")
        XCTAssertNil(foreground.backgroundFpsCap)
        XCTAssertEqual(foreground.backgroundSeconds, 0)

        // The side button: .inactive, then .background.
        inactive(engine)
        XCTAssertTrue(eventually { log.count("[bg] pre-warm") == 1 })
        engine.enterBackground()
        XCTAssertTrue(eventually { engine.mode == .backgroundSoftware })
        wire += await pull(engine, 8)
        XCTAssertTrue(eventually { log.count("[bg] +") >= 2 }, "L9 every status interval")
        let locked = engine.stats
        XCTAssertEqual(locked.mode, .backgroundSoftware)
        XCTAssertEqual(locked.encoder, "vt-sw", "the [lock] line's encoder")
        XCTAssertEqual(locked.backgroundFpsCap, 8)
        XCTAssertGreaterThan(locked.backgroundSeconds, 0)
        XCTAssertGreaterThan(locked.pullRate, 0, "the [lock] line's pulls=")
        XCTAssertGreaterThan(locked.outputFPS, 0, "the [lock] line's fps")
        XCTAssertNotNil(locked.cpuPercent, "measured by the status timer")
        XCTAssertEqual(locked.demotions, 0)
        XCTAssertEqual(locked.encoderErrors, 0)
        XCTAssertEqual(locked.holdFramesServed, 0, "the live map, not the hold picture")
        XCTAssertEqual(log.count("[bg-probe]"), 0, "no dry run while a background encoder feeds the dash")

        // The unlock: .inactive (nothing), .active.
        engine.enterForeground()
        XCTAssertTrue(eventually { engine.mode == .foreground })
        wire += await pull(engine, 3)
        XCTAssertTrue(eventually { log.count("[switch] first vt-hw IDR") == 2 && log.count("foreground \u{2192} ") == 1 })
        XCTAssertTrue(eventually { engine.stats.backgroundSeconds == 0 }, "the background period ended")
        let unlocked = engine.stats
        XCTAssertEqual(unlocked.encoder, "vt-hw")
        XCTAssertNil(unlocked.backgroundFpsCap)
        XCTAssertEqual(unlocked.backgroundSeconds, 0)

        // The lines in the order they are logged (the first frame of each encoder is pushed only after
        // its L6; at the unlock a pull may serve the new IDR, L8, before L13 is written).
        let story = try XCTUnwrap(log.inOrder([
            "[switch] first vt-hw IDR on the wire: ",                                   // L8, foreground
            "hold picture ready at 800x384: 2 IDR(s)",                                   // .inactive
            "[bg] pre-warm vt-sw at inactive: create=noErr hw=false probe=IDR ",        // L3
            "[bg] enter: canvas 800x384 policy=vtsw rungs=vt-sw,hold last-live-idr=",   // L4
            "[bg] try vt-sw (pre-warmed): create=noErr hw=false probe=IDR ",            // L5
            "[switch] vt-hw \u{2192} vt-sw: gate closed; next frame on the wire is an IDR", // L7
            "background \u{2192} backgroundSoftware @8fps (encoder vt-sw, 3375kbps)",   // L6
            "[switch] first vt-sw IDR on the wire: ",                                   // L8
            "[switch] vt-sw \u{2192} vt-hw: gate closed",                                // L7
            "foreground \u{2192} hardware encoder, IDR forced (background ",             // L13
        ]))
        XCTAssertTrue(story[3].hasSuffix(" hold-idrs=2"), story[3])
        XCTAssertTrue(story[4].hasSuffix(" sps=ok \u{2192} accepted"), story[4])
        XCTAssertTrue(story[9].contains(": vt-sw ") && story[9].contains(" frames ") && story[9].hasSuffix("; hold served 0)"),
                      story[9])
        let statusLines = log.all.filter { $0.hasPrefix("[bg] +") }
        XCTAssertTrue(statusLines.allSatisfy { $0.contains(" mode=backgroundSoftware enc=vt-sw cap=8fps ") }, "\(statusLines)")
        XCTAssertEqual(log.count("[bg] try "), 1, "the pre-warmed session was accepted at once")
        XCTAssertEqual(log.count("[vt-list] "), 1)
        // Every encoder change on the wire is an IDR (P0-6), and the hold picture never reached it.
        XCTAssertTrue(wire.first?.isKeyframe ?? false)
        for (a, b) in zip(wire, wire.dropFirst()) where a.encoderTag != b.encoderTag {
            XCTAssertTrue(b.isKeyframe, "tag \(a.encoderTag) → \(b.encoderTag) on a P-frame")
        }
        XCTAssertFalse(wire.contains { FakeAU.isHoldPicture($0) })
        XCTAssertEqual(Set(wire.map(\.encoderTag)).count, 3, "vt-hw, vt-sw, vt-hw again (three encoder instances)")
    }

    /// The software session is refused (the outcome Gate G0 calls G0-b): the hold picture answers the
    /// pulls, the dry run measures the background CPU path, and the `[lock]` line reads `dash=hold hold`.
    func testTheHoldStoryWhenEveryRungIsRejected() async throws {
        let factory = FakeEncoderFactory { r in
            var b = FakeDashVideoEncoder.Behavior()
            if r.software { b.usesHardware = true } // VideoToolbox handed back a hardware session
            return b
        }
        let engine = makeAppEngine(factory, encoderList: [
            BackgroundLog.EncoderListEntry(id: "com.example.sw.h264", name: "Example H.264", isHardwareAccelerated: false),
        ])
        let log = VideoLines()
        defer { log.stop() }
        engine.prepare(canvas: canvas, parameters: parameters)
        engine.resynchronize()
        var wire = await pull(engine, 3)
        inactive(engine)
        XCTAssertTrue(eventually { log.count("[bg] pre-warm") == 1 })
        engine.enterBackground()
        XCTAssertTrue(eventually { engine.mode == .hold })
        wire += await pull(engine, 4)
        XCTAssertTrue(eventually(3) { log.count("[bg-probe] render=") >= 1 && log.count("[bg] +") >= 1 })
        let held = engine.stats
        XCTAssertEqual(held.mode, .hold)
        XCTAssertEqual(held.encoder, "hold")
        XCTAssertNil(held.backgroundFpsCap)
        XCTAssertGreaterThanOrEqual(held.holdFramesServed, 4)
        XCTAssertGreaterThan(held.pullRate, 0, "published by the status timer (no render loop in hold)")
        XCTAssertNotNil(held.cpuPercent)

        let story = try XCTUnwrap(log.inOrder([
            "[bg] pre-warm vt-sw at inactive: create=noErr hw=true probe=IDR ",
            "[bg] enter: canvas 800x384 policy=vtsw rungs=vt-sw,hold ",
            "[bg] try vt-sw (pre-warmed): create=noErr hw=true ",
            "[bg] try vt-sw (fresh): create=noErr hw=true ",
            "[bg] try vt-sw (id=com.example.sw.h264): create=noErr hw=true ",
            "[switch] vt-hw \u{2192} hold: gate closed",
            "background \u{2192} hold (2 hold IDR(s); reason: all rungs rejected)",
            "[switch] first hold IDR on the wire: ",
            "[bg-probe] render=",
        ]))
        XCTAssertTrue(story[2].hasSuffix("\u{2192} rejected: hw=true"), story[2])
        XCTAssertTrue(log.all.contains { $0.hasPrefix("[bg] +") && $0.contains(" mode=hold enc=hold cap=- ") })
        let served = wire.suffix(4)
        XCTAssertTrue(served.allSatisfy { FakeAU.isHoldPicture($0) && $0.encoderTag == DashProjectionEngine.holdTag },
                      "only the pre-encoded hold IDRs; the dry run's pictures never reach the wire")
        engine.enterForeground()
        XCTAssertTrue(eventually { engine.mode == .foreground })
        XCTAssertTrue(eventually { log.count("[bg-probe] dry run ended after ") == 1 }, "the dry run ends at the unlock")
        XCTAssertTrue(eventually {
            log.all.contains { $0.hasPrefix("foreground \u{2192} hardware encoder, IDR forced (background ") && $0.contains("hold served ") }
        }, "L13 without a background encoder")
    }

    // MARK: vImage (Apple) against the integer reference (Core)

    private struct PlaneDiff {
        var y = 0, cb = 0, cr = 0
        var worst: Int { max(y, cb, cr) }
    }

    private static func diff(_ a: I420Frame, _ b: I420Frame) -> PlaneDiff {
        func worst(_ p: [UInt8], _ q: [UInt8]) -> Int { zip(p, q).map { abs(Int($0) - Int($1)) }.max() ?? 0 }
        return PlaneDiff(y: worst(a.y, b.y), cb: worst(a.cb, b.cb), cr: worst(a.cr, b.cr))
    }

    /// Converts the pixel buffer with both converters (the reference reads the same locked bytes).
    private func compare(_ buffer: CVPixelBuffer, file: StaticString = #filePath, line: UInt = #line) throws -> PlaneDiff {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let converter = try XCTUnwrap(BGRAToI420Converter(), file: file, line: line)
        var vimage = try XCTUnwrap(I420Frame(width: width, height: height), file: file, line: line)
        XCTAssertTrue(converter.convert(buffer, into: &vimage), file: file, line: line)
        var reference = try XCTUnwrap(I420Frame(width: width, height: height), file: file, line: line)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess, file: file, line: line)
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer), file: file, line: line)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ok = BGRAToI420.reference(bgra: UnsafeRawBufferPointer(start: base, count: bytesPerRow * height),
                                      width: width, height: height, bytesPerRow: bytesPerRow, into: &reference)
        XCTAssertTrue(ok, file: file, line: line)
        return Self.diff(vimage, reference)
    }

    /// Pseudo-random opaque pixels (every 2×2 block different), rows padded with garbage: the converters
    /// agree within ±2 on Y, Cb and Cr — so the chroma of both is the 2×2 mean, and both skip the padding.
    func testVImageConverterMatchesTheReferenceOnRandomPixelsWithPaddedRows() throws {
        let width = 64, height = 32, bytesPerRow = width * 4 + 40
        var state: UInt32 = 0x1234_5678
        func next() -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
        for i in bgra.indices { bgra[i] = next() }
        for row in 0 ..< height {
            for col in 0 ..< width { bgra[row * bytesPerRow + col * 4 + 3] = 255 } // opaque, as the dash UI
        }
        let converter = try XCTUnwrap(BGRAToI420Converter())
        var vimage = try XCTUnwrap(I420Frame(width: width, height: height))
        let converted = bgra.withUnsafeBytes { raw in
            converter.convert(bgra: raw.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow, into: &vimage)
        }
        XCTAssertTrue(converted)
        let reference = try XCTUnwrap(BGRAToI420.reference(bgra: bgra, width: width, height: height, bytesPerRow: bytesPerRow))
        let d = Self.diff(vimage, reference)
        XCTAssertLessThanOrEqual(d.y, 2, "Y")
        XCTAssertLessThanOrEqual(d.cb, 2, "Cb")
        XCTAssertLessThanOrEqual(d.cr, 2, "Cr")
    }

    /// The dash picture the dry run converts: rendered by DashRenderer into the engine's IOSurface pool
    /// buffers (800×384, and an odd width whose rows CoreVideo pads).
    func testVImageConverterMatchesTheReferenceOnRenderedDashPictures() throws {
        for (width, height) in [(800, 384), (72, 48)] {
            let factory = try PixelBufferFactory(width: width, height: height)
            let buffer = try XCTUnwrap(factory.makeBuffer())
            let list = DashDisplayList(size: DashSize(width: Double(width), height: Double(height)),
                                       background: DashColor(rgb: 0x1B1E24), commands: [
                .fill(.rect(DashRect(x: 0, y: 0, width: Double(width) / 2, height: Double(height) / 3)),
                      DashColor(rgb: 0x1A73E8), .nonZero),
                .fill(.rect(DashRect(x: Double(width) / 3, y: Double(height) / 2, width: Double(width) / 2, height: 9)),
                      DashColor(rgb: 0xFFCC00), .nonZero),
                .fill(.rect(DashRect(x: 3, y: Double(height) - 11, width: 7, height: 7)), DashColor(rgb: 0xE53935), .nonZero),
                .text("12:34 3.2 km", DashRect(x: 0, y: 0, width: Double(width), height: Double(height) / 2),
                      DashTextStyle(font: DashFont(size: Double(height) / 6, weight: .bold), color: .white, alignment: .center)),
            ])
            DashRenderer().render(list, into: buffer)
            let d = try compare(buffer)
            XCTAssertLessThanOrEqual(d.worst, 2, "\(width)x\(height) (bytesPerRow \(CVPixelBufferGetBytesPerRow(buffer))): \(d)")
        }
    }

    // MARK: the real VideoToolbox encoders against the stream check

    /// The first IDR of the real VideoToolbox sessions at 800×384: the foreground hardware request (`own`)
    /// must pass every `H264StreamCheck` rule — the same picture format a background encoder must match
    /// (design §3.7) — and the software request (`own-sw`, the background rung), when this machine has
    /// one, is reported with its verdict (the E2E `locked` scenario and the owner's log show it in L5).
    func testTheRealVideoToolboxFirstIDRsAgainstTheStreamCheck() throws {
        let probe = H264Encoder(label: "probe")
        do {
            try probe.configure(width: 800, height: 384, parameters: .default)
        } catch {
            probe.invalidate()
            throw XCTSkip("No usable VideoToolbox H.264 encoder on this machine: \(error)")
        }
        probe.invalidate()
        for (label, software) in [("own", false), ("own-sw", true)] {
            let enc = H264Encoder(label: label, allowSoftware: software)
            defer { enc.invalidate() }
            let frames = Locked<[EncodedFrame]>([])
            enc.onFrame = { f in frames.withLock { $0.append(f) } }
            let fps = software ? 8 : 24
            do {
                try enc.configure(width: 800, height: 384, parameters: EncoderParameters(bitrate: 3_375_000, frameRate: fps))
            } catch {
                XCTAssertTrue(software, "the hardware request must create a session: \(error)")
                print("[seam] \(label): no session (\(error))")
                continue
            }
            let picture = try XCTUnwrap(PixelBufferFactory.makeStandaloneBuffer(width: 800, height: 384))
            DashRenderer().render(DashDisplayList(size: DashSize(width: 800, height: 384), background: DashColor(rgb: 0x203040),
                                                  commands: [.fill(.rect(DashRect(x: 100, y: 100, width: 200, height: 90)),
                                                                   DashColor(rgb: 0xFFCC00), .nonZero)]),
                                  into: picture)
            enc.encode(pixelBuffer: picture, pts: 0, forceKeyframe: true)
            enc.completeFrames()
            XCTAssertTrue(eventually { !frames.current.isEmpty }, label)
            let idr = try XCTUnwrap(frames.current.first, label)
            XCTAssertTrue(idr.isKeyframe, label)
            let issues = H264StreamCheck.check(accessUnit: idr.accessUnit, canvas: canvas, requireKeyframe: true, frameRate: fps)
            let sps = H264SPS.parse(accessUnit: idr.accessUnit)
            print("[seam] \(label) hw=\(enc.usesHardware.map { String($0) } ?? "?"): \(sps?.summary ?? "sps ?") "
                + "→ \(BackgroundLog.streamCheck(issues))")
            if !software {
                XCTAssertEqual(issues, [], "the dash-proven foreground SPS/PPS passes every stream-check rule: \(sps?.summary ?? "?")")
            }
        }
    }
}
#endif
