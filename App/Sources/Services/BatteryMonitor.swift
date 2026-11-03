// SPDX-License-Identifier: AGPL-3.0-or-later
// Locked iPhone, Phase 0 (P0-12): the battery level and state for the diagnostics — the `[lock]` line
// (`SystemControlling.batteryStatus`, IOSSystem) and the projection engine's background lines
// (`DashProjectionEngine.batteryProvider`, read on its render queue). UIDevice battery monitoring is
// switched on once; the two battery notifications are observed on the main queue and the latest
// reading is cached under a lock, so any thread can read it without UIKit or the main actor.
// The Simulator reports no battery (`?% unknown`).

import Foundation
import UIKit
import OpenCfMotoCore

final class BatteryMonitor: @unchecked Sendable {
    static let shared = BatteryMonitor()

    private let lock = NSLock()
    private var cached: BatteryStatus?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    /// Enables battery monitoring and starts following the level / state notifications. Main thread;
    /// idempotent.
    @MainActor
    func start() {
        guard !started else { return }
        started = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(token)
        }
    }

    /// The latest reading; nil before `start()`. Any thread.
    var status: BatteryStatus? { lock.withLock { cached } }

    @MainActor
    private func refresh() {
        let device = UIDevice.current
        let state: BatteryStatus.State
        switch device.batteryState {
        case .unplugged: state = .unplugged
        case .charging: state = .charging
        case .full: state = .full
        case .unknown: state = .unknown
        @unknown default: state = .unknown
        }
        // UIKit reports −1 for an unknown level; BatteryStatus keeps nil for it.
        let reading = BatteryStatus(level: Double(device.batteryLevel), state: state)
        lock.withLock { cached = reading }
    }
}
