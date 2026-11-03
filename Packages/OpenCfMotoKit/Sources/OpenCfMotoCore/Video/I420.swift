// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §3.5): the I420 picture a CPU H.264 encoder takes, and the integer
// BT.601 limited-range BGRA → I420 reference conversion. The app converts with vImage on the CPU
// (OpenCfMotoApple `BGRAToI420Converter`, used by the Phase 0 background dry run); this reference is
// what the Linux tests check and the oracle the vImage converter is compared with on macOS.
//
//   Y  = ((66R + 129G + 25B + 128) >> 8) + 16
//   Cb = ((−38R − 74G + 112B + 128) >> 8) + 128
//   Cr = ((112R − 94G − 18B + 128) >> 8) + 128      (>> is an arithmetic shift)
//
// Chroma is computed from the mean of each 2×2 block's R, G and B, rounded ((sum + 2) / 4). Black is
// (16, 128, 128), white (235, 128, 128), pure red (82, 90, 240).

import Foundation

/// An 8-bit planar YUV 4:2:0 picture: the Y plane (`width × height`), then Cb (U) and Cr (V)
/// (`width/2 × height/2` each), video range, tightly packed (stride = plane width). Reused across
/// frames: the converters write into existing planes, nothing is allocated per frame.
public struct I420Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var y: [UInt8]
    public var cb: [UInt8]
    public var cr: [UInt8]

    /// Bytes per row of the Y plane.
    public var lumaStride: Int { width }
    /// Bytes per row of the Cb and Cr planes.
    public var chromaStride: Int { width / 2 }
    public var chromaWidth: Int { width / 2 }
    public var chromaHeight: Int { height / 2 }

    /// Zero-filled planes; nil for odd, non-positive or absurd (> 8192) sizes.
    public init?(width: Int, height: Int) {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0, width <= 8192, height <= 8192 else { return nil }
        self.width = width
        self.height = height
        y = [UInt8](repeating: 0, count: width * height)
        cb = [UInt8](repeating: 0, count: (width / 2) * (height / 2))
        cr = [UInt8](repeating: 0, count: (width / 2) * (height / 2))
    }
}

public enum BGRAToI420 {
    /// Converts 32-bit BGRA pixels (bytes B, G, R, A per pixel — CoreGraphics' premultiplied-first
    /// little-endian layout; alpha is ignored, the dash UI is opaque) with `bytesPerRow` ≥ `width × 4`
    /// (row padding is skipped) into `frame`, whose size must be `width × height`. Returns false and
    /// leaves `frame` unchanged for odd sizes, a size mismatch, a short `bytesPerRow` or a short buffer.
    ///
    /// The buffer must hold `bytesPerRow × (height − 1) + width × 4` bytes at least (the last row
    /// needs no padding).
    public static func reference(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                                 into frame: inout I420Frame) -> Bool {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0, frame.width == width, frame.height == height,
              bytesPerRow >= width * 4 else { return false }
        let (padded, overflow) = bytesPerRow.multipliedReportingOverflow(by: height - 1)
        let (needed, overflow2) = padded.addingReportingOverflow(width * 4)
        guard !overflow, !overflow2, bgra.count >= needed else { return false }
        let chromaWidth = width / 2
        frame.y.withUnsafeMutableBufferPointer { y in
            frame.cb.withUnsafeMutableBufferPointer { cb in
                frame.cr.withUnsafeMutableBufferPointer { cr in
                    for row in stride(from: 0, to: height, by: 2) {
                        let top = row * bytesPerRow, bottom = top + bytesPerRow
                        for col in stride(from: 0, to: width, by: 2) {
                            // The 2×2 block: (row, col), (row, col + 1), (row + 1, col), (row + 1, col + 1).
                            var sumR = 0, sumG = 0, sumB = 0
                            func pixel(_ offset: Int, _ lumaIndex: Int) {
                                let b = Int(bgra[offset]), g = Int(bgra[offset + 1]), r = Int(bgra[offset + 2])
                                y[lumaIndex] = UInt8(truncatingIfNeeded: luma(r: r, g: g, b: b))
                                sumR += r
                                sumG += g
                                sumB += b
                            }
                            pixel(top + col * 4, row * width + col)
                            pixel(top + col * 4 + 4, row * width + col + 1)
                            pixel(bottom + col * 4, (row + 1) * width + col)
                            pixel(bottom + col * 4 + 4, (row + 1) * width + col + 1)
                            let r = (sumR + 2) / 4, g = (sumG + 2) / 4, b = (sumB + 2) / 4
                            let chromaIndex = (row / 2) * chromaWidth + col / 2
                            cb[chromaIndex] = UInt8(truncatingIfNeeded: blueDifference(r: r, g: g, b: b))
                            cr[chromaIndex] = UInt8(truncatingIfNeeded: redDifference(r: r, g: g, b: b))
                        }
                    }
                }
            }
        }
        return true
    }

    // For 8-bit R, G, B the formulas stay within 16…235 (Y) and 16…240 (Cb, Cr), so the UInt8
    // conversions above never truncate.

    /// Y = ((66R + 129G + 25B + 128) >> 8) + 16.
    static func luma(r: Int, g: Int, b: Int) -> Int { ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16 }

    /// Cb = ((−38R − 74G + 112B + 128) >> 8) + 128 (arithmetic shift).
    static func blueDifference(r: Int, g: Int, b: Int) -> Int { ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128 }

    /// Cr = ((112R − 94G − 18B + 128) >> 8) + 128 (arithmetic shift).
    static func redDifference(r: Int, g: Int, b: Int) -> Int { ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128 }

    /// Convenience over `reference(bgra:width:height:bytesPerRow:into:)`: a new frame, nil on the same
    /// failures.
    public static func reference(bgra: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> I420Frame? {
        guard var frame = I420Frame(width: width, height: height) else { return nil }
        let ok = bgra.withUnsafeBytes { raw in
            reference(bgra: raw, width: width, height: height, bytesPerRow: bytesPerRow, into: &frame)
        }
        return ok ? frame : nil
    }
}
