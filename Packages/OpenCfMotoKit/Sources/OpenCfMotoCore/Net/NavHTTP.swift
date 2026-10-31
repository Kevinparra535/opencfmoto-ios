// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AppHttp.kt
//
// Shared HTTP policy of the map / navigation services (docs/spec/navigation-dash.md §9):
// Java-URLEncoder-compatible encoding, per-endpoint timeouts and size caps, friendly errors, and
// request builders that set the same headers as Android (`getText`, `postForm`, `postJson`).
// The User-Agent and per-host spacing are added by `ThrottledHTTPClient`.

import Foundation

/// Java `URLEncoder.encode(s, "UTF-8")`: unreserved `A–Z a–z 0–9 . - * _`, space → `+`,
/// everything else `%XX` (UTF-8 bytes, upper-case hex). Note `~` is encoded (`%7E`).
public enum FormURLEncoding {
    public static func encode(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for b in value.utf8 {
            switch b {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "_"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out.append("%")
                out.append(hexDigit(b >> 4))
                out.append(hexDigit(b & 0x0F))
            }
        }
        return out
    }

    /// Inverse of `encode` (`+` → space, `%XX` → byte). Invalid escapes are kept literally.
    public static func decode(_ value: String) -> String {
        var bytes: [UInt8] = []
        let src = Array(value.utf8)
        var i = 0
        while i < src.count {
            let b = src[i]
            if b == UInt8(ascii: "+") {
                bytes.append(0x20); i += 1
            } else if b == UInt8(ascii: "%"), i + 2 < src.count, let h = hexValue(src[i + 1]), let l = hexValue(src[i + 2]) {
                bytes.append(h << 4 | l); i += 3
            } else {
                bytes.append(b); i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexDigit(_ v: UInt8) -> Character {
        Character(Unicode.Scalar(v < 10 ? 48 + v : 55 + v))
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return c - 48
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return c - 55
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return c - 87
        default: return nil
        }
    }
}

/// Errors raised by the navigation services. `description` is the user-facing Android message.
public enum NavServiceError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Non-2xx HTTP status; `busy` = 429 or 5xx.
    case http(code: Int, message: String, busy: Bool)
    /// Body larger than the endpoint cap ("Response too large").
    case responseTooLarge
    /// Body is not the expected JSON.
    case invalidJSON(String)
    /// Service-level failure ("No route", "Route too short", OSRM `message`, …).
    case service(String)

    public var description: String {
        switch self {
        case let .http(_, message, _): return message
        case .responseTooLarge: return "Response too large"
        case let .invalidJSON(m): return m
        case let .service(m): return m
        }
    }

    public var errorDescription: String? { description }

    /// Android `AppHttp.readOrThrow` mapping of a non-2xx status.
    public static func forStatus(_ code: Int) -> NavServiceError {
        let busy = code == 429 || (500 ... 599).contains(code)
        let msg: String
        if code == 429 {
            msg = "Map service is busy (rate limited) — try again shortly"
        } else if (500 ... 599).contains(code) {
            msg = "Map service temporarily unavailable (HTTP \(code))"
        } else {
            msg = "Request failed (HTTP \(code))"
        }
        return .http(code: code, message: msg, busy: busy)
    }

    /// Best user-facing text for any error (Android `e.message ?: fallback`).
    public static func message(for error: Error, fallback: String) -> String {
        if let e = error as? NavServiceError { return e.description }
        if let e = error as? HTTPClientError { return e.description }
        if let e = error as? TimeoutError { return e.description }
        let text = String(describing: error)
        return text.isEmpty ? fallback : text
    }
}

/// Per-endpoint request policy (timeouts and response-size cap) from `AppHttp`.
public struct NavHTTPPolicy: Sendable, Equatable {
    public var connectTimeout: TimeInterval
    public var readTimeout: TimeInterval
    public var maxBytes: Int

    public init(connectTimeout: TimeInterval, readTimeout: TimeInterval, maxBytes: Int) {
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.maxBytes = maxBytes
    }

