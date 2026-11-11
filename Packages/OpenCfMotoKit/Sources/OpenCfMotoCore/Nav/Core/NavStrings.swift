// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxNav.kt (instruction/dirFor/arrowFor/joinRoute*),
// GpxVoice.kt (dirPhrase), GpxDashUi.kt (maneuverWord, status / toast / voice phrases).
//
// All user-facing text produced by the navigation core, in English (verbatim Android strings) and
// Spanish (natural phrasing, e.g. "En 300 metros, gira a la izquierda"). The English table is the
// reference: tests pin it byte-for-byte against the Kotlin implementation.

import Foundation

/// Every fixed message the navigation engine speaks or shows (status line / toast / cards).
public enum NavPhrase: Sendable, Equatable {
    // Voice (docs/spec/navigation-dash.md §5.3)
    case routeUpdated, routeReady, arrived, navigationFinished, typeSearchOnPhone
    case navigatingTo(String)
    case saved, homeSet, markerAdded, parkingMarked, parkingUpdated, parkingCleared
    case backOnTrack, centered, buildingCircuit, lapTimerArmed, pinDropped, destinationReached
    case arrivingAt(String)
    case lap(Int)
    case followingTrackReversed, rerouting
    /// Waypoint cue; nil name → "waypoint".
    case approaching(String?)
    // Status / toast
    case routing, noRoadRoute
    case routeSummary(String)
    case gpsFreeRide
    case gpsNavigateTo(String)
    case gpsTrack(String)
    case gpsOnly
    case savedToFavorites(String)
    case savePinHint, alreadyFreeRide, alreadyNearby, noGpsForParking, parkedSpotCleared
    case noHomeSet, noGpsToSetHome, homeSetHere, snapBackOnTrack, recentered, noGps
    case needGpsForCircuit, pickDestinationForCircuit, pickPlaceAwayForCircuit
    case buildingCircuitTo(String)
    case thereAndBackReturning, thereAndBackReturns, noCircuitFound
    case lapTimerOff, needGpsForLap, lapArmedHint
    case lapFinished(Int, String)
    case freeRide, gettingRoute, waitingForGps, straightLine, avoidNotApplied
    case centeredOnGps, noGpsYet, headingUp, northUp
    case savedPlaceNotSet(Int)
    case searching, noResults
    case placesFound(Int)
    case recentAndFavorites, searchIdleHintPhone, searchIdleHintBike, suggestions
    case needGpsForPoi
    case findingNearby(String)
    case noneFoundNearby(String)
    case foundNearby(Int, String)
}

/// Localised text tables + display number formatting for one language.
public struct NavStrings: Sendable, Equatable {
    public var language: NavLanguage
    /// Decimal separator for *displayed* distances ("." = Android parity).
    public var decimalSeparator: Character

    public init(language: NavLanguage = .en, decimalSeparator: Character = ".") {
        self.language = language
        self.decimalSeparator = decimalSeparator
    }

    public static let english = NavStrings(language: .en)

    private var es: Bool { language == .es }

    // MARK: Numbers

    /// `formatDistance` with this table's decimal separator.
    public func distance(_ metres: Double, _ units: MapUnits) -> String {
        NavFormat.formatDistance(metres, units: units, decimalSeparator: decimalSeparator)
    }

    /// Voice distance ("300 meters" / "300 metros").
    public func spokenDistance(_ metres: Double, _ units: MapUnits) -> String {
        NavFormat.roundedSpokenDistance(metres, units: units, language: language)
    }

    /// "In <distance>, <phrase>" / "En <distance>, <phrase>".
    public func inDistance(_ distanceText: String, _ phrase: String) -> String {
        es ? "En \(distanceText), \(phrase)" : "In \(distanceText), \(phrase)"
    }

    // MARK: Maneuver vocabulary

