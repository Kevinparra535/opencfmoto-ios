// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) res/values/strings.xml + res/values-es/strings.xml (conn_*,
// main_*) and the hard-coded strings of MainActivity.kt / ConnectionState.kt / TripActivity.kt —
// docs/spec/app-features.md §7.2, §7.4, §9.2, §9.3, §9.13.
//
// User-visible texts produced by the session models (ConnectionModel, RideModel, ControlsModel,
// PermissionsModel, AppModel). The model layer has no bundle: small EN/ES tables keyed by the
// app language (`AppCore.language`). Log lines stay English (Android stage tags), see
// `phaseLogLabel` / `phaseAndroidName`.

import Foundation
import OpenCfMotoCore

/// EN/ES texts of the session models.
enum SessionText {
    private static func pick(_ l: NavLanguage, _ en: String, _ es: String) -> String { l == .es ? es : en }

    // MARK: - Connection phases (logs / problem reports, English like Android)

    /// `ConnectionState.logLabel` (English in every locale).
    static func phaseLogLabel(_ p: ConnectionPhase) -> String {
        switch p {
        case .idle: return "Ready"
        case .joiningWifi: return "Connecting to bike Wi-Fi\u{2026}"
        case .linking: return "Linking to dashboard\u{2026}"
        case .streaming: return "Connected \u{2014} projecting to dash"
        case .mirroring: return "Mirroring screen to dash"
        case .reconnecting: return "Link dropped \u{2014} reconnecting\u{2026}"
        case .waitingForBike: return "Bike out of range \u{2014} waiting\u{2026}"
        case .stopped: return "Stopped"
        case .error: return "Error \u{2014} see logs"
        }
    }

    /// Android `ConnectionState` enum NAME (problem reports: `phase=STREAMING …`).
    static func phaseAndroidName(_ p: ConnectionPhase) -> String {
        switch p {
        case .idle: return "IDLE"
        case .joiningWifi: return "JOINING_WIFI"
        case .linking: return "PXC_CONNECTING"
        case .streaming: return "STREAMING"
        case .mirroring: return "MIRRORING"
        case .reconnecting: return "RECONNECTING"
        case .waitingForBike: return "WAITING_FOR_BIKE"
        case .stopped: return "STOPPED"
        case .error: return "ERROR"
        }
    }

    // MARK: - Connection details (§7.4 / §9.3)

    static func attempt(_ n: Int, _ l: NavLanguage) -> String {
        pick(l, "attempt \(n)", "intento \(n)")
    }

    static func waitingForBikeWifi(_ l: NavLanguage) -> String {
        pick(l, "waiting for bike Wi-Fi", "esperando el Wi-Fi de la moto")
    }

    static func willResume(_ l: NavLanguage) -> String {
        pick(l, "will resume when the bike is back", "se reanudará cuando vuelva la moto")
    }

    /// PXC_CONNECTING detail after the Wi-Fi came back (BikeLink.onWifiReacquired).
    static func reconnecting(_ l: NavLanguage) -> String {
        pick(l, "reconnecting", "reconectando")
    }

    static func officialAppInTheWay(_ l: NavLanguage) -> String {
        pick(l, "close the official CFMoto app, then reconnect", "cierra la app oficial de CFMoto y vuelve a conectar")
    }

    /// `conn_detail_easyconn_offline`.
    static func easyConnOffline(_ l: NavLanguage) -> String {
        pick(l, "Bike Wi\u{2011}Fi is up but EasyConn is offline \u{2014} keep the pairing QR open on the dash",
             "El Wi-Fi de la moto está activo pero EasyConn está desconectado: mantén abierto el QR de emparejamiento en el tablero")
    }

    /// No dash answered on a Wi-Fi the app could not confirm as the bike's (SSID unknown, nothing
    /// streamed yet): the phone may still be on the home Wi-Fi, so never claim the bike Wi-Fi is up.
    static func noDashOnThisWifi(ssid: String, _ l: NavLanguage) -> String {
        pick(l, "No dash answered on this Wi-Fi \u{2014} if your iPhone is not on \u{201C}\(ssid)\u{201D}, join it in Settings \u{25B8} Wi-Fi; otherwise keep the pairing QR open on the dash",
             "Ningún tablero respondió en este Wi-Fi: si el iPhone no está en «\(ssid)», únete en Ajustes \u{25B8} Wi-Fi; si lo está, mantén abierto el QR de emparejamiento en el tablero")
    }

