// SPDX-License-Identifier: AGPL-3.0-or-later
// Field log 1: on the dash's Wi-Fi (no internet) NWPathMonitor(requiredInterfaceType: .wifi) stays
// unsatisfied (notAvailable, no interface, no gateway) although the Wi-Fi interface holds its DHCP
// address. The snapshot built from those path facts + getifaddrs must say "up, local-only" (runs on
// Linux too; the NWPath → facts step is a plain field copy on Apple platforms).

import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoApple

final class PlatformWifiLocalOnlyTests: XCTestCase {
    /// The phone's interfaces on the bike Wi-Fi (fixture values): cellular, a VPN tunnel and en0.
    static let bikeInterfaces = [
        WiFiInterfaceAddress(interfaceName: "lo0", address: WiFiIPv4("127.0.0.1")!, netmask: WiFiIPv4("255.0.0.0"),
                             isLoopback: true),
        WiFiInterfaceAddress(interfaceName: "pdp_ip0", address: WiFiIPv4("10.64.1.9")!, netmask: WiFiIPv4("255.255.255.255")),
        WiFiInterfaceAddress(interfaceName: "ipsec4", address: WiFiIPv4("192.0.2.7")!, netmask: WiFiIPv4("255.0.0.0")),
        WiFiInterfaceAddress(interfaceName: "en0", address: WiFiIPv4("192.168.0.50")!, netmask: WiFiIPv4("255.255.255.0")),
    ]

    static let unsatisfied = WiFiPathFacts(isSatisfied: false, unsatisfiedReason: "notAvailable")

    func testUnsatisfiedPathWithAnAddressIsUpAndLocalOnly() {
        let s = WiFiSnapshot(path: Self.unsatisfied, addresses: Self.bikeInterfaces, fallbackInterfaceName: "en0")
        XCTAssertFalse(s.isSatisfied)
        XCTAssertTrue(s.isUp)
        XCTAssertTrue(s.isLocalOnly)
        XCTAssertEqual(s.interfaceName, "en0")
        XCTAssertEqual(s.usablePhoneIPv4, "192.168.0.50")
        XCTAssertEqual(s.prefixLength, 24)
        XCTAssertEqual(s.unsatisfiedReason, "notAvailable")
        XCTAssertEqual(s.gateways, [])
        XCTAssertEqual(s.primaryGateway, "192.168.0.1", "no path gateway: the subnet .1")
        XCTAssertEqual(s.dashHostCandidates, ["192.168.0.1"])
        XCTAssertTrue(s.isOn(WiFiSubnet.knownDashSubnets))
        XCTAssertEqual(s.description, "wifi=up(local-only, path=unsatisfied:notAvailable) iface=en0 ip=192.168.0.50/24 gw=192.168.0.1(subnet)")
        var named = s
        named.ssid = "CFMOTO-f46457"
        XCTAssertEqual(named.description,
                       "wifi=up(local-only, path=unsatisfied:notAvailable) iface=en0 ip=192.168.0.50/24 gw=192.168.0.1(subnet) ssid=CFMOTO-f46457")
    }

    func testNoWifiAddressIsDownAsBefore() {
        // Cellular only: en0 carries no IPv4. Same snapshot and log text as before the change.
        let cellular = Self.bikeInterfaces.filter { $0.interfaceName != "en0" }
        let s = WiFiSnapshot(path: Self.unsatisfied, addresses: cellular, fallbackInterfaceName: "en0")
        XCTAssertFalse(s.isUp)
        XCTAssertFalse(s.isLocalOnly)
        XCTAssertNil(s.interfaceName, "a fallback name without an address is not reported")
        XCTAssertNil(s.phoneIPv4)
        XCTAssertNil(s.primaryGateway)
        XCTAssertEqual(s.description, "wifi=down reason=notAvailable")
        XCTAssertEqual(WiFiSnapshot(path: .none, addresses: [], fallbackInterfaceName: nil), .unavailable)
    }

    func testSelfAssignedAddressIsNotUp() {
        // Associated, DHCP not done: 169.254/16 is no usable address (the dash cannot call it back).
        let linkLocal = [WiFiInterfaceAddress(interfaceName: "en0", address: WiFiIPv4("169.254.7.7")!,
                                              netmask: WiFiIPv4("255.255.0.0"))]
        let s = WiFiSnapshot(path: Self.unsatisfied, addresses: linkLocal, fallbackInterfaceName: "en0")
        XCTAssertFalse(s.isUp)
        XCTAssertFalse(s.isLocalOnly)
        XCTAssertEqual(s.interfaceName, "en0")
        XCTAssertEqual(s.description, "wifi=down iface=en0 ip=169.254.7.7/16 reason=notAvailable")
    }

