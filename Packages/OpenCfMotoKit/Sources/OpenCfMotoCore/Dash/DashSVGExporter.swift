// SPDX-License-Identifier: AGPL-3.0-or-later
// Exports a `DashDisplayList` as SVG for visual review (docs/screenshots/dash) and debugging.
// Text is laid out with `DashTextLayout` (same wrapping / ellipsis as the renderer); raster tiles
// become checkerboard placeholders labelled z/x/y (dark when inverted for night mode).

import Foundation

/// A font family used for characters in `range` (SVG rasterisers such as cairosvg do not fall
/// back per glyph, so symbols missing from the main font would render as boxes).
public struct DashSVGFontFallback: Sendable, Equatable {
    public var range: ClosedRange<UInt32>
    public var fontFamily: String
    public init(range: ClosedRange<UInt32>, fontFamily: String) { self.range = range; self.fontFamily = fontFamily }
}

public struct DashSVGExporter: Sendable {
    /// ⌨ (Miscellaneous Technical) and fullwidth ＋／－ (Halfwidth and Fullwidth Forms).
    public static let defaultSymbolFallbacks = [
        DashSVGFontFallback(range: 0x2300 ... 0x23FF, fontFamily: "DejaVu Sans"),
        DashSVGFontFallback(range: 0xFF00 ... 0xFFEF, fontFamily: "WenQuanYi Zen Hei"),
    ]

    public var measurer: any DashTextMeasurer
    /// CSS font stack for text.
    public var fontFamily: String
    /// Stretch / squeeze every text line to its measured width (`textLength`), so the exported
    /// picture shows exactly the layout computed with `measurer` whatever font the viewer has.
    public var fitTextToMeasuredWidth: Bool
    /// Overlay the hit regions (debug).
    public var showHitRegions: Bool
    /// Per-character font fallbacks emitted as `<tspan font-family>` runs.
    public var symbolFallbacks: [DashSVGFontFallback] = DashSVGExporter.defaultSymbolFallbacks

    public init(measurer: any DashTextMeasurer = ApproximateTextMeasurer(),
                fontFamily: String = "Inter, Roboto, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif",
                fitTextToMeasuredWidth: Bool = true, showHitRegions: Bool = false) {
        self.measurer = measurer
        self.fontFamily = fontFamily
        self.fitTextToMeasuredWidth = fitTextToMeasuredWidth
        self.showHitRegions = showHitRegions
    }

    private static func n(_ v: Double) -> String { DashSVGNumber.format(v, decimals: 2) }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func paint(_ attr: String, _ c: DashColor) -> String {
        var s = "\(attr)=\"\(c.rgbHex)\""
        if c.alpha < 1 { s += " \(attr)-opacity=\"\(DashSVGNumber.format(c.alpha, decimals: 3))\"" }
        return s
    }

    private static func weight(_ w: DashFontWeight) -> Int {
        switch w {
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        }
    }

