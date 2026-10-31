// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

/// Vectors: docs/spec/media-video.md §10.3 table + extra cases produced by the original Kotlin
/// `AaCompositor.computeViewport` / `mapCanvasToSource` (copied verbatim into the golden harness).
final class VideoMirrorFitTests: XCTestCase {
    private typealias V = MirrorFitMath.Viewport

    private func vp(_ w: Int, _ h: Int, _ sw: Int, _ sh: Int, _ fit: ScreenFit,
                    t: Int = 0, b: Int = 0, l: Int = 0, r: Int = 0) -> V? {
        MirrorFitMath.viewport(canvasWidth: w, canvasHeight: h, sourceWidth: sw, sourceHeight: sh, fit: fit,
                               margins: ScreenMargins(customised: true, top: t, bottom: b, left: l, right: r))
    }

    private func check(_ w: Int, _ h: Int, _ sw: Int, _ sh: Int, t: Int = 0, b: Int = 0, l: Int = 0, r: Int = 0,
                       fit: V, fill: V, stretch: V, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(vp(w, h, sw, sh, .fit, t: t, b: b, l: l, r: r), fit, "FIT", file: file, line: line)
        XCTAssertEqual(vp(w, h, sw, sh, .fill, t: t, b: b, l: l, r: r), fill, "FILL", file: file, line: line)
        XCTAssertEqual(vp(w, h, sw, sh, .stretch, t: t, b: b, l: l, r: r), stretch, "STRETCH", file: file, line: line)
    }

    // §10.3 worked examples.

    func testAA800x480IntoCFDL16() {
        check(800, 384, 800, 480, fit: V(x: 80, y: 0, width: 640, height: 384),
              fill: V(x: 0, y: -48, width: 800, height: 480), stretch: V(x: 0, y: 0, width: 800, height: 384))
    }

    func testAA720x1280IntoCFDL26() {
        check(800, 944, 720, 1280, fit: V(x: 134, y: 0, width: 531, height: 944),
              fill: V(x: 0, y: -239, width: 800, height: 1422), stretch: V(x: 0, y: 0, width: 800, height: 944))
    }

    func testAA800x480Into800MT() {
        check(1280, 576, 800, 480, fit: V(x: 160, y: 0, width: 960, height: 576),
              fill: V(x: 0, y: -96, width: 1280, height: 768), stretch: V(x: 0, y: 0, width: 1280, height: 576))
    }

    func testNkAdvancedWithTopMargin22() {
        check(720, 704, 720, 712, t: 22, fit: V(x: 15, y: 22, width: 690, height: 682),
              fill: V(x: 0, y: 7, width: 720, height: 712), stretch: V(x: 0, y: 22, width: 720, height: 682))
    }

    func testMirrorPortraitPhoneIntoLandscapeDash() {
        check(800, 384, 1080, 2400, fit: V(x: 313, y: 0, width: 173, height: 384),
              fill: V(x: 0, y: -697, width: 800, height: 1778), stretch: V(x: 0, y: 0, width: 800, height: 384))
    }

    func testMirrorLandscapePhoneIntoLandscapeDash() {
        check(800, 384, 2400, 1080, fit: V(x: 0, y: 12, width: 800, height: 360),
              fill: V(x: -26, y: 0, width: 853, height: 384), stretch: V(x: 0, y: 0, width: 800, height: 384))
    }

    func testMirrorPortraitPhoneIntoPortraitDash() {
        check(800, 944, 1080, 2400, fit: V(x: 187, y: 0, width: 425, height: 944),
              fill: V(x: 0, y: -417, width: 800, height: 1778), stretch: V(x: 0, y: 0, width: 800, height: 944))
    }

    // Extra golden vectors (Kotlin harness): iPhone screen sizes, margins, degenerate area.

    func testIPhoneScreensKotlinGolden() {
        check(800, 384, 1170, 2532, fit: V(x: 311, y: 0, width: 177, height: 384),
              fill: V(x: 0, y: -673, width: 800, height: 1731), stretch: V(x: 0, y: 0, width: 800, height: 384))
        check(800, 944, 1170, 2532, fit: V(x: 182, y: 0, width: 436, height: 944),
              fill: V(x: 0, y: -393, width: 800, height: 1731), stretch: V(x: 0, y: 0, width: 800, height: 944))
        check(1280, 576, 2532, 1170, fit: V(x: 16, y: 0, width: 1247, height: 576),
              fill: V(x: 0, y: -7, width: 1280, height: 591), stretch: V(x: 0, y: 0, width: 1280, height: 576))
        check(544, 512, 1179, 2556, fit: V(x: 154, y: 0, width: 236, height: 512),
              fill: V(x: 0, y: -333, width: 544, height: 1179), stretch: V(x: 0, y: 0, width: 544, height: 512))
    }

