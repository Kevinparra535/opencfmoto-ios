// SPDX-License-Identifier: AGPL-3.0-or-later
// `SystemControlling` on iOS: UIKit idle timer, thermal / Low Power Mode notifications, the app's
// Settings page, a light haptic, the Local Network permission (TN3179 probe from OpenCfMotoApple)
// and the device / build identity used in logs and problem reports.

import Foundation
import UIKit
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

@MainActor
final class IOSSystem: SystemControlling {
    let flavor: BuildFlavor
    let appVersion: String
    let buildNumber: String
    let deviceModel: String
    let systemVersion: String
    var onPowerStateChange: (() -> Void)?

    private let store: KeyValueStore
    private var observers: [NSObjectProtocol] = []
    /// Set once the onboarding asked for Local Network access: probing before that would pop the
    /// system alert out of context (`checkLocalNetworkAccess` must never show it by itself).
    private static let localNetworkRequestedKey = "ios.local_network_requested"

    init(flavor: BuildFlavor, store: KeyValueStore) {
        self.flavor = flavor
        self.store = store
        let info = Bundle.main.infoDictionary ?? [:]
        appVersion = info["CFBundleShortVersionString"] as? String ?? "0.0"
        buildNumber = info["CFBundleVersion"] as? String ?? "0"
        deviceModel = Self.machineIdentifier()
        systemVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onPowerStateChange?() }
            }
            observers.append(token)
        }
    }

    var preferredLanguageCode: String {
        guard let first = Locale.preferredLanguages.first else { return "en" }
        let code = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? first
        return code.lowercased()
    }

    var isIdleTimerDisabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }

    var isLowPowerModeEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    var thermalLevel: ThermalLevel {
        ThermalLevel.fromProcessInfoThermalState(rawValue: ProcessInfo.processInfo.thermalState.rawValue)
    }

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func hapticTap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    func checkLocalNetworkAccess() async -> LocalNetworkAccessState {
        guard store.bool(forKey: Self.localNetworkRequestedKey) == true else { return .undetermined }
        return Self.map(await LocalNetworkPermission.check())
    }

    func requestLocalNetworkAccess() async -> LocalNetworkAccessState {
        store.set(true, forKey: Self.localNetworkRequestedKey)
        return Self.map(await LocalNetworkPermission.request())
    }

    private static func map(_ access: LocalNetworkAccess) -> LocalNetworkAccessState {
        switch access {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        case .unavailable: return .unavailable
        }
    }

    /// "iPhone15,2" (utsname machine); the simulated model in the Simulator.
    private static func machineIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }
}
