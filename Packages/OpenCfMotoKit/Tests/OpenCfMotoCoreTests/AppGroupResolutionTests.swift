// SPDX-License-Identifier: AGPL-3.0-or-later
// AppGroupResolution: which App Group the app and the mirror extension use (the declared one, or
// the one AltStore / SideStore re-signed the app with, from ALTAppGroups).

import XCTest
@testable import OpenCfMotoCore

final class AppGroupResolutionTests: XCTestCase {
    private let declared = "group.io.github.example.opencfmoto"
    private var resigned: String { declared + ".ABCDE12345" }   // AltStore: <declared>.<team id>

    private func resolve(_ declared: String?, _ alt: [String], entitled: Set<String>) -> AppGroupResolution.Choice? {
        asking(declared, alt, entitled: entitled).choice
    }

    /// The resolution and the ids it asked about, in order.
    private func asking(_ declared: String?, _ alt: [String],
                        entitled: Set<String>) -> (choice: AppGroupResolution.Choice?, asked: [String]) {
        var asked: [String] = []
        let choice = AppGroupResolution.resolve(declared: declared, altStoreGroups: alt) { id in
            asked.append(id)
            return entitled.contains(id)
        }
        return (choice, asked)
    }

    func testTheEntitledDeclaredGroupWinsAndNothingElseIsAsked() {
        let (choice, asked) = asking(declared, [resigned], entitled: [declared, resigned])
        XCTAssertEqual(choice, .init(identifier: declared, source: .declared))
        XCTAssertEqual(asked, [declared], "Xcode / TestFlight builds never look at ALTAppGroups")
    }

    func testAReSignedBuildUsesTheEntitledAltStoreGroup() {
        let (choice, asked) = asking(declared, [resigned], entitled: [resigned])
        XCTAssertEqual(choice, .init(identifier: resigned, source: .resigned))
        XCTAssertEqual(asked, [declared, resigned])
    }

    func testNoEntitledGroupGivesNil() {
        XCTAssertNil(resolve(declared, [resigned], entitled: []))
        XCTAssertNil(resolve(declared, [], entitled: []))
        XCTAssertNil(resolve(nil, [], entitled: [declared]))
        XCTAssertNil(resolve(declared, [resigned], entitled: ["group.other"]), "only candidates are asked")
    }

    func testAnUnrelatedEntryIsChosenOnlyWhenNothingBetterIsEntitled() {
        let unrelated = "group.com.someone.else"
        // Listed first, but the entry extending the declared group comes first.
        XCTAssertEqual(resolve(declared, [unrelated, resigned], entitled: [unrelated, resigned]),
                       .init(identifier: resigned, source: .resigned))
        // Nothing better is entitled: the unrelated entry is still a shared container.
        XCTAssertEqual(resolve(declared, [unrelated, resigned], entitled: [unrelated]),
                       .init(identifier: unrelated, source: .resigned))
        // The declared group beats every entry.
        XCTAssertEqual(resolve(declared, [unrelated], entitled: [unrelated, declared])?.source, .declared)
    }

    func testCandidateOrderPrefixOnADotBoundaryAndRepeats() {
        let lookalike = declared + "2"                       // not "<declared>." — no extension of it
        let second = declared + ".FGHIJ67890"
        let order = AppGroupResolution.candidates(declared: declared,
                                                  altStoreGroups: [lookalike, resigned, declared, second, resigned])
        XCTAssertEqual(order.map(\.identifier), [declared, resigned, second, lookalike])
        XCTAssertEqual(order.map(\.source), [.declared, .resigned, .resigned, .resigned])
    }

