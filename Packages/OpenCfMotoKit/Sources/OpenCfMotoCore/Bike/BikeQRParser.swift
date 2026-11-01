// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) QrData.kt
//
// Pairing-QR parser (docs/spec/session-network.md §2): formats A–F, failure hints and the manual
// SSID/password entry URL. Behaviour is byte-exact with the Android app, including its Kotlin/JVM
// string semantics (Kotlin `trim`, Android `URLDecoder`, `Uri.encode`, ICU regexes).

import Foundation

public extension BikeQR {

    // MARK: - Parse

    /// Parses a scanned pairing QR (or a manual-entry URL). Returns nil when no format matches.
    ///
    /// Formats, tried in order on the Kotlin-trimmed text (which also becomes `raw`):
    /// - **A/B** Carbit / EasyConnect URL query (`ssid`, `pwd`, `action`, `mac`/`bm`, `name`, `modelid`, `sn`,
    ///   `auth`, `channel`); phone-hotspot QRs (`action=128` or `bm=` without `ssid`) get a synthesized
    ///   `PHONE-HOTSPOT-xxxxxx` SSID.
    /// - **C** bare `CARBIT` + 12 hex digits token (phone hotspot).
    /// - **D** Moto Morini / MotoFun `Wifi=SSID#PWD#MAC`.
    /// - **E** Kove / Thinkerride positional `?SSID&PWD&ap=1` (or a bare `CQKY_…&…&ap=1`).
    /// - **F** manual entry: see `manualPairingURL(ssid:password:displayName:)` (parses as format A).
    static func parse(_ raw: String) -> BikeQR? {
        let t = AppJvmText.trim(raw)
        if t.isEmpty { return nil }
        if let q = parseCarbit(t) { return q }
        if let q = parseCarbitToken(t) { return q }
        if let q = parseMotoMorini(t) { return q }
        if let q = parseThinkerride(t) { return q }
        return nil
    }

    /// Normalises a MAC like Android `QrData.formatMac`: 12 hex digits (separators ignored) →
    /// `"aa:bb:cc:dd:ee:ff"`; otherwise the input is returned UNCHANGED if it contains `:` and is at
    /// least 11 UTF-16 units long, else nil. Blank/nil → nil.
    static func formatMac(_ raw: String?) -> String? {
        guard let raw, !AppJvmText.isBlank(raw) else { return nil }
        var hex: [UInt16] = []
        for u in raw.utf16 {
            let isHexLetter = (u >= 0x61 && u <= 0x66) || (u >= 0x41 && u <= 0x46)
            if isHexLetter || AppJvmText.decimalDigit(u) != nil { hex.append(u) }
        }
        if hex.count != 12 {
            return (raw.unicodeScalars.contains(":") && AppJvmText.utf16Length(raw) >= 11) ? raw : nil
        }
        var pairs: [String] = []
        var i = 0
        while i < 12 {
            pairs.append(String(decoding: hex[i ..< i + 2], as: UTF16.self).lowercased())
            i += 2
        }
        return pairs.joined(separator: ":")
    }

    // MARK: - Failure hints

    /// Why a scan that `parse` rejected is not a pairing QR — verbatim Android strings (`QrData.kt:240-268`),
    /// first match wins; nil → generic "Invalid QR". Only meaningful when `parse` returned nil.
    static func failureHint(for raw: String) -> String? {
        let t = AppJvmText.trim(raw)
        let has = { (needle: String) in AppJvmText.containsIgnoreCase(t, needle) }
        if has("motomorini.com") && !has("Wifi=") {
            return QRHintText.moriniNoWifi
        }
        if AppJvmText.containsMatch(QRRegex.vehicleInfo, t) || (has("color:") && has("vin:")) {
            return QRHintText.vehicleInfo
        }
        if has("carbit.com") && has("downsdk") {
            return QRHintText.carbitDownload
        }
        if has("carbit.com") && !has("ssid=") && (has("action=128") || has("bm=")) {
            return QRHintText.phoneHotspot
        }
        if AppJvmText.containsMatch(QRRegex.carbitTokenFind, t) {
            return QRHintText.carbitToken
        }
        if has("thinkerride.com") || (has("kove") && has("download")) || has("KOVE APP") {
            return QRHintText.thinkerride
        }
        if AppJvmText.startsWithIgnoreCase(t, "http") && !has("ssid=") && !has("Wifi=") {
            return QRHintText.urlWithoutCredentials
        }
        return nil
    }

