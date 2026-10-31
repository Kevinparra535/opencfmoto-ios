// SPDX-License-Identifier: AGPL-3.0-or-later
// Java number semantics used by the Android app's persisted formats and UI strings:
// `Double.toString`, `Double.parseDouble`, `Long.parseLong`, `String.format("%.Nf", Locale.US)`
// (HALF_UP on the shortest decimal), `Math.round(float)` and the saturating `(int)`/`(long)` casts.

import Foundation

/// Internal helpers (core-app).
enum AppJavaNumber {

    // MARK: - Shortest decimal digits

    /// Shortest round-trip decimal digits of a finite, non-zero `|d|` as `0.d1d2… × 10^exp10`.
    /// (Swift's `description` is shortest round-trip, like JDK 19+ `Double.toString`.)
    static func shortestDigits(_ d: Double) -> (digits: [UInt8], exp10: Int) {
        let text = "\(abs(d))"
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        var digits: [UInt8] = []
        var pointPos: Int?
        for ch in mantissa {
            if ch == "." { pointPos = digits.count; continue }
            if let v = ch.wholeNumberValue { digits.append(UInt8(v)) }
        }
        var intDigits = pointPos ?? digits.count
        // strip leading zeros
        while let first = digits.first, first == 0, digits.count > 1 {
            digits.removeFirst()
            intDigits -= 1
        }
        // strip trailing zeros
        while let last = digits.last, last == 0, digits.count > 1 { digits.removeLast() }
        if digits == [0] { return ([0], 0) }
        return (digits, intDigits + exponent)
    }

    // MARK: - Double.toString

