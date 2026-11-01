// SPDX-License-Identifier: AGPL-3.0-or-later
// Android (AOSP libcore) `org.json` semantics on top of the contract's `JSONValue` model:
// - parser = port of AOSP `JSONTokener` (lenient: comments, unquoted/single-quoted strings,
//   `=`/`=>` separators, `;` separators, hex/octal integers, case-insensitive literals, a leading
//   BOM, trailing text after the first value ignored) with AOSP error messages;
// - the typed `opt*` coercions of `JSONObject` / `JSONArray` (`JSON.toInteger` etc.);
// - writers identical to `JSONObject.toString()` and `toString(indentSpaces)` (`JSONStringer`).
// Used for the cross-platform files: "opencfmoto.settings" v1, `bikes_json`, trip files.

import Foundation

/// Internal (core-app).
enum AndroidOrgJSON {

    struct ParseError: Error, CustomStringConvertible, Equatable {
        let message: String
        var description: String { message }
    }

    // MARK: - Parsing

    /// `JSONTokener(text).nextValue()`.
    static func parseValue(_ text: String) throws -> JSONValue {
        var t = Tokener(text)
        return try t.nextValue()
    }

    /// `new JSONObject(text)`.
    static func parseObject(_ text: String) throws -> OrderedJSONObject {
        var t = Tokener(text)
        let v = try t.nextValue()
        guard case let .object(o) = v else { throw typeMismatch(v, "JSONObject") }
        return o
    }

    /// `new JSONArray(text)`.
    static func parseArray(_ text: String) throws -> [JSONValue] {
        var t = Tokener(text)
        let v = try t.nextValue()
        guard case let .array(a) = v else { throw typeMismatch(v, "JSONArray") }
        return a
    }

    private static func javaClassName(_ v: JSONValue) -> String {
        switch v {
        case .string: return "java.lang.String"
        case let .int(i): return (Int64(Int32.min) ... Int64(Int32.max)).contains(i) ? "java.lang.Integer" : "java.lang.Long"
        case .double: return "java.lang.Double"
        case .bool: return "java.lang.Boolean"
        case .null: return "org.json.JSONObject$1"
        case .object: return "org.json.JSONObject"
        case .array: return "org.json.JSONArray"
        }
    }

    /// `JSON.typeMismatch(actual, requiredType)`.
    static func typeMismatch(_ v: JSONValue, _ required: String) -> ParseError {
        ParseError(message: "Value \(javaToString(v)) of type \(javaClassName(v)) cannot be converted to \(required)")
    }

    // MARK: - Coercions (`org.json.JSON`)

    /// `String.valueOf(value)` of a stored value (`JSON.toString` for non-null values).
    static func javaToString(_ v: JSONValue) -> String {
        switch v {
        case let .string(s): return s
        case let .int(i): return String(i)
        case let .double(d): return AppJavaNumber.doubleToString(d)
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        case .object, .array: return compact(v)
        }
    }

    /// `JSON.toString(value)` (nil when absent).
    static func toString(_ v: JSONValue?) -> String? { v.map(javaToString) }

    /// `JSON.toInteger(value)`.
    static func toInteger(_ v: JSONValue?) -> Int32? {
        switch v {
        case let .int(i)?: return Int32(truncatingIfNeeded: i)
        case let .double(d)?: return AppJavaNumber.d2i(d)
        case let .string(s)?: return AppJavaNumber.parseDouble(s).map(AppJavaNumber.d2i)
        default: return nil
        }
    }

    /// `JSON.toLong(value)`.
    static func toLong(_ v: JSONValue?) -> Int64? {
        switch v {
        case let .int(i)?: return i
        case let .double(d)?: return AppJavaNumber.d2l(d)
        case let .string(s)?: return AppJavaNumber.parseDouble(s).map(AppJavaNumber.d2l)
        default: return nil
        }
    }

    /// `JSON.toDouble(value)`.
    static func toDouble(_ v: JSONValue?) -> Double? {
        switch v {
        case let .int(i)?: return Double(i)
        case let .double(d)?: return d
        case let .string(s)?: return AppJavaNumber.parseDouble(s)
        default: return nil
        }
    }

    /// `JSON.toBoolean(value)` (`"true"`/`"false"` strings accepted, ignoring case).
    static func toBoolean(_ v: JSONValue?) -> Bool? {
        switch v {
        case let .bool(b)?: return b
        case let .string(s)?:
            if AppJvmText.equalsIgnoreCase(s, "true") { return true }
            if AppJvmText.equalsIgnoreCase(s, "false") { return false }
            return nil
        default: return nil
        }
    }

