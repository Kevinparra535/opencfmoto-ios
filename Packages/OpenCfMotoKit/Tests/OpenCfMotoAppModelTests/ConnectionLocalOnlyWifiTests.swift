// SPDX-License-Identifier: AGPL-3.0-or-later
// Field log 1 replayed on the session model. On the dash's Wi-Fi (no internet) iOS reports the Wi-Fi
// path unsatisfied (notAvailable) although the phone holds its DHCP address. The iOS adapter now
// reports that network up and local-only (subnet .1 as the gateway): join, link, supervision and
// auto-connect must treat it like any Wi-Fi, and the logs must say what it is.
import Foundation
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

/// Networks of the field sequence (fixture SSID, never the owner's).
enum FieldWifi {
    /// The bike Wi-Fi as the iOS adapter reports it now: path unsatisfied, en0 with its DHCP address.
    nonisolated static func bike(ssid: String?, ip: String = "192.168.0.50") -> WifiNetworkInfo {
        WifiNetworkInfo(isWifiAvailable: true, ssid: ssid, interfaceName: "en0", phoneIPv4: ip, gateway: "192.168.0.1",
                        dashHostCandidates: ["192.168.0.1"], isLocalOnly: true, pathUnsatisfiedReason: "notAvailable")
    }

    /// No Wi-Fi address ("wifi=down reason=notAvailable"; what the old adapter said on the bike Wi-Fi).
    nonisolated static let down = WifiNetworkInfo(pathUnsatisfiedReason: "notAvailable")

    /// A normal Wi-Fi with internet.
    nonisolated static let home = WifiNetworkInfo(isWifiAvailable: true, ssid: "HomeWiFi", interfaceName: "en0",
                                                  phoneIPv4: "10.0.0.5", gateway: "10.0.0.1",
                                                  dashHostCandidates: ["10.0.0.1"])

    /// A home Wi-Fi on the dash's address plan (192.168.0.x, a common router default) as the free
    /// flavor sees it: SSID unreadable, internet, so the path is satisfied (review NEWCOMER-1).
    nonisolated static let homeOnDashPlan = WifiNetworkInfo(isWifiAvailable: true, interfaceName: "en0",
                                                            phoneIPv4: "192.168.0.23", gateway: "192.168.0.1",
                                                            dashHostCandidates: ["192.168.0.1"])
}

/// `WifiJoining` fake whose join leaves the phone on a scripted network (PreviewWifi's join always
/// switches to a satisfied-looking one).
final class ScriptedWifi: WifiJoining, @unchecked Sendable {
    private let lock = NSLock()
    private var network: WifiNetworkInfo
    private var continuations: [UUID: AsyncStream<WifiNetworkInfo>.Continuation] = [:]
    private var _joinResult: Result<WifiJoinResult, WifiJoinFailure> = .success(.joined)
    private var _networkAfterJoin: WifiNetworkInfo?
    private var _joinedSSIDs: [String] = []
    let supportsAutomaticJoin: Bool

    init(supportsAutomaticJoin: Bool = true, network: WifiNetworkInfo) {
        self.supportsAutomaticJoin = supportsAutomaticJoin
        self.network = network
    }

    /// Result of every `join`; `networkAfterJoin` (if any) is published before it returns.
    var joinResult: Result<WifiJoinResult, WifiJoinFailure> {
        get { lock.withLock { _joinResult } }
        set { lock.withLock { _joinResult = newValue } }
    }

    var networkAfterJoin: WifiNetworkInfo? {
        get { lock.withLock { _networkAfterJoin } }
        set { lock.withLock { _networkAfterJoin = newValue } }
    }

    var joinedSSIDs: [String] { lock.withLock { _joinedSSIDs } }

    func join(ssid: String, passphrase: String?) async throws -> WifiJoinResult {
        let (result, after) = lock.withLock { () -> (Result<WifiJoinResult, WifiJoinFailure>, WifiNetworkInfo?) in
            _joinedSSIDs.append(ssid)
            return (_joinResult, _networkAfterJoin)
        }
        if let after { setNetwork(after) }
        return try result.get()
    }

    func forget(ssid: String) {}

    func currentNetwork() async -> WifiNetworkInfo { lock.withLock { network } }

