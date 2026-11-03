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
    public static func reference(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                                 into frame: inout I420Frame) -> Bool {
        _ = (bgra, width, height, bytesPerRow, frame)
        return false // step-0 placeholder: K implements
    }

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