    func testAllFourMarginsKotlinGolden() {
        check(800, 384, 1170, 2532, t: 10, b: 30, l: 5, r: 7, fit: V(x: 319, y: 10, width: 159, height: 344),
              fill: V(x: 5, y: -670, width: 788, height: 1705), stretch: V(x: 5, y: 10, width: 788, height: 344))
        check(720, 704, 2556, 1179, t: 22, fit: V(x: 0, y: 197, width: 720, height: 332),
              fill: V(x: -379, y: 22, width: 1479, height: 682), stretch: V(x: 0, y: 22, width: 720, height: 682))
    }

    func testOversizedMarginsClampLikeAndroid() {
        // right = 600 is clamped to W − left = 500 → area width 1 (coerceAtLeast(1)).
        check(800, 384, 801, 385, l: 300, r: 600, fit: V(x: 300, y: 192, width: 1, height: 0),
              fill: V(x: -99, y: 0, width: 799, height: 384), stretch: V(x: 300, y: 0, width: 1, height: 384))
        let area = MirrorFitMath.insetArea(canvasWidth: 800, canvasHeight: 384,
                                           margins: ScreenMargins(customised: true, top: 500, bottom: 9, left: 0, right: 0))
        XCTAssertEqual(area, V(x: 0, y: 384, width: 800, height: 1))
    }

    func testInvalidInputsGiveNil() {
        XCTAssertNil(vp(0, 384, 800, 480, .fit))
        XCTAssertNil(vp(800, 384, 0, 480, .fit))
        XCTAssertNil(vp(800, 384, 800, -1, .fill))
    }

    func testJavaRoundSemantics() {
        XCTAssertEqual(MirrorFitMath.javaRound(0.5), 1)
        XCTAssertEqual(MirrorFitMath.javaRound(1.49999), 1)
        XCTAssertEqual(MirrorFitMath.javaRound(-0.5), 0)
        XCTAssertEqual(MirrorFitMath.javaRound(-1.5), -1)
        XCTAssertEqual(MirrorFitMath.javaRound(531.0), 531)
        XCTAssertEqual(MirrorFitMath.javaRound(.nan), 0)
    }

    // §10.3 inverse-map vectors (800MT FIT, viewport 160,0,960,576, source 800×480).

    func testInverseMap() {
        let v = V(x: 160, y: 0, width: 960, height: 576)
        func m(_ x: Int, _ y: Int) -> [Int]? {
            MirrorFitMath.mapCanvasToSource(x: x, y: y, viewport: v, sourceWidth: 800, sourceHeight: 480).map { [$0.x, $0.y] }
        }
        XCTAssertNil(m(0, 0))
        XCTAssertEqual(m(160, 0), [0, 0])
        XCTAssertEqual(m(640, 288), [400, 240])
        XCTAssertEqual(m(1119, 575), [799, 479])
        XCTAssertNil(m(1200, 10))
        XCTAssertNil(m(1120, 0))
        XCTAssertNil(m(159, 300))
    }

    // Orientation (CGImagePropertyOrientation raw values, EXIF semantics).

    func testOrientedSizeAndQuarterTurns() {
        for raw: UInt32 in 1 ... 4 {
            XCTAssertFalse(MirrorFitMath.isQuarterTurn(orientation: raw))
            XCTAssertEqual(MirrorFitMath.orientedSize(width: 1170, height: 2532, orientation: raw).width, 1170)
        }
        for raw: UInt32 in 5 ... 8 {
            XCTAssertTrue(MirrorFitMath.isQuarterTurn(orientation: raw))
            let s = MirrorFitMath.orientedSize(width: 1170, height: 2532, orientation: raw)
            XCTAssertEqual([s.width, s.height], [2532, 1170])
        }
        XCTAssertFalse(MirrorFitMath.isQuarterTurn(orientation: 0)) // unknown → up
        XCTAssertFalse(MirrorFitMath.isQuarterTurn(orientation: 42))
    }

