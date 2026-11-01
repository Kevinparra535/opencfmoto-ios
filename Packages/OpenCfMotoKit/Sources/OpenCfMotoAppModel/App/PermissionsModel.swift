// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-session. The PUBLIC SURFACE below is the contract the SwiftUI
// layer codes against: implement the bodies, add private helpers / new files freely, add new
// public members only if needed (report them), never rename or remove existing public members.
//
// Onboarding + permissions (docs/spec/ios-platform-facts.md: When-In-Use location only; the Local
// Network prompt is triggered by the first outbound probe, so `requestLocalNetwork()` must be
// called in the foreground right after pairing; camera permission is asked by the scanner UI).
//
// Ported from OpenCfMoto (Android) SetupActivity.kt (`setup_seen` → iOS `onboarding_done`).

import Foundation
import Observation
import OpenCfMotoCore

@MainActor
@Observable
public final class PermissionsModel {
    @ObservationIgnored let core: AppCore

    public private(set) var location: LocationPermission = .notDetermined
    public private(set) var isPreciseLocation = true
    public private(set) var localNetwork: LocalNetworkAccessState = .undetermined
    /// Persisted ("onboarding_done"); false on first launch.
    public private(set) var hasCompletedOnboarding = false
    public private(set) var step: OnboardingStep = .welcome

    /// KeyValueStore key of the onboarding flag (Android `setup_seen`).
    static let onboardingDoneKey = "onboarding_done"

    /// Location permission changed (RideModel starts / stops GPS). Wired by AppModel.
    @ObservationIgnored var onLocationPermissionChange: (@MainActor (LocationPermission) -> Void)?
    /// Onboarding finished (AppModel retries auto-connect, like Android's return from Setup).
    @ObservationIgnored var onOnboardingCompleted: (@MainActor () -> Void)?

    public init(core: AppCore) {
        self.core = core
        let done = core.services.keyValueStore.bool(forKey: Self.onboardingDoneKey) ?? false
        hasCompletedOnboarding = done
        step = done ? .done : .welcome
        let loc = core.services.location
        location = loc.permission
        isPreciseLocation = loc.isPrecise
        loc.onPermissionChange = { [weak self] p in self?.locationPermissionChanged(p) }
    }

    public func requestLocation() {
        let loc = core.services.location
        Log.i("PERM", "requesting When-In-Use location (current: \(loc.permission.rawValue))")
        loc.requestPermission()
        // Some providers answer synchronously without a callback when nothing changes.
        if loc.permission != location { locationPermissionChanged(loc.permission) }
    }

    public func requestLocalNetwork() async {
        let result = await core.services.system.requestLocalNetworkAccess()
        localNetwork = result
        Log.i("PERM", "[LAN] local network access: \(result.rawValue)")
    }

    /// Re-checks both permissions (on app foreground).
    public func refresh() async {
        let loc = core.services.location
        if loc.permission != location || loc.isPrecise != isPreciseLocation {
            locationPermissionChanged(loc.permission)
        }
        let result = await core.services.system.checkLocalNetworkAccess()
        // Keep a decisive earlier answer when the probe has nothing to test against.
        if result == .granted || result == .denied || localNetwork == .undetermined || localNetwork == .unavailable {
            localNetwork = result
        }
    }

    /// Next onboarding step (welcome → location → local network → pair bike → done). Reaching `.done`
    /// only shows the last page (ride-safety note, Ride Mode advice): its "Start riding" button calls
    /// `completeOnboarding()`, which swaps onboarding for Home and starts auto-connect (review UI-3:
    /// completing here hid that page in the same update). `advance()` at `.done` completes too.
    public func advance() {
        let all = OnboardingStep.allCases
        guard let i = all.firstIndex(of: step), i + 1 < all.count else {
            completeOnboarding()
            return
        }
        step = all[i + 1]
    }

    public func completeOnboarding() {
        step = .done
        guard !hasCompletedOnboarding else { return }
        hasCompletedOnboarding = true
        core.services.keyValueStore.set(true, forKey: Self.onboardingDoneKey)
        Log.i("APP", "onboarding done")
        onOnboardingCompleted?()
    }

    /// Settings ▸ "Show onboarding again".
    public func resetOnboarding() {
        hasCompletedOnboarding = false
        core.services.keyValueStore.set(false, forKey: Self.onboardingDoneKey)
        step = .welcome
    }

    public func openAppSettings() { core.services.system.openAppSettings() }

    // MARK: - Private

    private func locationPermissionChanged(_ p: LocationPermission) {
        location = p
        isPreciseLocation = core.services.location.isPrecise
        Log.i("PERM", "location permission: \(p.rawValue)\(isPreciseLocation ? "" : " (approximate)")")
        onLocationPermissionChange?(p)
    }
}
