// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) res/values/strings.xml + res/values-es/strings.xml (dash_*,
// dashset_*, gpx_*) and the hard-coded English strings of GpxDashUi.kt —
// docs/spec/app-features.md §9.1, §9.9, §9.13; navigation-dash.md §11.8, §11.11.
//
// Spanish fixes recommended by the spec are applied: dash_left "IZQUIERDA" → "RESTANTE",
// dash_arrive "LLEGAR" → "LLEGADA". Strings Android leaves untranslated (Lap/Stop, Follow on…)
// get proposed Spanish here.

import Foundation

/// UI language of the dash (the core has no bundle lookups; small EN/ES tables).
public enum DashLanguage: String, Sendable, Codable, CaseIterable {
    case en, es

    /// First supported language in `preferred` (e.g. `Locale.preferredLanguages`), default English.
    public static func preferred(from preferred: [String]) -> DashLanguage {
        for tag in preferred {
            let lower = tag.lowercased()
            if lower.hasPrefix("es") { return .es }
            if lower.hasPrefix("en") { return .en }
        }
        return .en
    }

    /// From `Locale.preferredLanguages`.
    public static var system: DashLanguage { preferred(from: Locale.preferredLanguages) }
}

/// Every fixed label of the dash UI.
public enum DashText: String, Sendable, CaseIterable {
    // Search pill
    case searchHere, circuit, lap, lapStop
    // Nav card / metrics
    case time, arrive, left, alt, end
    case limit
    // Preview card
    case go, save, home, marker, cancel, done
    // Arrive card
    case youveArrived, parkHere, findParking, doneFreeRide
    // Menu
    case ride, map, settings, endNavigation, goHome, setHomeHere, recenterRecalc, recordRide, stopRecording
    case followOn, freePan, headingUp, northUp, voiceOn, voiceMuted, zoomOutGlyph, zoomInGlyph, close
    case units, metric, imperial, theme, auto, day, night, voice, on, off, nextStop, autoFinish
    case chrome, dark, black, slate, forest, routeMode, fast, fun, avoidTolls, avoidHighways
    // Search sheet
    case typeOnPhoneHint, typeOnPhoneStatus, typeOnPhoneRow, recentAndFavorites, typeOrTapCategory, noResults, delete
    // Toasts produced by the dash itself (camera / UI-only actions)
    case centeredOnGps, noGpsYet, routeOverview, overview
    // Hold screen default
    case holdDefault
    // Apple Music (iOS addition): menu entry, empty title, `.openMusic` with nothing loaded
    case music, unknownSong, nothingPlaying

    public func localized(_ lang: DashLanguage) -> String {
        switch lang {
        case .en: return en
        case .es: return es
        }
    }

    public var en: String {
        switch self {
        case .searchHere: return "Search here"
        case .circuit: return "Circuit"
        case .lap: return "Lap"
        case .lapStop: return "Stop"
        case .time: return "TIME"
        case .arrive: return "ARRIVE"
        case .left: return "LEFT"
        case .alt: return "ALT"
        case .end: return "End"
        case .limit: return "LIMIT"
        case .go: return "Go"
        case .save: return "★ Save"
        case .home: return "Home"
        case .marker: return "＋ Marker"
        case .cancel: return "Cancel"
        case .done: return "Done"
        case .youveArrived: return "You've arrived"
        case .parkHere: return "Park here"
        case .findParking: return "Find parking"
        case .doneFreeRide: return "Done · free ride"
        case .ride: return "Ride"
        case .map: return "Map"
        case .settings: return "Settings"
        case .endNavigation: return "End navigation"
        case .goHome: return "Go Home"
        case .setHomeHere: return "Set Home here"
        case .recenterRecalc: return "Recenter / Recalc"
        case .recordRide: return "Record ride"
        case .stopRecording: return "Stop recording"
        case .followOn: return "Follow on"
        case .freePan: return "Free pan"
        case .headingUp: return "Heading up"
        case .northUp: return "North up"
        case .voiceOn: return "Voice on"
        case .voiceMuted: return "Voice muted"
        case .zoomOutGlyph: return "－"
        case .zoomInGlyph: return "＋"
        case .close: return "Close"
        case .units: return "Units"
        case .metric: return "Metric"
        case .imperial: return "Imperial"
        case .theme: return "Theme"
        case .auto: return "Auto"
        case .day: return "Day"
        case .night: return "Night"
        case .voice: return "Voice"
        case .on: return "On"
        case .off: return "Off"
        case .nextStop: return "Next stop"
        case .autoFinish: return "Auto-finish"
        case .chrome: return "Chrome"
        case .dark: return "Dark"
        case .black: return "Black"
        case .slate: return "Slate"
        case .forest: return "Forest"
        case .routeMode: return "Route mode"
        case .fast: return "Fast"
        case .fun: return "Fun"
        case .avoidTolls: return "Avoid tolls"
        case .avoidHighways: return "Avoid highways"
        case .typeOnPhoneHint: return "Type on your PHONE keyboard…"
        case .typeOnPhoneStatus: return "⌨ Type on PHONE — results show here"
        case .typeOnPhoneRow: return "⌨ Type on your phone"
        case .recentAndFavorites: return "Recent & favorites"
        case .typeOrTapCategory: return "Type on PHONE, or tap a category"
        case .noResults: return "No results"
        case .delete: return "Delete"
        case .centeredOnGps: return "Centered on GPS"
        case .noGpsYet: return "No GPS yet — wait for a fix"
        case .routeOverview: return "Route overview · north up"
        case .overview: return "Overview · north up"
        case .holdDefault: return "Open OpenCfMoto on your phone to resume the map"
        case .music: return "Music"
        case .unknownSong: return "Unknown song"
        case .nothingPlaying: return "Nothing playing in Apple Music"
        }
    }