    /// `failureHint(for:)` reworded for iPhone users: the two phone-hotspot hints (the dash joins the
    /// PHONE's hotspot) become `iosPhoneHotspotUnsupportedHint` — the iPhone app has no such transport
    /// (session-network.md §11.11 is not implemented), so "turn on the hotspot, then Connect" would be a
    /// dead end. Other hints are unchanged ("Android hotspot" → "Personal Hotspot" otherwise).
    static func iosFailureHint(for raw: String) -> String? {
        guard let hint = failureHint(for: raw) else { return nil }
        if hint == QRHintText.phoneHotspot || hint == QRHintText.carbitToken { return iosPhoneHotspotUnsupportedHint }
        return hint.replacingOccurrences(of: "Android hotspot", with: "Personal Hotspot")
    }

    /// Shown (EN; the app localizes it) for dashes that join the phone's hotspot instead of offering
    /// their own Wi-Fi (Carbit `action=128` / `bm=` / `CARBIT…` QRs) — at pairing and at Connect.
    static let iosPhoneHotspotUnsupportedHint =
        "This dash joins the phone's hotspot instead of offering its own Wi-Fi \u{2014} OpenCfMoto can't connect that way on iPhone yet. If the dash can show a Wi-Fi QR with an SSID and password, scan that one."

    /// The QR only offers the phone-hotspot transport: no SoftAP credentials (synthetic
    /// `PHONE-HOTSPOT-xxxxxx` SSID, empty password). Such a bike cannot be joined from an iPhone.
    var requiresPhoneHotspot: Bool { supportsPhoneHotspot && password.isEmpty }

    // MARK: - Manual entry (format F)

    /// The synthetic pairing URL Android builds for dashes that show SSID + password instead of a QR
    /// (`QrData.buildManual`, Android `Uri.Builder`):
    /// `http://manual.opencfmoto.local/?ssid=…&pwd=…&auth=wpa2-psk&action=1&name=…`.
    /// The SSID and display name are Kotlin-trimmed; the password is kept verbatim. Values are encoded
    /// with Android `Uri.encode` semantics. Returns nil when the SSID or password is empty.
    static func manualPairingURL(ssid: String, password: String, displayName: String? = nil) -> String? {
        let s = AppJvmText.trim(ssid)
        let p = password
        if s.isEmpty || p.isEmpty { return nil }
        let trimmedName = displayName.map(AppJvmText.trim) ?? ""
        let name = trimmedName.isEmpty ? s : trimmedName
        let enc = AppJvmText.androidUriEncode
        return "http://manual.opencfmoto.local/?ssid=\(enc(s))&pwd=\(enc(p))&auth=wpa2-psk&action=1&name=\(enc(name))"
    }

    /// Builds the manual-entry URL and parses it back (so manual bikes are stored exactly like
    /// scanned ones). `raw` of the result is the synthetic URL.
    static func buildManual(ssid: String, password: String, displayName: String? = nil) -> BikeQR? {
        guard let url = manualPairingURL(ssid: ssid, password: password, displayName: displayName) else { return nil }
        return parse(url)
    }

    // MARK: - Log lines (no secrets)

    /// Android's parse log line (MainActivity.kt) — contains no password:
    /// `QR parsed: ssid=… mac=… action=… (ap=…, p2p=…, hotspot=…) modelId=… sn=…` (nil → `null`).
    /// iOS never logs the raw QR (session-network.md §9.2); log this instead.
    var parsedLogLine: String {
        "QR parsed: ssid=\(ssid) mac=\(mac ?? "null") action=\(action) "
            + "(ap=\(supportsAp), p2p=\(supportsP2p), hotspot=\(supportsPhoneHotspot)) "
            + "modelId=\(modelId ?? "null") sn=\(sn ?? "null")"
    }

    /// Android's failure log line: `QR parse FAILED — missing ssid/pwd?[ (<hint>)]`.
    static func parseFailedLogLine(for raw: String) -> String {
        "QR parse FAILED \u{2014} missing ssid/pwd?" + (failureHint(for: raw).map { " (\($0))" } ?? "")
    }

    // MARK: - Formats (private)

    /// Query map from a URL (text after the first `?`, cut at the first `#`). Keys lower-cased,
    /// values form-decoded (raw value kept when the decoder throws); last duplicate wins.
    private static func queryParams(_ raw: String) -> [String: String] {
        let query = AppJvmText.substringBefore(AppJvmText.substringAfter(raw, "?", missing: ""), "#")
        if query.isEmpty { return [:] }
        var out: [String: String] = [:]
        for part in AppJvmText.split(query, "&") where !part.isEmpty {
            let (key, value) = AppJvmText.splitAtFirstEquals(part)
            if key.isEmpty { continue }
            let v = value ?? ""
            out[key.lowercased()] = AppJvmText.androidURLDecode(v) ?? v
        }
        return out
    }