    // MARK: - Writers

    /// `JSONObject.numberToString` for a double.
    static func numberToString(_ d: Double) -> String? {
        guard d.isFinite else { return nil } // JSON.checkDouble throws
        if d == 0 && d.sign == .minus { return "-0" }
        let l = AppJavaNumber.d2l(d)
        if d == Double(l) { return String(l) }
        return AppJavaNumber.doubleToString(d)
    }

    /// `JSONStringer.string(value)` quoting (escapes `"` `\` `/`, control chars, U+2028/U+2029).
    static func quote(_ s: String, into out: inout String) {
        out.append("\"")
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x2F: out.append("\\/")
            case 0x09: out.append("\\t")
            case 0x08: out.append("\\b")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x0C: out.append("\\f")
            case 0x2028: out.append("\\u2028")
            case 0x2029: out.append("\\u2029")
            case 0 ... 0x1F: out.append(String(format: "\\u%04x", scalar.value))
            default: out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
    }

    /// `JSONObject.toString()` / `JSONArray.toString()` (compact). Non-finite doubles (which AOSP
    /// refuses to store) are written as `null`.
    static func compact(_ v: JSONValue) -> String {
        var out = ""
        write(v, indent: nil, depth: 0, into: &out)
        return out
    }

    /// `toString(indentSpaces)`: one key per line, `"key": value`, nested indentation, no trailing newline.
    static func pretty(_ v: JSONValue, indentSpaces: Int = 2) -> String {
        var out = ""
        write(v, indent: String(repeating: " ", count: indentSpaces), depth: 0, into: &out)
        return out
    }

    private static func newline(_ indent: String?, _ depth: Int, into out: inout String) {
        guard let indent else { return }
        out.append("\n")
        for _ in 0 ..< depth { out.append(indent) }
    }

