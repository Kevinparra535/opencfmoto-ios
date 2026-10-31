// SPDX-License-Identifier: AGPL-3.0-or-later
// The loopback testing hook of ConnectionModel (Testing/ConnectionTestingHooks.swift) used by the
// iOS app's `-e2eFakeDash` mode: overrides reach the link tuning, a fake dash on 127.0.0.1 is probed
// and can call back when the phone side is presented as 127.0.0.2, and — the reason the hook
// exists — without a distinct phone address the loopback dash is never probed.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

/// A Wi-Fi port that is already on a fixed network (the app's e2e fake Wi-Fi does the same).
private final class FixedNetworkWifi: WifiJoining, @unchecked Sendable {
    let supportsAutomaticJoin = true
    let network: WifiNetworkInfo
    init(_ network: WifiNetworkInfo) { self.network = network }
    func join(ssid: String, passphrase: String?) async throws -> WifiJoinResult { .alreadyJoined }
    func forget(ssid: String) {}
    func currentNetwork() async -> WifiNetworkInfo { network }
    func networkUpdates() -> AsyncStream<WifiNetworkInfo> {
        let current = network
        return AsyncStream { $0.yield(current) }
    }
}

final class ConnectionTestingHooksTests: XCTestCase {
    private static let ssid = "CFMOTO-E2E16"
    private static let raw = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=E2E0&action=1&ssid=CFMOTO-E2E16&pwd=e2e-fake-dash&auth=wpa2-psk"

    private static func loopbackNetwork(phoneIPv4: String) -> WifiNetworkInfo {
        WifiNetworkInfo(isWifiAvailable: true, ssid: ssid, interfaceName: "lo0", phoneIPv4: phoneIPv4,
                        gateway: "127.0.0.1", dashHostCandidates: ["127.0.0.1"])
    }

    @MainActor
    func testOverridesReplaceTheLinkTuning() async {
        let h = AppTestHarness()
        var timings = LinkTimings()
        timings.heartbeatInterval = 1.5
        h.connection.applyTestingOverrides(ConnectionTestingOverrides(
            interfaceProvider: { [InterfaceAddress(name: "lo0", ipv4: "127.0.0.9", netmask: "255.0.0.0")] },
            linkTimings: timings, connectBackTimeout: 4, autoConnectDelay: 0.25))
        XCTAssertEqual(h.connection.tuning.interfaceProvider?().map(\.ipv4), ["127.0.0.9"])
        XCTAssertEqual(h.connection.tuning.linkTimings.heartbeatInterval, 1.5)
        XCTAssertEqual(h.connection.tuning.connectBackTimeout, 4)
        XCTAssertEqual(h.connection.tuning.autoConnectDelay, 0.25)

        // Empty overrides keep everything.
        h.connection.applyTestingOverrides(ConnectionTestingOverrides())
        XCTAssertEqual(h.connection.tuning.interfaceProvider?().map(\.ipv4), ["127.0.0.9"])
        XCTAssertEqual(h.connection.tuning.connectBackTimeout, 4)
    }

    func testLoopbackPresetPresentsThePhoneOnLo0() {
        let addresses = ConnectionTestingOverrides.loopback().interfaceProvider?() ?? []
        XCTAssertEqual(addresses, [InterfaceAddress(name: "lo0", ipv4: "127.0.0.2", netmask: "255.0.0.0")])
        // The dash (127.0.0.1) is a candidate for that phone address; the phone address itself is not.
        let local = InterfaceAddresses.pickBikeIPv4(from: addresses, interfaceName: "lo0", subnetHint: "127.0.0.1")
        XCTAssertEqual(local?.ipv4, "127.0.0.2")
        XCTAssertEqual(InterfaceAddresses.gatewayCandidates(dashHost: nil, injectedGateway: "127.0.0.1", local: local),
                       ["127.0.0.1"])
    }

    @MainActor
    func testLoopbackOverridesProbeAFakeDashOnLoopbackThatCallsBack() async throws {
        let net = LinkMemoryNetwork(phoneHost: "127.0.0.1")
        let dash = LinkFakeDash(network: net, host: "127.0.0.1")
        dash.installProbeServer()
        let wifi = FixedNetworkWifi(Self.loopbackNetwork(phoneIPv4: ConnectionTestingOverrides.loopbackPhoneIPv4))
        let h = AppTestHarness(network: net) { $0.wifi = wifi }
        h.addBike(raw: Self.raw)
        h.connection.applyTestingOverrides(.loopback())

        h.connection.connect()
        let probed = await eventually { dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        XCTAssertEqual(net.listenLog, [10922, 10921, 10920])
        XCTAssertEqual(net.connectLog.first, "127.0.0.1:10930")
        XCTAssertEqual(h.connection.phase, .linking)

        // The dash calls back (CAR_CTRL on :10922) and gets its reply.
        let ctrl = try dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        let reply = try await ctrl.next()
        XCTAssertEqual(reply.frame.cmd, 0x10001)
        let handshaking = await eventually { h.connection.diagnostics.state == .handshaking }
        XCTAssertTrue(handshaking, "\(h.connection.diagnostics.state)")

        h.connection.stop()
        ctrl.close()
        let closed = await linkEventually { net.openListenerPorts.isEmpty }
        XCTAssertTrue(closed)
    }

    @MainActor
    func testWithoutADistinctPhoneAddressTheLoopbackDashIsNeverProbed() async {
        let net = LinkMemoryNetwork(phoneHost: "127.0.0.1")
        let dash = LinkFakeDash(network: net, host: "127.0.0.1")
        dash.installProbeServer()
        // The phone address equals the dash address: the link never probes its own address.
        let wifi = FixedNetworkWifi(Self.loopbackNetwork(phoneIPv4: "127.0.0.1"))
        let h = AppTestHarness(network: net) { $0.wifi = wifi }
        h.addBike(raw: Self.raw)

        h.connection.connect()
        let failed = await eventually { h.connection.phase == .error }
        XCTAssertTrue(failed)
        XCTAssertEqual(h.connection.issue, .wifiUnavailable)
        XCTAssertTrue(net.connectLog.isEmpty, "\(net.connectLog)")
        XCTAssertEqual(dash.acceptedCount.current, 0)
    }
}
