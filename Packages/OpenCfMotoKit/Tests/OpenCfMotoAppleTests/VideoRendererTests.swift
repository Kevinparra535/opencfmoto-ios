// SPDX-License-Identifier: AGPL-3.0-or-later
// DashRenderer / CoreTextMeasurer / PixelBufferFactory on Apple platforms (CPU CoreGraphics).
#if canImport(CoreGraphics) && canImport(CoreVideo) && canImport(CoreText)
import CoreGraphics
import CoreText
import CoreVideo
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class VideoRendererTests: XCTestCase {
    private func buffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        try XCTUnwrap(PixelBufferFactory.makeStandaloneBuffer(width: w, height: h))
    }

    private func rgba(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
        guard let p = PixelBufferFactory.pixel(pb, x: x, y: y) else { return [] }
        return [Int(p.r), Int(p.g), Int(p.b), Int(p.a)]
    }

    private func list(_ w: Double, _ h: Double, _ commands: [DashDrawCommand], background: DashColor = .black) -> DashDisplayList {
        DashDisplayList(size: DashSize(width: w, height: h), background: background, commands: commands)
    }

    func testPixelBufferFactoryMakesExactBGRABuffers() throws {
        let f = try PixelBufferFactory(width: 800, height: 384, minimumBufferCount: 2, maximumBufferCount: 2)
        let a = try XCTUnwrap(f.makeBuffer())
        XCTAssertEqual(CVPixelBufferGetWidth(a), 800)
        XCTAssertEqual(CVPixelBufferGetHeight(a), 384)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(a), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(a))
        let b = try XCTUnwrap(f.makeBuffer())
        XCTAssertNil(f.makeBuffer(), "allocation threshold reached")
        _ = b
        XCTAssertThrowsError(try PixelBufferFactory(width: 0, height: 10))
        XCTAssertTrue(PixelBufferFactory.fill(a, with: DashColor(rgb: 0x123456)))
        XCTAssertEqual(rgba(a, 799, 383), [0x12, 0x34, 0x56, 255])
    }

    func testFilledRectsLandAtTopLeftOrigin() throws {
        let pb = try buffer(64, 32)
        let r = DashRenderer()
        XCTAssertTrue(r.render(list(64, 32, [
            .fill(.rect(DashRect(x: 0, y: 0, width: 16, height: 8)), DashColor(rgb: 0xFF0000), .nonZero),
            .fill(.rect(DashRect(x: 32, y: 16, width: 16, height: 16)), DashColor(rgb: 0x00FF00), .nonZero),
        ]), into: pb))
        XCTAssertEqual(rgba(pb, 2, 2), [255, 0, 0, 255], "red rect at the TOP-left")
        XCTAssertEqual(rgba(pb, 2, 28), [0, 0, 0, 255], "bottom-left stays background")
        XCTAssertEqual(rgba(pb, 40, 20), [0, 255, 0, 255])
        XCTAssertEqual(rgba(pb, 60, 2), [0, 0, 0, 255])
        XCTAssertEqual(r.stats.commands, 2)
    }

    func testBackgroundOverwritesOldContent() throws {
        let pb = try buffer(8, 8)
        PixelBufferFactory.fill(pb, with: .white)
        DashRenderer().render(list(8, 8, [], background: DashColor(rgb: 0x101418)), into: pb)
        XCTAssertEqual(rgba(pb, 4, 4), [0x10, 0x14, 0x18, 255])
    }

    func testEvenOddFillLeavesAHole() throws {
        let pb = try buffer(40, 40)
        var ring = DashPath.rect(DashRect(x: 0, y: 0, width: 40, height: 40))
        ring.append(.rect(DashRect(x: 10, y: 10, width: 20, height: 20)))
        DashRenderer().render(list(40, 40, [.fill(ring, .white, .evenOdd)]), into: pb)
        XCTAssertEqual(rgba(pb, 5, 5), [255, 255, 255, 255])
        XCTAssertEqual(rgba(pb, 20, 20), [0, 0, 0, 255])
        DashRenderer().render(list(40, 40, [.fill(ring, .white, .nonZero)]), into: pb)
        XCTAssertEqual(rgba(pb, 20, 20), [255, 255, 255, 255])
    }

    func testTransformSaveRestoreAndClip() throws {
        let pb = try buffer(40, 40)
        DashRenderer().render(list(40, 40, [
            .save,
            .transform(.translation(10, 10)),
            .fill(.rect(DashRect(x: 0, y: 0, width: 4, height: 4)), DashColor(rgb: 0xFF0000), .nonZero),
            .restore,
            .fill(.rect(DashRect(x: 0, y: 0, width: 4, height: 4)), DashColor(rgb: 0x0000FF), .nonZero),
            .save,
            .clip(.rect(DashRect(x: 30, y: 30, width: 5, height: 5))),
            .fill(.rect(DashRect(x: 20, y: 20, width: 20, height: 20)), DashColor(rgb: 0x00FF00), .nonZero),
            .restore,
            .restore, // unbalanced restore is ignored
        ]), into: pb)
        XCTAssertEqual(rgba(pb, 11, 11), [255, 0, 0, 255])
        XCTAssertEqual(rgba(pb, 1, 1), [0, 0, 255, 255], "transform restored")
        XCTAssertEqual(rgba(pb, 32, 32), [0, 255, 0, 255])
        XCTAssertEqual(rgba(pb, 22, 22), [0, 0, 0, 255], "outside the clip")
    }

    func testRotationIsClockwiseOnScreen() throws {
        // A bar from the centre to the right, rotated +90° (clockwise, y down) must point DOWN.
        let pb = try buffer(40, 40)
        DashRenderer().render(list(40, 40, [
            .transform(.translation(20, 20)),
            .transform(.rotation(.pi / 2)),
            .fill(.rect(DashRect(x: 0, y: -2, width: 15, height: 4)), .white, .nonZero),
        ]), into: pb)
        XCTAssertEqual(rgba(pb, 20, 30), [255, 255, 255, 255])
        XCTAssertEqual(rgba(pb, 30, 20), [0, 0, 0, 255])
    }

    func testStrokeWithDashPattern() throws {
        let pb = try buffer(60, 10)
        DashRenderer().render(list(60, 10, [
            .stroke(.polyline([DashPoint(0, 5), DashPoint(60, 5)]),
                    DashStroke(width: 4, color: .white, cap: .butt, join: .miter, dash: [10, 10])),
        ]), into: pb)
        XCTAssertEqual(rgba(pb, 5, 5), [255, 255, 255, 255])
        XCTAssertEqual(rgba(pb, 15, 5), [0, 0, 0, 255], "gap of the dash pattern")
        XCTAssertEqual(rgba(pb, 25, 5), [255, 255, 255, 255])
    }

    /// Lit pixels (red channel > 128) per row inside the buffer.
    private func litRows(_ pb: CVPixelBuffer) -> [Int: Int] {
        var rows: [Int: Int] = [:]
        for y in 0 ..< CVPixelBufferGetHeight(pb) {
            for x in 0 ..< CVPixelBufferGetWidth(pb) where (PixelBufferFactory.pixel(pb, x: x, y: y)?.r ?? 0) > 128 {
                rows[y, default: 0] += 1
            }
        }
        return rows
    }

    func testTextIsUprightAndVerticallyCentred() throws {
        let pb = try buffer(64, 64)
        let style = DashTextStyle(font: DashFont(size: 40, weight: .bold), color: .white, alignment: .center)
        DashRenderer().render(list(64, 64, [.text("T", DashRect(x: 0, y: 0, width: 64, height: 64), style)]), into: pb)
        let rows = litRows(pb)
        XCTAssertFalse(rows.isEmpty, "text drawn")
        let top = rows.keys.min()!, bottom = rows.keys.max()!
        // "T": the widest rows (the bar) are at the TOP of the glyph when drawn upright.
        let widest = rows.max { $0.value < $1.value }!.key
        XCTAssertLessThan(widest - top, bottom - widest, "glyph is not upside down")
        // Block centred: lit region roughly in the middle of the 64-px box.
        XCTAssertGreaterThan(top, 4)
        XCTAssertLessThan(bottom, 60)
        // Horizontally centred.
        var xs: [Int] = []
        for x in 0 ..< 64 where (PixelBufferFactory.pixel(pb, x: x, y: widest)?.r ?? 0) > 128 { xs.append(x) }
        XCTAssertEqual(Double(xs.min()! + xs.max()!) / 2, 32, accuracy: 3)
    }

    func testTextAlignmentLeftAndRight() throws {
        let style = DashTextStyle(font: DashFont(size: 20), color: .white, alignment: .left)
        let pbL = try buffer(100, 30)
        DashRenderer().render(list(100, 30, [.text("ii", DashRect(x: 10, y: 0, width: 80, height: 30), style)]), into: pbL)
        let pbR = try buffer(100, 30)
        var right = style
        right.alignment = .right
        DashRenderer().render(list(100, 30, [.text("ii", DashRect(x: 10, y: 0, width: 80, height: 30), right)]), into: pbR)
        func litXs(_ pb: CVPixelBuffer) -> [Int] {
            (0 ..< 100).filter { x in (0 ..< 30).contains { y in (PixelBufferFactory.pixel(pb, x: x, y: y)?.r ?? 0) > 128 } }
        }
        let l = litXs(pbL), r = litXs(pbR)
        XCTAssertFalse(l.isEmpty)
        XCTAssertFalse(r.isEmpty)
        XCTAssertGreaterThanOrEqual(l.min()!, 10)
        XCTAssertLessThan(l.max()!, 30)
        XCTAssertGreaterThan(r.min()!, 70)
        XCTAssertLessThanOrEqual(r.max()!, 90)
    }

    func testLongTextIsTruncatedInsideItsRect() throws {
        let pb = try buffer(120, 30)
        let style = DashTextStyle(font: DashFont(size: 18), color: .white, maxLines: 1)
        DashRenderer().render(list(120, 30, [
            .text("Avenida Boyacá con Calle 80 hacia el norte", DashRect(x: 10, y: 0, width: 60, height: 30), style),
        ]), into: pb)
        for y in 0 ..< 30 {
            for x in 72 ..< 120 { XCTAssertLessThan(PixelBufferFactory.pixel(pb, x: x, y: y)?.r ?? 0, 100, "(\(x),\(y)) outside the box") }
        }
    }

    func testMissingTilesUsePlaceholders() throws {
        let pb = try buffer(64, 32)
        DashRenderer().render(list(64, 32, [
            .tile(z: 16, x: 1, y: 1, rect: DashRect(x: 0, y: 0, width: 32, height: 32), invert: false),
            .tile(z: 16, x: 2, y: 1, rect: DashRect(x: 32, y: 0, width: 32, height: 32), invert: true),
        ]), into: pb)
        XCTAssertEqual(rgba(pb, 10, 10), [0xE9, 0xE5, 0xDC, 255])
        XCTAssertEqual(rgba(pb, 50, 10), [0x26, 0x2A, 0x2E, 255])
    }

    func testMakeImageAndBufferCopyAreIndependent() throws {
        let r = DashRenderer()
        let l = list(16, 8, [.fill(.rect(DashRect(x: 0, y: 0, width: 16, height: 8)), DashColor(rgb: 0x336699), .nonZero)])
        let image = try XCTUnwrap(r.makeImage(l, scale: 2))
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 16)
        let pb = try buffer(16, 8)
        r.render(l, into: pb)
        let copy = try XCTUnwrap(DashRenderer.makeImage(from: pb))
        PixelBufferFactory.fill(pb, with: .white)
        // The copy keeps the old pixels.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(copy, in: CGRect(x: 0, y: 0, width: 16, height: 8))
        let px = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual([Int(px[0]), Int(px[1]), Int(px[2])], [0x33, 0x66, 0x99])
    }

    func testListOfAnotherSizeIsScaledToTheBuffer() throws {
        let pb = try buffer(40, 20)
        DashRenderer().render(list(20, 10, [.fill(.rect(DashRect(x: 10, y: 0, width: 10, height: 10)), .white, .nonZero)]), into: pb)
        XCTAssertEqual(rgba(pb, 30, 15), [255, 255, 255, 255])
        XCTAssertEqual(rgba(pb, 10, 15), [0, 0, 0, 255])
    }

    // MARK: CoreTextMeasurer

    func testCoreTextMeasurer() {
        let m = CoreTextMeasurer()
        let regular = DashFont(size: 20)
        let wide = m.measure("WWW", font: regular), narrow = m.measure("iii", font: regular)
        XCTAssertGreaterThan(wide.width, narrow.width)
        XCTAssertGreaterThan(wide.ascent, 10)
        XCTAssertGreaterThan(wide.descent, 2)
        XCTAssertEqual(wide.lineHeight, wide.ascent + wide.descent)
        XCTAssertEqual(m.measure("", font: regular).width, 0)
        // Same metrics for every string of a font (ascent/descent of the font, no leading).
        XCTAssertEqual(m.measure("Ag", font: regular).ascent, wide.ascent)
        let mono = DashFont(size: 30, weight: .bold, monospacedDigits: true)
        XCTAssertEqual(m.measure("1111", font: mono).width, m.measure("8888", font: mono).width, accuracy: 0.01)
        let bold = m.measure("Hello", font: DashFont(size: 20, weight: .bold)).width
        XCTAssertGreaterThan(bold, m.measure("Hello", font: regular).width)
        for w in [DashFontWeight.medium, .semibold] {
            XCTAssertGreaterThan(m.measure("Hello", font: DashFont(size: 20, weight: w)).width, 0)
        }
        // Roughly the size of the deterministic approximation used by the layout tests.
        let approx = ApproximateTextMeasurer().measure("Calle 80", font: regular).width
        XCTAssertEqual(m.measure("Calle 80", font: regular).width, approx, accuracy: approx * 0.35)
    }

    func testFontProviderCachesFonts() {
        let p = DashFontProvider()
        let a = p.font(for: DashFont(size: 17, weight: .bold))
        let b = p.font(for: DashFont(size: 17, weight: .bold))
        XCTAssertTrue(a === b)
        XCTAssertEqual(Double(CTFontGetSize(a)), 17, accuracy: 0.01)
    }
}
#endif
