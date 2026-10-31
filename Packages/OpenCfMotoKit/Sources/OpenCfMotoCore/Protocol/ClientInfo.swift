// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) PxcHandshake.kt (onClientInfo, onCheckSn) and BikeProfile.kt
// (basePhoneClientInfo, advertisesScreenTouch)
//
// CLIENT_INFO (0x10010, bike → phone) parsing and the phone's reply (0x10011), plus CHECK_SN
// (docs/spec/control-plane.md §7, §8, §10.2).

import Foundation

/// The bike's CLIENT_INFO JSON with Android org.json `opt*` semantics. The raw object (`json`) is
/// what the bike-profile scoring reads.
public struct BikeClientInfo: Sendable, Equatable {
    /// The parsed object, keys in received order (the "raw dictionary" used for scoring).
    public var json: OrderedJSONObject
    /// The payload text as received (UTF-8, malformed bytes as U+FFFD). Redact before sharing.
    public var text: String

    public init(json: OrderedJSONObject, text: String = "") {
        self.json = json
        self.text = text.isEmpty ? json.jsonString : text
    }

    /// Lenient parse (org.json `JSONObject(text)`): leading/trailing NULs, whitespace and a BOM are
    /// trimmed first; trailing bytes after the object are ignored. Returns nil if no object parses.
    public static func parse(_ text: String) -> BikeClientInfo? {
        let trimmed = BikeClientInfo.trimNulsAndWhitespace(text)
        guard let obj = try? PxcOrgJSON.parseObject(trimmed) else { return nil }
        return BikeClientInfo(json: obj, text: text)
    }

    /// Parses a raw 0x10010 payload.
    public static func parse(_ payload: Data) -> BikeClientInfo? {
        parse(String(decoding: payload, as: UTF8.self))
    }

    static func trimNulsAndWhitespace(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        func junk(_ u: Unicode.Scalar) -> Bool {
            u.value == 0 || u.value == 0xFEFF || u.properties.isWhitespace
        }
        var lo = 0, hi = scalars.count
        while lo < hi, junk(scalars[lo]) { lo += 1 }
        while hi > lo, junk(scalars[hi - 1]) { hi -= 1 }
        if lo == 0, hi == scalars.count { return s }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[lo ..< hi])
        return String(view)
    }

    // MARK: org.json opt* accessors

    public func has(_ key: String) -> Bool { json[key] != nil }

    /// `optString(key)`: "" when missing; numbers/booleans as text; JSON null → "null".
    public func optString(_ key: String) -> String { PxcOrgJSON.string(json[key]) ?? "" }

    /// `optInt(key, fallback)`: numeric strings are parsed (`"128"` → 128).
    public func optInt(_ key: String, _ fallback: Int = 0) -> Int { PxcOrgJSON.int(json[key]) ?? fallback }

    /// `optBoolean(key, fallback)`: booleans or the strings "true"/"false" (any case).
    public func optBoolean(_ key: String, _ fallback: Bool = false) -> Bool { PxcOrgJSON.bool(json[key]) ?? fallback }

    // MARK: Fields

    /// `HUID`, falling back to `huid`; empty → nil (Android `carHuid`).
    public var huid: String? {
        let a = optString("HUID")
        if !a.isEmpty { return a }
        let b = optString("huid")
        return b.isEmpty ? nil : b
    }

    public var huName: String { optString("HUName") }
    public var sdkVersion: String { optString("sdkVersion") }
    public var versionName: String { optString("version_name") }
    public var packageName: String { optString("package_name") }
    public var channel: String { optString("channel") }
    /// The bike's own touch claim (`supportScreenTouch`).
    public var supportsScreenTouch: Bool { optBoolean("supportScreenTouch") }
    /// `socketTimeoutPeriodWifi` (seconds; 9 on known dashes) when present and positive.
    public var socketTimeoutSeconds: Int? {
        guard has("socketTimeoutPeriodWifi") else { return nil }
        let v = optInt("socketTimeoutPeriodWifi", 0)
        return v > 0 ? v : nil
    }

    /// The contract summary for the app.
    public func dashInfo(profile: BikeProfileID) -> DashInfo {
        DashInfo(huid: huid ?? "", huName: huName, sdkVersion: sdkVersion, versionName: versionName,
                 packageName: packageName, channel: channel, socketTimeoutSeconds: socketTimeoutSeconds,
                 supportsScreenTouch: supportsScreenTouch, profile: profile, rawJSON: text)
    }
}

/// Builder of the phone's CLIENT_INFO reply (0x10011). Key order and values are exactly Android's
/// `basePhoneClientInfo` (control-plane.md §8.1–§8.3); do not reorder.
public enum PhoneClientInfoReply {
    public static let pxcVersion = "1.0.2"
    public static let phoneOs = "Android"
    public static let package = PxcProbe.spoofedPackage
    public static let versionCode = 126
    public static let token = 0
    public static let appVersionFingerPrint = "opencfmoto-poc"

