// SPDX-License-Identifier: AGPL-3.0-or-later
// The sun's elevation above the horizon from a position and an instant — the dash's AUTO night mode
// (P0, D06) follows the sun at the rider's GPS fix and the phone's clock, computed on the device: no
// server, no lookup, nothing leaves the phone.
//
// Low-precision solar coordinates of the Astronomical Almanac (mean longitude and anomaly, ecliptic
// longitude, obliquity → right ascension / declination; Greenwich mean sidereal time → hour angle):
// better than 0.1° between 1950 and 2050, far more than a day / night switch needs.

import Foundation

public enum SunPosition {
    /// Unix time of J2000.0 (2000-01-01 12:00 TT, taken as UTC: the 64-s difference is irrelevant here).
    static let j2000Unix: TimeInterval = 946_728_000

    /// Elevation of the sun's centre above the horizon, in degrees (−90…90; no refraction), at
    /// `latitude` / `longitude` (degrees, north / east positive) and `date` (an instant: no time zone).
    /// nil for a coordinate that is not finite or out of range, or a date that is not finite.
    public static func elevationDeg(latitude: Double, longitude: Double, date: Date) -> Double? {
        let t = date.timeIntervalSince1970
        guard latitude.isFinite, longitude.isFinite, t.isFinite,
              (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else { return nil }
        let rad = Double.pi / 180
        let n = (t - j2000Unix) / 86_400 // days since J2000.0
        let meanLongitude = 280.460 + 0.985_647_4 * n
        let meanAnomaly = (357.528 + 0.985_600_3 * n) * rad
        let eclipticLongitude = (meanLongitude + 1.915 * sin(meanAnomaly) + 0.020 * sin(2 * meanAnomaly)) * rad
        let obliquity = (23.439 - 0.000_000_4 * n) * rad
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let gmstHours = 18.697_374_558 + 24.065_709_824_419_08 * n
        let hourAngle = (gmstHours * 15 + longitude) * rad - rightAscension
        let phi = latitude * rad
        let s = sin(phi) * sin(declination) + cos(phi) * cos(declination) * cos(hourAngle)
        return asin(min(1, max(-1, s))) / rad
    }
}
