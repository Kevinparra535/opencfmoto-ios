// SPDX-License-Identifier: AGPL-3.0-or-later
// IPv4 math, gatewayForSubnet vectors (session-network.md §4.2), interface selection, Wi-Fi snapshot
// probe-target ladder, Bonjour TXT parsing and the AsyncStream broadcaster (runs on Linux too).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PlatformAddressingTests: XCTestCase {
    // MARK: WiFiIPv4

    func testParseAndFormat() {
        XCTAssertEqual(WiFiIPv4("192.168.0.1")?.value, 0xC0A8_0001)
        XCTAssertEqual(WiFiIPv4("192.168.49.132")?.description, "192.168.49.132")
        XCTAssertEqual(WiFiIPv4(10, 0, 0, 7).description, "10.0.0.7")
        XCTAssertEqual(WiFiIPv4(bytes: [192, 168, 4, 1])?.description, "192.168.4.1")
        XCTAssertEqual(WiFiIPv4("0.0.0.0")?.value, 0)
        XCTAssertEqual(WiFiIPv4("255.255.255.255")?.value, UInt32.max)
        for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1..2.3", "a.b.c.d", " 1.2.3.4", "1.2.3.4 ", "-1.2.3.4",
                    "1.2.3.1000", "::1", "1.2.3.4/24"] {
            XCTAssertNil(WiFiIPv4(bad), bad)
        }
        XCTAssertNil(WiFiIPv4(bytes: [1, 2, 3]))
        XCTAssertEqual(WiFiIPv4(192, 168, 0, 1).octets, [192, 168, 0, 1])
        XCTAssertTrue(WiFiIPv4("10.0.0.1")! < WiFiIPv4("192.168.0.1")!)
    }

    func testAddressClasses() {
        XCTAssertTrue(WiFiIPv4("169.254.12.3")!.isLinkLocal)
        XCTAssertFalse(WiFiIPv4("169.255.0.1")!.isLinkLocal)
        XCTAssertTrue(WiFiIPv4("127.0.0.1")!.isLoopback)
        XCTAssertTrue(WiFiIPv4("224.0.0.251")!.isMulticast)
        XCTAssertTrue(WiFiIPv4("0.0.0.0")!.isUnspecified)
        // Android isUsableBikeIpv4: not loopback / any / multicast.
        XCTAssertTrue(WiFiIPv4("192.168.0.1")!.isUsableDashAddress)
        XCTAssertTrue(WiFiIPv4("169.254.1.1")!.isUsableDashAddress)
        XCTAssertFalse(WiFiIPv4("127.0.0.1")!.isUsableDashAddress)
        XCTAssertFalse(WiFiIPv4("0.0.0.0")!.isUsableDashAddress)
        XCTAssertFalse(WiFiIPv4("239.1.2.3")!.isUsableDashAddress)
        XCTAssertFalse(WiFiIPv4("255.255.255.255")!.isUsableDashAddress)
        // Phone address on the bike Wi-Fi: additionally not link-local.
        XCTAssertTrue(WiFiIPv4("192.168.0.50")!.isUsableLocalAddress)
        XCTAssertFalse(WiFiIPv4("169.254.7.7")!.isUsableLocalAddress)
    }

    func testNetmaskAndPrefix() {
        XCTAssertEqual(WiFiIPv4.netmask(prefixLength: 24).description, "255.255.255.0")
        XCTAssertEqual(WiFiIPv4.netmask(prefixLength: 28).description, "255.255.255.240")
        XCTAssertEqual(WiFiIPv4.netmask(prefixLength: 0).description, "0.0.0.0")
        XCTAssertEqual(WiFiIPv4.netmask(prefixLength: 32).description, "255.255.255.255")
        XCTAssertEqual(WiFiIPv4.prefixLength(netmask: WiFiIPv4("255.255.255.0")!), 24)
        XCTAssertEqual(WiFiIPv4.prefixLength(netmask: WiFiIPv4("255.255.255.240")!), 28)
        XCTAssertEqual(WiFiIPv4.prefixLength(netmask: WiFiIPv4("255.0.0.0")!), 8)
        XCTAssertEqual(WiFiIPv4.prefixLength(netmask: WiFiIPv4("0.0.0.0")!), 0)
        XCTAssertEqual(WiFiIPv4.prefixLength(netmask: WiFiIPv4("255.255.255.255")!), 32)
        XCTAssertNil(WiFiIPv4.prefixLength(netmask: WiFiIPv4("255.0.255.0")!))
        XCTAssertNil(WiFiIPv4.prefixLength(netmask: WiFiIPv4("0.255.255.255")!))
    }

    /// session-network.md §4.2 `gatewayForSubnet` vectors (D).
    func testGatewayForSubnetSpecVectors() {
        let vectors: [(String, Int, String?)] = [
            ("192.168.0.50", 24, "192.168.0.1"),
            ("192.168.49.132", 24, "192.168.49.1"),
            ("192.168.4.2", 24, "192.168.4.1"),
            ("172.20.10.2", 28, "172.20.10.1"),
            ("10.0.0.7", 8, "10.0.0.1"),
            ("192.168.49.1", 24, nil),
        ]
        for (ip, p, expected) in vectors {
            XCTAssertEqual(WiFiIPv4.gatewayForSubnet(WiFiIPv4(ip)!, prefixLength: p)?.description, expected, "\(ip)/\(p)")
        }
        // Prefix outside 1…31 → nil.
        XCTAssertNil(WiFiIPv4.gatewayForSubnet(WiFiIPv4("192.168.0.50")!, prefixLength: 32))
        XCTAssertNil(WiFiIPv4.gatewayForSubnet(WiFiIPv4("192.168.0.50")!, prefixLength: 0))
        XCTAssertEqual(WiFiIPv4.gatewayForSubnet(WiFiIPv4("192.168.0.50")!, prefixLength: 31)?.description, "192.168.0.51")
    }

    func testSubnets() {
        let s = WiFiSubnet("192.168.0.77/24")!
        XCTAssertEqual(s.description, "192.168.0.0/24")
        XCTAssertTrue(s.contains("192.168.0.1"))
        XCTAssertFalse(s.contains("192.168.1.1"))
        XCTAssertFalse(s.contains("not an ip"))
        XCTAssertEqual(WiFiSubnet("10.1.2.3")?.prefixLength, 32)
        XCTAssertNil(WiFiSubnet("10.1.2.3/33"))
        XCTAssertNil(WiFiSubnet("10.1.2/8"))
        let known = WiFiSubnet.knownDashSubnets
        XCTAssertTrue(known.contains { $0.contains("192.168.0.1") })
        XCTAssertTrue(known.contains { $0.contains("192.168.49.132") })
        XCTAssertTrue(known.contains { $0.contains("192.168.4.2") })
        XCTAssertFalse(known.contains { $0.contains("10.0.0.1") })
        XCTAssertEqual(WiFiSubnet.knownDashAddresses, ["192.168.0.1", "192.168.49.1"])
    }

    // MARK: Interfaces

    func testPickPrimaryPrefersUsableAddressOnNamedInterface() {
        let all = [
            WiFiInterfaceAddress(interfaceName: "en1", address: WiFiIPv4("10.0.0.5")!),
            WiFiInterfaceAddress(interfaceName: "en0", address: WiFiIPv4("169.254.3.4")!, netmask: WiFiIPv4("255.255.0.0")),
            WiFiInterfaceAddress(interfaceName: "en0", address: WiFiIPv4("192.168.0.50")!, netmask: WiFiIPv4("255.255.255.0")),
            WiFiInterfaceAddress(interfaceName: "en2", address: WiFiIPv4("192.168.49.132")!, isUp: false),
        ]
        let p = WiFiInterfaces.pickPrimary(all, interfaceName: "en0")
        XCTAssertEqual(p?.address.description, "192.168.0.50")
        XCTAssertEqual(p?.prefixLength, 24)
        XCTAssertNil(WiFiInterfaces.pickPrimary(all, interfaceName: "en2"), "down interface ignored")
        XCTAssertNil(WiFiInterfaces.pickPrimary(all, interfaceName: "pdp_ip0"))
        // Link-local only → returned as last resort (DHCP still pending).
        let ll = WiFiInterfaces.pickPrimary([all[1]], interfaceName: "en0")
        XCTAssertEqual(ll?.address.description, "169.254.3.4")
        XCTAssertEqual(ll?.prefixLength, 16)
    }

    func testGetifaddrsFindsLoopback() throws {
        let all = WiFiInterfaces.ipv4Addresses()
        guard !all.isEmpty else { throw XCTSkip("getifaddrs returned no IPv4 interfaces in this sandbox") }
        let lo = all.first { $0.address.description == "127.0.0.1" }
        XCTAssertNotNil(lo)
        XCTAssertEqual(lo?.isLoopback, true)
        XCTAssertEqual(lo?.prefixLength, 8)
        if let lo { XCTAssertEqual(WiFiInterfaces.primaryIPv4(onInterface: lo.interfaceName)?.address.description, "127.0.0.1") }
    }

    // MARK: Snapshot ladder

    func testDashHostCandidatesWithGateway() {
        let s = WiFiSnapshot(isSatisfied: true, interfaceName: "en0", phoneIPv4: "192.168.0.50", prefixLength: 24,
                             gateways: ["192.168.0.1"])
        XCTAssertEqual(s.usablePhoneIPv4, "192.168.0.50")
        XCTAssertEqual(s.subnetGateway, "192.168.0.1")
        XCTAssertEqual(s.dashHostCandidates, ["192.168.0.1"])
        XCTAssertTrue(s.isOn(WiFiSubnet.knownDashSubnets))
    }

    func testDashHostCandidatesWithoutGatewayUsesSubnetDotOne() {
        let s = WiFiSnapshot(isSatisfied: true, interfaceName: "en0", phoneIPv4: "192.168.49.132", prefixLength: 24)
        XCTAssertEqual(s.dashHostCandidates, ["192.168.49.1"])
    }

    func testDashHostCandidatesGatewayDifferentFromSubnetAndUnusableGatewayFiltered() {
        let s = WiFiSnapshot(isSatisfied: true, phoneIPv4: "10.0.0.7", prefixLength: 8, gateways: ["0.0.0.0", "10.0.0.254"])
        XCTAssertEqual(s.usableGateways, ["10.0.0.254"])
        XCTAssertEqual(s.dashHostCandidates, ["10.0.0.254", "10.0.0.1"])
        XCTAssertFalse(s.isOn(WiFiSubnet.knownDashSubnets))
    }

    func testDashHostCandidatesFallBackToKnownAddresses() {
        let unknown = WiFiSnapshot(isSatisfied: true, phoneIPv4: "169.254.9.9", prefixLength: 16)
        XCTAssertNil(unknown.usablePhoneIPv4)
        XCTAssertNil(unknown.subnetGateway)
        XCTAssertEqual(unknown.dashHostCandidates, ["192.168.0.1", "192.168.49.1"])
        XCTAssertEqual(WiFiSnapshot.unavailable.dashHostCandidates, ["192.168.0.1", "192.168.49.1"])
    }

    func testDashHostCandidatesNeverIncludeOurOwnAddress() {
        // Phone is the .1 (we are the group owner): never probe ourselves.
        let s = WiFiSnapshot(isSatisfied: true, phoneIPv4: "192.168.49.1", prefixLength: 24, gateways: ["192.168.49.1"])
        XCTAssertFalse(s.dashHostCandidates.contains("192.168.49.1"))
    }

    func testSnapshotDescription() {
        let s = WiFiSnapshot(isSatisfied: true, interfaceName: "en0", phoneIPv4: "192.168.0.50", prefixLength: 24,
                             gateways: ["192.168.0.1"], ssid: "CFMOTO-f46457")
        XCTAssertEqual(s.description, "wifi=up iface=en0 ip=192.168.0.50/24 gw=192.168.0.1 ssid=CFMOTO-f46457")
        let d = WiFiSnapshot(isSatisfied: false, isLocalNetworkDenied: true, unsatisfiedReason: "localNetworkDenied")
        XCTAssertEqual(d.description, "wifi=down localNetworkDenied reason=localNetworkDenied")
    }

    // MARK: Bonjour TXT

    func testTXTLookupAndPackage() {
        let txt = ["huid": "6GUV", "PackageName": " net.easyconn ", "ip": "192.168.0.1", "port": "10930", "empty": "  "]
        XCTAssertEqual(EasyConnTXT.value(txt, "huid"), "6GUV")
        XCTAssertEqual(EasyConnTXT.value(txt, "HUID"), "6GUV")
        XCTAssertNil(EasyConnTXT.value(txt, "empty"))
        XCTAssertEqual(EasyConnTXT.packageName(txt), "net.easyconn")
        XCTAssertEqual(EasyConnTXT.packageName(["package": "x.y"]), "x.y")
        XCTAssertNil(EasyConnTXT.packageName([:]))
        XCTAssertEqual(EasyConnTXT.serviceType, "_EasyConn._tcp")
    }

    func testTXTEndpoint() {
        XCTAssertTrue(EasyConnTXT.endpoint(["ip": "192.168.0.1", "port": "10930"])! == ("192.168.0.1", 10930))
        XCTAssertTrue(EasyConnTXT.endpoint(["IP": " 192.168.49.1 ", "Port": "10931"])! == ("192.168.49.1", 10931))
        XCTAssertNil(EasyConnTXT.endpoint(["ip": "192.168.0.1"]))
        XCTAssertNil(EasyConnTXT.endpoint(["ip": "192.168.0.1", "port": "0"]))
        XCTAssertNil(EasyConnTXT.endpoint(["ip": "192.168.0.1", "port": "70000"]))
        XCTAssertNil(EasyConnTXT.endpoint(["ip": "127.0.0.1", "port": "10930"]))
        XCTAssertNil(EasyConnTXT.endpoint(["ip": "fe80::1", "port": "10930"]))
        XCTAssertTrue(EasyConnTXT.isUsable(host: "192.168.0.1", port: 10930))
        XCTAssertFalse(EasyConnTXT.isUsable(host: "0.0.0.0", port: 10930))
        XCTAssertFalse(EasyConnTXT.isUsable(host: "192.168.0.1", port: 0))
    }

    // MARK: Broadcaster

    func testBroadcasterFanOutInitialValueAndFinish() async {
        let b = OCMPlatformBroadcaster<Int>()
        let s1 = b.stream(initial: 0)
        let s2 = b.stream()
        XCTAssertEqual(b.subscriberCount, 2)
        b.yield(1)
        b.yield(2)
        b.finish()
        var got1: [Int] = []
        for await v in s1 { got1.append(v) }
        var got2: [Int] = []
        for await v in s2 { got2.append(v) }
        XCTAssertEqual(got1, [0, 1, 2])
        XCTAssertEqual(got2, [1, 2])
        XCTAssertEqual(b.subscriberCount, 0)
        // Streams created after finish() end immediately.
        var late: [Int] = []
        for await v in b.stream(initial: 9) { late.append(v) }
        XCTAssertEqual(late, [])
    }

    func testBroadcasterUnregistersTerminatedStreams() async throws {
        let b = OCMPlatformBroadcaster<Int>()
        let task = Task {
            var n = 0
            for await _ in b.stream() { n += 1 }
            return n
        }
        for _ in 0 ..< 50 where b.subscriberCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(b.subscriberCount, 1)
        task.cancel()
        _ = await task.value
        for _ in 0 ..< 50 where b.subscriberCount != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(b.subscriberCount, 0)
    }
}
