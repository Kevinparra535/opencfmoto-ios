// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Read-only access to `JSONSerialization` output with Android org.json `opt*` / `get*` semantics
// (numbers given as strings are accepted, missing keys fall back), so service responses parse the
// same way as on Android. JSON `null` counts as missing.

import Foundation

struct NavJSON {
    let value: Any?

    init(_ value: Any?) { self.value = value }

    /// Max nesting of service / backup JSON (real responses nest < 10 levels).
    static let maxDepth = 64

    /// Parses `data`; throws `NavServiceError.invalidJSON` for malformed input, and for input nested
    /// deeper than `maxDepth` before `JSONSerialization` recurses into it (review SEC-4).
    static func parse(_ data: Data) throws -> NavJSON {
        guard !exceedsDepth(data, limit: maxDepth) else { throw NavServiceError.invalidJSON("Nesting too deep") }
        do {
            return NavJSON(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        } catch {
            throw NavServiceError.invalidJSON("Not valid JSON")
        }
    }

    /// Linear scan: true when `[` / `{` nest deeper than `limit` outside string literals.
    static func exceedsDepth(_ data: Data, limit: Int) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var depth = 0
            var inString = false
            var escaped = false
            for b in raw {
                if inString {
                    if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                    continue
                }
                switch b {
                case 0x22: inString = true
                case 0x5B, 0x7B:
                    depth += 1
                    if depth > limit { return true }
                case 0x5D, 0x7D: depth -= 1
                default: break
                }
            }
            return false
        }
    }

    var isNull: Bool { value == nil || value is NSNull }

    var object: [String: Any]? { value as? [String: Any] }
    var array: [Any]? { value as? [Any] }

    subscript(_ key: String) -> NavJSON {
        guard let o = value as? [String: Any], let v = o[key], !(v is NSNull) else { return NavJSON(nil) }
        return NavJSON(v)
    }

    subscript(_ index: Int) -> NavJSON {
        guard let a = value as? [Any], index >= 0, index < a.count, !(a[index] is NSNull) else { return NavJSON(nil) }
        return NavJSON(a[index])
    }

    func has(_ key: String) -> Bool { !self[key].isNull }

    /// Array elements (empty when not an array).
    var elements: [NavJSON] { (value as? [Any])?.map { NavJSON($0 is NSNull ? nil : $0) } ?? [] }

    var count: Int { (value as? [Any])?.count ?? 0 }

    // MARK: Scalars

    /// org.json `optString`: strings as-is, numbers / bools as text, else `fallback`.
    func string(_ fallback: String = "") -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber where Self.isBool(n): return n.boolValue ? "true" : "false"
        case let n as NSNumber:
            let d = n.doubleValue
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return NavNumberFormat.javaString(d)
        default: return fallback
        }
    }

    /// org.json `optDouble`: numbers or numeric strings, else `fallback`.
    func double(_ fallback: Double) -> Double { doubleOrNil ?? fallback }

    /// org.json `getDouble` without the throw: nil when missing / not numeric.
    var doubleOrNil: Double? {
        switch value {
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        case _ where Self.isBool(value): return nil
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    /// org.json `optInt`: numbers (truncated) or numeric strings, else `fallback`.
    func int(_ fallback: Int) -> Int { intOrNil ?? fallback }

    var intOrNil: Int? {
        guard let d = doubleOrNil, d.isFinite else { return nil }
        return NavNumberFormat.truncateToInt(d)
    }

    /// org.json `optBoolean`: booleans or "true"/"false" strings, else `fallback`.
    func bool(_ fallback: Bool) -> Bool {
        if Self.isBool(value), let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            switch s.lowercased() {
            case "true": return true
            case "false": return false
            default: return fallback
            }
        }
        return fallback
    }

    /// Distinguishes JSON booleans from numbers. `JSONSerialization` yields `__NSCFBoolean`
    /// (objCType "c") for true/false on both Darwin and Linux, while integers 0/1 also bridge to
    /// `Bool`, so `is Bool` cannot be used.
    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber, !(v is String) else { return false }
        #if canImport(Darwin)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        return String(cString: n.objCType) == "c"
        #endif
    }
}
