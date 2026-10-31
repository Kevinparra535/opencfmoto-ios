// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (pickBikeInterfaceIp / resolveGateway /
// gatewayForSubnet) and EasyConnDiscovery.kt (isUsableBikeIpv4).
//
// Current Wi-Fi addressing for the bike link: interface name, phone IPv4 + prefix, gateways and
// (full flavor) SSID. docs/spec/ios-platform-facts.md (j), session-network.md §4.
//
// Layout of this file:
// - Foundation-only part (compiled on every platform, unit-tested on Linux): `WiFiIPv4`,
//   `WiFiSubnet`, `WiFiInterfaces` (getifaddrs), `WiFiSnapshot`, `OCMPlatformBroadcaster`.
// - Network.framework part: `WiFiInfo` (NWPathMonitor(requiredInterfaceType: .wifi)).
// - iOS + full flavor: SSID through `NEHotspotNetwork.fetchCurrent` (`#if !OCM_NO_HOTSPOT`).
//
// Never hard-code "en0": the Wi-Fi interface is identified by NWInterface.type == .wifi and its
// BSD name is then used to filter getifaddrs (TN3179 "Identify the Wi-Fi interface correctly").

#if canImport(Foundation)
import Foundation
import OpenCfMotoCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - IPv4 value

/// An IPv4 address as a host-order `UInt32` (192.168.0.1 == 0xC0A8_0001).
public struct WiFiIPv4: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    /// Strict dotted quad ("192.168.0.1"): exactly four decimal parts 0…255, digits only.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = UInt32(p), n <= 255 else { return nil }
            v = (v << 8) | n
        }
        value = v
    }

    /// Network-order bytes (4), e.g. `IPv4Address.rawValue` or `in_addr`.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 else { return nil }
        self.init(bytes[0], bytes[1], bytes[2], bytes[3])
    }

    public var octets: [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    public var description: String { octets.map(String.init).joined(separator: ".") }

    public static func < (a: WiFiIPv4, b: WiFiIPv4) -> Bool { a.value < b.value }

    /// 169.254.0.0/16 (no DHCP lease yet).
    public var isLinkLocal: Bool { (value & 0xFFFF_0000) == 0xA9FE_0000 }
    /// 127.0.0.0/8
    public var isLoopback: Bool { (value >> 24) == 127 }
    /// 0.0.0.0
    public var isUnspecified: Bool { value == 0 }
    /// 224.0.0.0/4
    public var isMulticast: Bool { (value >> 28) == 0xE }
    /// 255.255.255.255
    public var isBroadcast: Bool { value == 0xFFFF_FFFF }

    /// Android `EasyConnDiscovery.isUsableBikeIpv4`: not loopback, not the any-address, not multicast.
    public var isUsableDashAddress: Bool { !isLoopback && !isUnspecified && !isMulticast && !isBroadcast }

    /// Usable as the phone's own address on the bike Wi-Fi: additionally not link-local (169.254/16
    /// means DHCP has not completed — the dash cannot call back such an address).
    public var isUsableLocalAddress: Bool { isUsableDashAddress && !isLinkLocal }

    /// Netmask for a prefix length 0…32.
    public static func netmask(prefixLength p: Int) -> WiFiIPv4 {
        let n = max(0, min(32, p))
        return WiFiIPv4(n == 0 ? 0 : UInt32.max << UInt32(32 - n))
    }

    /// Prefix length of a contiguous netmask (255.255.255.0 → 24); nil for non-contiguous masks.
    public static func prefixLength(netmask m: WiFiIPv4) -> Int? {
        let ones = m.value.leadingZeroBitCount == 0 ? (~m.value).leadingZeroBitCount : 0
        guard netmask(prefixLength: ones) == m else { return nil }
        return ones
    }

    /// Android `gatewayForSubnet` (EasyConnProber.kt): `(ip & mask) | 1` for prefix 1…31, nil when
    /// that equals our own address (we ARE the .1, e.g. a Wi-Fi Direct group owner).
    public static func gatewayForSubnet(_ ip: WiFiIPv4, prefixLength p: Int) -> WiFiIPv4? {
        guard (1 ... 31).contains(p) else { return nil }
        let gw = WiFiIPv4((ip.value & netmask(prefixLength: p).value) | 1)
        return gw == ip ? nil : gw
    }
}

/// An IPv4 subnet (network + prefix length).
public struct WiFiSubnet: Hashable, Sendable, CustomStringConvertible {
    public let network: WiFiIPv4
    public let prefixLength: Int