    /// Format A (Carbit / EasyConnect) and B (phone hotspot).
    private static func parseCarbit(_ raw: String) -> BikeQR? {
        let q = queryParams(raw)
        let action = q["action"].flatMap(AppJvmText.toIntOrNull) ?? 0
        let mac = formatMac(q["mac"]) ?? formatMac(q["bm"])
        let ssid = AppJvmText.trim(q["ssid"] ?? "")
        let pwd = q["pwd"] ?? ""
        let phoneHotspot = (action & 128) != 0 || (ssid.isEmpty && mac != nil && q["bm"] != nil)
        if ssid.isEmpty && !phoneHotspot { return nil }
        if !ssid.isEmpty && pwd.isEmpty && !phoneHotspot { return nil }
        let display: String?
        if let n = q["name"], !AppJvmText.isBlank(n) {
            display = n
        } else if !ssid.isEmpty {
            display = nil
        } else {
            display = mac.map { "Phone hotspot (\(AppJvmText.takeLastUTF16($0, 8)))" }
        }
        let finalSsid = ssid.isEmpty
            ? "PHONE-HOTSPOT-" + AppJvmText.takeLastUTF16((mac ?? "").replacingOccurrences(of: ":", with: ""), 6)
            : ssid
        return BikeQR(
            raw: raw,
            ssid: finalSsid,
            password: pwd,
            auth: q["auth"],
            mac: mac,
            name: display,
            action: (phoneHotspot && (action & 128) == 0) ? (action | 128) : action,
            modelId: q["modelid"],
            sn: q["sn"],
            channel: q["channel"]
        )
    }

    /// Format C: `CARBIT` + 12 hex digits (case preserved in the synthesized SSID).
    private static func parseCarbitToken(_ raw: String) -> BikeQR? {
        guard let m = AppJvmText.matchEntire(QRRegex.carbitToken, raw),
              let hex = AppJvmText.group(m, 1, in: raw),
              let mac = formatMac(hex) else { return nil }
        return BikeQR(
            raw: raw,
            ssid: "PHONE-HOTSPOT-" + AppJvmText.takeLastUTF16(hex, 6),
            password: "",
            auth: nil,
            mac: mac,
            name: "Phone hotspot (\(AppJvmText.takeLastUTF16(mac, 8)))",
            action: 128,
            modelId: nil,
            sn: nil,
            channel: nil
        )
    }

    /// Format D: Moto Morini / MotoFun (`Wifi=SSID#PWD#MAC&MachineID=…&ProductID=…`).
    private static func parseMotoMorini(_ raw: String) -> BikeQR? {
        guard let wifi = AppJvmText.firstMatch(QRRegex.moriniWifi, in: raw),
              let ssidGroup = AppJvmText.group(wifi, 1, in: raw) else { return nil }
        let ssid = AppJvmText.trim(ssidGroup)
        if ssid.isEmpty { return nil }
        let after = AppJvmText.substringFromUTF16(raw, wifi.range.location + wifi.range.length)
        guard after.unicodeScalars.first == "#" else { return nil }
        let hashParts = AppJvmText.split2(String(Substring(after.unicodeScalars.dropFirst())), "#")
        let pwd = AppJvmText.trim(AppJvmText.substringBefore(hashParts[0], "&"))
        if pwd.isEmpty { return nil }
        var macToken: String?
        if hashParts.count > 1 {
            let token = AppJvmText.trim(AppJvmText.substringBefore(hashParts[1], "&"))
            macToken = token.isEmpty ? nil : token
        }
        let machineId = AppJvmText.firstMatch(QRRegex.moriniMachineId, in: raw).flatMap { AppJvmText.group($0, 1, in: raw) }
        let productId = AppJvmText.firstMatch(QRRegex.moriniProductId, in: raw).flatMap { AppJvmText.group($0, 1, in: raw) }
        return BikeQR(
            raw: raw,
            ssid: ssid,
            password: pwd,
            auth: "wpa2-psk",
            mac: formatMac(macToken) ?? formatMac(machineId),
            name: ssid,
            action: 1,
            modelId: productId,
            sn: machineId,
            channel: nil
        )
    }