    /// Java `Double.toString(d)`: plain notation for 1e-3 ≤ |d| < 1e7 (at least one fraction digit),
    /// otherwise `d.dddE±n` (e.g. `1.0E-4`, `1.0E7`).
    static func doubleToString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let sign = d < 0 ? "-" : ""
        let (digits, exp10) = shortestDigits(d)
        let mag = abs(d)
        let ds = digits.map { String($0) }.joined()
        if mag >= 1e-3 && mag < 1e7 {
            if exp10 <= 0 {
                return sign + "0." + String(repeating: "0", count: -exp10) + ds
            }
            if exp10 >= digits.count {
                return sign + ds + String(repeating: "0", count: exp10 - digits.count) + ".0"
            }
            let i = ds.index(ds.startIndex, offsetBy: exp10)
            return sign + ds[..<i] + "." + ds[i...]
        }
        let first = ds.prefix(1)
        let rest = ds.dropFirst()
        return sign + first + "." + (rest.isEmpty ? "0" : rest) + "E" + String(exp10 - 1)
    }

    // MARK: - String.format("%.Nf", Locale.US)

    /// Java `String.format(Locale.US, "%.<precision>f", d)`: the shortest decimal digits rounded
    /// HALF_UP (`1.005` → `1.01`, `0.125` → `0.13`), unlike C `printf` which rounds the binary value.
    static func formatFixed(_ d: Double, precision: Int) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        let negative = d.sign == .minus
        let p = max(0, precision)
        var intPart: [UInt8] = [0]
        var fracPart = [UInt8](repeating: 0, count: p)
        if d != 0 {
            var (digits, exp10) = shortestDigits(d)
            let keep = exp10 + p // number of leading digits that survive
            if keep < 0 {
                digits = [0]; exp10 = 1 // rounds to zero (Java: no rounding when prec < 0)
            } else if keep == 0 {
                if digits[0] >= 5 { digits = [1]; exp10 += 1 } else { digits = [0]; exp10 = 1 }
            } else if keep < digits.count {
                let roundUp = digits[keep] >= 5
                digits = Array(digits[0 ..< keep])
                if roundUp {
                    var i = keep - 1
                    while i >= 0 {
                        if digits[i] == 9 { digits[i] = 0; i -= 1 } else { digits[i] += 1; break }
                    }
                    if i < 0 { digits.insert(1, at: 0); exp10 += 1 }
                }
            }
            // Lay the digits out: value = 0.digits × 10^exp10
            if digits == [0] {
                intPart = [0]
            } else {
                if exp10 > 0 {
                    intPart = (0 ..< exp10).map { $0 < digits.count ? digits[$0] : 0 }
                } else {
                    intPart = [0]
                }
                for k in 0 ..< p {
                    let idx = exp10 + k // digit index for 10^-(k+1)
                    fracPart[k] = (idx >= 0 && idx < digits.count) ? digits[idx] : 0
                }
            }
        }
        let intText = intPart.map { String($0) }.joined()
        let fracText = fracPart.map { String($0) }.joined()
        return (negative ? "-" : "") + intText + (p > 0 ? "." + fracText : "")
    }

    // MARK: - Parsing

    /// Java `Double.parseDouble` / `Double.valueOf(String)` (nil on NumberFormatException):
    /// leading/trailing chars ≤ U+0020 trimmed, optional sign, `NaN`, `Infinity`, decimal with
    /// optional exponent, hex floats (`0x1.8p3`), optional `f`/`F`/`d`/`D` suffix.
    static func parseDouble(_ text: String) -> Double? {
        var u = Array(text.utf16)
        while let f = u.first, f <= 0x20 { u.removeFirst() }
        while let l = u.last, l <= 0x20 { u.removeLast() }
        guard !u.isEmpty, u.allSatisfy({ $0 < 0x80 }) else { return nil }
        var b: [UInt8] = u.map { UInt8($0) }
        var negative = false
        if b[0] == UInt8(ascii: "+") || b[0] == UInt8(ascii: "-") {
            negative = b[0] == UInt8(ascii: "-")
            b.removeFirst()
        }
        let word = String(decoding: b, as: UTF8.self)
        if word == "NaN" { return Double.nan }
        if word == "Infinity" { return negative ? -Double.infinity : Double.infinity }
        if let last = b.last, [UInt8(ascii: "f"), UInt8(ascii: "F"), UInt8(ascii: "d"), UInt8(ascii: "D")].contains(last) {
            b.removeLast()
        }
        guard !b.isEmpty else { return nil }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        func isHexDigit(_ c: UInt8) -> Bool { isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        /// `[+-]? digits+`
        func validExponent(_ e: ArraySlice<UInt8>) -> Bool {
            var e = e
            if let c = e.first, c == UInt8(ascii: "+") || c == UInt8(ascii: "-") { e = e.dropFirst() }
            return !e.isEmpty && e.allSatisfy(isDigit)
        }
        /// `digits [. digits?] | . digits` (with the given digit class)
        func validMantissa(_ m: ArraySlice<UInt8>, _ digit: (UInt8) -> Bool) -> Bool {
            let parts = m.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
            return parts.count <= 2 && parts.allSatisfy { $0.allSatisfy(digit) } && parts.contains { !$0.isEmpty }
        }
        let isHex = b.count >= 2 && b[0] == UInt8(ascii: "0") && (b[1] == UInt8(ascii: "x") || b[1] == UInt8(ascii: "X"))
        if isHex {
            let h = b[2...]
            guard let p = h.firstIndex(where: { $0 == UInt8(ascii: "p") || $0 == UInt8(ascii: "P") }),
                  validMantissa(h[..<p], isHexDigit),
                  validExponent(h[(p + 1)...]) else { return nil }
        } else {
            let e = b.firstIndex(where: { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") })
            guard validMantissa(b[..<(e ?? b.endIndex)], isDigit) else { return nil }
            if let e, !validExponent(b[(e + 1)...]) { return nil }
        }
        guard let v = Double(String(decoding: b, as: UTF8.self)) else { return nil }
        return negative ? -v : v
    }

    /// `Character.digit(c, radix)` for one UTF-16 unit (Unicode decimal digits, ASCII and
    /// full-width Latin letters).
    static func digit(_ unit: UInt16, radix: Int) -> Int? {
        var v: Int?
        switch unit {
        case 0x41 ... 0x5A: v = Int(unit - 0x41) + 10
        case 0x61 ... 0x7A: v = Int(unit - 0x61) + 10
        case 0xFF21 ... 0xFF3A: v = Int(unit - 0xFF21) + 10
        case 0xFF41 ... 0xFF5A: v = Int(unit - 0xFF41) + 10
        default: v = AppJvmText.decimalDigit(unit)
        }
        guard let d = v, d < radix else { return nil }
        return d
    }

    /// Java `Long.parseLong(s, radix)` (nil on NumberFormatException).
    static func parseLong(_ s: String, radix: Int = 10) -> Int64? {
        let u = Array(s.utf16)
        guard !u.isEmpty else { return nil }
        var i = 0
        var negative = false
        if u[0] < 0x30 {
            if u[0] == 0x2D { negative = true } else if u[0] != 0x2B { return nil }
            if u.count == 1 { return nil }
            i = 1
        }
        var magnitude: UInt64 = 0
        let limit: UInt64 = negative ? UInt64(Int64.max) + 1 : UInt64(Int64.max)
        while i < u.count {
            guard let d = digit(u[i], radix: radix) else { return nil }
            let (m1, o1) = magnitude.multipliedReportingOverflow(by: UInt64(radix))
            let (m2, o2) = m1.addingReportingOverflow(UInt64(d))
            if o1 || o2 || m2 > limit { return nil }
            magnitude = m2
            i += 1
        }
        if negative { return magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude) }
        return Int64(magnitude)
    }

    // MARK: - Casts

    /// Java `(long) d`: NaN → 0, saturating, truncation toward zero.
    static func d2l(_ d: Double) -> Int64 {
        if d.isNaN { return 0 }
        if d >= 9_223_372_036_854_775_807.0 { return Int64.max }
        if d <= -9_223_372_036_854_775_808.0 { return Int64.min }
        return Int64(d)
    }

    /// Java `(int) d`: NaN → 0, saturating, truncation toward zero.
    static func d2i(_ d: Double) -> Int32 {
        if d.isNaN { return 0 }
        if d >= 2_147_483_647.0 { return Int32.max }
        if d <= -2_147_483_648.0 { return Int32.min }
        return Int32(d)
    }

    /// Kotlin `Float.toInt()` / Java `(int) f`.
    static func f2i(_ f: Float) -> Int32 { d2i(Double(f)) }

    /// Java `Math.round(float)` = `floor(f + 1/2)` computed exactly; NaN → 0; saturating.
    static func roundFloat(_ f: Float) -> Int32 {
        if f.isNaN { return 0 }
        return d2i((Double(f) + 0.5).rounded(.down))
    }
}
