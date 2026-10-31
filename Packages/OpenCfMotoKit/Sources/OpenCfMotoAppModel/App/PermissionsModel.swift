// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 SKELETON — owner: logic-session. The PUBLIC SURFACE below is the contract the SwiftUI
// layer codes against: implement the bodies, add private helpers / new files freely, add new
// public members only if needed (report them), never rename or remove existing public members.
//
// Onboarding + permissions (docs/spec/ios-platform-facts.md: When-In-Use location only; the Local
// Network prompt is triggered by the first outbound probe, so `requestLocalNetwork()` must be
// called in the foreground right after pairing; camera permission is asked by the scanner UI).

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

    public init(core: AppCore) {
        self.core = core
        // TODO(logic-session): read persisted flag, current location permission, observe changes.
    }

    public func requestLocation() { /* TODO(logic-session) */ }
    public func requestLocalNetwork() async { /* TODO(logic-session) */ }
    public func refresh() async { /* TODO(logic-session): re-check both (on app foreground) */ }
    public func advance() { /* TODO(logic-session): next OnboardingStep */ }
    public func completeOnboarding() { /* TODO(logic-session) */ }
    /// Settings ▸ "Show onboarding again".
    public func resetOnboarding() { /* TODO(logic-session) */ }
    public func openAppSettings() { core.services.system.openAppSettings() }
}
