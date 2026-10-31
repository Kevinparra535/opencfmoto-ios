// SPDX-License-Identifier: AGPL-3.0-or-later
//
// User-visible strings produced by the data models (garage, settings, navigation, trips, logs):
// small EN/ES tables keyed by `AppCore.language` (no bundle lookups in the package). English texts
// are the Android ones (docs/spec/app-features.md §3–§9, session-network.md §2.11); Spanish reuses
// the Android `values-es` strings where they exist and the spec's proposed translations otherwise.
// Log lines stay English by design and are not here.

import Foundation
import OpenCfMotoCore

extension LogicData {
    struct Strings: Sendable, Equatable {
        let language: NavLanguage

        init(_ language: NavLanguage) { self.language = language }

        private var es: Bool { language == .es }
        private func t(_ en: String, _ es: String) -> String { self.es ? es : en }

        // MARK: - Garage / pairing

        /// `main_invalid_qr`.
        var invalidQR: String { t("Invalid QR", "QR no válido") }
        /// Manual pairing with an empty field (`ManualWifiPairing.kt`).
        var ssidAndPasswordRequired: String {
            t("SSID and password are required", "El SSID y la contraseña son obligatorios")
        }
        /// Photo could not be stored (`GarageActivity.kt`).
        var couldNotReadImage: String { t("Couldn't read that image", "No se pudo leer esa imagen") }
        var bikeNotFound: String { t("Bike not found", "Moto no encontrada") }

        /// Localizes a `BikeQR.iosFailureHint(for:)` text (English verbatim from the core). Unknown
        /// texts are returned unchanged.
        func qrHint(_ englishHint: String) -> String {
            guard es else { return englishHint }
            return Self.qrHintsES[englishHint] ?? englishHint
        }

        /// The iOS wording of the seven Android parse-failure hints (Android hotspot → Personal
        /// Hotspot) → Spanish.
        static let qrHintsES: [String: String] = [
            "Moto Morini QR has no Wifi= field \u{2014} open the phone-link / MotoFun QR on the dash":
                "El QR de Moto Morini no tiene el campo Wifi=: abre en el tablero el QR de enlace con el teléfono / MotoFun",
            "that QR is bike info (color/VIN), not Wi\u{2011}Fi pairing \u{2014} open MotoPlay / EasyConnect / MotoFun QR":
                "ese QR es información de la moto (color/VIN), no el emparejamiento Wi\u{2011}Fi: abre el QR de MotoPlay / EasyConnect / MotoFun",
            "that is the Carbit app-download QR, not pairing \u{2014} open MotoPlay / EasyConnect so the Wi-Fi QR (SSID + password) stays on screen":
                "ese es el QR para descargar la app de Carbit, no el de emparejamiento: abre MotoPlay / EasyConnect para que el QR del Wi-Fi (SSID + contraseña) quede en pantalla",
            "this dash joins your phone hotspot \u{2014} turn on Personal Hotspot with the SSID/password shown on the dash, then Connect":
                "este tablero se conecta al punto de acceso de tu teléfono: activa el Punto de acceso personal con el SSID y la contraseña que muestra el tablero y luego toca Conectar",
            "Carbit ID QR \u{2014} enable Personal Hotspot with the SSID/password on the dash, then Connect":
                "QR de ID de Carbit: activa el Punto de acceso personal con el SSID y la contraseña del tablero y luego toca Conectar",
            "Kove/Thinkerride \u{2014} need the SoftAP pairing QR (SSID+password on the dash, or g.thinkerride.com?SSID&PWD&ap=1). Garage \u{2192} enter SSID/pwd if the QR is only \u{201C}download KOVE APP\u{201D}":
                "Kove/Thinkerride: hace falta el QR de emparejamiento SoftAP (SSID + contraseña en el tablero, o g.thinkerride.com?SSID&PWD&ap=1). Garaje \u{2192} introduce el SSID y la contraseña si el QR solo dice \u{00AB}download KOVE APP\u{00BB}",
            "URL QR without ssid/pwd \u{2014} need the dash pairing QR (Carbit / EasyConnect / MotoFun / Thinkerride SoftAP), or enable phone hotspot if the dash asks for it":
                "QR de URL sin ssid/pwd: hace falta el QR de emparejamiento del tablero (Carbit / EasyConnect / MotoFun / Thinkerride SoftAP), o activa el punto de acceso del teléfono si el tablero lo pide",
        ]

        // MARK: - Settings

        /// Profile picker entry for automatic selection.
        var auto: String { t("Auto", "Automático") }
        /// Import of a blank file (`SetupActivity.kt`).
        var emptyFile: String { t("Empty file", "Archivo vacío") }
        /// `Import failed: <e>`.
        func importFailed(_ detail: String) -> String { t("Import failed: \(detail)", "Error al importar: \(detail)") }
        /// `Export failed: <e>` (`trips_export_failed`).
        func exportFailed(_ detail: String) -> String { t("Export failed: \(detail)", "Error al exportar: \(detail)") }
        /// Android's `onto` fallback when no bike is selected.
        var selectedBike: String { t("selected bike", "la moto seleccionada") }

