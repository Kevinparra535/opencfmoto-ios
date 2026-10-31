// SPDX-License-Identifier: AGPL-3.0-or-later
// Vectors: docs/spec/control-plane.md §7, §8 (incl. the §8.4 worked example with the §9.5 key),
// §10.2 and §2.3.
import XCTest
@testable import OpenCfMotoCore

final class ProtocolClientInfoTests: XCTestCase {
    /// control-plane.md §8.4, verbatim (800 bytes).
    static let workedExampleJSON = "{\"pxcVersion\":\"1.0.2\",\"phoneUUID\":\"3f2b8c1e-9a47-4d2e-8b6a-0c5d7e9f1a23\",\"phoneBrand\":\"samsung\",\"phoneModel\":\"SM-G991B\",\"phoneOsVersion\":\"35\",\"phoneOs\":\"Android\",\"package\":\"com.cfmoto.cfmotointernational\",\"versionCode\":126,\"token\":0,\"pubkey\":\"MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCJK2qMkijMfOspHCr9UMR+djdNu6vnubHpqfJMacvtgSnbOmaMpse9gLsKp3Hd1GTK5k9W8Jk3PPU6JW3drsgdK43RdlotOlGT5PMiw7jmo0OydzXjuFrjfhLscuz6MbNPXO12IkrgoVWPsfOp3xskqWrlfQuCGNljUt\\/UzHJWFwIDAQAB\",\"encryptedHUID\":\"cfSiCV3iPlLnlyC9c70nMK+ssR6NtAo0nVB9D4IzEa6kszXDMylU7NtPTdLHMnPMqjphXhkVEjpeQ7sapLP0rniYP9fz+ZY5aS\\/xeGZvLzbxjOR4iHDec2JtAXMI4rJQ4vchKpmAxvQ4yZmKKFmhW2NXmraAKZF9RrzNyFhbZS0=\",\"bluetoothName\":\"OpenCfMoto\",\"supportH264IFrame\":true,\"supportFunction\":0,\"supportSyncCorrectTime\":false,\"appVersionFingerPrint\":\"opencfmoto-poc\"}"

    // MARK: §8 reply

    func testWorkedExampleReplyIsByteExact() throws {
        let reply = PhoneClientInfoReply.build(phone: LinkTestKeys.examplePhone, huid: "6GUVA2C00100055",
                                               signer: LinkTestKeys.fixtureSigner, profile: .legacy,
                                               forceTouch: false, forceNonTouch: false)
        XCTAssertEqual(reply.jsonString, Self.workedExampleJSON)
        XCTAssertEqual(reply.jsonData.count, 800)
        let frame = PhoneClientInfoReply.frame(reply).encoded()
        XCTAssertEqual(frame.prefix(16), linkHex("11 00 01 00 30 03 00 00 21 03 01 00 00 00 00 00"))
        XCTAssertEqual(frame.count, 816)
    }

    func testKeyOrderTemplate() {
        let reply = PhoneClientInfoReply.build(phone: PhoneIdentity(phoneUUID: "u", phoneBrand: "Apple", phoneModel: "iPhone16,1",
                                                                    phoneOsVersion: "35", bluetoothName: "OpenCfMoto"),
                                               publicKeyBase64: "PK", encryptedHUID: "", supportFunction: 128,
                                               appendScreenTouch: true)
        XCTAssertEqual(reply.entries.map(\.key), [
            "pxcVersion", "phoneUUID", "phoneBrand", "phoneModel", "phoneOsVersion", "phoneOs", "package", "versionCode",
            "token", "pubkey", "encryptedHUID", "bluetoothName", "supportH264IFrame", "supportFunction",
            "supportSyncCorrectTime", "appVersionFingerPrint", "supportScreenTouch",
        ])
        XCTAssertEqual(reply.jsonString, "{\"pxcVersion\":\"1.0.2\",\"phoneUUID\":\"u\",\"phoneBrand\":\"Apple\",\"phoneModel\":\"iPhone16,1\",\"phoneOsVersion\":\"35\",\"phoneOs\":\"Android\",\"package\":\"com.cfmoto.cfmotointernational\",\"versionCode\":126,\"token\":0,\"pubkey\":\"PK\",\"encryptedHUID\":\"\",\"bluetoothName\":\"OpenCfMoto\",\"supportH264IFrame\":true,\"supportFunction\":128,\"supportSyncCorrectTime\":false,\"appVersionFingerPrint\":\"opencfmoto-poc\",\"supportScreenTouch\":true}")
    }

