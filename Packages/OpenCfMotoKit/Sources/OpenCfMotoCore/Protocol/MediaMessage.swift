// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (mediaLoop / sendReqBase / handleMediaReq)
//
// ReqBase framing of the media plane (:10921 media control, :10920 media data), little-endian
// (docs/spec/media-video.md §3):
//
//   offset  size  field
//   0       2     cmdType  (Int16; all known values < 256)
//   2       2     cmdLen   (UInt16, body length, header excluded)
//   4       4     token    (Int32; read and ignored — replies ALWAYS carry token 0)
//   8       n     body

import Foundation

/// Media-plane command types (ReqBase `cmdType`).
public enum MediaCmd {
    /// REQ_RV_CONFIG_CAPTURE: canvas request (w, h, fps, encoder, …, ext, encryptedHUID).
    public static let reqConfigCapture: Int16 = 16
    /// RLY_RV_CONFIG_CAPTURE: encoder, w & 0xFFF0, h & 0xFFF0, ext.
    public static let rlyConfigCapture: Int16 = 17
    /// Dash touch event (18-byte body). Never answered.
    public static let touch: Int16 = 32
    public static let reqGetVersion: Int16 = 48
    /// Body `i32 3, i32 1` (hard-coded in Android).
    public static let rlyGetVersion: Int16 = 49
    public static let reqHeartbeat: Int16 = 64
    public static let rlyHeartbeat: Int16 = 65
    /// REQ_CONFIGCAPTUREREXTEND (JSON body, content unknown).
    public static let reqConfigCaptureExtend: Int16 = 96
    /// Body `{"state":0}` verbatim.
    public static let rlyConfigCaptureExtend: Int16 = 97
    /// REQ_RV_DATA_START: resynchronize the encoder (gate, flush, IDR) BEFORE replying 113.
    public static let reqDataStart: Int16 = 112
    public static let rlyDataStart: Int16 = 113
    /// REQ_RV_DATA_NEXT: answered with ONE raw `[size i32 LE][Annex-B AU]` (no ReqBase header).
    public static let reqDataNext: Int16 = 114
    /// REQ_START_H264 (never observed on a dash).
    public static let reqStartH264: Int16 = 128
    public static let rlyStartH264: Int16 = 129

    /// Log name of a media command type.
    public static func name(of cmd: Int16) -> String {
        switch cmd {
        case reqConfigCapture: return "REQ_RV_CONFIG_CAPTURE"
        case rlyConfigCapture: return "RLY_RV_CONFIG_CAPTURE"
        case touch: return "TOUCH"
        case reqGetVersion: return "REQ_GET_VERSION"
        case rlyGetVersion: return "RLY_GET_VERSION"
        case reqHeartbeat: return "REQ_HEARTBEAT"
        case rlyHeartbeat: return "RLY_HEARTBEAT"
        case reqConfigCaptureExtend: return "REQ_CONFIGCAPTUREREXTEND"
        case rlyConfigCaptureExtend: return "RLY_CONFIGCAPTUREREXTEND"
        case reqDataStart: return "REQ_RV_DATA_START"
        case rlyDataStart: return "RLY_RV_DATA_START"
        case reqDataNext: return "REQ_RV_DATA_NEXT"
        case reqStartH264: return "REQ_START_H264"
        case rlyStartH264: return "RLY_START_H264"
        default: return "?"
        }
    }
}

/// One ReqBase message (header + body).
public struct MediaMessage: Sendable, Equatable, CustomStringConvertible {
    public static let headerSize = 8

    public var cmdType: Int16
    /// The request token (logged only). Replies are always built with token 0.
    public var token: Int32
    public var body: Data

    public init(cmdType: Int16, token: Int32 = 0, body: Data = Data()) {
        self.cmdType = cmdType
        self.token = token
        self.body = body
    }

    /// A phone → dash reply: token 0, `cmdLen = body.count`.
    public static func reply(_ cmdType: Int16, body: Data = Data()) -> MediaMessage {
        MediaMessage(cmdType: cmdType, token: 0, body: body)
    }

