// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — platform-neutral drawing description of one dash frame.
//
// The dash UI (map + HUD chrome) is BUILT in OpenCfMotoCore as a `DashDisplayList` (testable on
// Linux, exportable to SVG for visual review) and EXECUTED by `DashRenderer` (OpenCfMotoApple,
// CoreGraphics) into the CVPixelBuffer that is H.264-encoded for the dash.
//
// Coordinate system: dash canvas pixels, origin TOP-LEFT, y grows DOWN (same as dash touches).
// Angles in radians, positive = clockwise on screen (y-down), like CGAffineTransform(rotationAngle:)
// in a flipped (UIKit) context.

import Foundation

public struct DashColor: Hashable, Sendable, Codable, CustomStringConvertible {
    /// 0xAARRGGBB
    public var argb: UInt32
    public init(argb: UInt32) { self.argb = argb }
    /// rgb = 0xRRGGBB, alpha 0…1.
    public init(rgb: UInt32, alpha: Double = 1) {
        let a = UInt32((max(0, min(1, alpha)) * 255).rounded())
        self.argb = (a << 24) | (rgb & 0x00FF_FFFF)
    }
    public var alpha: Double { Double((argb >> 24) & 0xFF) / 255 }
    public var red: Double { Double((argb >> 16) & 0xFF) / 255 }
    public var green: Double { Double((argb >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(argb & 0xFF) / 255 }
    public func withAlpha(_ a: Double) -> DashColor { DashColor(rgb: argb & 0x00FF_FFFF, alpha: a) }
    /// "#RRGGBB" (alpha dropped) — for SVG export.
    public var rgbHex: String { String(format: "#%06X", argb & 0x00FF_FFFF) }
    public var description: String { String(format: "#%08X", argb) }

    public static let white = DashColor(argb: 0xFFFF_FFFF)
    public static let black = DashColor(argb: 0xFF00_0000)
    public static let clear = DashColor(argb: 0x0000_0000)
}

public struct DashPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = DashPoint(0, 0)
}

public struct DashSize: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct DashRect: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static let zero = DashRect(x: 0, y: 0, width: 0, height: 0)
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: DashPoint { DashPoint(midX, midY) }
    public var size: DashSize { DashSize(width: width, height: height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public func contains(_ p: DashPoint) -> Bool { p.x >= x && p.x < maxX && p.y >= y && p.y < maxY }
    public func insetBy(dx: Double, dy: Double) -> DashRect {
        DashRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
    public func offsetBy(dx: Double, dy: Double) -> DashRect { DashRect(x: x + dx, y: y + dy, width: width, height: height) }
    public func intersects(_ o: DashRect) -> Bool { x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY }
    public func union(_ o: DashRect) -> DashRect {
        let nx = min(x, o.x), ny = min(y, o.y)
        return DashRect(x: nx, y: ny, width: max(maxX, o.maxX) - nx, height: max(maxY, o.maxY) - ny)
    }
    public var description: String { String(format: "(%.1f,%.1f %.1fx%.1f)", x, y, width, height) }
}

/// Affine transform with CGAffineTransform semantics: p' = (a·x + c·y + tx, b·x + d·y + ty).
public struct DashTransform: Hashable, Sendable, Codable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public static let identity = DashTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public static func translation(_ dx: Double, _ dy: Double) -> DashTransform {
        DashTransform(a: 1, b: 0, c: 0, d: 1, tx: dx, ty: dy)
    }
    public static func scale(_ sx: Double, _ sy: Double) -> DashTransform {
        DashTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }
    /// Clockwise on screen (y-down) for positive angles.
    public static func rotation(_ radians: Double) -> DashTransform {
        let cs = cos(radians), sn = sin(radians)
        return DashTransform(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0)
    }
    /// `self` then `t` (CGAffineTransform.concatenating semantics).
    public func concatenating(_ t: DashTransform) -> DashTransform {
        DashTransform(a: a * t.a + b * t.c, b: a * t.b + b * t.d,
                      c: c * t.a + d * t.c, d: c * t.b + d * t.d,
                      tx: tx * t.a + ty * t.c + t.tx, ty: tx * t.b + ty * t.d + t.ty)
    }
    public func apply(_ p: DashPoint) -> DashPoint {
        DashPoint(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }
    public var inverted: DashTransform? {
        let det = a * d - b * c
        guard abs(det) > 1e-12 else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return DashTransform(a: ia, b: ib, c: ic, d: id, tx: -(tx * ia + ty * ic), ty: -(tx * ib + ty * id))
    }
}

public enum DashPathElement: Hashable, Sendable, Codable {
    case move(DashPoint)
    case line(DashPoint)
    case quad(DashPoint, DashPoint)            // control, end
    case cubic(DashPoint, DashPoint, DashPoint) // control1, control2, end
    case close
}

/// A vector path. Arcs/circles are stored as cubic Béziers so renderers only need
/// move/line/quad/cubic/close. Build icons from SVG path data with `DashPath(svg:)`
/// (implemented in Dash/DashPathSVG.swift).
public struct DashPath: Hashable, Sendable, Codable {
    public var elements: [DashPathElement]
    public init(_ elements: [DashPathElement] = []) { self.elements = elements }

    public mutating func move(to p: DashPoint) { elements.append(.move(p)) }
    public mutating func line(to p: DashPoint) { elements.append(.line(p)) }
    public mutating func quad(to p: DashPoint, control: DashPoint) { elements.append(.quad(control, p)) }
    public mutating func cubic(to p: DashPoint, control1: DashPoint, control2: DashPoint) { elements.append(.cubic(control1, control2, p)) }
    public mutating func close() { elements.append(.close) }
    public mutating func append(_ other: DashPath) { elements.append(contentsOf: other.elements) }

    public var isEmpty: Bool { elements.isEmpty }

    public func applying(_ t: DashTransform) -> DashPath {
        DashPath(elements.map { e in
            switch e {
            case let .move(p): return .move(t.apply(p))
            case let .line(p): return .line(t.apply(p))
            case let .quad(c, p): return .quad(t.apply(c), t.apply(p))
            case let .cubic(c1, c2, p): return .cubic(t.apply(c1), t.apply(c2), t.apply(p))
            case .close: return .close
            }
        })
    }

    public static func rect(_ r: DashRect) -> DashPath {
        DashPath([.move(DashPoint(r.minX, r.minY)), .line(DashPoint(r.maxX, r.minY)), .line(DashPoint(r.maxX, r.maxY)),
                  .line(DashPoint(r.minX, r.maxY)), .close])
    }

    /// Rounded rectangle; per-corner radii (clamped to half the shorter side).
    public static func roundedRect(_ r: DashRect, topLeft: Double, topRight: Double, bottomRight: Double, bottomLeft: Double) -> DashPath {
        let m = min(r.width, r.height) / 2
        let tl = max(0, min(topLeft, m)), tr = max(0, min(topRight, m))
        let br = max(0, min(bottomRight, m)), bl = max(0, min(bottomLeft, m))
        let k = 0.5522847498 // cubic circle constant
        var p = DashPath()
        p.move(to: DashPoint(r.minX + tl, r.minY))
        p.line(to: DashPoint(r.maxX - tr, r.minY))
        if tr > 0 { p.cubic(to: DashPoint(r.maxX, r.minY + tr), control1: DashPoint(r.maxX - tr + tr * k, r.minY), control2: DashPoint(r.maxX, r.minY + tr - tr * k)) }
        p.line(to: DashPoint(r.maxX, r.maxY - br))
        if br > 0 { p.cubic(to: DashPoint(r.maxX - br, r.maxY), control1: DashPoint(r.maxX, r.maxY - br + br * k), control2: DashPoint(r.maxX - br + br * k, r.maxY)) }
        p.line(to: DashPoint(r.minX + bl, r.maxY))
        if bl > 0 { p.cubic(to: DashPoint(r.minX, r.maxY - bl), control1: DashPoint(r.minX + bl - bl * k, r.maxY), control2: DashPoint(r.minX, r.maxY - bl + bl * k)) }
        p.line(to: DashPoint(r.minX, r.minY + tl))
        if tl > 0 { p.cubic(to: DashPoint(r.minX + tl, r.minY), control1: DashPoint(r.minX, r.minY + tl - tl * k), control2: DashPoint(r.minX + tl - tl * k, r.minY)) }
        p.close()
        return p
    }

    public static func roundedRect(_ r: DashRect, radius: Double) -> DashPath {
        roundedRect(r, topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
    }

    public static func ellipse(in r: DashRect) -> DashPath {
        roundedRect(r, radius: min(r.width, r.height) / 2) // exact for circles; good enough for ovals
    }

    public static func circle(center c: DashPoint, radius: Double) -> DashPath {
        ellipse(in: DashRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
    }

    public static func polyline(_ pts: [DashPoint], closed: Bool = false) -> DashPath {
        guard let first = pts.first else { return DashPath() }
        var p = DashPath([.move(first)])
        for q in pts.dropFirst() { p.line(to: q) }
        if closed { p.close() }
        return p
    }
}

public enum DashFontWeight: String, Hashable, Sendable, Codable { case regular, medium, semibold, bold }

public struct DashFont: Hashable, Sendable, Codable {
    /// Font size in canvas pixels (Android sp × density; 1 sp = 1 px on 800-wide dashes).
    public var size: Double
    public var weight: DashFontWeight
    /// Tabular digits (speed, clock) so numbers do not jitter.
    public var monospacedDigits: Bool
    public init(size: Double, weight: DashFontWeight = .regular, monospacedDigits: Bool = false) {
        self.size = size; self.weight = weight; self.monospacedDigits = monospacedDigits
    }
}

public enum DashTextAlignment: String, Hashable, Sendable, Codable { case left, center, right }

public struct DashTextStyle: Hashable, Sendable, Codable {
    public var font: DashFont
    public var color: DashColor
    public var alignment: DashTextAlignment
    /// Lines before truncating the last one with "…" (1 = single line, ellipsised).
    public var maxLines: Int
    /// Extra spacing between characters in em (Android letterSpacing; lanes use 0.12).
    public var letterSpacingEm: Double
    public init(font: DashFont, color: DashColor, alignment: DashTextAlignment = .left, maxLines: Int = 1, letterSpacingEm: Double = 0) {
        self.font = font; self.color = color; self.alignment = alignment; self.maxLines = maxLines; self.letterSpacingEm = letterSpacingEm
    }
}

public enum DashLineCap: String, Hashable, Sendable, Codable { case butt, round, square }
public enum DashLineJoin: String, Hashable, Sendable, Codable { case miter, round, bevel }
public enum DashFillRule: String, Hashable, Sendable, Codable { case nonZero, evenOdd }

public struct DashStroke: Hashable, Sendable, Codable {
    public var width: Double
    public var color: DashColor
    public var cap: DashLineCap
    public var join: DashLineJoin
    /// Dash pattern lengths (on, off, …); empty = solid.
    public var dash: [Double]
    public init(width: Double, color: DashColor, cap: DashLineCap = .round, join: DashLineJoin = .round, dash: [Double] = []) {
        self.width = width; self.color = color; self.cap = cap; self.join = join; self.dash = dash
    }
}

/// One drawing operation. Renderers execute them in order.
public enum DashDrawCommand: Hashable, Sendable {
    case fill(DashPath, DashColor, DashFillRule)
    case stroke(DashPath, DashStroke)
    /// Text block laid out inside `rect`: lines are wrapped (word boundaries) up to
    /// `style.maxLines`, the last visible line truncated with "…"; the block is vertically centred
    /// in `rect` (block height = lines × lineHeight where lineHeight = ascent + descent) and each
    /// line horizontally aligned per `style.alignment`. Baseline of line i =
    /// rect.minY + (rect.height − blockHeight)/2 + i·lineHeight + ascent.
    case text(String, DashRect, DashTextStyle)
    /// 256-px raster map tile (slippy z/x/y) drawn into `rect` in the current transform.
    /// `invert` = night mode (RGB → 255 − c). Missing tiles: renderer draws a neutral placeholder
    /// fill and requests the tile in the background.
    case tile(z: Int, x: Int, y: Int, rect: DashRect, invert: Bool)
    /// Save / restore graphics state (transform + clip).
    case save
    case restore
    /// Concatenate a transform to the current one.
    case transform(DashTransform)
    /// Intersect the clip with a path (non-zero rule).
    case clip(DashPath)
}

/// A tappable area produced by the UI builder (renderers ignore it). `id` is interpreted by the
/// dash UI controller, e.g. "fab.recenter", "preview.go", "chip.1", "menu.end".
public struct DashHitRegion: Hashable, Sendable, Codable {
    public var id: String
    public var rect: DashRect
    /// Part of the handlebar focus order (in list order).
    public var focusable: Bool
    public init(id: String, rect: DashRect, focusable: Bool = true) {
        self.id = id; self.rect = rect; self.focusable = focusable
    }
}

/// A complete dash frame description.
public struct DashDisplayList: Hashable, Sendable {
    public var size: DashSize
    /// Cleared before drawing (chrome background, e.g. #101418).
    public var background: DashColor
    public var commands: [DashDrawCommand]
    /// Hit regions, front-most LAST (hit-test in reverse order).
    public var hitRegions: [DashHitRegion]
    public init(size: DashSize, background: DashColor, commands: [DashDrawCommand] = [], hitRegions: [DashHitRegion] = []) {
        self.size = size; self.background = background; self.commands = commands; self.hitRegions = hitRegions
    }

    /// Front-most hit region containing `p`.
    public func hitTest(_ p: DashPoint) -> DashHitRegion? {
        hitRegions.last(where: { $0.rect.contains(p) })
    }
}

public struct DashTextMetrics: Hashable, Sendable {
    public var width: Double
    public var ascent: Double
    public var descent: Double
    public init(width: Double, ascent: Double, descent: Double) { self.width = width; self.ascent = ascent; self.descent = descent }
    public var lineHeight: Double { ascent + descent }
}

/// Measures single-line text. The Apple implementation uses CoreText (`CoreTextMeasurer`);
/// `ApproximateTextMeasurer` is the deterministic Linux/test default.
public protocol DashTextMeasurer: Sendable {
    func measure(_ text: String, font: DashFont) -> DashTextMetrics
}

/// Deterministic approximation of SF Pro / Roboto metrics (good enough for layout tests).
public struct ApproximateTextMeasurer: DashTextMeasurer {
    public init() {}
    public func measure(_ text: String, font: DashFont) -> DashTextMetrics {
        let s = font.size
        var w = 0.0
        for ch in text {
            switch ch {
            case "i", "l", "I", "j", "!", "|", ".", ",", ":", ";", "'", "·": w += 0.28
            case "f", "t", "r", " ": w += 0.33
            case "m", "w", "M", "W": w += 0.86
            case "0"..."9": w += font.monospacedDigits ? 0.6 : 0.56
            default: w += ch.isUppercase ? 0.66 : 0.54
            }
        }
        let weightFactor: Double = (font.weight == .bold || font.weight == .semibold) ? 1.06 : 1.0
        return DashTextMetrics(width: w * s * weightFactor, ascent: s * 0.95, descent: s * 0.25)
    }
}
