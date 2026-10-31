// SPDX-License-Identifier: AGPL-3.0-or-later
// Little-endian byte reading/writing helpers shared by every wire-format codec in the core.
// All PXC / EasyConnect structures are little-endian (see docs/spec/control-plane.md, media-video.md).

import Foundation

public enum ByteIOError: Error, Equatable, CustomStringConvertible {
    case outOfBounds(needed: Int, available: Int)

    public var description: String {
        switch self {
        case let .outOfBounds(needed, available):
            return "ByteReader out of bounds: needed \(needed) byte(s), \(available) available"
        }
    }
}

/// Appends little-endian scalars and raw bytes to a growable buffer.
public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    public var data: Data { Data(bytes) }
    public var count: Int { bytes.count }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func i8(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
    public mutating func u16le(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    public mutating func i16le(_ v: Int16) { u16le(UInt16(bitPattern: v)) }
    public mutating func u32le(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
    }
    public mutating func i32le(_ v: Int32) { u32le(UInt32(bitPattern: v)) }
    public mutating func u64le(_ v: UInt64) {
        u32le(UInt32(truncatingIfNeeded: v))
        u32le(UInt32(truncatingIfNeeded: v >> 32))
    }
    public mutating func i64le(_ v: Int64) { u64le(UInt64(bitPattern: v)) }
    public mutating func append(_ d: Data) { bytes.append(contentsOf: d) }
    public mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    public mutating func zeros(_ n: Int) { if n > 0 { bytes.append(contentsOf: repeatElement(0, count: n)) } }
}

/// Reads little-endian scalars from an immutable byte buffer with bounds checking.
public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ data: Data) { self.bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, n <= remaining else { throw ByteIOError.outOfBounds(needed: n, available: remaining) }
        defer { offset += n }
        return bytes[offset ..< offset + n]
    }

    public mutating func u8() throws -> UInt8 { try take(1).first! }
    public mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    public mutating func u16le() throws -> UInt16 {
        let s = try take(2); let b = s.startIndex
        return UInt16(s[b]) | (UInt16(s[b + 1]) << 8)
    }
    public mutating func i16le() throws -> Int16 { Int16(bitPattern: try u16le()) }
    public mutating func u32le() throws -> UInt32 {
        let s = try take(4); let b = s.startIndex
        return UInt32(s[b]) | (UInt32(s[b + 1]) << 8) | (UInt32(s[b + 2]) << 16) | (UInt32(s[b + 3]) << 24)
    }
    public mutating func i32le() throws -> Int32 { Int32(bitPattern: try u32le()) }
    public mutating func u64le() throws -> UInt64 {
        let lo = UInt64(try u32le()); let hi = UInt64(try u32le())
        return lo | (hi << 32)
    }
    public mutating func i64le() throws -> Int64 { Int64(bitPattern: try u64le()) }
    public mutating func bytes(_ n: Int) throws -> [UInt8] { Array(try take(n)) }
    public mutating func data(_ n: Int) throws -> Data { Data(try take(n)) }
    public mutating func skip(_ n: Int) throws { _ = try take(n) }
    /// Everything that has not been read yet (consumes it).
    public mutating func rest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
    /// Reads a little-endian Int32 at an absolute offset without moving the cursor.
    public func peekI32le(at absolute: Int) -> Int32? {
        guard absolute >= 0, absolute + 4 <= bytes.count else { return nil }
        let v = UInt32(bytes[absolute]) | (UInt32(bytes[absolute + 1]) << 8)
            | (UInt32(bytes[absolute + 2]) << 16) | (UInt32(bytes[absolute + 3]) << 24)
        return Int32(bitPattern: v)
    }
}

public extension Data {
    /// Lower-case hex without separators, e.g. "0a1bff".
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Hex dump with a space between bytes, truncated after `limit` bytes (for logs).
    func hexDump(limit: Int = 64) -> String {
        let shown = prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return count > limit ? shown + " …(+\(count - limit)b)" : shown
    }

    /// Parses hex (whitespace, ':' and '-' separators ignored). Returns nil on odd length / bad digit.
    init?(hexString: String) {
        let cleaned = hexString.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard cleaned.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx ..< next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self.init(out)
    }
}
