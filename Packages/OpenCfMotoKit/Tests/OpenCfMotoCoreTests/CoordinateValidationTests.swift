// SPDX-License-Identifier: AGPL-3.0-or-later
// Review SEC-1: NaN, infinite and out-of-range coordinates from a crafted GPX file, imported map
// data or a service response never get past the parsers (they used to reach Int(...) conversions in
// the tile corridor prefetch and trap), and a crafted polyline never overflows.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class CoordinateValidationTests: XCTestCase {
    func testValidator() {
        XCTAssertTrue(GeoMath.isValidCoordinate(lat: 4.65, lon: -74.05))
        XCTAssertTrue(GeoMath.isValidCoordinate(lat: -90, lon: 180))
        for (lat, lon) in [(Double.nan, 0.0), (0, .nan), (.infinity, 0), (0, -.infinity), (90.0001, 0), (0, 180.0001),
                           (0, 1e300), (1e20, 0), (-200, 10)] {
            XCTAssertFalse(GeoMath.isValidCoordinate(lat: lat, lon: lon), "\(lat),\(lon)")
        }
    }

    func testGpxDropsUnusablePoints() throws {
        let gpx = """
        <?xml version="1.0"?><gpx version="1.1"><trk><name>Evil</name><trkseg>
        <trkpt lat="45.0" lon="1.0"><ele>NaN</ele></trkpt>
        <trkpt lat="45.1" lon="1e300"/>
        <trkpt lat="NaN" lon="1.2"/>
        <trkpt lat="inf" lon="1.3"/>
        <trkpt lat="45.2" lon="1e20"/>
        <trkpt lat="200" lon="1.4"/>
        <trkpt lat="45.3" lon="1.5"><ele>12</ele></trkpt>
        </trkseg></trk><wpt lat="-inf" lon="0"/></gpx>
        """
        let track = GpxParser.parse(gpx)
        XCTAssertEqual(track.points.map(\.lat), [45.0, 45.3])
        XCTAssertNil(track.points[0].ele) // NaN elevation dropped
        XCTAssertEqual(track.points[1].ele, 12)
        XCTAssertTrue(track.waypoints.isEmpty)
        let allBad = #"<gpx><trk><trkseg><trkpt lat="nan" lon="1"/><trkpt lat="1" lon="inf"/></trkseg></trk></gpx>"#
        XCTAssertThrowsError(try GpxParser.importTrack(Data(allBad.utf8), fileName: "bad.gpx")) {
            XCTAssertEqual($0 as? GpxParser.ImportError, .empty)
        }
    }

    func testImportedAndPersistedPlacesNeedValidCoordinates() {
        let list = #"[{"name":"ok","lat":4.65,"lon":-74.05},{"name":"far","lat":45.1,"lon":1e300},"# +
            #"{"name":"str","lat":"NaN","lon":"1"},{"name":"big","lat":91,"lon":0}]"#
        XCTAssertEqual(PlacesStore.decodeList(list).map(\.name), ["ok"])

        let store = PlacesStore(store: InMemoryKeyValueStore())
        let map = #"{"format":"opencfmoto.map","version":1,"favorites":[{"name":"Fav","lat":45.1,"lon":1e300},"# +
            #"{"name":"Good","lat":4.6,"lon":-74.1}],"home":{"name":"Home","lat":1e300,"lon":0}}"#
        let result = MapDataBackup.importJSON(map, into: store, preferences: MapPreferences())
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(store.favorites().map(\.name), ["Good"])
        XCTAssertNil(store.home())
        // A saved handlebar slot "lat,lon".
        XCTAssertNil(SavedPlaceSlots.parseCoordinate("nan,1"))
        XCTAssertNil(SavedPlaceSlots.parseCoordinate("45,1e300"))
        XCTAssertEqual(SavedPlaceSlots.parseCoordinate(" 4.65 , -74.05 "), GeoPoint(lat: 4.65, lon: -74.05))
    }

    func testSearchAndPOIResultsWithBadCoordinatesAreSkipped() throws {
        let photon = #"{"features":[{"geometry":{"coordinates":[1e300,45]},"properties":{"name":"Bad"}},"# +
            #"{"geometry":{"coordinates":[26.1,44.4]},"properties":{"name":"Good"}}]}"#
        XCTAssertEqual(try PlaceSearch.parsePhoton(Data(photon.utf8)).map(\.place.name), ["Good"])
        let nominatim = #"[{"lat":"NaN","lon":"26","name":"Bad"},{"lat":"44.4","lon":"26.1","name":"Good"}]"#
        XCTAssertEqual(try PlaceSearch.parseNominatim(Data(nominatim.utf8)).map(\.place.name), ["Good"])
        let overpass = try NavJSON.parse(Data((#"{"elements":[{"lat":91,"lon":0,"tags":{"name":"Bad"}},"# +
            #"{"center":{"lat":44.4,"lon":1e300},"tags":{"name":"Bad2"}},{"lat":44.4,"lon":26.1,"tags":{"name":"Good"}}]}"#).utf8))
        XCTAssertEqual(OverpassClient.parseNearby(overpass, value: "fuel", lat: 44.4, lon: 26.1, maxResults: 10).map(\.name), ["Good"])
    }

    func testRouterGeometryWithBadCoordinatesIsRejected() throws {
        let osrm = try NavJSON.parse(Data(#"{"geometry":{"coordinates":[[26.1,44.4],[1e300,44.5]]},"distance":10}"#.utf8))
        XCTAssertNil(OsrmRouter.parseRoute(osrm, label: "x"))
        let ok = try NavJSON.parse(Data(#"{"geometry":{"coordinates":[[26.1,44.4],[26.2,44.5]]},"distance":10}"#.utf8))
        XCTAssertEqual(OsrmRouter.parseRoute(ok, label: "x")?.points.count, 2)
        let ors = try NavJSON.parse(Data(#"{"geometry":{"coordinates":[[26.1,44.4],[26.2,"NaN"]]},"properties":{}}"#.utf8))
        XCTAssertNil(OrsRouter.parseFeature(ors, label: "x"))
    }

    func testPolylineDecodingNeverTrapsAndValhallaRejectsImpossibleShapes() throws {
        // Deltas near 2^60 overflow an Int accumulator after a few points: decoding stops instead.
        let huge = String(repeating: "~~~~~~~~~~~?", count: 40)
        XCTAssertLessThan(PolylineCodec.decode(huge, precision: 6).count, 40)
        XCTAssertEqual(PolylineCodec.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 5).count, 3) // Google's vector
        // A Valhalla leg whose shape decodes to impossible coordinates rejects the route.
        let bad = PolylineCodec.encode([GeoPoint(lat: 44.4, lon: 26.1), GeoPoint(lat: 44.5, lon: 26.2)], precision: 5)
        let good = PolylineCodec.encode([GeoPoint(lat: 44.4, lon: 26.1), GeoPoint(lat: 44.5, lon: 26.2)], precision: 6)
        func trip(_ shape: String) throws -> NavJSON {
            let escaped = shape.replacingOccurrences(of: "\\", with: "\\\\")
            return try NavJSON.parse(Data(#"{"legs":[{"shape":"\#(escaped)","summary":{"length":1,"time":60},"maneuvers":[]}]}"#.utf8))
        }
        // Precision-5 data read at precision 6 is 10× off… in the other direction it is impossible.
        let tenTimes = PolylineCodec.encode([GeoPoint(lat: 444.0, lon: 26.1), GeoPoint(lat: 445.0, lon: 26.2)], precision: 6)
        XCTAssertNil(ValhallaRouter.parseTrip(try trip(tenTimes), label: "x"))
        XCTAssertNotNil(ValhallaRouter.parseTrip(try trip(good), label: "x"))
        XCTAssertNotNil(ValhallaRouter.parseTrip(try trip(bad), label: "x")) // 10× smaller but still valid
    }
}
