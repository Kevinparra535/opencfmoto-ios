// SPDX-License-Identifier: AGPL-3.0-or-later
// Navigation state of the root stack (Android: the activities started from MainActivity).
//
// Home pushes typed `MainRoute`s onto the one NavigationStack owned by `RootView`; the QR scanner
// is a sheet (a self-contained task) whose follow-up (Connect / Mirror) runs only once the sheet
// is fully dismissed, so a second presentation (the manual Wi-Fi join prompt) never collides with
// the closing scanner.

import SwiftUI
import Observation

/// Typed destinations of the root navigation stack.
enum MainRoute: Hashable {
    case navigate
    case dashPreview
    case controls
    case settings
    case garage
    case trips
    case logs
    case about
    case mirror
}

/// What to start once a scanner sheet paired a bike (Android: Connect, or the mirror link if the
/// scan was for Mirror — app-features §7.5.5).
enum MainScanFollowUp: Equatable {
    case none
    case connect
    case mirror
}

struct MainScanRequest: Identifiable, Equatable {
    let id = UUID()
    var followUp: MainScanFollowUp
}

@MainActor
@Observable
final class MainRouter {
    /// The root NavigationStack path.
    var path: [MainRoute] = []
    /// Non-nil while the root scanner sheet is shown.
    var scanRequest: MainScanRequest?
    /// Set by the scanner sheet when it paired a bike; performed in the sheet's `onDismiss`.
    @ObservationIgnored var pendingFollowUp: MainScanFollowUp = .none

    func open(_ route: MainRoute) {
        path.append(route)
    }

    func scan(then followUp: MainScanFollowUp) {
        guard scanRequest == nil else { return }
        pendingFollowUp = .none
        scanRequest = MainScanRequest(followUp: followUp)
    }
}

private struct MainRouterKey: EnvironmentKey {
    static let defaultValue: MainRouter? = nil
}

extension EnvironmentValues {
    /// The root router; nil when a screen is shown outside `RootView` (previews, other stacks).
    var mainRouter: MainRouter? {
        get { self[MainRouterKey.self] }
        set { self[MainRouterKey.self] = newValue }
    }
}
