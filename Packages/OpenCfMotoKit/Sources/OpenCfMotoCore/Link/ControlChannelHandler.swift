// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) PxcHandshake.kt (handle) and BikeProfile.kt
// (Cfdl26PortraitProfile.handleUnknownControl — the universal cmd + 1 policy)
//
// One handler per :10922 connection. Deterministic: frame in → reply frames out (written in
// order on the SAME connection) + events for the engine. Shared session state (profile, HUID,
// identity, signer, canvas) lives in `LinkSessionContext` (docs/spec/control-plane.md §3, §5, §11).

import Foundation

/// The PXC channel a :10922 connection selected with its first frame.
public enum PxcChannel: String, Sendable, Equatable {
    case carCtrl = "CAR_CTRL"
    case carData = "CAR_DATA"
}

/// What the engine must know about a handled control frame.
public enum ControlChannelEvent: Sendable, Equatable {
    /// 0x10000 / 0x20000 (acked). `startHeartbeat` is true only for the first select on this
    /// connection (Android starts a second heartbeat thread on a duplicated select; iOS dedupes).
    case channelSelected(PxcChannel, startHeartbeat: Bool)
    /// CLIENT_INFO parsed, profile selected, 0x10011 reply built.
    case dashIdentified(DashInfo, BikeProfile)
    /// CLIENT_INFO did not parse: logged loudly, NO reply (Android parity).
    case clientInfoUnparsable(String)
    /// CHECK_SN answered (0x103e1 + 0x201c0).
    case checkSnCompleted(serial: String)
    /// 0x10600 answered.
    case timeSync(HuTimeSync.Mode)
    /// Any other frame acked cmd + 1 (empty).
    case acked(request: UInt32)
}

/// Replies (in order) and events for one inbound frame.
public struct ControlChannelResponse: Sendable, Equatable {
    public var replies: [PxcFrame]
    public var events: [ControlChannelEvent]

    public init(replies: [PxcFrame] = [], events: [ControlChannelEvent] = []) {
        self.replies = replies
        self.events = events
    }
}

public final class ControlChannelHandler: @unchecked Sendable {
    public let context: LinkSessionContext
    /// Log prefix (":10922").
    public let tag: String
    private let lock = NSLock()
    private var selectedChannels: Set<String> = []
    private var _channel: PxcChannel?

    public init(context: LinkSessionContext, tag: String = ":10922") {
        self.context = context
        self.tag = tag
    }

    /// CLIENT_INFO / CHECK_SN payloads larger than this are not parsed (real ones are < 1 KiB; frames
    /// may be up to 1 MiB): treated as unparsable (review SEC-4).
    public static let maxJSONPayloadBytes = 64 * 1024
    /// Payload text logged per frame (a peer could otherwise fill the log ring with 1 MiB lines).
    static let maxLoggedPayloadChars = 2048

    /// The payload text for a log line, cut to `maxLoggedPayloadChars`.
    private static func loggable(_ frame: PxcFrame) -> String {
        let text = frame.payloadText
        guard text.count > maxLoggedPayloadChars else { return text }
        return String(text.prefix(maxLoggedPayloadChars)) + "\u{2026}(\(frame.payload.count) bytes)"
    }

    /// The channel this connection selected (nil until 0x10000 / 0x20000).
    public var channel: PxcChannel? { lock.lock(); defer { lock.unlock() }; return _channel }

    /// Handles one inbound frame (Android `PxcHandshake.handle`).
    public func handle(_ frame: PxcFrame) -> ControlChannelResponse {
        switch frame.cmd {
        case PxcCmd.channelCarCtrl:
            return select(.carCtrl, ack: PxcCmd.channelCarCtrlAck)
        case PxcCmd.channelCarData:
            return select(.carData, ack: PxcCmd.channelCarDataAck)
        case PxcCmd.clientInfo:
            return onClientInfo(frame)
        case PxcCmd.querySpeed:
            Log.i("LINK", "[\(tag)] QUERY_SPEED \(Self.loggable(frame)) → reply 0x10691")
            return ControlChannelResponse(replies: [PxcFrame(cmd: PxcCmd.querySpeedReply)])
        case PxcCmd.checkSn:
            return onCheckSn(frame)
        case PxcCmd.heartbeat:
            return ControlChannelResponse(replies: [PxcFrame(cmd: PxcCmd.heartbeatAck)])
        case PxcCmd.heartbeatAck, PxcCmd.checkSnResultAck:
            return ControlChannelResponse() // acks from the bike — nothing to do
        case PxcCmd.huTimeSync:
            return onTimeSync(frame)
        case PxcCmd.huQueryTime:
            Log.i("LINK", "[CLOCK-LAB] HU_QUERY_TIME len=\(frame.payload.count) → 0x10451 empty")
            let channel = context.clientInfo?.channel.trimmingCharacters(in: .whitespaces) ?? ""
            Log.i("LINK", "[\(tag)] HU_QUERY_TIME (0x10450) len=\(frame.payload.count) channel=\(channel.isEmpty ? "-" : channel) → 0x10451 empty")
            return ControlChannelResponse(replies: [HuQueryTime.replyFrame()])
        default:
            return ackUnknown(frame)
        }
    }

