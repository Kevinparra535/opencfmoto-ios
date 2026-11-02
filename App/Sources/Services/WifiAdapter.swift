// SPDX-License-Identifier: AGPL-3.0-or-later
// `WifiJoining` on iOS: WifiJoiner (NEHotspotConfiguration, joinOnce = false, association confirmed)
// + WiFiInfo (NWPathMonitor on .wifi, getifaddrs on that interface, NEHotspotNetwork SSID).
// Free flavor (`OCM_NO_HOTSPOT`, no Hotspot Configuration entitlement): joins are manual — the
// package does not see the app's compilation flags, so the joiner gets `hotspotEnabled: false`.
//
// "Wi-Fi up" = the Wi-Fi path is satisfied OR the Wi-Fi interface holds a usable IPv4: on the dash's
// access point (no internet) iOS keeps the path unsatisfied although the phone has its address
// (field log 1). Such a network is reported up and `isLocalOnly`, with its SSID and the subnet `.1`
// as the gateway when the path lists none.

import Foundation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

final class WifiAdapter: WifiJoining, @unchecked Sendable {
    let supportsAutomaticJoin: Bool
    private let joiner: WifiJoiner
    private let info = WiFiInfo()

    /// Interface re-read while a `networkUpdates()` stream is open: a local-only network's address
    /// comes and goes without any path change (the path stays unsatisfied).
    private static let addressPollInterval: TimeInterval = 2
    /// Faster while associated without a DHCP lease yet (at most 20 times in a row, 10 s).
    private static let leasePollInterval: TimeInterval = 0.5
    private static let leasePollTicks = 20

    init(flavor: BuildFlavor) {
        supportsAutomaticJoin = flavor == .full
        joiner = WifiJoiner(options: WifiJoinOptions(hotspotEnabled: flavor == .full))
        info.start()
    }

    /// "es" / "en" for the join messages (same rule as the app language).
    private static var language: String { WifiJoinMessages.preferredLanguage() }

    func join(ssid: String, passphrase: String?) async throws -> WifiJoinResult {
        do {
            switch try await joiner.join(ssid: ssid, passphrase: passphrase ?? "") {
            case .joined: return .joined
            case .alreadyJoined: return .alreadyJoined
            case .manualJoinRequired: return .manualJoinRequired
            }
        } catch let error as WifiJoinError {
            throw WifiJoinFailure(message: error.message(language: Self.language),
                                  suggestsManualJoin: error.suggestsManualJoin,
                                  userCancelled: error == .userDenied)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let ns = error as NSError
            let generic = WifiJoinError.failed(code: ns.code, domain: ns.domain)
            throw WifiJoinFailure(message: generic.message(language: Self.language), suggestsManualJoin: true)
        }
    }

    func forget(ssid: String) {
        joiner.forget(ssid: ssid)
    }

    func currentNetwork() async -> WifiNetworkInfo {
        _ = await info.firstSnapshot(timeout: 1.0)
        var snapshot = info.refreshedSnapshot() // the address may change without a path change
        if snapshot.isUp { snapshot.ssid = await WiFiInfo.fetchSSID() }
        return Self.map(snapshot)
    }

    func networkUpdates() -> AsyncStream<WifiNetworkInfo> {
        let info = self.info
        _ = info.refreshedSnapshot() // the first value must be the interface as it is now
        let source = info.updates()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                for await update in source {
                    var snapshot = update
                    if snapshot.isUp { snapshot.ssid = await WiFiInfo.fetchSSID() }
                    continuation.yield(Self.map(snapshot))
                }
                continuation.finish()
            }
            // A change found by the re-read is published on `updates()` like a path update.
            let poll = Task {
                var leaseTicks = 0
                while !Task.isCancelled {
                    let now = info.current
                    let leasePending = now.isSatisfied && now.usablePhoneIPv4 == nil
                    leaseTicks = leasePending ? leaseTicks + 1 : 0
                    let fast = leasePending && leaseTicks <= Self.leasePollTicks
                    await sleepSeconds(fast ? Self.leasePollInterval : Self.addressPollInterval)
                    if Task.isCancelled { return }
                    _ = info.refreshedSnapshot()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                poll.cancel()
            }
        }
    }

    private static func map(_ s: WiFiSnapshot) -> WifiNetworkInfo {
        WifiNetworkInfo(isWifiAvailable: s.isUp,
                        ssid: s.ssid,
                        interfaceName: s.interfaceName,
                        phoneIPv4: s.usablePhoneIPv4,
                        gateway: s.primaryGateway,
                        dashHostCandidates: s.dashHostCandidates,
                        isLocalNetworkDenied: s.isLocalNetworkDenied,
                        isLocalOnly: s.isLocalOnly,
                        pathUnsatisfiedReason: s.isSatisfied ? nil : s.unsatisfiedReason)
    }
}
