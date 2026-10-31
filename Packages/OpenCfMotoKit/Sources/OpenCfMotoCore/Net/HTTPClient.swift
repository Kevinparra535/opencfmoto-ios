// SPDX-License-Identifier: AGPL-3.0-or-later
// Minimal HTTP abstraction for routing / search / tiles / speed-limit lookups.
// On iOS the implementation prefers the CELLULAR interface while the phone is joined to the
// bike's Wi-Fi (which has no internet) — see OpenCfMotoApple/CellularHTTPClient.swift.

import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 15) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200 ..< 300).contains(status) }
    public var bodyString: String { String(decoding: body, as: UTF8.self) }
}

public enum HTTPClientError: Error, Equatable, CustomStringConvertible {
    case badStatus(Int, String)
    case invalidResponse(String)
    case noNetwork
    case timeout

    public var description: String {
        switch self {
        case let .badStatus(code, snippet): return "HTTP \(code): \(snippet)"
        case let .invalidResponse(m): return "invalid HTTP response: \(m)"
        case .noNetwork: return "no internet connection"
        case .timeout: return "request timed out"
        }
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public extension HTTPClient {
    /// GET returning the body; throws `HTTPClientError.badStatus` for non-2xx.
    func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> Data {
        let r = try await send(HTTPRequest(url: url, headers: headers, timeout: timeout))
        guard r.isSuccess else { throw HTTPClientError.badStatus(r.status, String(r.bodyString.prefix(200))) }
        return r.body
    }
}

/// Shared identification sent to public OSM-based services (their usage policies require a
/// descriptive User-Agent with contact info).
public enum AppHTTPIdentity {
    public static var appVersion = "0.1.0"
    public static var userAgent: String {
        "OpenCfMoto-iOS/\(appVersion) (moto dash map; +https://github.com/Kevinparra535/opencfmoto-ios)"
    }
}