    func testLandscapeReplyEndsWithScreenTouchAndSupportFunction128() {
        let reply = PhoneClientInfoReply.build(phone: LinkTestKeys.examplePhone, huid: "6GUVA2C00100055",
                                               signer: LinkTestKeys.fixtureSigner, profile: .cfdl26Landscape,
                                               forceTouch: false, forceNonTouch: false)
        var expected = Self.workedExampleJSON.replacingOccurrences(of: "\"supportFunction\":0", with: "\"supportFunction\":128")
        expected.removeLast()
        expected += ",\"supportScreenTouch\":true}"
        XCTAssertEqual(reply.jsonString, expected)
    }

    func testScreenTouchKeyPerProfileAndForceFlags() {
        func hasTouch(_ p: BikeProfile, force: Bool = false, nonTouch: Bool = false) -> Bool {
            PhoneClientInfoReply.build(phone: LinkTestKeys.examplePhone, huid: nil, signer: LinkTestKeys.fixtureSigner,
                                       profile: p, forceTouch: force, forceNonTouch: nonTouch)["supportScreenTouch"] != nil
        }
        // Defaults: Landscape and NkTouch include it, Portrait only when forced, the others never.
        XCTAssertTrue(hasTouch(.cfdl26Landscape))
        XCTAssertTrue(hasTouch(.nkAdvanced))
        XCTAssertFalse(hasTouch(.cfdl26Portrait))
        XCTAssertTrue(hasTouch(.cfdl26Portrait, force: true))
        for p in [BikeProfile.legacy, .nk800, .motoplayLandscape, .clc450, .morini] {
            XCTAssertFalse(hasTouch(p), p.name)
            XCTAssertFalse(hasTouch(p, force: true), p.name) // even with Force touchscreen
        }
        // Disable touchscreen wins over everything.
        XCTAssertFalse(hasTouch(.cfdl26Landscape, nonTouch: true))
        XCTAssertFalse(hasTouch(.cfdl26Portrait, force: true, nonTouch: true))
        XCTAssertTrue(PhoneClientInfoReply.advertisesScreenTouch(profileSupportsTouch: false, forceTouch: true, forceNonTouch: false))
        XCTAssertFalse(PhoneClientInfoReply.advertisesScreenTouch(profileSupportsTouch: true, forceTouch: true, forceNonTouch: true))
    }

    func testSupportFunctionPerProfile() {
        XCTAssertEqual(BikeProfile.legacy.supportFunction, 0)
        XCTAssertEqual(BikeProfile.clc450.supportFunction, 0)
        for p in [BikeProfile.nk800, .nkAdvanced, .morini, .motoplayLandscape, .cfdl26Landscape, .cfdl26Portrait] {
            XCTAssertEqual(p.supportFunction, 128, p.name)
        }
    }

    func testNoHuidGivesEmptyEncryptedHUID() {
        let reply = PhoneClientInfoReply.build(phone: LinkTestKeys.examplePhone, huid: nil, signer: LinkTestKeys.fixtureSigner,
                                               profile: .legacy, forceTouch: false, forceNonTouch: false)
        XCTAssertEqual(reply["encryptedHUID"], .string(""))
        XCTAssertEqual(reply["pubkey"], .string(LinkTestKeys.fixtureSigner.publicKeyBase64))
    }

    func testSignerFailureYieldsEmptyEncryptedHUID() {
        let tooLong = String(repeating: "X", count: 118) // > 117 bytes
        let reply = PhoneClientInfoReply.build(phone: LinkTestKeys.examplePhone, huid: tooLong, signer: LinkTestKeys.fixtureSigner,
                                               profile: .legacy, forceTouch: false, forceNonTouch: false)
        XCTAssertEqual(reply["encryptedHUID"], .string(""))
    }

