// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) EasyConnProber.kt (pickBikeInterfaceIp, resolveGateway,
// gatewayForSubnet)
//
// Local IPv4 addresses and the dash address ladder (docs/spec/session-network.md §4,
// ios-platform-facts.md (j)): NWPath.gateways is Apple-only, so the core takes an optional injected
// gateway and falls back to `(ip & mask) | 1`, then 192.168.0.1 and 192.168.49.1.
// Interface names (en0…) are NOT API on iOS: the Apple layer should pass the Wi-Fi interface name
// from NWPathMonitor when it has one.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One IPv4 address of a local interface.
public struct InterfaceAddress: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var name: String
    public var ipv4: String
    public var netmask: String
    public var isUp: Bool
    public var isLoopback: Bool

    public init(name: String, ipv4: String, netmask: String, isUp: Bool = true, isLoopback: Bool = false) {
        self.name = name
        self.ipv4 = ipv4
        self.netmask = netmask
        self.isUp = isUp
        self.isLoopback = isLoopback
    }

    /// Prefix length of the netmask (e.g. 24), nil if the mask is not contiguous / unparsable.
    public var prefixLength: Int? {
        guard let m = InterfaceAddresses.parseIPv4(netmask) else { return nil }
        let ones = m.nonzeroBitCount
        let contiguous = ones == 0 ? m == 0 : (m >> UInt32(32 - ones)) == (UInt32.max >> UInt32(32 - ones)) && (m << UInt32(ones)) == 0
        return contiguous ? ones : nil
    }

    /// 169.254.0.0/16.
    public var isLinkLocal: Bool { ipv4.hasPrefix("169.254.") }

    public var description: String { "\(name) \(ipv4)/\(prefixLength.map(String.init) ?? netmask)\(isUp ? "" : " down")" }
}

public enum InterfaceAddresses {
    /// Known dash gateways (SoftAP, Wi-Fi Direct group owner).
    public static let knownDashGateways = ["192.168.0.1", "192.168.49.1"]

    /// All IPv4 addresses of local interfaces (`getifaddrs`).
    public static func current() -> [InterfaceAddress] {
        var out: [InterfaceAddress] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ip = ipv4Value(addr)
            let mask = entry.pointee.ifa_netmask.map(ipv4Value) ?? 0
            let flags = UInt32(entry.pointee.ifa_flags)
            // IFF_UP = 0x1, IFF_LOOPBACK = 0x8 on Linux and Darwin.
            out.append(InterfaceAddress(name: String(cString: entry.pointee.ifa_name),
                                        ipv4: format(ip), netmask: format(mask),
                                        isUp: flags & 0x1 != 0, isLoopback: flags & 0x8 != 0))
        }
        return out
    }

    private static func ipv4Value(_ sa: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        UnsafeRawPointer(sa).withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
        }
    }

    // MARK: Address math

    /// Dotted quad → host-order value; nil if malformed.
    public static func parseIPv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let o = UInt32(p), o <= 255 else { return nil }
            v = (v << 8) | o
        }
        return v
    }

    public static func format(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    public static func isValidIPv4(_ s: String) -> Bool { parseIPv4(s) != nil }

    /// Android `gatewayForSubnet`: the ".1" host `(ip & mask) | 1` for prefixes 1…31; nil if that is
    /// our own address (we are the group owner) or the prefix is out of range.
    public static func subnetGateway(ip: String, prefixLength: Int) -> String? {
        guard (1 ... 31).contains(prefixLength), let v = parseIPv4(ip) else { return nil }
        let mask = UInt32.max << UInt32(32 - prefixLength)
        let gw = (v & mask) | 1
        return gw == v ? nil : format(gw)
    }

    /// `subnetGateway` for an interface address (nil without a usable netmask).
    public static func subnetGateway(of address: InterfaceAddress) -> String? {
        guard let prefix = address.prefixLength else { return nil }
        return subnetGateway(ip: address.ipv4, prefixLength: prefix)
    }

    /// True if `ip` is inside the subnet of `address`.
    public static func contains(_ address: InterfaceAddress, _ ip: String) -> Bool {
        guard let prefix = address.prefixLength, prefix > 0, let a = parseIPv4(address.ipv4), let b = parseIPv4(ip) else { return false }
        let mask = UInt32.max << UInt32(32 - prefix)
        return a & mask == b & mask
    }

    /// Picks the phone's IPv4 on the bike network (Android `pickBikeInterfaceIp`, iOS flavour):
    /// 1. `preferredIP` if an up interface carries it;
    /// 2. the interface named `interfaceName` (the Apple layer passes the NWPath Wi-Fi interface);
    /// 3. an interface whose subnet contains `subnetHint` (e.g. the injected gateway);
    /// 4. an interface on a known dash subnet (192.168.0.x, 192.168.49.x, 192.168.4.x);
    /// 5. the first up, non-loopback, non-link-local IPv4.
    public static func pickBikeIPv4(from addresses: [InterfaceAddress], preferredIP: String? = nil,
                                    interfaceName: String? = nil, subnetHint: String? = nil) -> InterfaceAddress? {
        let usable = addresses.filter { $0.isUp && !$0.isLoopback && isValidIPv4($0.ipv4) }
        if let preferredIP, let hit = usable.first(where: { $0.ipv4 == preferredIP }) { return hit }
        if let interfaceName, let hit = usable.first(where: { $0.name == interfaceName && !$0.isLinkLocal }) { return hit }
        let routable = usable.filter { !$0.isLinkLocal }
        if let subnetHint, let hit = routable.first(where: { contains($0, subnetHint) }) { return hit }
        let knownPrefixes = ["192.168.0.", "192.168.49.", "192.168.4."]
        if let hit = routable.first(where: { a in knownPrefixes.contains { a.ipv4.hasPrefix($0) } }) { return hit }
        return routable.first
    }

    /// Ordered dash-address candidates (deduplicated):
    /// explicit dash host → injected gateway (NWPath.gateways) → `(ip & mask) | 1` of the local Wi-Fi
    /// address → 192.168.0.1 → 192.168.49.1. When the local address is known, guessed candidates
    /// outside its subnet are skipped (explicit ones are always kept).
    public static func gatewayCandidates(dashHost: String?, injectedGateway: String?, local: InterfaceAddress?) -> [String] {
        var out: [String] = []
        func add(_ s: String?, guessed: Bool) {
            guard let s, isValidIPv4(s), !out.contains(s) else { return }
            if guessed, let local, local.prefixLength != nil, !contains(local, s) { return }
            if let local, s == local.ipv4 { return }
            out.append(s)
        }
        add(dashHost, guessed: false)
        add(injectedGateway, guessed: false)
        add(local.flatMap(subnetGateway(of:)), guessed: true)
        for g in knownDashGateways { add(g, guessed: true) }
        return out
    }
}
