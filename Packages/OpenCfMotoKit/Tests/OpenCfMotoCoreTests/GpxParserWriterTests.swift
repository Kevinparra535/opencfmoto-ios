// SPDX-License-Identifier: AGPL-3.0-or-later
// GPX parsing (XMLParser, document order) and writing (GPX 1.1).

import XCTest
@testable import OpenCfMotoCore

final class GpxParserWriterTests: XCTestCase {
    func testUpstreamParserVector() {
        let t = GpxParser.parse(NavFixtures.data("parser_vector.gpx"), fallbackName: "test")
        XCTAssertEqual(t.name, "Test Ride")
        XCTAssertEqual(t.points.count, 2)
        XCTAssertEqual(t.points[0].lat, 45.0, accuracy: 1e-6)
        XCTAssertEqual(t.points[0].ele, 100.0)
        XCTAssertNil(t.points[1].ele)
        XCTAssertEqual(t.waypoints.count, 1)
        XCTAssertEqual(t.waypoints[0].name, "Peak")
    }

    func testSampleTrackWithNamespacesCDATAAndEntities() {
        let t = GpxParser.parse(NavFixtures.data("sample_track.gpx"), fallbackName: "sample")
        XCTAssertEqual(t.name, "Transfăgărășan test") // trimmed <trk><name>, not the metadata name
        XCTAssertEqual(t.points.count, 61)
        XCTAssertEqual(t.points[0].ele, 500)
        XCTAssertEqual(t.points[30].lat, 45.03, accuracy: 1e-12)
        XCTAssertEqual(t.points[60].lon, 25.042, accuracy: 1e-12)
        XCTAssertEqual(t.waypoints.map(\.name), ["Peak", "Fuel & Food"])
        XCTAssertEqual(t.waypoints[0].ele, 580)
        XCTAssertNil(t.points[5].name)
    }

    func testRouteOnlyFileUsesRoutePointsAndRouteName() {
        let t = GpxParser.parse(NavFixtures.data("route_only.gpx"), fallbackName: "file")
        XCTAssertEqual(t.name, "Route Name")
        XCTAssertEqual(t.points.map(\.lat), [44.43, 44.44, 44.44])
        XCTAssertEqual(t.points[0].name, "Start")
        XCTAssertEqual(t.points[2].ele, 85.5)
        XCTAssertEqual(t.waypoints, [])
    }

    func testDocumentOrderCaseInsensitiveAndInvalidPointsSkipped() {
        let t = GpxParser.parse(NavFixtures.data("mixed_order.gpx"), fallbackName: "mixed")
        // Self-closing and long-form points keep document order (Android appends self-closing ones
        // after all long-form ones); upper-case TRKPT / prefixed gpx:trkpt are accepted.
        XCTAssertEqual(t.points.map(\.lat), [1, 2, 3, 6])
        XCTAssertEqual(t.points[1].ele, 20)
        XCTAssertEqual(t.points[3].name, "Six")
        XCTAssertEqual(t.name, "Ignored route") // no <trk><name> → first <rte><name>
    }

    func testFallbackNameAndMalformedXML() {
        let t = GpxParser.parse("<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"2\"/><trkpt lat=\"3\" lon=\"4\"></trkseg>", fallbackName: "broken")
        XCTAssertEqual(t.name, "broken")
        // Points read before the error are kept (libxml2 on Linux may also recover the unclosed one).
        XCTAssertEqual(t.points.first?.lat, 1)
        XCTAssertLessThanOrEqual(t.points.count, 2)
        XCTAssertEqual(GpxParser.parse(Data(), fallbackName: "x").points, [])
    }

    func testImportValidationAndSummary() throws {
        XCTAssertThrowsError(try GpxParser.importTrack(Data("<gpx></gpx>".utf8), fileName: "empty.gpx")) { e in
            XCTAssertEqual((e as? GpxParser.ImportError)?.description, "GPX has no track points or waypoints")
        }
        let t = try GpxParser.importTrack(NavFixtures.data("mixed_order.gpx"), fileName: "my ride.gpx")
        XCTAssertEqual(t.name, "Ignored route")
        let noName = try GpxParser.importTrack(Data(#"<gpx><wpt lat="1" lon="2"/></gpx>"#.utf8), fileName: "only wpt.gpx")
        XCTAssertEqual(noName.name, "only wpt")
        let sample = GpxParser.parse(NavFixtures.data("sample_track.gpx"))
        XCTAssertEqual(GpxParser.summaryLabel(sample), "Transfăgărășan test  ·  61 pts · 2 wpt · 6.6 km")
        XCTAssertEqual(GpxParser.historyPlace(sample), Place(name: "Transfăgărășan test", lat: 45, lon: 25, category: "gpx", subtitle: "GPX track"))
    }

    func testWriterRoundTripAndFormat() {
        let track = GpxTrack(name: "A & B <test>", points: [TrackPoint(lat: 45, lon: 25, ele: 100.25), TrackPoint(lat: 45.0123456789, lon: 25.01, name: "P\"1")],
                             waypoints: [TrackPoint(lat: 45.005, lon: 25.005, name: "Peak")])
        let xml = GpxWriter.write(track, time: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(xml, """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="OpenCfMoto" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>A &amp; B &lt;test&gt;</name>
            <time>2023-11-14T22:13:20Z</time>
          </metadata>
          <wpt lat="45.005000" lon="25.005000">
            <name>Peak</name>
          </wpt>
          <trk>
            <name>A &amp; B &lt;test&gt;</name>
            <trkseg>
              <trkpt lat="45.000000" lon="25.000000">
                <ele>100.3</ele>
              </trkpt>
              <trkpt lat="45.012346" lon="25.010000">
                <name>P&quot;1</name>
              </trkpt>
            </trkseg>
          </trk>
        </gpx>

        """)
        let back = GpxParser.parse(xml)
        XCTAssertEqual(back.name, "A & B <test>")
        XCTAssertEqual(back.points.count, 2)
        XCTAssertEqual(back.points[1].lat, 45.012346, accuracy: 1e-9)
        XCTAssertEqual(back.points[1].name, "P\"1")
        XCTAssertEqual(back.waypoints.map(\.name), ["Peak"])
        let rte = GpxWriter.write(route: Route(points: track.points, distanceM: 1, durationSec: 1), name: "R", asRoute: true)
        XCTAssertTrue(rte.contains("<rte>\n    <name>R</name>\n    <rtept lat=\"45.000000\""))
        XCTAssertEqual(GpxParser.parse(rte).points.count, 2)
        XCTAssertEqual(GpxWriter.suggestedFileName(for: "Ride: day/1"), "Ride_ day_1.gpx")
        XCTAssertEqual(GpxWriter.suggestedFileName(for: "  "), "route.gpx")
    }
}
