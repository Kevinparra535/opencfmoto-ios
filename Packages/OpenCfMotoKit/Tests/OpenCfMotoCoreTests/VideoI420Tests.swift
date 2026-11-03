// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0: I420Frame and the integer BT.601 limited-range BGRA → I420 reference
// conversion (design §3.5), the oracle of the vImage converter. Expected values computed by hand from
//   Y = ((66R + 129G + 25B + 128) >> 8) + 16, Cb = ((−38R − 74G + 112B + 128) >> 8) + 128,
//   Cr = ((112R − 94G − 18B + 128) >> 8) + 128, chroma from the rounded 2×2 mean ((sum + 2) / 4).
import XCTest
@testable import OpenCfMotoCore

final class VideoI420Tests: XCTestCase {
    /// BGRA bytes (B, G, R, A per pixel) of rows of (R, G, B) pixels, each row followed by `padding`
    /// bytes of 0xEE (which would show up in the result if read).
    private func bgra(_ rows: [[(Int, Int, Int)]], padding: Int = 0, alpha: UInt8 = 0xFF) -> (bytes: [UInt8], bytesPerRow: Int) {
        var out: [UInt8] = []
        for row in rows {
            for (r, g, b) in row { out += [UInt8(b), UInt8(g), UInt8(r), alpha] }
            out += [UInt8](repeating: 0xEE, count: padding)
        }
        return (out, rows[0].count * 4 + padding)
    }

    private func uniform(_ rgb: (Int, Int, Int), width: Int, height: Int) -> [[(Int, Int, Int)]] {
        [[(Int, Int, Int)]](repeating: [(Int, Int, Int)](repeating: rgb, count: width), count: height)
    }

    private func convert(_ image: (bytes: [UInt8], bytesPerRow: Int), width: Int, height: Int) -> I420Frame? {
        BGRAToI420.reference(bgra: image.bytes, width: width, height: height, bytesPerRow: image.bytesPerRow)
    }

    func testFrameGeometry() throws {
        let f = try XCTUnwrap(I420Frame(width: 800, height: 384))
        XCTAssertEqual([f.y.count, f.cb.count, f.cr.count], [307_200, 76_800, 76_800])
        XCTAssertEqual([f.lumaStride, f.chromaStride, f.chromaWidth, f.chromaHeight], [800, 400, 400, 192])
        XCTAssertTrue(f.y.allSatisfy { $0 == 0 } && f.cb.allSatisfy { $0 == 0 } && f.cr.allSatisfy { $0 == 0 })
        XCTAssertNotNil(I420Frame(width: 8192, height: 8192))
        XCTAssertNotNil(I420Frame(width: 2, height: 2))
        for (w, h) in [(3, 2), (4, 3), (0, 2), (2, 0), (-2, 2), (2, -2), (8194, 2), (2, 8194)] {
            XCTAssertNil(I420Frame(width: w, height: h), "\(w)x\(h)")
        }
    }

    func testBlackWhiteRedGreenBlueExact() throws {
        let cases: [((Int, Int, Int), (UInt8, UInt8, UInt8))] = [
            ((0, 0, 0), (16, 128, 128)), ((255, 255, 255), (235, 128, 128)), ((255, 0, 0), (82, 90, 240)),
            ((0, 255, 0), (144, 54, 34)), ((0, 0, 255), (41, 240, 110)),
        ]
        for (rgb, yuv) in cases {
            let f = try XCTUnwrap(convert(bgra(uniform(rgb, width: 4, height: 2)), width: 4, height: 2))
            XCTAssertEqual(f.y, [UInt8](repeating: yuv.0, count: 8), "Y of \(rgb)")
            XCTAssertEqual(f.cb, [yuv.1, yuv.1], "Cb of \(rgb)")
            XCTAssertEqual(f.cr, [yuv.2, yuv.2], "Cr of \(rgb)")
        }
    }

    func testChromaIsFromTheRounded2x2Mean() throws {
        // R (0, 0, 0, 2), B (255, 254, 253, 251): mean (1, 0, 253) with (sum + 2) / 4. A truncated mean
        // (0, 0, 253) would give Cr 110, so would averaging the per-pixel Cr (110.25).
        let f = try XCTUnwrap(convert(bgra([[(0, 0, 255), (0, 0, 254)], [(0, 0, 253), (2, 0, 251)]]), width: 2, height: 2))
        XCTAssertEqual(f.y, [41, 41, 41, 41])
        XCTAssertEqual(f.cb, [239])
        XCTAssertEqual(f.cr, [111])
        // Negative intermediates use an arithmetic shift: the mean (12, 22, 32) gives
        // Cr = ((1344 − 2068 − 576 + 128) >> 8) + 128 = −5 + 128 = 123 (a truncating division gives 124).
        let g = try XCTUnwrap(convert(bgra([[(10, 20, 30), (11, 21, 31)], [(12, 22, 32), (13, 23, 33)]]), width: 2, height: 2))
        XCTAssertEqual(g.y, [32, 32, 33, 34])
        XCTAssertEqual(g.cb, [134])
        XCTAssertEqual(g.cr, [123])
    }