    public var es: String {
        switch self {
        case .searchHere: return "Busca aquí"
        case .circuit: return "Circuito"
        case .lap: return "Vuelta"
        case .lapStop: return "Parar"
        case .time: return "TIEMPO"
        case .arrive: return "LLEGADA"
        case .left: return "RESTANTE"
        case .alt: return "ALT"
        case .end: return "Fin"
        case .limit: return "LÍMITE"
        case .go: return "Ir"
        case .save: return "★ Guardar"
        case .home: return "Casa"
        case .marker: return "＋ Marcador"
        case .cancel: return "Cancelar"
        case .done: return "Hecho"
        case .youveArrived: return "Has llegado"
        case .parkHere: return "Aparca aquí"
        case .findParking: return "Buscar aparcamiento"
        case .doneFreeRide: return "Listo · ruta libre"
        case .ride: return "Conducir"
        case .map: return "Mapa"
        case .settings: return "Ajustes"
        case .endNavigation: return "Finalizar navegación"
        case .goHome: return "Ir a casa"
        case .setHomeHere: return "Fijar aquí mi casa"
        case .recenterRecalc: return "Recentrar/Recalcular"
        case .recordRide: return "Grabar la ruta"
        case .stopRecording: return "Detener grabación"
        case .followOn: return "Seguimiento activado"
        case .freePan: return "Desplazamiento libre"
        case .headingUp: return "Rumbo arriba"
        case .northUp: return "Norte arriba"
        case .voiceOn: return "Voz activada"
        case .voiceMuted: return "Voz silenciada"
        case .zoomOutGlyph: return "－"
        case .zoomInGlyph: return "＋"
        case .close: return "Cerrar"
        case .units: return "Unidades"
        case .metric: return "Métrico"
        case .imperial: return "Imperial"
        case .theme: return "Tema"
        case .auto: return "Auto"
        case .day: return "Día"
        case .night: return "Noche"
        case .voice: return "Voz"
        case .on: return "Activado"
        case .off: return "Apagado"
        case .nextStop: return "Próxima parada"
        case .autoFinish: return "Finalizar automáticamente"
        case .chrome: return "Interfaz"
        case .dark: return "Oscuro"
        case .black: return "Negro"
        case .slate: return "Pizarra"
        case .forest: return "Bosque"
        case .routeMode: return "Modo de ruta"
        case .fast: return "Rápido"
        case .fun: return "Divertido"
        case .avoidTolls: return "Evitar peajes"
        case .avoidHighways: return "Evitar autovías"
        case .typeOnPhoneHint: return "Escribe en el teclado del TELÉFONO…"
        case .typeOnPhoneStatus: return "⌨ Escribe en el TELÉFONO: los resultados aparecen aquí"
        case .typeOnPhoneRow: return "⌨ Escribe en tu teléfono"
        case .recentAndFavorites: return "Recientes y favoritos"
        case .typeOrTapCategory: return "Escribe en el TELÉFONO o toca una categoría"
        case .noResults: return "Sin resultados"
        case .delete: return "Eliminar"
        case .centeredOnGps: return "Centrado en el GPS"
        case .noGpsYet: return "Aún no hay GPS: espera la señal"
        case .routeOverview: return "Vista de la ruta · norte arriba"
        case .overview: return "Vista general · norte arriba"
        case .holdDefault: return "Abre OpenCfMoto en el teléfono para reanudar el mapa"
        case .music: return "Música"
        case .unknownSong: return "Canción desconocida"
        case .nothingPlaying: return "Apple Music no está reproduciendo nada"
        }
    }
}

/// Formatted / parameterised dash strings.
public enum DashStrings {
    /// "<n> places" (search result count).
    public static func places(_ n: Int, _ lang: DashLanguage) -> String {
        switch lang {
        case .en: return "\(n) places"
        case .es: return "\(n) lugares"
        }
    }