    static func lostLink(_ l: NavLanguage) -> String {
        pick(l, "lost bike link", "se perdió el enlace con la moto")
    }

    /// `conn_detail_connect_failed`.
    static func connectFailed(_ l: NavLanguage) -> String {
        pick(l, "Connect failed \u{2014} see Logs / Share Logs", "Error de conexión: mira Registros o Compartir registros")
    }

    /// `conn_detail_auto_connect_failed`.
    static func autoConnectFailed(_ l: NavLanguage) -> String {
        pick(l, "Auto-connect failed \u{2014} see Logs", "Error de conexión automática: mira Registros")
    }

    static func localNetworkDenied(_ l: NavLanguage) -> String {
        pick(l, "Local Network access is off \u{2014} allow it in Settings \u{25B8} OpenCfMoto",
             "El acceso a la red local está desactivado: actívalo en Ajustes \u{25B8} OpenCfMoto")
    }

    /// The system dropped the link's connect() although Local Network access works (review POSIX-2).
    static func systemBlocksBikeLink(_ l: NavLanguage) -> String {
        pick(l, "Something on the phone blocks the bike Wi-Fi (VPN, data restriction or filter)",
             "Algo en el teléfono bloquea el Wi-Fi de la moto (VPN, restricción de datos o filtro)")
    }

    /// Dialog text for `systemBlocksBikeLink`.
    static func systemBlocksBikeLinkMessage(_ l: NavLanguage) -> String {
        pick(l, "Local Network access is on, but iOS still blocked the connection to the dash. A VPN without local-network access, a Wi-Fi data restriction for OpenCfMoto or a content filter does that: turn it off, then tap Connect again. Share Logs if it keeps happening.",
             "El acceso a la red local está activado, pero iOS bloqueó igualmente la conexión con el tablero. Eso lo hace una VPN sin acceso a la red local, una restricción de datos Wi-Fi para OpenCfMoto o un filtro de contenido: desactívalo y vuelve a tocar Conectar. Comparte los registros si sigue pasando.")
    }

    /// The system dropped the link's connect() and the Local Network check could not tell why.
    static func bikeLinkBlocked(_ l: NavLanguage) -> String {
        pick(l, "The phone blocked the connection to the dash \u{2014} check Local Network access and any VPN",
             "El teléfono bloqueó la conexión con el tablero: revisa el acceso a la red local y cualquier VPN")
    }

    /// Dialog text for `bikeLinkBlocked`.
    static func bikeLinkBlockedMessage(_ l: NavLanguage) -> String {
        pick(l, "iOS blocked the connection to the dash. Check that Local Network access is on for OpenCfMoto (Settings \u{25B8} OpenCfMoto \u{25B8} Local Network) and that no VPN, Wi-Fi data restriction or content filter blocks the bike Wi-Fi, then tap Connect again.",
             "iOS bloqueó la conexión con el tablero. Comprueba que el acceso a la red local esté activado para OpenCfMoto (Ajustes \u{25B8} OpenCfMoto \u{25B8} Red local) y que ninguna VPN, restricción de datos Wi-Fi o filtro de contenido bloquee el Wi-Fi de la moto; luego vuelve a tocar Conectar.")
    }

    /// The rider tapped "I've joined" while iOS still reports another Wi-Fi (review SESS-1).
    static func manualJoinStillOnOtherWifi(other: String, ssid: String, _ l: NavLanguage) -> String {
        pick(l, "iOS still reports \u{201C}\(other)\u{201D}. Join \u{201C}\(ssid)\u{201D} in Settings \u{25B8} Wi-Fi with the password below, then come back \u{2014} OpenCfMoto continues automatically.",
             "iOS sigue indicando «\(other)». Únete a «\(ssid)» en Ajustes \u{25B8} Wi-Fi con la contraseña de abajo y vuelve: OpenCfMoto seguirá automáticamente.")
    }

    static func noWifiAddress(_ l: NavLanguage) -> String {
        pick(l, "not connected to the bike Wi-Fi \u{2014} join it, then tap Connect",
             "no estás conectado al Wi-Fi de la moto: únete y vuelve a tocar Conectar")
    }

