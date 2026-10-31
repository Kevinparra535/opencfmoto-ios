// SPDX-License-Identifier: AGPL-3.0-or-later
// Framing for the ReplayKit mirror relay (docs/spec/ios-platform-facts.md §f, design
// recommendation 14): the Broadcast Upload Extension encodes the screen with VideoToolbox and
// sends Annex-B access units to the host app — which owns the dash link — over an App-Group Unix
// domain stream socket. The host sends the negotiated canvas / encoder settings and keyframe
// requests back. Pure Swift (Linux-testable); the socket transport is
// OpenCfMotoApple/MirrorRelay.swift.
//
// Wire format, all integers little-endian:
//
//   message := [type: u8][payloadLength: u32 LE][payload: payloadLength bytes]
//
//   type 1 HELLO             client → server  [protocolVersion u8][agent UTF-8 …]
//   type 2 CONFIG            server → client  MirrorRelayConfig (36 bytes in v1, see below)
//   type 3 FRAME             client → server  [flags u8, bit0 = keyframe][sequence u64]
//                                             [presentationTime µs i64][Annex-B access unit …]
//   type 4 KEYFRAME_REQUEST  server → client  (empty payload)
//   type 5 STOP              both directions  [reason UTF-8 …]
//   type 6 LOG               client → server  [level u8][tagLength u8][tag UTF-8][message UTF-8 …]
//
// Unknown message types are skipped (forward compatibility); a payload longer than the
// decoder's limit is a protocol error (the connection should be dropped).

import Foundation

/// Message type byte of the mirror relay protocol.
public enum MirrorRelayMessageType: UInt8, Sendable, CaseIterable {
    case hello = 1
    case config = 2
    case frame = 3
    case keyframeRequest = 4
    case stop = 5
    case log = 6
}

/// Constants of the mirror relay protocol.
public enum MirrorRelayProtocol {
    /// Protocol version sent in HELLO and CONFIG.
    public static let version: UInt8 = 1
    /// `[type u8][length u32]`.
    public static let headerLength = 5
    /// Sanity cap for one payload (an IDR at 2.5 Mbit/s is ~20–100 KB).
    public static let defaultMaxPayloadLength = 8 << 20
    /// File name of the Unix socket inside the App Group container.
    /// (Same default as `AppGroup.defaultSocketName`, so both helpers resolve the same file.)
    public static let socketFileName = "ocm.sock"
    /// Fixed part of a FRAME payload before the access unit.
    public static let frameHeaderLength = 17
}

public enum MirrorRelayProtocolError: Error, Equatable, CustomStringConvertible {
    /// The announced payload is larger than the decoder accepts.
    case payloadTooLarge(type: UInt8, length: Int)
    /// A known message type with a payload too short for its fixed fields.
    case truncatedPayload(type: UInt8, expected: Int, actual: Int)

    public var description: String {
        switch self {
        case let .payloadTooLarge(t, l): return "mirror relay: payload of type \(t) too large (\(l) bytes)"
        case let .truncatedPayload(t, e, a): return "mirror relay: type \(t) payload truncated (need \(e), got \(a))"
        }
    }
}

/// What the host app tells the broadcast extension: the canvas negotiated with the dash (RLY 17),
/// the encoder settings and how to fit the phone screen into the canvas.
public struct MirrorRelayConfig: Sendable, Equatable {
    public var canvas: VideoCanvas
    public var parameters: EncoderParameters
    /// Mirror default is FIT (iOS cannot rotate other apps; FILL shows only a slice).
    public var fit: ScreenFit
    public var margins: ScreenMargins

    public init(canvas: VideoCanvas, parameters: EncoderParameters = .default, fit: ScreenFit = .fit,
                margins: ScreenMargins = .zero) {
        self.canvas = canvas
        self.parameters = parameters
        self.fit = fit
        self.margins = margins
    }

    /// Encoded length of a version-1 CONFIG payload.
    public static let encodedLength = 36

