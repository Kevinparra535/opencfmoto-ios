// SPDX-License-Identifier: AGPL-3.0-or-later
// Vectors: docs/spec/control-plane.md §12.3, §12.5, §12.6 (scoring table), §12.7
// (test/BikeProfileSelectTest.kt); media-video.md §7.2 (encoder values).
import XCTest
@testable import OpenCfMotoCore

final class ProfileSelectionTests: XCTestCase {
    private func info(_ json: String) -> BikeClientInfo {
        guard let i = BikeClientInfo.parse(json) else { fatalError("bad JSON \(json)") }
        return i
    }

    /// Registry order: Nk800, NkTouch, Morini, MP-66, ClC450, Land, Port, Legacy.
    private func assertScores(_ json: String, _ expected: [Int], selects: BikeProfileID,
                              file: StaticString = #filePath, line: UInt = #line) {
        let i = info(json)
        XCTAssertEqual(BikeProfiles.registry.map { $0.score(i) }, expected, "scores", file: file, line: line)
        XCTAssertEqual(BikeProfiles.select(info: i, override: nil, log: false).id, selects, "selection", file: file, line: line)
    }

    // MARK: §12.6 table (rows A–L)

    func testCaseA_675SR_CFDL16() {
        assertScores(#"{"HUID":"6GUVA2C00100055","HUName":"CFDL16-6GUV","sdkVersion":"0.9.29.1","supportFunction":0}"#,
                     [0, 0, 1, 3, 0, -1, 0, 8], selects: .legacy)
    }

    func testCaseB_1000MTX() {
        assertScores(#"{"HUID":"6WX0AT231300200","package_name":"com.cfmoto.cfdashmotoplay","version_name":"CFDL26.2.3.5.0.6","sdkVersion":"1.1.4","enableSockServerAuth":true,"supportScreenTouch":true,"supportMirrorOverlayTouch":true,"supportFunction":128}"#,
                     [0, 11, 0, 0, 0, 9, 12, 1], selects: .cfdl26Portrait)
    }

    func testCaseC_800MT_AP() {
        assertScores(#"{"HUID":"6WWV00000001","package_name":"com.cfmoto.easyconnect","version_name":"CFDL26.2.3.0.5","sdkVersion":"1.1.2","enableSockServerAuth":true,"supportScreenTouch":true,"supportLandscapeAdaptive":true,"supportFunction":128}"#,
                     [0, 9, 0, 1, 0, 19, 9, 1], selects: .cfdl26Landscape)
    }

    func testCaseD_800NKAdvanced() {
        assertScores(#"{"HUID":"6KWV00000001","package_name":"com.cfmoto.easyconnect","version_name":"CFDL26.2.3.0.5","sdkVersion":"1.1.2","enableSockServerAuth":true,"supportScreenTouch":true,"supportMirrorOverlayTouch":true,"supportFunction":128}"#,
                     [0, 18, 0, 0, 0, 12, 9, 1], selects: .nkAdvanced)
    }

    func testCaseE_US800NK() {
        assertScores(#"{"HUID":"CRCP230501740","package_name":"linux_no_package","sdkVersion":"0.9.23.4","supportFunction":128}"#,
                     [9, 0, 1, 3, 1, -1, 0, 1], selects: .nk800)
    }

    func testCaseF_Morini() {
        assertScores(#"{"HUID":"CARB12345678","channel":"21333","flavor":51,"package_name":"","sdkVersion":"1.0.13.1"}"#,
                     [0, 2, 30, 1, 0, 0, 0, 1], selects: .morini)
    }

    func testCaseG_CLC450() {
        assertScores(#"{"HUName":"CFMOTO-48FB4C","channel":"66660736","sdkVersion":"0.9.23.4"}"#,
                     [0, 0, 1, 3, 13, -1, 0, 1], selects: .clc450)
    }

    func testCaseH_MotoPlay66660742() {
        assertScores(#"{"channel":"66660742","sdkVersion":"0.9.25.1","supportLandscapeAdaptive":true}"#,
                     [0, -4, 1, 14, 0, -1, 0, 1], selects: .motoplayLandscape)
    }

