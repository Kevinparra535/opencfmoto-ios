// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Delayed actions of the navigation engine (Android `Handler.postDelayed`): the 2 s / 2.5 s
// auto-finish after "Destination reached" / "Arriving at …". Injected so tests can run them
// deterministically.

import Foundation

/// Runs an action once after a delay.
public protocol NavScheduler: Sendable {
    func schedule(after seconds: TimeInterval, _ action: @escaping @Sendable () -> Void)
}

/// Production scheduler: a detached `Task` that sleeps, then runs the action.
public struct TaskNavScheduler: NavScheduler {
    public init() {}
    public func schedule(after seconds: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        Task.detached {
            await sleepSeconds(seconds)
            action()
        }
    }
}

/// Camera requests that accompany navigation actions (Android moves the osmdroid camera inside the
/// same handlers). The dash UI owns the camera; these are hints it may follow.
public enum NavCameraHint: Sendable, Equatable {
    /// Centre on a point at a zoom (north-up), e.g. a dropped pin (z16) or a place while waiting
    /// for GPS.
    case center(GeoPoint, zoom: Double)
    /// North-up overview fitting these polylines with `paddingPx` (route previews: 160, route
    /// overview: 72).
    case fit([[GeoPoint]], paddingPx: Double)
    /// Resume following the rider (after Go, a reroute or Recenter), heading-up or north-up.
    case follow(headingUp: Bool)
}