    /// Exact wire bytes. Bodies are limited to 65535 bytes by the 16-bit `cmdLen`.
    public func encoded() -> Data {
        precondition(body.count <= Int(UInt16.max), "ReqBase body too large (\(body.count) bytes)")
        var w = ByteWriter(capacity: MediaMessage.headerSize + body.count)
        w.i16le(cmdType)
        w.u16le(UInt16(body.count))
        w.i32le(token)
        w.append(body)
        return w.data
    }

    /// Parsed ReqBase header.
    public struct Header: Sendable, Equatable {
        public var cmdType: Int16
        public var cmdLen: Int
        public var token: Int32
    }

    /// Parses an 8-byte header (`cmdType` signed, `cmdLen` unsigned, Android semantics).
    public static func parseHeader(_ bytes: [UInt8]) throws -> Header {
        var r = ByteReader(bytes)
        let cmd = try r.i16le()
        let len = try r.u16le()
        let token = try r.i32le()
        return Header(cmdType: cmd, cmdLen: Int(len), token: token)
    }

    /// Decodes one complete message from the start of `data`; nil if more bytes are needed.
    public static func decode(_ data: Data) throws -> (message: MediaMessage, consumed: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { return nil }
        let h = try parseHeader(Array(bytes[0 ..< headerSize]))
        let end = headerSize + h.cmdLen
        guard bytes.count >= end else { return nil }
        return (MediaMessage(cmdType: h.cmdType, token: h.token, body: Data(bytes[headerSize ..< end])), end)
    }

    /// Reads one message: exactly 8 header bytes, then exactly `cmdLen` body bytes.
    /// Throws `TransportError.closed` on EOF ("media closed") and `MediaMessageError.shortBody` when
    /// the peer closes mid-body ("media body short"); either way the connection is finished.
    public static func read(from stream: any ByteStream) async throws -> MediaMessage {
        let header = try parseHeader([UInt8](try await stream.read(exactly: headerSize)))
        guard header.cmdLen > 0 else { return MediaMessage(cmdType: header.cmdType, token: header.token) }
        do {
            let body = try await stream.read(exactly: header.cmdLen)
            return MediaMessage(cmdType: header.cmdType, token: header.token, body: body)
        } catch TransportError.closed {
            throw MediaMessageError.shortBody(expected: header.cmdLen)
        }
    }

    public var description: String {
        "MediaMessage(\(cmdType) \(MediaCmd.name(of: cmdType)) len=\(body.count) token=\(token))"
    }
}

public enum MediaMessageError: Error, Equatable, CustomStringConvertible {
    case shortBody(expected: Int)
    public var description: String {
        switch self {
        case let .shortBody(n): return "media body short (expected \(n) bytes)"
        }
    }
}

/// Fixed media-plane replies (docs/spec/media-video.md §4, §14.2). Every reply has token 0.
public enum MediaReplies {
    /// 49: `03 00 00 00 01 00 00 00` (version 3, subVersion 1 — hard-coded in Android).
    public static var getVersion: MediaMessage {
        var w = ByteWriter(capacity: 8)
        w.i32le(3)
        w.i32le(1)
        return .reply(MediaCmd.rlyGetVersion, body: w.data)
    }

    /// 65, empty.
    public static var heartbeat: MediaMessage { .reply(MediaCmd.rlyHeartbeat) }

    /// 97: the 11 ASCII bytes `{"state":0}` verbatim.
    public static var configCaptureExtend: MediaMessage {
        .reply(MediaCmd.rlyConfigCaptureExtend, body: Data("{\"state\":0}".utf8))
    }

    /// 113, empty.
    public static var dataStart: MediaMessage { .reply(MediaCmd.rlyDataStart) }

    /// 129, empty.
    public static var startH264: MediaMessage { .reply(MediaCmd.rlyStartH264) }
}
