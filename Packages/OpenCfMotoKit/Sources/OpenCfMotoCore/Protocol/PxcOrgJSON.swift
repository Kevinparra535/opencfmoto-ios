// SPDX-License-Identifier: AGPL-3.0-or-later
// Re-implements the parsing behaviour of Android's libcore `org.json` (`JSONTokener`,
// `JSONObject(String)`, `JSONObject.opt*` coercions) — the parser OpenCfMoto (Android) uses for every
// JSON the dash sends (docs/spec/control-plane.md §7, §18.6).
//
// Why not JSONSerialization: org.json is lenient (unquoted and single-quoted strings, `=`/`=>`
// separators, `;` between pairs, `#`/`//`/`/* */` comments, trailing bytes after the object are
// ignored) and its `optString/optInt/optBoolean` coercions decide the bike-profile scores. Porting
// the tokenizer keeps both identical on iOS and Linux (JSONSerialization also cannot tell `true`
// from `1` portably).

import Foundation

public enum PxcOrgJSONError: Error, Equatable, CustomStringConvertible {
    case syntax(String)
    case notAnObject

    public var description: String {
        switch self {
        case let .syntax(m): return "org.json syntax error: \(m)"
        case .notAnObject: return "org.json: value is not a JSONObject"
        }
    }
}

/// org.json-compatible parsing and value coercions.
public enum PxcOrgJSON {
    /// `JSONObject(text)`: parses the first value and requires an object; anything after the
    /// object is ignored (Android behaviour). A leading BOM is skipped.
    public static func parseObject(_ text: String) throws -> OrderedJSONObject {
        var t = Tokener(text)
        let v = try t.nextValue()
        guard case let .object(obj) = v else { throw PxcOrgJSONError.notAnObject }
        return obj
    }

    /// `JSONTokener(text).nextValue()`.
    public static func parseValue(_ text: String) throws -> JSONValue {
        var t = Tokener(text)
        return try t.nextValue()
    }

    // MARK: - opt* coercions (JSON.toString / toInteger / toBoolean)

