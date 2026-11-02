// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (pickBikeInterfaceIp / resolveGateway /
// gatewayForSubnet) and EasyConnDiscovery.kt (isUsableBikeIpv4).
//
// Current Wi-Fi addressing for the bike link: interface name, phone IPv4 + prefix, gateways and
// (full flavor) SSID. docs/spec/ios-platform-facts.md (j), session-network.md §4.
//
// "Wi-Fi up" does not need a satisfied path. On the dash's access point (no internet) iOS keeps
// NWPathMonitor(requiredInterfaceType: .wifi) unsatisfied (`notAvailable`, no interface listed)
// although the Wi-Fi interface holds its DHCP address (field log 1). A Wi-Fi interface with a usable
// IPv4 therefore counts as up ("local-only"), and the bike link uses that interface directly.
//
// Layout of this file:
// - Foundation-only part (compiled on every platform, unit-tested on Linux): `WiFiIPv4`,
//   `WiFiSubnet`, `WiFiInterfaces` (getifaddrs), `WiFiPathFacts`, `WiFiSnapshot`,
//   `OCMPlatformBroadcaster`.
// - Network.framework part: `WiFiInfo` (NWPathMonitor(requiredInterfaceType: .wifi)).
// - iOS + full flavor: SSID through `NEHotspotNetwork.fetchCurrent` (`#if !OCM_NO_HOTSPOT`).
//
// The Wi-Fi interface is the one the path reports (NWInterface.type == .wifi). An unsatisfied path
// lists none: then the interface whose functional type is Wi-Fi (SIOCGIFFUNCTIONALTYPE, TN3179
// "Identify the Wi-Fi interface correctly"), and "en0" only when the type says nothing else.

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
/// (`NWInterface.name`); without one, by its functional type (`wifiInterfaceName(among:)`).
public enum WiFiInterfaces {
    /// iOS's Wi-Fi interface: the last resort when neither the path nor the functional type names one.
    public static let defaultWifiInterfaceName = "en0"
    /// `IFRTYPE_FUNCTIONAL_UNKNOWN` / `IFRTYPE_FUNCTIONAL_WIFI_INFRA` (<net/if.h>).
    public static let functionalTypeUnknown: UInt32 = 0
    public static let functionalTypeWifiInfra: UInt32 = 3

    /// The Wi-Fi interface when the path names none (an unsatisfied path lists no interface): among
    /// the interfaces carrying IPv4, the one whose functional type is Wi-Fi ("en0" first, else one with
    /// a usable address). With none typed Wi-Fi: "en0", unless its type says it is something else
    /// (wired, cellular…): then nil.
    public static func wifiInterfaceName(among all: [WiFiInterfaceAddress],
                                         typeOf: (String) -> UInt32? = WiFiInterfaces.functionalType(ofInterface:)) -> String? {
        var names: [String] = []
        for a in all where a.isUp && !a.isLoopback && !names.contains(a.interfaceName) {
            names.append(a.interfaceName)
        }
        let wifi = names.filter { typeOf($0) == functionalTypeWifiInfra }
        if wifi.contains(defaultWifiInterfaceName) { return defaultWifiInterfaceName }
        if let usable = wifi.first(where: { name in
            all.contains { $0.interfaceName == name && $0.address.isUsableLocalAddress }
        }) { return usable }
        if let first = wifi.first { return first }
        if let type = typeOf(defaultWifiInterfaceName), type != functionalTypeUnknown { return nil }
        return defaultWifiInterfaceName
    }

    private static let functionalTypes = Locked<[String: UInt32]>([:])

    /// Functional type of a BSD interface (`SIOCGIFFUNCTIONALTYPE`, cached per name); nil where it
    /// cannot be read (not Darwin, unknown interface).
    public static func functionalType(ofInterface name: String) -> UInt32? {
        if let known = functionalTypes.withLock({ $0[name] }) { return known }
        guard let type = readFunctionalType(name) else { return nil }
        functionalTypes.withLock { $0[name] = type }
        return type
    }

    private static func readFunctionalType(_ name: String) -> UInt32? {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var request = ifreq()
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: request.ifr_name) else { return nil }
        withUnsafeMutableBytes(of: &request.ifr_name) { buffer in
            for (i, b) in bytes.enumerated() { buffer[i] = b }
        }
        // _IOWR('i', 173, struct ifreq): Swift does not import the SIOCGIFFUNCTIONALTYPE macro.
        let code = UInt(0xC000_0000) | (UInt(MemoryLayout<ifreq>.size & 0x1FFF) << 16)
            | (UInt(UInt8(ascii: "i")) << 8) | 173
        let rc = withUnsafeMutablePointer(to: &request) { ioctl(fd, code, UnsafeMutableRawPointer($0)) }
        guard rc == 0 else { return nil }
        // ifru_functional_type is the union's first (and only read) member.
        return withUnsafeBytes(of: &request.ifr_ifru) { $0.load(as: UInt32.self) }
        #else
        return nil
        #endif
    }

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