    public init(network: WiFiIPv4, prefixLength: Int) {
        let p = max(0, min(32, prefixLength))
        self.prefixLength = p
        self.network = WiFiIPv4(network.value & WiFiIPv4.netmask(prefixLength: p).value)
    }

    /// "192.168.0.0/24" (a bare address means /32).
    public init?(_ cidr: String) {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count), let a = WiFiIPv4(String(parts[0])) else { return nil }
        var p = 32
        if parts.count == 2 {
            guard let n = Int(parts[1]), (0 ... 32).contains(n) else { return nil }
            p = n
        }
        self.init(network: a, prefixLength: p)
    }

    public func contains(_ a: WiFiIPv4) -> Bool {
        (a.value & WiFiIPv4.netmask(prefixLength: prefixLength).value) == network.value
    }

    public func contains(_ s: String) -> Bool { WiFiIPv4(s).map(contains) ?? false }

    public var description: String { "\(network)/\(prefixLength)" }

    /// Address plans of the known dashes (session-network.md §4.3): CFDL16/CFDL26 SoftAP
    /// 192.168.0.1, Wi-Fi Direct group owners 192.168.49.1, Morini/Yunmo SoftAP 192.168.4.1.
    public static let knownDashSubnets: [WiFiSubnet] = [
        WiFiSubnet(network: WiFiIPv4(192, 168, 0, 0), prefixLength: 24),
        WiFiSubnet(network: WiFiIPv4(192, 168, 49, 0), prefixLength: 24),
        WiFiSubnet(network: WiFiIPv4(192, 168, 4, 0), prefixLength: 24),
    ]

    /// Dash addresses tried as a last resort when neither a gateway nor the subnet `.1` is known
    /// (ios-platform-facts.md (j) ladder step 3).
    public static let knownDashAddresses: [String] = ["192.168.0.1", "192.168.49.1"]
}

// MARK: - getifaddrs

/// One IPv4 address of a local interface (from `getifaddrs`).
public struct WiFiInterfaceAddress: Sendable, Equatable {
    public var interfaceName: String
    public var address: WiFiIPv4
    public var netmask: WiFiIPv4?
    public var isUp: Bool
    public var isLoopback: Bool

    public init(interfaceName: String, address: WiFiIPv4, netmask: WiFiIPv4? = nil, isUp: Bool = true, isLoopback: Bool = false) {
        self.interfaceName = interfaceName
        self.address = address
        self.netmask = netmask
        self.isUp = isUp
        self.isLoopback = isLoopback
    }

    public var prefixLength: Int? { netmask.flatMap { WiFiIPv4.prefixLength(netmask: $0) } }
}

/// IPv4 interface enumeration. Pick the Wi-Fi interface by the NAME the Wi-Fi `NWPath` reports
/// (`NWInterface.name`), never by assuming "en0".
public enum WiFiInterfaces {
    /// All IPv4 addresses of all interfaces (empty if `getifaddrs` fails).
    public static func ipv4Addresses() -> [WiFiInterfaceAddress] {
        var out: [WiFiInterfaceAddress] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        let upFlag = UInt32(truncatingIfNeeded: IFF_UP)
        let loopbackFlag = UInt32(truncatingIfNeeded: IFF_LOOPBACK)
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next
            guard let sa = ifa.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET,
                  let namePtr = ifa.ifa_name else { continue }
            let addr = ipv4(from: sa)
            var mask: WiFiIPv4?
            if let m = ifa.ifa_netmask { mask = ipv4(from: m) }
            out.append(WiFiInterfaceAddress(
                interfaceName: String(cString: namePtr),
                address: addr,
                netmask: mask,
                isUp: (UInt32(ifa.ifa_flags) & upFlag) != 0,
                isLoopback: (UInt32(ifa.ifa_flags) & loopbackFlag) != 0
            ))
        }
        return out
    }

    /// The best IPv4 on `interfaceName`: up, usable (non-link-local) addresses first.
    public static func primaryIPv4(onInterface interfaceName: String) -> WiFiInterfaceAddress? {
        pickPrimary(ipv4Addresses(), interfaceName: interfaceName)
    }

    /// Pure selection rule used by `primaryIPv4(onInterface:)`: same interface name, up, prefer a
    /// usable local address (not 169.254/16); a link-local address is returned only as a last resort.
    public static func pickPrimary(_ all: [WiFiInterfaceAddress], interfaceName: String) -> WiFiInterfaceAddress? {
        let candidates = all.filter { $0.interfaceName == interfaceName && $0.isUp && !$0.address.isUnspecified }
        return candidates.first(where: { $0.address.isUsableLocalAddress }) ?? candidates.first
    }

    private static func ipv4(from sa: UnsafeMutablePointer<sockaddr>) -> WiFiIPv4 {
        let raw = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        // s_addr is in network byte order.
        return WiFiIPv4(UInt32(bigEndian: raw))
    }
}