    private static func write(_ v: JSONValue, indent: String?, depth: Int, into out: inout String) {
        switch v {
        case let .string(s): quote(s, into: &out)
        case let .int(i): out.append(String(i))
        case let .double(d): out.append(numberToString(d) ?? "null")
        case let .bool(b): out.append(b ? "true" : "false")
        case .null: out.append("null")
        case let .array(items):
            out.append("[")
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(",") }
                newline(indent, depth + 1, into: &out)
                write(item, indent: indent, depth: depth + 1, into: &out)
            }
            if !items.isEmpty { newline(indent, depth, into: &out) }
            out.append("]")
        case let .object(obj):
            out.append("{")
            for (i, e) in obj.entries.enumerated() {
                if i > 0 { out.append(",") }
                newline(indent, depth + 1, into: &out)
                quote(e.key, into: &out)
                out.append(indent == nil ? ":" : ": ")
                write(e.value, indent: indent, depth: depth + 1, into: &out)
            }
            if !obj.entries.isEmpty { newline(indent, depth, into: &out) }
            out.append("}")
        }
    }

    // MARK: - Tokener (port of AOSP org.json.JSONTokener)

    private struct Tokener {
        /// Max nesting of objects / arrays (settings packs, bikes_json and trip files nest ≤ 4 levels).
        /// Deeper input fails instead of recursing until a stack overflow (review SEC-4).
        static let maxDepth = 64

        let input: [UInt16]
        var pos = 0
        var depth = 0

        init(_ text: String) {
            var units = Array(text.utf16)
            if units.first == 0xFEFF { units.removeFirst() } // consume an optional BOM
            input = units
        }

        private var inputString: String { String(decoding: input, as: UTF16.self) }

        func syntaxError(_ message: String) -> ParseError {
            ParseError(message: message + " at character \(pos) of \(inputString)")
        }

        mutating func nextValue() throws -> JSONValue {
            let c = try nextClean()
            switch c {
            case -1: throw syntaxError("End of input")
            case 0x7B, 0x5B:                               // { [
                depth += 1
                defer { depth -= 1 }
                // Not `syntaxError`: that message embeds the whole input.
                guard depth <= Tokener.maxDepth else { throw ParseError(message: "Nesting too deep at character \(pos)") }
                return c == 0x7B ? try readObject() : try readArray()
            case 0x27, 0x22: return .string(try nextString(quote: UInt16(c))) // ' "
            default:
                pos -= 1
                return try readLiteral()
            }
        }

        /// Next non-whitespace, non-comment unit, or -1 at the end.
        mutating func nextClean() throws -> Int {
            while pos < input.count {
                let c = input[pos]
                pos += 1
                switch c {
                case 0x09, 0x20, 0x0A, 0x0D:
                    continue
                case 0x2F: // '/'
                    if pos == input.count { return Int(c) }
                    let peek = input[pos]
                    switch peek {
                    case 0x2A: // '*': skip a /* c-style comment */
                        pos += 1
                        var end = -1
                        var k = pos
                        while k + 1 < input.count {
                            if input[k] == 0x2A && input[k + 1] == 0x2F { end = k; break }
                            k += 1
                        }
                        if end == -1 { throw syntaxError("Unterminated comment") }
                        pos = end + 2
                        continue
                    case 0x2F: // '//' end-of-line comment
                        pos += 1
                        skipToEndOfLine()
                        continue
                    default:
                        return Int(c)
                    }
                case 0x23: // '#': end-of-line comment
                    skipToEndOfLine()
                    continue
                default:
                    return Int(c)
                }
            }
            return -1
        }

        mutating func skipToEndOfLine() {
            while pos < input.count {
                let c = input[pos]
                if c == 0x0D || c == 0x0A {
                    pos += 1
                    break
                }
                pos += 1
            }
        }

        mutating func nextString(quote: UInt16) throws -> String {
            var builder: [UInt16] = []
            var start = pos
            while pos < input.count {
                let c = input[pos]
                pos += 1
                if c == quote {
                    builder.append(contentsOf: input[start ..< pos - 1])
                    return String(decoding: builder, as: UTF16.self)
                }
                if c == 0x5C { // backslash
                    if pos == input.count { throw syntaxError("Unterminated escape sequence") }
                    builder.append(contentsOf: input[start ..< pos - 1])
                    builder.append(try readEscapeCharacter())
                    start = pos
                }
            }
            throw syntaxError("Unterminated string")
        }

        mutating func readEscapeCharacter() throws -> UInt16 {
            let escaped = input[pos]
            pos += 1
            switch escaped {
            case 0x75: // 'u'
                if pos + 4 > input.count { throw syntaxError("Unterminated escape sequence") }
                let hex = Array(input[pos ..< pos + 4])
                pos += 4
                guard let v = AppJavaNumber.parseLong(String(decoding: hex, as: UTF16.self), radix: 16),
                      v >= Int64(Int32.min), v <= Int64(Int32.max) else {
                    throw syntaxError("Invalid escape sequence: " + String(decoding: hex, as: UTF16.self))
                }
                return UInt16(truncatingIfNeeded: v)
            case 0x74: return 0x09 // t
            case 0x62: return 0x08 // b
            case 0x6E: return 0x0A // n
            case 0x72: return 0x0D // r
            case 0x66: return 0x0C // f
            default: return escaped // ' " \ and anything else
            }
        }

        mutating func readLiteral() throws -> JSONValue {
            let start = pos
            let excluded: Set<UInt16> = [0x7B, 0x7D, 0x5B, 0x5D, 0x2F, 0x5C, 0x3A, 0x2C, 0x3D, 0x3B, 0x23, 0x20, 0x09, 0x0C]
            while pos < input.count {
                let c = input[pos]
                if c == 0x0D || c == 0x0A || excluded.contains(c) { break }
                pos += 1
            }
            let literal = String(decoding: input[start ..< pos], as: UTF16.self)
            if literal.isEmpty { throw syntaxError("Expected literal value") }
            if AppJvmText.equalsIgnoreCase(literal, "null") { return .null }
            if AppJvmText.equalsIgnoreCase(literal, "true") { return .bool(true) }
            if AppJvmText.equalsIgnoreCase(literal, "false") { return .bool(false) }
            if !literal.unicodeScalars.contains(".") {
                var number = literal
                var base = 10
                if literal.hasPrefix("0x") || literal.hasPrefix("0X") {
                    number = String(literal.dropFirst(2))
                    base = 16
                } else if literal.hasPrefix("0") && literal.utf16.count > 1 {
                    number = String(literal.dropFirst(1))
                    base = 8
                }
                if let l = AppJavaNumber.parseLong(number, radix: base) {
                    return .int(l)
                }
            }
            if let d = AppJavaNumber.parseDouble(literal) {
                return .double(d) // NaN/Infinity are only rejected when put into an object
            }
            return .string(literal)
        }

        mutating func readArray() throws -> JSONValue {
            var result: [JSONValue] = []
            var hasTrailingSeparator = false
            while true {
                switch try nextClean() {
                case -1:
                    throw syntaxError("Unterminated array")
                case 0x5D: // ]
                    if hasTrailingSeparator { result.append(.null) }
                    return .array(result)
                case 0x2C, 0x3B: // , ;
                    result.append(.null) // a separator without a value first means "null"
                    hasTrailingSeparator = true
                    continue
                default:
                    pos -= 1
                }
                result.append(try nextValue())
                switch try nextClean() {
                case 0x5D: return .array(result)
                case 0x2C, 0x3B:
                    hasTrailingSeparator = true
                    continue
                default:
                    throw syntaxError("Unterminated array")
                }
            }
        }

        mutating func readObject() throws -> JSONValue {
            var result = OrderedJSONObject()
            let first = try nextClean()
            if first == 0x7D { return .object(result) } // }
            if first != -1 { pos -= 1 }
            while true {
                let name = try nextValue()
                guard case let .string(key) = name else {
                    throw syntaxError("Names must be strings, but \(javaToString(name)) is of type \(javaClassName(name))")
                }
                let separator = try nextClean()
                if separator != 0x3A && separator != 0x3D { // : =
                    throw syntaxError("Expected ':' after \(key)")
                }
                if pos < input.count && input[pos] == 0x3E { pos += 1 } // =>
                let value = try nextValue()
                if case let .double(d) = value, !d.isFinite { // JSONObject.put → JSON.checkDouble
                    throw ParseError(message: "Forbidden numeric value: \(AppJavaNumber.doubleToString(d))")
                }
                result[key] = value
                switch try nextClean() {
                case 0x7D: return .object(result)
                case 0x3B, 0x2C: continue
                default: throw syntaxError("Unterminated object")
                }
            }
        }
    }
}