    /// HUD fallback word when a cue has no road name (`GpxDashUi.maneuverWord`).
    public func maneuverWord(_ dir: TurnDir) -> String {
        switch dir {
        case .left: return es ? "Gira a la izquierda" : "Turn left"
        case .right: return es ? "Gira a la derecha" : "Turn right"
        case .sharpLeft: return es ? "Izquierda cerrada" : "Sharp left"
        case .sharpRight: return es ? "Derecha cerrada" : "Sharp right"
        case .slightLeft: return es ? "Ligeramente a la izquierda" : "Slight left"
        case .slightRight: return es ? "Ligeramente a la derecha" : "Slight right"
        case .uturn: return es ? "Cambio de sentido" : "U-turn"
        case .roundabout: return es ? "Rotonda" : "Roundabout"
        case .mergeLeft, .mergeRight: return es ? "Incorpórate" : "Merge"
        case .forkLeft: return es ? "Mantente a la izquierda" : "Keep left"
        case .forkRight: return es ? "Mantente a la derecha" : "Keep right"
        case .straight, .continue: return es ? "Continúa" : "Continue"
        case .arrive: return es ? "Llegada" : "Arrive"
        }
    }

    /// Short HUD label while riding back onto the route (`GpxNav.joinRouteWord`).
    public func joinRouteWord(_ dir: TurnDir) -> String {
        switch dir {
        case .left: return es ? "Gira a la izquierda" : "Turn left"
        case .right: return es ? "Gira a la derecha" : "Turn right"
        case .sharpLeft: return es ? "Izquierda cerrada" : "Sharp left"
        case .sharpRight: return es ? "Derecha cerrada" : "Sharp right"
        case .slightLeft: return es ? "Ligeramente a la izquierda" : "Bear left"
        case .slightRight: return es ? "Ligeramente a la derecha" : "Bear right"
        case .uturn: return es ? "Da la vuelta" : "Turn around"
        case .straight, .continue: return es ? "Sigue recto" : "Go ahead"
        default: return es ? "Hacia la ruta" : "To route"
        }
    }

    /// Spoken cue while off the road (`GpxNav.joinRouteSpeak`, lower-case first letter).
    public func joinRouteSpeak(_ dir: TurnDir) -> String {
        switch dir {
        case .left: return es ? "gira a la izquierda hacia la ruta" : "turn left toward the route"
        case .right: return es ? "gira a la derecha hacia la ruta" : "turn right toward the route"
        case .sharpLeft: return es ? "gira bruscamente a la izquierda hacia la ruta" : "sharp left toward the route"
        case .sharpRight: return es ? "gira bruscamente a la derecha hacia la ruta" : "sharp right toward the route"
        case .slightLeft: return es ? "ve ligeramente a la izquierda hacia la ruta" : "bear left toward the route"
        case .slightRight: return es ? "ve ligeramente a la derecha hacia la ruta" : "bear right toward the route"
        case .uturn: return es ? "da la vuelta hacia la ruta" : "turn around toward the route"
        case .straight, .continue: return es ? "sigue recto hacia la ruta" : "go ahead to the route"
        default: return es ? "dirígete a la ruta" : "head to the route"
        }
    }

    /// Voice fallback when a cue has no instruction (`GpxVoice.dirPhrase`).
    public func dirPhrase(_ dir: TurnDir) -> String {
        switch dir {
        case .left: return es ? "gira a la izquierda" : "turn left"
        case .right: return es ? "gira a la derecha" : "turn right"
        case .sharpLeft: return es ? "gira bruscamente a la izquierda" : "make a sharp left"
        case .sharpRight: return es ? "gira bruscamente a la derecha" : "make a sharp right"
        case .slightLeft: return es ? "mantente a la izquierda" : "keep left"
        case .slightRight: return es ? "mantente a la derecha" : "keep right"
        case .uturn: return es ? "da la vuelta" : "make a U-turn"
        case .roundabout: return es ? "entra en la rotonda" : "enter the roundabout"
        case .mergeLeft: return es ? "incorpórate por la izquierda" : "merge left"
        case .mergeRight: return es ? "incorpórate por la derecha" : "merge right"
        case .forkLeft: return es ? "mantente a la izquierda en la bifurcación" : "keep left at the fork"
        case .forkRight: return es ? "mantente a la derecha en la bifurcación" : "keep right at the fork"
        case .arrive: return es ? "has llegado" : "you have arrived"
        case .straight, .continue: return es ? "sigue recto" : "continue straight"
        }
    }