    func testSatisfiedPathIsUnchanged() {
        // A normal Wi-Fi with internet: the path names the interface and its gateway.
        let path = WiFiPathFacts(isSatisfied: true, interfaceName: "en0", gateways: ["10.0.0.1"])
        let home = [WiFiInterfaceAddress(interfaceName: "en0", address: WiFiIPv4("10.0.0.23")!,
                                         netmask: WiFiIPv4("255.255.255.0"))]
        let s = WiFiSnapshot(path: path, addresses: home, fallbackInterfaceName: "en9")
        XCTAssertTrue(s.isSatisfied)
        XCTAssertTrue(s.isUp)
        XCTAssertFalse(s.isLocalOnly)
        XCTAssertNil(s.unsatisfiedReason)
        XCTAssertEqual(s.primaryGateway, "10.0.0.1")
        XCTAssertEqual(s.description, "wifi=up iface=en0 ip=10.0.0.23/24 gw=10.0.0.1")
        // The path's own interface wins over the fallback.
        let path1 = WiFiPathFacts(isSatisfied: false, unsatisfiedReason: "notAvailable", interfaceName: "en1")
        let two = Self.bikeInterfaces + [WiFiInterfaceAddress(interfaceName: "en1", address: WiFiIPv4("192.168.49.132")!,
                                                              netmask: WiFiIPv4("255.255.255.0"))]
        let s1 = WiFiSnapshot(path: path1, addresses: two, fallbackInterfaceName: "en0")
        XCTAssertEqual(s1.interfaceName, "en1")
        XCTAssertEqual(s1.usablePhoneIPv4, "192.168.49.132")
    }

    func testLocalNetworkDeniedStaysVisible() {
        let denied = WiFiPathFacts(isSatisfied: false, unsatisfiedReason: "localNetworkDenied", isLocalNetworkDenied: true)
        let s = WiFiSnapshot(path: denied, addresses: Self.bikeInterfaces, fallbackInterfaceName: "en0")
        XCTAssertTrue(s.isLocalOnly)
        XCTAssertTrue(s.isLocalNetworkDenied)
        XCTAssertEqual(s.description,
                       "wifi=up(local-only, path=unsatisfied:localNetworkDenied) iface=en0 ip=192.168.0.50/24 gw=192.168.0.1(subnet) localNetworkDenied")
    }

    func testNewAddressRule() {
        let bike = WiFiSnapshot(path: Self.unsatisfied, addresses: Self.bikeInterfaces, fallbackInterfaceName: "en0")
        XCTAssertTrue(bike.hasNewAddress(since: .unavailable), "Wi-Fi was down")
        XCTAssertFalse(bike.hasNewAddress(since: bike), "same address and gateway")
        let home = WiFiSnapshot(isSatisfied: true, interfaceName: "en0", phoneIPv4: "10.0.0.23", prefixLength: 24,
                                gateways: ["10.0.0.1"])
        XCTAssertTrue(bike.hasNewAddress(since: home))
        var renewed = bike
        renewed.phoneIPv4 = "192.168.0.77"
        XCTAssertTrue(renewed.hasNewAddress(since: bike))
        // The same network seen through a satisfied path (gateway listed) is not new.
        let satisfiedBike = WiFiSnapshot(isSatisfied: true, interfaceName: "en0", phoneIPv4: "192.168.0.50",
                                         prefixLength: 24, gateways: ["192.168.0.1"])
        XCTAssertFalse(bike.hasNewAddress(since: satisfiedBike))
    }

    // MARK: Wi-Fi interface without a path interface

    func testWifiInterfaceByFunctionalType() {
        let all = Self.bikeInterfaces + [
            WiFiInterfaceAddress(interfaceName: "en1", address: WiFiIPv4("169.254.3.4")!, netmask: WiFiIPv4("255.255.0.0")),
            WiFiInterfaceAddress(interfaceName: "en2", address: WiFiIPv4("192.168.4.2")!, netmask: WiFiIPv4("255.255.255.0")),
        ]
        func types(_ map: [String: UInt32]) -> (String) -> UInt32? { { map[$0] } }
        // No type readable (not Darwin): iOS's Wi-Fi interface.
        XCTAssertEqual(WiFiInterfaces.wifiInterfaceName(among: all, typeOf: { _ in nil }), "en0")
        // en0 is Wi-Fi.
        XCTAssertEqual(WiFiInterfaces.wifiInterfaceName(among: all, typeOf: types(["en0": 3, "pdp_ip0": 5])), "en0")
        // en0 is wired (a Mac, an iPad adapter): the Wi-Fi interface with a usable address.
        XCTAssertEqual(WiFiInterfaces.wifiInterfaceName(among: all, typeOf: types(["en0": 2, "en1": 3, "en2": 3])), "en2")
        XCTAssertEqual(WiFiInterfaces.wifiInterfaceName(among: all, typeOf: types(["en0": 2, "en1": 3])), "en1")
        // Nothing typed Wi-Fi and en0 known to be something else: no Wi-Fi interface.
        XCTAssertNil(WiFiInterfaces.wifiInterfaceName(among: all, typeOf: types(["en0": 2, "pdp_ip0": 5])))
        // en0 of unknown type: still en0.
        XCTAssertEqual(WiFiInterfaces.wifiInterfaceName(among: all, typeOf: types(["en0": 0])), "en0")
    }

    func testFunctionalTypeOfLoopback() throws {
        #if canImport(Darwin)
        // SIOCGIFFUNCTIONALTYPE works (request code and ifreq layout): lo0 is IFRTYPE_FUNCTIONAL_LOOPBACK.
        XCTAssertEqual(WiFiInterfaces.functionalType(ofInterface: "lo0"), 1)
        XCTAssertNil(WiFiInterfaces.functionalType(ofInterface: "nosuch99"))
        #else
        XCTAssertNil(WiFiInterfaces.functionalType(ofInterface: "lo"))
        #endif
    }
}