    /// Overall budget handed to `HTTPRequest.timeout` (connect + read, the closest single-deadline
    /// equivalent of Android's two socket timeouts).
    public var totalTimeout: TimeInterval { connectTimeout + readTimeout }

    public static let defaultMaxBytes = 8 * 1024 * 1024
    /// Long road routes (steps + full geometry) on OSRM / Valhalla.
    public static let maxRouteBytes = 24 * 1024 * 1024

    /// `getText` defaults (Photon, Nominatim): 10 s + 10 s, 8 MiB.
    public static let getText = NavHTTPPolicy(connectTimeout: 10, readTimeout: 10, maxBytes: defaultMaxBytes)
    /// `postForm` defaults (Overpass): 20 s + 25 s, 8 MiB.
    public static let postForm = NavHTTPPolicy(connectTimeout: 20, readTimeout: 25, maxBytes: defaultMaxBytes)
    /// `postJson` defaults: 15 s + 20 s, 8 MiB.
    public static let postJson = NavHTTPPolicy(connectTimeout: 15, readTimeout: 20, maxBytes: defaultMaxBytes)
    /// OSRM full overview: 25 s + 60 s, 24 MiB.
    public static let osrmFull = NavHTTPPolicy(connectTimeout: 25, readTimeout: 60, maxBytes: maxRouteBytes)
    /// OSRM simplified fallback: 25 s + 45 s, 24 MiB.
    public static let osrmSimplified = NavHTTPPolicy(connectTimeout: 25, readTimeout: 45, maxBytes: maxRouteBytes)
    /// Valhalla: 25 s + 60 s, 24 MiB.
    public static let valhalla = NavHTTPPolicy(connectTimeout: 25, readTimeout: 60, maxBytes: maxRouteBytes)
    /// OpenRouteService: 20 s + 35 s, 8 MiB.
    public static let ors = NavHTTPPolicy(connectTimeout: 20, readTimeout: 35, maxBytes: defaultMaxBytes)
}

/// Request builders + response checking shared by routers, search and Overpass.
public enum NavHTTP {
    public static let acceptJSON = "application/json"
    public static let acceptJSONOrGeoJSON = "application/json, application/geo+json"
    public static let formContentType = "application/x-www-form-urlencoded; charset=UTF-8"
    public static let jsonContentType = "application/json; charset=UTF-8"

    /// Android `getText`: GET with `Accept: application/json`.
    public static func getRequest(_ url: URL, policy: NavHTTPPolicy = .getText, accept: String = acceptJSON) -> HTTPRequest {
        HTTPRequest(url: url, method: "GET", headers: ["Accept": accept], body: nil, timeout: policy.totalTimeout)
    }

    /// Android `postForm`: form body, `Accept: application/json`.
    public static func postFormRequest(_ url: URL, formBody: String, policy: NavHTTPPolicy = .postForm) -> HTTPRequest {
        HTTPRequest(url: url, method: "POST",
                    headers: ["Accept": acceptJSON, "Content-Type": formContentType],
                    body: Data(formBody.utf8), timeout: policy.totalTimeout)
    }

    /// Android `postJson`: JSON body, `Accept: application/json, application/geo+json`, extra headers.
    public static func postJSONRequest(_ url: URL, json: String, policy: NavHTTPPolicy = .postJson,
                                       extraHeaders: [String: String] = [:]) -> HTTPRequest {
        var headers = ["Accept": acceptJSONOrGeoJSON, "Content-Type": jsonContentType]
        for (k, v) in extraHeaders { headers[k] = v }
        return HTTPRequest(url: url, method: "POST", headers: headers, body: Data(json.utf8), timeout: policy.totalTimeout)
    }

    /// Sends and returns the body; non-2xx → `NavServiceError.forStatus`, oversize → `.responseTooLarge`.
    public static func fetch(_ client: HTTPClient, _ request: HTTPRequest, maxBytes: Int) async throws -> Data {
        let r = try await client.send(request)
        guard r.isSuccess else { throw NavServiceError.forStatus(r.status) }
        if r.body.count > maxBytes { throw NavServiceError.responseTooLarge }
        return r.body
    }
}