    func networkUpdates() -> AsyncStream<WifiNetworkInfo> {
        AsyncStream { continuation in
            let id = UUID()
            let current = lock.withLock { () -> WifiNetworkInfo in
                continuations[id] = continuation
                return network
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.continuations[id] = nil }
            }
        }
    }

    func setNetwork(_ info: WifiNetworkInfo) {
        let targets = lock.withLock { () -> [AsyncStream<WifiNetworkInfo>.Continuation] in
            network = info
            return Array(continuations.values)
        }
        for c in targets { c.yield(info) }
    }
}

final class ConnectionLocalOnlyWifiTests: XCTestCase {
    static let noInternetNote = "Wi-Fi up without internet (iOS reports the path unsatisfied: notAvailable) \u{2014} using the interface directly"

    /// Messages logged since `before` (ids are increasing).
    private func messages(since before: UInt64) -> [String] {
        Log.shared.lines().filter { $0.id > before }.map(\.message)
    }

    private func lastLogID() -> UInt64 { Log.shared.lines().last?.id ?? 0 }

    /// The dash connects back and streams a few frames (ConnectionReviewFixTests' sequence).
    private func streamFromFakeDash(_ dash: LinkFakeDash) async throws -> [() -> Void] {
        let ctrl = try dash.openControl()
        try await ctrl.send(PxcFrame(cmd: 0x10000))
        _ = try await ctrl.nextRaw()
        try await ctrl.send(cmd: 0x10010, json: LinkDashSamples.cfdl16ClientInfo)
        _ = try await ctrl.next()
        let mctl = try dash.openMedia(port: 10921)
        try await mctl.send(cmd: 16, body: LinkDashSamples.configCaptureBody(width: 800, height: 386))
        _ = try await mctl.reply()
        try await mctl.send(cmd: 112)
        _ = try await mctl.reply()
        let mdata = try dash.openMedia(port: 10920)
        for _ in 1 ... 3 {
            try await mdata.send(cmd: 114)
            _ = try await mdata.frame()
        }
        return [ctrl.close, mctl.close, mdata.close]
    }

    // MARK: The field sequence

    /// Connect → the hotspot join is confirmed on the local-only bike Wi-Fi → the link starts there and
    /// the dash streams. Field log 1 instead had "not associated after 15 s", then "Wi-Fi lost: bike
    /// network gone (wifi=down)" right after the manual join.
    @MainActor
    func testJoinOnTheLocalOnlyBikeWifiLinksAndStreamsWithoutAWifiLoss() async throws {
        let net = LinkMemoryNetwork(phoneHost: "192.168.0.50")
        let dash = LinkFakeDash(network: net, host: "192.168.0.1")
        dash.installProbeServer()
        let wifi = ScriptedWifi(network: FieldWifi.down)
        let h = AppTestHarness(network: net, frameSource: TestFrameSource()) { $0.wifi = wifi }
        let (_, qr) = h.addBike()
        wifi.networkAfterJoin = FieldWifi.bike(ssid: qr.ssid)
        let before = lastLogID()

        h.connection.connect()
        let probed = await eventually { dash.acceptedCount.current == 1 }
        XCTAssertTrue(probed)
        let closers = try await streamFromFakeDash(dash)
        let streaming = await eventually { h.connection.phase == .streaming }
        XCTAssertTrue(streaming)
        await settle(0.3)
        XCTAssertEqual(h.connection.phase, .streaming)
        XCTAssertEqual(wifi.joinedSSIDs, [qr.ssid])
        XCTAssertEqual(h.connection.sessionNetwork, FieldWifi.bike(ssid: qr.ssid))

        let lines = messages(since: before)
        XCTAssertFalse(lines.contains { $0.hasPrefix("Wi-Fi lost") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains(SessionText.waitingForBikeWifi(h.language)) }, "\(lines)")
        XCTAssertEqual(lines.filter { $0.hasPrefix(Self.noInternetNote) }.count, 1, "\(lines)")
        XCTAssertTrue(lines.contains("\u{2192} starting PXC link (own dash UI) on wifi=up(local-only, path=unsatisfied:notAvailable) ssid=\(qr.ssid) iface=en0 ip=192.168.0.50 gw=192.168.0.1"),
                      "\(lines)")
        h.connection.stop()
        closers.forEach { $0() }
    }

