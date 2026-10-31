// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) PxcFrame.kt
//
// CmdBaseHead: the 16-byte little-endian frame used on the PXC control socket (:10922) and on the
// :10930 probe connection (docs/spec/control-plane.md §2).
//
//   offset  size  field
//   0       4     cmd        (UInt32 LE)
//   4       4     totalLen   (= 16 + payload.count)
//   8       4     magic      (= cmd XOR totalLen)
//   12      4     reserved   (written as 0, ignored on read)
//   16      n     payload    (JSON UTF-8, binary or empty)

import Foundation

/// One PXC control frame (CmdBaseHead header + payload).
public struct PxcFrame: Sendable, Equatable, CustomStringConvertible {
    /// Size of the CmdBaseHead header.
    public static let headerSize = 16
    /// Largest payload accepted from the dash. Android has no cap (a hostile `totalLen` makes it
    /// allocate ~2 GiB); real control payloads are well under 2 KB (control-plane.md §18.2).
    public static let maxPayloadSize = 1 << 20

    public var cmd: UInt32
    public var payload: Data

    public init(cmd: UInt32, payload: Data = Data()) {
        self.cmd = cmd
        self.payload = payload
    }

    /// Frame with a UTF-8 text payload (JSON bodies).
    public init(cmd: UInt32, text: String) {
        self.init(cmd: cmd, payload: Data(text.utf8))
    }

    /// `totalLen` header field (16 + payload length).
    public var totalLength: UInt32 { UInt32(truncatingIfNeeded: PxcFrame.headerSize + payload.count) }
    /// `magic` header field (`cmd XOR totalLen`).
    public var magic: UInt32 { cmd ^ totalLength }

    /// Exact wire bytes: header + payload in one buffer (write it with ONE `ByteStream.write` so a
    /// heartbeat can never interleave with a reply).
    public func encoded() -> Data {
        var w = ByteWriter(capacity: PxcFrame.headerSize + payload.count)
        w.u32le(cmd)
        w.u32le(totalLength)
        w.u32le(magic)
        w.u32le(0)
        w.append(payload)
        return w.data
    }

    /// Payload decoded as UTF-8; malformed sequences become U+FFFD (Android `String(bytes, UTF_8)`).
    public var payloadText: String { String(decoding: payload, as: UTF8.self) }

    /// "0x10010" style command id (lower-case hex, Android `cmdHex()`).
    public var cmdHex: String { PxcCmd.hex(cmd) }

    public var description: String {
        "PxcFrame(\(cmdHex) \(PxcCmd.name(of: cmd)) len=\(payload.count))"
    }

    // MARK: - Header parsing

    /// Parsed CmdBaseHead header.
    public struct Header: Sendable, Equatable {
        public var cmd: UInt32
        public var totalLength: UInt32
        public var magic: UInt32
        /// `max(Int32(totalLen) - 16, 0)` — a `totalLen < 16` with a matching magic is accepted as an
        /// empty frame, exactly like Android.
        public var payloadLength: Int
        /// `totalLen` was below 16 (accepted as empty, but worth a log line).
        public var isUndersized: Bool { Int32(bitPattern: totalLength) < Int32(PxcFrame.headerSize) }
    }

    /// Validates a 16-byte header (magic check on the raw 32-bit values, 1 MiB payload cap).
    public static func parseHeader(_ bytes: [UInt8], maxPayloadSize: Int = PxcFrame.maxPayloadSize) throws -> Header {
        guard bytes.count >= headerSize else {
            throw PxcFrameError.truncated(needed: headerSize, available: bytes.count)
        }
        let r = ByteReader(bytes)
        let cmd = UInt32(bitPattern: r.peekI32le(at: 0)!)
        let total = UInt32(bitPattern: r.peekI32le(at: 4)!)
        let magic = UInt32(bitPattern: r.peekI32le(at: 8)!)
        guard cmd ^ total == magic else {
            throw PxcFrameError.badMagic(cmd: cmd, totalLength: total, magic: magic)
        }
        let payloadLength = max(Int(Int32(bitPattern: total)) - headerSize, 0)
        guard payloadLength <= maxPayloadSize else {
            throw PxcFrameError.payloadTooLarge(payloadLength)
        }
        return Header(cmd: cmd, totalLength: total, magic: magic, payloadLength: payloadLength)
    }