// MARK: - Path facts

/// What the Wi-Fi `NWPath` reports, without Network.framework types: a snapshot is built from these
/// plus getifaddrs (`WiFiSnapshot.init(path:addresses:fallbackInterfaceName:)`).
public struct WiFiPathFacts: Sendable, Equatable {
    public var isSatisfied: Bool
    /// `NWPath.unsatisfiedReason` as text when not satisfied, e.g. "notAvailable".
    public var unsatisfiedReason: String?
    public var isLocalNetworkDenied: Bool
    /// BSD name of the `.wifi` interface the path lists (an unsatisfied path lists none).
    public var interfaceName: String?
    /// Usable or not, the IPv4 gateways of the path (`NWPath.gateways`).
    public var gateways: [String]

    public init(isSatisfied: Bool, unsatisfiedReason: String? = nil, isLocalNetworkDenied: Bool = false,
                interfaceName: String? = nil, gateways: [String] = []) {
        self.isSatisfied = isSatisfied
        self.unsatisfiedReason = unsatisfiedReason
        self.isLocalNetworkDenied = isLocalNetworkDenied
        self.interfaceName = interfaceName
        self.gateways = gateways
    }

    /// Before the first path update.
    public static let none = WiFiPathFacts(isSatisfied: false)
}

// MARK: - Snapshot

/// What the app knows about the current Wi-Fi link (bike network or not).
public struct WiFiSnapshot: Sendable, Equatable, CustomStringConvertible {
    /// The Wi-Fi path is satisfied (associated, link up, and iOS deems it usable). Does NOT imply
    /// internet. A network without internet (the dash) may stay unsatisfied with a usable address:
    /// see `isUp` / `isLocalOnly`.
    public var isSatisfied: Bool
    /// BSD name of the Wi-Fi interface: the one the path reports, else the functional-type / "en0"
    /// fallback when it carries an IPv4 (logs, address lookup).
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

    /// Builds a snapshot from the path facts and the interface addresses. Without a Wi-Fi interface
    /// in the path, `fallbackInterfaceName` is used, and reported only when it carries an IPv4.
    public init(path: WiFiPathFacts, addresses: [WiFiInterfaceAddress], fallbackInterfaceName: String?) {
        var name = path.interfaceName
        var address = name.flatMap { WiFiInterfaces.pickPrimary(addresses, interfaceName: $0) }
        if name == nil, let fallback = fallbackInterfaceName,
           let a = WiFiInterfaces.pickPrimary(addresses, interfaceName: fallback) {
            name = fallback
            address = a
        }
        self.init(isSatisfied: path.isSatisfied, interfaceName: name, phoneIPv4: address?.address.description,
                  prefixLength: address?.prefixLength, gateways: path.gateways,
                  isLocalNetworkDenied: path.isLocalNetworkDenied,
                  unsatisfiedReason: path.isSatisfied ? nil : path.unsatisfiedReason)
    }

    /// Wi-Fi is up: the path is satisfied, or the Wi-Fi interface holds a usable IPv4 (a network
    /// without internet, like the dash's, that iOS reports unsatisfied).
    public var isUp: Bool { isSatisfied || usablePhoneIPv4 != nil }

    /// Up through the interface address only: iOS reports the Wi-Fi path unsatisfied.
    public var isLocalOnly: Bool { !isSatisfied && usablePhoneIPv4 != nil }

    /// Phone IPv4 if it can be used on a bike network (not 169.254/16, loopback or 0.0.0.0).
    public var usablePhoneIPv4: String? {
        guard let s = phoneIPv4, let a = WiFiIPv4(s), a.isUsableLocalAddress else { return nil }
        return s
    }

    /// The path's first usable gateway, else the subnet `.1` (a local-only path lists no gateway).
    public var primaryGateway: String? { usableGateways.first ?? subnetGateway }

