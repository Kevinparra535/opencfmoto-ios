// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnDiscovery.kt (discoverNsd / endpointFrom / readTxt /
// isUsableBikeIpv4).
//
// Bonjour discovery of the dash's EasyConn endpoint (`_EasyConn._tcp`). Some SoftAP dashes (Morini
// ML*) ignore the classic :10930 wake probe but advertise this service; CFDL16 dashes advertise it
// with TXT `huid, huname, channel, flavor, port, ip`; others (450NK) advertise nothing — so Bonjour
// is only an accelerator raced against `gateway:10930` (control-plane.md §18.5).
//
// Requires `NSBonjourServices = [_EasyConn._tcp]` and `NSLocalNetworkUsageDescription` in the APP
// Info.plist; browsing is a Local Network operation (DNS-SD reports kDNSServiceErr_PolicyDenied
// −65570 when denied). No multicast entitlement is needed.

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore

/// Pure helpers for `_EasyConn._tcp` TXT records.
public enum EasyConnTXT {
    /// Service type browsed for (Android `SERVICE_TYPE = "_EasyConn._tcp."`).
    public static let serviceType = "_EasyConn._tcp"

    /// Case-insensitive TXT lookup (exact key first, like Android `readTxt`), trimmed, blank → nil.
    public static func value(_ txt: [String: String], _ key: String) -> String? {
        let raw = txt[key] ?? txt.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value
        guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    /// The companion package advertised by the dash (logged only): `packagename`, `packageName`, `package`.
    public static func packageName(_ txt: [String: String]) -> String? {
        value(txt, "packagename") ?? value(txt, "packageName") ?? value(txt, "package")
    }

    /// Endpoint from the TXT `ip` / `port` keys when both are present and usable (IPv4 that is not
    /// loopback/any/multicast, port 1…65535). Android ignores these keys; iOS uses them to skip a
    /// resolve round-trip.
    public static func endpoint(_ txt: [String: String]) -> (host: String, port: UInt16)? {
        guard let ipText = value(txt, "ip"), let ip = WiFiIPv4(ipText), ip.isUsableDashAddress,
              let portText = value(txt, "port"), let p = Int(portText), (1 ... 65535).contains(p) else { return nil }
        return (ip.description, UInt16(p))
    }

    /// Android `endpointFrom` acceptance: IPv4, usable, port 1…65535.
    public static func isUsable(host: String, port: Int) -> Bool {
        guard (1 ... 65535).contains(port), let ip = WiFiIPv4(host) else { return false }
        return ip.isUsableDashAddress
    }
}
#endif

#if canImport(Network)
import Network

/// `DashDiscovery` over `NWBrowser(.bonjourWithTXTRecord(type: "_EasyConn._tcp"))`.
///
/// For each service: if its TXT carries a usable `ip` + `port`, that endpoint is used directly;
/// otherwise the service endpoint is resolved by opening a short TCP `NWConnection` to it (IPv4,
/// Wi-Fi) and reading `currentPath.remoteEndpoint`, then closing it. `discover(timeout:)` returns as
/// soon as the first usable endpoint is known (Android: "first service that resolves to a usable
/// IPv4:port"), or after `timeout` with whatever was found (possibly nothing).
public final class BonjourDashDiscovery: DashDiscovery, @unchecked Sendable {
    public let serviceType: String
    public let requiredInterfaceType: NWInterface.InterfaceType?
    /// Upper bound for one resolve connection.
    public let resolveTimeout: TimeInterval

    private let lock = NSLock()
    private var _lastBrowseDenied = false

    public init(serviceType: String = EasyConnTXT.serviceType, requiredInterfaceType: NWInterface.InterfaceType? = .wifi,
                resolveTimeout: TimeInterval = 3) {
        self.serviceType = serviceType
        self.requiredInterfaceType = requiredInterfaceType
        self.resolveTimeout = resolveTimeout
    }

    /// True when the most recent browse was refused by Local Network privacy.
    public var lastBrowseDenied: Bool { lock.lock(); defer { lock.unlock() }; return _lastBrowseDenied }

    public func discover(timeout: TimeInterval) async -> [DiscoveredDash] {
        let session = BonjourBrowseSession(serviceType: serviceType, interface: requiredInterfaceType,
                                           resolveTimeout: resolveTimeout)
        let found = await session.run(timeout: timeout)
        recordDenied(session.policyDenied)
        return found
    }

    private func recordDenied(_ denied: Bool) {
        lock.lock(); defer { lock.unlock() }
        _lastBrowseDenied = denied
    }
}

/// One browse (internal). Resolves its continuation exactly once.
final class BonjourBrowseSession: @unchecked Sendable {
    private let serviceType: String
    private let interface: NWInterface.InterfaceType?
    private let resolveTimeout: TimeInterval
    private let queue = DispatchQueue(label: "ocm.bonjour")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var found: [DiscoveredDash] = []
    private var seen = Set<String>()
    private var resolving: [String: NWConnection] = [:]
    private var finished = false
    private var continuation: CheckedContinuation<[DiscoveredDash], Never>?
    private var _policyDenied = false

    /// DNS-SD kDNSServiceErr_PolicyDenied (Local Network access denied).
    static let policyDeniedCode: Int32 = -65570

    init(serviceType: String, interface: NWInterface.InterfaceType?, resolveTimeout: TimeInterval) {
        self.serviceType = serviceType
        self.interface = interface
        self.resolveTimeout = resolveTimeout
    }

