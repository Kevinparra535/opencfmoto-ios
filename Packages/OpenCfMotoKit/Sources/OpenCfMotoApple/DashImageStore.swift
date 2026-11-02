// SPDX-License-Identifier: AGPL-3.0-or-later
// Raster images of the dash UI that are not map tiles — Apple Music album artwork (iOS addition,
// scratchpad contract "music" §8.4): the app registers encoded bytes under an id
// (`DashProjecting.setDashImage(id:data:)`), display lists draw them with
// `DashDrawCommand.image(id:rect:cornerRadius:)` (DashRenderer).
//
// - Bytes are validated with ImageIO when registered and decoded lazily, once, on first use:
//   `CGImageSourceCreateThumbnailAtIndex` (≤ `maxDecodePixels`, EXIF orientation applied), redrawn
//   into 32BGRA premultiplied like the map tiles.
// - Per device rect a variant is made: aspect FILL + centred crop at exactly the rect's pixel size
//   with high-quality scaling — or, when the decode is smaller than that, the cropped decode itself
//   (never upscaled past the decode; the renderer stretches it). Variants live in a small LRU, so a
//   song's cover is scaled once for the tile and once for the sheet, not every frame.
// - A memory warning (observed by notification NAME, no UIKit import) drops the decodes and the
//   variants but keeps the bytes; the next draw decodes again.
// Thread-safe (one lock): the main actor registers, the render queue draws.

import Foundation
import OpenCfMotoCore

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO

public final class DashImageStore: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Longest side of a decoded image (the dash never shows artwork larger than ~600 px).
        public var maxDecodePixels = 640
        /// Images kept (least recently used ones are dropped).
        public var capacity = 6
        /// Scaled variants kept.
        public var variantCapacity = 8
        public init() {}
    }

    public let configuration: Configuration

    /// Largest variant edge accepted (a 4K dash would need 3840).
    static let maxVariantPixels = 4_096

    private struct Entry {
        var data: Data
        var decoded: CGImage?
        var lastUse: UInt64
        /// Bumps when the bytes are replaced: variants of the old bytes are never served.
        var generation: UInt64
    }

    private struct VariantKey: Hashable {
        let id: String
        let generation: UInt64
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var variants: VideoLRU<VariantKey, CGImage>
    private var tick: UInt64 = 0
    private var generations: UInt64 = 0
    private var memoryWarningToken: NSObjectProtocol?
    /// Decodes so far (tests: purge + re-decode).
    private(set) var decodeCount = 0
    /// Variants made so far (tests: the variant cache).
    private(set) var variantCount = 0

    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// BGRA in memory, premultiplied alpha (DashRenderer / TileImageCache layout).
    static let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        variants = VideoLRU(capacity: max(1, configuration.variantCapacity))
        // UIApplication.didReceiveMemoryWarningNotification by name (no UIKit import; never fires on macOS).
        memoryWarningToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil, queue: nil
        ) { [weak self] _ in self?.purgeDecoded() }
    }

    deinit {
        if let t = memoryWarningToken { NotificationCenter.default.removeObserver(t) }
    }

    /// Registers (or replaces) the encoded image `id`. false (nothing stored, an older image under
    /// `id` is removed too) when ImageIO cannot read the bytes.
    @discardableResult
    public func set(id: String, data: Data) -> Bool {
        let valid = Self.isReadable(data)
        lock.lock()
        defer { lock.unlock() }
        variants.removeAll { $0.id == id }
        guard valid else {
            entries[id] = nil
            return false
        }
        tick &+= 1
        generations &+= 1
        entries[id] = Entry(data: data, decoded: nil, lastUse: tick, generation: generations)
        let capacity = max(1, configuration.capacity)
        while entries.count > capacity,
              let oldest = entries.filter({ $0.key != id }).min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries[oldest] = nil
            variants.removeAll { $0.id == oldest }
        }
        return true
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[id] = nil
        variants.removeAll { $0.id == id }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        variants.removeAll()
    }

    public func contains(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[id] != nil
    }

    /// Ids currently registered (diagnostics, tests).
    public var ids: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted()
    }

    /// The image `id` for a device rect of `pixelWidth` × `pixelHeight`: aspect fill + centred crop
    /// at exactly that size, or the cropped decode when it is smaller (never upscaled). nil = unknown
    /// id, bytes that do not decode, or a degenerate size.
    public func image(id: String, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth <= Self.maxVariantPixels,
              pixelHeight <= Self.maxVariantPixels else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[id] else { return nil }
        tick &+= 1
        entry.lastUse = tick
        let key = VariantKey(id: id, generation: entry.generation, width: pixelWidth, height: pixelHeight)
        if let hit = variants.get(key) {
            entries[id] = entry
            return hit
        }
        if entry.decoded == nil {
            entry.decoded = Self.decode(entry.data, maxPixels: configuration.maxDecodePixels)
            decodeCount += 1
        }
        entries[id] = entry
        guard let decoded = entry.decoded,
              let variant = Self.fillVariant(decoded, width: pixelWidth, height: pixelHeight) else { return nil }
        variantCount += 1
        variants.set(key, variant)
        return variant
    }

    /// Memory warning: drop decodes and variants, keep the bytes.
    public func purgeDecoded() {
        lock.lock()
        defer { lock.unlock() }
        for id in Array(entries.keys) { entries[id]?.decoded = nil }
        variants.removeAll()
    }

    // MARK: - ImageIO / CoreGraphics

    /// ImageIO knows the format, the data is complete and holds at least one image.
    static func isReadable(_ data: Data) -> Bool {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetStatus(source) == .statusComplete
            && CGImageSourceGetCount(source) > 0
    }

    /// Decoded (EXIF orientation applied), longest side ≤ `maxPixels`, as 32BGRA premultiplied.
    static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return redraw(image, width: image.width, height: image.height, draw: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                      quality: .none)
    }

    /// The part of `image` an aspect-FILL of `width` × `height` shows (centred), at that size — or at
    /// the crop's own size when that is smaller (never upscaled).
    static func fillVariant(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let w0 = Double(image.width), h0 = Double(image.height)
        guard w0 > 0, h0 > 0 else { return nil }
        let scale = max(Double(width) / w0, Double(height) / h0) // source px → variant px
        let cropW = Double(width) / scale, cropH = Double(height) / scale // the visible part, source px
        let k = min(1, scale) // never upscale: at most 1 variant px per source px
        let outW = max(1, Int((cropW * k).rounded())), outH = max(1, Int((cropH * k).rounded()))
        // Place the whole image so the centred crop covers the output (CG is y-up; a centred crop
        // is symmetric, so the same offsets work vertically).
        let drawW = w0 * Double(outW) / cropW, drawH = h0 * Double(outH) / cropH
        let rect = CGRect(x: (Double(outW) - drawW) / 2, y: (Double(outH) - drawH) / 2, width: drawW, height: drawH)
        return redraw(image, width: outW, height: outH, draw: rect, quality: .high)
    }

    private static func redraw(_ image: CGImage, width: Int, height: Int, draw rect: CGRect,
                               quality: CGInterpolationQuality) -> CGImage? {
        guard width > 0, height > 0, width <= maxVariantPixels, height <= maxVariantPixels,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = quality
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
#endif
