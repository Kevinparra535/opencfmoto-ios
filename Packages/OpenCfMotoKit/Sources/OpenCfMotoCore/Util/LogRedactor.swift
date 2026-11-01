// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) LogRedactor.kt
//
// Strips secrets from log lines (session-network.md §9.2, app-features.md §6.2). The four Android
// regexes are applied verbatim, in order, case-insensitive (ICU, like Android's java.util.regex):
//   1 JSON secrets   ("(?:password|pwd|passphrase|psk|btPin)"\s*:\s*)"[^"]*"   → $1"«redacted»"
//   2 URL/kv secrets \b(pwd|password|psk|passphrase)=([^&\s"]*)                → $1=«redacted»
//   3 JSON serials   ("(?:HUID|sn|uuid|carHuid)"\s*:\s*)"([^"]*)"              → $1"<maskTail>"
//   4 bare serials   \b(carHuid|HUID|sn)=([A-Za-z0-9]{6,})                     → $1=<maskTail>
// iOS addition (fixes the Android GAP): pairing QRs in a line are also PARSED and their Wi-Fi password
// masked in every format (Moto Morini `Wifi=SSID#PWD#…` and Kove/Thinkerride `?SSID&PWD&ap=1` leak
// through the regexes on Android). SSIDs and model ids are kept on purpose.
// iOS addition (review SEC-2): API keys in URL query parameters — custom tile servers put a billable
// key there (MapTiler `?key=`, Thunderforest `?apikey=`, Stadia `?api_key=`, Mapbox `?access_token=`,
// any `?token=`):  [?&](key|apikey|api_key|access_token|token)=([^&\s"]*)  → `<sep>$1=«redacted»`.
// Anchored on `?` / `&` so plain `token=<n>` fields of the PXC logs stay readable. `redact` stays
// byte-identical to Android; `redactAll` (what the app installs) applies the iOS additions.

import Foundation

public enum LogRedactor {
    /// `«redacted»` (U+00AB … U+00BB).
    public static let mask = "\u{00AB}redacted\u{00BB}"

