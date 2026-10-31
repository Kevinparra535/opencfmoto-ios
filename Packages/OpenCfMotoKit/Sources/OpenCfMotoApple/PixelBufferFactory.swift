// SPDX-License-Identifier: AGPL-3.0-or-later
// IOSurface-backed 32BGRA CVPixelBuffers at exactly the negotiated canvas size — the render
// target of the CoreGraphics dash renderer and the input of the VideoToolbox encoder
// (docs/spec/media-video.md §15.5, ios-platform-facts.md design recommendation 3).

#if canImport(CoreVideo)
import CoreVideo
import Foundation
import OpenCfMotoCore

public enum PixelBufferFactoryError: Error, CustomStringConvertible {
    case invalidSize(width: Int, height: Int)
    case poolCreationFailed(CVReturn)

    public var description: String {
        switch self {
        case let .invalidSize(w, h): return "invalid pixel buffer size \(w)x\(h)"
        case let .poolCreationFailed(r): return "CVPixelBufferPoolCreate failed (\(r))"
        }
    }
}

/// A small pool of 32BGRA, IOSurface-backed, CoreGraphics-compatible pixel buffers.
/// Thread-safe (CVPixelBufferPool is thread-safe).
public final class PixelBufferFactory: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// Buffers in use (rendering, held by the encoder, kept as "last picture") never exceed this;
    /// `makeBuffer()` returns nil instead of allocating more.
    public let maximumBufferCount: Int
    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary

    public init(width: Int, height: Int, minimumBufferCount: Int = 3, maximumBufferCount: Int = 6) throws {
        guard width > 0, height > 0 else { throw PixelBufferFactoryError.invalidSize(width: width, height: height) }
        self.width = width
        self.height = height
        self.maximumBufferCount = max(1, maximumBufferCount)
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: max(1, minimumBufferCount),
        ]
        var out: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary,
                                             Self.bufferAttributes(width: width, height: height) as CFDictionary, &out)
        guard status == kCVReturnSuccess, let pool = out else { throw PixelBufferFactoryError.poolCreationFailed(status) }
        self.pool = pool
        auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: self.maximumBufferCount] as CFDictionary
    }

    /// Attributes of every buffer: 32BGRA, exact size, IOSurface-backed, CG-compatible.
    public static func bufferAttributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
    }

    /// A buffer from the pool, or nil when `maximumBufferCount` buffers are already in use.
    public func makeBuffer() -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &out)
        if status == kCVReturnWouldExceedAllocationThreshold {
            Log.shared.throttled("pb-pool-\(width)x\(height)", interval: 5, .debug, "VIDEO",
                                 "pixel buffer pool \(width)x\(height) exhausted (\(maximumBufferCount) in use)")
            return nil
        }
        guard status == kCVReturnSuccess else { return nil }
        return out
    }

    /// Releases idle buffers (e.g. when going to the background).
    public func flush() {
        CVPixelBufferPoolFlush(pool, CVPixelBufferPoolFlushFlags.excessBuffers)
    }

    /// A standalone buffer with the same attributes (tests, one-off pictures).
    public static func makeStandaloneBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         bufferAttributes(width: width, height: height) as CFDictionary, &out)
        return status == kCVReturnSuccess ? out : nil
    }

    /// Fills a 32BGRA buffer with one opaque colour (alpha forced to 255).
    @discardableResult
    public static func fill(_ buffer: CVPixelBuffer, with color: DashColor) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return false }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let b = UInt8(truncatingIfNeeded: color.argb)
        let g = UInt8(truncatingIfNeeded: color.argb >> 8)
        let r = UInt8(truncatingIfNeeded: color.argb >> 16)
        for y in 0 ..< h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< w {
                row[x * 4] = b
                row[x * 4 + 1] = g
                row[x * 4 + 2] = r
                row[x * 4 + 3] = 255
            }
        }
        return true
    }

    /// Reads one pixel of a 32BGRA buffer as (r, g, b, a) — diagnostics and tests.
    public static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        guard x >= 0, y >= 0, x < CVPixelBufferGetWidth(buffer), y < CVPixelBufferGetHeight(buffer) else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let p = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(to: UInt8.self)
        return (p[2], p[1], p[0], p[3])
    }
}
#endif