    /// Format E: Kove / Thinkerride SoftAP (positional or `ssid=`/`pwd=` query).
    private static func parseThinkerride(_ raw: String) -> BikeQR? {
        let trimmed = AppJvmText.trim(raw)
        let looksThinker = AppJvmText.containsIgnoreCase(trimmed, "thinkerride.com")
            || AppJvmText.containsMatch(QRRegex.cqkyToken, trimmed)
        if !looksThinker { return nil }
        let query: String
        if trimmed.unicodeScalars.contains("?") {
            query = AppJvmText.substringBefore(AppJvmText.substringAfter(trimmed, "?", missing: trimmed), "#")
        } else if AppJvmText.containsMatch(QRRegex.cqkyPrefix, trimmed) {
            query = AppJvmText.substringBefore(trimmed, "#")
        } else {
            return nil
        }
        if AppJvmText.isBlank(query) { return nil }
        var ssid: String?
        var pwd: String?
        for part in AppJvmText.split(query, "&") where !part.isEmpty {
            let (rawKey, rawValue) = AppJvmText.splitAtFirstEquals(part)
            if let rawValue {
                let key = AppJvmText.trim(rawKey).lowercased()
                let value = AppJvmText.trim(AppJvmText.androidURLDecode(rawValue) ?? rawValue)
                switch key {
                case "ssid": if !value.isEmpty { ssid = value }
                case "pwd", "password", "pass": if !value.isEmpty { pwd = value }
                default: break // "ap" flag and unknown keys are ignored
                }
            } else {
                let token = AppJvmText.trim(AppJvmText.androidURLDecode(part) ?? part)
                if token.isEmpty || AppJvmText.equalsIgnoreCase(token, "ap") { continue }
                if ssid == nil { ssid = token } else if pwd == nil { pwd = token }
            }
        }
        let s = AppJvmText.trim(ssid ?? "")
        let p = pwd ?? ""
        if s.isEmpty || p.isEmpty { return nil }
        return BikeQR(raw: raw, ssid: s, password: p, auth: "wpa2-psk", mac: nil, name: s, action: 1,
                      modelId: nil, sn: nil, channel: nil)
    }
}

/// Compiled ICU regexes (same engine and patterns as Android's `java.util.regex`).
private enum QRRegex {
    private static func make(_ pattern: String) -> NSRegularExpression {
        // Patterns are constants; failure would be a programming error.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    static let carbitToken = make(#"(?i)^CARBIT([0-9A-F]{12})$"#)
    static let carbitTokenFind = make(#"(?i)^CARBIT[0-9A-F]{12}$"#)
    static let moriniWifi = make(#"(?i)(?:^|[?&])Wifi=([^&#\s]+)"#)
    static let moriniMachineId = make(#"(?i)MachineID=([^&#\s]+)"#)
    static let moriniProductId = make(#"(?i)ProductID=([^&#\s]+)"#)
    static let cqkyToken = make(#"(?i)^CQKY_[^\s&]+&"#)
    static let cqkyPrefix = make(#"(?i)^CQKY_"#)
    static let vehicleInfo = make(#"(?i)^code:.*engine:.*vin:"#)
}

/// Verbatim Android hint strings (`QrData.kt:240-268`).
private enum QRHintText {
    static let moriniNoWifi =
        "Moto Morini QR has no Wifi= field \u{2014} open the phone-link / MotoFun QR on the dash"
    static let vehicleInfo =
        "that QR is bike info (color/VIN), not Wi\u{2011}Fi pairing \u{2014} open MotoPlay / EasyConnect / MotoFun QR"
    static let carbitDownload =
        "that is the Carbit app-download QR, not pairing \u{2014} open MotoPlay / EasyConnect so the Wi-Fi QR (SSID + password) stays on screen"
    static let phoneHotspot =
        "this dash joins your phone hotspot \u{2014} turn on Android hotspot with the SSID/password shown on the dash, then Connect"
    static let carbitToken =
        "Carbit ID QR \u{2014} enable Android hotspot with the SSID/password on the dash, then Connect"
    static let thinkerride =
        "Kove/Thinkerride \u{2014} need the SoftAP pairing QR (SSID+password on the dash, or g.thinkerride.com?SSID&PWD&ap=1). Garage \u{2192} enter SSID/pwd if the QR is only \u{201C}download KOVE APP\u{201D}"
    static let urlWithoutCredentials =
        "URL QR without ssid/pwd \u{2014} need the dash pairing QR (Carbit / EasyConnect / MotoFun / Thinkerride SoftAP), or enable phone hotspot if the dash asks for it"
}
