// SPDX-License-Identifier: AGPL-3.0-or-later
// Scripted dash models shared by the controller tests and the snapshot scenes.
import XCTest
@testable import OpenCfMotoCore

enum DashFixtures {
    static let land = DashSize(width: 800, height: 384)
    static let port = DashSize(width: 800, height: 944)
    static let wide = DashSize(width: 1280, height: 576)

    /// Rider near Câmpina, Prahova (the demo footage area).
    static let rider = GeoPoint(lat: 45.1270, lon: 25.7340)
    static let campina = Place(name: "Câmpina", lat: 45.1300, lon: 25.7400, category: "city", subtitle: "Prahova, România")
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-26 14:05 UTC
    static let afternoon = Date(timeIntervalSince1970: 1_792_972_800 + 14 * 3600 + 5 * 60)

    static func fix(_ p: GeoPoint = rider, kmh: Double = 42, course: Double? = 20) -> LocationFix {
        LocationFix(lat: p.lat, lon: p.lon, speedMps: kmh / 3.6, courseDeg: course, accuracyM: 5, altitudeM: 412, timeMs: 1_792_972_800_000)
    }

    /// A smooth synthetic road: north from `start`, then bending east.
    static func road(from start: GeoPoint = rider, northM: Double = 900, eastM: Double = 1400, n: Int = 60) -> [TrackPoint] {
        var pts: [TrackPoint] = []
        let mLat = 111_320.0, mLon = 111_320.0 * cos(start.lat * .pi / 180)
        for i in 0 ..< n {
            let t = Double(i) / Double(n - 1)
            // quarter-circle-ish bend
            let a = t * .pi / 2
            let dy = northM * sin(a) + 120 * sin(t * 9)
            let dx = eastM * (1 - cos(a)) + 60 * sin(t * 5)
            pts.append(TrackPoint(lat: start.lat + dy / mLat, lon: start.lon + dx / mLon))
        }
        return pts
    }

    static func alternativeRoad(from start: GeoPoint = rider, to end: GeoPoint) -> [TrackPoint] {
        var pts: [TrackPoint] = []
        let n = 50
        for i in 0 ..< n {
            let t = Double(i) / Double(n - 1)
            let lat = start.lat + (end.lat - start.lat) * t - 0.004 * sin(t * .pi)
            let lon = start.lon + (end.lon - start.lon) * t + 0.006 * sin(t * .pi)
            pts.append(TrackPoint(lat: lat, lon: lon))
        }
        return pts
    }

    static func base(_ canvas: DashSize = land) -> DashModel {
        var m = DashModel(canvas: canvas)
        m.fix = fix()
        m.compassHeadingDeg = 18
        m.date = afternoon
        m.timeZone = utc
        m.nav = NavSnapshot(mode: .freeRide, puck: rider, puckBearingDeg: 20,
                            speedLimit: SpeedLimit(kmh: 50, label: "50"),
                            pins: [Place(name: "Fav", lat: 45.1290, lon: 25.7290, category: "", subtitle: "")])
        m.places = DashPlaces(home: Place(name: "Home", lat: 45.12, lon: 25.72, category: "home", subtitle: "Home"),
                              parked: nil,
                              favorites: [Place(name: "Cafe Central", lat: 45.125, lon: 25.731, category: "cafe", subtitle: "Bulevardul Carol I")],
                              markers: [],
                              history: [campina, Place(name: "Free ride", lat: 0, lon: 0, category: "mode", subtitle: "Started free ride")])
        return m
    }

    static func freeRide(_ canvas: DashSize = land) -> DashModel { base(canvas) }

    static func preview(_ canvas: DashSize = land) -> DashModel {
        var m = base(canvas)
        let end = campina.point
        let fast = Route(points: road(from: rider, northM: 330, eastM: 470), distanceM: 10_200, durationSec: 840, label: "Fast")
        let fun = Route(points: alternativeRoad(from: rider, to: end), distanceM: 25_400, durationSec: 1200, label: "Fun")
        m.nav.preview = RoutePreview(place: campina, routes: [fast, fun], selectedIndex: 0,
                                     meta: "10.2 km · 14:14 · city · Prahova, România",
                                     chipLabels: ["Fast · 14:14 · 10.2 km", "Fun · 14:20 · 25.4 km"])
        return m
    }

