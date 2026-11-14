// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: «¿Cuál es tu moto?» — every family rule, the corroboration rule over the scoring quirks of
// control-plane.md §12.6 (fixtures A–L), the 37426 ambiguity and the owner's 450MT case.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class BikeCandidatesTests: XCTestCase {
    // control-plane.md §12.6 inputs (the same JSON as ProfileSelectionTests).
    static let fixtureA = #"{"HUID":"6GUVA2C00100055","HUName":"CFDL16-6GUV","sdkVersion":"0.9.29.1","supportFunction":0}"#
    static let fixtureB = #"{"HUID":"6WX0AT231300200","package_name":"com.cfmoto.cfdashmotoplay","version_name":"CFDL26.2.3.5.0.6","sdkVersion":"1.1.4","enableSockServerAuth":true,"supportScreenTouch":true,"supportMirrorOverlayTouch":true,"supportFunction":128}"#
    static let fixtureC = #"{"HUID":"6WWV00000001","package_name":"com.cfmoto.easyconnect","version_name":"CFDL26.2.3.0.5","sdkVersion":"1.1.2","enableSockServerAuth":true,"supportScreenTouch":true,"supportLandscapeAdaptive":true,"supportFunction":128}"#
    static let fixtureD = #"{"HUID":"6KWV00000001","package_name":"com.cfmoto.easyconnect","version_name":"CFDL26.2.3.0.5","sdkVersion":"1.1.2","enableSockServerAuth":true,"supportScreenTouch":true,"supportMirrorOverlayTouch":true,"supportFunction":128}"#
    static let fixtureE = #"{"HUID":"CRCP230501740","package_name":"linux_no_package","sdkVersion":"0.9.23.4","supportFunction":128}"#
    static let fixtureF = #"{"HUID":"CARB12345678","channel":"21333","flavor":51,"package_name":"","sdkVersion":"1.0.13.1"}"#
    static let fixtureG = #"{"HUName":"CFMOTO-48FB4C","channel":"66660736","sdkVersion":"0.9.23.4"}"#
    static let fixtureH = #"{"channel":"66660742","sdkVersion":"0.9.25.1","supportLandscapeAdaptive":true}"#
    static let fixtureI = #"{"sdkVersion":"1.2.0"}"#
    static let fixtureJ = #"{"sdkVersion":"0.9.30"}"#
    static let fixtureK = #"{"sdkVersion":"1.2.0","supportScreenTouch":true}"#
    static let fixtureL = #"{"version_name":"CFDL06.6.10","package_name":"net.easyconn","sdkVersion":"0.9.25.1","supportFunction":128}"#

    private func info(_ json: String) -> BikeClientInfo { BikeClientInfo.parse(json)! }

    private func live(_ json: String) -> DashInfo { DashInfo(rawJSON: json) }

    private func qr(_ modelId: String?, ssid: String = "CFMOTO-a1b2c3", action: Int = 1, extra: String = "") -> BikeQR {
        let mid = modelId.map { "modelid=\($0)&" } ?? ""
        return BikeQR.parse("http://www.carbit.com.cn/downsdk/1/2/_sdk?\(mid)sn=aaaa&action=\(action)&ssid=\(ssid)&pwd=demo1234&auth=wpa2-psk\(extra)")!
    }

    private func resolve(qr q: BikeQR?, hint: BikeProfileID? = nil, override: Bool = false, canvas: LearnedDashSize? = nil,
                         live l: String? = nil) -> BikeCandidateList {
        let bike = q.map { GarageBike(id: "b1", ssid: $0.ssid, name: "Test", profileHint: hint) }
        let s = BikeCandidates.signals(qr: q, bike: bike, hasProfileOverride: override, learned: canvas, live: l.map(live))
        return BikeCandidates.resolve(s)
    }

    private func size(_ w: Int, _ h: Int) -> LearnedDashSize { LearnedDashSize(width: w, height: h) }

    // MARK: Rule 1: canvas

    func testDecisiveCanvases() {
        XCTAssertEqual(BikeCandidates.family(forCanvas: size(720, 712)), .nkAdvanced)
        XCTAssertEqual(BikeCandidates.family(forCanvas: size(720, 704)), .nkAdvanced)
        XCTAssertEqual(BikeCandidates.family(forCanvas: size(1280, 576)), .cfdl26Landscape)
        XCTAssertEqual(BikeCandidates.family(forCanvas: size(800, 951)), .cfdl26Portrait)
        XCTAssertEqual(BikeCandidates.family(forCanvas: size(800, 944)), .cfdl26Portrait)
        XCTAssertEqual(BikeCandidates.family(forCanvas: size(544, 512)), .clc450)
        XCTAssertEqual(BikeCandidates.family(forCanvas: size(1024, 464)), .morini)
        XCTAssertEqual(BikeCandidates.family(forCanvas: size(800, 400)), .motoplayLandscape)
        XCTAssertNil(BikeCandidates.family(forCanvas: size(800, 386)), "800×384 is shared: falls through")
        XCTAssertNil(BikeCandidates.family(forCanvas: size(800, 384)))
        XCTAssertNil(BikeCandidates.family(forCanvas: size(1280, 720)), "not decisive")
        XCTAssertNil(BikeCandidates.family(forCanvas: size(640, 480)))
    }

    func testTheCanvasWinsOverEverythingElse() {
        let list = resolve(qr: qr("37416"), hint: .legacy, canvas: size(544, 512), live: Self.fixtureA)
        XCTAssertEqual(list.families, [.clc450])
        XCTAssertEqual(list.source, .canvas)
        XCTAssertEqual(list.ids, ["cfmoto-450cl-c"])
        XCTAssertEqual(list.preselectedId, "cfmoto-450cl-c")
        XCTAssertEqual(list.brand, .cfmoto)
    }

    // MARK: Live markers

    func testLiveMarkersOfEveryFamilyAndOfTheFixtures() {
        XCTAssertEqual(BikeCandidates.liveMarkers(info(Self.fixtureA)), [.legacy])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(Self.fixtureB)), [.nkAdvanced, .cfdl26Landscape, .cfdl26Portrait])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(Self.fixtureC)), [.nkAdvanced, .cfdl26Landscape, .cfdl26Portrait])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(Self.fixtureD)), [.nkAdvanced, .cfdl26Landscape, .cfdl26Portrait])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(Self.fixtureE)), [.nk800])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(Self.fixtureF)), [.morini])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(Self.fixtureG)), [.clc450])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(Self.fixtureH)), [.motoplayLandscape])
        for quirk in [Self.fixtureI, Self.fixtureJ, Self.fixtureK, Self.fixtureL] {
            XCTAssertEqual(BikeCandidates.liveMarkers(info(quirk)), [], quirk)
        }
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"sdkVersion":"0.9.29.3"}"#)), [.legacy])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"channel":" 37416 "}"#)), [.legacy])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"sdkVersion":"0.9.23.1","package_name":"linux_no_package"}"#)), [.nk800])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"HUID":"6KWV1"}"#)), [.nkAdvanced])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"package_name":"com.cfmoto.easyconnect"}"#)),
                       [.nkAdvanced, .cfdl26Landscape, .cfdl26Portrait])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"package_name":"x.CFDash.y"}"#)), [.cfdl26Landscape, .cfdl26Portrait])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"version_name":"CFDL26.1","HUID":"carb9"}"#)), [.nkAdvanced, .morini],
                       "a CARB dash is not CFDL26")
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"HUName":"x-48fb4c"}"#)), [.clc450])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"channel":"21322"}"#)), [.morini])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"flavor":51}"#)), [.morini])
        XCTAssertEqual(BikeCandidates.liveMarkers(info(#"{"flavor":65540}"#)), [])
    }

    func testSignalsFromAClientInfoFixture() {
        let s = BikeCandidates.signals(qr: qr("37416"), bike: GarageBike(id: "b1", ssid: "CFMOTO-a1b2c3", name: "x", profileHint: .legacy),
                                       hasProfileOverride: false, learned: size(800, 386), live: live(Self.fixtureA))
        XCTAssertEqual(s.qrModelId, "37416")
        XCTAssertEqual(s.ssid, "CFMOTO-a1b2c3")
        XCTAssertFalse(s.supportsP2p)
        XCTAssertEqual(s.profileHint, .legacy)
        XCTAssertEqual(s.learnedCanvas, size(800, 386))
        XCTAssertEqual(s.liveWinner, .legacy)
        XCTAssertEqual(s.liveMarkers, [.legacy])
        XCTAssertNil(s.flavor)
        XCTAssertFalse(s.moriniQR)
        let f = BikeCandidates.signals(qr: nil, bike: nil, hasProfileOverride: false, learned: nil, live: live(Self.fixtureF))
        XCTAssertEqual(f.liveWinner, .morini)
        XCTAssertEqual(f.flavor, 51)
        let none = BikeCandidates.signals(qr: nil, bike: nil, hasProfileOverride: false, learned: nil, live: live("not json"))
        XCTAssertNil(none.liveWinner)
        XCTAssertEqual(none.liveMarkers, [])
        let p2p = BikeCandidates.signals(qr: qr("37426", ssid: "DIRECT-xy"), bike: nil, hasProfileOverride: false, learned: nil, live: nil)
        XCTAssertTrue(p2p.supportsP2p)
        let moriniRaw = BikeQR.parse("http://www.motomorini.com/app?modelid=00297&ssid=ML_12ab&pwd=demo1234")
        if let moriniRaw {
            XCTAssertTrue(BikeCandidates.signals(qr: moriniRaw, bike: nil, hasProfileOverride: false, learned: nil, live: nil).moriniQR)
        }
    }

    // MARK: Rule 2: corroborated live winner

    func testCorroboratedLiveWinners() {
        let unknown = qr("12345", ssid: "DASH-1")
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureA).families, [.legacy])
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureA).source, .clientInfo)
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureB).families, [.cfdl26Portrait])
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureC).ids, BikeCandidates.ambiguous37426)
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureD).ids, BikeCandidates.ambiguous37426)
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureD).families, [.cfdl26Landscape, .nkAdvanced])
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureE).families, [.nk800])
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureF).families, [.morini])
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureF).brand, .morini)
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureG).families, [.clc450])
        XCTAssertEqual(resolve(qr: unknown, live: Self.fixtureH).families, [.motoplayLandscape])
        // a winner claimed by the QR modelId is corroborated without markers
        XCTAssertEqual(resolve(qr: qr("66660742"), live: #"{"sdkVersion":"0.9.30"}"#).families, [.motoplayLandscape])
    }

    func testTheScoringQuirksNeverGiveANonCfmotoDashACfmotoList() {
        let unknown = qr("12345", ssid: "TRK-502X")
        for quirk in [Self.fixtureI, Self.fixtureJ, Self.fixtureK, Self.fixtureL] {
            let winner = BikeProfiles.select(info: info(quirk), override: nil, log: false).id
            // the hint `refine` would persist is that winner
            let list = resolve(qr: unknown, hint: winner, live: quirk)
            XCTAssertEqual(list.ids, [], quirk)
            XCTAssertEqual(list.families, [], quirk)
            XCTAssertNil(list.preselectedId, quirk)
            XCTAssertNil(list.brand, quirk)
            let wide = resolve(qr: unknown, hint: winner, canvas: size(1280, 720), live: quirk)
            XCTAssertEqual(wide.ids, [], "\(quirk) + 1280×720")
            XCTAssertNil(wide.preselectedId)
            // persisted data only (no session)
            XCTAssertEqual(resolve(qr: unknown, hint: winner).ids, [], quirk)
        }
        // a bare non-touch CLIENT_INFO: Morini wins at 1, uncorroborated
        XCTAssertEqual(BikeProfiles.select(info: info("{}"), override: nil, log: false).id, .morini)
        XCTAssertEqual(resolve(qr: unknown, live: "{}").ids, [])
        // a per-bike override makes the hint the override: not evidence
        XCTAssertEqual(resolve(qr: unknown, hint: .nkAdvanced, override: true).ids, [])
        XCTAssertEqual(resolve(qr: qr("37416"), hint: .nkAdvanced, override: true).families, [.legacy], "rule 4 still applies")
    }

    // MARK: Rule 3: the persisted hint

    func testHintsNeedCorroboration() {
        XCTAssertEqual(resolve(qr: qr("12345", ssid: "DASH-9"), hint: .motoplayLandscape).ids, [], "hint without 66660742")
        XCTAssertEqual(resolve(qr: qr("66660742", ssid: "DASH-9"), hint: .motoplayLandscape).source, .profileHint)
        // legacy: corroborated by 37416, a CFMOTO SSID or a live legacy marker — never by itself
        XCTAssertEqual(resolve(qr: qr("37416", ssid: "DASH-9"), hint: .legacy).source, .profileHint)
        XCTAssertEqual(resolve(qr: qr(nil, ssid: "CFMOTO-f0e1"), hint: .legacy).families, [.legacy])
        XCTAssertEqual(resolve(qr: qr(nil, ssid: "cfmoto-f0e1"), hint: .legacy).families, [.legacy])
        XCTAssertEqual(resolve(qr: qr(nil, ssid: "TRK-502X"), hint: .legacy, live: #"{"HUName":"CFDL16-X"}"#).families, [.legacy])
        XCTAssertEqual(resolve(qr: qr(nil, ssid: "TRK-502X"), hint: .legacy).ids, [], "a TRK… SSID without modelId")
        XCTAssertEqual(resolve(qr: qr("37426", ssid: "DASH-9"), hint: .cfdl26Landscape).ids, BikeCandidates.ambiguous37426)
        XCTAssertEqual(resolve(qr: qr("37426", ssid: "DASH-9"), hint: .nkAdvanced).source, .profileHint)
        XCTAssertEqual(resolve(qr: qr("37426", ssid: "DASH-9"), hint: .cfdl26Portrait).ids, ["cfmoto-800mt-x", "cfmoto-1000mt-x"])
    }

    // MARK: Rule 4: the QR modelId

    func testQRModelIds() {
        XCTAssertEqual(resolve(qr: qr("37416")).families, [.legacy])
        XCTAssertEqual(resolve(qr: qr("37416")).source, .qr)
        let ap = resolve(qr: qr("37426"))
        XCTAssertEqual(ap.ids, ["cfmoto-800mt-explore", "cfmoto-800nk-advanced", "cfmoto-800mt", "cfmoto-800mt-x", "cfmoto-1000mt-x"])
        XCTAssertNil(ap.preselectedId)
        XCTAssertEqual(ap.brand, .cfmoto)
        XCTAssertEqual(resolve(qr: qr("37426", action: 9)).families, [.cfdl26Portrait], "P2P bit")
        XCTAssertEqual(resolve(qr: qr("37426", ssid: "DIRECT-ab")).families, [.cfdl26Portrait])
        XCTAssertEqual(resolve(qr: qr("66660742")).families, [.motoplayLandscape])
        XCTAssertEqual(resolve(qr: qr("66660736")).ids, ["cfmoto-450cl-c"])
        XCTAssertEqual(resolve(qr: qr("CLC450")).ids, ["cfmoto-450cl-c"])
        let nk = resolve(qr: qr("66660703"))
        XCTAssertEqual(nk.ids, ["cfmoto-800nk", "cfmoto-450nk"])
        XCTAssertNil(nk.preselectedId)
        XCTAssertEqual(resolve(qr: qr("21333", ssid: "DASH")).families, [.morini])
        let unknown = resolve(qr: qr("12345", ssid: "DASH"))
        XCTAssertEqual(unknown.ids, [], "an unknown modelId is not legacy")
        XCTAssertEqual(unknown.source, .none)
        XCTAssertNil(unknown.brand)
        XCTAssertEqual(resolve(qr: qr("12345", ssid: "CFMOTO-x")).brand, .cfmoto, "a CFMOTO SSID still prefilters the search")
        XCTAssertEqual(resolve(qr: nil).ids, [])
    }

    // MARK: Rule 5: Morini brand

    func testMoriniBrand() {
        XCTAssertEqual(resolve(qr: qr("12345", ssid: "MLN_abc")).families, [.morini])
        XCTAssertEqual(resolve(qr: qr("00297", ssid: "ML_x1")).families, [.morini])
        XCTAssertEqual(resolve(qr: qr("00297", ssid: "ML_x1")).source, .brand)
        XCTAssertEqual(resolve(qr: qr("12345", ssid: "MLX-1")).ids, [], "MLX… + 12345 is not Morini")
        var s = BikeSignals(qrModelId: "12345", ssid: "DASH")
        s.flavor = 51
        XCTAssertEqual(BikeCandidates.resolve(s).families, [.morini])
        XCTAssertEqual(BikeCandidates.resolve(BikeSignals(qrModelId: "12345", ssid: "DASH", moriniQR: true)).families, [.morini])
        let m = BikeCandidates.resolve(BikeSignals(qrModelId: "12345", ssid: "MLN_1"))
        XCTAssertEqual(m.ids, ["motomorini-x-cape-650", "motomorini-x-cape-700", "motomorini-seiemmezzo"])
        XCTAssertEqual(m.brand, .morini)
        XCTAssertNil(m.preselectedId)
        var flavorCF = BikeSignals(qrModelId: "12345", ssid: "DASH")
        flavorCF.flavor = 65540
        XCTAssertEqual(BikeCandidates.resolve(flavorCF).ids, [])
        XCTAssertEqual(BikeCandidates.resolve(flavorCF).brand, .cfmoto)
    }

    // MARK: Sequences

    func testThe800NKAdvancedFirstConnect() {
        // CLIENT_INFO (D) arrived, the early profile was landscape and `refine` kept it: hint landscape.
        let before = resolve(qr: qr("37426"), hint: .cfdl26Landscape, live: Self.fixtureD)
        XCTAssertEqual(before.ids, BikeCandidates.ambiguous37426)
        XCTAssertNil(before.preselectedId)
        // persisted data only (the session died between CLIENT_INFO and REQ 16)
        XCTAssertEqual(resolve(qr: qr("37426"), hint: .cfdl26Landscape).ids, BikeCandidates.ambiguous37426)
        // REQ 16 taught the canvas: decisive
        let after = resolve(qr: qr("37426"), hint: .cfdl26Landscape, canvas: size(720, 712), live: Self.fixtureD)
        XCTAssertEqual(after.ids, ["cfmoto-800nk-advanced"])
        XCTAssertEqual(after.preselectedId, "cfmoto-800nk-advanced")
        XCTAssertEqual(after.source, .canvas)
    }

    func testTheOwnersCase() {
        // 37416 QR, 800×386 learned (falls through), hint legacy, live CFDL16 CLIENT_INFO
        for liveJSON in [Optional(Self.fixtureA), nil] {
            let list = resolve(qr: qr("37416", ssid: "CFMOTO-f46457"), hint: .legacy, canvas: size(800, 386), live: liveJSON)
            XCTAssertEqual(list.families, [.legacy])
            XCTAssertEqual(list.ids, ["cfmoto-450mt", "cfmoto-450sr", "cfmoto-450nk", "cfmoto-675nk", "cfmoto-675sr-r",
                                      "cfmoto-700mt-18l", "cfmoto-700mt-20l", "cfmoto-300sr"])
            XCTAssertEqual(list.ids.first, "cfmoto-450mt")
            XCTAssertNil(list.preselectedId)
            XCTAssertEqual(list.brand, .cfmoto)
        }
    }

    func testIdsAreFilteredToTheCatalogAndDeduplicated() {
        let only = Array(FuelCatalog.all.filter { $0.id != "cfmoto-450sr" })
        let list = BikeCandidates.resolve(BikeSignals(qrModelId: "37416"), catalog: only)
        XCTAssertFalse(list.ids.contains("cfmoto-450sr"))
        XCTAssertEqual(list.ids.count, 7)
        for family in BikeProfileID.allCases {
            let ids = BikeCandidates.resolve(BikeSignals(learnedCanvas: nil, liveWinner: family, liveMarkers: [family])).ids
            XCTAssertFalse(ids.contains("cfmoto-700cl-x"), "\(family)")
            XCTAssertEqual(Set(ids).count, ids.count)
        }
        XCTAssertEqual(BikeCandidates.visibleBeforeMore, 4)
    }
}