// MARK: - Snapshot

/// What the app knows about the current Wi-Fi link (bike network or not).
public struct WiFiSnapshot: Sendable, Equatable, CustomStringConvertible {
    /// A Wi-Fi path exists and is satisfied (associated, link up). Does NOT imply internet.
    public var isSatisfied: Bool
    /// BSD name of the Wi-Fi interface as reported by Network.framework (logs only).
    public var interfaceName: String?
    /// Phone IPv4 on the Wi-Fi interface (may be 169.254.x.x before DHCP completes).
    public var phoneIPv4: String?
    public var prefixLength: Int?
    /// IPv4 gateways of the Wi-Fi path (`NWPath.gateways`), e.g. ["192.168.0.1"].
    public var gateways: [String]
    /// SSID when known (full flavor: `NEHotspotNetwork.fetchCurrent`; nil otherwise).
    public var ssid: String?
    /// The Wi-Fi path is unsatisfied because Local Network privacy denied it.
    public var isLocalNetworkDenied: Bool
    /// `NWPath.unsatisfiedReason` as text when the path is not satisfied (diagnostics).
    public var unsatisfiedReason: String?

    public init(isSatisfied: Bool, interfaceName: String? = nil, phoneIPv4: String? = nil, prefixLength: Int? = nil,
                gateways: [String] = [], ssid: String? = nil, isLocalNetworkDenied: Bool = false,
                unsatisfiedReason: String? = nil) {
        self.isSatisfied = isSatisfied
        self.interfaceName = interfaceName
        self.phoneIPv4 = phoneIPv4
        self.prefixLength = prefixLength
        self.gateways = gateways
        self.ssid = ssid
        self.isLocalNetworkDenied = isLocalNetworkDenied
        self.unsatisfiedReason = unsatisfiedReason
    }

    /// No Wi-Fi path.
    public static let unavailable = WiFiSnapshot(isSatisfied: false)

    /// Phone IPv4 if it can be used on a bike network (not 169.254/16, loopback or 0.0.0.0).
    public var usablePhoneIPv4: String? {
        guard let s = phoneIPv4, let a = WiFiIPv4(s), a.isUsableLocalAddress else { return nil }
        return s
    }

    /// Android `gatewayForSubnet` of the phone address (192.168.0.50/24 → 192.168.0.1).
    public var subnetGateway: String? {
        guard let s = usablePhoneIPv4, let a = WiFiIPv4(s), let p = prefixLength else { return nil }
        return WiFiIPv4.gatewayForSubnet(a, prefixLength: p)?.description
    }

    /// Usable IPv4 gateways of the Wi-Fi path.
    public var usableGateways: [String] {
        gateways.filter { WiFiIPv4($0)?.isUsableDashAddress ?? false }
    }

    /// Dash probe targets in ladder order (ios-platform-facts.md (j)): `NWPath.gateways`, then the
    /// subnet `.1`, then the known dash addresses (only when nothing better is known or they are on
    /// the phone's subnet). Bonjour is separate (`BonjourDashDiscovery`). Deduplicated.
    public var dashHostCandidates: [String] {
        var out: [String] = []
        func add(_ s: String?) { if let s, !out.contains(s) { out.append(s) } }
        usableGateways.forEach(add)
        add(subnetGateway)
        let phoneSubnet: WiFiSubnet? = {
            guard let s = usablePhoneIPv4, let a = WiFiIPv4(s), let p = prefixLength else { return nil }
            return WiFiSubnet(network: a, prefixLength: p)
        }()
        let nothingBetterKnown = out.isEmpty
        for k in WiFiSubnet.knownDashAddresses {
            if nothingBetterKnown || (phoneSubnet?.contains(k) ?? false) { add(k) }
        }
        // Never probe our own address.
        if let me = usablePhoneIPv4 { out.removeAll { $0 == me } }
        return out
    }