    private static func make(_ pattern: String) -> NSRegularExpression {
        // Constant patterns; a failure would be a programming error.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let jsonSecret = make(#"("(?:password|pwd|passphrase|psk|btPin)"\s*:\s*)"[^"]*""#)
    private static let urlSecret = make(#"\b(pwd|password|psk|passphrase)=([^&\s"]*)"#)
    private static let jsonSerial = make(#"("(?:HUID|sn|uuid|carHuid)"\s*:\s*)"([^"]*)""#)
    private static let bareSerial = make(#"\b(carHuid|HUID|sn)=([A-Za-z0-9]{6,})"#)
    private static let qrStart = make(#"(https?://|CQKY_|Wifi=)"#)
    private static let urlApiKey = make(#"([?&])(key|apikey|api_key|access_token|token)=([^&\s"]*)"#)

    /// Android `LogRedactor.redact`: the four regex rules only (byte-identical results).
    public static func redact(_ line: String) -> String {
        var s = line
        s = replace(jsonSecret, in: s) { m, str in group(m, 1, str) + "\"" + mask + "\"" }
        s = replace(urlSecret, in: s) { m, str in group(m, 1, str) + "=" + mask }
        s = replace(jsonSerial, in: s) { m, str in group(m, 1, str) + "\"" + maskTail(group(m, 2, str)) + "\"" }
        s = replace(bareSerial, in: s) { m, str in group(m, 1, str) + "=" + maskTail(group(m, 2, str)) }
        return s
    }

    /// iOS redaction: the Android rules, URL API keys, then parse-based masking of pairing-QR passwords.
    public static func redactAll(_ line: String) -> String {
        redactQRPasswords(redactURLAPIKeys(redact(line)))
    }

    /// Masks `key` / `apikey` / `api_key` / `access_token` / `token` URL query parameters (review SEC-2).
    public static func redactURLAPIKeys(_ line: String) -> String {
        replace(urlApiKey, in: line) { m, str in group(m, 1, str) + group(m, 2, str) + "=" + mask }
    }

    /// Masks the Wi-Fi password of every pairing QR found in `line` (any `BikeQR` format): each
    /// candidate starting at `http(s)://`, `CQKY_` or `Wifi=` is parsed (to the end of the line, then
    /// to the next whitespace) and the occurrences of its password — verbatim, Android `Uri.encode`d
    /// or form-encoded — that form a whole QR field (preceded by start / `& # ? =` / whitespace and
    /// followed by end / `& #` / whitespace) after the candidate start are replaced with `«redacted»`.
    public static func redactQRPasswords(_ line: String) -> String {
        var s = line
        var searchFrom = 0
        while true {
            let ns = NSString(string: s)
            guard searchFrom < ns.length,
                  let m = qrStart.firstMatch(in: s, options: [], range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            else { break }
            let start = m.range.location
            let rest = ns.substring(from: start)
            var password: String?
            if let q = BikeQR.parse(rest), !q.password.isEmpty {
                password = q.password
            } else if let token = rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
                      let q = BikeQR.parse(token), !q.password.isEmpty {
                password = q.password
            }
            if let pwd = password, pwd != mask {
                var region = rest
                let encoded = AppJvmText.androidUriEncode(pwd)
                let variants = Set([pwd, encoded, encoded.replacingOccurrences(of: "%20", with: "+")])
                for v in variants.sorted(by: { $0.utf16.count > $1.utf16.count }) where !v.isEmpty {
                    region = replaceField(v, in: region)
                }
                s = ns.substring(to: start) + region
            }
            searchFrom = start + m.range.length
        }
        return s
    }

    /// Replaces occurrences of `value` in `text` that form a whole QR field with the mask.
    private static func replaceField(_ value: String, in text: String) -> String {
        let t = Array(text.utf16), v = Array(value.utf16)
        guard !v.isEmpty, v.count <= t.count else { return text }
        func isBefore(_ u: UInt16) -> Bool { u == 0x26 || u == 0x23 || u == 0x3F || u == 0x3D || u == 0x20 || u == 0x09 }
        func isAfter(_ u: UInt16) -> Bool { u == 0x26 || u == 0x23 || u == 0x20 || u == 0x09 }
        var out: [UInt16] = []
        out.reserveCapacity(t.count)
        let maskUnits = Array(mask.utf16)
        var i = 0
        while i < t.count {
            if i + v.count <= t.count, t[i ..< i + v.count].elementsEqual(v),
               i == 0 || isBefore(t[i - 1]),
               i + v.count == t.count || isAfter(t[i + v.count]) {
                out.append(contentsOf: maskUnits)
                i += v.count
            } else {
                out.append(t[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// `maskTail(v)`: `v` if ≤ 4 UTF-16 units, else the first 4 + `…` + `*` × min(len − 4, 8).
    public static func maskTail(_ v: String) -> String {
        let units = Array(v.utf16)
        if units.count <= 4 { return v }
        return String(decoding: units[0 ..< 4], as: UTF16.self) + "\u{2026}" + String(repeating: "*", count: min(units.count - 4, 8))
    }

    /// Installs the iOS redactor on a log bus (`Log.redactor`, applied on export). With
    /// `includeSecrets` ("Include secrets in shared logs") the redactor is removed.
    public static func install(on log: Log = .shared, includeSecrets: Bool = false) {
        if includeSecrets {
            log.redactor = nil
        } else {
            log.redactor = { @Sendable (line: String) -> String in LogRedactor.redactAll(line) }
        }
    }

    // MARK: - Regex helpers

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: NSString) -> String {
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : s.substring(with: r)
    }

    /// Kotlin `Regex.replace(input) { transform }`: non-overlapping matches, literal replacements.
    private static func replace(_ re: NSRegularExpression, in s: String,
                                _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = NSString(string: s)
        let matches = re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform(m, ns)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
