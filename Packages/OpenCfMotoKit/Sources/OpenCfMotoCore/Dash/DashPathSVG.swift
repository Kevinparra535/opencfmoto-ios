// SPDX-License-Identifier: AGPL-3.0-or-later
// SVG / Android VectorDrawable path-data parser for `DashPath` (contract in Dash/DisplayList.swift).
// Supports M m L l H h V v C c S s Q q T t A a Z z, implicit command repeats (pairs after M/m
// are line-tos), packed numbers ("0.5.5", "1-2", "1e-3") and packed arc flags ("a1 1 0 01.5.5").
// Elliptical arcs are converted to cubic Béziers (≤ 90° per segment) so renderers only need
// move/line/quad/cubic/close.

import Foundation

public enum DashSVGPathError: Error, Equatable, CustomStringConvertible {
    /// A character that is neither a command, a number nor a separator.
    case unexpectedCharacter(Character, offset: Int)
    /// A number was required at `offset`.
    case expectedNumber(offset: Int)
    /// An arc flag (`0`/`1`) was required at `offset`.
    case expectedFlag(offset: Int)
    /// Path data must start with M/m.
    case missingMoveTo(offset: Int)

    public var description: String {
        switch self {
        case let .unexpectedCharacter(c, o): return "unexpected character '\(c)' at \(o)"
        case let .expectedNumber(o): return "expected a number at \(o)"
        case let .expectedFlag(o): return "expected an arc flag (0/1) at \(o)"
        case let .missingMoveTo(o): return "path data must start with M/m (offset \(o))"
        }
    }
}

public extension DashPath {
    /// Parses SVG path data (e.g. an Android `android:pathData`). Throws `DashSVGPathError`.
    init(svg: String) throws {
        var parser = DashSVGPathParser(svg)
        self = try parser.parse()
    }

    /// SVG path data for this path ("M x y L … Z"), numbers with ≤ 3 decimals (POSIX format).
    var svgPathData: String {
        var parts: [String] = []
        parts.reserveCapacity(elements.count)
        for e in elements {
            switch e {
            case let .move(p): parts.append("M\(DashSVGNumber.format(p.x)) \(DashSVGNumber.format(p.y))")
            case let .line(p): parts.append("L\(DashSVGNumber.format(p.x)) \(DashSVGNumber.format(p.y))")
            case let .quad(c, p):
                parts.append("Q\(DashSVGNumber.format(c.x)) \(DashSVGNumber.format(c.y)) \(DashSVGNumber.format(p.x)) \(DashSVGNumber.format(p.y))")
            case let .cubic(c1, c2, p):
                parts.append("C\(DashSVGNumber.format(c1.x)) \(DashSVGNumber.format(c1.y)) \(DashSVGNumber.format(c2.x)) \(DashSVGNumber.format(c2.y)) \(DashSVGNumber.format(p.x)) \(DashSVGNumber.format(p.y))")
            case .close: parts.append("Z")
            }
        }
        return parts.joined(separator: " ")
    }

    /// Bounding box of all on-curve and control points (a superset of the exact curve bounds;
    /// exact for polygons). nil for an empty path.
    var controlPointBounds: DashRect? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ p: DashPoint) {
            minX = Swift.min(minX, p.x); minY = Swift.min(minY, p.y)
            maxX = Swift.max(maxX, p.x); maxY = Swift.max(maxY, p.y)
        }
        for e in elements {
            switch e {
            case let .move(p), let .line(p): add(p)
            case let .quad(c, p): add(c); add(p)
            case let .cubic(c1, c2, p): add(c1); add(c2); add(p)
            case .close: break
            }
        }
        guard minX.isFinite else { return nil }
        return DashRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// POSIX number formatting shared by the SVG writers (no locale, ≤ 3 decimals, no "-0").
enum DashSVGNumber {
    static func format(_ v: Double, decimals: Int = 3) -> String {
        guard v.isFinite else { return "0" }
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" || s.isEmpty { s = "0" }
        return s
    }
}

