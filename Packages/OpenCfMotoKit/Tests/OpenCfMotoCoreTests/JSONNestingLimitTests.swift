// SPDX-License-Identifier: AGPL-3.0-or-later
// Review SEC-4: the recursive org.json tokeners (dash JSON, settings packs) and the service JSON path
// reject absurd nesting instead of recursing until a stack overflow — checked on a thread with the
// 512 KiB stack of Darwin's cooperative pool, where the link task parses CLIENT_INFO / CHECK_SN.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class JSONNestingLimitTests: XCTestCase {
    static func nested(_ depth: Int, inner: String = "1") -> String {
        String(repeating: "[", count: depth) + inner + String(repeating: "]", count: depth)
    }

    /// Runs `body` on a thread with a small stack and returns its result.
    private func onSmallStack<T: Sendable>(_ stack: Int = 512 * 1024, _ body: @escaping @Sendable () -> T) -> T? {
        let result = Locked<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.set(body())
            done.signal()
        }
        thread.stackSize = stack
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success)
        return result.current
    }

    func testPxcOrgJSONLimitsNesting() {
        XCTAssertNoThrow(try PxcOrgJSON.parseValue(Self.nested(64)))
        XCTAssertThrowsError(try PxcOrgJSON.parseValue(Self.nested(65))) {
            XCTAssertEqual($0 as? PxcOrgJSONError, .syntax("Nesting too deep"))
        }
        XCTAssertThrowsError(try PxcOrgJSON.parseObject("{\"a\":" + Self.nested(64) + "}")) // 65 with the object
        let survived = onSmallStack { () -> Bool in
            let info = BikeClientInfo.parse("{\"HUID\":\"x\",\"a\":" + Self.nested(100_000) + "}")
            let serial = CheckSn.serial(from: Data(("{\"sn\":\"DS1\",\"a\":" + Self.nested(100_000) + "}").utf8))
            return info == nil && serial.isEmpty
        }
        XCTAssertEqual(survived, true)
        // Real dash JSON still parses.
        XCTAssertNotNil(BikeClientInfo.parse(#"{"HUID":"6GUVA2C00100055","HUName":"CFDL16","supportFunction":{"a":[1,[2]]}}"#))
    }

    func testAndroidOrgJSONLimitsNesting() {
        XCTAssertNoThrow(try AndroidOrgJSON.parseValue(Self.nested(64)))
        XCTAssertThrowsError(try AndroidOrgJSON.parseValue(Self.nested(65))) { error in
            let message = (error as? AndroidOrgJSON.ParseError)?.message ?? ""
            XCTAssertTrue(message.hasPrefix("Nesting too deep"), message)
            XCTAssertLessThan(message.count, 100) // never echoes the (huge) input
        }
        let pack = #"{"format":"opencfmoto.settings","version":1,"settings":{},"x":"# + Self.nested(100_000) + "}"
        let message = onSmallStack(1024 * 1024) { () -> String in
            SettingsBackup.importJSON(pack, into: SettingsStore(store: InMemoryKeyValueStore()), bikeId: nil, bikeName: nil).message
        }
        XCTAssertEqual(message?.hasPrefix("Not valid JSON: Nesting too deep"), true, message ?? "")
    }

    func testSettingsPacksHaveASizeCap() {
        let big = #"{"format":"opencfmoto.settings","version":1,"settings":{},"pad":""# + String(repeating: "x", count: SettingsBackup.maxPackBytes) + #""}"#
        let result = SettingsBackup.importJSON(big, into: SettingsStore(store: InMemoryKeyValueStore()), bikeId: nil, bikeName: nil)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.hasPrefix("Not valid JSON: file too large"), result.message)
    }

    func testServiceJSONLimitsNesting() throws {
        XCTAssertNoThrow(try NavJSON.parse(Data(Self.nested(64).utf8)))
        XCTAssertThrowsError(try NavJSON.parse(Data(Self.nested(65).utf8)))
        XCTAssertThrowsError(try NavJSON.parse(Data(("{\"features\":" + Self.nested(100_000) + "}").utf8)))
        // Brackets inside strings do not count; escaped quotes do not end a string.
        let tricky = #"{"name":"[[[[\"{{{{","a":[[1]]}"# 
        XCTAssertFalse(NavJSON.exceedsDepth(Data(tricky.utf8), limit: 3))
        XCTAssertTrue(NavJSON.exceedsDepth(Data(tricky.utf8), limit: 2))
        XCTAssertEqual(try NavJSON.parse(Data(tricky.utf8))["name"].string(), "[[[[\"{{{{")
    }
}
