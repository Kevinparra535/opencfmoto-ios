// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: FuelProfile defaults, clamps, completeness and its v1 JSON.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class FuelProfileTests: XCTestCase {
    private func encode<T: Encodable>(_ v: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(v), as: UTF8.self)
    }

    func testDefaultsAndCatalogProfile() throws {
        let entry = try XCTUnwrap(FuelCatalog.entry(id: "cfmoto-450mt"))
        let p = FuelProfile.from(entry, nowMs: 1_793_461_327_000)
        XCTAssertEqual(p.v, 1)
        XCTAssertEqual(p.catalogId, "cfmoto-450mt")
        XCTAssertEqual(p.name, "CFMOTO 450MT")
        XCTAssertEqual(p.tankL, 17.5)
        XCTAssertEqual(p.seedKmPerL, 20.5)
        XCTAssertEqual(p.seedSource, .catalog)
        XCTAssertEqual(p.reservePct, 12)
        XCTAssertEqual(FuelProfile.defaultReservePct, 12)
        XCTAssertTrue(p.preferLearned)
        XCTAssertTrue(p.isComplete)
        let m = FuelProfile.manual(nowMs: 5)
        XCTAssertNil(m.catalogId)
        XCTAssertEqual(m.name, "")
        XCTAssertEqual(m.tankL, 0)
        XCTAssertEqual(m.seedKmPerL, 15.5)
        XCTAssertEqual(m.seedSource, .manual)
        XCTAssertFalse(m.isComplete, "no tank yet")
    }

    func testClamps() {
        var p = FuelProfile(catalogId: nil, name: "", tankL: 2, seedKmPerL: 80, seedSource: .manual, reservePct: 40, updatedAtMs: 0)
        var c = p.clamped()
        XCTAssertEqual(c.tankL, 3)
        XCTAssertEqual(c.seedKmPerL, 60)
        XCTAssertEqual(c.reservePct, 30)
        p.tankL = .nan
        p.seedKmPerL = -.infinity
        p.reservePct = 1
        c = p.clamped()
        XCTAssertEqual(c.tankL, 3)
        XCTAssertEqual(c.seedKmPerL, 5)
        XCTAssertEqual(c.reservePct, 5)
        p.tankL = 80
        XCTAssertEqual(p.clamped().tankL, 60)
    }

    func testCompleteness() {
        func complete(_ t: Double, _ k: Double) -> Bool {
            FuelProfile(catalogId: nil, name: "", tankL: t, seedKmPerL: k, seedSource: .manual, updatedAtMs: 0).isComplete
        }
        XCTAssertTrue(complete(3, 5))
        XCTAssertTrue(complete(60, 60))
        XCTAssertFalse(complete(2.9, 20))
        XCTAssertFalse(complete(15, 4.9))
        XCTAssertFalse(complete(.nan, 20))
        XCTAssertFalse(complete(15, .infinity))
    }

    func testJSONRoundTripMatchesTheDocumentedShape() throws {
        let entry = try XCTUnwrap(FuelCatalog.entry(id: "cfmoto-450mt"))
        let p = FuelProfile.from(entry, nowMs: 1_793_461_327_000)
        let json = try encode(p)
        XCTAssertEqual(json, #"{"catalogId":"cfmoto-450mt","name":"CFMOTO 450MT","preferLearned":true,"reservePct":12,"seedKmPerL":20.5,"seedSource":"catalog","tankL":17.5,"updatedAtMs":1793461327000,"v":1}"#)
        XCTAssertEqual(try JSONDecoder().decode(FuelProfile.self, from: Data(json.utf8)), p)
        let manual = try encode(FuelProfile.manual(nowMs: 1))
        XCTAssertFalse(manual.contains("catalogId"), "nil optionals are omitted")
        XCTAssertEqual(try JSONDecoder().decode(FuelProfile.self, from: Data(manual.utf8)), FuelProfile.manual(nowMs: 1))
    }

    func testOtherVersionsAndBrokenDocumentsAreRejected() {
        let v2 = #"{"catalogId":"cfmoto-450mt","name":"x","preferLearned":true,"reservePct":12,"seedKmPerL":20.5,"seedSource":"catalog","tankL":17.5,"updatedAtMs":1,"v":2}"#
        XCTAssertNil(try? JSONDecoder().decode(FuelProfile.self, from: Data(v2.utf8)))
        XCTAssertNil(try? JSONDecoder().decode(FuelProfile.self, from: Data(#"{"v":1}"#.utf8)))
        XCTAssertNil(try? JSONDecoder().decode(FuelProfile.self, from: Data("[]".utf8)))
        let noPrefer = #"{"name":"x","reservePct":12,"seedKmPerL":20.5,"seedSource":"manual","tankL":17.5,"updatedAtMs":1,"v":1}"#
        XCTAssertEqual(try? JSONDecoder().decode(FuelProfile.self, from: Data(noPrefer.utf8)).preferLearned, true)
    }
}
