// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) MainActivity.kt:580-631 (the dash's "type on phone" hand-off;
// input-controls §6.7, app-features §7.5.7).
//
// The dash's request to type the search on the phone (`NavigationModel.typeOnPhoneRequested`: the
// dash search pill, the ASSISTANT key or the search sheet's "Type on phone") is taken by the screen
// the rider can SEE — Home's search field, the Map hub or the Dash view — and only while the scene
// is active and nothing covers that screen (Ride Mode, the scanner or manual-join sheet). Otherwise
// it stays pending and is picked up as soon as that holds: the rider unlocks the phone or comes
// back to the app (iOS cannot bring an app to the front; "when the rider opens the app, focus the
// search field"), leaves Ride Mode (its overlay shows a hint meanwhile), closes the sheet, or the
// screen appears. RootView sends other screens (Settings, Trips, Controls…) back to Home, whose
// field then takes it. Review findings UI-1, UI-2, UI-4, CL-3.

import SwiftUI
import OpenCfMotoAppModel

/// Shared rule for the screens that can show the dash's "type on phone" request.
@MainActor
enum MainTypeOnPhone {
    /// Seconds a request may wait under Ride Mode (the overlay shows a hint meanwhile) before it is
    /// dropped as stale — the rider answers a dash prompt at a stop, not at the end of the ride.
    static let rideModeLifetime: TimeInterval = 120

    /// The request is waiting and a visible screen may act on it now.
    static func isActionable(model: AppModel, router: MainRouter?, scenePhase: ScenePhase) -> Bool {
        model.navigation.typeOnPhoneRequested
            && scenePhase == .active
            && !model.ride.isRideModeActive
            && model.connection.manualJoin == nil
            && router?.scanRequest == nil
    }
}

extension View {
    /// Calls `perform` whenever the dash's "type on phone" request is pending and this screen can show
    /// it (`isVisible`, the scene active, no Ride Mode cover or root sheet) — on arrival, and again
    /// when any of those becomes true later. `perform` must acknowledge the request.
    func mainTypeOnPhone(isVisible: Bool, perform: @escaping () -> Void) -> some View {
        modifier(MainTypeOnPhoneTrigger(isVisible: isVisible, perform: perform))
    }
}

private struct MainTypeOnPhoneTrigger: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.mainRouter) private var router
    @Environment(\.scenePhase) private var scenePhase
    let isVisible: Bool
    let perform: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: isReady, initial: true) { _, ready in
            if ready { perform() }
        }
    }

    private var isReady: Bool {
        isVisible && MainTypeOnPhone.isActionable(model: model, router: router, scenePhase: scenePhase)
    }
}
