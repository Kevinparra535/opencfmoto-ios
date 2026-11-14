// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the dash's low-range toast and its voice line (EN / ES, neutral Latin-American Spanish: «hasta la
// reserva», «carga gasolina»; never «repostar» or «depósito»). The toast says the range like Home: «~»,
// rounded down to 10 km (5 mi), counted to the reserve. The longest toast (ES, under a step) is 47
// characters: one or two lines of the toast pill on every canvas.

import Foundation

public extension DashStrings {
    /// The toast text: "Low range: ~70 km to reserve", "On reserve: refuel soon".
    static func fuelToast(_ level: FuelAlertLevel, range: FuelFormat.RangeDisplay, _ lang: DashLanguage) -> String {
        switch (level, lang) {
        case (.reserve, .en): return "On reserve: refuel soon"
        case (.reserve, .es): return "En reserva: carga gasolina pronto"
        case (.low, .en):
            return range.isUnderStep ? "Low range: under \(range.number) to reserve" : "Low range: ~\(range.number) to reserve"
        case (.low, .es):
            return range.isUnderStep ? "Autonomía baja: menos de \(range.number) hasta la reserva"
                : "Autonomía baja: ~\(range.number) hasta la reserva"
        }
    }

    /// The voice line: "Low range. About 70 kilometers to reserve.", "You're on reserve. Refuel soon."
    static func fuelVoice(_ level: FuelAlertLevel, range: FuelFormat.RangeDisplay, _ lang: DashLanguage) -> String {
        let metric = range.unit == FuelFormat.distanceUnit(.metric)
        let amount = range.isUnderStep ? range.step : range.value
        switch (level, lang) {
        case (.reserve, .en): return "You're on reserve. Refuel soon."
        case (.reserve, .es): return "Estás en reserva. Carga gasolina pronto."
        case (.low, .en):
            let unit = metric ? "kilometers" : "miles"
            return range.isUnderStep ? "Low range. Under \(amount) \(unit) to reserve."
                : "Low range. About \(amount) \(unit) to reserve."
        case (.low, .es):
            // «millas» is feminine: «Unas 40 millas», «Unos 70 kilómetros».
            let unit = metric ? "kilómetros" : "millas"
            let about = metric ? "Unos" : "Unas"
            return range.isUnderStep ? "Autonomía baja. Menos de \(amount) \(unit) hasta la reserva."
                : "Autonomía baja. \(about) \(amount) \(unit) hasta la reserva."
        }
    }
}