    // MARK: §7 parsing

    func testParsesDocumentedFieldsWithOptSemantics() throws {
        let info = try XCTUnwrap(BikeClientInfo.parse(LinkDashSamples.mtxClientInfo))
        XCTAssertEqual(info.huid, "6WX0AT231300200")
        XCTAssertEqual(info.huName, "CFMOTO-805120")
        XCTAssertEqual(info.packageName, "com.cfmoto.cfdashmotoplay")
        XCTAssertEqual(info.versionName, "CFDL26.2.3.5.0.6")
        XCTAssertEqual(info.sdkVersion, "1.1.4")
        XCTAssertEqual(info.optString("flavor"), "65540") // optString of a number
        XCTAssertEqual(info.optInt("supportFunction"), 128)
        XCTAssertTrue(info.optBoolean("enableSockServerAuth"))
        XCTAssertTrue(info.supportsScreenTouch)
        XCTAssertEqual(info.socketTimeoutSeconds, 9)
        XCTAssertEqual(info.optString("missing"), "")
        XCTAssertEqual(info.optInt("missing", 7), 7)
        XCTAssertFalse(info.optBoolean("missing"))
        let dash = info.dashInfo(profile: .cfdl26Portrait)
        XCTAssertEqual(dash, DashInfo(huid: "6WX0AT231300200", huName: "CFMOTO-805120", sdkVersion: "1.1.4",
                                      versionName: "CFDL26.2.3.5.0.6", packageName: "com.cfmoto.cfdashmotoplay",
                                      channel: "", socketTimeoutSeconds: 9, supportsScreenTouch: true,
                                      profile: .cfdl26Portrait, rawJSON: LinkDashSamples.mtxClientInfo))
    }

    func testOrgJsonCoercions() throws {
        let info = try XCTUnwrap(BikeClientInfo.parse("""
            {"channel":37416,"flavor":"51","supportFunction":"128","a":" 12 ","b":"12.9","c":1.0E10,"d":3000000000,
             "t1":"TRUE","t2":"False","t3":1,"t4":"yes","n":null,"o":{"k":"v/w"},"arr":[1,"x"],"dbl":1.5,"neg":-2.9}
            """))
        XCTAssertEqual(info.channel, "37416")
        XCTAssertEqual(info.optInt("flavor"), 51)
        XCTAssertEqual(info.optInt("supportFunction"), 128)
        XCTAssertEqual(info.optInt("a"), 12) // Double.parseDouble trims
        XCTAssertEqual(info.optInt("b"), 12) // (int) 12.9
        XCTAssertEqual(info.optInt("neg"), -2) // truncation toward zero
        XCTAssertEqual(info.optInt("d"), Int(Int32(truncatingIfNeeded: Int64(3_000_000_000)))) // Long.intValue()
        XCTAssertEqual(info.optInt("c"), Int(Int32.max)) // (int) saturates
        XCTAssertTrue(info.optBoolean("t1"))
        XCTAssertFalse(info.optBoolean("t2", true))
        XCTAssertFalse(info.optBoolean("t3")) // numbers are NOT booleans in org.json
        XCTAssertTrue(info.optBoolean("t3", true)) // → fallback
        XCTAssertFalse(info.optBoolean("t4")) // "yes" is not a boolean
        XCTAssertEqual(info.optString("n"), "null")
        XCTAssertEqual(info.optString("o"), "{\"k\":\"v\\/w\"}")
        XCTAssertEqual(info.optString("arr"), "[1,\"x\"]")
        XCTAssertEqual(info.optString("dbl"), "1.5")
        XCTAssertEqual(info.optString("c"), "1.0E10") // Java Double.toString
    }

