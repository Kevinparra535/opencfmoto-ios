// SPDX-License-Identifier: AGPL-3.0-or-later
// `WifiJoining` on iOS: WifiJoiner (NEHotspotConfiguration, joinOnce = false, association confirmed)
// + WiFiInfo (NWPathMonitor on .wifi, getifaddrs on that interface, NEHotspotNetwork SSID).
// Free flavor (`OCM_NO_HOTSPOT`, no Hotspot Configuration entitlement): joins are manual — the
// package does not see the app's compilation flags, so the joiner gets `hotspotEnabled: false`.

import Foundation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

final class WifiAdapter: WifiJoining, @unchecked Sendable {
    let supportsAutomaticJoin: Bool
    private let joiner: WifiJoiner
    private let info = WiFiInfo()

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
        var snapshot = info.refreshedSnapshot() // DHCP may have completed without a path change
        if snapshot.isSatisfied { snapshot.ssid = await WiFiInfo.fetchSSID() }
        return Self.map(snapshot)
    }

    func networkUpdates() -> AsyncStream<WifiNetworkInfo> {
        let source = info.updates()
        let info = self.info
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                var leasePoll: Task<Void, Never>?
                for await update in source {
                    var snapshot = update
                    if snapshot.isSatisfied { snapshot.ssid = await WiFiInfo.fetchSSID() }
                    continuation.yield(Self.map(snapshot))
                    leasePoll?.cancel()
                    leasePoll = nil
                    if snapshot.isSatisfied, snapshot.usablePhoneIPv4 == nil {
                        // Associated but no DHCP lease yet: NWPath may not change when it arrives,
                        // so re-read the address (a change is published on `updates()`).
                        leasePoll = Task {
                            for _ in 0 ..< 20 {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                if Task.isCancelled { return }
                                let s = info.refreshedSnapshot()
                                if !s.isSatisfied || s.usablePhoneIPv4 != nil { return }
                            }
                        }
                    }
                }
                leasePoll?.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func map(_ s: WiFiSnapshot) -> WifiNetworkInfo {
        WifiNetworkInfo(isWifiAvailable: s.isSatisfied,
                        ssid: s.ssid,
                        interfaceName: s.interfaceName,
                        phoneIPv4: s.usablePhoneIPv4,
                        gateway: s.usableGateways.first,
                        dashHostCandidates: s.dashHostCandidates,
                        isLocalNetworkDenied: s.isLocalNetworkDenied)
    }
}