    static func navigating(_ canvas: DashSize = land, offRoute: Bool = false) -> DashModel {
        var m = base(canvas)
        let pts = road()
        m.nav.mode = .navTo(campina)
        m.nav.destination = campina
        m.nav.route = Route(points: pts, distanceM: 2_400, durationSec: 300, label: "Fast")
        m.nav.progress = RouteProgress(nearestIndex: 6, doneM: 230, remainM: 12_345, offTrackM: offRoute ? 95 : 3,
                                       snapLat: pts[6].lat, snapLon: pts[6].lon, trackBearingDeg: 15, etaSec: 1_080)
        m.nav.puck = offRoute ? GeoPoint(lat: pts[6].lat, lon: pts[6].lon - 0.0012) : pts[6].point
        m.fix = fix(m.nav.puck!, kmh: 47, course: 15)
        if offRoute {
            m.nav.cue = HudCue(dir: .left, distanceText: "95 m", text: "Turn left")
            m.nav.metrics = HudMetrics(time: "18m", arrive: "14:23", left: "12.3 km", alt: "412", altUnit: "m",
                                       status: "Route · 12.3 km · OFF 95 m", statusWarning: true)
        } else {
            m.nav.cue = HudCue(dir: .right, distanceText: "350 m", text: "Strada Republicii", lanes: "↑ ↑ →")
            m.nav.metrics = HudMetrics(time: "18m", arrive: "14:23", left: "12.3 km", alt: "412", altUnit: "m",
                                       status: "Route · 12.3 km · avg 41")
        }
        m.nav.speedLimit = SpeedLimit(kmh: 50, label: "50")
        return m
    }

    static func arrival(_ canvas: DashSize = land) -> DashModel {
        var m = base(canvas)
        m.nav.arrival = ArrivalCard(title: "Arrived · Câmpina", meta: "Mark parking, find a spot, or continue free ride")
        return m
    }

    static func withSearchResults(_ m0: DashModel) -> DashModel {
        var m = m0
        m.search = DashSearchState(query: "fuel", results: [
            Place(name: "OMV Câmpina", lat: 45.131, lon: 25.737, category: "Fuel", subtitle: "350 m · OMV · Bulevardul Carol I 120"),
            Place(name: "Petrom", lat: 45.122, lon: 25.741, category: "Fuel", subtitle: "1.2 km · Petrom"),
            Place(name: "Rompetrol", lat: 45.140, lon: 25.720, category: "Fuel", subtitle: "2.4 km"),
        ], status: "3 fuel nearby")
        return m
    }

    // MARK: Apple Music (iOS addition)

    /// The time the music fixtures are sampled at (and drawn for): "2:13" played, "-3:51" left.
    static let musicNow: TimeInterval = 1_000

    /// A fictional song: 6:04 long, 2:13 in at `musicNow`.
    static func song(_ state: DashNowPlaying.State = .playing, title: String = "Ruta del Sol (Remastered 2012)",
                     artist: String = "Los Pistones", album: String = "Ruta Sessions", artworkId: String? = "music.art.p1f",
                     duration: TimeInterval = 364) -> DashNowPlaying {
        DashNowPlaying(title: title, artist: artist, album: album, artworkId: artworkId, state: state, duration: duration,
                       position: 133, positionAt: musicNow, rate: 1)
    }

    static func withMusic(_ m0: DashModel, _ song: DashNowPlaying = song()) -> DashModel {
        var m = m0
        m.music = song
        return m
    }

    /// The nav cue of `navigating()`, for layouts that reserve the nav card.
    static let navCue = HudCue(dir: .right, distanceText: "350 m", text: "Strada Republicii", lanes: "↑ ↑ →")
    /// A tall nav card (2-line road + lanes): 601 px wide on 800-wide canvases.
    static let longNavCue = HudCue(dir: .sharpLeft, distanceText: "1.2 km",
                                   text: "Autopista Norte con Calle 170, salida hacia La Calera y Sopó", lanes: "↖ ↑ ↑ ↑")
    static let longSongTitle = "Concierto para Moto y Orquesta en Re Menor, Op. 73: II. Adagio molto espressivo"

    /// `navigating()` with the next turn (index `index`) `distance` m ahead.
    static func navigating(turn index: Int, at distance: Double, _ canvas: DashSize = land) -> DashModel {
        var m = navigating(canvas)
        m.nav.progress?.upcomingTurn = TurnCue(index: index, distanceAlongM: 1_000 + Double(index) * 500,
                                               distanceFromRiderM: distance, dir: .right, speak: "", shortLabel: "")
        return m
    }
}

final class DashFixturesTests: XCTestCase {
    func testFixturesAreConsistent() {
        XCTAssertTrue(DashFixtures.freeRide().nav.mode == .freeRide)
        XCTAssertTrue(DashFixtures.preview().inPreview)
        XCTAssertTrue(DashFixtures.navigating().navigating)
        XCTAssertTrue(DashFixtures.arrival().showsArrival)
        XCTAssertEqual(DashFixtures.road().count, 60)
        XCTAssertEqual(DashFixtures.preview().nav.preview?.routes.count, 2)
        XCTAssertEqual(DashFixtures.navigating().nav.cue, DashFixtures.navCue)
        let song = DashFixtures.song()
        XCTAssertEqual(DashMusicFormat.time(song.elapsedSeconds(at: DashFixtures.musicNow)), "2:13")
        XCTAssertEqual(DashMusicFormat.remaining(song, at: DashFixtures.musicNow), "-3:51")
        XCTAssertEqual(DashFixtures.navigating(turn: 4, at: 350).nav.progress?.upcomingTurn?.index, 4)
    }
}