    func testHuidFallbackAndEmptyHuid() throws {
        XCTAssertEqual(BikeClientInfo.parse("{\"huid\":\"lower\"}")?.huid, "lower")
        XCTAssertEqual(BikeClientInfo.parse("{\"HUID\":\"UP\",\"huid\":\"lower\"}")?.huid, "UP")
        XCTAssertNil(BikeClientInfo.parse("{\"HUID\":\"\"}")?.huid)
        XCTAssertNil(BikeClientInfo.parse("{}")?.huid)
    }

    func testLenientParsing() throws {
        // Trailing NULs (C string terminator) and garbage after the object are ignored.
        XCTAssertEqual(BikeClientInfo.parse("{\"HUID\":\"6GUV\"}\u{0}\u{0}")?.huid, "6GUV")
        XCTAssertEqual(BikeClientInfo.parse("\u{0}  {\"HUID\":\"6GUV\"}xyz")?.huid, "6GUV")
        XCTAssertEqual(BikeClientInfo.parse(Data([0xEF, 0xBB, 0xBF]) + Data("{\"HUID\":\"BOM\"}".utf8))?.huid, "BOM")
        // org.json leniency: unquoted / single-quoted strings, = and => separators, ; between pairs, comments.
        let lenient = try XCTUnwrap(BikeClientInfo.parse("{HUID:CRCP230501740; 'sdkVersion'='0.9.23.4', package_name=>linux_no_package # c\n, /* x */ flag:true}"))
        XCTAssertEqual(lenient.huid, "CRCP230501740")
        XCTAssertEqual(lenient.sdkVersion, "0.9.23.4")
        XCTAssertEqual(lenient.packageName, "linux_no_package")
        XCTAssertTrue(lenient.optBoolean("flag"))
        // Duplicate keys: last value wins, first position kept.
        let dup = try XCTUnwrap(BikeClientInfo.parse("{\"a\":1,\"b\":2,\"a\":3}"))
        XCTAssertEqual(dup.json.entries.map(\.key), ["a", "b"])
        XCTAssertEqual(dup.optInt("a"), 3)
        // Not an object / broken → nil.
        XCTAssertNil(BikeClientInfo.parse("[1,2]"))
        XCTAssertNil(BikeClientInfo.parse(""))
        XCTAssertNil(BikeClientInfo.parse("{\"a\":"))
        XCTAssertNil(BikeClientInfo.parse("{\"a\":1,}")) // Android rejects a trailing comma in objects
    }

    // MARK: §10.2 CHECK_SN

    func testCheckSnRepliesAreByteExact() {
        let frames = CheckSn.replies(to: Data(LinkDashSamples.checkSn.utf8))
        XCTAssertEqual(frames.map { $0.encoded() }, [
            linkHex("e1 03 01 00 10 00 00 00 f1 03 01 00 00 00 00 00"),
            linkHex("c0 01 02 00 6b 00 00 00 ab 01 02 00 00 00 00 00 7b 22 69 73 4f 6b 22 3a 74 72 75 65 2c 22 65 72 72 43 6f 64 65 22 3a 30 2c 22 65 72 72 4d 73 67 22 3a 22 22 2c 22 69 64 22 3a 22 44 53 58 58 5a 4d 48 4e 46 56 33 44 45 58 45 42 42 33 50 5a 32 22 2c 22 63 6c 69 65 6e 74 5f 73 65 74 22 3a 22 65 61 73 79 5f 63 6f 6e 6e 22 7d"),
        ])
    }

    func testCheckSnClientSetIsConstantAndBadPayloadGivesEmptyId() {
        XCTAssertEqual(CheckSn.result(serial: CheckSn.serial(from: Data("{\"client_set\":\"other\",\"sn\":\"S1\"}".utf8))).jsonString,
                       "{\"isOk\":true,\"errCode\":0,\"errMsg\":\"\",\"id\":\"S1\",\"client_set\":\"easy_conn\"}")
        XCTAssertEqual(CheckSn.serial(from: Data("not json".utf8)), "")
        XCTAssertEqual(CheckSn.serial(from: Data()), "")
    }
}