    /// Word of a geometric (GPX) turn cue: turn left / turn right / sharp left / sharp right.
    public func geometricTurnWord(_ dir: TurnDir) -> String {
        switch dir {
        case .left: return es ? "gira a la izquierda" : "turn left"
        case .right: return es ? "gira a la derecha" : "turn right"
        case .sharpLeft: return es ? "izquierda cerrada" : "sharp left"
        case .sharpRight: return es ? "derecha cerrada" : "sharp right"
        default: return es ? "continúa" : "continue"
        }
    }

    /// Short label of a geometric turn cue ("← Left", "Right →", "←← Sharp", "Sharp →→").
    public func geometricShortLabel(_ dir: TurnDir) -> String {
        switch dir {
        case .left: return es ? "← Izq." : "← Left"
        case .right: return es ? "Der. →" : "Right →"
        case .sharpLeft: return es ? "←← Cerrada" : "←← Sharp"
        case .sharpRight: return es ? "Cerrada →→" : "Sharp →→"
        default: return "↑"
        }
    }

    /// Spoken/HUD instruction for a router step (`GpxNav.instruction`). English is verbatim
    /// Android; Spanish follows the same structure.
    public func instruction(type: String, modifier: String?, road: String?, exit: Int?) -> String {
        let m = modifier?.lowercased()
        let t = type.lowercased()
        if !es {
            let onto = road.map { " onto \($0)" } ?? ""
            switch t {
            case "roundabout", "rotary", "roundabout turn":
                if let exit { return "at the roundabout take exit \(exit)\(onto)" }
                return "at the roundabout\(Self.modWordEN(m).map { ", \($0)" } ?? "")\(onto)"
            case "merge": return "merge\(Self.modWordEN(m).map { " \($0)" } ?? "")\(onto)"
            case "fork": return "keep \(Self.sideWordEN(m) ?? "ahead")\(onto)"
            case "on ramp": return "take the ramp\(Self.modWordEN(m).map { " \($0)" } ?? "")\(onto)"
            case "off ramp": return "take the exit\(Self.modWordEN(m).map { " \($0)" } ?? "")\(onto)"
            case "end of road": return "turn \(Self.sideWordEN(m) ?? "ahead")\(onto)"
            case "new name", "continue": return road.map { "continue onto \($0)" } ?? "continue straight"
            case "arrive": return "you have arrived"
            default:
                switch m {
                case "uturn": return "make a U-turn\(onto)"
                case nil, "straight": return "continue straight\(onto)"
                // Kotlin interpolates a null modWord as "null" (unreachable with OSRM/Valhalla/ORS
                // modifiers; kept for byte parity).
                default: return "turn \(Self.modWordEN(m) ?? "null")\(onto)"
                }
            }
        }
        // Spanish
        let hacia = road.map { " hacia \($0)" } ?? ""
        switch t {
        case "roundabout", "rotary", "roundabout turn":
            if let exit { return "en la rotonda, toma la salida \(exit)\(hacia)" }
            return "en la rotonda\(Self.modWordES(m).map { ", \($0)" } ?? "")\(hacia)"
        case "merge": return "incorpórate\(Self.sideWordES(m).map { " por la \($0)" } ?? "")\(hacia)"
        case "fork":
            if let side = Self.sideWordES(m) { return "mantente a la \(side)\(hacia)" }
            return "sigue recto\(hacia)"
        case "on ramp": return "toma la rampa\(Self.modWordES(m).map { " \($0)" } ?? "")\(hacia)"
        case "off ramp": return "toma la salida\(Self.modWordES(m).map { " \($0)" } ?? "")\(hacia)"
        case "end of road":
            if let side = Self.sideWordES(m) { return "gira a la \(side)\(hacia)" }
            return "sigue recto\(hacia)"
        case "new name", "continue": return road.map { "continúa por \($0)" } ?? "sigue recto"
        case "arrive": return "has llegado"
        default:
            switch m {
            case "uturn": return "da la vuelta\(hacia)"
            case nil, "straight": return "sigue recto\(hacia)"
            default:
                if let w = Self.turnWordES(m) { return "\(w)\(hacia)" }
                return "gira\(hacia)"
            }
        }
    }

