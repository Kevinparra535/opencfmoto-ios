// SPDX-License-Identifier: AGPL-3.0-or-later
// A scripted dash on the in-memory network: answers the :10930 probe and lets tests connect back to
// the phone's listeners and drive the CFDL16 / CFDL26 sequences byte by byte.

import Foundation
import XCTest
@testable import OpenCfMotoCore

final class LinkFakeDash: @unchecked Sendable {
    enum ProbeBehavior: Sendable {
        /// Reply `{"status":true}`.
        case accept
        /// Reply `{"status":false}`.
        case reject
        /// Close without replying.
        case closeWithoutReply
        /// Reply with a corrupt header.
        case badMagic
    }

    let network: LinkMemoryNetwork
    let host: String
    let probePort: UInt16
    let probeBehavior = Locked<ProbeBehavior>(.accept)
    /// Raw bytes of every probe frame received.
    let probesReceived = Locked<[Data]>([])
    /// Number of probes answered with acceptance.
    let acceptedCount = Locked(0)

    /// §2.3 probe acceptance bytes.
    static let acceptBytes = linkHex("11 00 00 70 1f 00 00 00 0e 00 00 70 00 00 00 00 7b 22 73 74 61 74 75 73 22 3a 74 72 75 65 7d")
    /// session-network.md §5.3 rejection bytes.
    static let rejectBytes = linkHex("11 00 00 70 20 00 00 00 31 00 00 70 00 00 00 00 7b 22 73 74 61 74 75 73 22 3a 66 61 6c 73 65 7d")

    init(network: LinkMemoryNetwork, host: String = "192.168.0.1", probePort: UInt16 = 10930) {
        self.network = network
        self.host = host
        self.probePort = probePort
    }

    /// Starts answering probes on host:probePort.
    func installProbeServer() {
        network.registerEndpoint(host: host, port: probePort) { [self] stream in
            Task { await self.serveProbe(stream) }
        }
    }

    func uninstallProbeServer() {
        network.removeEndpoint(host: host, port: probePort)
    }

    private func serveProbe(_ stream: LinkMemoryStream) async {
        do {
            let raw = try await LinkFakeDash.readRawFrame(stream)
            probesReceived.withLock { $0.append(raw) }
            switch probeBehavior.current {
            case .accept:
                try await stream.write(LinkFakeDash.acceptBytes)
                acceptedCount.withLock { $0 += 1 }
            case .reject:
                try await stream.write(LinkFakeDash.rejectBytes)
            case .closeWithoutReply:
                stream.close()
                return
            case .badMagic:
                try await stream.write(linkHex("11 00 00 70 1f 00 00 00 0f 00 00 70 00 00 00 00"))
            }
            // Wait for the phone to close the probe socket.
            _ = try? await stream.read(exactly: 1)
        } catch {}
        stream.close()
    }

    /// Reads one raw CmdBaseHead frame (header + payload) from a stream.
    static func readRawFrame(_ stream: any ByteStream) async throws -> Data {
        let header = try await stream.read(exactly: 16)
        let h = try PxcFrame.parseHeader([UInt8](header))
        guard h.payloadLength > 0 else { return header }
        return header + (try await stream.read(exactly: h.payloadLength))
    }

    /// Connects back to the phone's :10922.
    func openControl() throws -> LinkFakeControl {
        LinkFakeControl(stream: try network.dial(port: 10922, fromHost: host))
    }

    /// Connects back to a phone media port (:10921 / :10920).
    func openMedia(port: UInt16) throws -> LinkFakeMedia {
        LinkFakeMedia(stream: try network.dial(port: port, fromHost: host))
    }
}

/// Dash end of a :10922 connection.
final class LinkFakeControl: @unchecked Sendable {
    let stream: LinkMemoryStream
    /// Phone heartbeats (0x70000000) skipped by `next`.
    let heartbeats = Locked(0)
    /// Raw bytes of the last phone heartbeat seen.
    let lastHeartbeatRaw = Locked<Data?>(nil)

    init(stream: LinkMemoryStream) { self.stream = stream }

    func send(_ frame: PxcFrame) async throws { try await stream.write(frame.encoded()) }

    func send(cmd: UInt32, json: String) async throws { try await send(PxcFrame(cmd: cmd, text: json)) }

    func sendRaw(_ data: Data) async throws { try await stream.write(data) }

    /// The next frame from the phone that is not a phone heartbeat: raw bytes + decoded frame.
    func next(timeout: TimeInterval = 3) async throws -> (raw: Data, frame: PxcFrame) {
        let s = stream
        let hb = heartbeats
        let hbRaw = lastHeartbeatRaw
        return try await linkWithin(timeout, "control frame") {
            while true {
                let raw = try await LinkFakeDash.readRawFrame(s)
                guard let decoded = try PxcFrame.decode(raw)?.frame else { throw TransportError.failed("undecodable") }
                if decoded.cmd == PxcCmd.heartbeat, decoded.payload.isEmpty {
                    hb.withLock { $0 += 1 }
                    hbRaw.set(raw)
                    continue
                }
                return (raw, decoded)
            }
        }
    }

    /// The next raw frame bytes (heartbeats skipped).
    func nextRaw(timeout: TimeInterval = 3) async throws -> Data { try await next(timeout: timeout).raw }