final class ProtocolOrgJSONTests: XCTestCase {
    func testLiteralTyping() throws {
        XCTAssertEqual(try PxcOrgJSON.parseValue("42"), .int(42))
        XCTAssertEqual(try PxcOrgJSON.parseValue("-7"), .int(-7))
        XCTAssertEqual(try PxcOrgJSON.parseValue("0x1F"), .int(31))
        XCTAssertEqual(try PxcOrgJSON.parseValue("0777"), .int(511)) // Java octal
        XCTAssertEqual(try PxcOrgJSON.parseValue("08"), .double(8)) // octal fails → Double.valueOf
        XCTAssertEqual(try PxcOrgJSON.parseValue("9223372036854775808"), .double(9.223372036854775808e18))
        XCTAssertEqual(try PxcOrgJSON.parseValue("1e5"), .double(100_000))
        XCTAssertEqual(try PxcOrgJSON.parseValue("1.5f"), .double(1.5))
        XCTAssertEqual(try PxcOrgJSON.parseValue("TRUE"), .bool(true))
        XCTAssertEqual(try PxcOrgJSON.parseValue("Null"), .null)
        XCTAssertEqual(try PxcOrgJSON.parseValue("6GUVA2C00100055"), .string("6GUVA2C00100055"))
        XCTAssertEqual(try PxcOrgJSON.parseValue("'it''s'"), .string("it"))
        XCTAssertThrowsError(try PxcOrgJSON.parseValue("NaN")) // forbidden numeric value
        XCTAssertThrowsError(try PxcOrgJSON.parseValue(""))
    }

    func testStringEscapes() throws {
        XCTAssertEqual(try PxcOrgJSON.parseValue("\"a\\/b\\n\\u00e9\\ud83d\\ude00\\q\""), .string("a/b\né😀q"))
        XCTAssertThrowsError(try PxcOrgJSON.parseValue("\"abc"))
        XCTAssertThrowsError(try PxcOrgJSON.parseValue("\"\\u12\""))
    }

    func testArrays() throws {
        XCTAssertEqual(try PxcOrgJSON.parseValue("[1,,2]"), .array([.int(1), .null, .int(2)]))
        XCTAssertEqual(try PxcOrgJSON.parseValue("[1,]"), .array([.int(1), .null]))
        XCTAssertEqual(try PxcOrgJSON.parseValue("[]"), .array([]))
        XCTAssertEqual(try PxcOrgJSON.parseValue("[1;2]"), .array([.int(1), .int(2)]))
        XCTAssertThrowsError(try PxcOrgJSON.parseValue("[1 2]"))
    }

    func testNestedObjectsKeepOrder() throws {
        let o = try PxcOrgJSON.parseObject("{\"z\":{\"b\":1,\"a\":2},\"y\":[{\"x\":true}]}")
        XCTAssertEqual(o.entries.map(\.key), ["z", "y"])
        XCTAssertEqual(o.jsonString, "{\"z\":{\"b\":1,\"a\":2},\"y\":[{\"x\":true}]}")
        XCTAssertThrowsError(try PxcOrgJSON.parseObject("{null:1}"))
        XCTAssertThrowsError(try PxcOrgJSON.parseObject("{1:1}"))
        XCTAssertThrowsError(try PxcOrgJSON.parseObject("\"str\""))
    }

    func testJavaDoubleToString() {
        XCTAssertEqual(PxcOrgJSON.javaDoubleString(1.0), "1.0")
        XCTAssertEqual(PxcOrgJSON.javaDoubleString(0.001), "0.001")
        XCTAssertEqual(PxcOrgJSON.javaDoubleString(1234567.0), "1234567.0")
        XCTAssertEqual(PxcOrgJSON.javaDoubleString(1.0e7), "1.0E7")
        XCTAssertEqual(PxcOrgJSON.javaDoubleString(1.25e10), "1.25E10")
        XCTAssertEqual(PxcOrgJSON.javaDoubleString(1.5e-5), "1.5E-5")
        XCTAssertEqual(PxcOrgJSON.javaDoubleString(-0.0), "-0.0")
        XCTAssertEqual(PxcOrgJSON.javaDoubleString(.infinity), "Infinity")
    }
}
