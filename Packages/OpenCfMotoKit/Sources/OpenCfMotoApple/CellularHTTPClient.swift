// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AppHttp.kt (cellular pinning while the process is bound to the
// bike Wi-Fi, identifying User-Agent, response size cap).
//
// HTTP/1.1 over Network.framework pinned to the CELLULAR interface: while the phone is joined to the
// bike's Wi-Fi (no internet) the dash network may become the default route, and URLSession cannot be
// forced onto cellular (ios-platform-facts.md (b): "URLSession has no equivalent"). DTS: use
// `requiredInterfaceType = .cellular` with Network framework + a small HTTP/1.1 client + NWProtocolTLS.
//
// The HTTP/1.1 codec below (`CellularHTTP1`) is private to this adapter on purpose (independent of
// the core-nav HTTP1 codec) and Foundation-only, so it is unit-tested on Linux:
// request line + headers (Host, User-Agent, Accept-Encoding: identity, Connection: close,
// Content-Length), response status line, headers (lower-cased, duplicates joined with ", ", obs-fold),
// 1xx skipping, HEAD/204/304 without body, Transfer-Encoding: chunked (extensions + trailers),
// Content-Length, and close-delimited bodies, with a size cap.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// Minimal HTTP/1.1 client codec used by `CellularHTTPClient` (internal; exposed to tests via @testable).
enum CellularHTTP1 {
    /// Where and what to request.
    struct Target: Equatable, Sendable {
        var isTLS: Bool
        /// Host for the connection / SNI (IPv6 without brackets).
        var host: String
        var port: UInt16
        /// origin-form request target, "/path?query" (percent-encoding preserved).
        var requestTarget: String
        /// Host header value ("host" or "host:port" when not the scheme default; IPv6 bracketed).
        var hostHeader: String
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case badURL(String)
        case malformed(String)
        case tooLarge(Int)
        case truncated(String)

        var description: String {
            switch self {
            case let .badURL(m): return "bad URL: \(m)"
            case let .malformed(m): return "malformed response: \(m)"
            case let .tooLarge(n): return "Response too large (> \(n) bytes)"
            case let .truncated(m): return "truncated response: \(m)"
            }
        }
    }

    static func target(for url: URL) throws -> Target {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure.badURL(url.absoluteString)
        }
        let scheme = (c.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { throw Failure.badURL("unsupported scheme '\(scheme)'") }
        guard var host = c.host, !host.isEmpty else { throw Failure.badURL("missing host") }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let tls = scheme == "https"
        let defaultPort = tls ? 443 : 80
        let port = c.port ?? defaultPort
        guard (1 ... 65535).contains(port) else { throw Failure.badURL("bad port \(port)") }
        var target = c.percentEncodedPath
        if target.isEmpty { target = "/" }
        if !target.hasPrefix("/") { target = "/" + target }
        if let q = c.percentEncodedQuery { target += "?" + q }
        var hostHeader = host.contains(":") ? "[\(host)]" : host
        if port != defaultPort { hostHeader += ":\(port)" }
        return Target(isTLS: tls, host: host, port: UInt16(port), requestTarget: target, hostHeader: hostHeader)
    }

    /// Headers the client controls itself (caller values are ignored).
    static let controlledHeaders: Set<String> = [
        "host", "connection", "content-length", "transfer-encoding", "accept-encoding", "keep-alive", "te",
        "upgrade", "proxy-connection", "trailer",
    ]