    /// `optString(name)`: String as is; numbers/booleans/null via `String.valueOf` ("null" for a
    /// JSON null); objects/arrays as their JSON text; missing → nil (callers use "").
    public static func string(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case let .string(s): return s
        case let .int(i): return String(i)
        case let .double(d): return javaDoubleString(d)
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        case .object, .array: return value.jsonString
        }
    }

    /// `optInt(name)`: Integer as is, Long truncated to 32 bits, Double cast (saturating), String via
    /// `(int) Double.parseDouble(s)`; anything else → nil (callers use the fallback).
    public static func int(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case let .int(i): return Int(Int32(truncatingIfNeeded: i))
        case let .double(d): return Int(javaDoubleToInt(d))
        case let .string(s):
            guard let d = javaParseDouble(s) else { return nil }
            return Int(javaDoubleToInt(d))
        default: return nil
        }
    }

    /// `optBoolean(name)`: Boolean as is, or the strings "true"/"false" (case-insensitive); numbers
    /// are NOT coerced (org.json `optBoolean` of `1` is the fallback).
    public static func bool(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case let .bool(b): return b
        case let .string(s):
            switch s.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Java `(int) d`: NaN → 0, out of range saturates, otherwise truncation toward zero.
    static func javaDoubleToInt(_ d: Double) -> Int32 {
        if d.isNaN { return 0 }
        if d >= Double(Int32.max) { return Int32.max }
        if d <= Double(Int32.min) { return Int32.min }
        return Int32(d.rounded(.towardZero))
    }

    /// Java `Double.parseDouble`: trims whitespace, accepts an optional f/F/d/D suffix, "NaN",
    /// "Infinity" (signed). Returns nil where Java throws NumberFormatException.
    static func javaParseDouble(_ s: String) -> Double? {
        // Java String.trim(): drop every char <= U+0020 at both ends.
        let units = Array(s.utf16)
        var lo = 0, hi = units.count
        while lo < hi, units[lo] <= 0x20 { lo += 1 }
        while hi > lo, units[hi - 1] <= 0x20 { hi -= 1 }
        var t = String(decoding: units[lo ..< hi], as: UTF16.self)
        if t.isEmpty { return nil }
        switch t {
        case "NaN", "+NaN", "-NaN": return .nan
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let lower = t.lowercased()
        let isHex = lower.contains("x")
        // Java hex floats need a binary exponent ("0x1p3"); "0x10" is not a double.
        if isHex, !lower.contains("p") { return nil }
        if let last = t.last, "fFdD".contains(last), !isHex {
            t.removeLast()
        }
        // Reject spellings Swift accepts but Java does not.
        if lower.contains("inf") || lower.contains("nan") || t.contains("_") { return nil }
        guard t.allSatisfy({ $0.isASCII }) else { return nil }
        return Double(t)
    }

    /// Java `Double.toString(d)`.
    static func javaDoubleString(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        let mag = abs(d)
        if mag >= 1e-3, mag < 1e7 {
            return "\(d)" // Swift prints plain decimal with ".0" in this range, like Java
        }
        // Scientific: shortest digits from Swift, Java layout "d.dddE±x".
        let text = "\(mag)"
        var digits = ""
        var exponent = 0
        if let eIdx = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let mant = String(text[text.startIndex ..< eIdx])
            exponent = Int(text[text.index(after: eIdx)...]) ?? 0
            let parts = mant.split(separator: ".", omittingEmptySubsequences: false)
            let intPart = String(parts[0])
            let frac = parts.count > 1 ? String(parts[1]) : ""
            digits = intPart + frac
            exponent += intPart.count - 1
        } else {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            let intPart = String(parts[0])
            let frac = parts.count > 1 ? String(parts[1]) : ""
            if intPart != "0" {
                exponent = intPart.count - 1
                digits = intPart + frac
            } else {
                let lead = frac.prefix(while: { $0 == "0" }).count
                exponent = -(lead + 1)
                digits = String(frac.dropFirst(lead))
            }
        }
        while digits.count > 1, digits.hasSuffix("0") { digits.removeLast() }
        while digits.count > 1, digits.hasPrefix("0") { digits.removeFirst() }
        let first = digits.prefix(1)
        var rest = String(digits.dropFirst())
        if rest.isEmpty { rest = "0" }
        return (d < 0 ? "-" : "") + first + "." + rest + "E" + String(exponent)
    }

    // MARK: - Tokener (UTF-16 based, like Java String.charAt)

    struct Tokener {
        private let s: [UInt16]
        private var pos = 0

        init(_ text: String) {
            var units = Array(text.utf16)
            if units.first == 0xFEFF { units.removeFirst() }
            s = units
        }

        private static func c(_ ch: Character) -> UInt16 { ch.utf16.first! }

        mutating func nextValue() throws -> JSONValue {
            let c = nextCleanInternal()
            switch c {
            case nil: throw PxcOrgJSONError.syntax("End of input")
            case Tokener.c("{"): return .object(try readObject())
            case Tokener.c("["): return .array(try readArray())
            case Tokener.c("'"), Tokener.c("\""): return .string(try nextString(quote: c!))
            default:
                pos -= 1
                return try readLiteral()
            }
        }

        /// Skips whitespace (\t \n \r space) and comments; returns the next unit or nil at the end.
        private mutating func nextCleanInternal() -> UInt16? {
            while pos < s.count {
                let c = s[pos]
                pos += 1
                switch c {
                case 0x09, 0x20, 0x0A, 0x0D:
                    continue
                case Tokener.c("/"):
                    if pos == s.count { return c }
                    let peek = s[pos]
                    if peek == Tokener.c("*") {
                        pos += 1
                        if let end = indexOf([Tokener.c("*"), Tokener.c("/")], from: pos) {
                            pos = end + 2
                            continue
                        }
                        // Unterminated comment: org.json throws; treat as end of input.
                        pos = s.count
                        return nil
                    } else if peek == Tokener.c("/") {
                        pos += 1
                        skipToEndOfLine()
                        continue
                    }
                    return c
                case Tokener.c("#"):
                    skipToEndOfLine()
                    continue
                default:
                    return c
                }
            }
            return nil
        }

        private func indexOf(_ needle: [UInt16], from: Int) -> Int? {
            guard needle.count <= s.count else { return nil }
            var i = from
            while i + needle.count <= s.count {
                if Array(s[i ..< i + needle.count]) == needle { return i }
                i += 1
            }
            return nil
        }

        private mutating func skipToEndOfLine() {
            while pos < s.count {
                let c = s[pos]
                if c == 0x0D || c == 0x0A {
                    pos += 1
                    break
                }
                pos += 1
            }
        }

        private mutating func nextString(quote: UInt16) throws -> String {
            var out: [UInt16] = []
            while pos < s.count {
                let c = s[pos]
                pos += 1
                if c == quote { return String(decoding: out, as: UTF16.self) }
                if c == Tokener.c("\\") {
                    if pos == s.count { throw PxcOrgJSONError.syntax("Unterminated escape sequence") }
                    out.append(try readEscapeCharacter())
                } else {
                    out.append(c)
                }
            }
            throw PxcOrgJSONError.syntax("Unterminated string")
        }

        private mutating func readEscapeCharacter() throws -> UInt16 {
            let escaped = s[pos]
            pos += 1
            switch escaped {
            case Tokener.c("u"):
                guard pos + 4 <= s.count else { throw PxcOrgJSONError.syntax("Unterminated escape sequence") }
                let hex = String(decoding: s[pos ..< pos + 4], as: UTF16.self)
                pos += 4
                guard let v = UInt16(hex, radix: 16) else { throw PxcOrgJSONError.syntax("Invalid escape sequence: \(hex)") }
                return v
            case Tokener.c("t"): return 0x09
            case Tokener.c("b"): return 0x08
            case Tokener.c("n"): return 0x0A
            case Tokener.c("r"): return 0x0D
            case Tokener.c("f"): return 0x0C
            default: return escaped // \' \" \\ and any other char escape themselves
            }
        }

        private static let literalTerminators: Set<UInt16> = Set("{}[]/\\:,=;# \t\u{0C}".utf16)

        private mutating func readLiteral() throws -> JSONValue {
            let start = pos
            while pos < s.count {
                let c = s[pos]
                if c == 0x0D || c == 0x0A || Tokener.literalTerminators.contains(c) { break }
                pos += 1
            }
            let literal = String(decoding: s[start ..< pos], as: UTF16.self)
            if literal.isEmpty { throw PxcOrgJSONError.syntax("Expected literal value") }
            let lower = literal.lowercased()
            if lower == "null" { return .null }
            if lower == "true" { return .bool(true) }
            if lower == "false" { return .bool(false) }
            // Integral types (with Java's 0x / leading-0 octal prefixes) first.
            if !literal.contains(".") {
                var number = Substring(literal)
                var base = 10
                if literal.hasPrefix("0x") || literal.hasPrefix("0X") {
                    number = number.dropFirst(2)
                    base = 16
                } else if literal.hasPrefix("0"), literal.count > 1 {
                    number = number.dropFirst(1)
                    base = 8
                }
                if let v = Tokener.javaParseLong(String(number), radix: base) { return .int(v) }
            }
            if let d = PxcOrgJSON.javaParseDouble(literal) {
                // JSONObject.put rejects NaN / infinities ("Forbidden numeric value").
                guard d.isFinite else { throw PxcOrgJSONError.syntax("Forbidden numeric value: \(literal)") }
                return .double(d)
            }
            return .string(literal) // unquoted string
        }

        /// Java `Long.parseLong(s, radix)`: optional sign, at least one digit, no whitespace.
        private static func javaParseLong(_ s: String, radix: Int) -> Int64? {
            guard !s.isEmpty else { return nil }
            var body = Substring(s)
            var negative = false
            if body.first == "-" || body.first == "+" {
                negative = body.first == "-"
                body = body.dropFirst()
            }
            guard !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.hexDigitValue.map { $0 < radix } == true }) else { return nil }
            guard let magnitude = UInt64(body, radix: radix) else { return nil }
            if negative {
                if magnitude == UInt64(Int64.max) + 1 { return Int64.min }
                guard magnitude <= UInt64(Int64.max) else { return nil }
                return -Int64(magnitude)
            }
            guard magnitude <= UInt64(Int64.max) else { return nil }
            return Int64(magnitude)
        }

        private mutating func readObject() throws -> OrderedJSONObject {
            var result = OrderedJSONObject()
            let first = nextCleanInternal()
            if first == Tokener.c("}") { return result }
            if first != nil { pos -= 1 }
            while true {
                let name = try nextValue()
                guard case let .string(key) = name else {
                    if case .null = name { throw PxcOrgJSONError.syntax("Names cannot be null") }
                    throw PxcOrgJSONError.syntax("Names must be strings")
                }
                let separator = nextCleanInternal()
                guard separator == Tokener.c(":") || separator == Tokener.c("=") else {
                    throw PxcOrgJSONError.syntax("Expected ':' after \(key)")
                }
                if pos < s.count, s[pos] == Tokener.c(">") { pos += 1 }
                result[key] = try nextValue()
                switch nextCleanInternal() {
                case Tokener.c("}"): return result
                case Tokener.c(";"), Tokener.c(","): continue
                default: throw PxcOrgJSONError.syntax("Unterminated object")
                }
            }
        }

        private mutating func readArray() throws -> [JSONValue] {
            var result: [JSONValue] = []
            var hasTrailingSeparator = false
            while true {
                switch nextCleanInternal() {
                case nil:
                    throw PxcOrgJSONError.syntax("Unterminated array")
                case Tokener.c("]"):
                    if hasTrailingSeparator { result.append(.null) }
                    return result
                case Tokener.c(","), Tokener.c(";"):
                    // A separator without a value first means "null".
                    result.append(.null)
                    hasTrailingSeparator = true
                    continue
                default:
                    pos -= 1
                }
                result.append(try nextValue())
                switch nextCleanInternal() {
                case Tokener.c("]"): return result
                case Tokener.c(","), Tokener.c(";"):
                    hasTrailingSeparator = true
                    continue
                default:
                    throw PxcOrgJSONError.syntax("Unterminated array")
                }
            }
        }
    }
}