    /// Another usable address or gateway than `baseline`, or Wi-Fi was down then: the phone changed
    /// networks (the rule `ConnectionModel.matchesManualJoin` applies to a manual join).
    public func hasNewAddress(since baseline: WiFiSnapshot) -> Bool {
        !baseline.isUp || baseline.usablePhoneIPv4 != usablePhoneIPv4 || baseline.primaryGateway != primaryGateway
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

    /// "wifi=up", "wifi=up(local-only, path=unsatisfied:notAvailable)" or "wifi=down".
    public var stateDescription: String {
        if isSatisfied { return "wifi=up" }
        if isLocalOnly { return "wifi=up(local-only, path=unsatisfied:\(unsatisfiedReason ?? "unknown"))" }
        return "wifi=down"
    }

    public var description: String {
        var parts = [stateDescription]
        if let interfaceName { parts.append("iface=\(interfaceName)") }
        if let phoneIPv4 { parts.append("ip=\(phoneIPv4)" + (prefixLength.map { "/\($0)" } ?? "")) }
        if !gateways.isEmpty {
            parts.append("gw=\(gateways.joined(separator: ","))")
        } else if isLocalOnly, let guess = subnetGateway {
            parts.append("gw=\(guess)(subnet)")
        }
        if let ssid { parts.append("ssid=\(ssid)") }
        if isLocalNetworkDenied { parts.append("localNetworkDenied") }
        if !isLocalOnly, let unsatisfiedReason { parts.append("reason=\(unsatisfiedReason)") }
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
/// `refreshedSnapshot()` re-reads the interface: a local-only network's address comes and goes while
/// the path stays unsatisfied, so nothing else would tell.
///
/// Thread-safety: `final class` guarded by an NSLock; callbacks run on an internal serial queue.
public final class WiFiInfo: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ocm.wifi.path")
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var _current: WiFiSnapshot = .unavailable
    private var pathFacts = WiFiPathFacts.none
    /// Bumped by every path update: a refresh built from older facts never overwrites a newer path.
    private var factsGeneration: UInt64 = 0
    /// The Wi-Fi interface the last path named (an unsatisfied path names none; the name stays).
    private var pathWifiName: String?
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

    /// Re-reads the Wi-Fi interface address and returns the refreshed snapshot; a change is published
    /// like a path update. The path stays unsatisfied while a local-only network's address comes and
    /// goes, and DHCP may complete without a path change.
    public func refreshedSnapshot() -> WiFiSnapshot {
        lock.lock()
        let f = pathFacts
        let generation = factsGeneration
        let known = pathWifiName
        lock.unlock()
        let s = Self.snapshot(facts: f, knownWifiInterface: known)
        lock.lock()
        guard generation == factsGeneration else {
            // A path update landed meanwhile: it is newer.
            let latest = _current
            lock.unlock()
            return latest
        }
        let changed = s != _current
        if changed { _current = s }
        let cb = _onChange
        lock.unlock()
        if changed {
            Log.i("WIFI", "[wifi] interface: \(s)")
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

    /// Builds a snapshot from a Wi-Fi path (and the interface addresses now).
    public static func snapshot(from path: Network.NWPath) -> WiFiSnapshot {
        snapshot(facts: facts(from: path), knownWifiInterface: nil)
    }

    /// The path facts in Network.framework-free form.
    static func facts(from path: Network.NWPath) -> WiFiPathFacts {
        let gateways: [String] = path.gateways.compactMap { ep in
            guard case let .hostPort(host, _) = ep, case let .ipv4(a) = host,
                  let v = WiFiIPv4(bytes: [UInt8](a.rawValue)) else { return nil }
            return v.description
        }
        let satisfied = path.status == .satisfied
        return WiFiPathFacts(isSatisfied: satisfied,
                             unsatisfiedReason: satisfied ? nil : "\(path.unsatisfiedReason)",
                             isLocalNetworkDenied: !satisfied && path.unsatisfiedReason == .localNetworkDenied,
                             interfaceName: path.availableInterfaces.first { $0.type == .wifi }?.name,
                             gateways: gateways)
    }

    /// Path facts + getifaddrs. Without a Wi-Fi interface in the path: the one an earlier path named,
    /// else the functional-type lookup ("en0" as the last resort).
    static func snapshot(facts: WiFiPathFacts, knownWifiInterface: String?) -> WiFiSnapshot {
        let addresses = WiFiInterfaces.ipv4Addresses()
        let fallback = facts.interfaceName != nil ? nil
            : knownWifiInterface ?? WiFiInterfaces.wifiInterfaceName(among: addresses)
        return WiFiSnapshot(path: facts, addresses: addresses, fallbackInterfaceName: fallback)
    }

    private func handle(_ path: Network.NWPath) {
        let f = Self.facts(from: path)
        lock.lock()
        if let name = f.interfaceName { pathWifiName = name }
        let known = pathWifiName
        lock.unlock()
        let s = Self.snapshot(facts: f, knownWifiInterface: known)
        lock.lock()
        pathFacts = f
        factsGeneration &+= 1
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

    /// `firstSnapshot` plus the SSID (when iOS reveals it; also on a local-only Wi-Fi).
    public func snapshotWithSSID(timeout: TimeInterval = 1.0) async -> WiFiSnapshot {
        var s = await firstSnapshot(timeout: timeout)
        if s.isUp { s.ssid = await Self.fetchSSID() }
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