    /// True if the phone address or a gateway lies in one of `subnets`.
    public func isOn(_ subnets: [WiFiSubnet]) -> Bool {
        if let s = usablePhoneIPv4, subnets.contains(where: { $0.contains(s) }) { return true }
        return usableGateways.contains { g in subnets.contains { $0.contains(g) } }
    }

    public var description: String {
        var parts = ["wifi=\(isSatisfied ? "up" : "down")"]
        if let interfaceName { parts.append("iface=\(interfaceName)") }
        if let phoneIPv4 { parts.append("ip=\(phoneIPv4)" + (prefixLength.map { "/\($0)" } ?? "")) }
        if !gateways.isEmpty { parts.append("gw=\(gateways.joined(separator: ","))") }
        if let ssid { parts.append("ssid=\(ssid)") }
        if isLocalNetworkDenied { parts.append("localNetworkDenied") }
        if let unsatisfiedReason { parts.append("reason=\(unsatisfiedReason)") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Multicast AsyncStream helper

/// Fan-out of values to any number of `AsyncStream` subscribers (each call to `stream()` returns a
/// new independent stream; a terminated stream unregisters itself). Thread-safe (NSLock).
final class OCMPlatformBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UInt64: AsyncStream<Element>.Continuation] = [:]
    private var nextID: UInt64 = 1
    private var finished = false

    init() {}

    var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return continuations.count }

    /// A new stream; `initial` (if any) is delivered first. Keeps the newest `buffer` values when
    /// the consumer is slow.
    func stream(initial: Element? = nil, buffer: Int = 32) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: .bufferingNewest(max(1, buffer))) { cont in
            lock.lock()
            if finished {
                lock.unlock()
                cont.finish()
                return
            }
            let id = nextID
            nextID &+= 1
            continuations[id] = cont
            lock.unlock()
            if let initial { cont.yield(initial) }
            cont.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    func yield(_ value: Element) {
        lock.lock()
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(value) }
    }

    /// Ends every stream; later `stream()` calls return finished streams.
    func finish() {
        lock.lock()
        finished = true
        let conts = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in conts { c.finish() }
    }

    private func remove(_ id: UInt64) {
        lock.lock(); continuations[id] = nil; lock.unlock()
    }
}
#endif

// MARK: - Network.framework adapter

#if canImport(Network)
import Network

