// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the refuel log — add / undo-last / delete, the input bounds, anchors, cost and the v1 JSON.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class RefuelLogTests: XCTestCase {
    func testAddStampsTheOdometerAndSubtractsLateKmFlooredAtThePreviousEntry() {
        var log = RefuelLog()
        let a = log.add(RefuelInput(kind: .full), nowMs: 1000, odometerKm: 1000, unseen: false, id: "a")
        XCTAssertEqual(a.odometerKm, 1000)
        XCTAssertNil(a.unseenSincePrev)
        let b = log.add(RefuelInput(kind: .full, litres: 15, lateKm: 20), nowMs: 2000, odometerKm: 1300, unseen: true, id: "b")
        XCTAssertEqual(b.odometerKm, 1280, "the real refuel was 20 km ago")
        XCTAssertEqual(b.lateKm, 20)
        XCTAssertEqual(b.unseenSincePrev, true)
        let c = log.add(RefuelInput(kind: .partial, litres: 3, lateKm: 500), nowMs: 3000, odometerKm: 1300, unseen: false, id: "c")
        XCTAssertEqual(c.odometerKm, 1280, "never before the previous entry")
        XCTAssertEqual(log.entries.map(\.id), ["a", "b", "c"])
        var fresh = RefuelLog()
        XCTAssertEqual(fresh.add(RefuelInput(kind: .full, lateKm: 50), nowMs: 1, odometerKm: 10, unseen: false).odometerKm, 0)
        XCTAssertFalse(fresh.entries[0].id.isEmpty, "a UUID by default")
    }

    func testKindSpecificFieldsAreDropped() {
        var log = RefuelLog()
        let full = log.add(RefuelInput(kind: .full, litres: 10, levelAfter: .half), nowMs: 1, odometerKm: 0, unseen: false)
        XCTAssertNil(full.levelAfter, "a full tank has no level")
        let partial = log.add(RefuelInput(kind: .partial, levelAfter: .quarter), nowMs: 2, odometerKm: 1, unseen: false)
        XCTAssertEqual(partial.levelAfter, .quarter)
        let level = log.add(RefuelInput(kind: .level, levelAfter: .threeQuarters), nowMs: 3, odometerKm: 2, unseen: false)
        XCTAssertEqual(level.levelAfter, .threeQuarters)
        XCTAssertNil(level.litres)
    }

    func testUndoLastAndDelete() {
        var log = RefuelLog()
        log.add(RefuelInput(kind: .full), nowMs: 1, odometerKm: 0, unseen: false, id: "a")
        log.add(RefuelInput(kind: .partial, litres: 4), nowMs: 2, odometerKm: 50, unseen: true, id: "b")
        log.add(RefuelInput(kind: .full, litres: 12), nowMs: 3, odometerKm: 200, unseen: false, id: "c")
        log.add(RefuelInput(kind: .full, litres: 12), nowMs: 4, odometerKm: 400, unseen: false, id: "d")
        XCTAssertEqual(log.undoLast()?.id, "d")
        XCTAssertEqual(log.entries.map(\.id), ["a", "b", "c"])
        // deleting an unseen-stamped entry carries its stamp to the next one
        XCTAssertEqual(log.delete(id: "b")?.id, "b")
        XCTAssertEqual(log.entries.map(\.id), ["a", "c"])
        XCTAssertEqual(log.entries[1].unseenSincePrev, true)
        XCTAssertNil(log.delete(id: "zz"))
        XCTAssertEqual(log.delete(id: "c")?.id, "c")
        XCTAssertEqual(log.entries.map(\.id), ["a"])
        XCTAssertNil(log.entries[0].unseenSincePrev)
        _ = log.undoLast()
        XCTAssertNil(log.undoLast())
    }

    func testTheLogKeepsTheNewest1000() {
        var log = RefuelLog()
        for i in 0 ..< 1005 { log.add(RefuelInput(kind: .full, litres: 10), nowMs: Int64(i), odometerKm: Double(i), unseen: false, id: "e\(i)") }
        XCTAssertEqual(log.entries.count, RefuelLog.maxEntries)
        XCTAssertEqual(log.entries.first?.id, "e5")
        XCTAssertEqual(log.entries.last?.id, "e1004")
    }

    func testAnchorsAndCost() {
        func entry(_ kind: RefuelKind, litres: Double? = nil, level: TankLevel? = nil, per: Double? = nil, total: Double? = nil) -> RefuelEntry {
            RefuelEntry(id: "x", atMs: 0, kind: kind, litres: litres, levelAfter: level, pricePerLitre: per, totalPrice: total, odometerKm: 0)
        }
        XCTAssertTrue(entry(.full).isAnchor)
        XCTAssertTrue(entry(.level, level: .half).isAnchor)
        XCTAssertTrue(entry(.partial, level: .quarter).isAnchor)
        XCTAssertFalse(entry(.partial, litres: 5).isAnchor)
        XCTAssertEqual(entry(.full, litres: 10, per: 4.25).cost, 42.5)
        XCTAssertEqual(entry(.full, litres: 10, per: 4.25, total: 40).cost, 40, "the total wins")
        XCTAssertEqual(entry(.full, total: 40).cost, 40)
        XCTAssertNil(entry(.full, litres: 10).cost)
        XCTAssertNil(entry(.full, per: 4).cost)
        var log = RefuelLog()
        XCTAssertNil(log.lastAnchorIndex)
        log.add(RefuelInput(kind: .full), nowMs: 1, odometerKm: 0, unseen: false)
        log.add(RefuelInput(kind: .partial, litres: 2), nowMs: 2, odometerKm: 0, unseen: false)
        XCTAssertEqual(log.lastAnchorIndex, 0)
        log.add(RefuelInput(kind: .level, levelAfter: .half), nowMs: 3, odometerKm: 0, unseen: false)
        XCTAssertEqual(log.lastAnchorIndex, 2)
    }

    func testInputBounds() {
        XCTAssertNil(RefuelInput().invalidField())
        XCTAssertNil(RefuelInput(kind: .full, litres: 100, pricePerLitre: 0, totalPrice: 10_000_000, tripMeterKm: 5000, lateKm: 0).invalidField())
        XCTAssertNil(RefuelInput(kind: .partial, litres: 0.1, lateKm: 2000).invalidField())
        XCTAssertEqual(RefuelInput(litres: 0).invalidField(), .litres)
        XCTAssertEqual(RefuelInput(litres: 100.1).invalidField(), .litres)
        XCTAssertEqual(RefuelInput(litres: .nan).invalidField(), .litres)
        XCTAssertEqual(RefuelInput(pricePerLitre: -1).invalidField(), .price)
        XCTAssertEqual(RefuelInput(totalPrice: 10_000_001).invalidField(), .price)
        XCTAssertEqual(RefuelInput(totalPrice: .infinity).invalidField(), .price)
        XCTAssertEqual(RefuelInput(tripMeterKm: 0).invalidField(), .tripMeter)
        XCTAssertEqual(RefuelInput(tripMeterKm: 5001).invalidField(), .tripMeter)
        XCTAssertEqual(RefuelInput(lateKm: -1).invalidField(), .lateKm)
        XCTAssertEqual(RefuelInput(lateKm: 2001).invalidField(), .lateKm)
        XCTAssertEqual(RefuelInput(litres: -3, pricePerLitre: -1).invalidField(), .litres, "the first bad field")
        // level corrections
        XCTAssertNil(RefuelInput(kind: .level, levelAfter: .half).invalidField())
        XCTAssertEqual(RefuelInput(kind: .level).invalidField(), .level)
        XCTAssertEqual(RefuelInput(kind: .level, litres: 5, levelAfter: .half).invalidField(), .litres)
        XCTAssertEqual(RefuelInput(kind: .level, levelAfter: .half, pricePerLitre: 4).invalidField(), .price)
        XCTAssertEqual(RefuelInput(kind: .level, levelAfter: .half, totalPrice: 4).invalidField(), .price)
        XCTAssertEqual(RefuelInput(kind: .level, levelAfter: .half, tripMeterKm: 4).invalidField(), .tripMeter)
        XCTAssertEqual(TankLevel.allCases.map(\.fraction), [0.25, 0.5, 0.75])
    }

    func testJSONRoundTrip() throws {
        let log = RefuelLog(entries: [
            RefuelEntry(id: "6F1C", atMs: 1_792_000_000_000, kind: .full, odometerKm: 1000),
            RefuelEntry(id: "A2B4", atMs: 1_793_000_000_000, kind: .full, litres: 15.2, pricePerLitre: 4.25, tripMeterKm: 318,
                        odometerKm: 1311.4),
            RefuelEntry(id: "C9D0", atMs: 1_793_300_000_000, kind: .level, levelAfter: .half, odometerKm: 1460.2, unseenSincePrev: true),
        ])
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let json = String(decoding: try e.encode(log), as: UTF8.self)
        XCTAssertEqual(json, #"{"entries":[{"atMs":1792000000000,"id":"6F1C","kind":"full","odometerKm":1000},{"atMs":1793000000000,"id":"A2B4","kind":"full","litres":15.2,"odometerKm":1311.4,"pricePerLitre":4.25,"tripMeterKm":318},{"atMs":1793300000000,"id":"C9D0","kind":"level","levelAfter":"half","odometerKm":1460.2,"unseenSincePrev":true}],"v":1}"#)
        XCTAssertEqual(try JSONDecoder().decode(RefuelLog.self, from: Data(json.utf8)), log)
        XCTAssertNil(try? JSONDecoder().decode(RefuelLog.self, from: Data(#"{"entries":[],"v":2}"#.utf8)))
    }
}
