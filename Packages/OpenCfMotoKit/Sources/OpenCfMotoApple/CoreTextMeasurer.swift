// SPDX-License-Identifier: AGPL-3.0-or-later
// CoreText text measurement for the dash UI layout (DashTextMeasurer contract) and the CTFont /
// CTLine construction shared with DashRenderer, so layout and rendering agree exactly.
// Fonts: the system UI font (SF Pro) at the DashFont pixel size; "bold" = the emphasized system
// font; medium / semibold via the weight trait; tabular digits via the number-spacing feature.
// Metrics: ascent + descent only (no leading) — Android `includeFontPadding = false`
// (docs/spec/navigation-dash.md §15 note 3).

#if canImport(CoreText) && canImport(CoreGraphics)
import CoreGraphics
import CoreText
import Foundation
import OpenCfMotoCore

/// Builds and caches the CTFont for each `DashFont`. Thread-safe; CTFont objects are immutable
/// and may be used from any thread.
public final class DashFontProvider: @unchecked Sendable {
    /// Shared provider used by `CoreTextMeasurer()` and `DashRenderer()` by default.
    public static let shared = DashFontProvider()

    private let lock = NSLock()
    private var fonts: [DashFont: CTFont] = [:]

    public init() {}

    /// The CTFont for `font` (created once, then cached).
    public func font(for font: DashFont) -> CTFont {
        lock.lock()
        if let f = fonts[font] { lock.unlock(); return f }
        lock.unlock()
        let made = Self.makeFont(font)
        lock.lock()
        if fonts.count > 256 { fonts.removeAll() }
        fonts[font] = made
        lock.unlock()
        return made
    }

    /// Ascent and descent (canvas px) of `font`.
    public func metrics(for font: DashFont) -> (ascent: Double, descent: Double) {
        let f = self.font(for: font)
        return (Double(CTFontGetAscent(f)), Double(CTFontGetDescent(f)))
    }

    /// UIFont.Weight-compatible values used for the weight trait.
    static func weightTrait(_ w: DashFontWeight) -> CGFloat {
        switch w {
        case .regular: return 0
        case .medium: return 0.23
        case .semibold: return 0.3
        case .bold: return 0.4
        }
    }

    static func makeFont(_ font: DashFont) -> CTFont {
        let size = CGFloat(max(1, font.size.isFinite ? font.size : 1))
        let uiType: CTFontUIFontType = font.weight == .bold ? .emphasizedSystem : .system
        let base = CTFontCreateUIFontForLanguage(uiType, size, nil)
            ?? CTFontCreateWithName((font.weight == .bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        var descriptor = CTFontCopyFontDescriptor(base)
        if font.weight == .medium || font.weight == .semibold {
            let traits: [CFString: Any] = [kCTFontWeightTrait: weightTrait(font.weight)]
            let attributes: [CFString: Any] = [kCTFontTraitsAttribute: traits]
            descriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes as CFDictionary)
        }
        if font.monospacedDigits {
            let feature: [CFString: Any] = [
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ]
            let attributes: [CFString: Any] = [kCTFontFeatureSettingsAttribute: [feature]]
            descriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes as CFDictionary)
        }
        if font.weight == .regular || font.weight == .bold, !font.monospacedDigits {
            return base
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}

/// Builds CTLines with the dash text attributes (font, colour, letter spacing).
enum DashTextLineBuilder {
    static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    static let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)

    /// One line of text. `kern` (px) is applied between characters only (not after the last one),
    /// like Android letterSpacing, so alignment stays exact.
    static func line(_ text: String, font: CTFont, color: CGColor?, kern: Double) -> CTLine {
        let attributed = NSMutableAttributedString(string: text)
        let length = attributed.length
        if length > 0 {
            let full = NSRange(location: 0, length: length)
            attributed.addAttribute(fontKey, value: font, range: full)
            if let color { attributed.addAttribute(colorKey, value: color, range: full) }
            if kern != 0, kern.isFinite, length > 1 {
                let last = (text as NSString).rangeOfComposedCharacterSequence(at: length - 1)
                if last.location > 0 {
                    attributed.addAttribute(kernKey, value: NSNumber(value: kern), range: NSRange(location: 0, length: last.location))
                }
            }
        }
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }

    /// Typographic width of a line (px).
    static func width(_ line: CTLine) -> Double {
        CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}

/// `DashTextMeasurer` backed by CoreText with exactly the fonts `DashRenderer` draws with.
/// Single-line width without letter spacing; ascent/descent of the font (no leading).
public struct CoreTextMeasurer: DashTextMeasurer {
    private let fonts: DashFontProvider
    private let cache: MeasureCache

    public init(fonts: DashFontProvider = .shared) {
        self.fonts = fonts
        cache = MeasureCache()
    }

    public func measure(_ text: String, font: DashFont) -> DashTextMetrics {
        let key = MeasureCache.Key(text: text, font: font)
        if let hit = cache.get(key) { return hit }
        let ctFont = fonts.font(for: font)
        let width = text.isEmpty ? 0 : DashTextLineBuilder.width(DashTextLineBuilder.line(text, font: ctFont, color: nil, kern: 0))
        let m = DashTextMetrics(width: width, ascent: Double(CTFontGetAscent(ctFont)), descent: Double(CTFontGetDescent(ctFont)))
        cache.put(key, m)
        return m
    }

    final class MeasureCache: @unchecked Sendable {
        struct Key: Hashable { let text: String; let font: DashFont }
        private let lock = NSLock()
        private var values: [Key: DashTextMetrics] = [:]
        func get(_ k: Key) -> DashTextMetrics? { lock.lock(); defer { lock.unlock() }; return values[k] }
        func put(_ k: Key, _ v: DashTextMetrics) {
            lock.lock()
            if values.count >= 4096 { values.removeAll(keepingCapacity: true) }
            values[k] = v
            lock.unlock()
        }
    }
}
#endif
