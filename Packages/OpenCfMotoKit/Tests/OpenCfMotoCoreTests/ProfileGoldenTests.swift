// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden vectors produced by running VERBATIM copies of the Kotlin score() bodies of BikeProfile.kt
// (OpenCfMoto 2.0.18) on 240 randomized CLIENT_INFO objects (org.json on the JVM), including string /
// number / boolean coercion edge cases ("128", "TRUE", "yes", 1, " 37416 ", numeric channels).
// Line format: <json> | <scores in registry order> | <selected profile id>.
import XCTest
@testable import OpenCfMotoCore

final class ProfileGoldenTests: XCTestCase {
    func testScoresAndSelectionMatchKotlin() throws {
        var checked = 0
        for line in Self.vectors.split(separator: "\n") {
            let parts = line.components(separatedBy: " | ")
            XCTAssertEqual(parts.count, 3, String(line))
            let info = try XCTUnwrap(BikeClientInfo.parse(parts[0]), parts[0])
            let expected = parts[1].split(separator: ",").map { Int($0)! }
            XCTAssertEqual(BikeProfiles.registry.map { $0.score(info) }, expected, parts[0])
            XCTAssertEqual(BikeProfiles.select(info: info, override: nil, log: false).id.rawValue, parts[2], parts[0])
            checked += 1
        }
        XCTAssertEqual(checked, 240)
    }