/// Converts one SVG elliptical arc (endpoint parameterisation) into cubic Bézier segments
/// (control1, control2, end), each spanning at most 90°. Returns `[]` when the end point equals
/// the start point and a single straight "cubic" (a line) when a radius is zero.
public func dashArcToCubics(from p0: DashPoint, rx rxIn: Double, ry ryIn: Double, xAxisRotationDeg: Double,
                            largeArc: Bool, sweep: Bool, to p1: DashPoint) -> [(DashPoint, DashPoint, DashPoint)] {
    if p0.x == p1.x && p0.y == p1.y { return [] }
    var rx = abs(rxIn), ry = abs(ryIn)
    if rx == 0 || ry == 0 {
        // Degenerate: straight line expressed as a cubic with controls on the chord.
        let c1 = DashPoint(p0.x + (p1.x - p0.x) / 3, p0.y + (p1.y - p0.y) / 3)
        let c2 = DashPoint(p0.x + 2 * (p1.x - p0.x) / 3, p0.y + 2 * (p1.y - p0.y) / 3)
        return [(c1, c2, p1)]
    }
    let phi = xAxisRotationDeg * .pi / 180
    let cosPhi = cos(phi), sinPhi = sin(phi)
    let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
    let x1p = cosPhi * dx2 + sinPhi * dy2
    let y1p = -sinPhi * dx2 + cosPhi * dy2
    // Out-of-range radii are scaled up (SVG F.6.6).
    let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lambda > 1 {
        let s = lambda.squareRoot()
        rx *= s; ry *= s
    }
    let rx2 = rx * rx, ry2 = ry * ry
    let num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
    let den = rx2 * y1p * y1p + ry2 * x1p * x1p
    var coef = den == 0 ? 0 : (max(0, num / den)).squareRoot()
    if largeArc == sweep { coef = -coef }
    let cxp = coef * (rx * y1p / ry)
    let cyp = coef * -(ry * x1p / rx)
    let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
    let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

    func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
    let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
    let theta1 = angle(1, 0, ux, uy)
    var dTheta = angle(ux, uy, vx, vy)
    if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
    if sweep && dTheta < 0 { dTheta += 2 * .pi }

    let segments = max(1, Int((abs(dTheta) / (.pi / 2) - 1e-9).rounded(.up)))
    let delta = dTheta / Double(segments)
    let t = 4.0 / 3.0 * tan(delta / 4)
    func map(_ x: Double, _ y: Double) -> DashPoint {
        DashPoint(cx + rx * cosPhi * x - ry * sinPhi * y, cy + rx * sinPhi * x + ry * cosPhi * y)
    }
    var out: [(DashPoint, DashPoint, DashPoint)] = []
    out.reserveCapacity(segments)
    for k in 0 ..< segments {
        let a1 = theta1 + Double(k) * delta
        let a2 = a1 + delta
        let c1a = cos(a1), s1a = sin(a1), c2a = cos(a2), s2a = sin(a2)
        let q1 = map(c1a - t * s1a, s1a + t * c1a)
        let q2 = map(c2a + t * s2a, s2a - t * c2a)
        let end = k == segments - 1 ? p1 : map(c2a, s2a)
        out.append((q1, q2, end))
    }
    return out
}

struct DashSVGPathParser {
    private let bytes: [UInt8]
    private var i = 0
    private var path = DashPath()
    private var current = DashPoint.zero
    private var subpathStart = DashPoint.zero
    private var needsMoveAfterClose = false
    private enum Last { case other, cubic(DashPoint), quad(DashPoint) }
    private var last: Last = .other

    init(_ s: String) { bytes = Array(s.utf8) }

    private static func isSeparator(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0x2C // space \t \n \r \f ,
    }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isNumberStart(_ c: UInt8) -> Bool {
        isDigit(c) || c == 0x2B || c == 0x2D || c == 0x2E // + - .
    }
    private static let commandLetters: Set<UInt8> = Set("MmLlHhVvCcSsQqTtAaZz".utf8)

    private mutating func skipSeparators() {
        while i < bytes.count, Self.isSeparator(bytes[i]) { i += 1 }
    }

    private func char(at offset: Int) -> Character {
        let end = min(bytes.count, offset + 4)
        let s = String(decoding: bytes[offset ..< end], as: UTF8.self)
        return s.first ?? "?"
    }

    private mutating func number() throws -> Double {
        skipSeparators()
        let start = i
        guard i < bytes.count, Self.isNumberStart(bytes[i]) else { throw DashSVGPathError.expectedNumber(offset: i) }
        if bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
        var digits = 0
        while i < bytes.count, Self.isDigit(bytes[i]) { i += 1; digits += 1 }
        if i < bytes.count, bytes[i] == 0x2E {
            i += 1
            while i < bytes.count, Self.isDigit(bytes[i]) { i += 1; digits += 1 }
        }
        guard digits > 0 else { throw DashSVGPathError.expectedNumber(offset: start) }
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 { // e E
            var j = i + 1
            if j < bytes.count, bytes[j] == 0x2B || bytes[j] == 0x2D { j += 1 }
            var expDigits = 0
            while j < bytes.count, Self.isDigit(bytes[j]) { j += 1; expDigits += 1 }
            if expDigits > 0 { i = j }
        }
        let text = String(decoding: bytes[start ..< i], as: UTF8.self)
        guard let v = Double(text) else { throw DashSVGPathError.expectedNumber(offset: start) }
        return v
    }