    private func select(_ ch: PxcChannel, ack: UInt32) -> ControlChannelResponse {
        lock.lock()
        let first = selectedChannels.insert(ch.rawValue).inserted && selectedChannels.count == 1
        if _channel == nil { _channel = ch }
        lock.unlock()
        let hex = ch == .carCtrl ? "0x10000" : "0x20000"
        Log.i("LINK", "[\(tag)] bike selected \(ch.rawValue) (\(hex)) → ack \(PxcCmd.hex(ack))")
        return ControlChannelResponse(replies: [PxcFrame(cmd: ack)], events: [.channelSelected(ch, startHeartbeat: first)])
    }

    private func onClientInfo(_ frame: PxcFrame) -> ControlChannelResponse {
        guard frame.payload.count <= Self.maxJSONPayloadBytes else {
            Log.e("LINK", "[\(tag)] !! CLIENT_INFO of \(frame.payload.count) bytes \u{2014} too large to be real, NOT parsed / NOT replying")
            return ControlChannelResponse(events: [.clientInfoUnparsable(Self.loggable(frame))])
        }
        let text = frame.payloadText
        Log.i("LINK", "[\(tag)] *** CLIENT_INFO from bike *** \(text)")
        guard let info = BikeClientInfo.parse(text) else {
            Log.e("LINK", "[\(tag)] !! CLIENT_INFO parse failed — NOT replying (Android parity); the dash will likely stall. len=\(frame.payload.count) hex=\(frame.payload.prefix(48).hexString)")
            return ControlChannelResponse(events: [.clientInfoUnparsable(text)])
        }
        // Masked here: the bare-serial redaction rule only matches alphanumeric HUIDs (review SEC-5).
        Log.i("LINK", "[\(tag)] carHuid=\(info.huid.map(LogRedactor.maskTail) ?? "null") HUName=\(info.huName) channel=\(info.channel)")
        Log.i("LINK", "[\(tag)] bike touch=\(info.supportsScreenTouch) supportHID=\(info.optBoolean("supportHID")) supportMirrorOverlayTouch=\(info.optBoolean("supportMirrorOverlayTouch")) socketTimeoutPeriodWifi=\(info.socketTimeoutSeconds.map(String.init) ?? "-")")
        let (profile, reply, dash) = context.applyClientInfo(info, tag: tag)
        let replyFrame = PhoneClientInfoReply.frame(reply)
        Log.i("LINK", "[\(tag)] → CLIENT_INFO reply \(String(reply.jsonString.prefix(180)))…")
        return ControlChannelResponse(replies: [replyFrame], events: [.dashIdentified(dash, profile)])
    }

    private func onCheckSn(_ frame: PxcFrame) -> ControlChannelResponse {
        Log.i("LINK", "[\(tag)] CHECK_SN from bike: \(Self.loggable(frame))")
        // An oversized payload is answered like an unparsable one (empty id), without parsing it.
        let serial = frame.payload.count <= Self.maxJSONPayloadBytes ? CheckSn.serial(from: frame.payload) : ""
        let result = CheckSn.result(serial: serial)
        // The reply echoes the serial under "id", which no redaction rule covers: log it masked (the
        // wire payload is unchanged; the request line above is masked by the "sn" rule) — review SEC-5.
        Log.i("LINK", "[\(tag)] → CHECK_SN_RESULT \(CheckSn.result(serial: LogRedactor.maskTail(serial)).jsonString)")
        return ControlChannelResponse(
            replies: [PxcFrame(cmd: PxcCmd.checkSnAck), PxcFrame(cmd: PxcCmd.checkSnResult, payload: result.jsonData)],
            events: [.checkSnCompleted(serial: serial)])
    }

    private func onTimeSync(_ frame: PxcFrame) -> ControlChannelResponse {
        let ack = context.timeSyncAck(for: frame)
        let note = context.noteTimeSync()
        if note.log {
            Log.i("LINK", "[CLOCK-LAB] HU_TIME_SYNC → \(context.timeSyncForcePhone ? "phone" : "echo")")
            Log.i("LINK", "[\(tag)] HU_TIME_SYNC #\(note.count) len=\(frame.payload.count) → ack 0x10601 mode=\(ack.mode.rawValue) time=\(ack.stamp)")
        }
        return ControlChannelResponse(replies: [PxcFrame(cmd: PxcCmd.huTimeSyncAck, payload: ack.payload)],
                                      events: [.timeSync(ack.mode)])
    }

    /// The universal policy: ack EVERY other frame with cmd + 1 and an empty payload (the CFDL26
    /// burst and newer CFDL16 units gate the media ports on these acks).
    private func ackUnknown(_ frame: PxcFrame) -> ControlChannelResponse {
        let ack = PxcCmd.reply(to: frame.cmd)
        let body = frame.payload.isEmpty ? "" : Self.loggable(frame)
        let hex = frame.payload.isEmpty ? "" : " hex=" + frame.payload.prefix(48).hexString
        let marker = frame.cmd == PxcCmd.screenTouch ? " *** SCREEN_TOUCH ***" : ""
        Log.i("LINK", "[\(tag)] CFDL26 ctrl \(frame.cmdHex) (\(PxcCmd.name(of: frame.cmd)))\(marker) len=\(frame.payload.count) \(body)\(hex) → ack \(PxcCmd.hex(ack)) (empty)")
        return ControlChannelResponse(replies: [PxcFrame(cmd: ack)], events: [.acked(request: frame.cmd)])
    }
}