    /// Decodes exactly one complete frame from the start of `data`.
    /// - Returns: the frame and the number of bytes it occupied, or nil if more bytes are needed.
    /// - Throws: `PxcFrameError` on bad magic or an oversized payload.
    public static func decode(_ data: Data, maxPayloadSize: Int = PxcFrame.maxPayloadSize) throws -> (frame: PxcFrame, consumed: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { return nil }
        let header = try parseHeader(Array(bytes[0 ..< headerSize]), maxPayloadSize: maxPayloadSize)
        let end = headerSize + header.payloadLength
        guard bytes.count >= end else { return nil }
        return (PxcFrame(cmd: header.cmd, payload: Data(bytes[headerSize ..< end])), end)
    }

    // MARK: - Stream reading

    /// Reads one frame from a byte stream (Android `PxcFrame.read`).
    /// - Throws: `TransportError.closed` on EOF before/at the header (the "bike closed" case),
    ///   `PxcFrameError.badMagic` / `.payloadTooLarge` for a corrupt header, and
    ///   `PxcFrameError.shortPayload` if the peer closes mid-payload. On any `PxcFrameError` the caller
    ///   must close that connection (and only that one).
    public static func read(from stream: any ByteStream, maxPayloadSize: Int = PxcFrame.maxPayloadSize) async throws -> PxcFrame {
        let headerBytes = try await stream.read(exactly: headerSize)
        let header = try parseHeader([UInt8](headerBytes), maxPayloadSize: maxPayloadSize)
        guard header.payloadLength > 0 else { return PxcFrame(cmd: header.cmd) }
        do {
            let payload = try await stream.read(exactly: header.payloadLength)
            return PxcFrame(cmd: header.cmd, payload: payload)
        } catch TransportError.closed {
            throw PxcFrameError.shortPayload(expected: header.payloadLength)
        }
    }
}

/// Frame-level protocol errors (the connection that produced them must be closed).
public enum PxcFrameError: Error, Equatable, CustomStringConvertible {
    /// `cmd XOR totalLen != magic`.
    case badMagic(cmd: UInt32, totalLength: UInt32, magic: UInt32)
    /// Payload length above `PxcFrame.maxPayloadSize`.
    case payloadTooLarge(Int)
    /// The peer closed before the announced payload arrived.
    case shortPayload(expected: Int)
    /// A buffer handed to a one-shot parser is shorter than a header.
    case truncated(needed: Int, available: Int)

    public var description: String {
        switch self {
        case let .badMagic(cmd, len, magic):
            // Same wording as Android (signed decimal values).
            return "bad magic: cmd=\(Int32(bitPattern: cmd)) len=\(Int32(bitPattern: len)) magic=\(Int32(bitPattern: magic))"
        case let .payloadTooLarge(n):
            return "payload too large: \(n) bytes (cap \(PxcFrame.maxPayloadSize))"
        case let .shortPayload(n):
            return "short payload, expected=\(n)"
        case let .truncated(needed, available):
            return "truncated header: needed \(needed), available \(available)"
        }
    }
}

/// Incremental CmdBaseHead decoder for transports that deliver arbitrary chunks
/// (e.g. `NWConnection.receive`). Feed bytes with `append`, then drain frames with `next()`.
/// After a thrown error the decoder is poisoned: close the connection.
public struct PxcFrameDecoder {
    public let maxPayloadSize: Int
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var pendingHeader: PxcFrame.Header?
    private var failure: PxcFrameError?

    public init(maxPayloadSize: Int = PxcFrame.maxPayloadSize) {
        self.maxPayloadSize = maxPayloadSize
    }

    /// Bytes received but not yet returned as part of a frame.
    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    public mutating func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
    }

    /// Next complete frame, or nil if more bytes are needed.
    public mutating func next() throws -> PxcFrame? {
        if let failure { throw failure }
        if pendingHeader == nil {
            guard bufferedByteCount >= PxcFrame.headerSize else { return nil }
            do {
                pendingHeader = try PxcFrame.parseHeader(Array(buffer[readIndex ..< readIndex + PxcFrame.headerSize]),
                                                         maxPayloadSize: maxPayloadSize)
            } catch let e as PxcFrameError {
                failure = e
                throw e
            }
            readIndex += PxcFrame.headerSize
        }
        guard let header = pendingHeader, bufferedByteCount >= header.payloadLength else { return nil }
        let payload = Data(buffer[readIndex ..< readIndex + header.payloadLength])
        readIndex += header.payloadLength
        pendingHeader = nil
        compactIfNeeded()
        return PxcFrame(cmd: header.cmd, payload: payload)
    }

    /// Drains every complete frame currently buffered.
    public mutating func drain() throws -> [PxcFrame] {
        var out: [PxcFrame] = []
        while let f = try next() { out.append(f) }
        return out
    }

    private mutating func compactIfNeeded() {
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 4096, readIndex * 2 > buffer.count {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }
}
