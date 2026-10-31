// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) PxcFrame.kt (command constants + nameOf)
//
// Command catalogue of the PXC control plane (docs/spec/control-plane.md §3). Naming pattern:
// 0x1xxxx car-initiated, 0x2xxxx phone-initiated, 0x3xxxx "R2A", 0x4xxxx "A2R", 0x7000000x
// transport level. A reply is the request cmd + 1 (usually with an empty payload).

import Foundation

/// PXC control command ids (CmdBaseHead `cmd`).
public enum PxcCmd {
    // MARK: Channel selects (first frame of a :10922 connection; server answers cmd + 1)
    public static let channelCarCtrl: UInt32 = 0x0001_0000
    public static let channelCarCtrlAck: UInt32 = 0x0001_0001
    public static let channelCarData: UInt32 = 0x0002_0000
    public static let channelCarDataAck: UInt32 = 0x0002_0001
    /// Carbit "RV" channels (never observed; generic cmd + 1 ack, no heartbeat).
    public static let channelRvCtrl: UInt32 = 0x0003_0000
    public static let channelRvData: UInt32 = 0x0004_0000

    // MARK: Transport level
    /// Phone → bike probe on :10930 ("ECP_PXC_MDNS_RESPOND").
    public static let mdnsRespond: UInt32 = 0x7000_0010
    /// Bike → phone probe answer `{"status":true|false}`.
    public static let mdnsRespondAck: UInt32 = 0x7000_0011
    public static let heartbeat: UInt32 = 0x7000_0000
    public static let heartbeatAck: UInt32 = 0x7000_0001

    // MARK: Handshake
    public static let clientInfo: UInt32 = 0x0001_0010
    public static let clientInfoReply: UInt32 = 0x0001_0011
    public static let querySpeed: UInt32 = 0x0001_0690
    public static let querySpeedReply: UInt32 = 0x0001_0691
    public static let checkSn: UInt32 = 0x0001_03E0
    public static let checkSnAck: UInt32 = 0x0001_03E1
    public static let checkSnResult: UInt32 = 0x0002_01C0
    public static let checkSnResultAck: UInt32 = 0x0002_01C1

    // MARK: Notify frames (acked cmd + 1, empty)
    /// CFDL26 `{"log":"…mdns success…"}` — the first gate of the burst.
    public static let logReport: UInt32 = 0x0001_0780
    public static let logReportAck: UInt32 = 0x0001_0781
    /// `{port,userName,pwd}` of the dash's FTP OTA server (never connect to it).
    public static let otaFtpInfo: UInt32 = 0x0001_03A0
    /// `{music,talkie,tts,vr,autoChangeToBT}` feature flags.
    public static let mediaFeatureConfig: UInt32 = 0x0001_0020
    /// `{maxNaviIcon:161,supportFunction:0}` (unnamed in the SDK).
    public static let naviFeatureNotify: UInt32 = 0x0001_0040
    /// Empty, repeats periodically (unnamed).
    public static let periodicNotify: UInt32 = 0x0001_0750
    /// Empty (unnamed).
    public static let notify10430: UInt32 = 0x0001_0430
    /// `{bluetooth:4129}` (unnamed).
    public static let bluetoothNotify: UInt32 = 0x0001_0460
    /// Voice-command grammar JSON (US 800NK, 450NK; unnamed).
    public static let voiceGrammarNotify: UInt32 = 0x0001_0470
    /// SOCKS uplink offer `{ctrlPort,dataPort,userName,pwd}` (not required).
    public static let sockServerInfo: UInt32 = 0x0001_04A0
    public static let sockServerInfoAck: UInt32 = 0x0001_04A1

    // MARK: Clock
    /// Bike wall clock, ~every 2 s (16-byte header + 29 ASCII chars). Reply with a body (echo).
    public static let huTimeSync: UInt32 = 0x0001_0600
    public static let huTimeSyncAck: UInt32 = 0x0001_0601
    /// `ECP_C2P_QUERY_TIME`; default reply is an empty 0x10451.
    public static let huQueryTime: UInt32 = 0x0001_0450
    public static let huQueryTimeAck: UInt32 = 0x0001_0451

    // MARK: SDK constants never observed on the supported dashes (logged by name only)
    public static let remoteAuthResult: UInt32 = 0x0002_0010
    public static let authHuid: UInt32 = 0x0003_0010
    public static let mirrorStart: UInt32 = 0x0003_0020
    public static let mirrorStop: UInt32 = 0x0003_0030
    /// `CMD_SCREEN_TOUCH` (R2A). Acked cmd + 1 and logged as `*** SCREEN_TOUCH ***` if it ever arrives.
    public static let screenTouch: UInt32 = 0x0003_0040
    /// `CMD_RVINFO`: Android's decimal literal 1610809424 = 0x60030050 (its comment says 0x60004110;
    /// the compiled value wins).
    public static let rvInfo: UInt32 = 0x6003_0050
    public static let screenEvent: UInt32 = 0x0004_0010
    /// `CMD_START_OVERLAY`: Android's decimal literal 262224 = 0x40050 (its comment says 0x40020).
    public static let startOverlay: UInt32 = 0x0004_0050

