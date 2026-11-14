// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the bundled catalog matches its sourced research row for row, every row meets the catalog
// rules, and the search is exact-token (no substring / partial-token scoring).
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class FuelCatalogTests: XCTestCase {
    /// The "Machine-readable copy" of the catalog research (fuel/CATALOG.md, revision 2): the transcription
    /// source. Its `families` are the dash families each row is listed for.
    static let researchJSON = #"""
[
 {"id":"cfmoto-450mt","brand":"CFMOTO","model":"450MT","aliases":["Ibex 450"],"years":"2024+","tankL":17.5,"seedKmpl":20.5,"confidence":"published-test","tankSource":"https://www.cfmoto.com.au/model/450mt","tankKind":"official","consumptionSource":"https://www.motoplanete.us/cfmoto/11119/450-MT-2025/contact.html","families":[{"profile":"legacy","status":"confirmed"},{"profile":"motoplay_land","status":"guessed"}]},
 {"id":"cfmoto-450sr","brand":"CFMOTO","model":"450SR","aliases":["450SR-S","450SR TC","450SS"],"years":"2023+","tankL":14,"seedKmpl":20.0,"confidence":"published-test","tankSource":"https://www.cfmoto.com.au/model/450sr-abs","tankKind":"official","consumptionSource":"https://www.autocar.co.nz/2023-cfmoto-450-sr-review","families":[{"profile":"legacy","status":"guessed"},{"profile":"motoplay_land","status":"guessed"}]},
 {"id":"cfmoto-450nk","brand":"CFMOTO","model":"450NK","aliases":[],"years":"2023+","tankL":14,"seedKmpl":19.0,"confidence":"published-test","tankSource":"https://www.cfmoto.com.au/model/450nk-abs","tankKind":"official","consumptionSource":"https://www.bennetts.co.uk/bikesocial/reviews/bikes/cfmoto/450nk-2024-review","families":[{"profile":"legacy","status":"guessed"},{"profile":"motoplay_land","status":"guessed"},{"profile":"nk800","status":"guessed"}]},
 {"id":"cfmoto-450cl-c","brand":"CFMOTO","model":"450CL-C","aliases":["CL-C450"],"years":"2024+","tankL":12,"seedKmpl":19.0,"confidence":"estimate","tankSource":"https://medias.cfmoto.ca/download/1239/2026/22107/450cl-c_2026_en.pdf?lang=en","tankKind":"official","consumptionSource":"estimate: twin 400-500 cc class default 19.0 km/L (no independent test)","families":[{"profile":"clc450","status":"confirmed"}]},
 {"id":"cfmoto-675sr-r","brand":"CFMOTO","model":"675SR-R","aliases":["675SS"],"years":"2025+","tankL":15,"seedKmpl":16.5,"confidence":"published-test","tankSource":"https://medias.cfmoto.ca/download/1239/2026/19116/675ss_2026_en.pdf?lang=en","tankKind":"official","consumptionSource":"https://www.1000ps.com/en-gb/model/12901/cfmoto-675sr-r/2026","families":[{"profile":"legacy","status":"confirmed"},{"profile":"motoplay_land","status":"guessed"}]},
 {"id":"cfmoto-675nk","brand":"CFMOTO","model":"675NK","aliases":[],"years":"2025+","tankL":15,"seedKmpl":17.0,"confidence":"estimate","tankSource":"https://www.cfmoto.com.au/model/675nk","tankKind":"official","consumptionSource":"estimate: twin/triple 650-700 cc class default 17.0 km/L (no independent test)","families":[{"profile":"legacy","status":"guessed"},{"profile":"motoplay_land","status":"guessed"}]},
 {"id":"cfmoto-700mt-18l","brand":"CFMOTO","model":"700MT","aliases":["700MT Adventure"],"years":"MY2023-2024 (18 L)","tankL":18,"seedKmpl":17.0,"confidence":"published-test","tankSource":"https://www.bennetts.co.uk/bikesocial/reviews/bikes/cfmoto/700mt-2023-review","tankKind":"press","consumptionSource":"https://www.motoplanete.us/cfmoto/10717/700-MT-2024/contact.html","families":[{"profile":"legacy","status":"guessed"},{"profile":"motoplay_land","status":"guessed"}]},
 {"id":"cfmoto-700mt-20l","brand":"CFMOTO","model":"700MT","aliases":["700MT Adventure"],"years":"MY2025+ (20 L)","tankL":20,"seedKmpl":17.0,"confidence":"published-test","tankSource":"https://www.cfmoto.com.au/model/700mt","tankKind":"official","consumptionSource":"https://www.motoplanete.us/cfmoto/10717/700-MT-2024/contact.html","families":[{"profile":"legacy","status":"guessed"},{"profile":"motoplay_land","status":"guessed"}]},
 {"id":"cfmoto-700cl-x","brand":"CFMOTO","model":"700CL-X","aliases":["700CL-X Heritage","700CL-X Sport","700CL-X Adventure"],"years":"2021+","tankL":13,"seedKmpl":18.0,"confidence":"published-test","tankSource":"https://www.cfmoto.com.au/model/700cl-x-heritage","tankKind":"official","consumptionSource":"https://www.bikesales.com.au/editorial/details/2022-cfmoto-700cl-x-heritage-review-132099/","families":[]},
 {"id":"cfmoto-800mt","brand":"CFMOTO","model":"800MT Sport / Touring","aliases":["800MT Sport","800MT Touring","Ibex 800 S","Ibex 800 T"],"years":"2021+","tankL":19,"seedKmpl":17.5,"confidence":"published-test","tankSource":"https://www.cfmoto.com.au/model/800mt-touring","tankKind":"official","consumptionSource":"https://www.racq.com.au/articles/car-reviews/cfmoto-800mt-touring-motorcycle-review","families":[{"profile":"cfdl26_land","status":"guessed"}]},
 {"id":"cfmoto-800mt-explore","brand":"CFMOTO","model":"800MT Explore","aliases":["800MT Explore GT","Ibex 800 E"],"years":"2023+","tankL":19,"seedKmpl":17.5,"confidence":"published-test","tankSource":"https://cfmotobenelux.be/en/model/800mt-explore","tankKind":"official","consumptionSource":"https://www.advrider.com/cfmoto-800mt-explore/","families":[{"profile":"cfdl26_land","status":"confirmed"}]},
 {"id":"cfmoto-800mt-x","brand":"CFMOTO","model":"800MT-X","aliases":[],"years":"2025+","tankL":22.5,"seedKmpl":17.5,"confidence":"published-test","tankSource":"https://www.cfmoto.com.au/model/800mt-x","tankKind":"official","consumptionSource":"https://www.brm.co.nz/cfmoto-800mt-x-review-affordable-adventurer","families":[{"profile":"cfdl26_port","status":"confirmed"}]},
 {"id":"cfmoto-800nk","brand":"CFMOTO","model":"800NK","aliases":["800NK Sport"],"years":"2023+","tankL":15,"seedKmpl":17.5,"confidence":"published-test","tankSource":"https://medias.cfmoto.ca/download/770/2024/10258/2024_ibex-800nk-en.pdf?lang=en","tankKind":"official","consumptionSource":"https://motorcyclenews.com/bike-reviews/cf-moto/800nk-advanced","families":[{"profile":"nk800","status":"confirmed"}]},
 {"id":"cfmoto-800nk-advanced","brand":"CFMOTO","model":"800NK Advanced","aliases":["800NK Advanced TC"],"years":"2023+","tankL":15,"seedKmpl":17.5,"confidence":"published-test","tankSource":"https://motorcyclenews.com/bike-reviews/cf-moto/800nk-advanced","tankKind":"press","consumptionSource":"https://motorcyclenews.com/bike-reviews/cf-moto/800nk-advanced","families":[{"profile":"nk_adv","status":"confirmed"}]},
 {"id":"cfmoto-1000mt-x","brand":"CFMOTO","model":"1000MT-X","aliases":[],"years":"2026+","tankL":22.5,"seedKmpl":15.5,"confidence":"published-test","tankSource":"https://www.cfmoto.com.au/model/1000mt-x","tankKind":"official","consumptionSource":"https://www.1000ps.com/en-gb/article/3014010/first-ride-review-of-the-new-cfmoto-1000-mt-x","families":[{"profile":"cfdl26_port","status":"confirmed"}]},
 {"id":"cfmoto-300sr","brand":"CFMOTO","model":"300SR","aliases":["300SS"],"years":"2020+","tankL":12,"seedKmpl":22.0,"confidence":"estimate","tankSource":"https://medias.cfmoto.ca/download/1239/2026/19108/300ss_2026_en.pdf?lang=en","tankKind":"official","consumptionSource":"estimate: single <=300 cc class default 22.0 km/L (published 30-32 km/L lab-like, no mixed-riding test)","families":[{"profile":"legacy","status":"guessed"}]},
 {"id":"motomorini-x-cape-650","brand":"Moto Morini","model":"X-Cape 650","aliases":["X-Cape 649","Xcape 649","X-Cape 650X","X-Cape 650T"],"years":"2021-2024","tankL":18,"seedKmpl":20.0,"confidence":"published-test","tankSource":"https://www.autocarindia.com/bikes/moto-morini/x-cape/650","tankKind":"press","consumptionSource":"https://www.insella.it/da-sapere/vivere-moto/moto-morini-x-cape-650-ecco-velocita-massima-accelerazione-consumi-61229","families":[{"profile":"morini","status":"guessed"}]},
 {"id":"motomorini-x-cape-700","brand":"Moto Morini","model":"X-Cape 700","aliases":[],"years":"2025+","tankL":17.5,"seedKmpl":19.5,"confidence":"published-test","tankSource":"https://www.insella.it/news/velocita-max-potenza-peso-ecco-tutti-dati-della-moto-morini-x-cape-700-68729","tankKind":"press","consumptionSource":"https://www.insella.it/news/velocita-max-potenza-peso-ecco-tutti-dati-della-moto-morini-x-cape-700-68729","families":[{"profile":"morini","status":"guessed"}]},
 {"id":"motomorini-seiemmezzo","brand":"Moto Morini","model":"Seiemmezzo","aliases":["Seiemmezzo STR","Seiemmezzo SCR","Seiemmezzo 650"],"years":"2022+","tankL":15,"seedKmpl":19.5,"confidence":"published-test","tankSource":"https://www.motoplanete.us/morini/10667/seiemmezzo-650-str-2024/contact.html","tankKind":"press","consumptionSource":"https://www.insella.it/prova/moto-morini-seiemmezzo-str-2023","families":[{"profile":"morini","status":"guessed"}]}

]
"""#

    struct ResearchRow: Decodable {
        struct Family: Decodable { var profile: String; var status: String }
        var id: String
        var brand: String
        var model: String
        var aliases: [String]
        var years: String
        var tankL: Double
        var seedKmpl: Double
        var confidence: String
        var tankSource: String
        var tankKind: String
        var consumptionSource: String
        var families: [Family]
    }

    static let research: [ResearchRow] = try! JSONDecoder().decode([ResearchRow].self, from: Data(researchJSON.utf8))

    private func ids(_ q: String, brand: FuelBrand? = nil) -> [String] {
        FuelCatalog.search(q, brand: brand).map(\.id)
    }

    // MARK: Transcription

    func testTheCatalogIsTheResearchRowForRow() {
        let all = FuelCatalog.all
        XCTAssertEqual(all.count, 19)
        XCTAssertEqual(all.filter { $0.brand == .cfmoto }.count, 16)
        XCTAssertEqual(all.filter { $0.brand == .morini }.count, 3)
        XCTAssertEqual(all.map(\.id), Self.research.map(\.id), "catalog order = research order")
        for (e, r) in zip(all, Self.research) {
            XCTAssertEqual(e.brand.displayName, r.brand, e.id)
            XCTAssertEqual(e.model, r.model, e.id)
            XCTAssertEqual(e.aliases, r.aliases, e.id)
            XCTAssertEqual(e.marketNote, r.years, e.id)
            XCTAssertEqual(e.tankL, r.tankL, e.id)
            XCTAssertEqual(e.seedKmPerL, r.seedKmpl, e.id)
            XCTAssertEqual(e.tankSource, r.tankSource, e.id)
            XCTAssertEqual(e.consumptionSource, r.consumptionSource, e.id)
            XCTAssertEqual(e.tankKind, r.tankKind == "official" ? .official : .published, e.id)
            XCTAssertEqual(e.consumptionKind, r.confidence == "estimate" ? .estimate : .published, e.id)
            XCTAssertTrue(["official", "press"].contains(r.tankKind), e.id)
            XCTAssertTrue(["published-test", "estimate"].contains(r.confidence), e.id)
        }
    }

    func testEveryRowMeetsTheCatalogRules() {
        var seen = Set<String>()
        for e in FuelCatalog.all {
            XCTAssertTrue(seen.insert(e.id).inserted, "duplicate \(e.id)")
            XCTAssertNotNil(e.id.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression), e.id)
            XCTAssertTrue(e.id.hasPrefix(e.brand == .cfmoto ? "cfmoto-" : "motomorini-"), e.id)
            XCTAssertTrue((5.0 ... 40.0).contains(e.tankL), e.id)
            XCTAssertTrue((10.0 ... 45.0).contains(e.seedKmPerL), e.id)
            XCTAssertEqual((e.seedKmPerL * 2).rounded(), e.seedKmPerL * 2, "\(e.id): a multiple of 0.5")
            XCTAssertTrue(e.tankSource.hasPrefix("https://"), e.id)
            XCTAssertNotEqual(e.tankKind, .estimate, e.id)
            if e.consumptionKind == .estimate {
                XCTAssertTrue(e.consumptionSource.hasPrefix("estimate: "), e.id)
            } else {
                XCTAssertTrue(e.consumptionSource.hasPrefix("https://"), e.id)
            }
            XCTAssertEqual(FuelCatalog.entry(id: e.id), e)
            XCTAssertTrue(e.displayName.hasPrefix(e.brand.displayName + " "), e.id)
        }
        XCTAssertNil(FuelCatalog.entry(id: "cfmoto-450"))
    }

    func testPinnedFigures() throws {
        let mt = try XCTUnwrap(FuelCatalog.entry(id: "cfmoto-450mt"))
        XCTAssertEqual(mt.tankL, 17.5)
        XCTAssertEqual(mt.seedKmPerL, 20.5)
        XCTAssertLessThanOrEqual(mt.seedKmPerL, 21.0, "never Road Trip's 26 km/L")
        XCTAssertEqual(mt.displayName, "CFMOTO 450MT")
        XCTAssertEqual(mt.confidence, .published)
        // the smaller tank where sources disagree
        XCTAssertEqual(FuelCatalog.entry(id: "motomorini-x-cape-700")?.tankL, 17.5)
        XCTAssertEqual(FuelCatalog.entry(id: "motomorini-seiemmezzo")?.tankL, 15)
        XCTAssertEqual(FuelCatalog.entry(id: "cfmoto-700mt-18l")?.tankL, 18)
        XCTAssertEqual(FuelCatalog.entry(id: "cfmoto-700mt-20l")?.tankL, 20)
        XCTAssertEqual(FuelCatalog.entry(id: "cfmoto-800nk-advanced")?.tankKind, .published)
        XCTAssertEqual(FuelCatalog.entry(id: "cfmoto-450cl-c")?.confidence, .estimate)
        XCTAssertEqual(FuelCatalog.entry(id: "motomorini-x-cape-650")?.displayName, "Moto Morini X-Cape 650")
    }

    func testModelYearsAreParsedFromTheMarketNote() {
        for e in FuelCatalog.all {
            let (from, to) = FuelCatalog.yearRange(of: e.marketNote)
            XCTAssertEqual(e.fromYear, from, e.id)
            XCTAssertEqual(e.toYear, to, e.id)
            XCTAssertNotNil(e.fromYear, e.id)
        }
        XCTAssertTrue(FuelCatalog.yearRange(of: "2024+") == (2024, nil))
        XCTAssertTrue(FuelCatalog.yearRange(of: "2021-2024") == (2021, 2024))
        XCTAssertTrue(FuelCatalog.yearRange(of: "MY2023-2024 (18 L)") == (2023, 2024))
        XCTAssertTrue(FuelCatalog.yearRange(of: "MY2025+ (20 L)") == (2025, nil))
        XCTAssertTrue(FuelCatalog.yearRange(of: "2022") == (2022, 2022))
        XCTAssertTrue(FuelCatalog.yearRange(of: "all markets") == (nil, nil))
    }

    // MARK: Tokens

    func testWordsFoldSplitAndMergeBrands() {
        XCTAssertEqual(FuelCatalog.words("CF Moto 450mt"), ["cfmoto", "450mt"])
        XCTAssertEqual(FuelCatalog.words("cf-moto 450 MT"), ["cfmoto", "450", "mt"])
        XCTAssertEqual(FuelCatalog.words("CFMOTO 450-MT"), ["cfmoto", "450-mt"])
        XCTAssertEqual(FuelCatalog.words("Moto Morini X-Cape"), ["motomorini", "x-cape"])
        XCTAssertEqual(FuelCatalog.words("MotoMorini / Seiemmezzo"), ["motomorini", "seiemmezzo"])
        XCTAssertEqual(FuelCatalog.words("Morini"), ["motomorini"])
        XCTAssertEqual(FuelCatalog.words("  Ibéx\t450  "), ["ibex", "450"])
        XCTAssertEqual(FuelCatalog.words("800MT Sport / Touring"), ["800mt", "sport", "touring"])
        XCTAssertEqual(FuelCatalog.brand(ofToken: "cfmoto"), .cfmoto)
        XCTAssertEqual(FuelCatalog.brand(ofToken: "morini"), .morini)
        XCTAssertEqual(FuelCatalog.brand(ofToken: "motomorini"), .morini)
        XCTAssertNil(FuelCatalog.brand(ofToken: "cfm"))
        XCTAssertNil(FuelCatalog.brand(ofToken: "moto"))
    }

    func testTokenSetsAreCompactWordsAndModelNumbersOnly() throws {
        func tokens(_ id: String) throws -> Set<String> { FuelCatalog.tokenSet(of: try XCTUnwrap(FuelCatalog.entry(id: id))) }
        XCTAssertEqual(try tokens("cfmoto-450mt"), ["450mt", "450", "ibex"])
        XCTAssertEqual(try tokens("cfmoto-1000mt-x"), ["1000mtx", "1000"])
        XCTAssertEqual(try tokens("cfmoto-450cl-c"), ["450clc", "450", "clc450"])
        XCTAssertEqual(try tokens("motomorini-x-cape-700"), ["xcape", "700"])
        XCTAssertEqual(try tokens("cfmoto-800mt"), ["800mt", "800", "sport", "touring", "ibex", "s", "t"])
        let all = FuelCatalog.all.map(FuelCatalog.tokenSet).reduce(Set<String>()) { $0.union($1) }
        for fragment in ["mt", "x", "nk", "sr", "45", "80", "cl", "c"] { XCTAssertFalse(all.contains(fragment), fragment) }
    }

    // MARK: Search pins

    func testSearchPins() {
        XCTAssertEqual(ids("800 MT"), ["cfmoto-800mt", "cfmoto-800mt-explore"])
        XCTAssertEqual(ids("800mt"), ["cfmoto-800mt", "cfmoto-800mt-explore"])
        XCTAssertEqual(ids("450 NK"), ["cfmoto-450nk"])
        XCTAssertEqual(ids("450 SR"), ["cfmoto-450sr"])
        for q in ["CF Moto 450mt", "cf-moto 450 MT", "CFMOTO 450-MT", "Ibex 450"] {
            XCTAssertEqual(ids(q).first, "cfmoto-450mt", q)
        }
        XCTAssertEqual(ids("Ibex 450"), ["cfmoto-450mt"])
        XCTAssertEqual(ids("450ss"), ["cfmoto-450sr"])
        XCTAssertEqual(ids("675ss"), ["cfmoto-675sr-r"])
        XCTAssertEqual(ids("cl-c450"), ["cfmoto-450cl-c"])
        XCTAssertEqual(ids("xcape 649"), ["motomorini-x-cape-650"])
        XCTAssertEqual(ids("1000mtx"), ["cfmoto-1000mt-x"])
        XCTAssertEqual(ids("1000 MT X"), ["cfmoto-1000mt-x"])
        XCTAssertEqual(ids("800 mt x"), ["cfmoto-800mt-x"])
        XCTAssertEqual(ids("700 mt 2024"), ["cfmoto-700mt-18l"])
        XCTAssertEqual(ids("700 mt 2025"), ["cfmoto-700mt-20l"])
        for q in ["45", "80", "mt", "x", "ibe", "cfm", "450m", "800m", "xcap"] { XCTAssertEqual(ids(q), [], q) }
        XCTAssertEqual(ids("450"), ["cfmoto-450mt", "cfmoto-450sr", "cfmoto-450nk", "cfmoto-450cl-c"])
        XCTAssertEqual(ids("Moto Morini"), ["motomorini-x-cape-650", "motomorini-x-cape-700", "motomorini-seiemmezzo"])
        XCTAssertEqual(ids("cfmoto"), FuelCatalog.all.filter { $0.brand == .cfmoto }.map(\.id))
        XCTAssertEqual(ids("cfmoto").count, 16)
        XCTAssertEqual(ids("X-Cape", brand: .cfmoto), [])
        XCTAssertEqual(ids("Morini X-Cape", brand: .cfmoto), ["motomorini-x-cape-650", "motomorini-x-cape-700"])
        XCTAssertEqual(ids("X-Cape"), ["motomorini-x-cape-650", "motomorini-x-cape-700"])
        XCTAssertFalse(ids("800 MT").contains("cfmoto-450mt"))
        XCTAssertFalse(ids("450 NK").contains("cfmoto-450mt"))
        XCTAssertFalse(ids("450 SR").contains("cfmoto-450mt"))
    }

    func testEmptyQueryAndPrefilter() {
        XCTAssertEqual(ids(""), FuelCatalog.all.map(\.id))
        XCTAssertEqual(ids("   ", brand: .morini), ["motomorini-x-cape-650", "motomorini-x-cape-700", "motomorini-seiemmezzo"])
        XCTAssertEqual(ids("", brand: .cfmoto).count, 16)
        // a brand typed by the rider replaces the guessed prefilter
        XCTAssertEqual(ids("cfmoto 450 mt", brand: .morini), ["cfmoto-450mt"])
    }

    func testYearFilter() {
        XCTAssertEqual(ids("2021", brand: .morini), ["motomorini-x-cape-650"])
        XCTAssertEqual(ids("x-cape 2025"), ["motomorini-x-cape-700"])
        XCTAssertFalse(ids("2019").contains("cfmoto-450mt"))
        XCTAssertTrue(ids("2020").contains("cfmoto-300sr"))
        XCTAssertEqual(ids("1000mt-x 2025"), [], "the 1000MT-X starts in 2026")
    }

    func testOrderPutsTheBestNamedEntryFirst() {
        // "800 Explore": the Explore row names both of its model words.
        XCTAssertEqual(ids("800mt explore"), ["cfmoto-800mt-explore"])
        // "800": every 800 row matches; the ones whose name is the whole query come first, then catalog order.
        let eight = ids("800")
        XCTAssertEqual(Set(eight), ["cfmoto-800mt", "cfmoto-800mt-explore", "cfmoto-800mt-x", "cfmoto-800nk",
                                    "cfmoto-800nk-advanced"])
        XCTAssertLessThan(eight.firstIndex(of: "cfmoto-800mt-x")!, eight.firstIndex(of: "cfmoto-800nk-advanced")!)
        XCTAssertLessThan(eight.firstIndex(of: "cfmoto-800nk")!, eight.firstIndex(of: "cfmoto-800mt-explore")!)
    }

    // MARK: Families ⇔ candidate table

    func testCandidateTableEqualsTheResearchFamilies() {
        let known = Set(FuelCatalog.all.map(\.id))
        for (family, list) in BikeCandidates.familyTable {
            XCTAssertEqual(Set(list).count, list.count, "\(family): no duplicates")
            XCTAssertTrue(Set(list).isSubset(of: known), "\(family)")
            let research = Set(Self.research.filter { $0.families.contains { $0.profile == family.rawValue } }.map(\.id))
            XCTAssertEqual(Set(list), research, "\(family)")
        }
        let researchFamilies = Set(Self.research.flatMap { $0.families.map(\.profile) })
        XCTAssertEqual(researchFamilies, Set(BikeCandidates.familyTable.keys.map(\.rawValue)))
        XCTAssertEqual(BikeCandidates.ambiguous37426, ["cfmoto-800mt-explore", "cfmoto-800nk-advanced", "cfmoto-800mt",
                                                       "cfmoto-800mt-x", "cfmoto-1000mt-x"])
        XCTAssertTrue(Set(BikeCandidates.ambiguous37426).isSubset(of: known))
        let listed = Set(BikeCandidates.familyTable.values.flatMap { $0 } + BikeCandidates.ambiguous37426)
        XCTAssertFalse(listed.contains("cfmoto-700cl-x"))
        XCTAssertNotNil(FuelCatalog.entry(id: "cfmoto-700cl-x"), "searchable through «Otra moto»")
        XCTAssertEqual(ids("700cl-x"), ["cfmoto-700cl-x"])
        // 18 L before 20 L in both lists of the 700MT
        for family in [BikeProfileID.legacy, .motoplayLandscape] {
            let l = BikeCandidates.familyTable[family]!
            XCTAssertLessThan(l.firstIndex(of: "cfmoto-700mt-18l")!, l.firstIndex(of: "cfmoto-700mt-20l")!)
        }
        XCTAssertEqual(BikeCandidates.familyTable[.legacy]?.first, "cfmoto-450mt")
    }
}