    private static func modWordEN(_ m: String?) -> String? {
        switch m {
        case "sharp left": return "sharp left"
        case "sharp right": return "sharp right"
        case "slight left": return "slight left"
        case "slight right": return "slight right"
        case "left": return "left"
        case "right": return "right"
        case "straight": return "straight"
        case "uturn": return "around"
        default: return nil
        }
    }

    private static func sideWordEN(_ m: String?) -> String? {
        guard let m else { return nil }
        if m.contains("left") { return "left" }
        if m.contains("right") { return "right" }
        return nil
    }

    private static func modWordES(_ m: String?) -> String? {
        switch m {
        case "sharp left": return "cerrado a la izquierda"
        case "sharp right": return "cerrado a la derecha"
        case "slight left": return "ligeramente a la izquierda"
        case "slight right": return "ligeramente a la derecha"
        case "left": return "a la izquierda"
        case "right": return "a la derecha"
        case "straight": return "recto"
        case "uturn": return "de vuelta"
        default: return nil
        }
    }

    private static func sideWordES(_ m: String?) -> String? {
        guard let m else { return nil }
        if m.contains("left") { return "izquierda" }
        if m.contains("right") { return "derecha" }
        return nil
    }

    private static func turnWordES(_ m: String?) -> String? {
        switch m {
        case "sharp left": return "gira bruscamente a la izquierda"
        case "sharp right": return "gira bruscamente a la derecha"
        case "slight left": return "gira ligeramente a la izquierda"
        case "slight right": return "gira ligeramente a la derecha"
        case "left": return "gira a la izquierda"
        case "right": return "gira a la derecha"
        default: return nil
        }
    }

    // MARK: HUD

    /// Cue text when no turn is ahead / seeded card: "To <name>".
    public func toDestination(_ name: String) -> String { es ? "Hacia \(name)" : "To \(name)" }

    /// Straight-line cue word for STRAIGHT / CONTINUE ("Go ahead").
    public var goAhead: String { es ? "Sigue recto" : "Go ahead" }

    /// Seed distance text before the first fix.
    public var gpsPlaceholder: String { "GPS" }

    /// Status line `formatHud` (§4.6): " · "-joined "Route · <total>", "OFF <dist>", grade
    /// "%+d%%", "avg <speed>", "→ <name|wpt> <dist>".
    public func hudStatus(avgKmh: Double, progress p: RouteProgress?, totalM: Double, units: MapUnits,
                          showNextStop: Bool) -> String {
        guard let p else { return "" }
        var parts: [String] = []
        if totalM > 0 { parts.append((es ? "Ruta · " : "Route · ") + distance(totalM, units)) }
        if p.offTrackM > 40 { parts.append((es ? "FUERA " : "OFF ") + distance(p.offTrackM, units)) }
        if let g = p.gradePct, abs(g) >= 2 {
            let r = NavNumberFormat.roundHalfUp(g)
            parts.append((r >= 0 ? "+" : "") + String(r) + "%")
        }
        if Float(avgKmh) >= 1 {
            parts.append((es ? "media " : "avg ") + NavFormat.formatSpeed(kmh: avgKmh, units: units))
        }
        if showNextStop, let w = p.nextWaypoint {
            let n = w.name.flatMap { $0.isNavBlank ? nil : $0 } ?? (es ? "pto" : "wpt")
            let d = p.nextWaypointM.map { distance($0, units) } ?? ""
            parts.append("→ \(n) \(d)")
        }
        return parts.joined(separator: " · ")
    }

    /// Status line while navigating to a place without a road route yet.
    public func toDestinationStatus(speedKmh: Double, distanceM: Double, name: String, avgKmh: Double, units: MapUnits) -> String {
        let speed = NavFormat.formatSpeed(kmh: speedKmh, units: units) + " " + NavFormat.speedUnitLabel(units)
        let avg = NavFormat.formatSpeed(kmh: avgKmh, units: units)
        if es { return "\(speed) · \(distance(distanceM, units)) hasta \(name) · media \(avg)" }
        return "\(speed) · \(distance(distanceM, units)) to \(name) · avg \(avg)"
    }