    static let vectors = #"""
{"HUID":"6GUVA2C00100055","HUName":"CFDL16-6GUV","sdkVersion":"1.2.0"} | 0,2,1,1,0,-1,0,5 | legacy
{"sdkVersion":"","supportScreenTouch":true,"HUName":"CFMOTO-48FB4C","supportFunction":"128","version_name":"CFDL26.2.3.5.0.6","HUID":"","supportMirrorOverlayTouch":"yes"} | 0,6,0,0,4,5,5,1 | nk_adv
{"HUID":"6KWV0001","supportLandscapeAdaptive":false,"version_name":"CFDL06.6.10","supportFunction":128,"HUName":"CFMOTO-805120"} | 0,4,1,1,0,-1,0,1 | nk_adv
{"channel":66660742,"supportScreenTouch":false,"enableSockServerAuth":true,"version_name":"CFDL26.2.3.5.0.6","supportMirrorOverlayTouch":"TRUE","package_name":"x.cfdash.y","supportFunction":"128","HUName":"x48fb4cx"} | 0,8,1,11,4,6,7,1 | motoplay_land
{"HUID":"","version_name":"V1.0.18","supportLandscapeAdaptive":"true","supportScreenTouch":"yes","HUName":"cfdl16"} | 0,-4,1,2,0,-1,0,1 | motoplay_land
{"HUID":"Carb","supportLandscapeAdaptive":false,"sdkVersion":"0.9.30","supportMirrorOverlayTouch":true,"flavor":"x","supportScreenTouch":"true","HUName":"CFDL16-6GUV"} | 0,2,9,2,0,0,0,5 | morini
{"supportFunction":0,"package_name":"com.cfmoto.easyconnect","supportMirrorOverlayTouch":"false","sdkVersion":"1.1.2","flavor":"x"} | 0,5,1,1,0,4,2,1 | nk_adv
{"HUID":"6WWV0001","supportFunction":"128","flavor":65540,"HUName":"CFMOTO-48FB4C","sdkVersion":"0.9.23.4","supportLandscapeAdaptive":false,"enableSockServerAuth":1,"supportMirrorOverlayTouch":true} | 0,1,1,3,5,2,0,1 | clc450
{"HUID":"carb999","supportLandscapeAdaptive":"false","channel":"","supportScreenTouch":"true","package_name":"com.CFMOTO.x","sdkVersion":"0.9.23.4","supportFunction":0,"HUName":"cfdl16","version_name":"CFDL26.2.3.0.5"} | 0,5,8,2,1,0,0,1 | morini
{"package_name":"x.cfdash.y","supportFunction":128,"HUName":"cfdl16","sdkVersion":"1.1.2","supportLandscapeAdaptive":false,"HUID":"CRC"} | 0,3,1,1,0,2,3,1 | nk_adv
{"supportScreenTouch":1,"channel":66660742,"supportLandscapeAdaptive":"yes","supportMirrorOverlayTouch":"true","enableSockServerAuth":true,"HUID":"6KWV0001","sdkVersion":"0.","HUName":"x48fb4cx"} | 0,7,1,11,4,1,2,1 | motoplay_land
{"sdkVersion":"1.1.2","HUID":"6KWV0001","HUName":"CFDL16-6GUV","supportMirrorOverlayTouch":"false","flavor":"51","supportFunction":"x","supportLandscapeAdaptive":"true","channel":"66660736"} | 0,2,8,2,8,-1,0,5 | morini
{"sdkVersion":"0.9.23.9","enableSockServerAuth":true,"HUID":"6KWV0001","package_name":"com.cfmoto.easyconnect","HUName":"CFMOTO-805120","supportFunction":1} | 0,9,1,3,1,4,2,1 | nk_adv
{"supportLandscapeAdaptive":"yes","supportScreenTouch":"true","supportFunction":1,"channel":"21333","HUName":"","version_name":"CFDL06.6.10"} | 0,1,13,0,0,0,0,1 | morini
{"HUName":"x48fb4cx","sdkVersion":"0.9.25.1","supportFunction":1,"enableSockServerAuth":true,"channel":"66660736","HUID":"XYZ"} | 0,2,1,3,12,1,2,1 | clc450
{"package_name":"com.cfmoto.cfdashmotoplay","supportMirrorOverlayTouch":"TRUE","sdkVersion":"0.9.30","flavor":51} | 0,1,7,3,0,-1,3,1 | morini
{"flavor":"x","supportFunction":1,"sdkVersion":"0.9.29.1","enableSockServerAuth":true,"package_name":"","HUID":"6KWV0001","HUName":"CFMOTO-805120"} | 0,6,1,3,0,1,2,4 | nk_adv
{"supportLandscapeAdaptive":true,"sdkVersion":"0.9.30","HUName":"x48fb4cx","enableSockServerAuth":"TRUE","HUID":"carb999","supportFunction":"128"} | 0,-1,10,4,4,0,0,1 | morini
{"sdkVersion":"","package_name":"com.cfmoto.easyconnect","enableSockServerAuth":false,"HUName":"","flavor":"51","supportMirrorOverlayTouch":false} | 0,3,7,1,0,2,0,1 | morini
{"supportMirrorOverlayTouch":"TRUE","package_name":"net.easyconn","supportFunction":0,"version_name":"CFDL26.2.3.0.5","HUName":"CFMOTO-48FB4C","sdkVersion":"0.9.30","HUID":""} | 0,5,1,3,4,3,4,1 | nk_adv
{"package_name":"linux_no_package","HUID":"6WX0AT231300200","channel":"66660742","flavor":"x","supportMirrorOverlayTouch":"yes","supportScreenTouch":"TRUE","version_name":"CFDL26.2.3.5.0.6"} | 0,5,0,10,0,4,4,1 | motoplay_land
{"sdkVersion":"1.1.2","flavor":51,"supportScreenTouch":"true","version_name":"CFDL26.2.3.5.0.6","HUID":"CRCP230501740","channel":""} | 4,7,7,0,0,6,6,1 | nk_adv
{"sdkVersion":"0.9.23.4","HUID":"CARB1234","HUName":"","flavor":65540,"version_name":"CFDL06.6.10","supportLandscapeAdaptive":"true","channel":" 37416 "} | 0,-4,10,4,1,0,0,3 | morini
{"supportLandscapeAdaptive":"false","package_name":"com.cfmoto.cfdashmotoplay","supportFunction":"x","supportScreenTouch":false} | 0,0,1,1,0,-1,3,1 | cfdl26_port
{"sdkVersion":"0.9.30","package_name":"x.cfdash.y","enableSockServerAuth":"TRUE","HUName":"CFMOTO-805120","supportMirrorOverlayTouch":"false","HUID":""} | 0,2,1,3,0,1,2,1 | motoplay_land
{"sdkVersion":"1.0.13.1","supportScreenTouch":"yes","supportMirrorOverlayTouch":true,"HUName":"CFMOTO-48FB4C","supportFunction":0,"HUID":"CRC","channel":"21333"} | 0,3,16,1,4,-1,0,1 | morini
{"supportScreenTouch":"true","supportMirrorOverlayTouch":"TRUE","sdkVersion":"1.0.13.1","HUID":"carb999","supportLandscapeAdaptive":"TRUE","package_name":"linux_no_package","enableSockServerAuth":"true"} | 0,2,10,1,0,0,0,1 | morini
{"enableSockServerAuth":true,"sdkVersion":"0.9.29.1","version_name":"CFDL26.2.3.5.0.6","supportMirrorOverlayTouch":"true","channel":"37416","HUName":"CFMOTO-805120"} | 0,7,1,3,0,5,6,6 | nk_adv
{"enableSockServerAuth":false,"supportLandscapeAdaptive":"yes","HUName":"CFMOTO-48FB4C","sdkVersion":"","version_name":"CFDL26.2.3.0.5","supportScreenTouch":1,"HUID":"CRC","supportFunction":0} | 0,4,1,1,4,3,4,1 | nk_adv
{"sdkVersion":"0.9.23.4","HUID":"Carb","supportScreenTouch":"false","HUName":"CFDL16-6GUV","package_name":"linux_no_package","supportLandscapeAdaptive":false,"channel":"66660736","version_name":"V1.0.18","supportMirrorOverlayTouch":"yes"} | 5,0,9,3,9,0,0,5 | morini
{"sdkVersion":"0.9.23.4","package_name":"com.cfmoto.cfdashmotoplay","HUName":"cfdl16","flavor":51,"channel":"21333","supportMirrorOverlayTouch":"yes","supportFunction":128} | 0,0,19,3,1,-1,4,1 | morini
{"supportFunction":"x","sdkVersion":"1.1.2","supportMirrorOverlayTouch":"yes","supportLandscapeAdaptive":"false"} | 0,2,1,1,0,-1,0,1 | nk_adv
{"HUName":"","version_name":"V1.0.18","sdkVersion":"1.0.13.1","HUID":"6WWV0001","channel":"66660736","supportMirrorOverlayTouch":"false"} | 0,2,3,1,8,2,0,1 | clc450
{"enableSockServerAuth":"false","version_name":"CFDL26.2.3.0.5","HUName":"cfdl16","supportMirrorOverlayTouch":"false","sdkVersion":"","supportLandscapeAdaptive":"true"} | 0,0,1,2,0,7,4,1 | cfdl26_land
{"supportFunction":1,"supportScreenTouch":false,"sdkVersion":"","flavor":51,"HUName":"","channel":21333,"HUID":"6GUVA2C00100055"} | 0,0,20,1,0,-1,0,1 | morini
{"sdkVersion":"0.","HUName":"cfdl16","HUID":"6WWV0001","supportLandscapeAdaptive":false} | 0,0,1,1,0,2,0,1 | cfdl26_land
{"supportLandscapeAdaptive":"true","HUName":"x48fb4cx","HUID":"XYZ","supportMirrorOverlayTouch":true,"enableSockServerAuth":"yes","supportScreenTouch":false,"sdkVersion":"0.9.23.4"} | 0,-3,1,4,5,-1,0,1 | clc450
{"flavor":"51","HUID":"6WWV0001","supportMirrorOverlayTouch":"TRUE","supportFunction":"128","channel":21333,"version_name":"cfdl26","HUName":"","enableSockServerAuth":true,"sdkVersion":""} | 0,4,20,1,0,5,3,1 | morini
{"channel":66660742,"supportLandscapeAdaptive":"true","HUID":"6WWV0001","supportFunction":"128","enableSockServerAuth":"true","supportMirrorOverlayTouch":true} | 0,0,1,12,0,5,3,1 | motoplay_land
{"flavor":"51","package_name":"com.cfmoto.easyconnect","enableSockServerAuth":"true","HUName":"","supportMirrorOverlayTouch":"yes","sdkVersion":"0.9.29.1","supportFunction":128} | 0,6,7,3,0,5,3,4 | morini
{"version_name":"CFDL26.2.3.5.0.6","package_name":"com.CFMOTO.x","sdkVersion":"1.1.4","supportMirrorOverlayTouch":"TRUE","flavor":65540} | 0,7,1,1,0,5,6,1 | nk_adv
{"package_name":"x.cfdash.y","HUName":"CFMOTO-48FB4C","HUID":"","channel":"21333","sdkVersion":"0.9.25.1","supportLandscapeAdaptive":true,"flavor":"x","supportScreenTouch":1} | 0,-4,13,4,4,3,0,1 | morini
{"channel":37416,"sdkVersion":"0.9.25.1","package_name":"","HUName":"CFMOTO-805120","HUID":"6WX0AT231300200","enableSockServerAuth":"TRUE","flavor":"x","supportMirrorOverlayTouch":false,"supportLandscapeAdaptive":"yes"} | 0,2,1,3,0,1,2,3 | motoplay_land
{"channel":"66660742","HUID":"6GUVA2C00100055","HUName":"CFMOTO-48FB4C","supportScreenTouch":1,"sdkVersion":"0.","supportLandscapeAdaptive":true,"enableSockServerAuth":false} | 0,-4,1,12,4,-1,0,1 | motoplay_land
{"supportFunction":"128","HUName":"CFMOTO-48FB4C","version_name":"cfdl26","enableSockServerAuth":"yes","supportMirrorOverlayTouch":"true","package_name":"com.cfmoto.easyconnect","HUID":"Carb","supportScreenTouch":true,"sdkVersion":""} | 0,6,8,0,4,0,0,1 | morini
{"sdkVersion":"0.","package_name":"com.cfmoto.easyconnect","flavor":51,"channel":"21322","supportFunction":"x","supportMirrorOverlayTouch":false,"HUID":"6WWV0001","HUName":"cfdl16"} | 0,3,19,1,0,5,0,1 | morini
{"HUID":"6WWV0001","supportLandscapeAdaptive":"yes","sdkVersion":"1.0.13.1","supportFunction":"128","package_name":"com.cfmoto.cfdashmotoplay","channel":"","enableSockServerAuth":"yes","supportMirrorOverlayTouch":"yes"} | 0,3,3,1,0,5,6,1 | cfdl26_port
{"HUName":"","HUID":"6GUVA2C00100055","supportScreenTouch":1,"package_name":"x.cfdash.y","supportLandscapeAdaptive":1,"supportFunction":"128","flavor":65540,"version_name":"CFDL06.6.10","sdkVersion":"2"} | 0,3,1,1,0,2,3,1 | nk_adv
{"sdkVersion":"0.9.30","HUID":"XYZ","channel":"37416","enableSockServerAuth":true,"supportFunction":"x","HUName":"CFMOTO-805120"} | 0,2,1,3,0,1,2,3 | motoplay_land
{"supportMirrorOverlayTouch":false,"HUID":"CARB1234","channel":21333,"flavor":65540} | 0,0,22,1,0,0,0,1 | morini
{"version_name":"cfdl26","supportMirrorOverlayTouch":"false","enableSockServerAuth":"TRUE","package_name":"com.cfmoto.easyconnect","HUID":"Carb","flavor":"x"} | 0,5,9,1,0,0,0,1 | morini
{"supportFunction":1,"supportLandscapeAdaptive":1,"version_name":"CFDL26.2.3.0.5","enableSockServerAuth":1,"HUID":"6KWV0001","sdkVersion":"0.","channel":"66660742","HUName":"CFMOTO-805120"} | 0,8,1,11,0,3,4,1 | motoplay_land
{"supportScreenTouch":1,"version_name":"V1.0.18","supportMirrorOverlayTouch":"TRUE","supportFunction":1,"enableSockServerAuth":false,"HUID":"6WX0AT231300200","channel":"37416","sdkVersion":"2","package_name":"com.cfmoto.cfdashmotoplay"} | 0,3,1,1,0,1,5,3 | cfdl26_port
{"version_name":"CFDL26.2.3.0.5","HUID":"6WX0AT231300200","supportMirrorOverlayTouch":true,"enableSockServerAuth":"TRUE","supportFunction":"128","sdkVersion":"1.2.0","supportScreenTouch":true,"HUName":"x48fb4cx"} | 0,11,0,0,4,9,9,1 | nk_adv
{"HUID":"CRCP230501740","HUName":"cfdl16","package_name":"com.cfmoto.easyconnect","supportMirrorOverlayTouch":"true","sdkVersion":"0.9.29.1","supportLandscapeAdaptive":"yes"} | 4,4,1,3,0,2,0,4 | nk800
{"HUName":"cfdl16","enableSockServerAuth":1,"supportLandscapeAdaptive":"yes","package_name":"linux_no_package","sdkVersion":"","version_name":"cfdl26","supportMirrorOverlayTouch":"yes","flavor":"x","HUID":"6WWV0001"} | 0,0,1,1,0,2,0,1 | cfdl26_land
{"HUName":"","version_name":"CFDL26.2.3.5.0.6","enableSockServerAuth":true,"supportScreenTouch":"yes","sdkVersion":"0.9.30"} | 0,6,1,3,0,5,6,1 | nk_adv
{"channel":"21322","sdkVersion":"0.9.23.4","supportFunction":"x","HUName":"cfdl16","package_name":"com.cfmoto.easyconnect","HUID":"Carb"} | 0,3,21,3,1,0,0,1 | morini
{"HUID":"CRCP230501740","flavor":65540,"channel":"66660742","sdkVersion":"","enableSockServerAuth":"true","supportLandscapeAdaptive":"true","supportMirrorOverlayTouch":false,"supportFunction":1} | 4,-2,1,12,0,1,2,1 | motoplay_land
{"sdkVersion":"1.2.0","HUName":"","package_name":"","supportFunction":128,"channel":21333,"supportMirrorOverlayTouch":false,"enableSockServerAuth":"yes"} | 0,3,14,1,0,-1,0,1 | morini
{"version_name":"CFDL06.6.10","sdkVersion":"0.9.23.4","HUName":"x48fb4cx","flavor":51,"package_name":"com.CFMOTO.x"} | 0,0,7,3,5,-1,0,1 | morini
{"supportMirrorOverlayTouch":1,"version_name":"CFDL26.2.3.5.0.6","supportFunction":0,"sdkVersion":"0.9.23.4","supportLandscapeAdaptive":"yes","package_name":"com.cfmoto.easyconnect","channel":37416,"HUID":"6WWV0001","enableSockServerAuth":true,"HUName":"x48fb4cx"} | 0,9,1,3,5,11,6,3 | cfdl26_land
{"supportLandscapeAdaptive":"yes","enableSockServerAuth":1,"flavor":"x","channel":"","HUName":"CFMOTO-48FB4C","version_name":"CFDL26.2.3.5.0.6","supportFunction":1,"HUID":"6WX0AT231300200"} | 0,4,1,1,4,3,4,1 | nk_adv
{"version_name":"CFDL06.6.10","channel":37416,"supportScreenTouch":true,"HUName":"x48fb4cx","sdkVersion":"1.1.4","HUID":"6GUVA2C00100055","enableSockServerAuth":1,"supportFunction":0} | 0,3,0,0,4,0,0,3 | clc450
{"package_name":"com.cfmoto.easyconnect","enableSockServerAuth":"yes","HUID":"6WX0AT231300200","supportScreenTouch":"true","sdkVersion":"","supportLandscapeAdaptive":"true"} | 0,0,0,1,0,7,0,1 | cfdl26_land
{"HUID":"6WX0AT231300200","supportScreenTouch":"yes","supportFunction":1,"sdkVersion":"0."} | 0,0,1,1,0,-1,0,1 | morini
{"HUID":"XYZ","supportScreenTouch":"false","HUName":"CFMOTO-805120","package_name":"x.cfdash.y","flavor":65540,"supportMirrorOverlayTouch":false,"sdkVersion":"1.0.13.1","enableSockServerAuth":"yes","channel":37416,"version_name":"V1.0.18"} | 0,2,3,1,0,1,2,3 | morini
{"flavor":51,"supportScreenTouch":"false","package_name":"linux_no_package","HUName":"","HUID":"6WX0AT231300200","sdkVersion":"0.9.23.9","supportFunction":128} | 5,0,7,3,1,-1,0,1 | morini
{"sdkVersion":"1.0.13.1","version_name":"V1.0.18","package_name":"net.easyconn","channel":" 37416 ","supportFunction":1,"enableSockServerAuth":false} | 0,2,3,1,0,-1,0,3 | morini
{"channel":" 37416 ","HUID":"CARB1234","supportLandscapeAdaptive":"false","HUName":"x48fb4cx","enableSockServerAuth":1,"supportMirrorOverlayTouch":false} | 0,0,10,1,4,0,0,3 | morini
{"supportLandscapeAdaptive":"TRUE","HUName":"x48fb4cx","supportFunction":"x","supportScreenTouch":"yes","sdkVersion":"","supportMirrorOverlayTouch":1,"flavor":"51","HUID":"CARB1234","channel":"21340"} | 0,-4,16,2,4,0,0,1 | morini
{"version_name":"cfdl26","HUID":"6WWV0001","package_name":"net.easyconn","HUName":"cfdl16","supportFunction":1,"sdkVersion":"1.2.0"} | 0,2,1,1,0,2,0,1 | nk_adv
{"HUID":"6WX0AT231300200","supportMirrorOverlayTouch":"TRUE","supportLandscapeAdaptive":"yes","sdkVersion":"0.9.30","channel":"21322","supportScreenTouch":"true","enableSockServerAuth":true,"HUName":"CFMOTO-805120"} | 0,4,13,2,0,2,2,1 | morini
{"HUName":"","supportScreenTouch":"true","HUID":"","supportFunction":0,"flavor":"51","enableSockServerAuth":"TRUE","supportLandscapeAdaptive":false} | 0,3,7,0,0,2,2,1 | morini
{"flavor":65540,"HUID":"XYZ","supportLandscapeAdaptive":true,"supportScreenTouch":false,"HUName":"CFDL16-6GUV"} | 0,-4,1,2,0,-1,0,5 | legacy
{"HUName":"cfdl16","channel":66660742,"sdkVersion":"0.9.23.4","supportMirrorOverlayTouch":"yes"} | 0,0,1,13,1,-1,0,1 | motoplay_land
{"supportScreenTouch":false,"enableSockServerAuth":true,"supportFunction":1,"HUID":"6WX0AT231300200","HUName":"x48fb4cx"} | 0,2,1,1,4,1,2,1 | clc450
{"supportLandscapeAdaptive":false,"package_name":"x.cfdash.y","channel":66660742,"HUID":"6GUVA2C00100055","version_name":"CFDL26.2.3.0.5","supportMirrorOverlayTouch":true,"sdkVersion":"1.2.0","enableSockServerAuth":false} | 0,7,1,11,0,5,6,1 | motoplay_land
{"HUID":"XYZ","sdkVersion":"0.9.23.9","supportLandscapeAdaptive":"false","package_name":"","channel":"37416","supportMirrorOverlayTouch":"yes","HUName":"x48fb4cx"} | 0,0,1,3,5,-1,0,3 | clc450
{"supportLandscapeAdaptive":true,"flavor":65540,"enableSockServerAuth":"true","HUID":"XYZ","supportMirrorOverlayTouch":1,"HUName":"CFDL16-6GUV","version_name":"CFDL06.6.10","supportFunction":1} | 0,-2,1,2,0,1,2,5 | legacy
{"channel":"21322","supportLandscapeAdaptive":"false","supportScreenTouch":1,"supportMirrorOverlayTouch":false,"HUID":"","sdkVersion":"0.9.23.9"} | 0,0,14,3,1,-1,0,1 | morini
{"sdkVersion":"1.2.0","supportMirrorOverlayTouch":"false","HUName":"","HUID":"6KWV0001"} | 0,6,1,1,0,-1,0,1 | nk_adv
{"supportLandscapeAdaptive":false,"HUName":"","package_name":"com.cfmoto.easyconnect","version_name":"CFDL06.6.10","sdkVersion":"0.9.25.1","supportMirrorOverlayTouch":1} | 0,3,1,3,0,2,0,1 | nk_adv
{"sdkVersion":"0.9.23.4","package_name":"x.cfdash.y","supportLandscapeAdaptive":1,"HUID":"CRCP230501740","flavor":51,"enableSockServerAuth":true,"supportMirrorOverlayTouch":1,"HUName":"x48fb4cx","supportFunction":0} | 7,2,7,3,5,1,2,1 | nk800
{"version_name":"CFDL26.2.3.5.0.6","supportMirrorOverlayTouch":true,"supportFunction":"128","channel":"21340","HUID":"6KWV0001","supportLandscapeAdaptive":"true","package_name":"","sdkVersion":"1.1.4","enableSockServerAuth":false} | 0,8,1,2,0,10,7,1 | cfdl26_land
{"HUName":"CFMOTO-805120","enableSockServerAuth":"TRUE","package_name":"x.cfdash.y","channel":"66660736","supportFunction":128,"HUID":""} | 0,3,1,1,8,2,3,1 | clc450
{"package_name":"com.cfmoto.cfdashmotoplay","supportMirrorOverlayTouch":1,"enableSockServerAuth":"yes","sdkVersion":"0.9.30"} | 0,0,1,3,0,-1,3,1 | motoplay_land
{"sdkVersion":"1.0.13.1","supportScreenTouch":"yes","HUName":"x48fb4cx","supportFunction":128,"HUID":"Carb","enableSockServerAuth":"true","package_name":"com.CFMOTO.x"} | 0,5,11,1,4,0,0,1 | morini
{"sdkVersion":"0.","HUName":"CFMOTO-805120","supportScreenTouch":"false","supportFunction":"x","channel":" 37416 "} | 0,0,1,1,0,-1,0,3 | legacy
{"sdkVersion":"","HUName":"","supportLandscapeAdaptive":"yes"} | 0,0,1,1,0,-1,0,1 | morini
{"version_name":"CFDL26.2.3.0.5","enableSockServerAuth":"true","package_name":"","channel":66660742,"HUID":"CRCP230501740","supportFunction":"128"} | 4,7,1,11,0,6,7,1 | motoplay_land
{"HUName":"CFDL16-6GUV","supportScreenTouch":1,"HUID":"6KWV0001","flavor":51} | 0,4,8,1,0,-1,0,5 | morini
{"channel":"","supportFunction":0,"supportMirrorOverlayTouch":1,"enableSockServerAuth":1,"HUName":"x48fb4cx","sdkVersion":"1.1.4","HUID":"6GUVA2C00100055"} | 0,2,1,1,4,-1,0,1 | clc450
{"enableSockServerAuth":"yes","HUID":"6GUVA2C00100055","supportScreenTouch":1,"sdkVersion":"1.1.2","supportFunction":1,"package_name":"net.easyconn","supportLandscapeAdaptive":"TRUE","HUName":"CFMOTO-48FB4C"} | 0,-2,1,2,4,-1,0,1 | clc450
{"flavor":"x","HUID":"CARB1234","supportMirrorOverlayTouch":1,"sdkVersion":"0.9.25.1","enableSockServerAuth":"yes","supportScreenTouch":"TRUE","package_name":"com.cfmoto.cfdashmotoplay"} | 0,1,8,2,0,0,0,1 | morini
{"sdkVersion":"1.1.2","HUID":"6KWV0001","channel":"21322","supportScreenTouch":false,"version_name":"CFDL26.2.3.0.5","HUName":"CFMOTO-48FB4C"} | 0,10,14,1,4,5,6,1 | morini
{"version_name":"CFDL26.2.3.5.0.6","enableSockServerAuth":"true","HUName":"x48fb4cx","sdkVersion":"1.0.13.1"} | 0,8,3,1,4,7,8,1 | nk_adv
{"flavor":"x","sdkVersion":"1.1.4","enableSockServerAuth":"TRUE","supportMirrorOverlayTouch":true,"supportLandscapeAdaptive":"true","package_name":"com.CFMOTO.x","HUName":"CFMOTO-805120","HUID":"CRC"} | 0,1,1,2,0,7,4,1 | cfdl26_land
{"channel":37416,"supportMirrorOverlayTouch":false,"sdkVersion":"2","supportScreenTouch":false,"version_name":"cfdl26","HUID":"","supportLandscapeAdaptive":"true","package_name":"linux_no_package"} | 0,-2,1,2,0,-1,0,3 | legacy
{"HUID":"CRC","supportMirrorOverlayTouch":"yes","flavor":65540,"supportFunction":128,"HUName":"","sdkVersion":"1.0.13.1"} | 0,3,3,1,0,-1,0,1 | nk_adv
{"supportScreenTouch":"yes","channel":"21322","sdkVersion":"0.9.29.1","version_name":"CFDL26.2.3.0.5","HUName":"CFMOTO-805120","enableSockServerAuth":"false"} | 0,4,14,3,0,3,4,4 | morini
{"supportMirrorOverlayTouch":1,"package_name":"","channel":21333,"flavor":65540,"HUName":"CFMOTO-805120","supportFunction":"x","supportScreenTouch":"yes"} | 0,0,14,1,0,-1,0,1 | morini
{"HUID":"6GUVA2C00100055","supportFunction":"128","flavor":"51","package_name":"com.cfmoto.cfdashmotoplay","version_name":"V1.0.18"} | 0,0,7,1,0,-1,4,1 | morini
{"enableSockServerAuth":"true","HUID":"XYZ","supportScreenTouch":false,"supportMirrorOverlayTouch":true,"sdkVersion":"1.1.2","channel":21333,"HUName":"CFMOTO-805120"} | 0,5,14,1,0,1,2,1 | morini
{"supportFunction":0,"sdkVersion":"1.1.4","supportMirrorOverlayTouch":"yes","flavor":51,"supportLandscapeAdaptive":false,"HUID":"6KWV0001","package_name":"net.easyconn","HUName":"CFMOTO-48FB4C","supportScreenTouch":"TRUE"} | 0,7,6,0,4,0,0,1 | nk_adv
{"sdkVersion":"0.9.29.1","supportLandscapeAdaptive":false,"HUID":"6KWV0001","HUName":"CFMOTO-805120","channel":"66660736"} | 0,4,1,3,8,-1,0,4 | clc450
{"HUName":"CFMOTO-805120","channel":"37416","supportLandscapeAdaptive":"TRUE","HUID":"6GUVA2C00100055","sdkVersion":"1.1.2","version_name":"cfdl26","package_name":"com.cfmoto.cfdashmotoplay"} | 0,-2,1,2,0,5,5,3 | cfdl26_land
{"HUID":"CRCP230501740","version_name":"CFDL26.2.3.0.5","sdkVersion":"0.9.25.1","package_name":"com.cfmoto.easyconnect","supportMirrorOverlayTouch":true} | 4,8,1,3,0,6,4,1 | nk_adv
{"package_name":"x.cfdash.y","version_name":"CFDL06.6.10","HUName":"","supportScreenTouch":"TRUE","enableSockServerAuth":"true","supportLandscapeAdaptive":"true"} | 0,-1,0,1,0,6,2,1 | cfdl26_land
{"enableSockServerAuth":1,"package_name":"com.cfmoto.cfdashmotoplay","version_name":"V1.0.18","channel":"21340","supportLandscapeAdaptive":false} | 0,0,1,1,0,-1,3,1 | cfdl26_port
{"supportScreenTouch":"false","sdkVersion":"0.9.25.1","HUName":"","HUID":"CRC","enableSockServerAuth":"yes","supportFunction":1,"package_name":"linux_no_package","flavor":"51"} | 0,0,7,3,0,-1,0,1 | morini
{"supportFunction":0,"enableSockServerAuth":1,"supportScreenTouch":true,"supportLandscapeAdaptive":false,"sdkVersion":"2","supportMirrorOverlayTouch":"false"} | 0,3,0,0,0,0,0,1 | nk_adv
{"supportScreenTouch":"true","HUID":"6GUVA2C00100055","sdkVersion":"0.9.30","channel":"66660742","version_name":"CFDL06.6.10"} | 0,1,0,12,0,0,0,1 | motoplay_land
{"HUID":"6GUVA2C00100055","sdkVersion":"0.9.23.9","version_name":"CFDL26.2.3.5.0.6","package_name":"","enableSockServerAuth":"TRUE","channel":"21333"} | 0,6,14,3,1,5,6,1 | morini
{"enableSockServerAuth":1,"supportFunction":128,"version_name":"cfdl26","supportLandscapeAdaptive":"true","HUID":"CRCP230501740","package_name":"net.easyconn","supportScreenTouch":"true","supportMirrorOverlayTouch":"true"} | 4,-2,0,1,0,0,0,1 | nk800
{"version_name":"cfdl26","supportLandscapeAdaptive":"TRUE","sdkVersion":"0.9.23.9","channel":66660742,"HUName":"","supportMirrorOverlayTouch":false,"HUID":"Carb","supportFunction":"x","enableSockServerAuth":false} | 0,-4,10,14,1,0,0,1 | motoplay_land
{"supportLandscapeAdaptive":"yes","supportScreenTouch":"true","channel":"66660742","sdkVersion":"2","HUName":"","version_name":"CFDL26.2.3.5.0.6"} | 0,7,0,10,0,6,6,1 | motoplay_land
{"version_name":"CFDL26.2.3.5.0.6","supportScreenTouch":"false","HUID":"CARB1234","supportMirrorOverlayTouch":false,"supportLandscapeAdaptive":"true","sdkVersion":"1.1.2"} | 0,2,10,2,0,0,0,1 | morini
{"channel":"37416","sdkVersion":"2","supportLandscapeAdaptive":"yes","enableSockServerAuth":"TRUE","HUID":"6GUVA2C00100055","package_name":"net.easyconn","supportFunction":1,"version_name":"V1.0.18"} | 0,4,1,1,0,1,2,3 | nk_adv
{"supportMirrorOverlayTouch":"false","supportFunction":0,"HUName":"","flavor":65540,"HUID":"CARB1234"} | 0,0,10,1,0,0,0,1 | morini
{"HUID":"","supportScreenTouch":"yes","channel":" 37416 ","flavor":51,"supportMirrorOverlayTouch":true} | 0,1,8,1,0,-1,0,3 | morini
{"HUName":"cfdl16","supportFunction":128,"HUID":"6WWV0001","supportLandscapeAdaptive":"true"} | 0,-4,1,2,0,2,0,1 | motoplay_land
{"HUID":"6KWV0001","supportScreenTouch":"yes","HUName":"CFMOTO-805120","supportFunction":128,"version_name":"V1.0.18","sdkVersion":"0.9.23.9"} | 0,4,1,3,1,-1,0,1 | nk_adv
{"supportMirrorOverlayTouch":"true","package_name":"com.cfmoto.easyconnect","sdkVersion":"0.9.23.4","supportLandscapeAdaptive":1,"version_name":"CFDL26.2.3.5.0.6"} | 0,8,1,3,1,6,4,1 | nk_adv
{"sdkVersion":"0.9.29.1","package_name":"com.cfmoto.easyconnect","HUID":"Carb","channel":"21340","supportScreenTouch":1} | 0,3,9,3,0,0,0,4 | morini
{"package_name":"net.easyconn","supportScreenTouch":true,"supportFunction":1,"sdkVersion":"1.0.13.1","enableSockServerAuth":"true","supportMirrorOverlayTouch":"false"} | 0,5,2,0,0,2,2,1 | nk_adv
{"package_name":"net.easyconn","supportFunction":1,"HUID":"CRCP230501740","channel":"21333","HUName":"cfdl16"} | 4,0,13,1,0,-1,0,1 | morini
{"supportScreenTouch":"true","supportFunction":128,"sdkVersion":"1.2.0","package_name":"com.cfmoto.easyconnect","channel":"66660742","supportMirrorOverlayTouch":"TRUE","HUName":"x48fb4cx"} | 0,8,0,10,4,6,3,1 | motoplay_land
{"supportLandscapeAdaptive":1,"supportMirrorOverlayTouch":"true","supportFunction":128,"sdkVersion":"0.9.29.1","channel":"66660736","HUName":"","supportScreenTouch":"yes","HUID":"XYZ"} | 0,1,1,3,8,-1,0,4 | clc450
{"sdkVersion":"1.1.2","HUID":"Carb","HUName":"CFDL16-6GUV","supportLandscapeAdaptive":"TRUE","supportFunction":"x"} | 0,-2,10,2,0,0,0,5 | morini
{"version_name":"cfdl26","flavor":"51","supportMirrorOverlayTouch":"yes","HUID":"CRCP230501740","supportLandscapeAdaptive":false,"package_name":"","HUName":"CFMOTO-48FB4C","enableSockServerAuth":"false","channel":"66660736","supportFunction":"128"} | 4,0,8,1,12,-1,0,1 | clc450
{"HUName":"CFMOTO-805120","version_name":"CFDL26.2.3.0.5","channel":21333,"supportLandscapeAdaptive":"yes","HUID":"XYZ","supportFunction":128,"flavor":"x","package_name":"x.cfdash.y"} | 0,5,13,1,0,4,5,1 | morini
{"supportScreenTouch":"yes","supportLandscapeAdaptive":false,"sdkVersion":"0.9.23.4","channel":"66660742","version_name":"CFDL06.6.10","HUName":"cfdl16","supportFunction":0} | 0,0,1,13,1,-1,0,1 | motoplay_land
{"sdkVersion":"1.2.0","supportScreenTouch":"TRUE","enableSockServerAuth":1,"supportMirrorOverlayTouch":"TRUE","package_name":"x.cfdash.y","supportFunction":128,"HUName":"cfdl16","HUID":"6KWV0001"} | 0,9,0,0,0,3,3,1 | nk_adv
{"package_name":"","supportLandscapeAdaptive":"false","sdkVersion":"0.","enableSockServerAuth":false} | 0,0,1,1,0,-1,0,1 | morini
{"supportLandscapeAdaptive":1,"HUID":"XYZ","supportScreenTouch":"false","version_name":"CFDL06.6.10"} | 0,0,1,1,0,-1,0,1 | morini
{"sdkVersion":"","HUName":"CFMOTO-48FB4C","package_name":"","supportScreenTouch":"yes","channel":"21333"} | 0,0,14,1,4,-1,0,1 | morini
{"HUName":"","supportMirrorOverlayTouch":true,"supportFunction":"x","sdkVersion":"2","version_name":"CFDL06.6.10","channel":"66660742","supportScreenTouch":"false","package_name":"linux_no_package"} | 0,3,1,11,0,-1,0,1 | motoplay_land
{"HUID":"Carb","supportMirrorOverlayTouch":"yes","supportLandscapeAdaptive":"TRUE","supportScreenTouch":true,"enableSockServerAuth":"TRUE","HUName":"cfdl16","sdkVersion":"0.9.30","supportFunction":128} | 0,0,9,3,0,0,0,1 | morini
{"HUID":"XYZ","sdkVersion":"0.9.23.4","supportFunction":128,"flavor":51,"package_name":"net.easyconn","supportScreenTouch":"false"} | 0,0,7,3,1,-1,0,1 | morini
{"supportLandscapeAdaptive":"TRUE","channel":21333,"HUName":"cfdl16","supportMirrorOverlayTouch":false,"HUID":"CRC","supportScreenTouch":"TRUE","enableSockServerAuth":1,"supportFunction":1} | 0,-3,13,1,0,0,0,1 | morini
{"supportFunction":1,"enableSockServerAuth":"yes","supportLandscapeAdaptive":1,"package_name":"","HUName":"cfdl16","HUID":"CRCP230501740","sdkVersion":""} | 4,0,1,1,0,-1,0,1 | nk800
{"HUName":"cfdl16","channel":"","version_name":"CFDL06.6.10","sdkVersion":"1.1.2","enableSockServerAuth":1,"flavor":"x","supportFunction":0,"package_name":"com.CFMOTO.x"} | 0,2,1,1,0,1,2,1 | nk_adv
{"supportScreenTouch":"true","supportLandscapeAdaptive":"true","sdkVersion":"0.9.29.1","supportFunction":0,"HUID":"6WWV0001"} | 0,-3,0,3,0,3,0,4 | legacy
{"channel":"21322","HUID":"6GUVA2C00100055","package_name":"com.cfmoto.easyconnect","sdkVersion":"0.9.23.4","enableSockServerAuth":"yes","supportScreenTouch":"TRUE","HUName":""} | 0,4,12,2,1,3,0,1 | morini
{"HUID":"CARB1234","supportScreenTouch":"yes","flavor":51,"supportFunction":"x","HUName":"CFDL16-6GUV","enableSockServerAuth":1,"version_name":"CFDL26.2.3.0.5"} | 0,4,16,1,0,0,0,5 | morini
{"supportScreenTouch":1,"supportFunction":"128","supportMirrorOverlayTouch":true,"HUName":"CFMOTO-48FB4C","sdkVersion":"1.1.4","version_name":"V1.0.18"} | 0,4,1,1,4,-1,0,1 | nk_adv
{"sdkVersion":"2","package_name":"x.cfdash.y","HUName":""} | 0,2,1,1,0,1,2,1 | nk_adv
{"HUName":"CFMOTO-48FB4C","package_name":"","sdkVersion":"2","enableSockServerAuth":"false","channel":"37416","supportLandscapeAdaptive":"yes","flavor":51,"HUID":"6GUVA2C00100055"} | 0,2,8,1,4,-1,0,3 | morini
{"flavor":65540,"enableSockServerAuth":1,"supportLandscapeAdaptive":"TRUE","supportFunction":"128","channel":37416,"HUName":"CFMOTO-48FB4C","version_name":"cfdl26"} | 0,-4,1,2,4,-1,0,3 | clc450
{"HUID":"carb999","supportFunction":0,"enableSockServerAuth":"TRUE","supportScreenTouch":"yes","package_name":""} | 0,2,10,1,0,0,0,1 | morini
{"HUName":"cfdl16","version_name":"CFDL26.2.3.0.5","package_name":"com.cfmoto.easyconnect","supportScreenTouch":"TRUE","enableSockServerAuth":"TRUE","sdkVersion":"0.9.29.1","flavor":51} | 0,10,6,2,0,9,6,4 | nk_adv
{"supportLandscapeAdaptive":"false","HUName":"CFDL16-6GUV","enableSockServerAuth":"yes","HUID":"CRC","supportMirrorOverlayTouch":true,"package_name":"com.cfmoto.easyconnect","supportFunction":0} | 0,4,1,1,0,2,0,5 | legacy
{"supportFunction":1,"supportScreenTouch":"true","supportLandscapeAdaptive":false,"HUName":"x48fb4cx","HUID":"","sdkVersion":"1.1.2","channel":"21333"} | 0,3,13,0,4,0,0,1 | morini
{"enableSockServerAuth":false,"HUID":"CRC","channel":"21322","supportMirrorOverlayTouch":true} | 0,1,14,1,0,-1,0,1 | morini
{"package_name":"com.cfmoto.easyconnect","supportFunction":128,"flavor":65540,"supportMirrorOverlayTouch":false,"supportLandscapeAdaptive":true,"channel":66660742} | 0,0,1,12,0,7,0,1 | motoplay_land
{"channel":21333,"HUID":"CRC","supportScreenTouch":"true","enableSockServerAuth":true,"supportMirrorOverlayTouch":"false","supportLandscapeAdaptive":true,"supportFunction":0,"sdkVersion":""} | 0,-1,13,1,0,2,2,1 | morini
{"supportLandscapeAdaptive":"false","flavor":65540,"channel":37416,"supportMirrorOverlayTouch":"false","version_name":"cfdl26","sdkVersion":"","package_name":"com.cfmoto.easyconnect","supportFunction":"x","HUName":"CFDL16-6GUV"} | 0,3,1,1,0,2,0,7 | legacy
{"supportMirrorOverlayTouch":"yes","HUID":"XYZ","supportFunction":1,"channel":"37416","HUName":"CFMOTO-48FB4C","package_name":"com.cfmoto.easyconnect","supportScreenTouch":"yes","sdkVersion":"2","flavor":65540} | 0,5,1,1,4,4,2,3 | nk_adv
{"HUName":"CFDL16-6GUV","enableSockServerAuth":1,"supportScreenTouch":1,"version_name":"CFDL06.6.10","sdkVersion":"0.","supportFunction":0,"channel":37416,"HUID":"6WX0AT231300200"} | 0,0,1,1,0,-1,0,7 | legacy
{"flavor":51,"supportFunction":1,"version_name":"cfdl26","sdkVersion":"1.0.13.1","enableSockServerAuth":false,"package_name":"net.easyconn","HUID":"6WWV0001"} | 0,2,9,1,0,2,0,1 | morini
{"HUID":"XYZ","HUName":"","flavor":65540,"supportLandscapeAdaptive":"yes","supportScreenTouch":"false"} | 0,0,1,1,0,-1,0,1 | morini
{"HUName":"CFDL16-6GUV","supportLandscapeAdaptive":false,"package_name":"com.cfmoto.cfdashmotoplay","sdkVersion":"0.9.25.1","HUID":"CARB1234","supportMirrorOverlayTouch":"yes"} | 0,0,9,3,0,0,0,5 | morini
{"supportLandscapeAdaptive":false,"flavor":65540,"supportMirrorOverlayTouch":"true","enableSockServerAuth":false,"HUName":"x48fb4cx","supportFunction":128,"supportScreenTouch":"yes","package_name":"linux_no_package"} | 0,1,1,1,4,-1,0,1 | clc450
{"sdkVersion":"0.9.29.1","supportMirrorOverlayTouch":"false","channel":"21333","HUName":"CFDL16-6GUV","HUID":"6WWV0001","version_name":"CFDL26.2.3.0.5"} | 0,4,14,3,0,6,4,8 | morini
{"package_name":"com.CFMOTO.x","HUID":"6WWV0001","channel":66660742,"flavor":"x","supportScreenTouch":"TRUE","HUName":"","sdkVersion":"1.2.0","version_name":"V1.0.18"} | 0,3,0,10,0,5,2,1 | motoplay_land
{"channel":21333,"flavor":"51","package_name":"com.cfmoto.easyconnect","HUName":"CFMOTO-48FB4C","supportMirrorOverlayTouch":false,"sdkVersion":"1.2.0"} | 0,5,19,1,4,4,2,1 | morini
{"sdkVersion":"0.9.30","supportFunction":1,"package_name":"com.CFMOTO.x","HUID":"6WX0AT231300200","version_name":"CFDL26.2.3.5.0.6","supportScreenTouch":"true","supportLandscapeAdaptive":1,"HUName":"CFMOTO-48FB4C","flavor":51} | 0,5,6,2,4,4,4,1 | morini
{"enableSockServerAuth":true,"sdkVersion":"1.1.4","HUName":"CFMOTO-48FB4C","HUID":"Carb","channel":"21340"} | 0,4,10,1,4,0,0,1 | morini
{"version_name":"CFDL26.2.3.0.5","sdkVersion":"0.","supportScreenTouch":"TRUE","HUName":"CFMOTO-48FB4C"} | 0,5,0,0,4,4,4,1 | nk_adv
{"sdkVersion":"0.9.23.4","enableSockServerAuth":"false","HUID":"","supportFunction":0,"supportMirrorOverlayTouch":"false"} | 0,0,1,3,1,-1,0,1 | motoplay_land
{"sdkVersion":"","flavor":"x","enableSockServerAuth":"yes","HUName":"","supportScreenTouch":"false"} | 0,0,1,1,0,-1,0,1 | morini
{"supportMirrorOverlayTouch":1,"supportScreenTouch":"false","HUName":"","sdkVersion":"0.9.25.1","HUID":"6KWV0001"} | 0,4,1,3,0,-1,0,1 | nk_adv
{"supportFunction":"128","package_name":"com.cfmoto.cfdashmotoplay","enableSockServerAuth":"TRUE","supportMirrorOverlayTouch":"false","flavor":"51"} | 0,3,7,1,0,2,6,1 | morini
{"supportMirrorOverlayTouch":"false","supportLandscapeAdaptive":1,"sdkVersion":"0.9.23.9","HUName":"x48fb4cx","HUID":"6GUVA2C00100055"} | 0,0,1,3,5,-1,0,1 | clc450
{"HUID":"CARB1234","package_name":"x.cfdash.y","supportMirrorOverlayTouch":true,"sdkVersion":"0.9.23.9","channel":"21322","HUName":"CFMOTO-805120","enableSockServerAuth":"true","supportFunction":0} | 0,3,21,3,1,0,0,1 | morini
{"package_name":"x.cfdash.y","version_name":"CFDL26.2.3.5.0.6","supportScreenTouch":"true","supportLandscapeAdaptive":false,"sdkVersion":"1.1.4","HUName":"x48fb4cx","channel":21333,"supportFunction":"x","enableSockServerAuth":false} | 0,7,12,0,4,6,6,1 | morini
{"HUID":"6GUVA2C00100055","enableSockServerAuth":"false","sdkVersion":"2","version_name":"CFDL26.2.3.0.5","HUName":"x48fb4cx","flavor":51,"channel":" 37416 ","supportLandscapeAdaptive":"true","supportFunction":"128"} | 0,3,8,2,4,10,7,3 | cfdl26_land
{"supportMirrorOverlayTouch":false,"flavor":"x","package_name":"","supportLandscapeAdaptive":"false","version_name":"CFDL26.2.3.0.5","sdkVersion":"0.9.23.4","HUID":"Carb","supportFunction":"x","HUName":"CFMOTO-805120"} | 0,4,10,3,1,0,0,1 | morini
{"HUID":"6WWV0001","supportLandscapeAdaptive":false,"supportMirrorOverlayTouch":"TRUE"} | 0,1,1,1,0,2,0,1 | cfdl26_land
{"version_name":"cfdl26","supportScreenTouch":"TRUE","channel":" 37416 ","supportMirrorOverlayTouch":"TRUE","enableSockServerAuth":"yes","package_name":"com.CFMOTO.x","HUID":"6WX0AT231300200","sdkVersion":"0.9.30"} | 0,2,0,2,0,0,0,3 | legacy
{"supportFunction":"x","version_name":"CFDL26.2.3.5.0.6","supportScreenTouch":"false"} | 0,4,1,1,0,3,4,1 | nk_adv
{"HUName":"CFMOTO-48FB4C","HUID":"carb999","channel":"37416","supportScreenTouch":true} | 0,1,9,0,4,0,0,3 | morini
{"supportLandscapeAdaptive":"false","supportFunction":128,"sdkVersion":"2","HUName":"CFMOTO-48FB4C","supportMirrorOverlayTouch":"true"} | 0,4,1,1,4,-1,0,1 | nk_adv
{"package_name":"linux_no_package","channel":21333,"HUID":"XYZ","version_name":"V1.0.18","supportScreenTouch":true,"enableSockServerAuth":true,"supportMirrorOverlayTouch":1,"sdkVersion":"2","HUName":"cfdl16"} | 0,5,12,0,0,2,2,1 | morini
{"channel":"37416","supportScreenTouch":"yes","sdkVersion":"","HUName":"x48fb4cx","supportFunction":1,"flavor":"x","supportMirrorOverlayTouch":true,"HUID":"Carb"} | 0,1,10,1,4,0,0,3 | morini
{"supportLandscapeAdaptive":false,"HUID":"6WWV0001","enableSockServerAuth":true,"version_name":"V1.0.18","supportFunction":0,"supportScreenTouch":"TRUE"} | 0,3,0,0,0,5,2,1 | cfdl26_land
{"sdkVersion":"","supportScreenTouch":"yes","HUName":"CFMOTO-48FB4C","package_name":"net.easyconn","supportFunction":0,"supportMirrorOverlayTouch":"yes"} | 0,0,1,1,4,-1,0,1 | clc450
{"supportMirrorOverlayTouch":"false","HUName":"CFMOTO-48FB4C","supportLandscapeAdaptive":1,"sdkVersion":"0.9.23.9","version_name":"CFDL26.2.3.0.5","HUID":"carb999","enableSockServerAuth":1} | 0,4,10,3,5,0,0,1 | morini
{"sdkVersion":"2","supportLandscapeAdaptive":false,"supportMirrorOverlayTouch":1,"HUID":"CRC","HUName":"CFDL16-6GUV"} | 0,2,1,1,0,-1,0,5 | legacy
{"enableSockServerAuth":false,"HUID":"6WX0AT231300200","channel":66660742,"supportScreenTouch":"yes","HUName":""} | 0,0,1,11,0,-1,0,1 | motoplay_land
{"enableSockServerAuth":"false","HUName":"CFMOTO-805120","channel":37416,"version_name":"CFDL06.6.10","supportFunction":0,"sdkVersion":"0.","supportLandscapeAdaptive":1} | 0,0,1,1,0,-1,0,3 | legacy
{"supportMirrorOverlayTouch":"yes","enableSockServerAuth":"TRUE","package_name":"com.cfmoto.easyconnect","supportScreenTouch":"TRUE","supportLandscapeAdaptive":"TRUE"} | 0,2,0,1,0,9,2,1 | cfdl26_land
{} | 0,0,1,1,0,-1,0,1 | morini
{"sdkVersion":"2","channel":66660742,"HUName":"CFDL16-6GUV"} | 0,2,1,11,0,-1,0,5 | motoplay_land
{"supportMirrorOverlayTouch":"false","HUID":"CARB1234","supportFunction":"128","enableSockServerAuth":"TRUE","sdkVersion":"1.2.0","HUName":""} | 0,5,10,1,0,0,0,1 | morini
{"sdkVersion":"0.9.30","HUID":"6WX0AT231300200","HUName":"CFDL16-6GUV","supportFunction":0,"supportScreenTouch":true} | 0,1,0,2,0,0,0,5 | legacy
{"flavor":"51","HUID":"6GUVA2C00100055","enableSockServerAuth":"true","sdkVersion":"1.1.2","HUName":"CFMOTO-805120","supportFunction":128,"supportMirrorOverlayTouch":"TRUE"} | 0,6,8,1,0,2,3,1 | morini
{"version_name":"CFDL06.6.10","HUName":"","HUID":"CARB1234","sdkVersion":"0.9.23.9","supportFunction":0,"supportMirrorOverlayTouch":true,"enableSockServerAuth":1} | 0,1,10,3,1,0,0,1 | morini
{"HUID":"CRCP230501740","HUName":"CFMOTO-805120","enableSockServerAuth":"true","supportScreenTouch":"TRUE","supportMirrorOverlayTouch":false,"package_name":""} | 4,3,0,0,0,2,2,1 | nk800
{"sdkVersion":"","HUName":"x48fb4cx","package_name":"net.easyconn","supportMirrorOverlayTouch":1,"enableSockServerAuth":"false","HUID":"6GUVA2C00100055","flavor":"51"} | 0,0,7,1,4,-1,0,1 | morini
{"sdkVersion":"1.2.0","HUName":"cfdl16","package_name":"x.cfdash.y","channel":"66660736","supportFunction":128} | 0,3,1,1,8,2,3,1 | clc450
{"channel":" 37416 ","supportFunction":"x","package_name":"","supportLandscapeAdaptive":"TRUE","HUID":"CRC","version_name":"CFDL06.6.10","sdkVersion":"1.2.0","HUName":"x48fb4cx","supportMirrorOverlayTouch":1,"supportScreenTouch":1,"enableSockServerAuth":1} | 0,-2,1,2,4,-1,0,3 | clc450
{"supportScreenTouch":1,"sdkVersion":"0.9.23.4","channel":37416,"HUID":"carb999","supportMirrorOverlayTouch":true} | 0,1,10,3,1,0,0,3 | morini
{"version_name":"CFDL06.6.10","channel":"66660736","package_name":"com.cfmoto.cfdashmotoplay","HUName":"x48fb4cx","sdkVersion":"0.9.29.1","enableSockServerAuth":"TRUE","supportScreenTouch":true,"supportLandscapeAdaptive":"yes","HUID":"XYZ"} | 0,3,0,2,12,2,5,4 | clc450
{"sdkVersion":"0.9.29.1","version_name":"CFDL26.2.3.0.5","supportFunction":128,"supportScreenTouch":1,"HUID":"XYZ","channel":"21333","package_name":"","HUName":"CFMOTO-48FB4C"} | 0,5,14,3,4,4,5,4 | morini
{"supportFunction":0,"HUName":"CFMOTO-48FB4C","sdkVersion":"2","supportLandscapeAdaptive":"yes","enableSockServerAuth":1,"version_name":"cfdl26"} | 0,2,1,1,4,-1,0,1 | clc450
{"version_name":"V1.0.18","HUID":"6WX0AT231300200","package_name":"x.cfdash.y","supportLandscapeAdaptive":"true","enableSockServerAuth":1} | 0,-4,1,2,0,3,0,1 | cfdl26_land
{"enableSockServerAuth":false,"HUID":"XYZ","HUName":"CFMOTO-48FB4C","sdkVersion":"1.0.13.1","version_name":"V1.0.18","supportScreenTouch":"true"} | 0,3,2,0,4,0,0,1 | clc450
{"flavor":"x","supportScreenTouch":true,"enableSockServerAuth":"true","HUName":"cfdl16","package_name":"linux_no_package","sdkVersion":"0.9.23.4","supportFunction":"x"} | 5,3,0,2,1,2,2,1 | nk800
{"flavor":"x","channel":"66660736","supportMirrorOverlayTouch":"true","enableSockServerAuth":"false","HUName":"x48fb4cx","HUID":"6KWV0001","sdkVersion":"0.9.23.9"} | 0,5,1,3,13,-1,0,1 | clc450
{"supportLandscapeAdaptive":true,"sdkVersion":"1.2.0","HUID":"6GUVA2C00100055"} | 0,-2,1,2,0,-1,0,1 | motoplay_land
{"HUName":"CFMOTO-48FB4C","channel":"66660736","version_name":"CFDL26.2.3.0.5","supportLandscapeAdaptive":1,"supportMirrorOverlayTouch":"yes","sdkVersion":"2","enableSockServerAuth":"TRUE","supportScreenTouch":"yes"} | 0,8,1,1,12,7,8,1 | clc450
{"HUName":"cfdl16","sdkVersion":"0.9.23.9","supportLandscapeAdaptive":"TRUE","flavor":65540,"supportScreenTouch":true} | 0,-3,0,3,1,0,0,1 | motoplay_land
{"HUID":"CRC","sdkVersion":"0.","supportFunction":0,"version_name":"CFDL26.2.3.0.5","HUName":"CFDL16-6GUV","channel":"66660742","supportLandscapeAdaptive":true,"supportScreenTouch":false} | 0,0,1,12,0,7,4,5 | motoplay_land
{"version_name":"CFDL26.2.3.5.0.6","supportMirrorOverlayTouch":"false","HUName":"cfdl16","sdkVersion":"1.1.2"} | 0,6,1,1,0,5,6,1 | nk_adv
{"supportMirrorOverlayTouch":"yes","supportLandscapeAdaptive":"yes","HUID":"6GUVA2C00100055","supportScreenTouch":"true","HUName":"cfdl16","supportFunction":128,"sdkVersion":"2"} | 0,4,0,0,0,0,0,1 | nk_adv
{"HUID":"carb999","sdkVersion":"","HUName":"CFDL16-6GUV","package_name":"com.cfmoto.cfdashmotoplay"} | 0,0,9,1,0,0,0,5 | morini
{"package_name":"x.cfdash.y","version_name":"CFDL06.6.10","HUID":"CRCP230501740","channel":"66660736","sdkVersion":"0.9.25.1","supportScreenTouch":"yes","supportMirrorOverlayTouch":true} | 4,1,1,3,8,-1,0,1 | clc450
{"flavor":65540,"channel":"21333","sdkVersion":"1.1.4","version_name":"cfdl26","HUID":"CRC","enableSockServerAuth":"false","HUName":"","supportLandscapeAdaptive":"true","supportFunction":"128"} | 0,-1,14,2,0,-1,0,1 | morini
{"HUName":"","supportFunction":"128","version_name":"V1.0.18","sdkVersion":"0.9.23.9","supportScreenTouch":"true","HUID":"Carb"} | 0,1,9,2,1,0,0,1 | morini
{"version_name":"CFDL06.6.10","sdkVersion":"0.9.23.4","supportMirrorOverlayTouch":true,"HUID":"6GUVA2C00100055","supportLandscapeAdaptive":false} | 0,1,1,3,1,-1,0,1 | motoplay_land
{"supportMirrorOverlayTouch":"yes","HUID":"Carb","supportLandscapeAdaptive":"yes","supportScreenTouch":1} | 0,0,10,1,0,0,0,1 | morini
{"sdkVersion":"0.9.30","supportScreenTouch":true,"supportFunction":1} | 0,1,0,2,0,0,0,1 | motoplay_land
{"package_name":"com.cfmoto.easyconnect","enableSockServerAuth":false,"supportScreenTouch":false,"HUID":"CARB1234","version_name":"cfdl26"} | 0,3,9,1,0,0,0,1 | morini
{"sdkVersion":"0.9.29.1","version_name":"cfdl26","supportMirrorOverlayTouch":false,"HUID":"6KWV0001","supportLandscapeAdaptive":"false","supportScreenTouch":true,"HUName":"CFDL16-6GUV"} | 0,5,0,2,0,0,0,8 | legacy
{"sdkVersion":"1.1.4","HUID":"6WX0AT231300200","supportLandscapeAdaptive":"true","channel":"","supportScreenTouch":"TRUE","supportFunction":128} | 0,0,0,1,0,0,0,1 | motoplay_land
{"package_name":"net.easyconn","HUName":"CFMOTO-48FB4C","flavor":"51","supportFunction":"x","HUID":"XYZ","supportScreenTouch":"false","sdkVersion":"2","version_name":"V1.0.18","enableSockServerAuth":1} | 0,2,7,1,4,-1,0,1 | morini
{"sdkVersion":"2","supportFunction":128,"HUName":"CFMOTO-48FB4C","supportScreenTouch":"TRUE","HUID":"carb999","enableSockServerAuth":"false","supportLandscapeAdaptive":"true","channel":"37416","version_name":"CFDL06.6.10"} | 0,0,9,1,4,0,0,3 | morini
{"version_name":"V1.0.18","HUName":"CFDL16-6GUV","enableSockServerAuth":true,"supportLandscapeAdaptive":"TRUE","supportScreenTouch":"false","sdkVersion":"1.0.13.1"} | 0,0,3,2,0,1,2,5 | legacy
{"channel":"21340","enableSockServerAuth":"yes","supportMirrorOverlayTouch":false,"supportFunction":"128","HUName":"CFMOTO-48FB4C","package_name":"net.easyconn"} | 0,0,1,1,4,-1,0,1 | clc450
{"package_name":"net.easyconn","supportMirrorOverlayTouch":true,"supportLandscapeAdaptive":1,"HUID":"CRCP230501740","HUName":"CFMOTO-805120"} | 4,1,1,1,0,-1,0,1 | nk800
{"supportMirrorOverlayTouch":false,"package_name":"com.cfmoto.cfdashmotoplay","HUID":"CARB1234","supportScreenTouch":"true","sdkVersion":"0.9.25.1","HUName":""} | 0,1,8,2,0,0,0,1 | morini
{"sdkVersion":"","channel":"37416","HUID":"6GUVA2C00100055","supportScreenTouch":"true","version_name":"CFDL06.6.10","enableSockServerAuth":"TRUE","flavor":65540} | 0,3,0,0,0,2,2,3 | nk_adv
{"supportScreenTouch":"false","package_name":"com.cfmoto.cfdashmotoplay","sdkVersion":"","HUID":"6KWV0001","enableSockServerAuth":true,"supportLandscapeAdaptive":false} | 0,6,1,1,0,1,5,1 | nk_adv
{"supportFunction":128,"channel":"21333","HUID":"","supportLandscapeAdaptive":"true","enableSockServerAuth":1,"package_name":"com.CFMOTO.x","version_name":"cfdl26","sdkVersion":"1.1.2","HUName":"CFMOTO-805120"} | 0,-1,13,2,0,6,3,1 | morini
{"HUID":"Carb","supportScreenTouch":true,"supportLandscapeAdaptive":true,"supportFunction":1,"package_name":"net.easyconn","HUName":"CFDL16-6GUV","flavor":"51"} | 0,-3,14,1,0,0,0,5 | morini
{"HUName":"CFMOTO-48FB4C","supportMirrorOverlayTouch":1,"sdkVersion":"1.0.13.1","package_name":"com.CFMOTO.x","HUID":"XYZ","version_name":"V1.0.18","supportFunction":1} | 0,2,3,1,4,1,2,1 | clc450
{"supportFunction":"128","flavor":51,"HUName":"","enableSockServerAuth":"false","channel":"","sdkVersion":"1.0.13.1"} | 0,3,10,1,0,-1,0,1 | morini
{"supportLandscapeAdaptive":"TRUE","supportMirrorOverlayTouch":false,"sdkVersion":"0.9.30","HUName":"CFDL16-6GUV","version_name":"CFDL26.2.3.5.0.6","HUID":"6WX0AT231300200","channel":"66660736","supportScreenTouch":false,"supportFunction":"x","package_name":"com.cfmoto.cfdashmotoplay","enableSockServerAuth":false} | 0,0,1,4,8,7,7,5 | clc450
"""#
}
