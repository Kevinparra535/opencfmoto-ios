// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AppHttp.kt (getText/postForm/postJson: identifying User-Agent,
// per-request timeouts, response size cap).
//
// `HTTPClient` over URLSession with the system's default routing (normal Wi-Fi or cellular). Used
// when the phone is NOT joined to the bike Wi-Fi, and as the fallback of `SmartHTTPClient`.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLError → contract error mapping (Foundation-only, unit-tested on Linux).
enum SystemHTTPErrorMapping {
    /// `nil` means "cancellation" (rethrow `CancellationError`).
    static func map(_ code: URLError.Code, description: String) -> HTTPClientError? {
        switch code {
        case .cancelled:
            return nil
        case .timedOut:
            return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .callIsActive:
            return .noNetwork
        default:
            return .invalidResponse(description)
        }
    }

    /// Response headers with lower-cased names.
    static func lowercasedHeaders(_ fields: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in fields {
            guard let name = k as? String else { continue }
            out[name.lowercased()] = (v as? String) ?? "\(v)"
        }
        return out
    }
}
#endif

#if canImport(Darwin) && canImport(Foundation)

/// `HTTPClient` over `URLSession` (system routing). `HTTPRequest.timeout` bounds the whole exchange
/// (and is also the URLRequest idle timeout). Adds the identifying User-Agent unless the caller set one.
/// Non-2xx statuses are returned, not thrown (contract).
public final class SystemHTTPClient: HTTPClient, @unchecked Sendable {
    public let session: URLSession
    /// nil → `AppHTTPIdentity.userAgent` (read per request).
    public let userAgent: String?
    /// Response body cap (Android MAX_ROUTE_BYTES 24 MiB).
    public let maxResponseBytes: Int

    public init(session: URLSession = URLSession(configuration: .default), userAgent: String? = nil,
                maxResponseBytes: Int = 24 << 20) {
        self.session = session
        self.userAgent = userAgent
        self.maxResponseBytes = maxResponseBytes
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: max(1, request.timeout))
        req.httpMethod = request.method.isEmpty ? "GET" : request.method
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(userAgent ?? AppHTTPIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        }
        req.httpBody = request.body
        let session = self.session
        let cap = maxResponseBytes
        let finalRequest = req
        do {
            return try await withTimeout(max(1, request.timeout) + 0.5, label: "HTTP") { () async throws -> HTTPResponse in
                let (data, response) = try await session.data(for: finalRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw HTTPClientError.invalidResponse("not an HTTP response")
                }
                if data.count > cap { throw HTTPClientError.invalidResponse("Response too large (> \(cap) bytes)") }
                return HTTPResponse(status: http.statusCode,
                                    headers: SystemHTTPErrorMapping.lowercasedHeaders(http.allHeaderFields),
                                    body: data)
            }
        } catch is TimeoutError {
            throw HTTPClientError.timeout
        } catch let e as URLError {
            if Task.isCancelled { throw CancellationError() }
            guard let mapped = SystemHTTPErrorMapping.map(e.code, description: e.localizedDescription) else {
                throw CancellationError()
            }
            throw mapped
        }
    }
}
#endif