    /// Version-1 layout (LE):
    /// `[version u8][width u16][height u16][requestedWidth u16][requestedHeight u16]`
    /// `[requestedFps u16, 0 = unknown][bitrate u32][frameRate u16][keyframeInterval ms u32]`
    /// `[repeatLastFrameAfter ms u32][flags u8, bit0 = forceBaseline][fit u8: 0 FILL, 1 FIT, 2 STRETCH]`
    /// `[marginsCustomised u8][top u16][bottom u16][left u16][right u16]`
    public func encoded() -> Data {
        var w = ByteWriter(capacity: Self.encodedLength)
        w.u8(MirrorRelayProtocol.version)
        w.u16le(Self.u16(canvas.width))
        w.u16le(Self.u16(canvas.height))
        w.u16le(Self.u16(canvas.requestedWidth))
        w.u16le(Self.u16(canvas.requestedHeight))
        w.u16le(Self.u16(canvas.requestedFps ?? 0))
        w.u32le(Self.u32(parameters.bitrate))
        w.u16le(Self.u16(parameters.frameRate))
        w.u32le(Self.millis(parameters.keyframeIntervalSeconds))
        w.u32le(Self.millis(parameters.repeatLastFrameAfter))
        w.u8(parameters.forceBaseline ? 1 : 0)
        w.u8(Self.fitCode(fit))
        w.u8(margins.customised ? 1 : 0)
        w.u16le(Self.u16(margins.top))
        w.u16le(Self.u16(margins.bottom))
        w.u16le(Self.u16(margins.left))
        w.u16le(Self.u16(margins.right))
        return w.data
    }

    /// Decodes a CONFIG payload. Longer payloads (newer versions) are accepted; their extra
    /// trailing fields are ignored.
    public init(decoding payload: Data) throws {
        guard payload.count >= Self.encodedLength else {
            throw MirrorRelayProtocolError.truncatedPayload(type: MirrorRelayMessageType.config.rawValue,
                                                            expected: Self.encodedLength, actual: payload.count)
        }
        var r = ByteReader(payload)
        _ = try r.u8() // version (fields of v1 are a prefix of every later version)
        let width = Int(try r.u16le())
        let height = Int(try r.u16le())
        let reqW = Int(try r.u16le())
        let reqH = Int(try r.u16le())
        let reqFps = Int(try r.u16le())
        let bitrate = Int(try r.u32le())
        let fps = Int(try r.u16le())
        let keyMs = try r.u32le()
        let repeatMs = try r.u32le()
        let flags = try r.u8()
        let fitCode = try r.u8()
        let customised = try r.u8() != 0
        let top = Int(try r.u16le())
        let bottom = Int(try r.u16le())
        let left = Int(try r.u16le())
        let right = Int(try r.u16le())
        canvas = VideoCanvas(width: width, height: height, requestedWidth: reqW, requestedHeight: reqH,
                             requestedFps: reqFps == 0 ? nil : reqFps)
        parameters = EncoderParameters(bitrate: bitrate, frameRate: fps,
                                       keyframeIntervalSeconds: Double(keyMs) / 1000,
                                       forceBaseline: (flags & 1) != 0,
                                       repeatLastFrameAfter: Double(repeatMs) / 1000)
        fit = Self.fit(code: fitCode)
        margins = ScreenMargins(customised: customised, top: top, bottom: bottom, left: left, right: right)
    }

    static func fitCode(_ f: ScreenFit) -> UInt8 {
        switch f {
        case .fill: return 0
        case .fit: return 1
        case .stretch: return 2
        }
    }

    /// Unknown codes fall back to FIT (the safe mirror default).
    static func fit(code: UInt8) -> ScreenFit {
        switch code {
        case 0: return .fill
        case 2: return .stretch
        default: return .fit
        }
    }