    /// Status line in free ride.
    public func freeRideStatus(speedKmh: Double, avgKmh: Double, units: MapUnits) -> String {
        let speed = NavFormat.formatSpeed(kmh: speedKmh, units: units) + " " + NavFormat.speedUnitLabel(units)
        let avg = NavFormat.formatSpeed(kmh: avgKmh, units: units)
        return es ? "\(speed) · ruta libre · media \(avg)" : "\(speed) · free ride · avg \(avg)"
    }

    // MARK: Cards, chips, places

    public func arrivalTitle(_ name: String?) -> String {
        guard let name, !name.isNavBlank else { return es ? "Llegaste" : "You've arrived" }
        return es ? "Llegaste · \(name)" : "Arrived · \(name)"
    }

    public var arrivalMeta: String {
        es ? "Marca dónde estacionaste, busca estacionamiento o sigue en ruta libre" : "Mark parking, find a spot, or continue free ride"
    }

    /// Display text of a route label (data labels stay English in `Route.label`).
    public func routeLabel(_ label: String) -> String {
        guard es else { return label }
        switch label {
        case "Fast": return "Rápida"
        case "Fun": return "Divertida"
        case "Alt": return "Alt."
        case "Circuit": return "Circuito"
        case "Direct": return "Directa"
        case "No highway": return "Sin autopista"
        case "No toll": return "Sin peajes"
        case "No hwy/toll": return "Sin autopista/peaje"
        case "GPX": return "GPX"
        default: return label
        }
    }

    /// Display text of a routing warning (orchestrator warnings are English data).
    public func routingWarning(_ text: String) -> String {
        guard es else { return text }
        switch text {
        case RouteOrchestrator.warningAvoidFallback:
            return "No se pudieron evitar autopistas/peajes en línea: ruta normal (puede usar autopista)"
        case RouteOrchestrator.warningCircuitAvoid:
            return "No se pudieron evitar autopistas/peajes: el circuito puede usar autopista"
        case RouteOrchestrator.errorCircuit:
            return "No se pudo crear el circuito de ida y vuelta"
        case RouteOrchestrator.errorCircuitFailed:
            return "Falló el circuito"
        case "Avoid setting not applied":
            return phrase(.avoidNotApplied)
        default: return text
        }
    }

    /// Name given to a long-press pin.
    public var droppedPinName: String { es ? "Punto marcado" : "Dropped pin" }
    /// Name of the parking pin.
    public var parkedName: String { es ? "Estacionado" : "Parked" }
    /// Name of the home place.
    public var homeName: String { es ? "Casa" : "Home" }
    public var parkedHereSubtitle: String { es ? "Estacionado aquí" : "Parked here" }
    public var markedOnArrivalSubtitle: String { es ? "Marcado al llegar" : "Marked on arrival" }
    public var markedOnDashSubtitle: String { es ? "Marcado en el tablero" : "Marked on dash" }
    public var setOnDashSubtitle: String { es ? "Fijada en el tablero" : "Set on dash" }
    /// Waypoint pin name fallback.
    public var waypointName: String { es ? "Punto de paso" : "Waypoint" }
    /// POI chip label for display (chip identifiers stay English).
    public func poiChipLabel(_ label: String) -> String {
        guard es else { return label }
        switch label {
        case "Fuel": return "Gasolinera"
        case "Cafe": return "Café"
        case "Food": return "Comida"
        case "Parking": return "Estacionamiento"
        case "Hotel": return "Hotel"
        case "ATM": return "Cajero automático"
        case "Hospital": return "Hospital"
        case "Viewpoint": return "Mirador"
        default: return label
        }
    }

    // MARK: Lap card

    public var lapPassStartFinish: String { es ? "Pasa por salida/meta" : "Pass start/finish" }
    public func lapCurrent(_ lap: Int, _ time: String) -> String { es ? "VUELTA \(lap)  \(time)" : "LAP \(lap)  \(time)" }
    public func lapMeta(last: String, best: String) -> String {
        es ? "ÚLTIMA \(last)   MEJOR \(best)" : "LAST \(last)   BEST \(best)"
    }

