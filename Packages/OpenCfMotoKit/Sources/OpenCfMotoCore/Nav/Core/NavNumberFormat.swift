// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Number formatting that reproduces the JVM behaviour the Android app relies on
// (docs/spec/navigation-dash.md §0, §4.11, §15.8):
//  - `String.format("%.Nf", x)` rounds the *shortest decimal representation* of the double
//    HALF_UP (12.5 → "13", 0.15 → "0.2"), unlike C `printf` (round-half-even on the binary value);
//  - Kotlin `roundToInt()` / Java `Math.round` round ties toward +∞;
//  - Kotlin `Double.toString()` (used for coordinates in URLs) is Java `Double.toString`.
// Output always uses ASCII digits; the decimal separator is explicit (POSIX "." by default).

import Foundation

public enum NavNumberFormat {
    // MARK: - Rounding

    /// Kotlin `Double.roundToInt()` / Java `Math.round`: nearest integer, ties toward +∞.
    /// Non-finite input returns 0; values beyond `Int` range are clamped.
    public static func roundHalfUp(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        let f = x.rounded(.down)
        let r = (x - f) >= 0.5 ? f + 1 : f
        if r >= Double(Int.max) { return Int.max }
        if r <= Double(Int.min) { return Int.min }
        return Int(r)
    }

    /// Kotlin `Double.toInt()`: truncation toward zero, NaN → 0, saturating.
    public static func truncateToInt(_ x: Double) -> Int {
        guard !x.isNaN else { return 0 }
        if x >= Double(Int.max) { return Int.max }
        if x <= Double(Int.min) { return Int.min }
        return Int(x)
    }

    // MARK: - Shortest decimal digits

    /// Shortest round-trip decimal digits of |x|: `digits` has no leading zeros (except "0" for
    /// zero) and `pointPos` is the number of digits before the decimal point (may be ≤ 0 or
    /// > digits.count), i.e. |x| = 0.d1d2… × 10^pointPos.
    struct DecimalDigits: Equatable {
        var digits: [UInt8]
        var pointPos: Int
    }