    private static func u16(_ v: Int) -> UInt16 { UInt16(clamping: max(0, v)) }
    private static func u32(_ v: Int) -> UInt32 { UInt32(clamping: max(0, v)) }
    private static func millis(_ seconds: Double) -> UInt32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt32(clamping: Int64((seconds * 1000).rounded()))
    }
}

/// One message of the mirror relay protocol.
public enum MirrorRelayMessage: Sendable, Equatable {
    /// First message of the extension after connecting.
    case hello(version: UInt8, agent: String)
    /// Canvas / encoder / fit settings (host → extension), sent on connect and on every change.
    case config(MirrorRelayConfig)
    /// One encoded access unit (extension → host). Keyframes carry SPS + PPS + IDR.
    case frame(EncodedFrame)
    /// The host needs an IDR (REQ 112 resync, queue overflow, new connection).
    case keyframeRequest
    /// Orderly shutdown of the sender (broadcast finished / host stopping).
    case stop(reason: String)
    /// A log line from the extension, re-logged by the host (the extension has no log UI).
    case log(level: LogLevel, tag: String, message: String)

    public var type: MirrorRelayMessageType {
        switch self {
        case .hello: return .hello
        case .config: return .config
        case .frame: return .frame
        case .keyframeRequest: return .keyframeRequest
        case .stop: return .stop
        case .log: return .log
        }
    }

    /// `[type u8][length u32 LE][payload]`.
    public func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case let .hello(version, agent):
            w.u8(version)
            w.append(Array(agent.utf8))
        case let .config(cfg):
            w.append(cfg.encoded())
        case let .frame(f):
            w = ByteWriter(capacity: MirrorRelayProtocol.frameHeaderLength + f.accessUnit.count)
            w.u8(f.isKeyframe ? 1 : 0)
            w.u64le(f.sequence)
            w.i64le(Self.micros(f.presentationTime))
            w.append(f.accessUnit)
        case .keyframeRequest:
            break
        case let .stop(reason):
            w.append(Array(reason.utf8))
        case let .log(level, tag, message):
            let tagBytes = Self.truncatedUTF8(tag, maxBytes: 255)
            w.u8(UInt8(clamping: level.rawValue))
            w.u8(UInt8(tagBytes.count))
            w.append(tagBytes)
            w.append(Array(message.utf8))
        }
        return Self.envelope(type: type.rawValue, payload: w.bytes)
    }

    /// Wraps a payload into `[type][length][payload]`.
    public static func envelope(type: UInt8, payload: [UInt8]) -> Data {
        var w = ByteWriter(capacity: MirrorRelayProtocol.headerLength + payload.count)
        w.u8(type)
        w.u32le(UInt32(truncatingIfNeeded: payload.count))
        w.append(payload)
        return w.data
    }

    /// Decodes one payload. Returns nil for an unknown message type (the caller skips it).
    public static func decode(type rawType: UInt8, payload: Data) throws -> MirrorRelayMessage? {
        guard let type = MirrorRelayMessageType(rawValue: rawType) else { return nil }
        switch type {
        case .hello:
            guard let version = payload.first else {
                throw MirrorRelayProtocolError.truncatedPayload(type: rawType, expected: 1, actual: 0)
            }
            return .hello(version: version, agent: String(decoding: payload.dropFirst(), as: UTF8.self))
        case .config:
            return .config(try MirrorRelayConfig(decoding: payload))
        case .frame:
            guard payload.count >= MirrorRelayProtocol.frameHeaderLength else {
                throw MirrorRelayProtocolError.truncatedPayload(type: rawType, expected: MirrorRelayProtocol.frameHeaderLength,
                                                                actual: payload.count)
            }
            var r = ByteReader(payload)
            let flags = try r.u8()
            let seq = try r.u64le()
            let pts = try r.i64le()
            let au = r.rest()
            return .frame(EncodedFrame(accessUnit: au, isKeyframe: (flags & 1) != 0,
                                       presentationTime: Double(pts) / 1_000_000, sequence: seq))
        case .keyframeRequest:
            return .keyframeRequest
        case .stop:
            return .stop(reason: String(decoding: payload, as: UTF8.self))
        case .log:
            guard payload.count >= 2 else {
                throw MirrorRelayProtocolError.truncatedPayload(type: rawType, expected: 2, actual: payload.count)
            }
            var r = ByteReader(payload)
            let levelRaw = try r.u8()
            let tagLen = Int(try r.u8())
            guard r.remaining >= tagLen else {
                throw MirrorRelayProtocolError.truncatedPayload(type: rawType, expected: 2 + tagLen, actual: payload.count)
            }
            let tag = String(decoding: try r.bytes(tagLen), as: UTF8.self)
            let message = String(decoding: r.rest(), as: UTF8.self)
            return .log(level: LogLevel(rawValue: Int(levelRaw)) ?? .info, tag: tag, message: message)
        }
    }

    static func micros(_ seconds: TimeInterval) -> Int64 {
        guard seconds.isFinite else { return 0 }
        let us = (seconds * 1_000_000).rounded()
        if us >= Double(Int64.max) { return Int64.max }
        if us <= Double(Int64.min) { return Int64.min }
        return Int64(us)
    }

    /// UTF-8 bytes of `s`, cut at a character boundary so that at most `maxBytes` remain.
    static func truncatedUTF8(_ s: String, maxBytes: Int) -> [UInt8] {
        var out: [UInt8] = []
        for ch in s {
            let b = Array(String(ch).utf8)
            if out.count + b.count > maxBytes { break }
            out.append(contentsOf: b)
        }
        return out
    }
}

