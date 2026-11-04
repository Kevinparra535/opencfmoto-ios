// SPDX-License-Identifier: AGPL-3.0-or-later
// Places of the demo content (`-demoSeed`, screenshots, manual testing): public spots of the area the
// demo GPS loop (`DemoRoutePlayer.defaultRoute`, around Parque Simón Bolívar, Bogotá) runs through —
// never anyone's real address.

import Foundation
import OpenCfMotoCore

public enum DemoPlaces {
    /// The demo "home": a public spot well inside Parque Simón Bolívar (its northern lawns, more than
    /// 200 m from the roads of the demo loop), the park the loop circles. Named "Demo home" / "Casa (demo)"
    /// so no screenshot reads as somebody's home.
    public static func home(language: NavLanguage = .preferred) -> Place {
        Place(name: language == .es ? "Casa (demo)" : "Demo home", lat: 4.66350, lon: -74.09250)
    }

    /// The home's subtitle in the place lists.
    public static let homeSubtitle = "Parque Simón Bolívar (demo)"
}