    static func shortestDigits(_ value: Double) -> DecimalDigits {
        let a = abs(value)
        if a == 0 { return DecimalDigits(digits: [0], pointPos: 1) }
        // Swift's description is the shortest round-trip representation ("123.45", "1e-05",
        // "1.2345e+20", "10000000.0").
        let text = a.description
        var mantissa = Substring(text)
        var exp = 0
        if let eIdx = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[text.startIndex ..< eIdx]
            exp = Int(text[text.index(after: eIdx)...]) ?? 0
        }
        var intPart = mantissa
        var fracPart: Substring = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = mantissa[mantissa.startIndex ..< dot]
            fracPart = mantissa[mantissa.index(after: dot)...]
        }
        var digits: [UInt8] = []
        digits.reserveCapacity(intPart.count + fracPart.count)
        for ch in intPart { if let v = ch.wholeNumberValue { digits.append(UInt8(v)) } }
        for ch in fracPart { if let v = ch.wholeNumberValue { digits.append(UInt8(v)) } }
        var pointPos = intPart.count + exp
        // Strip leading zeros (each one moves the point left).
        var lead = 0
        while lead < digits.count - 1, digits[lead] == 0 { lead += 1 }
        if lead > 0 { digits.removeFirst(lead); pointPos -= lead }
        // Strip trailing zeros (do not change the value).
        while digits.count > 1, digits.last == 0 { digits.removeLast() }
        if digits == [0] { pointPos = 1 }
        return DecimalDigits(digits: digits, pointPos: pointPos)
    }

    // MARK: - %.Nf

    /// Java `String.format("%.<decimals>f", value)` with HALF_UP rounding of the shortest decimal
    /// representation, using `decimalSeparator` (default "."). No grouping separators.
    public static func fixed(_ value: Double, decimals: Int, decimalSeparator: Character = ".") -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let decimals = max(0, decimals)
        let negative = value.sign == .minus
        let dd = shortestDigits(value)
        // Number of significant digits to keep so that `decimals` fraction digits remain.
        let keep = dd.pointPos + decimals
        var kept: [UInt8]
        var pointPos = dd.pointPos
        if keep < 0 {
            kept = []          // far below half a unit in the last place → 0
            pointPos = -decimals
        } else {
            kept = Array(dd.digits.prefix(keep))
            if kept.count < keep { kept.append(contentsOf: repeatElement(0, count: keep - kept.count)) }
            let next: UInt8 = keep < dd.digits.count ? dd.digits[keep] : 0
            if next >= 5 {
                // Increment `kept` as a decimal integer.
                var i = kept.count - 1
                var carry = true
                while carry && i >= 0 {
                    if kept[i] == 9 { kept[i] = 0; i -= 1 } else { kept[i] += 1; carry = false }
                }
                if carry { kept.insert(1, at: 0); pointPos += 1 }
            }
        }
        // kept represents the value scaled so that its last digit is 10^-decimals and the digit
        // count before the point is `pointPos`.
        var intDigits: [UInt8]
        var fracDigits: [UInt8]
        if pointPos <= 0 {
            intDigits = [0]
            fracDigits = [UInt8](repeating: 0, count: min(decimals, -pointPos)) + kept
        } else {
            intDigits = Array(kept.prefix(pointPos))
            if intDigits.count < pointPos { intDigits.append(contentsOf: repeatElement(0, count: pointPos - intDigits.count)) }
            fracDigits = Array(kept.dropFirst(pointPos))
        }
        if fracDigits.count < decimals { fracDigits.append(contentsOf: repeatElement(0, count: decimals - fracDigits.count)) }
        if fracDigits.count > decimals { fracDigits = Array(fracDigits.prefix(decimals)) }
        while intDigits.count > 1, intDigits.first == 0 { intDigits.removeFirst() }
        var out = ""
        let allZero = intDigits.allSatisfy { $0 == 0 } && fracDigits.allSatisfy { $0 == 0 }
        // Java keeps the sign of negative values that round to zero ("-0.0").
        if negative && !(allZero && value == 0 && value.sign == .plus) { out.append("-") }
        for d in intDigits { out.append(Character(Unicode.Scalar(48 + d))) }
        if decimals > 0 {
            out.append(decimalSeparator)
            for d in fracDigits { out.append(Character(Unicode.Scalar(48 + d))) }
        }
        return out
    }

    // MARK: - Java Double.toString

    /// Java / Kotlin `Double.toString()`: plain decimal with at least one fraction digit for
    /// 1e-3 ≤ |x| < 1e7 ("45.0", "26.1025"), otherwise computerized scientific notation
    /// ("1.0E7", "1.0E-4", "1.2345E-5"). Uses the shortest round-trip digits (JDK 19+).
    public static func javaString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0.0" }
        let a = abs(value)
        let dd = shortestDigits(a)
        let digitText = dd.digits.map { String($0) }.joined()
        if a >= 1e-3 && a < 1e7 {
            if dd.pointPos <= 0 {
                return sign + "0." + String(repeating: "0", count: -dd.pointPos) + digitText
            }
            if dd.pointPos >= dd.digits.count {
                return sign + digitText + String(repeating: "0", count: dd.pointPos - dd.digits.count) + ".0"
            }
            let idx = digitText.index(digitText.startIndex, offsetBy: dd.pointPos)
            return sign + digitText[..<idx] + "." + digitText[idx...]
        }
        let first = digitText.prefix(1)
        var rest = String(digitText.dropFirst())
        if rest.isEmpty { rest = "0" }
        return sign + first + "." + rest + "E" + String(dd.pointPos - 1)
    }

    /// `String.format(Locale.US, "%d")`-style integer text (ASCII).
    public static func int(_ v: Int) -> String { String(v) }

    /// Zero-padded integer, e.g. `padded(5, width: 2)` → "05".
    public static func padded(_ v: Int, width: Int) -> String {
        let s = String(abs(v))
        let body = s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
        return v < 0 ? "-" + body : body
    }
}
