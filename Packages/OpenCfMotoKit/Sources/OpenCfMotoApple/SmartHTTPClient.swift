// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) AppHttp.kt (network choice: validated cellular first while the
// process is bound to the bike Wi-Fi, otherwise any internet network).
//
// Routes requests between the cellular-pinned client and the system (URLSession) client:
// - `preferCellular == true` (the app sets it while joined to the bike Wi-Fi, whose network has no
//   internet but may hold the default route): try `CellularHTTPClient` first, then fall back to the
//   system client on any failure except cancellation.
// - `preferCellular == false`: system client only (route planning at home over normal Wi-Fi).
// After the cellular path reports `.noNetwork` (no SIM, Cellular Data off for the app, airplane mode)
// it is skipped for `cellularRetryInterval` seconds so every tile does not pay for a failing attempt.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// Thread-safety: `final class` guarded by an NSLock.
public final class SmartHTTPClient: HTTPClient, @unchecked Sendable {
    private let cellular: any HTTPClient
    private let system: any HTTPClient
    private let clock: any MonotonicClock
    private let lock = NSLock()
    private var _preferCellular: Bool
    private var cellularSkipUntil: TimeInterval = -.infinity

    /// How long the cellular path is skipped after it reported `.noNetwork`.
    public let cellularRetryInterval: TimeInterval

    public init(cellular: any HTTPClient, system: any HTTPClient, preferCellular: Bool = false,
                cellularRetryInterval: TimeInterval = 10, clock: any MonotonicClock = SystemMonotonicClock()) {
        self.cellular = cellular
        self.system = system
        self._preferCellular = preferCellular
        self.cellularRetryInterval = cellularRetryInterval
        self.clock = clock
    }

    /// Set while the phone is joined to the bike Wi-Fi (the dash link is active).
    public var preferCellular: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _preferCellular }
        set {
            lock.lock()
            if newValue != _preferCellular { cellularSkipUntil = -.infinity }
            _preferCellular = newValue
            lock.unlock()
        }
    }

    /// True while the cellular path is being skipped after a `.noNetwork` failure.
    public var isCellularBackingOff: Bool {
        lock.lock(); defer { lock.unlock() }
        return clock.now() < cellularSkipUntil
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let useCellular = shouldTryCellular()

        var cellularError: Error?
        if useCellular {
            do {
                return try await cellular.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                cellularError = error
                if case HTTPClientError.noNetwork = error { startCellularBackOff() }
                Log.d("NET", "[NET] cellular request failed (\(error)) — falling back to system routing")
            }
        }
        do {
            return try await system.send(request)
        } catch {
            // Surface the more informative failure: a `.noNetwork` from the system path (bike Wi-Fi
            // without internet) hides less than a cellular timeout / protocol error.
            if let ce = cellularError, case HTTPClientError.noNetwork = error,
               !Self.isNoNetwork(ce), !(ce is CancellationError) {
                throw ce
            }
            throw error
        }
    }

    private func shouldTryCellular() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _preferCellular && clock.now() >= cellularSkipUntil
    }

    private func startCellularBackOff() {
        lock.lock(); defer { lock.unlock() }
        cellularSkipUntil = clock.now() + cellularRetryInterval
    }

    private static func isNoNetwork(_ e: Error) -> Bool {
        if case HTTPClientError.noNetwork = e { return true }
        return false
    }
}

#if canImport(Network) && canImport(Darwin)
extension SmartHTTPClient {
    /// Production wiring: `CellularHTTPClient()` + `SystemHTTPClient()`.
    public convenience init(preferCellular: Bool = false, userAgent: String? = nil) {
        self.init(cellular: CellularHTTPClient(options: CellularHTTPClient.Options(userAgent: userAgent)),
                  system: SystemHTTPClient(userAgent: userAgent),
                  preferCellular: preferCellular)
    }
}
#endif
#endif