    func testCaseI_UnknownNonTouchSdk12SelectsNkTouchQuirk() {
        assertScores(#"{"sdkVersion":"1.2.0"}"#, [0, 2, 1, 1, 0, -1, 0, 1], selects: .nkAdvanced)
    }

    func testCaseJ_UnknownNonTouchSdk0930() {
        assertScores(#"{"sdkVersion":"0.9.30"}"#, [0, 0, 1, 3, 0, -1, 0, 1], selects: .motoplayLandscape)
    }

    func testCaseK_UnknownTouchSdk12() {
        assertScores(#"{"sdkVersion":"1.2.0","supportScreenTouch":true}"#, [0, 3, 0, 0, 0, 0, 0, 1], selects: .nkAdvanced)
    }

    func testCaseL_NewerCFDL16Family() {
        assertScores(#"{"version_name":"CFDL06.6.10","package_name":"net.easyconn","sdkVersion":"0.9.25.1","supportFunction":128}"#,
                     [0, 0, 1, 3, 0, -1, 0, 1], selects: .motoplayLandscape)
    }

    // MARK: Rule details

    func testLegacyChannelIsTrimmedAndOthersAreExact() {
        XCTAssertEqual(BikeProfile.legacy.score(info(#"{"channel":" 37416 "}"#)), 3)
        XCTAssertEqual(BikeProfile.legacy.score(info(#"{"channel":37416,"HUName":"CFDL16-x","sdkVersion":"0.9.29.1"}"#)), 10)
        XCTAssertEqual(BikeProfile.morini.score(info(#"{"channel":" 21333","supportScreenTouch":true}"#)), 0)
        XCTAssertEqual(BikeProfile.motoplayLandscape.score(info(#"{"channel":66660742,"supportScreenTouch":true}"#)), 10)
    }

    func testCaseInsensitiveRules() {
        XCTAssertEqual(BikeProfile.cfdl26Portrait.score(info(#"{"HUID":"carb1","version_name":"CFDL26"}"#)), 0)
        XCTAssertEqual(BikeProfile.cfdl26Landscape.score(info(#"{"HUID":"Carb1","version_name":"CFDL26"}"#)), 0)
        XCTAssertEqual(BikeProfile.morini.score(info(#"{"HUID":"cArB1","supportScreenTouch":true}"#)), 9) // +8 CARB, +1 empty package once s > 0
        XCTAssertEqual(BikeProfile.clc450.score(info(#"{"HUName":"x48fb4cx"}"#)), 4)
        // looks26 via package containing "CFMOTO" / "cfdash" in any case.
        XCTAssertEqual(BikeProfile.cfdl26Landscape.score(info(#"{"package_name":"com.CFMOTO.x","sdkVersion":"1.0","supportScreenTouch":true}"#)), 2)
        XCTAssertEqual(BikeProfile.cfdl26Portrait.score(info(#"{"package_name":"x.CfDash","sdkVersion":"2"}"#)), 2)
        // Case-sensitive prefixes.
        XCTAssertEqual(BikeProfile.nk800.score(info(#"{"HUID":"crcp1"}"#)), 0)
        XCTAssertEqual(BikeProfile.legacy.score(info(#"{"HUName":"cfdl16"}"#)), 1)
    }

    func testSupportFunctionBonusOnlyWhenAlreadyClaimed() {
        XCTAssertEqual(BikeProfile.cfdl26Portrait.score(info(#"{"supportFunction":128}"#)), 0)
        XCTAssertEqual(BikeProfile.nkAdvanced.score(info(#"{"supportFunction":"128","sdkVersion":"1.1"}"#)), 3)
        XCTAssertEqual(BikeProfile.cfdl26Landscape.score(info(#"{"supportFunction":128,"supportScreenTouch":true}"#)), 0)
    }

    func testNk800RequiresCrcpOrSdkPlusPackage() {
        XCTAssertEqual(BikeProfile.nk800.score(info(#"{"sdkVersion":"0.9.23.9"}"#)), 0)
        XCTAssertEqual(BikeProfile.nk800.score(info(#"{"package_name":"linux_no_package"}"#)), 0)
        XCTAssertEqual(BikeProfile.nk800.score(info(#"{"sdkVersion":"0.9.23.9","package_name":"linux_no_package"}"#)), 5)
        XCTAssertEqual(BikeProfile.nk800.score(info(#"{"HUID":"CRCP1"}"#)), 4)
    }

    func testTieGoesToFirstInRegistryAndNoPositiveScoreFallsBackToLegacy() {
        // Morini (+1 not-touch) and MP-66 (+1 not-touch) tie at 1 with Legacy's floor 1: Morini is earlier.
        let i = info(#"{"HUID":"zzz"}"#)
        XCTAssertEqual(BikeProfiles.registry.map { $0.score(i) }, [0, 0, 1, 1, 0, -1, 0, 1])
        XCTAssertEqual(BikeProfiles.select(info: i, override: nil, log: false).id, .morini)
        XCTAssertEqual(BikeProfiles.scoresDescription(for: i).prefix(46), "[profile] scores=CFMoto 800NK (CRCP / sdk 0.9.")
    }

    func testManualOverrideWins() {
        let i = info(#"{"HUID":"CRCP230501740","package_name":"linux_no_package","sdkVersion":"0.9.23.4"}"#)
        XCTAssertEqual(BikeProfiles.select(info: i, override: .cfdl26Portrait, log: false), .cfdl26Portrait)
        XCTAssertEqual(BikeProfiles.selectByQR(BikeQR(raw: "x", ssid: "CFMOTO-1", password: "p", modelId: "37416"),
                                               override: .clc450), .clc450)
    }

    // MARK: §12.7 repo vectors

    func testRepoVectors() {
        XCTAssertTrue(BikeProfile.nk800.matchesModelId("66660703"))
        XCTAssertTrue(BikeProfile.nk800.matchesModelId("66660721"))
        XCTAssertTrue(BikeProfile.nk800.matchesModelId("66660732"))
        XCTAssertFalse(BikeProfile.nk800.matchesModelId("37426"))
        XCTAssertFalse(BikeProfile.nk800.matchesModelId("37416"))
        XCTAssertEqual(BikeProfiles.selectByModelId("66660703"), .nk800)
        XCTAssertEqual(BikeProfiles.selectByModelId("37426"), .nkAdvanced) // first registry hit
        XCTAssertEqual(BikeProfiles.selectByModelId(nil), .legacy)
        XCTAssertEqual(BikeProfiles.selectByModelId("999"), .legacy)
        XCTAssertFalse(BikeProfile.cfdl26Portrait.supportsScreenTouch)
        XCTAssertTrue(BikeProfile.cfdl26Landscape.supportsScreenTouch)
        XCTAssertFalse(BikeProfile.nk800.supportsScreenTouch)
    }

    // MARK: §12.3 attributes

    func testProfileAttributes() {
        XCTAssertEqual(BikeProfiles.registry.map(\.id),
                       [.nk800, .nkAdvanced, .morini, .motoplayLandscape, .clc450, .cfdl26Landscape, .cfdl26Portrait, .legacy])
        XCTAssertEqual(BikeProfile.legacy.name, "CFDL16 / legacy (BIKE A)")
        XCTAssertEqual(BikeProfile.nkAdvanced.defaultMargins, ScreenMargins(top: 22))
        for p in BikeProfiles.registry where p.id != .nkAdvanced {
            XCTAssertEqual(p.defaultMargins, .zero, p.name)
        }
        XCTAssertEqual(BikeProfile.cfdl26Portrait.panelSize, .init(width: 800, height: 951))
        XCTAssertEqual(BikeProfile.cfdl26Landscape.panelSize, .init(width: 1280, height: 576))
        XCTAssertEqual(BikeProfile.clc450.panelSize, .init(width: 544, height: 512))
        XCTAssertEqual(BikeProfile.morini.panelSize, .init(width: 1024, height: 464))
        XCTAssertEqual(BikeProfile.motoplayLandscape.panelSize, .init(width: 800, height: 400))
        XCTAssertNil(BikeProfile.legacy.panelSize)
        XCTAssertNil(BikeProfile.nk800.panelSize)
        XCTAssertEqual(BikeProfile.clc450.qrModelIds, ["66660736", "CLC450"])
        XCTAssertTrue(BikeProfile.clc450.matchesModelId(" CLC450 "))
        XCTAssertEqual(BikeProfile.morini.qrModelIds, ["21333", "21322"])
        for id in BikeProfileID.allCases { XCTAssertEqual(BikeProfile.profile(id).id, id) }
    }

    func testEncoderDefaults() {
        XCTAssertEqual(BikeProfile.legacy.encoderDefaults,
                       EncoderParameters(bitrate: 2_500_000, frameRate: 30, keyframeIntervalSeconds: 1, forceBaseline: true, repeatLastFrameAfter: 0.9))
        XCTAssertEqual(BikeProfile.morini.encoderDefaults,
                       EncoderParameters(bitrate: 2_000_000, frameRate: 10, keyframeIntervalSeconds: 2, forceBaseline: false, repeatLastFrameAfter: 0.9))
        for p in BikeProfiles.registry where p.id != .morini {
            XCTAssertTrue(p.forceBaseline)
            XCTAssertEqual(p.videoBitrate, 2_500_000)
        }
    }

    // MARK: §12.5 early selection from the QR

    private func qr(ssid: String, modelId: String?, action: Int = 1) -> BikeQR {
        BikeQR(raw: "http://x?ssid=\(ssid)", ssid: ssid, password: "12345678", action: action, modelId: modelId)
    }

    func testQRGuess() {
        XCTAssertEqual(BikeProfiles.selectByQR(nil, override: nil), .legacy)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO-f46457", modelId: "37416"), override: nil), .legacy)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO-1381DA", modelId: "66660703"), override: nil), .nk800)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO-x", modelId: "66660742"), override: nil), .motoplayLandscape)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO-x", modelId: "66660736"), override: nil), .clc450)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO-x", modelId: "123"), override: nil), .legacy)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO-x", modelId: nil), override: nil), .legacy)
        // 37426: P2P bit or DIRECT- SSID → Portrait, else Landscape (never NkTouch from the QR).
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO1565", modelId: "37426", action: 1), override: nil), .cfdl26Landscape)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO1565", modelId: "37426", action: 9), override: nil), .cfdl26Portrait)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "DIRECT-CF-CFMOTO-805120", modelId: "37426"), override: nil), .cfdl26Portrait)
        // Morini SSIDs.
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "MLN_p2p_7017", modelId: nil), override: nil), .morini)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "mln_x", modelId: "37426"), override: nil), .morini)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "ML174167", modelId: "00297"), override: nil), .morini)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "ml174167", modelId: "21333"), override: nil), .morini)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "ML174167", modelId: "37416"), override: nil), .legacy)
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO", modelId: "21322"), override: nil), .morini) // modelId match
    }

    func testLearnedGeometryWrapper() {
        let q = qr(ssid: "CFMOTO1565", modelId: "37426") // → Landscape (1280×576)
        // Same as the base panel → base.
        XCTAssertEqual(BikeProfiles.selectByQR(q, override: nil, learnedCanvas: .rounded(requestedWidth: 1280, requestedHeight: 576)),
                       .cfdl26Landscape)
        // Measured 720×712 (800NK Advanced): wrapped, near-square → not wide.
        let learned = BikeProfiles.selectByQR(q, override: nil, learnedCanvas: .rounded(requestedWidth: 720, requestedHeight: 712))
        XCTAssertEqual(learned.id, .cfdl26Landscape)
        XCTAssertTrue(learned.isLearnedGeometry)
        XCTAssertEqual(learned.name, "CFDL26 / MotoPlay Landscape (800MT) + measured 720x712")
        XCTAssertEqual(learned.panelSize, .init(width: 720, height: 712))
        XCTAssertFalse(learned.panelSize!.isWide)
        XCTAssertEqual(learned.supportFunction, 128)
        XCTAssertTrue(learned.appendsScreenTouchKey)
        XCTAssertEqual(learned.base, .cfdl26Landscape)
        // 800×951 has no AA best fit → keep the base.
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "DIRECT-x", modelId: "37426"), override: nil,
                                               learnedCanvas: .rounded(requestedWidth: 800, requestedHeight: 951)), .cfdl26Portrait)
        // Learned geometry is ignored without a QR, and invalid sizes are ignored.
        XCTAssertEqual(BikeProfiles.selectByQR(nil, override: nil, learnedCanvas: .rounded(requestedWidth: 720, requestedHeight: 712)), .legacy)
        XCTAssertEqual(BikeProfiles.selectByQR(q, override: nil, learnedCanvas: VideoCanvas(width: 0, height: 0)), .cfdl26Landscape)
        // Legacy (no panel) + measured 800×386 → wrapped.
        XCTAssertEqual(BikeProfiles.selectByQR(qr(ssid: "CFMOTO-f46457", modelId: "37416"), override: nil,
                                               learnedCanvas: .rounded(requestedWidth: 800, requestedHeight: 386)).panelSize,
                       .init(width: 800, height: 386))
    }

    func testBestFitVectors() {
        XCTAssertEqual(BikeProfiles.learnedGeometryFit(width: 1280, height: 576).map { [$0.width, $0.height] }, [1280, 720])
        XCTAssertEqual(BikeProfiles.learnedGeometryFit(width: 720, height: 712).map { [$0.width, $0.height] }, [720, 1280])
        XCTAssertEqual(BikeProfiles.learnedGeometryFit(width: 800, height: 386).map { [$0.width, $0.height] }, [800, 480])
        XCTAssertNil(BikeProfiles.learnedGeometryFit(width: 800, height: 951))
        XCTAssertNil(BikeProfiles.learnedGeometryFit(width: 544, height: 512))
    }

    // MARK: Keep-landscape refinement

    func testKeepLandscapeRefinement() {
        let d = info(#"{"HUID":"6KWV00000001","package_name":"com.cfmoto.easyconnect","version_name":"CFDL26.2.3.0.5","sdkVersion":"1.1.2","enableSockServerAuth":true,"supportScreenTouch":true,"supportMirrorOverlayTouch":true,"supportFunction":128}"#)
        let selected = BikeProfiles.select(info: d, override: nil, log: false)
        XCTAssertEqual(selected, .nkAdvanced)
        // Early Landscape (1280×576 wide) keeps itself against NkTouch.
        XCTAssertEqual(BikeProfiles.refine(early: .cfdl26Landscape, selected: selected), .cfdl26Landscape)
        // A learned near-square panel lets CLIENT_INFO upgrade to NkTouch.
        let learned = BikeProfile.cfdl26Landscape.withMeasuredPanel(.init(width: 720, height: 712))
        XCTAssertEqual(BikeProfiles.refine(early: learned, selected: selected), .nkAdvanced)
        // Non-wide or panel-less early profiles never block, and other selections are untouched.
        XCTAssertEqual(BikeProfiles.refine(early: .legacy, selected: selected), .nkAdvanced)
        XCTAssertEqual(BikeProfiles.refine(early: .cfdl26Portrait, selected: selected), .nkAdvanced)
        XCTAssertEqual(BikeProfiles.refine(early: .cfdl26Landscape, selected: .cfdl26Portrait), .cfdl26Portrait)
        // Morini 1024×464 and MP-66 800×400 are wide too.
        XCTAssertEqual(BikeProfiles.refine(early: .morini, selected: selected), .morini)
        XCTAssertTrue(BikeProfile.PanelSize(width: 1280, height: 576).isWide)
        XCTAssertTrue(BikeProfile.PanelSize(width: 3, height: 2).isWide)
        XCTAssertFalse(BikeProfile.PanelSize(width: 800, height: 951).isWide)
    }

    func testContextAppliesRefinementAndBuildsReplyWithNewProfile() {
        let ctx = LinkSessionContext(phone: LinkTestKeys.examplePhone, signer: LinkTestKeys.fixtureSigner,
                                     initialProfile: .cfdl26Landscape)
        let d = info(#"{"HUID":"6KWV00000001","package_name":"com.cfmoto.easyconnect","version_name":"CFDL26.2.3.0.5","sdkVersion":"1.1.2","enableSockServerAuth":true,"supportScreenTouch":true,"supportMirrorOverlayTouch":true,"supportFunction":128}"#)
        let (profile, reply, dash) = ctx.applyClientInfo(d)
        XCTAssertEqual(profile, .cfdl26Landscape) // kept
        XCTAssertEqual(ctx.activeProfile, .cfdl26Landscape)
        XCTAssertEqual(dash.profile, .cfdl26Landscape)
        XCTAssertEqual(reply["supportScreenTouch"], .bool(true))
        XCTAssertEqual(reply["supportFunction"], .int(128))
    }

    // MARK: Override ids

    func testOverrideIds() {
        XCTAssertNil(BikeProfiles.overrideID(from: nil))
        XCTAssertNil(BikeProfiles.overrideID(from: "auto"))
        XCTAssertNil(BikeProfiles.overrideID(from: "bogus"))
        XCTAssertEqual(BikeProfiles.overrideID(from: "legacy"), .legacy)
        XCTAssertEqual(BikeProfiles.overrideID(from: "nk800"), .nk800)
        XCTAssertEqual(BikeProfiles.overrideID(from: "nk_adv"), .nkAdvanced)
        XCTAssertEqual(BikeProfiles.overrideID(from: "cfdl26_land"), .cfdl26Landscape)
        XCTAssertEqual(BikeProfiles.overrideID(from: "cfdl26_port"), .cfdl26Portrait)
        XCTAssertEqual(BikeProfiles.overrideID(from: "clc450"), .clc450)
        XCTAssertEqual(BikeProfiles.overrideID(from: "morini"), .morini)
        XCTAssertEqual(BikeProfiles.overrideID(from: "motoplay_land"), .motoplayLandscape)
        XCTAssertEqual(BikeProfiles.overrideString(nil), "auto")
        XCTAssertEqual(BikeProfiles.overrideString(.nkAdvanced), "nk_adv")
        XCTAssertEqual(BikeProfiles.overrideIds.first, "auto")
        XCTAssertEqual(BikeProfiles.overrideIds.count, 1 + BikeProfileID.allCases.count)
    }
}
