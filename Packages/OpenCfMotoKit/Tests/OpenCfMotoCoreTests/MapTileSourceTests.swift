// SPDX-License-Identifier: AGPL-3.0-or-later
// The tile source rules (navigation-dash.md §10.4): no route-corridor prefetch from the OpenStreetMap
// Foundation servers (OSMF Tile Usage Policy), a "© OpenStreetMap" credit on the dash map for their
// tiles, nothing for a tile server the rider configured.
import XCTest
@testable import OpenCfMotoCore

final class MapTileSourceTests: XCTestCase {
    static let defaultTemplate = BikeSettings().tileURLTemplate

    func testTheDefaultTemplateIsTheOSMFServer() {
        XCTAssertEqual(Self.defaultTemplate, "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        XCTAssertEqual(MapTileSource.hosts(template: Self.defaultTemplate), ["tile.openstreetmap.org"])
        XCTAssertTrue(MapTileSource.isOpenStreetMapFoundation(template: Self.defaultTemplate))
        XCTAssertFalse(MapTileSource.allowsCorridorPrefetch(template: Self.defaultTemplate), "the default never prefetches")
        XCTAssertEqual(MapTileSource.attribution(template: Self.defaultTemplate), "© OpenStreetMap")
        XCTAssertEqual(MapTileSource.openStreetMapCredit, "© OpenStreetMap")
    }

    /// tile.openstreetmap.org, the legacy a./b./c.tile aliases and any other *.openstreetmap.org (or the
    /// Foundation's osm.org) host, however the rider spells it.
    func testEveryOSMFHostIsRecognised() {
        let osmf = [
            "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
            "http://tile.openstreetmap.org/{z}/{x}/{y}.png",
            "https://a.tile.openstreetmap.org/{z}/{x}/{y}.png",
            "https://b.tile.openstreetmap.org/{z}/{x}/{y}.png",
            "https://c.tile.openstreetmap.org/{z}/{x}/{y}.png",
            "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
            "https://TILE.OpenStreetMap.ORG/{z}/{x}/{y}.png",
            "https://tile.openstreetmap.org./{z}/{x}/{y}.png",
            "https://tile.openstreetmap.org:443/{z}/{x}/{y}.png",
            "https://user:secret@tile.openstreetmap.org/{z}/{x}/{y}.png",
            "  https://tile.openstreetmap.org/{z}/{x}/{y}.png\n",
            "https://tile.openstreetmap.org/{z}/{x}/{y}.png?layer=mapnik",
            "https://openstreetmap.org/{z}/{x}/{y}.png",
            "https://tiles.openstreetmap.org/{z}/{x}/{y}.png",
            "https://tile.osm.org/{z}/{x}/{y}.png",
            "https://tile.openstreetmap%2Eorg/{z}/{x}/{y}.png",
            // RFC 3986 (Foundation): a backslash is no delimiter, the host follows the last "@"
            "https://example.com\\@tile.openstreetmap.org/{z}/{x}/{y}.png",
        ]
        for t in osmf {
            XCTAssertTrue(MapTileSource.isOpenStreetMapFoundation(template: t), t)
            XCTAssertFalse(MapTileSource.allowsCorridorPrefetch(template: t), "no prefetch from \(t)")
            XCTAssertEqual(MapTileSource.attribution(template: t), "© OpenStreetMap", t)
        }
        for h in ["tile.openstreetmap.org", "a.tile.openstreetmap.org", "openstreetmap.org", "Tile.OpenStreetMap.Org.",
                  "tile.openstreetmap.org:443", "osm.org", "tile.osm.org"] {
            XCTAssertTrue(MapTileSource.isOpenStreetMapFoundation(host: h), h)
        }
    }

    /// A tile server the rider configured: corridor prefetch allowed, no credit drawn.
    func testCustomServersPrefetchAndDrawNoLabel() {
        let custom = [
            "https://tiles.example.com/{z}/{x}/{y}.png",
            "https://tiles.example.com/v1/{z}/{y}/{x}@2x.jpg?key=abc",
            "https://tile.openstreetmap.de/{z}/{x}/{y}.png",            // FOSSGIS, not the OSMF
            "https://tile.openstreetmap.org.example.com/{z}/{x}/{y}.png", // look-alike
            "https://notopenstreetmap.org/{z}/{x}/{y}.png",
            "https://openstreetmaporg.example/{z}/{x}/{y}.png",
            "https://example.com/proxy?u=https://tile.openstreetmap.org/{z}/{x}/{y}.png",
            "https://tile.openstreetmap.org@tiles.example.com/{z}/{x}/{y}.png", // userinfo, the host is example.com
            "http://192.168.1.10:8080/{z}/{x}/{y}.png",
            "http://localhost:8080/tiles/{z}/{x}/{y}.png",
        ]
        for t in custom {
            XCTAssertFalse(MapTileSource.isOpenStreetMapFoundation(template: t), t)
            XCTAssertTrue(MapTileSource.allowsCorridorPrefetch(template: t), "prefetch allowed for \(t)")
            XCTAssertNil(MapTileSource.attribution(template: t), t)
        }
        XCTAssertEqual(MapTileSource.hosts(template: "https://user:pw@Tiles.Example.com:8443/{z}/{x}/{y}.png"), ["tiles.example.com"])
        XCTAssertEqual(MapTileSource.hosts(template: "http://[::1]:8080/{z}/{x}/{y}.png").first, "[::1]")
    }

    /// No readable host: never a prefetch (fail closed), no credit (no tile is ever downloaded either).
    func testUnreadableTemplatesFailClosed() {
        for t in ["", "   ", "garbage", "tile.openstreetmap.org/{z}/{x}/{y}.png", "https:///{z}/{x}/{y}.png", "://x/{z}",
                  "https://@/{z}/{x}/{y}.png"] {
            XCTAssertTrue(MapTileSource.hosts(template: t).isEmpty, "\(t): \(MapTileSource.hosts(template: t))")
            XCTAssertFalse(MapTileSource.allowsCorridorPrefetch(template: t), "no prefetch for \(t)")
            XCTAssertNil(MapTileSource.attribution(template: t), t)
        }
        for h in ["", ".", "openstreetmap.org.example.com", "notopenstreetmap.org", "osm.org.example"] {
            XCTAssertFalse(MapTileSource.isOpenStreetMapFoundation(host: h), h)
        }
    }
}