    /// The field's own path: the automatic join failed and the manual-join prompt came up while the
    /// phone already sat on the bike Wi-Fi. Its SSID is readable there now: the session goes on at once.
    @MainActor
    func testManualJoinPromptGoesOnAtOnceOnTheLocalOnlyBikeWifi() async {
        let h = AppTestHarness()
        let (_, qr) = h.addBike()
        h.wifi.setNetwork(FieldWifi.bike(ssid: qr.ssid))
        h.wifi.nextJoinResult = .failure(WifiJoinFailure(message: "The phone did not join the bike.", suggestsManualJoin: true))
        let before = lastLogID()
        h.connection.connect()
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        XCTAssertNil(h.connection.manualJoin)
        await settle(0.2)
        XCTAssertNotEqual(h.connection.phase, .reconnecting)
        let lines = messages(since: before)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Wi-Fi joined: \(qr.ssid) (manual, wifi=up(local-only, path=unsatisfied:notAvailable)") },
                      "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("rider confirmed") }, "no tap on \u{201C}I've joined\u{201D} needed")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Wi-Fi lost") }, "\(lines)")
        h.connection.stop()
    }

    /// SSID unreadable and nothing changes while the prompt is up: the rider confirms, the link runs on
    /// the local-only Wi-Fi and the supervision keeps it (same network as the one joined).
    @MainActor
    func testRiderConfirmedManualJoinOnALocalOnlyWifiWithoutSSID() async {
        let h = AppTestHarness()
        h.addBike()
        h.wifi.setNetwork(FieldWifi.bike(ssid: nil))
        h.wifi.nextJoinResult = .failure(WifiJoinFailure(message: "The phone did not join the bike.", suggestsManualJoin: true))
        let before = lastLogID()
        h.connection.connect()
        let prompted = await eventually { h.connection.manualJoin != nil }
        XCTAssertTrue(prompted)
        await settle(0.1)
        XCTAssertNil(h.connection.link)
        h.connection.confirmManualJoin()
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        XCTAssertEqual(h.connection.sessionNetwork, FieldWifi.bike(ssid: nil))
        // A DHCP renewal on the same network is no loss either.
        h.wifi.setNetwork(FieldWifi.bike(ssid: nil, ip: "192.168.0.77"))
        await settle(0.2)
        XCTAssertNotEqual(h.connection.phase, .reconnecting)
        let lines = messages(since: before)
        XCTAssertFalse(lines.contains { $0.hasPrefix("Wi-Fi lost") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("\u{2192} starting PXC link (own dash UI) on wifi=up(local-only, path=unsatisfied:notAvailable) iface=en0") },
                      "\(lines)")
        h.connection.stop()
    }

    /// Free flavor (no SSID): an address on the dash's subnet skips the manual join, as on any Wi-Fi.
    @MainActor
    func testFreeFlavorSkipsTheManualJoinOnTheLocalOnlyBikeWifi() async {
        let h = AppTestHarness(flavor: .free)
        h.wifi.nextJoinResult = .success(.manualJoinRequired)
        h.wifi.setNetwork(FieldWifi.bike(ssid: nil))
        h.addBike()
        h.connection.connect()
        let linked = await eventually { h.connection.link != nil }
        XCTAssertTrue(linked)
        XCTAssertNil(h.connection.manualJoin)
        h.connection.stop()
    }

    /// Field log 1 at 22:26:45 said "Auto-connect idle … not on its Wi-Fi (wifi=down)".
    @MainActor
    func testAutoConnectStartsOnTheLocalOnlyBikeWifi() async {
        let h = AppTestHarness()
        let (bike, qr) = h.addBike()
        h.wifi.setNetwork(FieldWifi.bike(ssid: qr.ssid))
        let before = lastLogID()
        h.connection.maybeAutoConnect()
        let started = await eventually { h.connection.session != nil }
        XCTAssertTrue(started)
        XCTAssertEqual(h.connection.session?.trigger, .auto)
        let lines = messages(since: before)
        XCTAssertTrue(lines.contains("\u{2192} Auto-connect: '\(bike.name)' \u{2014} already on its Wi-Fi (wifi=up(local-only, path=unsatisfied:notAvailable) ssid=\(qr.ssid) iface=en0 ip=192.168.0.50 gw=192.168.0.1). Disable in Setup \u{25B8} Startup."),
                      "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix(Self.noInternetNote) }, "\(lines)")
        h.connection.stop()
    }

    /// The bike goes off (the address disappears) and comes back: lost, then re-acquired on the same
    /// local-only network; the "no internet" note is not repeated for it.
    @MainActor
    func testLocalOnlyBikeWifiLossAndReturnRestartsTheLink() async {
        let wifi = ScriptedWifi(network: FieldWifi.down)
        let h = AppTestHarness { $0.wifi = wifi }
        let (_, qr) = h.addBike()
        h.connection.tuning.wifiParkGrace = 30
        wifi.networkAfterJoin = FieldWifi.bike(ssid: qr.ssid)
        let before = lastLogID()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        let firstSerial = h.connection.linkSerial

        wifi.setNetwork(FieldWifi.down)
        let lost = await eventually { h.connection.phase == .reconnecting }
        XCTAssertTrue(lost)
        XCTAssertEqual(h.connection.detail, SessionText.waitingForBikeWifi(h.language))

        wifi.setNetwork(FieldWifi.bike(ssid: qr.ssid, ip: "192.168.0.51"))
        let restarted = await eventually { h.connection.link != nil && h.connection.linkSerial != firstSerial && h.connection.phase != .reconnecting }
        XCTAssertTrue(restarted)
        let lines = messages(since: before)
        XCTAssertEqual(lines.filter { $0.hasPrefix("Wi-Fi lost: bike network gone (wifi=down)") }.count, 1, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Wi-Fi re-acquired: \(qr.ssid)") }, "\(lines)")
        XCTAssertEqual(lines.filter { $0.hasPrefix(Self.noInternetNote) }.count, 1, "\(lines)")
        h.connection.stop()
    }

    /// A rider who confirms the manual join before the Wi-Fi is up (field log 1: "rider confirmed the
    /// manual join … wifi=down"): that network fingerprints nothing, so the bike Wi-Fi appearing later
    /// (SSID unknown) is still recognised by its dash subnet and the link restarts there.
    @MainActor
    func testManualJoinConfirmedBeforeTheWifiIsUpRecognisesTheBikeLater() async {
        let h = AppTestHarness(flavor: .free)
        h.wifi.nextJoinResult = .success(.manualJoinRequired)
        h.wifi.setNetwork(FieldWifi.down)
        h.addBike()
        h.connection.tuning.wifiParkGrace = 30
        h.connection.connect()
        _ = await eventually { h.connection.manualJoin != nil }
        h.connection.confirmManualJoin()
        let lost = await eventually { h.connection.phase == .reconnecting }
        XCTAssertTrue(lost)
        XCTAssertNil(h.connection.sessionNetwork)
        let serial = h.connection.linkSerial
        h.wifi.setNetwork(FieldWifi.bike(ssid: nil))
        let retried = await eventually { h.connection.unconfirmedNetwork == FieldWifi.bike(ssid: nil) }
        XCTAssertTrue(retried)
        let relinked = await eventually { h.connection.link != nil && h.connection.linkSerial != serial }
        XCTAssertTrue(relinked)
        h.connection.stop()
    }

    // MARK: Rules and logs

    func testRulesTreatALocalOnlyWifiLikeAnyWifi() {
        let ssid = "CFMOTO-f46457"
        let bike = FieldWifi.bike(ssid: ssid)
        let hidden = FieldWifi.bike(ssid: nil)
        XCTAssertTrue(ConnectionModel.isOnBikeNetwork(bike, ssid: ssid))
        XCTAssertTrue(ConnectionModel.isOnBikeNetwork(hidden, ssid: ssid), "dash subnet")
        XCTAssertTrue(ConnectionModel.isOnBikeNetwork(hidden, ssid: ssid, joined: hidden))
        XCTAssertTrue(ConnectionModel.isOnBikeNetwork(FieldWifi.bike(ssid: nil, ip: "192.168.0.77"), ssid: ssid, joined: hidden))
        XCTAssertFalse(ConnectionModel.isOnBikeNetwork(FieldWifi.down, ssid: ssid))
        XCTAssertFalse(ConnectionModel.isOnBikeNetwork(FieldWifi.home, ssid: ssid, joined: hidden))
        // The same bike seen through a satisfied path (DHCP router .1) is the same network.
        XCTAssertTrue(ConnectionModel.isSameNetwork(hidden, as: AppTestHarness.bikeNetwork(ssid: nil)))
        XCTAssertTrue(ConnectionModel.isConfirmedBikeNetwork(bike, ssid: ssid))
        XCTAssertTrue(ConnectionModel.isAlreadyOnBikeNetwork(bike, ssid: ssid))
        XCTAssertTrue(ConnectionModel.isAlreadyOnBikeNetwork(hidden, ssid: ssid))
        XCTAssertTrue(ConnectionModel.matchesManualJoin(bike, ssid: ssid, baseline: bike), "the SSID decides")
        XCTAssertTrue(ConnectionModel.matchesManualJoin(hidden, ssid: ssid, baseline: FieldWifi.down))
        XCTAssertFalse(ConnectionModel.matchesManualJoin(hidden, ssid: ssid, baseline: hidden))
        // Some other access point without internet is not the bike.
        let otherAP = WifiNetworkInfo(isWifiAvailable: true, interfaceName: "en0", phoneIPv4: "10.10.10.5",
                                      gateway: "10.10.10.1", isLocalOnly: true, pathUnsatisfiedReason: "notAvailable")
        XCTAssertFalse(ConnectionModel.isOnBikeNetwork(otherAP, ssid: ssid))
        XCTAssertFalse(ConnectionModel.isAlreadyOnBikeNetwork(otherAP, ssid: ssid))
        XCTAssertFalse(ConnectionModel.matchesManualJoin(otherAP, ssid: ssid, baseline: FieldWifi.down))
    }

    func testDescribeSaysLocalOnlyAndThePathReason() {
        XCTAssertEqual(ConnectionModel.describe(FieldWifi.bike(ssid: "CFMOTO-f46457")),
                       "wifi=up(local-only, path=unsatisfied:notAvailable) ssid=CFMOTO-f46457 iface=en0 ip=192.168.0.50 gw=192.168.0.1")
        var unknownReason = FieldWifi.bike(ssid: nil)
        unknownReason.pathUnsatisfiedReason = nil
        XCTAssertEqual(ConnectionModel.describe(unknownReason),
                       "wifi=up(local-only, path=unsatisfied:unknown) iface=en0 ip=192.168.0.50 gw=192.168.0.1")
        // Unchanged on a normal Wi-Fi and without Wi-Fi.
        XCTAssertEqual(ConnectionModel.describe(FieldWifi.home), "wifi=up ssid=HomeWiFi iface=en0 ip=10.0.0.5 gw=10.0.0.1")
        XCTAssertEqual(ConnectionModel.describe(FieldWifi.down), "wifi=down")
        XCTAssertEqual(ConnectionModel.describe(.unavailable), "wifi=down")
    }

    /// The note comes once per local-only network, again after a normal Wi-Fi in between.
    @MainActor
    func testNoInternetNoteIsLoggedOncePerNetwork() async {
        let wifi = ScriptedWifi(network: FieldWifi.down)
        let h = AppTestHarness { $0.wifi = wifi }
        let (_, qr) = h.addBike()
        h.connection.tuning.wifiParkGrace = 30
        wifi.networkAfterJoin = FieldWifi.bike(ssid: qr.ssid)
        let before = lastLogID()
        h.connection.connect()
        _ = await eventually { h.connection.link != nil }
        wifi.setNetwork(FieldWifi.bike(ssid: qr.ssid, ip: "192.168.0.77")) // same network, new lease
        await settle(0.1)
        XCTAssertEqual(messages(since: before).filter { $0.hasPrefix(Self.noInternetNote) }.count, 1)
        wifi.setNetwork(FieldWifi.home)
        _ = await eventually { h.connection.phase == .reconnecting }
        wifi.setNetwork(FieldWifi.bike(ssid: qr.ssid))
        _ = await eventually { h.connection.phase != .reconnecting }
        await settle(0.1)
        XCTAssertEqual(messages(since: before).filter { $0.hasPrefix(Self.noInternetNote) }.count, 2)
        h.connection.stop()
    }
}