    // MARK: MCULite / ECTinyPlus (android.R constants used as opaque ids; INFERRED, logging only)
    public static let channelMcuLiteCtrl: UInt32 = 0x0108_0000
    public static let channelMcuLiteData: UInt32 = 0x0109_0000
    public static let channelMcuCtrl: UInt32 = 0x0106_0000
    public static let channelMcuData: UInt32 = 0x0107_0000
    public static let mcuClientInfo: UInt32 = 0x0108_0010
    public static let mcuStartMirror: UInt32 = 0x0108_0020
    public static let mcuCheckOta: UInt32 = 0x0108_0030
    public static let mcuStartOta: UInt32 = 0x0108_0040

    /// The generic reply id for `cmd` (cmd + 1, wrapping like Java `Int`).
    public static func reply(to cmd: UInt32) -> UInt32 { cmd &+ 1 }

    /// "0x10010"-style lower-case hex (Android `"0x" + cmd.toUInt().toString(16)`).
    public static func hex(_ cmd: UInt32) -> String { "0x" + String(cmd, radix: 16) }

    /// Log name of a command (Android `PxcFrame.nameOf`, plus the handshake commands it handles
    /// explicitly and the unnamed notify frames). "?" when unknown.
    public static func name(of cmd: UInt32) -> String {
        switch cmd {
        case channelCarCtrl: return "CHANNEL_CAR_CTRL"
        case channelCarCtrlAck: return "CHANNEL_CAR_CTRL_ACK"
        case channelCarData: return "CHANNEL_CAR_DATA"
        case channelCarDataAck: return "CHANNEL_CAR_DATA_ACK"
        case channelRvCtrl: return "CHANNEL_RV_CTRL"
        case channelRvData: return "CHANNEL_RV_DATA"
        case mdnsRespond: return "MDNS_RESPOND"
        case mdnsRespondAck: return "MDNS_RESPOND_ACK"
        case heartbeat: return "HEARTBEAT"
        case heartbeatAck: return "HEARTBEAT_ACK"
        case clientInfoReply: return "CLIENT_INFO_RLY"
        case querySpeed: return "QUERY_SPEED"
        case querySpeedReply: return "QUERY_SPEED_RLY"
        case checkSn: return "CHECK_SN"
        case checkSnAck: return "CHECK_SN_ACK"
        case checkSnResult: return "CHECK_SN_RESULT"
        case checkSnResultAck: return "CHECK_SN_RESULT_ACK"
        case logReport: return "LOG_REPORT (CFDL26)"
        case logReportAck: return "LOG_REPORT_ACK (CFDL26)"
        case otaFtpInfo: return "OTA_FTP_INFO (CFDL26)"
        case mediaFeatureConfig: return "MEDIA_FEATURE_CFG (CFDL26)"
        case sockServerInfo: return "SOCK_SERVER_INFO"
        case sockServerInfoAck: return "SOCK_SERVER_INFO_ACK"
        case huTimeSync: return "HU_TIME_SYNC"
        case huTimeSyncAck: return "HU_TIME_SYNC_ACK"
        case huQueryTime: return "HU_QUERY_TIME"
        case huQueryTimeAck: return "HU_QUERY_TIME_ACK"
        case clientInfo: return "CLIENT_INFO (PXC)"
        case remoteAuthResult: return "REMOTE_AUTH_RESULT"
        case authHuid: return "AUTH_HUID"
        case mirrorStart: return "MIRROR_START (PXC)"
        case mirrorStop: return "MIRROR_STOP"
        case screenTouch: return "SCREEN_TOUCH"
        case rvInfo: return "RVINFO"
        case screenEvent: return "SCREEN_EVENT"
        case startOverlay: return "START_OVERLAY"
        case channelMcuLiteCtrl: return "CHANNEL_MCULITE_CTRL"
        case channelMcuLiteCtrl &+ 1: return "CHANNEL_MCULITE_CTRL_ACK"
        case channelMcuLiteData: return "CHANNEL_MCULITE_DATA"
        case channelMcuLiteData &+ 1: return "CHANNEL_MCULITE_DATA_ACK"
        case channelMcuCtrl: return "CHANNEL_MCU_CTRL"
        case channelMcuData: return "CHANNEL_MCU_DATA"
        case mcuClientInfo: return "MCU_CLIENT_INFO"
        case mcuStartMirror: return "MCU_START_MIRROR"
        case mcuCheckOta: return "MCU_CHECK_OTA"
        case mcuStartOta: return "MCU_START_OTA"
        default: return "?"
        }
    }
}