    /// Serialises the request. Caller headers are emitted in a deterministic (case-insensitive name)
    /// order; CR/LF/NUL are stripped from values and headers with invalid names are dropped.
    static func serializeRequest(_ request: HTTPRequest, target: Target, userAgent: String?) -> Data {
        var method = sanitizeToken(request.method.uppercased())
        if method.isEmpty { method = "GET" }
        var lines = ["\(method) \(target.requestTarget) HTTP/1.1", "Host: \(target.hostHeader)"]
        var hasUserAgent = false
        for (name, value) in request.headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let n = sanitizeToken(name)
            guard !n.isEmpty, n.count == name.count else { continue }
            let lower = n.lowercased()
            if controlledHeaders.contains(lower) { continue }
            if lower == "user-agent" { hasUserAgent = true }
            lines.append("\(n): \(sanitizeValue(value))")
        }
        if !hasUserAgent, let ua = userAgent, !ua.isEmpty { lines.append("User-Agent: \(sanitizeValue(ua))") }
        lines.append("Accept-Encoding: identity")
        lines.append("Connection: close")
        let body = request.body ?? Data()
        if !body.isEmpty || ["POST", "PUT", "PATCH"].contains(method) {
            lines.append("Content-Length: \(body.count)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    /// RFC 9110 token characters only.
    static func sanitizeToken(_ s: String) -> String {
        let extra = Set("!#$%&'*+-.^_`|~")
        return String(s.filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || extra.contains($0) })
    }

    static func sanitizeValue(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Incremental HTTP/1.1 response parser.
    struct ResponseParser {
        private enum State: Equatable {
            case statusLine, headers, fixedBody(Int), chunkSize, chunkData(Int), chunkDataEnd, trailers, untilClose, done
        }

        let isHeadRequest: Bool
        let maxBodyBytes: Int
        let maxHeaderBytes: Int

        private var state: State = .statusLine
        private var line: [UInt8] = []
        private var headerBytes = 0
        private var lastHeaderName: String?
        private(set) var status = 0
        private(set) var reason = ""
        /// Lower-cased names; repeated fields joined with ", ".
        private(set) var headers: [String: String] = [:]
        private(set) var body = Data()
        /// 1xx responses skipped (100 Continue, 103 Early Hints…).
        private(set) var informationalResponsesSkipped = 0

        init(isHeadRequest: Bool = false, maxBodyBytes: Int = 24 << 20, maxHeaderBytes: Int = 64 << 10) {
            self.isHeadRequest = isHeadRequest
            self.maxBodyBytes = max(0, maxBodyBytes)
            self.maxHeaderBytes = max(256, maxHeaderBytes)
        }

        var isComplete: Bool { state == .done }

        /// The response once complete.
        var response: HTTPResponse? {
            isComplete ? HTTPResponse(status: status, headers: headers, body: body) : nil
        }

        /// Feeds received bytes; returns true once the response is complete (later bytes are ignored).
        @discardableResult
        mutating func feed(_ data: Data) throws -> Bool {
            let bytes = [UInt8](data)
            var i = 0
            while i < bytes.count {
                switch state {
                case .done:
                    return true
                case let .fixedBody(remaining):
                    let n = min(remaining, bytes.count - i)
                    body.append(contentsOf: bytes[i ..< i + n])
                    i += n
                    state = remaining == n ? .done : .fixedBody(remaining - n)
                case let .chunkData(remaining):
                    let n = min(remaining, bytes.count - i)
                    body.append(contentsOf: bytes[i ..< i + n])
                    i += n
                    state = remaining == n ? .chunkDataEnd : .chunkData(remaining - n)
                case .untilClose:
                    let n = bytes.count - i
                    if body.count + n > maxBodyBytes { throw Failure.tooLarge(maxBodyBytes) }
                    body.append(contentsOf: bytes[i...])
                    i = bytes.count
                case .statusLine, .headers, .chunkSize, .chunkDataEnd, .trailers:
                    if let nl = bytes[i...].firstIndex(of: 0x0A) {
                        line.append(contentsOf: bytes[i ..< nl])
                        i = nl + 1
                        var l = line
                        line.removeAll(keepingCapacity: true)
                        if l.last == 0x0D { l.removeLast() }
                        try handleLine(l)
                    } else {
                        line.append(contentsOf: bytes[i...])
                        i = bytes.count
                        if line.count > maxHeaderBytes { throw Failure.malformed("line too long") }
                    }
                }
            }
            return state == .done
        }

        /// Call when the peer closed the connection: completes close-delimited bodies, throws for
        /// anything incomplete.
        mutating func finishAtEOF() throws -> HTTPResponse {
            switch state {
            case .done:
                break
            case .untilClose:
                state = .done
            case .trailers:
                // "0\r\n" seen but the final CRLF never came: the body itself is complete.
                state = .done
            case .statusLine:
                throw Failure.truncated(status == 0 && line.isEmpty ? "connection closed before any response"
                    : "connection closed in the status line")
            case .headers:
                throw Failure.truncated("connection closed in the headers")
            case let .fixedBody(remaining):
                throw Failure.truncated("connection closed with \(remaining) body byte(s) missing")
            case .chunkSize, .chunkData, .chunkDataEnd:
                throw Failure.truncated("connection closed inside the chunked body")
            }
            return HTTPResponse(status: status, headers: headers, body: body)
        }

        private mutating func handleLine(_ l: [UInt8]) throws {
            switch state {
            case .statusLine:
                if l.isEmpty { return } // tolerate a stray CRLF before the status line
                try parseStatusLine(l)
                state = .headers
            case .headers:
                headerBytes += l.count + 2
                if headerBytes > maxHeaderBytes { throw Failure.malformed("headers too large") }
                if l.isEmpty {
                    try endOfHeaders()
                    return
                }
                if l.first == 0x20 || l.first == 0x09 {
                    // obs-fold: continuation of the previous field.
                    guard let name = lastHeaderName, let existing = headers[name] else {
                        throw Failure.malformed("header continuation without a field")
                    }
                    headers[name] = existing + " " + Self.trimmed(l[...])
                    return
                }
                guard let colon = l.firstIndex(of: 0x3A) else { throw Failure.malformed("header line without ':'") }
                let name = String(decoding: l[..<colon], as: UTF8.self).lowercased()
                guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else {
                    throw Failure.malformed("bad header name '\(name)'")
                }
                let value = Self.trimmed(l[(colon + 1)...])
                if let existing = headers[name] {
                    headers[name] = existing + ", " + value
                } else {
                    headers[name] = value
                }
                lastHeaderName = name
            case .chunkSize:
                var text = String(decoding: l, as: UTF8.self)
                if let semi = text.firstIndex(of: ";") { text = String(text[..<semi]) } // chunk extensions
                text = text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text.count <= 15, text.allSatisfy({ $0.isHexDigit }),
                      let size = Int(text, radix: 16) else {
                    throw Failure.malformed("bad chunk size '\(text)'")
                }
                if size == 0 {
                    state = .trailers
                    return
                }
                if body.count + size > maxBodyBytes { throw Failure.tooLarge(maxBodyBytes) }
                state = .chunkData(size)
            case .chunkDataEnd:
                guard l.isEmpty else { throw Failure.malformed("missing CRLF after chunk data") }
                state = .chunkSize
            case .trailers:
                if l.isEmpty { state = .done } // trailer fields are ignored
            default:
                break
            }
        }

        private mutating func parseStatusLine(_ l: [UInt8]) throws {
            let s = String(decoding: l, as: UTF8.self)
            guard s.hasPrefix("HTTP/") else { throw Failure.malformed("bad status line '\(s.prefix(40))'") }
            let parts = s.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1].count == 3, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let code = Int(parts[1]), code >= 100 else {
                throw Failure.malformed("bad status line '\(s.prefix(40))'")
            }
            status = code
            reason = parts.count > 2 ? String(parts[2]) : ""
        }

        private mutating func endOfHeaders() throws {
            if (100 ..< 200).contains(status) {
                if status == 101 { throw Failure.malformed("unexpected 101 Switching Protocols") }
                informationalResponsesSkipped += 1
                status = 0
                reason = ""
                headers = [:]
                lastHeaderName = nil
                headerBytes = 0
                state = .statusLine
                return
            }
            if isHeadRequest || status == 204 || status == 304 {
                state = .done
                return
            }
            if let te = headers["transfer-encoding"] {
                let codings = te.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                state = codings.last == "chunked" ? .chunkSize : .untilClose
                return
            }
            if let cl = headers["content-length"] {
                let values = Set(cl.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                guard values.count == 1, let v = values.first, !v.isEmpty, v.count <= 18,
                      v.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(v) else {
                    throw Failure.malformed("bad Content-Length '\(cl)'")
                }
                if n > maxBodyBytes { throw Failure.tooLarge(maxBodyBytes) }
                state = n == 0 ? .done : .fixedBody(n)
                return
            }
            state = .untilClose
        }

        private static func trimmed(_ bytes: ArraySlice<UInt8>) -> String {
            String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }
}
#endif

#if canImport(Network)
import Network
#if canImport(Security)
import Security
#endif

/// `HTTPClient` whose connections are forced onto the cellular interface
/// (`NWParameters.requiredInterfaceType = .cellular`), HTTPS through `NWProtocolTLS` (SNI = host,
/// ALPN http/1.1, system trust evaluation). One connection per request (`Connection: close`).
///
/// Failures: no cellular path / Cellular Data disabled for the app (`.cellularDenied`) / DNS or
/// route failure → `HTTPClientError.noNetwork` (fast, so `SmartHTTPClient` can fall back);
/// deadline (`HTTPRequest.timeout`, whole exchange) → `.timeout`; protocol/TLS problems →
/// `.invalidResponse`. Non-2xx statuses are returned, not thrown (contract).
public final class CellularHTTPClient: HTTPClient, @unchecked Sendable {
    public struct Options: @unchecked Sendable { // value type; NWInterface.InterfaceType is a plain enum
        /// `.cellular` in production; `nil` lets tests use any interface.
        public var requiredInterfaceType: NWInterface.InterfaceType?
        /// Response body cap (Android MAX_ROUTE_BYTES 24 MiB).
        public var maxResponseBytes: Int
        /// nil → `AppHTTPIdentity.userAgent` (read per request).
        public var userAgent: String?

        public init(requiredInterfaceType: NWInterface.InterfaceType? = .cellular, maxResponseBytes: Int = 24 << 20,
                    userAgent: String? = nil) {
            self.requiredInterfaceType = requiredInterfaceType
            self.maxResponseBytes = maxResponseBytes
            self.userAgent = userAgent
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let target: CellularHTTP1.Target
        do {
            target = try CellularHTTP1.target(for: request.url)
        } catch {
            throw HTTPClientError.invalidResponse("\(error)")
        }
        let payload = CellularHTTP1.serializeRequest(request, target: target,
                                                     userAgent: options.userAgent ?? AppHTTPIdentity.userAgent)
        let isHead = request.method.uppercased() == "HEAD"
        let maxBytes = options.maxResponseBytes
        let timeout = max(1, request.timeout)
        let started = Date()
        let logTarget = "\(target.host)\(target.requestTarget.split(separator: "?").first.map(String.init) ?? "")"

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        let params: NWParameters
        if target.isTLS {
            let tls = NWProtocolTLS.Options()
            if WiFiIPv4(target.host) == nil, !target.host.contains(":") {
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, target.host)
            }
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        if let t = options.requiredInterfaceType { params.requiredInterfaceType = t }
        // Cellular networks are often IPv6-only (NAT64): do not force IPv4 here.

        guard let port = NWEndpoint.Port(rawValue: target.port) else { throw HTTPClientError.invalidResponse("bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: params)
        // Any `.waiting` state means this interface cannot reach the server right now: fail fast.
        let stream = NWByteStream(connection: conn, queue: DispatchQueue(label: "ocm.http.cellular"),
                                  stopOnWaiting: { _, _ in true })
        defer { stream.close() }

        let outcome = await stream.waitUntilReady(timeout: timeout)
        guard case .ready = outcome else {
            let unsatisfied = conn.currentPath.map { $0.status != .satisfied } ?? false
            let e = Self.httpError(for: outcome, pathUnsatisfied: unsatisfied)
            Log.d("NET", "[NET] cellular \(request.method) \(logTarget) failed to connect: \(e)")
            throw e
        }

        let remaining = max(0.5, timeout - Date().timeIntervalSince(started))
        do {
            let response = try await withTimeout(remaining, label: "cellular HTTP") { () async throws -> HTTPResponse in
                try await stream.write(payload)
                var parser = CellularHTTP1.ResponseParser(isHeadRequest: isHead, maxBodyBytes: maxBytes)
                while true {
                    let chunk: Data
                    do {
                        chunk = try await stream.readSome(maxCount: 64 * 1024)
                    } catch TransportError.closed {
                        return try parser.finishAtEOF()
                    }
                    if try parser.feed(chunk), let r = parser.response { return r }
                }
            }
            Log.d("NET", "[NET] cellular \(request.method) \(logTarget) → \(response.status) (\(response.body.count) B, \(Int(Date().timeIntervalSince(started) * 1000)) ms)")
            return response
        } catch is TimeoutError {
            throw HTTPClientError.timeout
        } catch let f as CellularHTTP1.Failure {
            throw HTTPClientError.invalidResponse(f.description)
        } catch let e as TransportError {
            if Task.isCancelled { throw CancellationError() }
            switch e {
            case .timeout: throw HTTPClientError.timeout
            case .cancelled: throw CancellationError()
            default: throw HTTPClientError.invalidResponse("connection error: \(e)")
            }
        }
    }

    /// Maps a failed readiness wait. `pathUnsatisfied`: the connection's current path is not satisfied
    /// (no usable interface of the required type) — reported as `.noNetwork` even at the deadline.
    static func httpError(for outcome: OCMReadyOutcome, pathUnsatisfied: Bool = false) -> Error {
        switch outcome {
        case .ready:
            return HTTPClientError.invalidResponse("unexpected ready")
        case .cancelled:
            return CancellationError()
        case let .timedOut(_, reason):
            return (reason != nil || pathUnsatisfied) ? HTTPClientError.noNetwork : HTTPClientError.timeout
        case let .waiting(error, _), let .failed(error, _):
            if case let .tls(status) = error { return HTTPClientError.invalidResponse("TLS error \(status)") }
            if OCMNWSupport.posixCode(error) == .ETIMEDOUT { return HTTPClientError.timeout }
            // Unsatisfied path (no cellular, `.cellularDenied`), DNS failure, unreachable…
            return HTTPClientError.noNetwork
        }
    }
}
#endif
