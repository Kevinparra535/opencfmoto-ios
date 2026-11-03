// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (design §3.5, P0-8): 32BGRA → I420 on the CPU with vImage, the pixel path a
// CPU H.264 encoder takes in the background (Phase 1) and the conversion the Phase 0 background dry
// run measures. BT.601 (ITU-R 601-4) video range: Y 16–235, CbCr 16–240, chroma of each 2×2 block —
// the same picture as the integer reference `BGRAToI420.reference` in Core (within ±2).
//
// Background rules: CPU only. No VTPixelTransferSession, Core Image, Metal or UIKit snapshot here (they
// may need the GPU, which a locked iPhone does not give the app).

#if canImport(Accelerate) && canImport(CoreVideo)
import Accelerate
import CoreVideo
import Foundation
import OpenCfMotoCore

/// Converts 32BGRA pixels (CoreGraphics premultiplied-first little-endian: bytes B, G, R, A; the dash
/// UI is opaque) into a reused `I420Frame`. The vImage conversion is generated once at `init`;
/// nothing is allocated per frame. Not thread-safe: use one converter per queue.
public final class BGRAToI420Converter: @unchecked Sendable {
    /// `vImageConvert_ARGB8888To420Yp8_Cb8_Cr8` reads ARGB; this permute map makes it read BGRA.
    private static let permuteMap: [UInt8] = [3, 2, 1, 0]
    private var info = vImage_ARGBToYpCbCr()

    /// nil when vImage refuses to generate the conversion.
    public init?() {
        // 8-bit video range (Y 16–235, CbCr 16–240).
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                             YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        let error = vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &info,
                                                                   kvImageARGB8888, kvImage420Yp8_Cb8_Cr8,
                                                                   vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { return nil }
    }

    /// Converts a 32BGRA pixel buffer of exactly `frame.width × frame.height` (row padding of
    /// `CVPixelBufferGetBytesPerRow` honoured; locked read-only while converting). False for another
    /// format or size, a lock failure or a vImage error; `frame` is then unspecified.
    @discardableResult
    public func convert(_ pixelBuffer: CVPixelBuffer, into frame: inout I420Frame) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixelBuffer) == frame.width, CVPixelBufferGetHeight(pixelBuffer) == frame.height,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { _ = CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        return convert(bgra: UnsafeRawPointer(base), width: frame.width, height: frame.height,
                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), into: &frame)
    }

    /// Converts `height` rows of `width` BGRA pixels, `bytesPerRow` apart (≥ `width × 4`), into
    /// `frame` (same size; even width and height). False on a size mismatch or a vImage error.
    @discardableResult
    public func convert(bgra base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                        into frame: inout I420Frame) -> Bool {
        guard width == frame.width, height == frame.height, width > 0, height > 0, width % 2 == 0, height % 2 == 0,
              bytesPerRow >= width * 4 else { return false }
        // Move the planes out of `frame` (no copy), write them, move them back.
        var y: [UInt8] = []
        var cb: [UInt8] = []
        var cr: [UInt8] = []
        swap(&y, &frame.y)
        swap(&cb, &frame.cb)
        swap(&cr, &frame.cr)
        defer {
            swap(&y, &frame.y)
            swap(&cb, &frame.cb)
            swap(&cr, &frame.cr)
        }
        let chromaWidth = width / 2
        let chromaHeight = height / 2
        guard y.count >= width * height, cb.count >= chromaWidth * chromaHeight, cr.count >= chromaWidth * chromaHeight
        else { return false }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: bytesPerRow)
        let error: vImage_Error = y.withUnsafeMutableBytes { (yRaw: UnsafeMutableRawBufferPointer) -> vImage_Error in
            cb.withUnsafeMutableBytes { (cbRaw: UnsafeMutableRawBufferPointer) -> vImage_Error in
                cr.withUnsafeMutableBytes { (crRaw: UnsafeMutableRawBufferPointer) -> vImage_Error in
                    var yPlane = vImage_Buffer(data: yRaw.baseAddress, height: vImagePixelCount(height),
                                               width: vImagePixelCount(width), rowBytes: width)
                    var cbPlane = vImage_Buffer(data: cbRaw.baseAddress, height: vImagePixelCount(chromaHeight),
                                                width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                    var crPlane = vImage_Buffer(data: crRaw.baseAddress, height: vImagePixelCount(chromaHeight),
                                                width: vImagePixelCount(chromaWidth), rowBytes: chromaWidth)
                    return vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&source, &yPlane, &cbPlane, &crPlane, &info,
                                                                  Self.permuteMap, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        return error == kvImageNoError
    }
}
#endif
