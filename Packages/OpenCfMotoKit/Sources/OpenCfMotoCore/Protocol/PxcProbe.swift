// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (probeTarget / JSONProbe)
//
// The :10930 probe ("ECP_PXC_MDNS_RESPOND"): the phone connects to the dash, sends ONE fixed frame,
// reads ONE reply and closes. The dash then connects back to the phone's listeners
// (docs/spec/control-plane.md §4, session-network.md §5.3).

import Foundation

public enum PxcProbe {
    /// The dash's probe/"mDNS respond" port.
    public static let port: UInt16 = 10930
    /// The spoofed official Android app (identity verified on every supported dash).
    public static let spoofedPackage = "com.cfmoto.cfmotointernational"
    /// Probe JSON, built as a literal exactly like Android (70 bytes, fixed key order).
    public static let payloadJSON = "{\"phoneType\":\"Android\",\"packageName\":\"\(spoofedPackage)\"}"

    /// The probe frame (cmd 0x70000010, totalLen 86, magic 0x70000046).
    public static var frame: PxcFrame { PxcFrame(cmd: PxcCmd.mdnsRespond, text: payloadJSON) }

    /// The exact 86 probe bytes.
    public static var frameBytes: Data { frame.encoded() }

    /// Accept rule: `cmd == 0x70000011` AND the UTF-8 body contains the substring "true"
    /// (`{"status":true}` accepted, `{"status":false}` rejected).
    public static func isAccepted(_ reply: PxcFrame) -> Bool {
        reply.cmd == PxcCmd.mdnsRespondAck && reply.payloadText.contains("true")
    }
}
