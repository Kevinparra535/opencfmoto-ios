// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §3.5): the vImage BGRA → I420 converter (BT.601 video range) — the
// values of the integer reference (black 16/128/128, white 235/128/128, red 82/90/240) within ±2,
// chroma from 2×2 blocks, and row padding (`bytesPerRow` > width × 4) honoured. Independent of
// Core's reference converter; the vImage-vs-reference oracle is added at integration.
#if canImport(Accelerate) && canImport(CoreVideo)
import CoreVideo
import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PixelConverterTests: XCTestCase {
    private func assertPlane(_ plane: [UInt8], _ expected: UInt8, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let worst = plane.map { abs(Int($0) - Int(expected)) }.max() ?? 99
        XCTAssertLessThanOrEqual(worst, 2, "\(name): \(Set(plane).sorted().prefix(6)) vs \(expected)", file: file, line: line)
    }

    private func converted(_ color: DashColor, width: Int = 32, height: Int = 16) throws -> I420Frame {
        let buffer = try XCTUnwrap(PixelBufferFactory.makeStandaloneBuffer(width: width, height: height))
        XCTAssertTrue(PixelBufferFactory.fill(buffer, with: color))
        let converter = try XCTUnwrap(BGRAToI420Converter())
        var frame = try XCTUnwrap(I420Frame(width: width, height: height))
        XCTAssertTrue(converter.convert(buffer, into: &frame))
        return frame
    }

    func testBlackWhiteAndRedMatchTheBT601VideoRangeValues() throws {
        for (color, y, cb, cr, name) in [(DashColor(rgb: 0x000000), UInt8(16), UInt8(128), UInt8(128), "black"),
                                         (DashColor(rgb: 0xFFFFFF), 235, 128, 128, "white"),
                                         (DashColor(rgb: 0xFF0000), 82, 90, 240, "red")] {
            let f = try converted(color)
            assertPlane(f.y, y, "\(name) Y")
            assertPlane(f.cb, cb, "\(name) Cb")
            assertPlane(f.cr, cr, "\(name) Cr")
        }
    }

    /// Rows `bytesPerRow` apart with garbage in the padding: only the pixels count, and each chroma
    /// sample comes from its own 2×2 block.
    func testPaddedRowsAndTwoByTwoChromaBlocks() throws {
        let width = 8, height = 4, bytesPerRow = width * 4 + 24
        var bgra = [UInt8](repeating: 0xEE, count: bytesPerRow * height) // padding: near-white garbage
        for y in 0 ..< height {
            for x in 0 ..< width {
                let red = x < width / 2 // left half red, right half blue
                let p = y * bytesPerRow + x * 4
                bgra[p] = red ? 0 : 255     // B
                bgra[p + 1] = 0             // G
                bgra[p + 2] = red ? 255 : 0 // R
                bgra[p + 3] = 255           // A
            }
        }
        let converter = try XCTUnwrap(BGRAToI420Converter())
        var frame = try XCTUnwrap(I420Frame(width: width, height: height))
        let ok = bgra.withUnsafeBytes { raw in
            converter.convert(bgra: raw.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow,
                              into: &frame)
        }
        XCTAssertTrue(ok)
        // Blue (0, 0, 255): Y 41, Cb 240, Cr 110 (BT.601 video range).
        for y in 0 ..< height {
            for x in 0 ..< width {
                let expected: UInt8 = x < width / 2 ? 82 : 41
                XCTAssertLessThanOrEqual(abs(Int(frame.y[y * width + x]) - Int(expected)), 2, "Y(\(x),\(y))")
            }
        }
        for y in 0 ..< height / 2 {
            for x in 0 ..< width / 2 {
                let red = x < width / 4
                XCTAssertLessThanOrEqual(abs(Int(frame.cb[y * width / 2 + x]) - (red ? 90 : 240)), 2, "Cb(\(x),\(y))")
                XCTAssertLessThanOrEqual(abs(Int(frame.cr[y * width / 2 + x]) - (red ? 240 : 110)), 2, "Cr(\(x),\(y))")
            }
        }
    }

    /// A pixel buffer whose rows CoreVideo padded (an odd number of 4-byte pixels per 64-byte row).
    func testPixelBufferRowPaddingIsHonoured() throws {
        let width = 18, height = 6
        let buffer = try XCTUnwrap(PixelBufferFactory.makeStandaloneBuffer(width: width, height: height))
        XCTAssertTrue(PixelBufferFactory.fill(buffer, with: DashColor(rgb: 0xFFFFFF)))
        let frame = try converted(DashColor(rgb: 0xFFFFFF), width: width, height: height)
        assertPlane(frame.y, 235, "Y")
        assertPlane(frame.cb, 128, "Cb")
        XCTAssertGreaterThanOrEqual(CVPixelBufferGetBytesPerRow(buffer), width * 4)
    }

    func testSizeMismatchIsRefused() throws {
        let converter = try XCTUnwrap(BGRAToI420Converter())
        let buffer = try XCTUnwrap(PixelBufferFactory.makeStandaloneBuffer(width: 32, height: 16))
        var other = try XCTUnwrap(I420Frame(width: 16, height: 16))
        XCTAssertFalse(converter.convert(buffer, into: &other))
        let bytes = [UInt8](repeating: 0, count: 64)
        let short = bytes.withUnsafeBytes { raw in
            converter.convert(bgra: raw.baseAddress!, width: 16, height: 16, bytesPerRow: 32, into: &other)
        }
        XCTAssertFalse(short, "bytesPerRow < width × 4")
    }

    /// The dry run converts the 800×384 dash canvas once per frame into the same planes.
    func testDashCanvasConvertsIntoReusedPlanes() throws {
        let frame1 = try converted(DashColor(rgb: 0x203040), width: 800, height: 384)
        XCTAssertEqual(frame1.y.count, 800 * 384)
        XCTAssertEqual(frame1.cb.count, 400 * 192)
        let converter = try XCTUnwrap(BGRAToI420Converter())
        let buffer = try XCTUnwrap(PixelBufferFactory.makeStandaloneBuffer(width: 800, height: 384))
        XCTAssertTrue(PixelBufferFactory.fill(buffer, with: DashColor(rgb: 0x000000)))
        var frame = frame1
        XCTAssertTrue(converter.convert(buffer, into: &frame))
        assertPlane(frame.y, 16, "Y after reuse")
        XCTAssertEqual(frame.y.count, 800 * 384, "the same plane sizes")
    }
}
#endif
