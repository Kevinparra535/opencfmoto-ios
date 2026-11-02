// SPDX-License-Identifier: AGPL-3.0-or-later
// `HandlebarRemoteProviding` on iOS: OpenCfMotoApple.HandlebarRemote (MPRemoteCommandCenter + Now
// Playing claim, optional outputVolume observation). Opt-in only (ControlsModel decides when to
// claim); the claim is refreshed when the app becomes active again (never while other audio plays).
// Apple Music (contract R4): `reclaimIfPossible()` takes the buttons back right after the rider
// paused the Music app — foreground only (a non-mixable activation from the background fails with
// cannotInterruptOthers), never while other audio plays (HandlebarRemote.reclaim refuses then).

import Foundation
import UIKit
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

@MainActor
final class HandlebarAdapter: HandlebarRemoteProviding {
    private let remote: HandlebarRemote
    private var activeObserver: NSObjectProtocol?

    var onSignal: ((HandlebarSignal) -> Void)?

    init(clock: MonotonicClock) {
        remote = HandlebarRemote(clock: clock)
        remote.onEvent = { [weak self] event in
            let signal = HandlebarSignal(event: event.raw, time: event.time, steps: event.steps)
            Task { @MainActor [weak self] in self?.onSignal?(signal) }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reclaimIfNeeded() }
        }
    }

    var isAvailable: Bool { true }
    var isEnabled: Bool { remote.isEnabled }

    var volumeButtonsEnabled: Bool {
        get { remote.volumeButtonsEnabled }
        set { remote.volumeButtonsEnabled = newValue }
    }

    func enable() {
        do {
            try remote.enable()
        } catch {
            // Capture stays enabled; the claim is retried when the app becomes active.
            Log.w("BTN", "[BTN] handlebar capture could not claim Now Playing: \(error.localizedDescription)")
        }
    }

    func disable() { remote.disable() }

    func reclaimIfPossible() -> HandlebarReclaimResult {
        guard remote.isEnabled else { return .refused }
        if remote.isClaimed { return .alreadyClaimed }
        guard UIApplication.shared.applicationState == .active else { return .refused }
        return remote.reclaim() ? .reclaimed : .refused
    }

    private func reclaimIfNeeded() {
        guard remote.isEnabled, !remote.isClaimed else { return }
        _ = remote.reclaim()
    }
}