    /// Status detail while the rider joins the bike Wi-Fi in Settings.
    static func joinInSettings(ssid: String, _ l: NavLanguage) -> String {
        pick(l, "Join \u{201C}\(ssid)\u{201D} in Settings \u{25B8} Wi-Fi", "Únete a «\(ssid)» en Ajustes \u{25B8} Wi-Fi")
    }

    /// Manual-join instructions (free flavor: no Hotspot Configuration entitlement).
    static func manualJoinMessage(ssid: String, _ l: NavLanguage) -> String {
        pick(l, "Open Settings \u{25B8} Wi-Fi and join \u{201C}\(ssid)\u{201D} with the password below, then come back to OpenCfMoto \u{2014} it continues automatically.",
             "Abre Ajustes \u{25B8} Wi-Fi y únete a «\(ssid)» con la contraseña de abajo; luego vuelve a OpenCfMoto y seguirá automáticamente.")
    }

    /// Duplicate Mirror tap (MainActivity.kt:1504).
    static func alreadyMirroring(_ l: NavLanguage) -> String {
        pick(l, "Already mirroring \u{2014} wait for the dash, or tap Stop first",
             "Ya se está duplicando: espera al tablero o toca Detener primero")
    }

    /// A saved bike whose dash joins the phone's hotspot (review IOS-3): same text as at pairing.
    static func phoneHotspotUnsupported(_ l: NavLanguage) -> String {
        LogicData.Strings(l).qrHint(BikeQR.iosPhoneHotspotUnsupportedHint)
    }

    /// Mirror tapped with location denied / restricted (review IOS-2): background location is what
    /// keeps the host's dash link alive while the rider uses other apps.
    static func mirrorNeedsLocation(_ l: NavLanguage) -> String {
        pick(l, "Mirroring needs Location access (While Using the App): it keeps the dash link alive while you use other apps. Allow it in Settings \u{25B8} OpenCfMoto \u{25B8} Location, then tap Mirror again.",
             "El modo Espejo necesita acceso a la ubicación (Al usar la app): mantiene el enlace con el tablero mientras usas otras apps. Actívalo en Ajustes \u{25B8} OpenCfMoto \u{25B8} Ubicación y vuelve a tocar Espejo.")
    }

    static func mirrorUnavailable(_ l: NavLanguage) -> String {
        pick(l, "Couldn't start mirroring \u{2014} see Logs", "No se pudo iniciar la duplicación: mira Registros")
    }

    // MARK: - Dash overlays

    /// The "hold" picture served while the phone is locked / the app is in the background.
    static func holdMessage(_ l: NavLanguage) -> String {
        pick(l, "Phone locked \u{2014} unlock to update the map", "Teléfono bloqueado: desbloquéalo para actualizar el mapa")
    }

    static func reconnectingBanner(_ l: NavLanguage) -> String {
        pick(l, "Reconnecting\u{2026}", "Reconectando\u{2026}")
    }

    static func waitingForWifiBanner(_ l: NavLanguage) -> String {
        pick(l, "Waiting for bike Wi-Fi\u{2026}", "Esperando el Wi-Fi de la moto\u{2026}")
    }

    // MARK: - Apple Music on the dash (iOS addition) — who gets the handlebar buttons

    /// Contract R2: the rider started Apple Music while the phone media remote drives the dash.
    static func musicTakesHandlebar(_ l: NavLanguage) -> String {
        pick(l, "Handlebar buttons now control Apple Music", "Los botones del manillar controlan ahora Apple Music")
    }

    /// Contract R3: the song was paused and OpenCfMoto took the buttons back.
    static func handlebarBackToDash(_ l: NavLanguage) -> String {
        pick(l, "Handlebar buttons control the dash again", "Los botones del manillar vuelven a controlar el tablero")
    }

    // MARK: - Dash menu: Record ride (GpxDashUi.kt:1893-1905)

    static func recordingRide(_ l: NavLanguage) -> String {
        pick(l, "Recording ride\u{2026}", "Grabando el viaje\u{2026}")
    }

    static func recordingSavedToast(_ l: NavLanguage) -> String {
        pick(l, "Ride recording saved", "Grabación del viaje guardada")
    }

    static func cannotRecord(_ l: NavLanguage) -> String {
        pick(l, "Can't record \u{2014} check GPS / permission", "No se puede grabar: revisa el GPS o el permiso")
    }

