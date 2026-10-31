// SPDX-License-Identifier: AGPL-3.0-or-later
// NavigationModel: snapshot / effect mirroring, toast auto-clear, debounced + cancellable search
// (Photon), POI chips, places lists, GPX import, "type on phone" (navigation-dash.md §7, §11–§12,
// app-features.md §7.5.7).

import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoAppModel

final class NavigationModelTests: XCTestCase {

    static let photonJSON = """
    {"type":"FeatureCollection","features":[
     {"type":"Feature","geometry":{"type":"Point","coordinates":[25.7372,45.1259]},
      "properties":{"osm_key":"place","osm_value":"city","name":"Câmpina","county":"Prahova","country":"România","type":"city"}},
     {"type":"Feature","geometry":{"type":"Point","coordinates":[26.0901,44.4392]},
      "properties":{"osm_key":"highway","osm_value":"residential","name":"Strada Câmpina","city":"București","country":"România","type":"street"}}
    ]}
    """

    static let overpassFuelJSON = """
    {"elements":[
     {"type":"node","id":1,"lat":44.4300,"lon":26.1030,"tags":{"amenity":"fuel","name":"Petrom","brand":"Petrom"}},
     {"type":"node","id":2,"lat":44.4400,"lon":26.1100,"tags":{"amenity":"fuel","name":"OMV"}}
    ]}
    """

    static let gpxVector = """
    <?xml version="1.0"?>
    <gpx version="1.1">
      <trk><name>Test Ride</name>
        <trkseg>
          <trkpt lat="45.0" lon="25.0"><ele>100</ele></trkpt>
          <trkpt lat="45.1" lon="25.1"/>
        </trkseg>
      </trk>
      <wpt lat="45.05" lon="25.05"><name>Peak</name></wpt>
    </gpx>
    """

    static let bucharestFix = LocationFix(lat: 44.4268, lon: 26.1025, speedMps: 0, accuracyM: 5, timeMs: 1_793_461_327_000)

