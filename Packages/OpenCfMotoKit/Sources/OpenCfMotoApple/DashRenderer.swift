// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) DashMapController.kt (raster tiles drawn on a Canvas, night
// INVERT_COLORS on tiles only) and the GpxDashUi.kt text/card rendering it composites with.
// Executes a DashDisplayList (OpenCfMotoCore/Dash/DisplayList.swift) with CoreGraphics + CoreText
// into a 32BGRA CVPixelBuffer at the negotiated canvas size — the CPU-only "own UI" path of
// docs/spec/media-video.md §15.5 and navigation-dash.md §15 note 3.
//
// Coordinate system: canvas pixels, origin TOP-LEFT, y down (= dash touch coordinates). The
// bitmap context is flipped once (translate(0,h) + scale(1,−1)); text and images are drawn with
// a local re-flip so they appear upright.

import Foundation
import OpenCfMotoCore

// MARK: - Platform-neutral text layout (unit-tested on Linux)

/// Line breaking of the `DashDrawCommand.text` contract. Mirrors the core layout helper
/// (`DashTextLayout.wrap/truncate` of the dash UI builder) rule for rule, so the renderer breaks
/// lines exactly where the layout engine sized the box: greedy word wrap at spaces, explicit "\n"
/// are hard breaks (an empty hard line stays an empty line), a word wider than the line is broken
/// between characters, at most `maxLines` lines and — when text is cut — the remainder is folded
/// into the last line, which always ends with "…" (longest prefix + "…" that fits, trailing
/// spaces trimmed). `width` must use the same model as the layout engine:
/// measurer width + letterSpacingEm × size × characterCount.
enum DashTextWrapper {
    static let ellipsis = "…"
    static let epsilon = 0.01

    /// `text` if it fits, else the longest prefix + "…" that fits ("…" alone if nothing fits).
    static func truncate(_ text: String, maxWidth: Double, width: (String) -> Double) -> String {
        if width(text) <= maxWidth + epsilon { return text }
        return ellipsized(text, maxWidth: maxWidth, width: width)
    }

    /// Always ends with "…": the longest prefix (possibly all of `text`) + "…" that fits.
    static func ellipsized(_ text: String, maxWidth: Double, width: (String) -> Double) -> String {
        let chars = Array(text)
        var lo = 0, hi = chars.count // number of characters kept
        func candidate(_ n: Int) -> String {
            var s = String(chars[0 ..< n])
            while s.last == " " { s.removeLast() }
            return s + ellipsis
        }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if width(candidate(mid)) <= maxWidth + epsilon {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return candidate(lo)
    }

    static func wrap(_ text: String, maxWidth: Double, maxLines: Int, width w: (String) -> Double) -> [String] {
        let maxLines = max(1, maxLines)
        if maxLines == 1, !text.contains("\n") {
            return [truncate(text, maxWidth: maxWidth, width: w)]
        }
        var lines: [String] = []
        for hard in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var words = hard.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if words.isEmpty { lines.append(""); continue }
            var line = ""
            var idx = 0
            while idx < words.count {
                let word = words[idx]
                let candidate = line.isEmpty ? word : line + " " + word
                if w(candidate) <= maxWidth + epsilon {
                    line = candidate
                    idx += 1
                } else if line.isEmpty {
                    // A single word wider than the line: break it between characters.
                    let chars = Array(word)
                    var n = 1
                    while n < chars.count, w(String(chars[0 ..< (n + 1)])) <= maxWidth + epsilon { n += 1 }
                    lines.append(String(chars[0 ..< n]))
                    if n >= chars.count { idx += 1 } else { words[idx] = String(chars[n...]) }
                } else {
                    lines.append(line)
                    line = ""
                }
            }
            if !line.isEmpty { lines.append(line) }
        }
        if lines.count <= maxLines { return lines }
        var kept = Array(lines[0 ..< (maxLines - 1)])
        let rest = lines[(maxLines - 1)...].joined(separator: " ")
        kept.append(ellipsized(rest, maxWidth: maxWidth, width: w))
        return kept
    }
}