    static func recordingStartedVoice(_ l: NavLanguage) -> String {
        pick(l, "Recording started", "Grabación iniciada")
    }

    static func recordingSavedVoice(_ l: NavLanguage) -> String {
        pick(l, "Recording saved", "Grabación guardada")
    }

    static func placeDeleted(_ l: NavLanguage) -> String {
        pick(l, "Deleted", "Eliminado")
    }

    // MARK: - GPS status (TripActivity.kt:95-130)

    static func locationPermissionNeeded(_ l: NavLanguage) -> String {
        pick(l, "Location permission needed", "Se necesita el permiso de ubicación")
    }

    static func gpsOff(_ l: NavLanguage) -> String {
        pick(l, "GPS is off", "GPS desactivado")
    }

    static func waitingForGps(_ l: NavLanguage) -> String {
        pick(l, "Waiting for GPS\u{2026}", "Esperando GPS\u{2026}")
    }

    static func gpsFix(accuracyM: Int?, _ l: NavLanguage) -> String {
        guard let a = accuracyM, a > 0 else { return pick(l, "GPS fix", "GPS fijado") }
        return pick(l, "GPS fix \u{00B1}\(a) m", "GPS fijado \u{00B1}\(a) m")
    }

    static func approximateLocation(_ l: NavLanguage) -> String {
        pick(l, "Approximate location \u{2014} turn on Precise Location", "Ubicación aproximada: activa la ubicación precisa")
    }

    // MARK: - Handlebar tester (Controls screen)

    static func gestureLabel(_ g: ButtonGesture, _ l: NavLanguage) -> String {
        switch g {
        case .navBack: return "\u{25C0}"
        case .navFwd: return "\u{25B6}"
        case .selectPress: return "\u{2605}"
        case .navBackLong: return pick(l, "Hold \u{25C0}", "Mantener \u{25C0}")
        case .navFwdLong: return pick(l, "Hold \u{25B6}", "Mantener \u{25B6}")
        case .selectLong: return pick(l, "Hold \u{2605}", "Mantener \u{2605}")
        case .navBackDouble: return pick(l, "Double \u{25C0}", "Doble \u{25C0}")
        case .navFwdDouble: return pick(l, "Double \u{25B6}", "Doble \u{25B6}")
        case .selectDouble: return pick(l, "Double \u{2605}", "Doble \u{2605}")
        }
    }

    /// What an action does on OUR dash UI (Android's labels describe Android Auto).
    static func actionLabel(_ a: ButtonAction, _ l: NavLanguage) -> String {
        switch a {
        case .none: return pick(l, "Nothing", "Nada")
        case .knobFwd: return pick(l, "Next item", "Elemento siguiente")
        case .knobBack: return pick(l, "Previous item", "Elemento anterior")
        case .select: return pick(l, "Select", "Seleccionar")
        case .back: return pick(l, "Back", "Atrás")
        case .home: return pick(l, "Menu", "Menú")
        case .assistant: return pick(l, "Search", "Buscar")
        case .up: return pick(l, "Up", "Arriba")
        case .down: return pick(l, "Down", "Abajo")
        case .left: return pick(l, "Left", "Izquierda")
        case .right: return pick(l, "Right", "Derecha")
        case .nav1: return pick(l, "Saved place 1", "Lugar guardado 1")
        case .nav2: return pick(l, "Saved place 2", "Lugar guardado 2")
        case .nav3: return pick(l, "Saved place 3", "Lugar guardado 3")
        }
    }

    // MARK: - Opened files / URLs (AppModel.handleOpenURL)

    static func gpxLoaded(_ name: String, _ l: NavLanguage) -> String {
        pick(l, "Loaded GPX: \(name)", "GPX cargado: \(name)")
    }

    /// GarageActivity "Added <name>".
    static func bikeAdded(_ name: String, _ l: NavLanguage) -> String {
        pick(l, "Added \(name)", "Añadida \(name)")
    }

    static func cannotOpenFile(_ l: NavLanguage) -> String {
        pick(l, "Can't open this file", "No se puede abrir este archivo")
    }

    static func cannotReadFile(_ l: NavLanguage) -> String {
        pick(l, "Couldn't read that file", "No se pudo leer el archivo")
    }
}