    static func ok(_ json: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["content-type": "application/json"], body: Data(json.utf8))
    }

    @MainActor
    private func navStrings(_ env: LDTestEnv) -> NavStrings {
        NavStrings(language: env.core.language, decimalSeparator: env.core.language.conventionalDecimalSeparator)
    }

    // MARK: Snapshot / effects

    @MainActor
    func testSnapshotMirrorsTheSessionAndActionsForward() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let nav = NavigationModel(core: env.core)
        XCTAssertEqual(nav.snapshot.mode, .freeRide)
        XCTAssertEqual(nav.poiChips, PlaceSearch.poiChips)

        let place = Place(name: "Plaza Bolívar", lat: 4.5981, lon: -74.0760, category: "square")
        nav.preview(place)
        await LDTest.expect { nav.snapshot.preview?.place == place }
        nav.cancelPreview()
        await LDTest.expect { nav.snapshot.preview == nil }

        nav.navigate(to: place)
        await LDTest.expect { nav.snapshot.mode == .navTo(place) }
        XCTAssertEqual(nav.snapshot.destination, place)
        // Navigating pushes a history row → `.placesChanged` → lists refresh.
        await LDTest.expect { nav.history.contains { $0.isSameLocation(as: place) } }

        nav.endNavigation()
        await LDTest.expect { nav.snapshot.mode == .freeRide }

        // The dash and the phone share the ONE session: a change made elsewhere shows up here.
        env.core.navigation.navigate(to: place)
        await LDTest.expect { nav.snapshot.mode == .navTo(place) }
        nav.startFreeRide()
        await LDTest.expect { nav.snapshot.mode == .freeRide }
        await LDTest.expect { nav.history.contains { $0.category == "mode" } }   // "Started free ride"
        XCTAssertEqual(nav.snapshot, env.core.navigation.snapshot)
    }

    @MainActor
    func testToastFromNavEffectsAutoClears() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let nav = NavigationModel(core: env.core)
        nav.toastDuration = 0.5
        nav.endNavigation()   // already in free ride → status toast
        let expected = navStrings(env).phrase(.alreadyFreeRide)
        await LDTest.expect("toast: \(String(describing: nav.toast))") { nav.toast == expected }
        await LDTest.expect(timeout: 3) { nav.toast == nil }

        nav.goHome()          // no home yet
        await LDTest.expect { nav.toast == self.navStrings(env).phrase(.noHomeSet) }
        // A newer toast restarts the timer.
        nav.recalc()          // no GPS
        await LDTest.expect { nav.toast == self.navStrings(env).phrase(.noGps) }
        await LDTest.expect(timeout: 3) { nav.toast == nil }
    }

    // MARK: Search

    @MainActor
    func testDebouncedSearchUsesPhotonAndSkipsStaleQueries() async throws {
        let http = PreviewHTTPClient()
        http.respond(toPrefix: "https://photon.komoot.io/api/", with: Self.ok(Self.photonJSON))
        let env = LDTestEnv(http: http)
        env.cleanUp(after: self)
        env.core.navigation.updateLocation(Self.bucharestFix)
        let nav = NavigationModel(core: env.core)
        nav.searchDebounce = 0.08
        func photonURLs() -> [String] {
            http.requests.map(\.url.absoluteString).filter { $0.hasPrefix("https://photon.komoot.io/") }
        }

        nav.query = "C"                  // < 2 characters: no request
        await LDTest.settle(0.2)
        XCTAssertTrue(photonURLs().isEmpty)
        XCTAssertTrue(nav.results.isEmpty)
        XCTAssertFalse(nav.isSearching)

        nav.query = "Câ"                 // superseded within the debounce window
        nav.query = "Câmp"
        nav.query = "Câmpina"
        XCTAssertFalse(nav.isSearching)  // nothing in flight during the debounce
        await LDTest.expect { !nav.results.isEmpty }
        XCTAssertFalse(nav.isSearching)
        XCTAssertNil(nav.lastError)
        XCTAssertEqual(nav.results.map(\.name), ["Câmpina", "Strada Câmpina"])
        let urls = photonURLs()
        XCTAssertEqual(urls.count, 2, "\(urls)")   // general + settlements, only for the last query
        XCTAssertTrue(urls.allSatisfy { $0.contains("q=C%C3%A2mpina&") }, "\(urls)")

        nav.query = ""                   // empty query clears the results
        XCTAssertTrue(nav.results.isEmpty)
        XCTAssertFalse(nav.isSearching)
    }

    @MainActor
    func testStaleResultsAreDroppedWhenTheQueryChanges() async throws {
        let slow = LDSlowHTTPClient(delay: 0.3) { _ in NavigationModelTests.ok(NavigationModelTests.photonJSON) }
        let env = LDTestEnv(http: slow)
        env.cleanUp(after: self)
        env.core.navigation.updateLocation(Self.bucharestFix)
        let nav = NavigationModel(core: env.core)
        nav.searchDebounce = 0.02

        nav.query = "Câmpina"
        await LDTest.expect { nav.isSearching }
        nav.query = "x"                  // cancels the request in flight
        XCTAssertFalse(nav.isSearching)
        XCTAssertTrue(nav.results.isEmpty)
        await LDTest.settle(1.0)
        XCTAssertTrue(nav.results.isEmpty, "a cancelled search must not publish results")
        XCTAssertFalse(nav.isSearching)

        // Go (keyboard) searches immediately, without the debounce.
        nav.searchDebounce = 30
        nav.query = "Câmpina"
        nav.searchNow()
        await LDTest.expect(timeout: 5) { !nav.results.isEmpty }
        nav.clearSearch()
        XCTAssertEqual(nav.query, "")
        XCTAssertTrue(nav.results.isEmpty)
        XCTAssertFalse(nav.isSearching)
    }

    @MainActor
    func testSearchErrorsAndEmptyGo() async throws {
        let env = LDTestEnv()   // every request answers 503
        env.cleanUp(after: self)
        env.core.navigation.updateLocation(Self.bucharestFix)
        let nav = NavigationModel(core: env.core)
        nav.searchDebounce = 30

        nav.searchNow()          // empty field
        XCTAssertEqual(nav.toast, env.strings.typePlace)

        nav.query = "Câmpina"
        nav.searchNow()
        let expected = env.strings.serviceError(NavServiceError.forStatus(503), fallback: env.strings.searchFailed)
        await LDTest.expect(timeout: 6) { nav.lastError != nil }
        XCTAssertEqual(nav.lastError, expected)
        XCTAssertFalse(nav.isSearching)
        XCTAssertTrue(nav.results.isEmpty)
        nav.clearSearch()
        XCTAssertNil(nav.lastError)
    }

    @MainActor
    func testPoiChips() async throws {
        let http = PreviewHTTPClient()
        http.respond(toPrefix: OverpassClient.endpoint.absoluteString, with: Self.ok(Self.overpassFuelJSON))
        let env = LDTestEnv(http: http)
        env.cleanUp(after: self)
        let nav = NavigationModel(core: env.core)
        let fuel = try XCTUnwrap(nav.poiChips.first { $0.label == "Fuel" })

        nav.searchNearby(fuel)   // no GPS yet
        await LDTest.expect { nav.lastError != nil }
        XCTAssertEqual(nav.lastError, navStrings(env).phrase(.needGpsForPoi))

        env.core.navigation.updateLocation(Self.bucharestFix)
        nav.searchNearby(fuel)
        await LDTest.expect(timeout: 6) { !nav.results.isEmpty }
        XCTAssertNil(nav.lastError)
        XCTAssertEqual(nav.results.map(\.name), ["Petrom", "OMV"])   // nearest first
        XCTAssertTrue(nav.results.allSatisfy { $0.category == "Fuel" })
        let label = navStrings(env).poiChipLabel("Fuel")
        XCTAssertEqual(nav.toast, navStrings(env).phrase(.foundNearby(2, label)))
    }

    // MARK: Places

    @MainActor
    func testPlacesListsFollowEveryWriter() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let nav = NavigationModel(core: env.core)
        let cafe = Place(name: "Café", lat: 4.61, lon: -74.08, category: "cafe")
        let pin = Place(name: "Pin", lat: 4.62, lon: -74.09, category: "pin")
        let house = Place(name: "", lat: 4.65, lon: -74.05)

        nav.saveFavorite(cafe)
        XCTAssertEqual(nav.favorites, [cafe])
        XCTAssertEqual(nav.toast, navStrings(env).phrase(.savedToFavorites("Café")))
        nav.addMarker(pin)
        XCTAssertEqual(nav.markers, [pin])
        nav.setHome(house)
        XCTAssertEqual(nav.home?.category, "home")
        XCTAssertEqual(nav.home?.name, navStrings(env).homeName)
        XCTAssertTrue(nav.favorites.contains { $0.isSameLocation(as: house) })
        nav.delete(cafe)
        XCTAssertFalse(nav.favorites.contains { $0.isSameLocation(as: cafe) })

        // Direct PlacesStore writers (e.g. the map-data import) reach the lists too.
        let other = Place(name: "Elsewhere", lat: 5.0, lon: -75.0)
        env.core.places.addFavorite(other)
        await LDTest.expect { nav.favorites.contains(other) }
        env.core.places.replaceAll(favorites: [], markers: [], history: [], parked: nil, home: nil)
        await LDTest.expect { nav.favorites.isEmpty && nav.markers.isEmpty && nav.home == nil }

        // Session-originated changes (dash "Park here") arrive through `.placesChanged`.
        env.core.navigation.updateLocation(Self.bucharestFix)
        nav.parkHere()
        await LDTest.expect { nav.parked != nil }
        XCTAssertEqual(nav.parked?.category, "parking")
    }

    // MARK: GPX

    @MainActor
    func testGpxImport() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let nav = NavigationModel(core: env.core)

        nav.loadGpx(data: Data("<gpx version=\"1.1\"></gpx>".utf8), fileName: "empty.gpx")
        XCTAssertEqual(nav.lastError, env.strings.gpxEmpty)
        XCTAssertEqual(nav.snapshot.mode, .freeRide)

        nav.loadGpx(data: Data(Self.gpxVector.utf8), fileName: "ride.gpx")
        XCTAssertNil(nav.lastError)
        await LDTest.expect { nav.snapshot.mode == .gpx(name: "Test Ride") }
        await LDTest.expect { nav.history.contains { $0.category == "gpx" && $0.name == "Test Ride" } }

        // Big files are parsed off the main actor.
        nav.synchronousGpxLimit = 16
        nav.endNavigation()
        await LDTest.expect { nav.snapshot.mode == .freeRide }
        nav.loadGpx(data: Data(Self.gpxVector.replacingOccurrences(of: "Test Ride", with: "Async Ride").utf8),
                    fileName: "async.gpx")
        await LDTest.expect { nav.snapshot.mode == .gpx(name: "Async Ride") }
        nav.loadGpx(data: Data("<gpx version=\"1.1\"><trk></trk></gpx>".utf8), fileName: "bad.gpx")
        await LDTest.expect { nav.lastError == env.strings.gpxEmpty }
    }

    // MARK: Type on phone

    @MainActor
    func testTypeOnPhoneRequest() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let nav = NavigationModel(core: env.core)
        XCTAssertFalse(nav.typeOnPhoneRequested)
        nav.requestTypeOnPhone()
        XCTAssertTrue(nav.typeOnPhoneRequested)
        XCTAssertEqual(env.system.hapticCount, 1)
        XCTAssertEqual(nav.toast, env.strings.bikeSearchOpen)
        nav.acknowledgeTypeOnPhone()
        XCTAssertFalse(nav.typeOnPhoneRequested)
    }

    // MARK: Strings

    func testNavigationStringsEnglishAndSpanish() {
        let en = LogicData.Strings(.en)
        let es = LogicData.Strings(.es)
        XCTAssertEqual(en.typePlace, "Type a place to search on the map")
        XCTAssertEqual(es.typePlace, "Escribe un lugar para buscar en el mapa")
        XCTAssertEqual(en.bikeSearchOpen, "Bike search open \u{2014} type here. Results appear on the dash.")
        XCTAssertEqual(es.bikeSearchOpen, "Búsqueda de la moto abierta: escribe aquí. Los resultados aparecen en el tablero.")
        XCTAssertEqual(en.gpxEmpty, "GPX has no track points or waypoints")
        XCTAssertNotEqual(es.gpxEmpty, en.gpxEmpty)
        XCTAssertEqual(en.serviceError(NavServiceError.forStatus(429), fallback: en.searchFailed),
                       "Map service is busy (rate limited) \u{2014} try again shortly")
        XCTAssertEqual(es.serviceError(NavServiceError.forStatus(503), fallback: es.searchFailed),
                       "Servicio de mapas no disponible temporalmente (HTTP 503)")
        XCTAssertEqual(es.serviceError(NavServiceError.forStatus(404), fallback: es.searchFailed),
                       "La petición falló (HTTP 404)")
        XCTAssertEqual(es.serviceError(HTTPClientError.noNetwork, fallback: es.searchFailed), "Sin conexión a internet")
        XCTAssertEqual(es.serviceError(NavServiceError.service("Se necesita GPS"), fallback: es.searchFailed), "Se necesita GPS")
        XCTAssertEqual(en.serviceError(TimeoutError(seconds: 5), fallback: en.searchFailed),
                       "The map service did not answer in time")
    }
}