    /// The metrics ALT label: "ALT m" / "ALT ft".
    public static func altLabel(unit: String, _ lang: DashLanguage) -> String {
        let u = unit.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? DashText.alt.localized(lang) : "\(DashText.alt.localized(lang)) \(u)"
    }

    /// Display label for a POI chip id (Android chip labels are the ids: Fuel, Cafe, Food,
    /// Parking, Hotel, ATM, Hospital, Viewpoint). Unknown ids are shown as-is.
    public static func poiChipLabel(_ id: String, _ lang: DashLanguage) -> String {
        guard lang == .es else { return id }
        switch id.lowercased() {
        case "fuel": return "Gasolina"
        case "cafe": return "Cafetería"
        case "food": return "Comida"
        case "parking": return "Aparcamiento"
        case "hotel": return "Hotel"
        case "atm": return "Cajero"
        case "hospital": return "Hospital"
        case "viewpoint": return "Mirador"
        default: return id
        }
    }

    /// `maneuverWord(dir)` (GpxDashUi.kt:2450-2464) — fallback cue text when no road name.
    public static func maneuverWord(_ dir: TurnDir, _ lang: DashLanguage) -> String {
        switch lang {
        case .en:
            switch dir {
            case .left: return "Turn left"
            case .right: return "Turn right"
            case .sharpLeft: return "Sharp left"
            case .sharpRight: return "Sharp right"
            case .slightLeft: return "Slight left"
            case .slightRight: return "Slight right"
            case .uturn: return "U-turn"
            case .roundabout: return "Roundabout"
            case .mergeLeft, .mergeRight: return "Merge"
            case .forkLeft: return "Keep left"
            case .forkRight: return "Keep right"
            case .straight, .continue: return "Continue"
            case .arrive: return "Arrive"
            }
        case .es:
            switch dir {
            case .left: return "Gira a la izquierda"
            case .right: return "Gira a la derecha"
            case .sharpLeft: return "Cerrada a la izquierda"
            case .sharpRight: return "Cerrada a la derecha"
            case .slightLeft: return "Ligeramente a la izquierda"
            case .slightRight: return "Ligeramente a la derecha"
            case .uturn: return "Cambio de sentido"
            case .roundabout: return "Rotonda"
            case .mergeLeft, .mergeRight: return "Incorpórate"
            case .forkLeft: return "Mantente a la izquierda"
            case .forkRight: return "Mantente a la derecha"
            case .straight, .continue: return "Continúa"
            case .arrive: return "Llegada"
            }
        }
    }

    /// Seeded cue text while navigating without a cue: "To <name>".
    public static func toDestination(_ name: String, _ lang: DashLanguage) -> String {
        switch lang {
        case .en: return "To \(name)"
        case .es: return "Hacia \(name)"
        }
    }
}

/// Small formatting helpers for what the dash formats itself (speed gauge, clock, night mode).
public enum DashFormat {
    /// Java `Math.round`-style HALF_UP rounding (`floor(x + 0.5)`), saturating like Java (0 for
    /// NaN / ±∞) — values derived from untrusted routes must never trap.
    public static func roundHalfUp(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        let r = (x + 0.5).rounded(.down)
        if r >= 9.2e18 { return Int.max }
        if r <= -9.2e18 { return Int.min }
        return Int(r)
    }

    /// `formatSpeed` (GpxNav.kt): `"%.0f"` of km/h (metric) or km/h·0.621371 (imperial), computed in
    /// Float like Android (`loc.speed * 3.6f`). nil speed (no fix) → "—"; a fix without speed → "0".
    public static func speed(mps: Double?, units: MapUnits) -> String {
        guard let mps else { return "—" }
        let kmh = Float(max(0, mps)) * Float(3.6)
        let v: Float = units == .imperial ? kmh * Float(0.621371) : kmh
        return String(roundHalfUp(Double(v)))
    }

    /// "km/h" | "mph".
    public static func speedUnit(_ units: MapUnits) -> String { units == .imperial ? "mph" : "km/h" }

    /// 24-hour "HH:mm" in `timeZone` (POSIX digits).
    public static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// `NightPrefs.isNightNow` (navigation-dash.md §10.3): DAY → false, NIGHT → true,
    /// AUTO → phone dark mode or local hour < 7 or ≥ 19. No sunrise/sunset algorithm (parity).
    public static func isNight(theme: MapTheme, phoneDarkMode: Bool, date: Date, timeZone: TimeZone) -> Bool {
        switch theme {
        case .day: return false
        case .night: return true
        case .auto:
            if phoneDarkMode { return true }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let h = cal.component(.hour, from: date)
            return h < 7 || h >= 19
        }
    }
}
