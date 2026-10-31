// SPDX-License-Identifier: AGPL-3.0-or-later
// `LocationProviding` on iOS: OpenCfMotoApple.LocationService (CLLocationManager, When-In-Use,
// best-for-navigation fixes, background updates only while a ride is active, RAW compass samples
// for NavigationSession.updateHeading — the session filters them itself).

import Foundation
import OpenCfMotoCore
import OpenCfMotoApple
import OpenCfMotoAppModel

@MainActor
final class LocationAdapter: LocationProviding {
    private let service: LocationService

    var onFix: ((LocationFix) -> Void)? {
        didSet { service.onFix = onFix }
    }

    var onRawHeading: ((Double) -> Void)? {
        didSet { service.onRawHeading = onRawHeading }
    }

    var onPermissionChange: ((LocationPermission) -> Void)?

    init(clock: MonotonicClock) {
        service = LocationService(clock: clock)
        service.onAuthorizationChange = { [weak self] authorization in
            self?.onPermissionChange?(LocationAdapter.map(authorization))
        }
        service.onError = { error in
            Log.w("LOC", "location error: \(error.localizedDescription)")
        }
    }

    var permission: LocationPermission { Self.map(service.authorization) }
    var isPrecise: Bool { service.isPreciseLocation }
    var isUpdating: Bool { service.isUpdating }
    var lastFix: LocationFix? { service.lastFix }

    func requestPermission() { service.requestWhenInUseAuthorization() }
    func start(rideActive: Bool) { service.start(rideActive: rideActive) }
    func setRideActive(_ active: Bool) { service.setRideActive(active) }
    func stop() { service.stop() }

    private static func map(_ a: LocationAuthorization) -> LocationPermission {
        switch a {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .whenInUse: return .whenInUse
        case .always: return .always
        }
    }
}