        /// Localizes a `SettingsBackup.importJSON` result message (English verbatim from the core).
        /// `ontoEnglish` is the `bikeName` given to the core (nil → "selected bike").
        func settingsImportMessage(_ message: String, ontoEnglish: String?) -> String {
            guard es else { return message }
            let ontoEN = ontoEnglish ?? "selected bike"
            let ontoES = ontoEnglish ?? selectedBike
            let importedPrefix = "Imported bike tuning ("
            let importedSuffix = ") onto \(ontoEN)"
            if message.hasPrefix(importedPrefix), message.hasSuffix(importedSuffix),
               message.count >= importedPrefix.count + importedSuffix.count {
                let profile = String(message.dropFirst(importedPrefix.count).dropLast(importedSuffix.count))
                return "Ajustes de la moto importados (\(profile)) en \(ontoES)"
            }
            if message == "Bike tuning imported onto \(ontoEN)" {
                return "Ajustes de la moto importados en \(ontoES)"
            }
            if let rest = Self.suffix(of: message, after: "Not valid JSON: ") {
                return "JSON no válido: \(rest)"
            }
            if let rest = Self.suffix(of: message, after: "Not an OpenCfMoto settings file (format=") {
                return "No es un archivo de ajustes de OpenCfMoto (format=\(rest)"
            }
            if let rest = Self.suffix(of: message, after: "Unsupported settings version ") {
                // "<v> (this app reads 1…1)"
                let localized = rest.replacingOccurrences(of: " (this app reads ", with: " (esta app lee ")
                return "Versión de ajustes no compatible: \(localized)"
            }
            if message == "Missing settings object" {
                return "Falta el objeto \u{00AB}settings\u{00BB}"
            }
            if let rest = Self.suffix(of: message, after: "Import failed: ") {
                return importFailed(rest)
            }
            return message
        }

        /// Localizes a `MapDataBackup.importJSON` result message (English verbatim from the core).
        func mapImportMessage(_ message: String) -> String {
            guard es else { return message }
            if message == "Map data imported" { return "Datos del mapa importados" }
            if message == "Not an OpenCfMoto map file" { return "No es un archivo de mapa de OpenCfMoto" }
            if let rest = Self.suffix(of: message, after: "Not valid JSON: ") { return "JSON no válido: \(rest)" }
            if let rest = Self.suffix(of: message, after: "Unsupported map backup version ") {
                return "Versión de copia del mapa no compatible: \(rest)"
            }
            if let rest = Self.suffix(of: message, after: "Import failed: ") { return importFailed(rest) }
            return message
        }

        private static func suffix(of text: String, after prefix: String) -> String? {
            guard text.hasPrefix(prefix) else { return nil }
            return String(text.dropFirst(prefix.count))
        }

        // MARK: - Navigation / search

        /// `main_type_place` (Android shows it when Go is tapped with an empty field).
        var typePlace: String { t("Type a place to search on the map", "Escribe un lugar para buscar en el mapa") }
        /// "Type on phone" from the dash search (`MainActivity.kt:612`, spec §9.13).
        var bikeSearchOpen: String {
            t("Bike search open \u{2014} type here. Results appear on the dash.",
              "Búsqueda de la moto abierta: escribe aquí. Los resultados aparecen en el tablero.")
        }
        var searchFailed: String { t("Search failed", "La búsqueda falló") }
        var gpxEmpty: String { t("GPX has no track points or waypoints", "El GPX no tiene puntos de track ni waypoints") }
        func gpxUnreadable(_ detail: String) -> String {
            t("Couldn't read that GPX file: \(detail)", "No se pudo leer el archivo GPX: \(detail)")
        }

        /// User-facing text for a routing / search failure (Android `AppHttp` messages, localized).
        func serviceError(_ error: Error, fallback: String) -> String {
            if let e = error as? NavServiceError {
                switch e {
                case let .http(code, _, _):
                    if code == 429 {
                        return t("Map service is busy (rate limited) \u{2014} try again shortly",
                                 "El servicio de mapas está saturado (límite de peticiones): inténtalo de nuevo en un momento")
                    }
                    if (500 ... 599).contains(code) {
                        return t("Map service temporarily unavailable (HTTP \(code))",
                                 "Servicio de mapas no disponible temporalmente (HTTP \(code))")
                    }
                    return t("Request failed (HTTP \(code))", "La petición falló (HTTP \(code))")
                case .responseTooLarge:
                    return t("Response too large", "Respuesta demasiado grande")
                case .invalidJSON:
                    return t("\(fallback): unexpected response from the map service",
                             "\(fallback): respuesta inesperada del servicio de mapas")
                case let .service(message):
                    // Service texts come from NavStrings (already in the session language) or the
                    // routing services themselves.
                    return message
                }
            }
            if let e = error as? HTTPClientError {
                switch e {
                case .noNetwork:
                    return t("No internet connection", "Sin conexión a internet")
                case .timeout:
                    return t("The map service did not answer in time", "El servicio de mapas no respondió a tiempo")
                case let .badStatus(code, _):
                    return t("Request failed (HTTP \(code))", "La petición falló (HTTP \(code))")
                case .invalidResponse:
                    return t("\(fallback): invalid response", "\(fallback): respuesta no válida")
                }
            }
            if error is TimeoutError {
                return t("The map service did not answer in time", "El servicio de mapas no respondió a tiempo")
            }
            return "\(fallback): \(LogicData.detail(of: error))"
        }

        // MARK: - Trips

        /// `trips_day_summary` (plural): `%1$d ride · %2$.1f km` / `%1$d viajes · %2$.1f km`.
        /// `distance` is already formatted (one decimal, locale separator).
        func tripDaySummary(count: Int, distance: String) -> String {
            if es {
                return count == 1 ? "\(count) viaje \u{00B7} \(distance) km" : "\(count) viajes \u{00B7} \(distance) km"
            }
            return count == 1 ? "\(count) ride \u{00B7} \(distance) km" : "\(count) rides \u{00B7} \(distance) km"
        }

        /// `trips_no_gps_points`.
        var tripHasNoPoints: String { t("Trip has no GPS points", "El viaje no tiene puntos GPS") }

        // MARK: - Logs / problem report

        /// `main_share_report_failed`.
        func shareReportFailed(_ detail: String) -> String {
            t("Couldn't share report: \(detail)", "No se pudo compartir el informe: \(detail)")
        }
    }
}
