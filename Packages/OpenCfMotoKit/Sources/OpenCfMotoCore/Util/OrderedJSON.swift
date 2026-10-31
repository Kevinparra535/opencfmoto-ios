// SPDX-License-Identifier: AGPL-3.0-or-later
// Deterministic JSON writer that preserves key insertion order and mimics Android's org.json
// `JSONObject.toString()` output byte-for-byte (no whitespace, "/" escaped as "\/", control
// characters as \b \t \n \f \r or \u00XX, numbers without trailing ".0" for integral values).
// Using the same bytes as the Android app removes one variable when comparing against the
// verified behaviour of the dashes. Parsing of incoming JSON uses JSONSerialization.

import Foundation

public indirect enum JSONValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case object(OrderedJSONObject)
    case array([JSONValue])
}

public struct OrderedJSONObject: Equatable, Sendable {
    public private(set) var entries: [(key: String, value: JSONValue)] = []

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public static func == (a: OrderedJSONObject, b: OrderedJSONObject) -> Bool {
        a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    /// Setting an existing key replaces its value in place (org.json `put` keeps the original slot
    /// in a LinkedHashMap); setting nil removes it.
    public subscript(key: String) -> JSONValue? {
        get { entries.first(where: { $0.key == key })?.value }
        set {
            if let idx = entries.firstIndex(where: { $0.key == key }) {
                if let v = newValue { entries[idx] = (key, v) } else { entries.remove(at: idx) }
            } else if let v = newValue {
                entries.append((key, v))
            }
        }
    }

    public mutating func put(_ key: String, _ value: String) { self[key] = .string(value) }
    public mutating func put(_ key: String, _ value: Int) { self[key] = .int(Int64(value)) }
    public mutating func put(_ key: String, _ value: Int64) { self[key] = .int(value) }
    public mutating func put(_ key: String, _ value: Bool) { self[key] = .bool(value) }
    public mutating func put(_ key: String, _ value: Double) { self[key] = .double(value) }
    public mutating func put(_ key: String, _ value: OrderedJSONObject) { self[key] = .object(value) }
    public mutating func put(_ key: String, _ value: JSONValue) { self[key] = value }

    public var jsonString: String { JSONValue.object(self).jsonString }
    public var jsonData: Data { Data(jsonString.utf8) }
}

public extension JSONValue {
    var jsonString: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case let .string(s): JSONValue.quote(s, into: &out)
        case let .int(i): out += String(i)
        case let .double(d): out += JSONValue.formatDouble(d)
        case let .bool(b): out += b ? "true" : "false"
        case .null: out += "null"
        case let .array(items):
            out += "["
            for (i, v) in items.enumerated() {
                if i > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case let .object(obj):
            out += "{"
            for (i, e) in obj.entries.enumerated() {
                if i > 0 { out += "," }
                JSONValue.quote(e.key, into: &out)
                out += ":"
                e.value.write(into: &out)
            }
            out += "}"
        }
    }

    /// org.json `JSONObject.quote` semantics.
    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "/":
                // Android's libcore org.json (JSONStringer.string) escapes every "/".
                // Android behaviour is what the dashes were verified against.
                out += "\\/"
            case "\u{08}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\r": out += "\\r"
            default:
                if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.append(ch)
                }
            }
        }
        out += "\""
    }

    /// Android org.json number formatting: integral doubles print without ".0".
    static func formatDouble(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }
}

/// Helpers for reading loosely-typed JSON produced by `JSONSerialization`.
public enum LooseJSON {
    public static func object(from data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        else { return nil }
        return obj
    }

    public static func object(from string: String) -> [String: Any]? { object(from: Data(string.utf8)) }

    public static func string(_ dict: [String: Any], _ key: String) -> String? {
        switch dict[key] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    public static func int(_ dict: [String: Any], _ key: String) -> Int? {
        switch dict[key] {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        case let b as Bool: return b ? 1 : 0
        default: return nil
        }
    }

    public static func double(_ dict: [String: Any], _ key: String) -> Double? {
        switch dict[key] {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public static func bool(_ dict: [String: Any], _ key: String) -> Bool? {
        switch dict[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }
}
