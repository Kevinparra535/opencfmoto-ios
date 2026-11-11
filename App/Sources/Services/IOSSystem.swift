// SPDX-License-Identifier: AGPL-3.0-or-later
// `SystemControlling` on iOS: UIKit idle timer, thermal / Low Power Mode notifications, the app's
// Settings page, a light haptic, the Local Network permission (TN3179 probe from OpenCfMotoApple),
// the phone's own light / dark appearance (dash map AUTO theme), the battery (BatteryMonitor; the
// locked-phone diagnostics) and the device / build identity used in logs and problem reports.

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
    /// Set once an explicit request got a decisive answer from Local Network privacy (the alert was
    /// shown and answered, or answered earlier): probing before that would pop the system alert out
    /// of context (`checkLocalNetworkAccess` must never show it by itself).
    private static let localNetworkRequestedKey = "ios.local_network_requested"

    init(flavor: BuildFlavor, store: KeyValueStore) {
        self.flavor = flavor
        self.store = store
        let info = Bundle.main.infoDictionary ?? [:]
        appVersion = info["CFBundleShortVersionString"] as? String ?? "0.0"
        buildNumber = info["CFBundleVersion"] as? String ?? "0"
        deviceModel = Self.machineIdentifier()
        systemVersion = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        BatteryMonitor.shared.start()
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

    /// Locked iPhone (Phase 0, P0-12): the cached UIDevice battery reading (`[lock] … batt=63% charging`).
    var batteryStatus: BatteryStatus? { BatteryMonitor.shared.status }

    var thermalLevel: ThermalLevel {
        ThermalLevel.fromProcessInfoThermalState(rawValue: ProcessInfo.processInfo.thermalState.rawValue)
    }

    /// The PHONE's appearance (Settings ▸ Display & Brightness: Dark, or Automatic after sunset). The dash
    /// map's AUTO theme used it on Android and before P0 (night = phone dark mode OR 19:00–06:59,
    /// navigation-dash §10.3, review finding CL-10); since P0 (D06) AUTO follows the sun at the rider's fix and
    /// ignores it. Read from the screen's traits: the app forces its own
    /// UI dark (`preferredColorScheme(.dark)` overrides the window, not the screen), so window or view
    /// traits would always say dark. In the background UIKit renders light AND dark app snapshots,
    /// briefly flipping traits, so the last foreground answer is kept until the scene is back.
    /// Cheap enough for RideModel to poll on its UI tick.
    var isSystemDarkMode: Bool {
        guard let scene = Self.foregroundWindowScene() else { return lastSystemDarkMode }
        let dark = scene.screen.traitCollection.userInterfaceStyle == .dark
        lastSystemDarkMode = dark
        return dark
    }

    private var lastSystemDarkMode = false

    private static func foregroundWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
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
        let access = await LocalNetworkPermission.request()
        // Off Wi-Fi the probe never reaches the local network (`.unavailable`, no alert shown):
        // remembering the request then would let every later quiet check send the probe datagram
        // and pop the alert at a random moment (review finding IOS-5). Leave the flag unset until an
        // explicit request (onboarding, on Wi-Fi) or the first Connect probe triggers the alert.
        if access.isDecisive {
            store.set(true, forKey: Self.localNetworkRequestedKey)
        }
        return Self.map(access)
    }

    /// After the bike link's connect() was dropped by the system (review POSIX-2): that connect already
    /// brought up the alert if it was due, so the check may probe now. A decisive answer is remembered
    /// like an explicit request's (the alert has been answered: later quiet checks may probe too).
    func checkLocalNetworkAccessAfterBlockedConnect() async -> LocalNetworkAccessState {
        let access = await LocalNetworkPermission.check()
        if access.isDecisive {
            store.set(true, forKey: Self.localNetworkRequestedKey)
        }
        return Self.map(access)
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
