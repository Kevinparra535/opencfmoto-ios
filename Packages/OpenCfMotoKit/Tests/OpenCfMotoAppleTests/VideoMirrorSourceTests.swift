// SPDX-License-Identifier: AGPL-3.0-or-later
// MirrorFrameSource composition (fit, margins, orientation) and ThermalMonitor on Apple platforms.
#if canImport(VideoToolbox) && canImport(CoreGraphics) && canImport(CoreMedia) && canImport(ImageIO)
import CoreGraphics
import CoreVideo
import ImageIO
import VideoToolbox
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

private func pollUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}

final class VideoMirrorSourceTests: XCTestCase {
    /// A "phone screen": top half red, bottom half blue (BGRA).
    private func screen(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        let pb = try XCTUnwrap(PixelBufferFactory.makeStandaloneBuffer(width: w, height: h))
        DashRenderer().render(DashDisplayList(size: DashSize(width: Double(w), height: Double(h)), background: DashColor(rgb: 0x0000FF),
                                              commands: [.fill(.rect(DashRect(x: 0, y: 0, width: Double(w), height: Double(h) / 2)),
                                                               DashColor(rgb: 0xFF0000), .nonZero)]), into: pb)
        return pb
    }

    private func rgb(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
        guard let p = PixelBufferFactory.pixel(pb, x: x, y: y) else { return [] }
        return [Int(p.r), Int(p.g), Int(p.b)]
    }

    private func isRed(_ c: [Int]) -> Bool { c.count == 3 && c[0] > 200 && c[1] < 60 && c[2] < 60 }
    private func isBlue(_ c: [Int]) -> Bool { c.count == 3 && c[0] < 60 && c[1] < 60 && c[2] > 200 }
    private func isBlack(_ c: [Int]) -> Bool { c.count == 3 && c.allSatisfy { $0 < 20 } }

    private func makeSource(fit: ScreenFit = .fit, margins: ScreenMargins = .zero) throws -> (MirrorFrameSource, Locked<[EncodedFrame]>) {
        let probe = H264Encoder(label: "probe")
        do { try probe.configure(width: 320, height: 160, parameters: .default) } catch {
            throw XCTSkip("No usable VideoToolbox H.264 encoder: \(error)")
        }
        probe.invalidate()
        let cfg = MirrorRelayConfig(canvas: VideoCanvas(width: 320, height: 160), parameters: EncoderParameters(bitrate: 800_000, frameRate: 30),
                                    fit: fit, margins: margins)
        let source = MirrorFrameSource(configuration: cfg)
        let frames = Locked<[EncodedFrame]>([])
        source.onFrame = { f in frames.withLock { $0.append(f) } }
        return (source, frames)
    }

    func testPortraitScreenIsLetterboxedIntoALandscapeCanvas() throws {
        let (source, frames) = try makeSource()
        defer { source.stop() }
        source.append(pixelBuffer: try screen(120, 240), orientation: .up)
        XCTAssertTrue(pollUntil { frames.current.first?.isKeyframe == true })
        // FIT: 120×240 into 320×160 → viewport 120,0 80×160 (black bars left/right).
        XCTAssertEqual(source.stats.viewport, MirrorFitMath.Viewport(x: 120, y: 0, width: 80, height: 160))
        let canvas = try XCTUnwrap(source.lastCanvasBufferForTesting)
        XCTAssertTrue(isBlack(rgb(canvas, 60, 80)), "left bar")
        XCTAssertTrue(isBlack(rgb(canvas, 260, 80)), "right bar")
        XCTAssertTrue(isRed(rgb(canvas, 160, 30)), "top half of the screen at the top")
        XCTAssertTrue(isBlue(rgb(canvas, 160, 130)))
        XCTAssertEqual(Array(AnnexB.nalUnits(annexB: frames.current[0].accessUnit).compactMap { AnnexB.nalType($0) }.prefix(3)), [7, 8, 5])
    }