    private mutating func flag() throws -> Bool {
        skipSeparators()
        guard i < bytes.count else { throw DashSVGPathError.expectedFlag(offset: i) }
        switch bytes[i] {
        case 0x30: i += 1; return false
        case 0x31: i += 1; return true
        default: throw DashSVGPathError.expectedFlag(offset: i)
        }
    }

    private mutating func point(relative: Bool) throws -> DashPoint {
        let x = try number()
        let y = try number()
        return relative ? DashPoint(current.x + x, current.y + y) : DashPoint(x, y)
    }

    /// After a close, a drawing command without M starts a new subpath at the closed one's start.
    private mutating func ensureSubpath() {
        if needsMoveAfterClose {
            path.move(to: current)
            needsMoveAfterClose = false
        }
    }

    mutating func parse() throws -> DashPath {
        skipSeparators()
        var command: UInt8?
        var first = true
        while true {
            skipSeparators()
            guard i < bytes.count else { break }
            let c = bytes[i]
            if Self.commandLetters.contains(c) {
                command = c
                i += 1
            } else if !Self.isNumberStart(c) {
                throw DashSVGPathError.unexpectedCharacter(char(at: i), offset: i)
            } else if command == nil || command == 0x5A || command == 0x7A {
                // Numbers with no pending command (or after Z) are invalid.
                if command == nil { throw DashSVGPathError.missingMoveTo(offset: i) }
                throw DashSVGPathError.unexpectedCharacter(char(at: i), offset: i)
            }
            guard let cmd = command else { throw DashSVGPathError.missingMoveTo(offset: i) }
            if first {
                guard cmd == 0x4D || cmd == 0x6D else { throw DashSVGPathError.missingMoveTo(offset: i - 1) }
                first = false
            }
            try execute(cmd)
            if cmd == 0x4D { command = 0x4C } // M → implicit L
            if cmd == 0x6D { command = 0x6C } // m → implicit l
        }
        return path
    }

    private mutating func execute(_ cmd: UInt8) throws {
        let relative = cmd >= 0x61 // lower case
        switch cmd {
        case 0x4D, 0x6D: // M m
            let p = try point(relative: relative)
            path.move(to: p)
            current = p
            subpathStart = p
            needsMoveAfterClose = false
            last = .other
        case 0x4C, 0x6C: // L l
            let p = try point(relative: relative)
            ensureSubpath()
            path.line(to: p)
            current = p
            last = .other
        case 0x48, 0x68: // H h
            let x = try number()
            let p = DashPoint(relative ? current.x + x : x, current.y)
            ensureSubpath()
            path.line(to: p)
            current = p
            last = .other
        case 0x56, 0x76: // V v
            let y = try number()
            let p = DashPoint(current.x, relative ? current.y + y : y)
            ensureSubpath()
            path.line(to: p)
            current = p
            last = .other
        case 0x43, 0x63: // C c
            let c1 = try point(relative: relative)
            let c2 = try point(relative: relative)
            let p = try point(relative: relative)
            ensureSubpath()
            path.cubic(to: p, control1: c1, control2: c2)
            current = p
            last = .cubic(c2)
        case 0x53, 0x73: // S s
            let c2 = try point(relative: relative)
            let p = try point(relative: relative)
            let c1: DashPoint
            if case let .cubic(prev) = last {
                c1 = DashPoint(2 * current.x - prev.x, 2 * current.y - prev.y)
            } else {
                c1 = current
            }
            ensureSubpath()
            path.cubic(to: p, control1: c1, control2: c2)
            current = p
            last = .cubic(c2)
        case 0x51, 0x71: // Q q
            let c = try point(relative: relative)
            let p = try point(relative: relative)
            ensureSubpath()
            path.quad(to: p, control: c)
            current = p
            last = .quad(c)
        case 0x54, 0x74: // T t
            let p = try point(relative: relative)
            let c: DashPoint
            if case let .quad(prev) = last {
                c = DashPoint(2 * current.x - prev.x, 2 * current.y - prev.y)
            } else {
                c = current
            }
            ensureSubpath()
            path.quad(to: p, control: c)
            current = p
            last = .quad(c)
        case 0x41, 0x61: // A a
            let rx = try number()
            let ry = try number()
            let rot = try number()
            let large = try flag()
            let sweep = try flag()
            let p = try point(relative: relative)
            ensureSubpath()
            for (c1, c2, end) in dashArcToCubics(from: current, rx: rx, ry: ry, xAxisRotationDeg: rot,
                                                largeArc: large, sweep: sweep, to: p) {
                path.cubic(to: end, control1: c1, control2: c2)
            }
            current = p
            last = .other
        case 0x5A, 0x7A: // Z z
            path.close()
            current = subpathStart
            needsMoveAfterClose = true
            last = .other
        default:
            throw DashSVGPathError.unexpectedCharacter(Character(UnicodeScalar(cmd)), offset: i - 1)
        }
    }
}