/// Observes the Wi-Fi path with `NWPathMonitor(requiredInterfaceType: .wifi)` and publishes
/// `WiFiSnapshot`s (interface name, phone IPv4 from getifaddrs on THAT interface, IPv4 gateways).
///
/// Thread-safety: `final class` guarded by an NSLock; callbacks run on an internal serial queue.
public final class WiFiInfo: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ocm.wifi.path")
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var _current: WiFiSnapshot = .unavailable
    private var _onChange: (@Sendable (WiFiSnapshot) -> Void)?
    private var firstUpdateWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID: UInt64 = 1
    private var hasFirstUpdate = false
    private let broadcaster = OCMPlatformBroadcaster<WiFiSnapshot>()

    public init() {}

    deinit { monitor?.cancel() }

    /// Latest snapshot (`.unavailable` before the first path update).
    public var current: WiFiSnapshot { lock.lock(); defer { lock.unlock() }; return _current }

    /// Called on an internal queue after every change.
    public var onChange: (@Sendable (WiFiSnapshot) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onChange }
        set { lock.lock(); _onChange = newValue; lock.unlock() }
    }

    /// Stream of snapshots (starts with the current one). Call `start()` to receive updates.
    public func updates() -> AsyncStream<WiFiSnapshot> { broadcaster.stream(initial: current) }

    /// Starts monitoring (idempotent).
    public func start() {
        lock.lock()
        guard monitor == nil else { lock.unlock(); return }
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor = m
        lock.unlock()
        m.pathUpdateHandler = { [weak self] path in self?.handle(path) }
        m.start(queue: queue)
    }

    /// Stops monitoring (idempotent). `current` keeps the last value.
    public func stop() {
        lock.lock()
        let m = monitor
        monitor = nil
        hasFirstUpdate = false
        let waiters = Array(firstUpdateWaiters.values)
        firstUpdateWaiters.removeAll()
        lock.unlock()
        m?.cancel()
        for w in waiters { w.resume() }
    }

    /// Waits (≤ `timeout`) for the first path update after `start()`, then returns `current`.
    public func firstSnapshot(timeout: TimeInterval = 1.0) async -> WiFiSnapshot {
        start()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if hasFirstUpdate || monitor == nil {
                lock.unlock()
                cont.resume()
                return
            }
            let id = nextWaiterID
            nextWaiterID &+= 1
            firstUpdateWaiters[id] = cont
            lock.unlock()
            queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in self?.releaseFirstUpdateWaiter(id) }
        }
        return current
    }

    /// Re-reads the phone IPv4 of the current Wi-Fi interface (DHCP may complete without a path
    /// change) and returns the refreshed snapshot.
    public func refreshedSnapshot() -> WiFiSnapshot {
        lock.lock()
        var s = _current
        lock.unlock()
        guard s.isSatisfied, let name = s.interfaceName else { return s }
        let a = WiFiInterfaces.primaryIPv4(onInterface: name)
        s.phoneIPv4 = a?.address.description
        s.prefixLength = a?.prefixLength
        lock.lock()
        let changed = s != _current
        if changed { _current = s }
        let cb = _onChange
        lock.unlock()
        if changed {
            cb?(s)
            broadcaster.yield(s)
        }
        return s
    }

    /// One-shot snapshot with a temporary monitor.
    public static func currentSnapshot(timeout: TimeInterval = 1.0) async -> WiFiSnapshot {
        let info = WiFiInfo()
        let s = await info.firstSnapshot(timeout: timeout)
        info.stop()
        return s
    }

    /// Builds a snapshot from a Wi-Fi path.
    public static func snapshot(from path: NWPath) -> WiFiSnapshot {
        let wifi = path.availableInterfaces.first { $0.type == .wifi }
        let name = wifi?.name
        let gateways: [String] = path.gateways.compactMap { ep in
            guard case let .hostPort(host, _) = ep, case let .ipv4(a) = host,
                  let v = WiFiIPv4(bytes: [UInt8](a.rawValue)) else { return nil }
            return v.description
        }
        let satisfied = path.status == .satisfied
        let addr = name.flatMap { WiFiInterfaces.primaryIPv4(onInterface: $0) }
        let denied = !satisfied && path.unsatisfiedReason == .localNetworkDenied
        return WiFiSnapshot(
            isSatisfied: satisfied,
            interfaceName: name,
            phoneIPv4: addr?.address.description,
            prefixLength: addr?.prefixLength,
            gateways: gateways,
            ssid: nil,
            isLocalNetworkDenied: denied,
            unsatisfiedReason: satisfied ? nil : "\(path.unsatisfiedReason)"
        )
    }

    private func handle(_ path: NWPath) {
        let s = Self.snapshot(from: path)
        lock.lock()
        let changed = s != _current || !hasFirstUpdate
        _current = s
        hasFirstUpdate = true
        let cb = _onChange
        let waiters = Array(firstUpdateWaiters.values)
        firstUpdateWaiters.removeAll()
        lock.unlock()
        for w in waiters { w.resume() }
        if changed {
            Log.i("WIFI", "[wifi] path: \(s)")
            cb?(s)
            broadcaster.yield(s)
        }
    }

    private func releaseFirstUpdateWaiter(_ id: UInt64) {
        lock.lock()
        let w = firstUpdateWaiters.removeValue(forKey: id)
        lock.unlock()
        w?.resume()
    }
}

#if os(iOS) && canImport(NetworkExtension) && !OCM_NO_HOTSPOT
import NetworkExtension

extension WiFiInfo {
    /// SSID of the current Wi-Fi network via `NEHotspotNetwork.fetchCurrent` (full flavor only).
    /// Requires the Access WiFi Information entitlement AND (precise location, or the network was
    /// configured by this app with NEHotspotConfiguration, …); otherwise iOS returns nil.
    public static func fetchSSID() async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            NEHotspotNetwork.fetchCurrent { network in
                cont.resume(returning: network?.ssid)
            }
        }
    }

    /// `firstSnapshot` plus the SSID (when iOS reveals it).
    public func snapshotWithSSID(timeout: TimeInterval = 1.0) async -> WiFiSnapshot {
        var s = await firstSnapshot(timeout: timeout)
        if s.isSatisfied { s.ssid = await Self.fetchSSID() }
        return s
    }
}
#else
extension WiFiInfo {
    /// SSID lookup is unavailable in this build (free flavor `OCM_NO_HOTSPOT`, or not iOS): always nil.
    public static func fetchSSID() async -> String? { nil }

    /// `firstSnapshot` (no SSID in this build).
    public func snapshotWithSSID(timeout: TimeInterval = 1.0) async -> WiFiSnapshot {
        await firstSnapshot(timeout: timeout)
    }
}
#endif
#endif
