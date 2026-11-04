// SPDX-License-Identifier: AGPL-3.0-or-later
// The demo content is public places only: the demo "home" (`-demoSeed`) lies well inside the park the
// demo GPS loop circles — off its roads — and says that it is a demo.
import XCTest
@testable import OpenCfMotoAppModel
@testable import OpenCfMotoCore

final class DemoDataTests: XCTestCase {
    /// Local metres east / north of `origin` (equirectangular: fine over a few kilometres).
    private func metres(_ p: GeoPoint, from origin: GeoPoint) -> (x: Double, y: Double) {
        let k = 111_320.0
        return ((p.lon - origin.lon) * k * cos(origin.lat * .pi / 180), (p.lat - origin.lat) * k)
    }

    /// Ray casting on the closed loop.
    private func inside(_ p: GeoPoint, _ ring: [GeoPoint]) -> Bool {
        var result = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.lat > p.lat) != (b.lat > p.lat),
               p.lon < (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon {
                result.toggle()
            }
            j = i
        }
        return result
    }

    /// Shortest distance (m) from `p` to the polyline.
    private func distance(_ p: GeoPoint, to line: [GeoPoint]) -> Double {
        zip(line, line.dropFirst()).map { a, b -> Double in
            let (bx, by) = metres(b, from: a), (px, py) = metres(p, from: a)
            let t = max(0, min(1, (px * bx + py * by) / max(bx * bx + by * by, 1e-9)))
            return hypot(px - t * bx, py - t * by)
        }.min() ?? .infinity
    }

    func testTheDemoHomeIsAPublicSpotInsideTheDemoLoop() {
        let loop = DemoRoutePlayer.defaultRoute
        XCTAssertEqual(loop.first, loop.last, "a closed loop")
        let home = DemoPlaces.home(language: .en)
        XCTAssertTrue(inside(home.point, loop), "inside the park the demo loop circles")
        XCTAssertGreaterThan(distance(home.point, to: loop), 200, "well off the loop's roads")
        // not on the park favourite of the demo seed (PlacesStore would merge the two)
        XCTAssertFalse(home.isSameLocation(as: Place(name: "Parque Simón Bolívar", lat: 4.65845, lon: -74.09380)))
        // it says it is a demo, in both languages
        XCTAssertEqual(home.name, "Demo home")
        XCTAssertEqual(DemoPlaces.home(language: .es).name, "Casa (demo)")
        XCTAssertEqual(DemoPlaces.home(language: .es).point, home.point)
        XCTAssertTrue(DemoPlaces.homeSubtitle.hasSuffix("(demo)"))
        // stored as Home with that subtitle
        let store = PlacesStore(store: InMemoryKeyValueStore())
        store.setHome(home, subtitle: DemoPlaces.homeSubtitle)
        XCTAssertEqual(store.home()?.name, "Demo home")
        XCTAssertEqual(store.home()?.subtitle, DemoPlaces.homeSubtitle)
        XCTAssertEqual(store.home()?.category, "home")
    }
}