/// Incremental decoder for a byte stream of relay messages (handles partial reads and several
/// messages per read). Not thread-safe: feed it from the connection's reader thread.
public struct MirrorRelayDecoder: Sendable {
    public let maxPayloadLength: Int
    private var buffer: [UInt8] = []
    private var readIndex = 0
    /// Messages of unknown type that were skipped.
    public private(set) var skippedUnknownMessages = 0

    public init(maxPayloadLength: Int = MirrorRelayProtocol.defaultMaxPayloadLength) {
        self.maxPayloadLength = max(0, maxPayloadLength)
    }

    /// Bytes received but not yet consumed by `nextMessage()`.
    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete message, or nil if more bytes are needed. Throws on a protocol error;
    /// the stream is then unusable and the connection should be closed.
    public mutating func nextMessage() throws -> MirrorRelayMessage? {
        while bufferedByteCount >= MirrorRelayProtocol.headerLength {
            let type = buffer[readIndex]
            let length = Int(buffer[readIndex + 1]) | (Int(buffer[readIndex + 2]) << 8)
                | (Int(buffer[readIndex + 3]) << 16) | (Int(buffer[readIndex + 4]) << 24)
            guard length <= maxPayloadLength else {
                throw MirrorRelayProtocolError.payloadTooLarge(type: type, length: length)
            }
            guard bufferedByteCount >= MirrorRelayProtocol.headerLength + length else { return nil }
            let start = readIndex + MirrorRelayProtocol.headerLength
            let payload = Data(buffer[start ..< start + length])
            readIndex = start + length
            compactIfNeeded()
            if let message = try MirrorRelayMessage.decode(type: type, payload: payload) {
                return message
            }
            skippedUnknownMessages += 1
        }
        return nil
    }

    /// Appends `data` and returns every message that is now complete.
    public mutating func decode(_ data: Data) throws -> [MirrorRelayMessage] {
        append(data)
        var out: [MirrorRelayMessage] = []
        while let m = try nextMessage() { out.append(m) }
        return out
    }

    private mutating func compactIfNeeded() {
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.count <= 1 << 20)
            readIndex = 0
        } else if readIndex >= 64 * 1024, readIndex * 2 >= buffer.count {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }
}