/// Vertical / horizontal placement of a laid-out text block (contract rule).
enum DashTextBlockGeometry {
    /// Baseline of line i = rect.minY + (rect.height − n·lineHeight)/2 + i·lineHeight + ascent.
    static func baselines(lineCount n: Int, rect: DashRect, ascent: Double, descent: Double) -> [Double] {
        guard n > 0 else { return [] }
        let lineHeight = ascent + descent
        let top = rect.minY + (rect.height - Double(n) * lineHeight) / 2
        return (0 ..< n).map { top + Double($0) * lineHeight + ascent }
    }

    /// Left x of a line of `lineWidth` inside `rect`.
    static func lineX(lineWidth: Double, rect: DashRect, alignment: DashTextAlignment) -> Double {
        switch alignment {
        case .left: return rect.minX
        case .center: return rect.minX + (rect.width - lineWidth) / 2
        case .right: return rect.maxX - lineWidth
        }
    }
}

// MARK: - CoreGraphics renderer (Apple platforms)

#if canImport(CoreGraphics) && canImport(CoreText) && canImport(CoreVideo)
import CoreGraphics
import CoreText
import CoreVideo

/// Counters of the last `render` call (diagnostics).
public struct DashRendererStats: Sendable, Equatable {
    public var commands = 0
    public var tilesDrawn = 0
    public var tilesMissing = 0
    public var tilesFromParent = 0
    public var textBlocks = 0
    /// `DashDrawCommand.image` drawn from the image store (album artwork) / not found there.
    public var imagesDrawn = 0
    public var imagesMissing = 0
    public init() {}
}

/// Renders `DashDisplayList`s with CoreGraphics on the CPU (safe in the background: no GPU).
/// Thread-safe: concurrent `render` calls are serialized by an internal lock.
public final class DashRenderer: @unchecked Sendable {
    public let fonts: DashFontProvider
    private let lock = NSLock()
    private var _tileCache: TileImageCache?
    private var _imageStore: DashImageStore?
    private var colors: [UInt32: CGColor] = [:]
    private var textLayouts: [TextLayoutKey: TextLayout] = [:]
    private var _stats = DashRendererStats()

    /// Placeholder for a missing tile (classic day / night; muted day / night, P0 D05).
    public var tilePlaceholderDay = DashColor(rgb: 0xE9E5DC)
    public var tilePlaceholderNight = DashColor(rgb: 0x262A2E)
    public var tilePlaceholderMutedDay = DashColor(rgb: 0xE5E4E0)
    public var tilePlaceholderMutedNight = DashColor(rgb: 0x16191D)
    /// Draw a cached ancestor tile (scaled up) while a tile is loading.
    public var usesParentTileFallback = true
    /// Resampling quality for tiles (map tiles are over-zoomed / rotated).
    public var tileInterpolation: CGInterpolationQuality = .low

    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// BGRA in memory, premultiplied alpha: the CVPixelBuffer 32BGRA layout.
    static let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    public init(tileCache: TileImageCache? = nil, imageStore: DashImageStore? = nil, fonts: DashFontProvider = .shared) {
        self.fonts = fonts
        _tileCache = tileCache
        _imageStore = imageStore
    }

    public var tileCache: TileImageCache? {
        get { lock.lock(); defer { lock.unlock() }; return _tileCache }
        set { lock.lock(); _tileCache = newValue; lock.unlock() }
    }

    /// Raster images drawn by `DashDrawCommand.image` (Apple Music artwork); nil draws none.
    public var imageStore: DashImageStore? {
        get { lock.lock(); defer { lock.unlock() }; return _imageStore }
        set { lock.lock(); _imageStore = newValue; lock.unlock() }
    }

    /// Statistics of the last render.
    public var stats: DashRendererStats { lock.lock(); defer { lock.unlock() }; return _stats }