    /// Waits `duration` and asserts that only phone heartbeats arrived meanwhile.
    func expectSilence(for duration: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let f = try await next(timeout: duration)
            XCTFail("unexpected frame \(f.frame)", file: file, line: line)
        } catch is TimeoutError {
            // expected
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func close() { stream.close() }
}

/// Dash end of a media connection.
final class LinkFakeMedia: @unchecked Sendable {
    let stream: LinkMemoryStream

    init(stream: LinkMemoryStream) { self.stream = stream }

    func send(_ message: MediaMessage) async throws { try await stream.write(message.encoded()) }

    func send(cmd: Int16, token: Int32 = 0x1234_5678, body: Data = Data()) async throws {
        try await send(MediaMessage(cmdType: cmd, token: token, body: body))
    }

    /// One ReqBase reply: raw bytes + decoded message.
    func reply(timeout: TimeInterval = 3) async throws -> (raw: Data, message: MediaMessage) {
        let s = stream
        return try await linkWithin(timeout, "media reply") {
            let header = try await s.read(exactly: 8)
            let h = try MediaMessage.parseHeader([UInt8](header))
            let body = h.cmdLen > 0 ? try await s.read(exactly: h.cmdLen) : Data()
            return (header + body, MediaMessage(cmdType: h.cmdType, token: h.token, body: body))
        }
    }

    /// One raw pulled frame `[size i32 LE][AU]`: raw bytes + the AU.
    func frame(timeout: TimeInterval = 3) async throws -> (raw: Data, accessUnit: Data) {
        let s = stream
        return try await linkWithin(timeout, "media frame") {
            let sizeBytes = try await s.read(exactly: 4)
            let size = Int(ByteReader(sizeBytes).peekI32le(at: 0)!)
            let au = try await s.read(exactly: size)
            return (sizeBytes + au, au)
        }
    }

    /// Asserts nothing arrives within `duration`.
    func expectSilence(for duration: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async {
        let s = stream
        do {
            let d = try await linkWithin(duration, "silence") { try await s.readSome(maxCount: 64) }
            XCTFail("unexpected bytes \(d.hexString)", file: file, line: line)
        } catch is TimeoutError {
            // expected
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func close() { stream.close() }
}

/// Sample dash payloads.
enum LinkDashSamples {
    /// CFDL16 675 SR-R CLIENT_INFO (fields documented in docs/01 §0, §3).
    static let cfdl16ClientInfo = "{\"HUID\":\"6GUVA2C00100055\",\"HUName\":\"CFDL16-6GUV\",\"channel\":\"37416\",\"flavor\":65540,\"sdkVersion\":\"0.9.29.1\",\"pxcVersion\":\"1.0.2\",\"screenType\":1,\"productType\":3,\"mirrorMode\":1,\"supportScreenMirroring\":true,\"socketTimeoutPeriodWifi\":9,\"supportFunction\":0}"

    /// 1000 MT-X CLIENT_INFO (control-plane.md §7, reconstructed).
    static let mtxClientInfo = "{\"HUID\":\"6WX0AT231300200\",\"HUName\":\"CFMOTO-805120\",\"package_name\":\"com.cfmoto.cfdashmotoplay\",\"version_name\":\"CFDL26.2.3.5.0.6\",\"sdkVersion\":\"1.1.4\",\"flavor\":65540,\"productType\":3,\"screenType\":1,\"mirrorMode\":1,\"pxcVersion\":\"1.0.2\",\"enableSockServerAuth\":true,\"dpi\":240,\"enableDPI\":true,\"supportScreenTouch\":true,\"supportHID\":true,\"supportMirrorOverlayTouch\":true,\"supportFunction\":128,\"supportConnect\":776,\"socketTimeoutPeriodWifi\":9,\"supportScreenMirroring\":true}"

    static let querySpeed = "{\"usbSpeed\":0,\"wifiSpeed\":0}"
    static let checkSn = "{\"client_set\":\"easy_conn\",\"sn\":\"DSXXZMHNFV3DEXEBB3PZ2\"}"

    /// HuTimeSyncTest.req("2026-07-24 17:09:20.190000000") (modelId 37426, seq 7), 45 bytes.
    static func timeSyncRequest(stamp: String = "2026-07-24 17:09:20.190000000", modelId: Int32 = 37426, seq: Int32 = 7) -> Data {
        var w = ByteWriter(capacity: 45)
        w.i32le(-2)
        w.i32le(modelId)
        w.i32le(seq)
        w.i32le(0)
        var bytes = w.bytes + Array(stamp.utf8)
        if bytes.count < 45 { bytes += [UInt8](repeating: 0, count: 45 - bytes.count) }
        return Data(bytes)
    }

    /// A REQ 16 body: 32-byte fixed part (+ optional encryptedHUID text).
    static func configCaptureBody(width: Int, height: Int, fps: Int32 = 30, encoder: Int32 = 2, ext: UInt8 = 0,
                                  touchMode: UInt8 = 0, huid: String? = nil) -> Data {
        var w = ByteWriter(capacity: 32)
        w.u16le(UInt16(width))
        w.u16le(UInt16(height))
        w.i32le(fps)
        w.i32le(encoder)
        w.zeros(13) // supportCodec .. capScreenMode (12..24)
        w.u8(touchMode) // 25
        w.zeros(3) // 26..28
        w.u8(ext) // 29
        w.zeros(2) // 30..31
        if let huid { w.append(Data(huid.utf8)) }
        return w.data
    }
}
