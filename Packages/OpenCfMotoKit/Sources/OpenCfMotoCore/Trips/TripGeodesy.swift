// SPDX-License-Identifier: AGPL-3.0-or-later AND Apache-2.0
// Portions Copyright (C) 2007 The Android Open Source Project, licensed under the Apache License,
// Version 2.0 (LICENSES/Apache-2.0.txt). Translated to Swift and modified by the OpenCfMoto for iOS
// contributors; this file as a whole is distributed under the AGPL-3.0-or-later (see NOTICE).
//
// Distance between two fixes as Android computes it for trips (`Location.distanceTo`): the WGS84
// ellipsoid inverse formula (Vincenty, NOAA "Inverse Formula" §4, 20 iterations max), returned as a
// 32-bit float. Port of AOSP `android.location.Location.computeDistanceAndBearing` (Apache-2.0).
// CoreLocation's `CLLocation.distance(from:)` differs by well under 0.5 % (app-features.md §13.5).

import Foundation

public enum TripGeodesy {
    /// Android `Location.distanceTo` in metres (Float like Android).
    public static func androidDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Float {
        let maxIters = 20
        let rlat1 = lat1 * (Double.pi / 180.0)
        let rlat2 = lat2 * (Double.pi / 180.0)
        let rlon1 = lon1 * (Double.pi / 180.0)
        let rlon2 = lon2 * (Double.pi / 180.0)

        let a = 6_378_137.0          // WGS84 major axis
        let b = 6_356_752.3142       // WGS84 semi-minor axis
        let f = (a - b) / a
        let aSqMinusBSqOverBSq = (a * a - b * b) / (b * b)

        let l = rlon2 - rlon1
        var aA = 0.0
        let u1 = atan((1.0 - f) * tan(rlat1))
        let u2 = atan((1.0 - f) * tan(rlat2))

        let cosU1 = cos(u1), cosU2 = cos(u2)
        let sinU1 = sin(u1), sinU2 = sin(u2)
        let cosU1cosU2 = cosU1 * cosU2
        let sinU1sinU2 = sinU1 * sinU2

        var sigma = 0.0
        var deltaSigma = 0.0
        var lambda = l // initial guess
        for _ in 0 ..< maxIters {
            let lambdaOrig = lambda
            let cosLambda = cos(lambda)
            let sinLambda = sin(lambda)
            let t1 = cosU2 * sinLambda
            let t2 = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda
            let sinSqSigma = t1 * t1 + t2 * t2
            let sinSigma = sqrt(sinSqSigma)
            let cosSigma = sinU1sinU2 + cosU1cosU2 * cosLambda
            sigma = atan2(sinSigma, cosSigma)
            let sinAlpha = (sinSigma == 0) ? 0.0 : cosU1cosU2 * sinLambda / sinSigma
            let cosSqAlpha = 1.0 - sinAlpha * sinAlpha
            let cos2SM = (cosSqAlpha == 0) ? 0.0 : cosSigma - 2.0 * sinU1sinU2 / cosSqAlpha

            let uSquared = cosSqAlpha * aSqMinusBSqOverBSq
            aA = 1 + (uSquared / 16384.0) * (4096.0 + uSquared * (-768 + uSquared * (320.0 - 175.0 * uSquared)))
            let bB = (uSquared / 1024.0) * (256.0 + uSquared * (-128.0 + uSquared * (74.0 - 47.0 * uSquared)))
            let cC = (f / 16.0) * cosSqAlpha * (4.0 + f * (4.0 - 3.0 * cosSqAlpha))
            let cos2SMSq = cos2SM * cos2SM
            deltaSigma = bB * sinSigma * (cos2SM + (bB / 4.0) * (cosSigma * (-1.0 + 2.0 * cos2SMSq)
                - (bB / 6.0) * cos2SM * (-3.0 + 4.0 * sinSigma * sinSigma) * (-3.0 + 4.0 * cos2SMSq)))

            lambda = l + (1.0 - cC) * f * sinAlpha * (sigma + cC * sinSigma * (cos2SM
                + cC * cosSigma * (-1.0 + 2.0 * cos2SM * cos2SM)))

            let delta = (lambda - lambdaOrig) / lambda
            if abs(delta) < 1.0e-12 { break }
        }
        return Float(b * aA * (sigma - deltaSigma))
    }

    /// Convenience over `GeoPoint`s.
    public static func androidDistance(_ p: GeoPoint, _ q: GeoPoint) -> Float {
        androidDistance(lat1: p.lat, lon1: p.lon, lat2: q.lat, lon2: q.lon)
    }
}
