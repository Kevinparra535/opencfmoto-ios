// SPDX-License-Identifier: AGPL-3.0-or-later
// CONTRACT FILE — parsed pairing QR (Android `QrData`, QrData.kt:27-42). The parser lives in
// Bike/BikeQRParser.swift (`BikeQR.parse(_:)`); see docs/spec/session-network.md §2.

import Foundation

public struct BikeQR: Sendable, Equatable, Hashable, Codable {
    /// The exact scanned text (trimmed). Also the garage identity of the bike.
    public var raw: String
    public var ssid: String
    /// WPA2 passphrase ("" only for phone-hotspot formats).
    public var password: String
    public var auth: String?
    /// Normalised MAC ("aa:bb:cc:dd:ee:ff") when present.
    public var mac: String?
    public var name: String?
    /// Capability bitmask: 1 AP, 2 AP+internet, 8 Wi-Fi Direct, 64 Bluetooth, 128 phone hotspot.
    public var action: Int
    public var modelId: String?
    public var sn: String?
    public var channel: String?

    public init(raw: String, ssid: String, password: String, auth: String? = nil, mac: String? = nil,
                name: String? = nil, action: Int = 0, modelId: String? = nil, sn: String? = nil, channel: String? = nil) {
        self.raw = raw
        self.ssid = ssid
        self.password = password
        self.auth = auth
        self.mac = mac
        self.name = name
        self.action = action
        self.modelId = modelId
        self.sn = sn
        self.channel = channel
    }

    public var supportsAp: Bool { (action & 1) != 0 || (action & 2) != 0 }
    public var supportsP2p: Bool { (action & 8) != 0 }
    public var supportsPhoneHotspot: Bool {
        (action & 128) != 0 || (ssid.trimmingCharacters(in: .whitespaces).isEmpty && !(mac ?? "").isEmpty)
    }
    /// Display name: QR name, else SSID.
    public var displayName: String { (name?.isEmpty == false ? name! : ssid) }
}