    func testRightOrientationRotatesClockwise() throws {
        let (source, frames) = try makeSource()
        defer { source.stop() }
        // Stored 80×160 portrait buffer displayed rotated 90° CW → 160×80 landscape: its top (red)
        // half ends up on the RIGHT. Aspect 2:1 = canvas aspect → full-canvas viewport.
        source.append(pixelBuffer: try screen(80, 160), orientation: .right)
        XCTAssertTrue(pollUntil { !frames.current.isEmpty })
        XCTAssertEqual(source.stats.viewport, MirrorFitMath.Viewport(x: 0, y: 0, width: 320, height: 160))
        let canvas = try XCTUnwrap(source.lastCanvasBufferForTesting)
        XCTAssertTrue(isRed(rgb(canvas, 260, 80)), "\(rgb(canvas, 260, 80))")
        XCTAssertTrue(isBlue(rgb(canvas, 60, 80)), "\(rgb(canvas, 60, 80))")
    }

    func testLeftOrientationRotatesCounterClockwise() throws {
        let (source, frames) = try makeSource()
        defer { source.stop() }
        source.append(pixelBuffer: try screen(80, 160), orientation: .left)
        XCTAssertTrue(pollUntil { !frames.current.isEmpty })
        let canvas = try XCTUnwrap(source.lastCanvasBufferForTesting)
        XCTAssertTrue(isRed(rgb(canvas, 60, 80)))
        XCTAssertTrue(isBlue(rgb(canvas, 260, 80)))
    }

    func testDownOrientationAndMarginsStayBlack() throws {
        let (source, frames) = try makeSource(fit: .stretch, margins: ScreenMargins(customised: true, top: 20, bottom: 0, left: 0, right: 0))
        defer { source.stop() }
        source.append(pixelBuffer: try screen(160, 80), orientation: .down)
        XCTAssertTrue(pollUntil { !frames.current.isEmpty })
        let canvas = try XCTUnwrap(source.lastCanvasBufferForTesting)
        XCTAssertTrue(isBlack(rgb(canvas, 160, 10)), "top margin")
        XCTAssertTrue(isBlue(rgb(canvas, 160, 40)), "rotated 180°: blue on top")
        XCTAssertTrue(isRed(rgb(canvas, 160, 150)))
    }

    func testStaticScreenIsRepeatedAndKeyframeRequestsAreHonoured() throws {
        let (source, frames) = try makeSource()
        defer { source.stop() }
        source.append(pixelBuffer: try screen(120, 240), orientation: .up)
        XCTAssertTrue(pollUntil { !frames.current.isEmpty })
        // No new screen frames: the 0.9 s keep-alive re-encodes the last picture.
        XCTAssertTrue(pollUntil(3) { frames.current.count >= 2 })
        XCTAssertGreaterThanOrEqual(source.stats.repeats, 1)
        let before = frames.current.count
        source.requestKeyframe()
        XCTAssertTrue(pollUntil { frames.current.count > before && frames.current.last?.isKeyframe == true })
    }

    func testDirectPullUseAsVideoFrameSource() async throws {
        let (source, _) = try makeSource()
        defer { source.stop() }
        source.prepare(canvas: VideoCanvas(width: 320, height: 160), parameters: .default)
        source.resynchronize()
        source.append(pixelBuffer: try screen(120, 240), orientation: .up)
        let f = await source.nextFrame(timeout: 3)
        XCTAssertTrue(f?.isKeyframe ?? false)
    }
}

#if canImport(Darwin)
final class VideoThermalMonitorTests: XCTestCase {
    func testThermalStateMapping() {
        XCTAssertEqual(ThermalMonitor.level(for: .nominal), .none)
        XCTAssertEqual(ThermalMonitor.level(for: .fair), .moderate)
        XCTAssertEqual(ThermalMonitor.level(for: .serious), .severe)
        XCTAssertEqual(ThermalMonitor.level(for: .critical), .critical)
    }

    func testObserverGetsTheCurrentStateImmediately() {
        let monitor = ThermalMonitor()
        monitor.start()
        defer { monitor.stop() }
        let seen = Locked<[ThermalMonitor.State]>([])
        let id = monitor.addObserver { s in seen.withLock { $0.append(s) } }
        XCTAssertEqual(seen.current.count, 1)
        XCTAssertEqual(seen.current.first, monitor.state)
        XCTAssertEqual(monitor.state.level, ThermalMonitor.level(for: ProcessInfo.processInfo.thermalState))
        monitor.removeObserver(id)
    }
}
#endif
#endif
