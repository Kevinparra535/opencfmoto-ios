// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Minimal HTTP/1.1 codec for the iOS cellular-pinned client (docs/spec/ios-platform-facts.md §b):
// URLSession cannot be forced onto WWAN while the phone is joined to the bike's no-internet Wi-Fi,
// so `CellularHTTPClient` (OpenCfMotoApple) opens an `NWConnection` with
// `requiredInterfaceType = .cellular` + TLS and speaks HTTP/1.1 itself using this codec:
//  - `HTTP1.serialize(_:)` writes one request with `Connection: close` and
//    `Accept-Encoding: identity` (no compression to undo);
//  - `HTTP1.ResponseParser` consumes the byte stream incrementally (status line, headers,
//    Content-Length, chunked transfer coding with trailers, or read-until-close).

import Foundation

public enum HTTP1 {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformedStatusLine(String)
        case malformedHeader(String)
        case malformedChunk(String)
        case invalidContentLength(String)
        case headersTooLarge(Int)
        case bodyTooLarge(Int)
        /// The connection closed before the message was complete.
        case unexpectedEOF

        public var description: String {
            switch self {
            case let .malformedStatusLine(l): return "malformed HTTP status line: \(l)"
            case let .malformedHeader(l): return "malformed HTTP header: \(l)"
            case let .malformedChunk(l): return "malformed chunk: \(l)"
            case let .invalidContentLength(v): return "invalid Content-Length: \(v)"
            case let .headersTooLarge(n): return "HTTP headers exceed \(n) bytes"
            case let .bodyTooLarge(n): return "Response too large (> \(n) bytes)"
            case .unexpectedEOF: return "connection closed before the response was complete"
            }
        }
    }

    // MARK: - Request

    /// Origin-form request target: percent-encoded path ("/" when empty) + "?" + query.
    public static func requestTarget(for url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: true)
        var path = comps?.percentEncodedPath ?? ""
        if path.isEmpty { path = "/" }
        if let q = comps?.percentEncodedQuery { return path + "?" + q }
        return path
    }

    /// Host header value: host (IPv6 in brackets) plus ":port" when not the scheme default.
    public static func hostHeader(for url: URL) -> String {
        var host = url.host ?? ""
        if host.contains(":") && !host.hasPrefix("[") { host = "[" + host + "]" }
        let scheme = (url.scheme ?? "http").lowercased()
        if let port = url.port {
            let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            if !isDefault { return host + ":" + String(port) }
        }
        return host
    }

    /// TCP port to connect to (explicit port, else 443 for https, else 80).
    public static func port(for url: URL) -> Int {
        if let p = url.port { return p }
        return (url.scheme ?? "").lowercased() == "https" ? 443 : 80
    }

    /// Serializes one request. Header order: Host, User-Agent, the request's own headers sorted by
    /// name (Host / Connection / Content-Length / Accept-Encoding supplied by the caller are
    /// replaced), Accept-Encoding: identity, Connection: close, Content-Length (when a body is
    /// present or the method normally carries one).
    public static func serialize(_ request: HTTPRequest, userAgent: String? = AppHTTPIdentity.userAgent) -> Data {
        let method = request.method.uppercased()
        var head = "\(method) \(requestTarget(for: request.url)) HTTP/1.1\r\n"
        head += "Host: \(hostHeader(for: request.url))\r\n"
        let reserved: Set<String> = ["host", "connection", "content-length", "accept-encoding", "transfer-encoding"]
        let hasUA = request.headers.keys.contains { $0.lowercased() == "user-agent" }
        if !hasUA, let userAgent { head += "User-Agent: \(userAgent)\r\n" }
        for key in request.headers.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            if reserved.contains(key.lowercased()) { continue }
            let value = request.headers[key] ?? ""
            head += "\(key): \(sanitize(value))\r\n"
        }
        head += "Accept-Encoding: identity\r\n"
        head += "Connection: close\r\n"
        let body = request.body ?? Data()
        if request.body != nil || ["POST", "PUT", "PATCH"].contains(method) {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    /// Strips CR/LF from header values (header injection guard).
    private static func sanitize(_ v: String) -> String {
        String(v.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }.map(Character.init))
    }

    // MARK: - Response

    /// Incremental HTTP/1.1 response parser. Feed bytes as they arrive; call `finish()` on EOF.
    public struct ResponseParser {
        private enum State: Equatable {
            case statusLine
            case headers
            case fixedBody(remaining: Int)
            case chunkSize
            case chunkData(remaining: Int)
            case chunkDataEnd
            case trailers
            case untilClose
            case complete
        }

        public let maxBodyBytes: Int
        public let maxHeaderBytes: Int
        public let isHeadRequest: Bool

        private var state: State = .statusLine
        private var buffer: [UInt8] = []
        private var pos = 0
        private var headerBytes = 0
        private var status = 0
        private var headers: [String: String] = [:]
        private var lastHeaderName: String?
        private var body: [UInt8] = []

        public init(maxBodyBytes: Int = 64 * 1024 * 1024, maxHeaderBytes: Int = 64 * 1024, isHeadRequest: Bool = false) {
            self.maxBodyBytes = maxBodyBytes
            self.maxHeaderBytes = maxHeaderBytes
            self.isHeadRequest = isHeadRequest
        }

        /// True once a complete response has been parsed.
        public var isComplete: Bool { state == .complete }

        /// The response, once complete.
        public var response: HTTPResponse? {
            isComplete ? HTTPResponse(status: status, headers: headers, body: Data(body)) : nil
        }

        /// Consumes `data`. Returns true when the response is complete (extra bytes are ignored).
        @discardableResult
        public mutating func feed(_ data: Data) throws -> Bool {
            if state == .complete { return true }
            buffer.append(contentsOf: data)
            try advance()
            compact()
            return state == .complete
        }

        /// Signals that the peer closed the connection and returns the response. A body delimited
        /// by connection close completes here; anything else incomplete throws `.unexpectedEOF`.
        public mutating func finish() throws -> HTTPResponse {
            if state == .untilClose { state = .complete }
            guard let r = response else { throw ParseError.unexpectedEOF }
            return r
        }

        private mutating func compact() {
            if pos > 0 && (pos >= 4096 || pos == buffer.count) {
                buffer.removeFirst(pos)
                pos = 0
            }
        }

        /// Next line without its CRLF / LF terminator, or nil if incomplete.
        private mutating func readLine() throws -> String? {
            var i = pos
            while i < buffer.count {
                if buffer[i] == 0x0A {
                    var end = i
                    if end > pos && buffer[end - 1] == 0x0D { end -= 1 }
                    let line = String(decoding: buffer[pos ..< end], as: UTF8.self)
                    pos = i + 1
                    return line
                }
                i += 1
            }
            if state == .statusLine || state == .headers || state == .trailers {
                if headerBytes + (buffer.count - pos) > maxHeaderBytes { throw ParseError.headersTooLarge(maxHeaderBytes) }
            }
            return nil
        }

        private mutating func appendBody(_ n: Int) throws {
            if body.count + n > maxBodyBytes { throw ParseError.bodyTooLarge(maxBodyBytes) }
            body.append(contentsOf: buffer[pos ..< pos + n])
            pos += n
        }

        private mutating func advance() throws {
            while true {
                switch state {
                case .complete:
                    return
                case .statusLine:
                    guard let line = try readLine() else { return }
                    headerBytes += line.utf8.count + 2
                    if line.isEmpty { continue } // tolerate stray CRLF before the status line
                    try parseStatusLine(line)
                    headers = [:]
                    lastHeaderName = nil
                    state = .headers
                case .headers:
                    guard let line = try readLine() else { return }
                    headerBytes += line.utf8.count + 2
                    if headerBytes > maxHeaderBytes { throw ParseError.headersTooLarge(maxHeaderBytes) }
                    if line.isEmpty {
                        try beginBody()
                    } else {
                        try parseHeaderLine(line)
                    }
                case let .fixedBody(remaining):
                    let n = min(remaining, buffer.count - pos)
                    if n == 0 { return }
                    try appendBody(n)
                    state = remaining - n == 0 ? .complete : .fixedBody(remaining: remaining - n)
                case .chunkSize:
                    guard let line = try readLine() else { return }
                    let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
                        .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    guard !sizeText.isEmpty, let size = Int(sizeText, radix: 16), size >= 0 else {
                        throw ParseError.malformedChunk(line)
                    }
                    if size == 0 {
                        state = .trailers
                    } else {
                        if body.count + size > maxBodyBytes { throw ParseError.bodyTooLarge(maxBodyBytes) }
                        state = .chunkData(remaining: size)
                    }
                case let .chunkData(remaining):
                    let n = min(remaining, buffer.count - pos)
                    if n == 0 { return }
                    try appendBody(n)
                    state = remaining - n == 0 ? .chunkDataEnd : .chunkData(remaining: remaining - n)
                case .chunkDataEnd:
                    guard let line = try readLine() else { return }
                    if !line.isEmpty { throw ParseError.malformedChunk("missing CRLF after chunk data") }
                    state = .chunkSize
                case .trailers:
                    guard let line = try readLine() else { return }
                    if line.isEmpty { state = .complete } else {
                        // Trailer fields are folded into the headers (lower-cased names).
                        try? parseHeaderLine(line)
                    }
                case .untilClose:
                    let n = buffer.count - pos
                    if n == 0 { return }
                    try appendBody(n)
                }
            }
        }

        private mutating func parseStatusLine(_ line: String) throws {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].uppercased().hasPrefix("HTTP/"),
                  parts[1].count == 3, let code = Int(parts[1]) else {
                throw ParseError.malformedStatusLine(line)
            }
            status = code
        }

        private mutating func parseHeaderLine(_ line: String) throws {
            if let f = line.unicodeScalars.first, f == " " || f == "\t" {
                // obs-fold continuation
                guard let name = lastHeaderName else { throw ParseError.malformedHeader(line) }
                headers[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                return
            }
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformedHeader(line) }
            let name = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { throw ParseError.malformedHeader(line) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
            lastHeaderName = name
        }

        private mutating func beginBody() throws {
            if (100 ..< 200).contains(status) && status != 101 {
                // Interim response (100 Continue / 103 Early Hints): the real one follows.
                state = .statusLine
                return
            }
            if isHeadRequest || status == 204 || status == 304 || status == 101 {
                state = .complete
                return
            }
            if let te = headers["transfer-encoding"]?.lowercased(),
               te.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) == "chunked" {
                state = .chunkSize
                return
            }
            if let cl = headers["content-length"] {
                // Duplicates were joined with ", "; they must agree.
                let values = Set(cl.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                guard values.count == 1, let v = values.first, let n = Int(v), n >= 0 else {
                    throw ParseError.invalidContentLength(cl)
                }
                if n > maxBodyBytes { throw ParseError.bodyTooLarge(maxBodyBytes) }
                state = n == 0 ? .complete : .fixedBody(remaining: n)
                return
            }
            state = .untilClose
        }
    }

    /// Parses a complete response held in memory (the connection is assumed closed after it).
    public static func parseResponse(_ data: Data, maxBodyBytes: Int = 64 * 1024 * 1024,
                                     isHeadRequest: Bool = false) throws -> HTTPResponse {
        var p = ResponseParser(maxBodyBytes: maxBodyBytes, isHeadRequest: isHeadRequest)
        if try p.feed(data), let r = p.response { return r }
        return try p.finish()
    }
}
