// SPDX-License-Identifier: AGPL-3.0-or-later
// Text wrapping / ellipsis exactly as `DashDrawCommand.text` is specified (Dash/DisplayList.swift):
// greedy word wrap inside the rect width, at most `maxLines`, the last visible line truncated with
// "…", block vertically centred, each line aligned per `DashTextStyle.alignment`.
// Shared by the layout engine (sizes), the SVG exporter and — recommended — the CoreGraphics
// renderer, so every consumer breaks lines identically for a given `DashTextMeasurer`.

import Foundation

/// One laid-out text line: `origin` = left x of the line, baseline y.
public struct DashTextLine: Hashable, Sendable {
    public var text: String
    public var width: Double
    public var origin: DashPoint
    public init(text: String, width: Double, origin: DashPoint) { self.text = text; self.width = width; self.origin = origin }
}

public enum DashTextLayout {
    /// The ellipsis appended to truncated lines.
    public static let ellipsis = "…"
    private static let epsilon = 0.01

    /// Width of one line including letter spacing (`letterSpacingEm × size` per character).
    public static func width(_ text: String, font: DashFont, letterSpacingEm: Double = 0,
                             measurer: any DashTextMeasurer) -> Double {
        guard !text.isEmpty else { return 0 }
        let w = measurer.measure(text, font: font).width
        return w + letterSpacingEm * font.size * Double(text.count)
    }

    /// Ascent / descent / line height for a font (measured on a reference string).
    public static func metrics(font: DashFont, measurer: any DashTextMeasurer) -> DashTextMetrics {
        let m = measurer.measure("Ag", font: font)
        return DashTextMetrics(width: 0, ascent: m.ascent, descent: m.descent)
    }

    /// Line height (ascent + descent) for a font.
    public static func lineHeight(font: DashFont, measurer: any DashTextMeasurer) -> Double {
        metrics(font: font, measurer: measurer).lineHeight
    }

    /// Single-line truncation: `text` if it fits, else the longest prefix + "…" that fits
    /// (trailing spaces trimmed before the ellipsis); "…" alone if nothing else fits.
    public static func truncate(_ text: String, maxWidth: Double, font: DashFont, letterSpacingEm: Double = 0,
                                measurer: any DashTextMeasurer) -> String {
        if width(text, font: font, letterSpacingEm: letterSpacingEm, measurer: measurer) <= maxWidth + epsilon { return text }
        return ellipsized(text, maxWidth: maxWidth, font: font, letterSpacingEm: letterSpacingEm, measurer: measurer)
    }

    /// Always ends with "…": the longest prefix (possibly the whole text) + "…" that fits.
    static func ellipsized(_ text: String, maxWidth: Double, font: DashFont, letterSpacingEm: Double,
                           measurer: any DashTextMeasurer) -> String {
        let chars = Array(text)
        var lo = 0, hi = chars.count // number of characters kept
        func candidate(_ n: Int) -> String {
            var s = String(chars[0 ..< n])
            while s.last == " " { s.removeLast() }
            return s + ellipsis
        }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if width(candidate(mid), font: font, letterSpacingEm: letterSpacingEm, measurer: measurer) <= maxWidth + epsilon {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return candidate(lo)
    }

    /// Greedy word wrap within `maxWidth`, at most `maxLines` lines; the remainder is folded into
    /// the last line and truncated with "…". Explicit "\n" are hard breaks. Words wider than the
    /// line are broken between characters.
    public static func wrap(_ text: String, maxWidth: Double, font: DashFont, letterSpacingEm: Double = 0,
                            maxLines: Int, measurer: any DashTextMeasurer) -> [String] {
        let maxLines = max(1, maxLines)
        let w: (String) -> Double = { width($0, font: font, letterSpacingEm: letterSpacingEm, measurer: measurer) }
        if maxLines == 1, !text.contains("\n") {
            return [truncate(text, maxWidth: maxWidth, font: font, letterSpacingEm: letterSpacingEm, measurer: measurer)]
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
        // The remainder is folded into the last line, which always signals the cut with "…".
        kept.append(ellipsized(rest, maxWidth: maxWidth, font: font, letterSpacingEm: letterSpacingEm, measurer: measurer))
        return kept
    }

    /// Number of lines `text` occupies (≤ maxLines) at `maxWidth`.
    public static func lineCount(_ text: String, maxWidth: Double, font: DashFont, letterSpacingEm: Double = 0,
                                 maxLines: Int, measurer: any DashTextMeasurer) -> Int {
        wrap(text, maxWidth: maxWidth, font: font, letterSpacingEm: letterSpacingEm, maxLines: maxLines, measurer: measurer).count
    }

    /// Positioned lines for `DashDrawCommand.text(text, rect, style)`:
    /// baseline of line i = rect.minY + (rect.height − blockHeight)/2 + i·lineHeight + ascent.
    public static func layout(_ text: String, in rect: DashRect, style: DashTextStyle,
                              measurer: any DashTextMeasurer) -> [DashTextLine] {
        let lines = wrap(text, maxWidth: rect.width, font: style.font, letterSpacingEm: style.letterSpacingEm,
                         maxLines: style.maxLines, measurer: measurer)
        let m = metrics(font: style.font, measurer: measurer)
        let blockHeight = Double(lines.count) * m.lineHeight
        let top = rect.minY + (rect.height - blockHeight) / 2
        return lines.enumerated().map { i, line in
            let lw = width(line, font: style.font, letterSpacingEm: style.letterSpacingEm, measurer: measurer)
            let x: Double
            switch style.alignment {
            case .left: x = rect.minX
            case .center: x = rect.midX - lw / 2
            case .right: x = rect.maxX - lw
            }
            return DashTextLine(text: line, width: lw, origin: DashPoint(x, top + Double(i) * m.lineHeight + m.ascent))
        }
    }
}