// MARK: - Typed accessors (AOSP JSONObject / JSONArray `opt*`)

extension OrderedJSONObject {
    /// `has(name)` (true even when the value is JSON null).
    func orgHas(_ name: String) -> Bool { self[name] != nil }
    /// `optString(name, fallback)`.
    func orgOptString(_ name: String, _ fallback: String = "") -> String {
        AndroidOrgJSON.toString(self[name]) ?? fallback
    }
    /// `optInt(name, fallback)`.
    func orgOptInt(_ name: String, _ fallback: Int32 = 0) -> Int32 {
        AndroidOrgJSON.toInteger(self[name]) ?? fallback
    }
    /// `optLong(name, fallback)`.
    func orgOptLong(_ name: String, _ fallback: Int64 = 0) -> Int64 {
        AndroidOrgJSON.toLong(self[name]) ?? fallback
    }
    /// `optDouble(name, fallback)` (default NaN).
    func orgOptDouble(_ name: String, _ fallback: Double = .nan) -> Double {
        AndroidOrgJSON.toDouble(self[name]) ?? fallback
    }
    /// `optBoolean(name, fallback)`.
    func orgOptBoolean(_ name: String, _ fallback: Bool = false) -> Bool {
        AndroidOrgJSON.toBoolean(self[name]) ?? fallback
    }
    /// `optJSONObject(name)`.
    func orgOptObject(_ name: String) -> OrderedJSONObject? {
        if case let .object(o)? = self[name] { return o }
        return nil
    }
    /// `optJSONArray(name)`.
    func orgOptArray(_ name: String) -> [JSONValue]? {
        if case let .array(a)? = self[name] { return a }
        return nil
    }
}

extension Array where Element == JSONValue {
    /// `JSONArray.opt(index)`.
    func orgOpt(_ index: Int) -> JSONValue? { indices.contains(index) ? self[index] : nil }
    func orgOptDouble(_ index: Int, _ fallback: Double = .nan) -> Double { AndroidOrgJSON.toDouble(orgOpt(index)) ?? fallback }
    func orgOptLong(_ index: Int, _ fallback: Int64 = 0) -> Int64 { AndroidOrgJSON.toLong(orgOpt(index)) ?? fallback }
    func orgOptObject(_ index: Int) -> OrderedJSONObject? {
        if case let .object(o)? = orgOpt(index) { return o }
        return nil
    }
    func orgOptArray(_ index: Int) -> [JSONValue]? {
        if case let .array(a)? = orgOpt(index) { return a }
        return nil
    }
}