    /// `advertisesScreenTouch`: "Disable touchscreen" wins, then "Force touchscreen", else the
    /// profile default (`BikeProfile.kt:278-283`).
    public static func advertisesScreenTouch(profileSupportsTouch: Bool, forceTouch: Bool, forceNonTouch: Bool) -> Bool {
        if forceNonTouch { return false }
        if forceTouch { return true }
        return profileSupportsTouch
    }

    /// The reply object.
    /// - Parameters:
    ///   - encryptedHUID: base64 signature of the bike HUID, "" when the bike sent none.
    ///   - supportFunction: the profile's advertised value (0 Legacy/ClC450, 128 others).
    ///   - appendScreenTouch: append the trailing `"supportScreenTouch":true` (CFDL26-family profiles
    ///     when touch is advertised). The key is otherwise absent, never `false`.
    public static func build(phone: PhoneIdentity, publicKeyBase64: String, encryptedHUID: String,
                             supportFunction: Int, appendScreenTouch: Bool) -> OrderedJSONObject {
        var o = OrderedJSONObject()
        o.put("pxcVersion", pxcVersion)
        o.put("phoneUUID", phone.phoneUUID)
        o.put("phoneBrand", phone.phoneBrand)
        o.put("phoneModel", phone.phoneModel)
        o.put("phoneOsVersion", phone.phoneOsVersion)
        o.put("phoneOs", phoneOs)
        o.put("package", package)
        o.put("versionCode", versionCode)
        o.put("token", token)
        o.put("pubkey", publicKeyBase64)
        o.put("encryptedHUID", encryptedHUID)
        o.put("bluetoothName", phone.bluetoothName)
        o.put("supportH264IFrame", true)
        o.put("supportFunction", supportFunction)
        // Never advertise supportSyncCorrectTime:true (Zontes/Voge clocks went to 00:00).
        o.put("supportSyncCorrectTime", false)
        o.put("appVersionFingerPrint", appVersionFingerPrint)
        if appendScreenTouch { o.put("supportScreenTouch", true) }
        return o
    }

    /// Convenience: reply for `profile`, signing `huid` with `signer`.
    /// A signer failure (HUID > 117 bytes) yields `encryptedHUID: ""` and a loud log instead of
    /// Android's silent "handler error" with no reply.
    public static func build(phone: PhoneIdentity, huid: String?, signer: HuidSigner, profile: BikeProfile,
                             forceTouch: Bool, forceNonTouch: Bool) -> OrderedJSONObject {
        var sig = ""
        if let huid, !huid.isEmpty {
            do {
                sig = try signer.encryptedHUID(huid)
            } catch {
                Log.e("LINK", "[:10922] !! encryptedHUID failed for HUID (\(huid.utf8.count) bytes): \(error) — sending \"\"")
            }
        }
        let touch = profile.appendsScreenTouchKey &&
            advertisesScreenTouch(profileSupportsTouch: profile.supportsScreenTouch, forceTouch: forceTouch, forceNonTouch: forceNonTouch)
        return build(phone: phone, publicKeyBase64: signer.publicKeyBase64, encryptedHUID: sig,
                     supportFunction: profile.supportFunction, appendScreenTouch: touch)
    }

    /// The 0x10011 frame carrying `reply` (org.json `toString()` bytes, UTF-8).
    public static func frame(_ reply: OrderedJSONObject) -> PxcFrame {
        PxcFrame(cmd: PxcCmd.clientInfoReply, payload: reply.jsonData)
    }
}

/// CHECK_SN (0x103e0) handling: ack 0x103e1 (empty), then 0x201c0 with the result object.
public enum CheckSn {
    /// `JSONObject(text).optString("sn")`; "" if the payload does not parse (the flow continues).
    public static func serial(from payload: Data) -> String {
        guard let obj = try? PxcOrgJSON.parseObject(BikeClientInfo.trimNulsAndWhitespace(String(decoding: payload, as: UTF8.self)))
        else { return "" }
        return PxcOrgJSON.string(obj["sn"]) ?? ""
    }

    /// `{"isOk":true,"errCode":0,"errMsg":"","id":"<sn>","client_set":"easy_conn"}` — `client_set`
    /// is the constant "easy_conn", not echoed.
    public static func result(serial: String) -> OrderedJSONObject {
        var o = OrderedJSONObject()
        o.put("isOk", true)
        o.put("errCode", 0)
        o.put("errMsg", "")
        o.put("id", serial)
        o.put("client_set", "easy_conn")
        return o
    }

    /// The two frames sent for a CHECK_SN request, in order.
    public static func replies(to payload: Data) -> [PxcFrame] {
        [PxcFrame(cmd: PxcCmd.checkSnAck),
         PxcFrame(cmd: PxcCmd.checkSnResult, payload: result(serial: serial(from: payload)).jsonData)]
    }
}