    var policyDenied: Bool { lock.lock(); defer { lock.unlock() }; return _policyDenied }

    func run(timeout: TimeInterval) async -> [DiscoveredDash] {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<[DiscoveredDash], Never>) in
                lock.lock()
                if finished {
                    // Cancelled before we got here: finish() already ran without a continuation.
                    let r = found
                    lock.unlock()
                    cont.resume(returning: r)
                    return
                }
                continuation = cont
                lock.unlock()
                if Task.isCancelled {
                    finish(reason: "cancelled")
                    return
                }
                start(timeout: timeout)
            }
        } onCancel: { [weak self] in
            self?.finish(reason: "cancelled")
        }
    }

    private func start(timeout: TimeInterval) {
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = false
        if let interface { params.requiredInterfaceType = interface }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: params)
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        browser = b
        lock.unlock()
        b.stateUpdateHandler = { [weak self] state in self?.handleBrowserState(state) }
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.handleResults(results) }
        Log.i("DISC", "[DISC] discovering \(serviceType).…")
        b.start(queue: queue)
        queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
            self?.finish(reason: "timeout")
        }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case let .failed(error):
            if Self.isPolicyDenied(error) { markDenied() }
            Log.w("DISC", "[DISC] start failed: \(error)")
            finish(reason: "failed")
        case let .waiting(error):
            if Self.isPolicyDenied(error) {
                markDenied()
                Log.w("DISC", "[DISC] Bonjour browse denied by Local Network privacy")
                finish(reason: "denied")
            }
        default:
            break
        }
    }

    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case let .dns(code) = error { return Int32(code) == policyDeniedCode }
        return false
    }

    private func markDenied() {
        lock.lock(); _policyDenied = true; lock.unlock()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            let key = "\(result.endpoint)"
            lock.lock()
            let isNew = !finished && !seen.contains(key)
            if isNew { seen.insert(key) }
            lock.unlock()
            guard isNew else { continue }

            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata { txt = record.dictionary }
            var name = key
            if case let .service(n, _, _, _) = result.endpoint { name = n }
            Log.i("DISC", "[DISC] found service name=\(name) — resolving")

            if let ep = EasyConnTXT.endpoint(txt) {
                accept(DiscoveredDash(host: ep.host, port: ep.port, txt: txt), source: "txt")
                continue
            }
            resolve(result.endpoint, name: name, key: key, txt: txt)
        }
    }

    /// Resolves a service endpoint to IPv4:port by opening (then closing) a short TCP connection.
    private func resolve(_ endpoint: NWEndpoint, name: String, key: String, txt: [String: String]) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(resolveTimeout.rounded(.up)))
        let params = NWParameters(tls: nil, tcp: tcp)
        if let interface { params.requiredInterfaceType = interface }
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: endpoint, using: params)
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        resolving[key] = conn
        lock.unlock()

        let done = OCMOnceFlag()
        let queue = self.queue
        let complete: @Sendable (String?) -> Void = { [weak self] failure in
            guard done.claim() else { return }
            conn.cancel()
            queue.async { conn.stateUpdateHandler = nil }  // break the connection ↔ handler cycle
            self?.resolveEnded(key: key)
            if let failure { Log.w("DISC", "[DISC] resolve failed for \(name): \(failure)") }
        }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let remote = OCMNWSupport.hostPort(conn.currentPath?.remoteEndpoint)
                complete(nil)
                if let remote, EasyConnTXT.isUsable(host: remote.host, port: Int(remote.port)) {
                    self?.accept(DiscoveredDash(host: remote.host, port: remote.port, txt: txt), source: "resolve")
                } else {
                    Log.w("DISC", "[DISC] resolve failed for \(name): unusable endpoint \(remote.map { "\($0.host):\($0.port)" } ?? "nil")")
                }
            case let .waiting(error):
                if case let .dns(code) = error, Int32(code) == BonjourBrowseSession.policyDeniedCode { self?.markDenied() }
                if OCMNWSupport.unsatisfiedReason(conn.currentPath) == .localNetworkDenied { self?.markDenied() }
                complete("\(error)")
            case let .failed(error):
                complete("\(error)")
            case .cancelled:
                complete(nil)
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + max(0.5, resolveTimeout)) { complete("timeout") }
    }

    private func resolveEnded(key: String) {
        lock.lock(); resolving[key] = nil; lock.unlock()
    }

    private func accept(_ dash: DiscoveredDash, source: String) {
        lock.lock()
        if finished || found.contains(dash) {
            lock.unlock()
            return
        }
        found.append(dash)
        lock.unlock()
        let pkg = EasyConnTXT.packageName(dash.txt).map { " pkg=\($0)" } ?? ""
        Log.i("DISC", "[DISC] NSD → \(dash.host):\(dash.port)\(pkg) (\(source))")
        finish(reason: "found")
    }

    private func finish(reason: String) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let result = found
        let cont = continuation
        continuation = nil
        let b = browser
        browser = nil
        let conns = Array(resolving.values)
        resolving.removeAll()
        lock.unlock()
        b?.cancel()
        for c in conns { c.cancel() }
        if result.isEmpty, reason == "timeout" {
            Log.i("DISC", "[DISC] NSD timed out / no usable EasyConn advertisement")
        }
        cont?.resume(returning: result)
    }
}
#endif