    /// Renders `list` into a 32BGRA pixel buffer (the whole buffer is overwritten). If the list
    /// size differs from the buffer it is scaled to fill the buffer. Returns false if the buffer
    /// is not 32BGRA or cannot be locked.
    @discardableResult
    public func render(_ list: DashDisplayList, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return false }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return false }
        defer { _ = CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else { return false }
        draw(list, in: ctx, pixelWidth: w, pixelHeight: h)
        return true
    }

    /// Renders `list` into a new image (phone-side "Dash view" preview, snapshots, tests).
    public func makeImage(_ list: DashDisplayList, scale: Double = 1) -> CGImage? {
        let s = scale.isFinite && scale > 0 ? scale : 1
        let w = max(1, Int((list.size.width * s).rounded()))
        let h = max(1, Int((list.size.height * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else { return nil }
        draw(list, in: ctx, pixelWidth: w, pixelHeight: h)
        return ctx.makeImage()
    }

    /// An independent copy of a 32BGRA pixel buffer as a CGImage (safe to keep after the buffer
    /// is reused by its pool).
    public static func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { _ = CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = Data(bytes: base, count: bpr * h)
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draws `list` into a bitmap context whose CTM is the CoreGraphics default (origin bottom-left,
    /// 1 unit = 1 pixel). The context state is restored afterwards.
    public func draw(_ list: DashDisplayList, in ctx: CGContext, pixelWidth: Int, pixelHeight: Int) {
        lock.lock()
        defer { lock.unlock() }
        var stats = DashRendererStats()
        stats.commands = list.commands.count
        let tiles = _tileCache
        let images = _imageStore

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)
        ctx.interpolationQuality = tileInterpolation

        // Background: overwrite every pixel (pool buffers still hold old frames).
        ctx.setBlendMode(.copy)
        ctx.setFillColor(cgColor(list.background))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.setBlendMode(.normal)

        if list.size.width > 0, list.size.height > 0,
           abs(list.size.width - Double(pixelWidth)) > 0.5 || abs(list.size.height - Double(pixelHeight)) > 0.5 {
            ctx.scaleBy(x: CGFloat(Double(pixelWidth) / list.size.width), y: CGFloat(Double(pixelHeight) / list.size.height))
        }

        var depth = 0
        for command in list.commands {
            switch command {
            case let .fill(path, color, rule):
                guard !path.isEmpty, color.alpha > 0 else { continue }
                ctx.beginPath()
                ctx.addPath(Self.cgPath(path))
                ctx.setFillColor(cgColor(color))
                ctx.fillPath(using: rule == .evenOdd ? .evenOdd : .winding)
            case let .stroke(path, stroke):
                guard !path.isEmpty, stroke.width > 0, stroke.width.isFinite, stroke.color.alpha > 0 else { continue }
                ctx.saveGState()
                ctx.setLineWidth(CGFloat(stroke.width))
                ctx.setLineCap(Self.cgCap(stroke.cap))
                ctx.setLineJoin(Self.cgJoin(stroke.join))
                let dashes = stroke.dash.filter { $0.isFinite && $0 >= 0 }
                if dashes.count == stroke.dash.count, dashes.reduce(0, +) > 0 {
                    ctx.setLineDash(phase: 0, lengths: dashes.map { CGFloat($0) })
                }
                ctx.setStrokeColor(cgColor(stroke.color))
                ctx.beginPath()
                ctx.addPath(Self.cgPath(path))
                ctx.strokePath()
                ctx.restoreGState()
            case let .text(text, rect, style):
                guard !text.isEmpty, style.color.alpha > 0 else { continue }
                stats.textBlocks += 1
                drawText(text, rect: rect, style: style, in: ctx)
            case let .tile(z, x, y, rect, treatment):
                drawTile(z: z, x: x, y: y, rect: rect, treatment: treatment, cache: tiles, in: ctx, stats: &stats)
            case let .image(id, rect, cornerRadius):
                drawImage(id: id, rect: rect, cornerRadius: cornerRadius, store: images, in: ctx, stats: &stats)
            case .save:
                ctx.saveGState()
                depth += 1
            case .restore:
                if depth > 0 {
                    ctx.restoreGState()
                    depth -= 1
                }
            case let .transform(t):
                ctx.concatenate(CGAffineTransform(a: CGFloat(t.a), b: CGFloat(t.b), c: CGFloat(t.c),
                                                  d: CGFloat(t.d), tx: CGFloat(t.tx), ty: CGFloat(t.ty)))
            case let .clip(path):
                ctx.beginPath()
                if path.isEmpty {
                    ctx.clip(to: CGRect.zero)
                } else {
                    ctx.addPath(Self.cgPath(path))
                    ctx.clip(using: .winding)
                }
            }
        }
        while depth > 0 {
            ctx.restoreGState()
            depth -= 1
        }
        ctx.restoreGState()
        _stats = stats
    }

    // MARK: text

    private struct TextLayoutKey: Hashable {
        let text: String
        let width: Double
        let style: DashTextStyle
    }

    private struct TextLayout {
        let lines: [(line: CTLine, width: Double)]
        let ascent: Double
        let descent: Double
    }

    /// Lays out a text block per the contract (wrap at words, maxLines, last line "…",
    /// block vertically centred, lineHeight = ascent + descent). Must be called with `lock` held.
    private func layout(_ text: String, width: Double, style: DashTextStyle) -> TextLayout {
        let key = TextLayoutKey(text: text, width: width, style: style)
        if let hit = textLayouts[key] { return hit }
        let font = fonts.font(for: style.font)
        let color = cgColor(style.color)
        let kern = style.letterSpacingEm * style.font.size
        func makeLine(_ s: String) -> CTLine { DashTextLineBuilder.line(s, font: font, color: color, kern: kern) }
        let maxWidth = max(0, width)
        // Break with the layout engine's width model (measurer width + spacing × characters).
        let texts = DashTextWrapper.wrap(text, maxWidth: maxWidth, maxLines: style.maxLines) { s in
            guard !s.isEmpty else { return 0 }
            let plain = DashTextLineBuilder.width(DashTextLineBuilder.line(s, font: font, color: nil, kern: 0))
            return plain + kern * Double(s.count)
        }
        var lines: [(line: CTLine, width: Double)] = []
        for s in texts {
            guard !s.isEmpty else { lines.append((makeLine(" "), 0)); continue } // empty hard line keeps its slot
            var line = makeLine(s)
            var w = DashTextLineBuilder.width(line)
            if w > maxWidth + DashTextWrapper.epsilon { // safety net; the wrapper already fitted the line
                let token = makeLine(DashTextWrapper.ellipsis)
                guard let truncated = CTLineCreateTruncatedLine(line, maxWidth, .end, token) else { continue }
                line = truncated
                w = DashTextLineBuilder.width(truncated)
            }
            lines.append((line, w))
        }
        let result = TextLayout(lines: lines, ascent: Double(CTFontGetAscent(font)), descent: Double(CTFontGetDescent(font)))
        if textLayouts.count >= 512 { textLayouts.removeAll(keepingCapacity: true) }
        textLayouts[key] = result
        return result
    }

    private func drawText(_ text: String, rect: DashRect, style: DashTextStyle, in ctx: CGContext) {
        let laid = layout(text, width: rect.width, style: style)
        guard !laid.lines.isEmpty else { return }
        let baselines = DashTextBlockGeometry.baselines(lineCount: laid.lines.count, rect: rect,
                                                        ascent: laid.ascent, descent: laid.descent)
        for (i, entry) in laid.lines.enumerated() {
            let x = DashTextBlockGeometry.lineX(lineWidth: entry.width, rect: rect, alignment: style.alignment)
            ctx.saveGState()
            // The CTM is y-down; CoreText draws y-up glyphs: re-flip around the baseline.
            ctx.translateBy(x: CGFloat(x), y: CGFloat(baselines[i]))
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(entry.line, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: tiles

    private func drawTile(z: Int, x: Int, y: Int, rect: DashRect, treatment: DashTileTreatment, cache: TileImageCache?,
                          in ctx: CGContext, stats: inout DashRendererStats) {
        let r = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        guard !r.isEmpty, r.minX.isFinite, r.minY.isFinite else { return }
        ctx.saveGState()
        // Adjacent tiles must meet without anti-aliased seams (also when the map is rotated).
        ctx.setShouldAntialias(false)
        defer { ctx.restoreGState() }
        if let cache {
            if let image = cache.image(z: z, x: x, y: y, treatment: treatment) {
                Self.drawImage(image, in: r, ctx: ctx)
                stats.tilesDrawn += 1
                return
            }
            cache.request(z: z, x: x, y: y)
            stats.tilesMissing += 1
            if usesParentTileFallback, let parent = cache.fallbackImage(z: z, x: x, y: y, treatment: treatment) {
                Self.drawImage(parent, in: r, ctx: ctx)
                stats.tilesFromParent += 1
                return
            }
        } else {
            stats.tilesMissing += 1
        }
        let placeholder: DashColor
        switch treatment {
        case .normal: placeholder = tilePlaceholderDay
        case .inverted: placeholder = tilePlaceholderNight
        case .mutedDay: placeholder = tilePlaceholderMutedDay
        case .mutedNight: placeholder = tilePlaceholderMutedNight
        }
        ctx.setFillColor(cgColor(placeholder))
        ctx.fill(r)
    }

    // MARK: images (album artwork)

    /// `DashDrawCommand.image`: the store's variant for the rect's DEVICE pixel size (the current
    /// transform's scale included, so a 2× phone preview gets a 2× variant), aspect filled and
    /// centre-cropped by the store, clipped to a rounded rect. An unknown id draws nothing (the
    /// scene's placeholder underneath shows). Never inverted at night (the scene dims it).
    private func drawImage(id: String, rect: DashRect, cornerRadius: Double, store: DashImageStore?,
                           in ctx: CGContext, stats: inout DashRendererStats) {
        let r = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
              r.width > 0, r.height > 0 else { return }
        let size = Self.devicePixelSize(of: r, transform: ctx.userSpaceToDeviceSpaceTransform)
        guard let store, let image = store.image(id: id, pixelWidth: size.width, pixelHeight: size.height) else {
            stats.imagesMissing += 1
            return
        }
        ctx.saveGState()
        let maxRadius = Double(min(r.width, r.height)) / 2
        let radius = CGFloat(cornerRadius.isFinite ? min(max(0, cornerRadius), maxRadius) : 0)
        ctx.beginPath()
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        } else {
            ctx.addRect(r)
        }
        ctx.clip()
        ctx.interpolationQuality = .high
        Self.drawImage(image, in: r, ctx: ctx) // the variant has the rect's aspect: it fills `r` exactly
        ctx.restoreGState()
        stats.imagesDrawn += 1
    }

    /// Pixel size of user-space rect `r` on the device: its sides scaled by the transform's axis
    /// scales (rotation-safe), at least 1 × 1.
    static func devicePixelSize(of r: CGRect, transform t: CGAffineTransform) -> (width: Int, height: Int) {
        let sx = Double((t.a * t.a + t.b * t.b).squareRoot())
        let sy = Double((t.c * t.c + t.d * t.d).squareRoot())
        func px(_ v: Double) -> Int {
            guard v.isFinite else { return 1 }
            return max(1, min(DashImageStore.maxVariantPixels, Int(v.rounded())))
        }
        return (px(Double(r.width) * sx), px(Double(r.height) * sy))
    }

    /// Draws an image upright into `r` of the y-down user space.
    static func drawImage(_ image: CGImage, in r: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    // MARK: conversions

    /// Must be called with `lock` held.
    private func cgColor(_ c: DashColor) -> CGColor {
        if let hit = colors[c.argb] { return hit }
        let components: [CGFloat] = [CGFloat(c.red), CGFloat(c.green), CGFloat(c.blue), CGFloat(c.alpha)]
        let made = CGColor(colorSpace: Self.colorSpace, components: components)
            ?? CGColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
        if colors.count > 512 { colors.removeAll(keepingCapacity: true) }
        colors[c.argb] = made
        return made
    }

    static func cgPath(_ path: DashPath) -> CGPath {
        let p = CGMutablePath()
        var hasCurrentPoint = false
        func pt(_ d: DashPoint) -> CGPoint? {
            guard d.x.isFinite, d.y.isFinite else { return nil }
            return CGPoint(x: d.x, y: d.y)
        }
        for element in path.elements {
            switch element {
            case let .move(a):
                guard let a = pt(a) else { continue }
                p.move(to: a)
                hasCurrentPoint = true
            case let .line(a):
                guard let a = pt(a) else { continue }
                if hasCurrentPoint { p.addLine(to: a) } else { p.move(to: a); hasCurrentPoint = true }
            case let .quad(c, a):
                guard let c = pt(c), let a = pt(a) else { continue }
                if hasCurrentPoint { p.addQuadCurve(to: a, control: c) } else { p.move(to: a); hasCurrentPoint = true }
            case let .cubic(c1, c2, a):
                guard let c1 = pt(c1), let c2 = pt(c2), let a = pt(a) else { continue }
                if hasCurrentPoint { p.addCurve(to: a, control1: c1, control2: c2) } else { p.move(to: a); hasCurrentPoint = true }
            case .close:
                if hasCurrentPoint { p.closeSubpath() }
            }
        }
        return p
    }

    static func cgCap(_ c: DashLineCap) -> CGLineCap {
        switch c {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }

    static func cgJoin(_ j: DashLineJoin) -> CGLineJoin {
        switch j {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}
#endif