    func testEveryBlockLandsInItsPlace() throws {
        // 4×4 of four 2×2 blocks: red | white over black | blue.
        let red = (255, 0, 0), white = (255, 255, 255), black = (0, 0, 0), blue = (0, 0, 255)
        let rows = [[red, red, white, white], [red, red, white, white], [black, black, blue, blue], [black, black, blue, blue]]
        let f = try XCTUnwrap(convert(bgra(rows), width: 4, height: 4))
        XCTAssertEqual(f.y, [82, 82, 235, 235, 82, 82, 235, 235, 16, 16, 41, 41, 16, 16, 41, 41])
        XCTAssertEqual(f.cb, [90, 128, 128, 240])
        XCTAssertEqual(f.cr, [240, 128, 128, 110])
    }

    func testRowPaddingAndAlphaAreIgnored() throws {
        let rows = [[(10, 20, 30), (200, 100, 50), (0, 0, 0), (255, 255, 255)],
                    [(1, 2, 3), (4, 5, 6), (7, 8, 9), (250, 240, 230)]]
        let tight = try XCTUnwrap(convert(bgra(rows), width: 4, height: 2))
        for padding in [4, 12, 48] {
            XCTAssertEqual(convert(bgra(rows, padding: padding), width: 4, height: 2), tight, "padding \(padding)")
        }
        XCTAssertEqual(convert(bgra(rows, alpha: 0), width: 4, height: 2), tight, "alpha")
        // The last row needs no padding after it.
        var image = bgra(rows, padding: 12)
        image.bytes.removeLast(12)
        XCTAssertEqual(convert(image, width: 4, height: 2), tight)
    }

    func testBadInputIsRejected() throws {
        let image = bgra(uniform((9, 9, 9), width: 4, height: 4))
        XCTAssertNil(convert(image, width: 3, height: 4), "odd width")
        XCTAssertNil(convert(image, width: 4, height: 3), "odd height")
        XCTAssertNil(convert(image, width: 0, height: 4))
        XCTAssertNil(BGRAToI420.reference(bgra: image.bytes, width: 4, height: 4, bytesPerRow: 15), "rows shorter than width × 4")
        // Short buffers: one byte less than bytesPerRow × (height − 1) + width × 4.
        var short = bgra(uniform((9, 9, 9), width: 4, height: 4), padding: 8)
        short.bytes.removeLast(8)
        XCTAssertNotNil(convert(short, width: 4, height: 4))
        short.bytes.removeLast()
        XCTAssertNil(convert(short, width: 4, height: 4))
        XCTAssertNil(BGRAToI420.reference(bgra: [], width: 2, height: 2, bytesPerRow: 8))
        XCTAssertNil(BGRAToI420.reference(bgra: image.bytes, width: 4, height: 4, bytesPerRow: Int.max), "an overflowing size")
        XCTAssertNil(BGRAToI420.reference(bgra: image.bytes, width: 4, height: 2, bytesPerRow: Int.max - 8), "an overflowing size")
    }

    func testFailureLeavesTheFrameUnchanged() throws {
        var frame = try XCTUnwrap(I420Frame(width: 4, height: 4))
        frame.y = [UInt8](repeating: 7, count: 16)
        let before = frame
        let small = bgra(uniform((255, 0, 0), width: 4, height: 2))
        let mismatch = small.bytes.withUnsafeBytes {
            BGRAToI420.reference(bgra: $0, width: 4, height: 2, bytesPerRow: 16, into: &frame)
        }
        XCTAssertFalse(mismatch, "the frame is 4×4")
        let truncated = small.bytes.withUnsafeBytes {
            BGRAToI420.reference(bgra: UnsafeRawBufferPointer(rebasing: $0.prefix(20)), width: 4, height: 4, bytesPerRow: 16, into: &frame)
        }
        XCTAssertFalse(truncated)
        XCTAssertEqual(frame, before)
    }

    func testReusedFrameIsOverwritten() throws {
        var frame = try XCTUnwrap(I420Frame(width: 2, height: 2))
        for (rgb, yuv) in [((255, 0, 0), (82, 90, 240)), ((0, 0, 0), (16, 128, 128))] as [((Int, Int, Int), (UInt8, UInt8, UInt8))] {
            let ok = bgra(uniform(rgb, width: 2, height: 2)).bytes.withUnsafeBytes {
                BGRAToI420.reference(bgra: $0, width: 2, height: 2, bytesPerRow: 8, into: &frame)
            }
            XCTAssertTrue(ok)
            XCTAssertEqual(frame.y, [yuv.0, yuv.0, yuv.0, yuv.0])
            XCTAssertEqual([frame.cb[0], frame.cr[0]], [yuv.1, yuv.2])
        }
    }

    func testDashCanvasWithPaddedRows() throws {
        // 800×384 with 64 bytes of row padding (as a CVPixelBuffer may have): every sample exact.
        let f = try XCTUnwrap(convert(bgra(uniform((255, 0, 0), width: 800, height: 384), padding: 64), width: 800, height: 384))
        XCTAssertTrue(f.y.allSatisfy { $0 == 82 })
        XCTAssertTrue(f.cb.allSatisfy { $0 == 90 })
        XCTAssertTrue(f.cr.allSatisfy { $0 == 240 })
    }
}