    /// The SVG document for one frame.
    public func svg(_ list: DashDisplayList) -> String {
        let w = list.size.width, h = list.size.height
        var out: [String] = []
        out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Self.n(w))\" height=\"\(Self.n(h))\" viewBox=\"0 0 \(Self.n(w)) \(Self.n(h))\">")
        out.append("<rect x=\"0\" y=\"0\" width=\"\(Self.n(w))\" height=\"\(Self.n(h))\" \(Self.paint("fill", list.background))/>")
        // Each `save` pushes a counter of groups opened by transform/clip until its `restore`.
        var stack: [Int] = [0]
        var clipId = 0
        for cmd in list.commands {
            switch cmd {
            case let .fill(path, color, rule):
                guard !path.isEmpty else { continue }
                let r = rule == .evenOdd ? " fill-rule=\"evenodd\"" : ""
                out.append("<path d=\"\(path.svgPathData)\" \(Self.paint("fill", color))\(r)/>")
            case let .stroke(path, st):
                guard !path.isEmpty else { continue }
                var a = "<path d=\"\(path.svgPathData)\" fill=\"none\" \(Self.paint("stroke", st.color)) stroke-width=\"\(Self.n(st.width))\""
                a += " stroke-linecap=\"\(st.cap.rawValue)\" stroke-linejoin=\"\(st.join.rawValue)\""
                if !st.dash.isEmpty { a += " stroke-dasharray=\"\(st.dash.map { Self.n($0) }.joined(separator: " "))\"" }
                out.append(a + "/>")
            case let .text(s, rect, style):
                out.append(contentsOf: text(s, rect, style))
            case let .tile(z, x, y, rect, invert):
                out.append(tile(z: z, x: x, y: y, rect: rect, invert: invert))
            case let .image(_, rect, _):
                // core-dash: rounded, clipped, deterministic placeholder (or `images[id]`).
                out.append("<rect x=\"\(Self.n(rect.x))\" y=\"\(Self.n(rect.y))\" width=\"\(Self.n(rect.width))\" height=\"\(Self.n(rect.height))\" fill=\"#3A4658\"/>")
            case .save:
                stack.append(0)
            case .restore:
                let opened = stack.popLast() ?? 0
                for _ in 0 ..< opened { out.append("</g>") }
                if stack.isEmpty { stack = [0] }
            case let .transform(t):
                out.append("<g transform=\"matrix(\(Self.n6(t.a)) \(Self.n6(t.b)) \(Self.n6(t.c)) \(Self.n6(t.d)) \(Self.n(t.tx)) \(Self.n(t.ty)))\">")
                stack[stack.count - 1] += 1
            case let .clip(path):
                clipId += 1
                out.append("<defs><clipPath id=\"c\(clipId)\" clipPathUnits=\"userSpaceOnUse\"><path d=\"\(path.svgPathData)\"/></clipPath></defs>")
                out.append("<g clip-path=\"url(#c\(clipId))\">")
                stack[stack.count - 1] += 1
            }
        }
        for level in stack.reversed() { for _ in 0 ..< level { out.append("</g>") } }
        if showHitRegions {
            for r in list.hitRegions {
                let color = r.focusable ? "#00C853" : "#FF1744"
                out.append("<rect x=\"\(Self.n(r.rect.x))\" y=\"\(Self.n(r.rect.y))\" width=\"\(Self.n(r.rect.width))\" height=\"\(Self.n(r.rect.height))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"1\" stroke-dasharray=\"3 2\"/>")
            }
        }
        out.append("</svg>")
        return out.joined(separator: "\n")
    }

    private static func n6(_ v: Double) -> String { DashSVGNumber.format(v, decimals: 6) }

    private func text(_ s: String, _ rect: DashRect, _ style: DashTextStyle) -> [String] {
        let lines = DashTextLayout.layout(s, in: rect, style: style, measurer: measurer)
        let f = style.font
        var common = "font-family=\"\(fontFamily)\" font-size=\"\(Self.n(f.size))\" font-weight=\"\(Self.weight(f.weight))\" \(Self.paint("fill", style.color))"
        if style.letterSpacingEm != 0 && !fitTextToMeasuredWidth {
            common += " letter-spacing=\"\(Self.n(style.letterSpacingEm * f.size))\""
        }
        return lines.compactMap { line in
            guard !line.text.isEmpty else { return nil }
            var a = "<text x=\"\(Self.n(line.origin.x))\" y=\"\(Self.n(line.origin.y))\" \(common) xml:space=\"preserve\""
            if fitTextToMeasuredWidth, line.width > 0 {
                a += " textLength=\"\(Self.n(line.width))\" lengthAdjust=\"spacingAndGlyphs\""
            }
            return a + ">\(runs(line.text))</text>"
        }
    }

    /// Escaped text with symbol characters wrapped in fallback-font tspans.
    func runs(_ text: String) -> String {
        guard !symbolFallbacks.isEmpty else { return Self.escape(text) }
        var out = ""
        var current: String?
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            if let fam = current {
                out += "<tspan font-family=\"\(fam)\">\(Self.escape(buffer))</tspan>"
            } else {
                out += Self.escape(buffer)
            }
            buffer = ""
        }
        for ch in text {
            let v = ch.unicodeScalars.first?.value ?? 0
            let fam = symbolFallbacks.first(where: { $0.range.contains(v) })?.fontFamily
            if fam != current { flush(); current = fam }
            buffer.append(ch)
        }
        flush()
        return out
    }

    private func tile(z: Int, x: Int, y: Int, rect r: DashRect, invert: Bool) -> String {
        let base = invert ? "#1B1E24" : "#F2EFE9"
        let alt = invert ? "#23272E" : "#E8E3DA"
        let line = invert ? "#30353D" : "#D6D0C4"
        let label = invert ? "#5A626E" : "#A39C90"
        var parts: [String] = []
        parts.append("<g>")
        parts.append("<rect x=\"\(Self.n(r.x))\" y=\"\(Self.n(r.y))\" width=\"\(Self.n(r.width))\" height=\"\(Self.n(r.height))\" fill=\"\(base)\"/>")
        let q = r.width / 4
        for i in 0 ..< 4 {
            for j in 0 ..< 4 where (i + j) % 2 == 1 {
                parts.append("<rect x=\"\(Self.n(r.x + Double(i) * q))\" y=\"\(Self.n(r.y + Double(j) * q))\" width=\"\(Self.n(q))\" height=\"\(Self.n(q))\" fill=\"\(alt)\"/>")
            }
        }
        parts.append("<rect x=\"\(Self.n(r.x))\" y=\"\(Self.n(r.y))\" width=\"\(Self.n(r.width))\" height=\"\(Self.n(r.height))\" fill=\"none\" stroke=\"\(line)\" stroke-width=\"1\"/>")
        let fs = max(8, r.width / 14)
        parts.append("<text x=\"\(Self.n(r.midX))\" y=\"\(Self.n(r.midY + fs * 0.35))\" font-family=\"\(fontFamily)\" font-size=\"\(Self.n(fs))\" fill=\"\(label)\" text-anchor=\"middle\">\(z)/\(x)/\(y)</text>")
        parts.append("</g>")
        return parts.joined()
    }
}