    // MARK: Fixed phrases

    public func phrase(_ p: NavPhrase) -> String {
        switch p {
        case .routeUpdated: return es ? "Ruta actualizada" : "Route updated"
        case .routeReady: return es ? "Ruta lista" : "Route ready"
        case .arrived: return es ? "Llegaste" : "Arrived"
        case .navigationFinished: return es ? "Navegación finalizada" : "Navigation finished"
        case .typeSearchOnPhone: return es ? "Escribe tu búsqueda en el teléfono" : "Type your search on the phone"
        case let .navigatingTo(n): return es ? "Navegando a \(n)" : "Navigating to \(n)"
        case .saved: return es ? "Guardado" : "Saved"
        case .homeSet: return es ? "Casa guardada" : "Home set"
        case .markerAdded: return es ? "Marcador añadido" : "Marker added"
        case .parkingMarked: return es ? "Estacionamiento marcado" : "Parking marked"
        case .parkingUpdated: return es ? "Estacionamiento actualizado" : "Parking updated"
        case .parkingCleared: return es ? "Estacionamiento borrado" : "Parking cleared"
        case .backOnTrack: return es ? "De vuelta en la ruta" : "Back on track"
        case .centered: return es ? "Centrado" : "Centered"
        case .buildingCircuit: return es ? "Creando circuito de ida y vuelta" : "Building there and back circuit"
        case .lapTimerArmed: return es ? "Cronómetro de vueltas activado" : "Lap timer armed"
        case .pinDropped: return es ? "Punto marcado" : "Pin dropped"
        case .destinationReached: return es ? "Llegaste a tu destino" : "Destination reached"
        case let .arrivingAt(n): return es ? "Llegando a \(n)" : "Arriving at \(n)"
        case let .lap(n): return es ? "Vuelta \(n)" : "Lap \(n)"
        case .followingTrackReversed: return es ? "Siguiendo el track en sentido contrario" : "Following the track the other way"
        case .rerouting: return es ? "Recalculando la ruta" : "Rerouting"
        case let .approaching(n):
            let name = n.flatMap { $0.isNavBlank ? nil : $0 }
            return es ? "Te acercas a \(name ?? "un punto de paso")" : "Approaching \(name ?? "waypoint")"
        case .routing: return es ? "Calculando ruta…" : "Routing…"
        case .noRoadRoute: return es ? "Sin ruta por carretera · línea recta" : "No road route · straight line"
        case let .routeSummary(d): return es ? "Ruta · \(d)" : "Route · \(d)"
        case .gpsFreeRide: return es ? "GPS… · ruta libre" : "GPS… · free ride"
        case let .gpsNavigateTo(n): return es ? "GPS… · navegar a \(n)" : "GPS… · navigate to \(n)"
        case let .gpsTrack(t): return es ? "GPS… · track de \(t)" : "GPS… · \(t) track"
        case .gpsOnly: return "GPS…"
        case let .savedToFavorites(n): return es ? "\(n) guardado en favoritos" : "Saved \(n) to favorites"
        case .savePinHint: return es ? "Guarda este punto: ábrelo luego para navegar" : "Save this pin — open it later to navigate"
        case .alreadyFreeRide: return es ? "Ya estás en ruta libre" : "Already free ride"
        case .alreadyNearby: return es ? "Ya estás cerca" : "Already nearby"
        case .noGpsForParking: return es ? "Sin GPS para marcar el estacionamiento" : "No GPS for parking"
        case .parkedSpotCleared: return es ? "Estacionamiento borrado" : "Parked spot cleared"
        case .noHomeSet:
            return es ? "No hay casa guardada: mantén presionado el mapa o usa Guardar casa aquí"
                : "No Home set — long-press map or use Set Home"
        case .noGpsToSetHome: return es ? "Sin GPS para fijar la casa" : "No GPS to set Home"
        case .homeSetHere: return es ? "Casa guardada aquí" : "Home set here"
        case .snapBackOnTrack: return es ? "Ajustado · de vuelta en la ruta" : "Snap · back on track"
        case .recentered: return es ? "Recentrado" : "Recentered"
        case .noGps: return es ? "Sin GPS" : "No GPS"
        case .needGpsForCircuit: return es ? "Se necesita GPS para un circuito" : "Need GPS for a circuit"
        case .pickDestinationForCircuit:
            return es ? "Elige un destino y luego Circuito (ida y vuelta)" : "Pick a destination, then Circuit (there & back)"
        case .pickPlaceAwayForCircuit:
            return es ? "Elige un lugar alejado de ti y luego Circuito" : "Pick a place away from you, then Circuit"
        case let .buildingCircuitTo(n): return es ? "Creando ida y vuelta a \(n)…" : "Building there & back to \(n)…"
        case .thereAndBackReturning: return es ? "Ida y vuelta · regreso al inicio" : "There & back · returning home"
        case .thereAndBackReturns: return es ? "Ida y vuelta · vuelve al inicio" : "There & back · returns home"
        case .noCircuitFound: return es ? "No se encontró ningún circuito" : "No circuit found"
        case .lapTimerOff: return es ? "Cronómetro desactivado" : "Lap timer off"
        case .needGpsForLap: return es ? "Se necesita GPS para el cronómetro" : "Need GPS for lap timer"
        case .lapArmedHint: return es ? "Vuelta: sal y luego pasa por salida/meta" : "Lap: ride out, then pass start/finish"
        case let .lapFinished(n, last): return es ? "Vuelta \(n)  \(last)" : "Lap \(n)  \(last)"
        case .freeRide: return es ? "Ruta libre" : "Free ride"
        case .gettingRoute: return es ? "Obteniendo ruta…" : "Getting route…"
        case .waitingForGps: return es ? "Esperando GPS para calcular la ruta" : "Waiting for GPS to route"
        case .straightLine: return es ? "Línea recta (sin ruta por carretera)" : "Straight line (no road route)"
        case .avoidNotApplied: return es ? "No se aplicó la opción de evitar" : "Avoid setting not applied"
        case .centeredOnGps: return es ? "Centrado en el GPS" : "Centered on GPS"
        case .noGpsYet: return es ? "Aún sin GPS: espera una señal" : "No GPS yet — wait for a fix"
        case .headingUp: return es ? "Rumbo arriba" : "Heading up"
        case .northUp: return es ? "Norte arriba" : "North up"
        case let .savedPlaceNotSet(n):
            return es ? "El lugar guardado \(n) no está configurado" : "Saved place \(n) is not set"
        case .searching: return es ? "Buscando…" : "Searching…"
        case .noResults: return es ? "Sin resultados" : "No results"
        case let .placesFound(n): return es ? "\(n) lugares" : "\(n) places"
        case .recentAndFavorites: return es ? "Recientes y favoritos" : "Recent & favorites"
        case .searchIdleHintPhone: return es ? "Busca un lugar o toca una categoría" : "Search for a place or tap a category"
        case .searchIdleHintBike: return es ? "Escribe en el TELÉFONO o toca una categoría" : "Type on PHONE, or tap a category"
        case .suggestions: return es ? "Sugerencias…" : "Suggestions…"
        case .needGpsForPoi: return es ? "Se necesita GPS para buscar cerca" : "Need GPS for nearby POI"
        case let .findingNearby(l): return es ? "Buscando \(l) cerca…" : "Finding \(l) nearby…"
        case let .noneFoundNearby(l): return es ? "No se encontró \(l) cerca" : "No \(l) found nearby"
        case let .foundNearby(n, l): return es ? "\(n) \(l) cerca" : "\(n) \(l) nearby"
        }
    }
}

extension String {
    /// Kotlin `isBlank()`: empty or only whitespace.
    var isNavBlank: Bool { allSatisfy { $0.isWhitespace } }

    /// Kotlin `replaceFirstChar { it.uppercase() }`.
    var navCapitalizedFirst: String {
        guard let f = first else { return self }
        return String(f).uppercased() + dropFirst()
    }
}
