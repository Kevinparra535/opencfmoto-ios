// SPDX-License-Identifier: AGPL-3.0-or-later
// JVM / Kotlin / Android string semantics needed for byte-exact ports of the Android app
// (OpenCfMoto, AGPL-3.0): Kotlin `trim()` / `isBlank()`, `java.net.URLDecoder` (Android flavour),
// `android.net.Uri.encode`, Kotlin ignore-case `contains`, `String.toIntOrNull()`,
// `String.hashCode()` and UTF-16 `takeLast`.
//
// Kotlin `Char` is a UTF-16 code unit, so the helpers below work on UTF-16 / Unicode scalars,
// never on Swift `Character`s (grapheme clusters would hide a delimiter followed by a combining mark).

import Foundation

/// Internal helpers (core-app). Kept internal and uniquely named to avoid collisions in the module.
enum AppJvmText {

    // MARK: whitespace / trim

    /// Kotlin/JVM `Char.isWhitespace()` = `Character.isWhitespace(c) || Character.isSpaceChar(c)`
    /// for one UTF-16 unit: categories Zs / Zl / Zp (incl. no-break spaces) plus U+0009…U+000D and
    /// U+001C…U+001F. U+0085, U+200B and U+FEFF are NOT whitespace.
    static func isKotlinWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09 ... 0x0D, 0x1C ... 0x1F, 0x20:
            return true
        case 0xD800 ... 0xDFFF:
            return false
        default:
            if unit < 0x80 { return false }
            guard let scalar = Unicode.Scalar(unit) else { return false }
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value <= 0xFFFF && isKotlinWhitespace(UInt16(scalar.value))
    }

    /// Kotlin `String.trim()`.
    static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isKotlinWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isKotlinWhitespace($0) })
        else { return "" }
        return String(Substring(scalars[first ... last]))
    }

    /// Kotlin `CharSequence.isBlank()` (empty or only whitespace).
    static func isBlank(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { isKotlinWhitespace($0) }
    }

    // MARK: substring helpers (first occurrence, scalar based — delimiters are ASCII)

    /// Kotlin `substringAfter(delimiter, missingDelimiterValue)`.
    static func substringAfter(_ s: String, _ delimiter: Unicode.Scalar, missing: String) -> String {
        let scalars = s.unicodeScalars
        guard let i = scalars.firstIndex(of: delimiter) else { return missing }
        return String(Substring(scalars[scalars.index(after: i)...]))
    }

    /// Kotlin `substringBefore(delimiter)` (whole string when the delimiter is absent).
    static func substringBefore(_ s: String, _ delimiter: Unicode.Scalar) -> String {
        let scalars = s.unicodeScalars
        guard let i = scalars.firstIndex(of: delimiter) else { return s }
        return String(Substring(scalars[..<i]))
    }

    /// Kotlin `split(delimiter)` keeping empty parts.
    static func split(_ s: String, _ delimiter: Unicode.Scalar) -> [String] {
        s.unicodeScalars.split(separator: delimiter, omittingEmptySubsequences: false).map { String(Substring($0)) }
    }

    /// Kotlin `split(delimiter, limit = 2)`.
    static func split2(_ s: String, _ delimiter: Unicode.Scalar) -> [String] {
        let scalars = s.unicodeScalars
        guard let i = scalars.firstIndex(of: delimiter) else { return [s] }
        return [String(Substring(scalars[..<i])), String(Substring(scalars[scalars.index(after: i)...]))]
    }

    /// `(key, value)` split at the first `=`; value nil when there is no `=`.
    static func splitAtFirstEquals(_ part: String) -> (key: String, value: String?) {
        let scalars = part.unicodeScalars
        guard let i = scalars.firstIndex(of: "=") else { return (part, nil) }
        return (String(Substring(scalars[..<i])), String(Substring(scalars[scalars.index(after: i)...])))
    }

    /// Kotlin `takeLast(n)` on UTF-16 units (a split surrogate pair becomes U+FFFD).
    static func takeLastUTF16(_ s: String, _ n: Int) -> String {
        let units = Array(s.utf16)
        if units.count <= n { return s }
        return String(decoding: units[(units.count - n)...], as: UTF16.self)
    }

    /// UTF-16 length (Java `String.length()`).
    static func utf16Length(_ s: String) -> Int { s.utf16.count }

    // MARK: case-insensitive matching (Kotlin `Char.equals(other, ignoreCase = true)`)

    /// True when haystack unit `h` equals ASCII needle unit `n` ignoring case with Java's simple
    /// case mappings: besides ASCII case pairs, `ı`/`İ` match `i`, `ſ` matches `s`, KELVIN SIGN matches `k`.
    static func asciiEqualsIgnoreCase(_ h: UInt16, _ n: UInt16) -> Bool {
        if h == n { return true }
        let nl = (n >= 0x41 && n <= 0x5A) ? n + 0x20 : n
        guard nl >= 0x61 && nl <= 0x7A else { return false }   // not a letter: exact match only
        let hl = (h >= 0x41 && h <= 0x5A) ? h + 0x20 : h
        if hl == nl { return true }
        switch h {
        case 0x0131, 0x0130: return nl == 0x69   // ı, İ → i
        case 0x017F: return nl == 0x73           // ſ → s
        case 0x212A: return nl == 0x6B           // K (Kelvin) → k
        default: return false
        }
    }

    /// Kotlin `CharSequence.contains(other, ignoreCase = true)` for an ASCII `needle`.
    static func containsIgnoreCase(_ haystack: String, _ needle: String) -> Bool {
        let h = Array(haystack.utf16), n = Array(needle.utf16)
        if n.isEmpty { return true }
        if n.count > h.count { return false }
        var start = 0
        while start + n.count <= h.count {
            var k = 0
            while k < n.count, asciiEqualsIgnoreCase(h[start + k], n[k]) { k += 1 }
            if k == n.count { return true }
            start += 1
        }
        return false
    }

    /// Kotlin `String.equals(other, ignoreCase = true)` for an ASCII `other`.
    static func equalsIgnoreCase(_ s: String, _ ascii: String) -> Bool {
        let h = Array(s.utf16), n = Array(ascii.utf16)
        guard h.count == n.count else { return false }
        for k in 0 ..< n.count where !asciiEqualsIgnoreCase(h[k], n[k]) { return false }
        return true
    }

    /// Kotlin `startsWith(prefix, ignoreCase = true)` for an ASCII prefix.
    static func startsWithIgnoreCase(_ s: String, _ prefix: String) -> Bool {
        let h = Array(s.utf16), n = Array(prefix.utf16)
        guard n.count <= h.count else { return false }
        for k in 0 ..< n.count where !asciiEqualsIgnoreCase(h[k], n[k]) { return false }
        return true
    }

    // MARK: numbers

    /// `Character.digit(c, 10)` for one UTF-16 unit (Unicode decimal digits, BMP only).
    static func decimalDigit(_ unit: UInt16) -> Int? {
        if unit >= 0x30 && unit <= 0x39 { return Int(unit - 0x30) }
        if unit < 0x80 || (0xD800 ... 0xDFFF).contains(unit) { return nil }
        guard let scalar = Unicode.Scalar(unit),
              scalar.properties.generalCategory == .decimalNumber,
              let v = scalar.properties.numericValue else { return nil }
        return Int(v)
    }

    /// Kotlin `String.toIntOrNull()` (radix 10, 32-bit, optional leading `+`/`-`, Unicode digits).
    static func toIntOrNull(_ s: String) -> Int? {
        let units = Array(s.utf16)
        guard !units.isEmpty else { return nil }
        var start = 0
        var negative = false
        if units[0] < 0x30 {   // possible sign
            if units.count == 1 { return nil }
            if units[0] == 0x2D { negative = true } else if units[0] == 0x2B { negative = false } else { return nil }
            start = 1
        }
        var magnitude: Int64 = 0
        let limit: Int64 = negative ? 2_147_483_648 : 2_147_483_647
        for i in start ..< units.count {
            guard let d = decimalDigit(units[i]) else { return nil }
            magnitude = magnitude * 10 + Int64(d)
            if magnitude > limit { return nil }
        }
        return Int(negative ? -magnitude : magnitude)
    }

    /// Java `String.hashCode()`: `h = 31*h + c` over UTF-16 units with 32-bit wrap-around.
    static func javaHashCode(_ s: String) -> Int32 {
        var h: Int32 = 0
        for unit in s.utf16 { h = h &* 31 &+ Int32(unit) }
        return h
    }

    // MARK: URL coding

    private static func hexValue(_ unit: UInt16) -> UInt8? {
        switch unit {
        case 0x30 ... 0x39: return UInt8(unit - 0x30)
        case 0x41 ... 0x46: return UInt8(unit - 0x41 + 10)
        case 0x61 ... 0x66: return UInt8(unit - 0x61 + 10)
        default: return nil
        }
    }

    /// `java.net.URLDecoder.decode(s, "UTF-8")` as shipped on Android (ojluni code with Android's
    /// strict hex check): `+` → space, runs of `%XX` decoded as UTF-8 (malformed → U+FFFD).
    /// Returns nil where Android throws `IllegalArgumentException` (non-hex digit after `%`,
    /// incomplete trailing escape) — callers then keep the raw value, as the Kotlin code does.
    static func androidURLDecode(_ s: String) -> String? {
        let units = Array(s.utf16)
        let n = units.count
        var out: [UInt16] = []
        out.reserveCapacity(n)
        var changed = false
        var i = 0
        while i < n {
            var c = units[i]
            if c == 0x2B { // '+'
                out.append(0x20)
                i += 1
                changed = true
            } else if c == 0x25 { // '%'
                var bytes: [UInt8] = []
                while i + 2 < n && c == 0x25 {
                    guard let hi = hexValue(units[i + 1]), let lo = hexValue(units[i + 2]) else { return nil }
                    bytes.append(hi << 4 | lo)
                    i += 3
                    if i < n { c = units[i] }
                }
                if i < n && c == 0x25 { return nil } // incomplete trailing escape
                out.append(contentsOf: String(decoding: bytes, as: UTF8.self).utf16)
                changed = true
            } else {
                out.append(c)
                i += 1
            }
        }
        return changed ? String(decoding: out, as: UTF16.self) : s
    }

    private static let upperHex: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// `android.net.Uri.encode(s)`: keeps `A–Z a–z 0–9 _ - ! . ~ ' ( ) *`, percent-encodes everything
    /// else as UTF-8 `%XX` with upper-case hex (space → `%20`, `+` → `%2B`).
    static func androidUriEncode(_ s: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            switch b {
            case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39,
                 0x5F, 0x2D, 0x21, 0x2E, 0x7E, 0x27, 0x28, 0x29, 0x2A:
                out.append(b)
            default:
                out.append(0x25)
                out.append(upperHex[Int(b >> 4)])
                out.append(upperHex[Int(b & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: regex (ICU — the same engine Android's java.util.regex uses)

    /// First match of `regex` in `s`, nil if none.
    static func firstMatch(_ regex: NSRegularExpression, in s: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count))
    }

    /// Kotlin `Regex.containsMatchIn`.
    static func containsMatch(_ regex: NSRegularExpression, _ s: String) -> Bool {
        firstMatch(regex, in: s) != nil
    }

    /// Kotlin `Regex.matchEntire` (the whole input must match).
    static func matchEntire(_ regex: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        let full = NSRange(location: 0, length: s.utf16.count)
        guard let m = regex.firstMatch(in: s, options: [.anchored], range: full), m.range == full else { return nil }
        return m
    }

    /// Captured group `i` of `match` in `s` (nil when the group did not participate).
    static func group(_ match: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        let r = match.range(at: i)
        guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
        return String(s[range])
    }

    /// Substring from a UTF-16 offset to the end (Kotlin `substring(startIndex)`).
    static func substringFromUTF16(_ s: String, _ offset: Int) -> String {
        let units = Array(s.utf16)
        guard offset < units.count else { return "" }
        return String(decoding: units[offset...], as: UTF16.self)
    }
}