    /// Maps a stored-picture point (centre-relative, y down) to the display.
    private func apply(_ raw: UInt32, _ x: Double, _ y: Double) -> [Double] {
        let m = MirrorFitMath.displayMatrix(orientation: raw)
        return [m.a * x + m.c * y, m.b * x + m.d * y].map { $0 == 0 ? 0 : $0 } // normalise -0
    }

    func testDisplayMatrixFollowsExifSemantics() {
        // Stored picture 2w × 2h: top-centre (0,-h), left-centre (-w,0).
        let topRow: (Double, Double) = (0, -1), leftColumn: (Double, Double) = (-1, 0)
        // 1 up: top row on top, column 0 on the left.
        XCTAssertEqual(apply(1, topRow.0, topRow.1), [0, -1]); XCTAssertEqual(apply(1, leftColumn.0, leftColumn.1), [-1, 0])
        // 2 upMirrored: top row on top, column 0 on the right.
        XCTAssertEqual(apply(2, topRow.0, topRow.1), [0, -1]); XCTAssertEqual(apply(2, leftColumn.0, leftColumn.1), [1, 0])
        // 3 down: top row at the bottom, column 0 on the right.
        XCTAssertEqual(apply(3, topRow.0, topRow.1), [0, 1]); XCTAssertEqual(apply(3, leftColumn.0, leftColumn.1), [1, 0])
        // 4 downMirrored: top row at the bottom, column 0 on the left.
        XCTAssertEqual(apply(4, topRow.0, topRow.1), [0, 1]); XCTAssertEqual(apply(4, leftColumn.0, leftColumn.1), [-1, 0])
        // 5 leftMirrored: row 0 on the left, column 0 at the top.
        XCTAssertEqual(apply(5, topRow.0, topRow.1), [-1, 0]); XCTAssertEqual(apply(5, leftColumn.0, leftColumn.1), [0, -1])
        // 6 right: row 0 on the right, column 0 at the top (rotate 90° clockwise).
        XCTAssertEqual(apply(6, topRow.0, topRow.1), [1, 0]); XCTAssertEqual(apply(6, leftColumn.0, leftColumn.1), [0, -1])
        // 7 rightMirrored: row 0 on the right, column 0 at the bottom.
        XCTAssertEqual(apply(7, topRow.0, topRow.1), [1, 0]); XCTAssertEqual(apply(7, leftColumn.0, leftColumn.1), [0, 1])
        // 8 left: row 0 on the left, column 0 at the bottom (rotate 90° counter-clockwise).
        XCTAssertEqual(apply(8, topRow.0, topRow.1), [-1, 0]); XCTAssertEqual(apply(8, leftColumn.0, leftColumn.1), [0, 1])
    }

    func testDisplayMatricesAreOrthonormal() {
        for raw: UInt32 in 0 ... 9 {
            let m = MirrorFitMath.displayMatrix(orientation: raw)
            XCTAssertEqual(abs(m.a * m.d - m.b * m.c), 1, "orientation \(raw)")
        }
    }

    func testIntermediateSizeSwapsForQuarterTurnsAndCaps() {
        let v = V(x: 311, y: 0, width: 177, height: 384)
        let up = MirrorFitMath.intermediateSize(viewport: v, orientation: 1, maxPixels: 800 * 384 * 2)
        XCTAssertEqual([up.width, up.height], [177, 384])
        let right = MirrorFitMath.intermediateSize(viewport: v, orientation: 6, maxPixels: 800 * 384 * 2)
        XCTAssertEqual([right.width, right.height], [384, 177])
        // FILL viewport 800×1731 > 2 × canvas → scaled down keeping the aspect.
        let big = MirrorFitMath.intermediateSize(viewport: V(x: 0, y: -673, width: 800, height: 1731), orientation: 1,
                                                 maxPixels: 800 * 384 * 2)
        XCTAssertLessThanOrEqual(big.width * big.height, 800 * 384 * 2)
        XCTAssertEqual(Double(big.width) / Double(big.height), 800.0 / 1731.0, accuracy: 0.01)
        let tiny = MirrorFitMath.intermediateSize(viewport: V(x: 0, y: 0, width: 1, height: 0), orientation: 1, maxPixels: 100)
        XCTAssertEqual([tiny.width, tiny.height], [2, 2])
    }
}