    func testInvalidIdsAreDroppedAndBlanksTrimmed() {
        let order = AppGroupResolution.candidates(
            declared: "  \(declared)\n",
            altStoreGroups: ["", "group.", "com.example.opencfmoto", "$(APP_GROUP_ID)", "group.$(BUNDLE_ID_PREFIX).x",
                             "group.with space", " \(resigned) "])
        XCTAssertEqual(order, [.init(identifier: declared, source: .declared),
                               .init(identifier: resigned, source: .resigned)])
        XCTAssertEqual(AppGroupResolution.candidates(declared: "$(APP_GROUP_ID)", altStoreGroups: [resigned]),
                       [.init(identifier: resigned, source: .resigned)],
                       "an unexpanded declaration is no candidate; the re-signed group still is")
    }

    func testWithoutADeclaredGroupTheEntriesKeepTheirOrder() {
        let a = "group.a.opencfmoto.T1", b = "group.b.opencfmoto.T2"
        XCTAssertEqual(AppGroupResolution.candidates(declared: nil, altStoreGroups: [b, a]).map(\.identifier), [b, a])
        XCTAssertEqual(resolve(nil, [b, a], entitled: [a, b])?.identifier, b)
    }

    func testAltStoreGroupsAsInfoPlistHoldsThem() {
        XCTAssertEqual(AppGroupResolution.altStoreGroups(from: [resigned, "group.x"]), [resigned, "group.x"])
        XCTAssertEqual(AppGroupResolution.altStoreGroups(from: [resigned, 7, ["nested"]] as [Any]), [resigned])
        XCTAssertEqual(AppGroupResolution.altStoreGroups(from: resigned), [resigned], "a lone string")
        XCTAssertEqual(AppGroupResolution.altStoreGroups(from: nil), [])
        XCTAssertEqual(AppGroupResolution.altStoreGroups(from: 42), [])
        XCTAssertEqual(AppGroupResolution.altStoreGroups(from: ["k": "v"]), [])
    }

    func testResolveFromAnInfoDictionary() {
        let info: [String: Any] = ["OCMAppGroupIdentifier": declared, "ALTAppGroups": [resigned]]
        XCTAssertEqual(AppGroupResolution.declaredInfoKey, "OCMAppGroupIdentifier")
        XCTAssertEqual(AppGroupResolution.altStoreInfoKey, "ALTAppGroups")
        XCTAssertEqual(AppGroupResolution.resolve(infoValue: { info[$0] }, isEntitled: { $0 == resigned }),
                       .init(identifier: resigned, source: .resigned))
        XCTAssertEqual(AppGroupResolution.resolve(infoValue: { info[$0] }, isEntitled: { _ in true })?.source, .declared)
        XCTAssertNil(AppGroupResolution.resolve(infoValue: { _ in nil }, isEntitled: { _ in true }))
    }

    func testNormalisation() {
        XCTAssertEqual(AppGroupResolution.normalized("group.com.example.opencfmoto"), "group.com.example.opencfmoto")
        XCTAssertEqual(AppGroupResolution.normalized("\tgroup.a.b \n"), "group.a.b")
        for bad in [nil, "", "group.", "com.example", "$(APP_GROUP_ID)", "group.$(X).y", "group.a b"] as [String?] {
            XCTAssertNil(AppGroupResolution.normalized(bad), String(describing: bad))
        }
    }

    func testLogLinesNeverNameAGroup() {
        XCTAssertNil(AppGroupResolution.logLine(for: .init(identifier: declared, source: .declared), declared: declared))
        let lines = [
            AppGroupResolution.logLine(for: .init(identifier: resigned, source: .resigned), declared: declared),
            AppGroupResolution.logLine(for: nil, declared: declared),
            AppGroupResolution.logLine(for: nil, declared: nil),
        ]
        XCTAssertEqual(lines.map { $0?.level }, [.info, .warn, .warn])
        XCTAssertTrue(lines[0]?.message.contains("re-signed") == true)
        XCTAssertTrue(lines[1]?.message.contains("not entitled") == true)
        XCTAssertTrue(lines[2]?.message.contains("none declared") == true)
        for line in lines {
            XCTAssertFalse(line?.message.contains("group.") ?? true, line?.message ?? "nil")
            XCTAssertFalse(line?.message.contains("ABCDE12345") ?? true)
        }
    }
}
