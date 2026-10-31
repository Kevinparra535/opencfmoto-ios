// SPDX-License-Identifier: AGPL-3.0-or-later
// `-demoSeed` (with the demo services): realistic content for screenshots and manual testing — one
// paired bike, three saved trips along DemoRoutePlayer.defaultRoute (the Bogotá loop the demo GPS
// replays), a home place, favourites and search history, and the onboarding marked done.
// Auto-connect is turned off so the Home screen is not caught in a demo "Linking…" attempt.
// Everything goes to the in-memory stores / temp folders of `AppServices.preview`, so nothing
// survives the process.

import Foundation
import OpenCfMotoCore
import OpenCfMotoAppModel

enum DemoSeed {
    /// A CFDL16 dash (675 SR-R) pairing QR with a display name.
    static let bikeQR = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=Demo&action=1&ssid=CFMOTO-6GUV675&pwd=demo-only-password&auth=wpa2-psk&name=675%20SR-R"

    static func apply(to services: AppServices, now: Date = Date()) {
        let store = services.keyValueStore
        store.set(true, forKey: "onboarding_done") // PermissionsModel.onboardingDoneKey

        let garage = Garage(store: store, secrets: services.secretStore)
        if let qr = BikeQR.parse(bikeQR) {
            let bike = garage.save(qr)
            garage.select(bike.id)
        }
        SettingsStore(store: store).update(forBike: nil) { $0.autoConnect = false }

        let places = PlacesStore(store: store)
        places.setHome(Place(name: "Home", lat: 4.65120, lon: -74.08360), subtitle: "Teusaquillo, Bogotá")
        let favorites = [
            Place(name: "Parque Simón Bolívar", lat: 4.65845, lon: -74.09380, category: "park", subtitle: "Bogotá"),
            Place(name: "Monserrate", lat: 4.60574, lon: -74.05622, category: "viewpoint", subtitle: "Cerros Orientales"),
            Place(name: "Mirador La Calera", lat: 4.72077, lon: -73.96734, category: "viewpoint", subtitle: "La Calera"),
            Place(name: "Autódromo de Tocancipá", lat: 4.95717, lon: -73.93664, category: "racetrack", subtitle: "Tocancipá"),
        ]
        for place in favorites { places.addFavorite(place) }
        places.pushHistory(Place(name: "Café San Alberto", lat: 4.66870, lon: -74.05440, category: "cafe", subtitle: "Zona G"))
        places.pushHistory(favorites[1])

        let trips = TripStore(directory: services.files.tripsDirectory)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let plans: [(daysAgo: Int, hour: Int, minute: Int, laps: Double, speed: Double)] = [
            (1, 17, 32, 2.0, 12.0),
            (3, 8, 10, 1.0, 10.5),
            (9, 15, 45, 3.5, 13.0),
        ]
        for (index, plan) in plans.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: -plan.daysAgo, to: today),
                  let start = calendar.date(bySettingHour: plan.hour, minute: plan.minute, second: 0, of: day) else { continue }
            let trip = makeTrip(start: start, laps: plan.laps, baseSpeed: plan.speed, phase: Double(index))
            do {
                try trips.save(trip)
            } catch {
                Log.w("APP", "demo seed: trip not saved: \(error)")
            }
        }
        Log.i("APP", "demo seed: bike, \(plans.count) trips, home + \(favorites.count) favourites")
    }

    /// A ride of `laps` loops of the demo route, one fix every 2 s at a gently varying speed (m/s).
    static func makeTrip(start: Date, laps: Double, baseSpeed: Double, phase: Double) -> Trip {
        let route = DemoRoutePlayer.defaultRoute
        var cumulative: [Double] = [0]
        for i in 1 ..< route.count {
            cumulative.append(cumulative[i - 1] + distance(route[i - 1], route[i]))
        }
        let loop = cumulative.last ?? 1
        let total = loop * laps
        let startMs = Int64((start.timeIntervalSince1970 * 1000).rounded())
        var points: [TripPoint] = []
        var travelled = 0.0
        var t = startMs
        var maxSpeed: Float = 0
        var step = 0
        while travelled < total {
            let speed = max(3, baseSpeed + 3 * sin(Double(step) / 9 + phase) + 1.5 * sin(Double(step) / 2.3))
            let p = point(at: travelled.truncatingRemainder(dividingBy: loop), route: route, cumulative: cumulative)
            points.append(TripPoint(lat: p.lat, lon: p.lon, timeMs: t, speedMs: Float(speed)))
            maxSpeed = max(maxSpeed, Float(speed))
            travelled += speed * 2
            t += 2000
            step += 1
        }
        let moving = Int64(points.count) * 2000
        return Trip(id: String(startMs), start: startMs, end: t + 90_000, distanceMeters: total.rounded(),
                    movingTimeMs: moving, maxSpeedMs: maxSpeed, points: points)
    }

    private static func point(at d: Double, route: [GeoPoint], cumulative: [Double]) -> GeoPoint {
        var i = 1
        while i < cumulative.count - 1, cumulative[i] < d { i += 1 }
        let a = route[i - 1]
        let b = route[i]
        let seg = cumulative[i] - cumulative[i - 1]
        let f = seg > 0 ? min(1, max(0, (d - cumulative[i - 1]) / seg)) : 0
        return GeoPoint(lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f)
    }

    private static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6_371_000.0
        let p1 = a.lat * .pi / 180
        let p2 = b.lat * .pi / 180
        let dp = (b.lat - a.lat) * .pi / 180
        let dl = (b.lon - a.lon) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
