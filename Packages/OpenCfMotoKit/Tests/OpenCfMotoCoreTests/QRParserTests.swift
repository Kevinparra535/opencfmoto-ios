// SPDX-License-Identifier: AGPL-3.0-or-later
// Vectors: docs/spec/session-network.md §2.13 (test/QrDataTest.kt), §2.14, §2.15.

import XCTest
@testable import OpenCfMotoCore

final class QRParserTests: XCTestCase {

    private func check(_ raw: String, ssid: String, pwd: String, auth: String?, mac: String?, name: String?,
                       action: Int, modelId: String?, sn: String?, ap: Bool, p2p: Bool, hs: Bool,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard let q = BikeQR.parse(raw) else { return XCTFail("parse failed for \(raw)", file: file, line: line) }
        XCTAssertEqual(q.ssid, ssid, "ssid", file: file, line: line)
        XCTAssertEqual(q.password, pwd, "pwd", file: file, line: line)
        XCTAssertEqual(q.auth, auth, "auth", file: file, line: line)
        XCTAssertEqual(q.mac, mac, "mac", file: file, line: line)
        XCTAssertEqual(q.name, name, "name", file: file, line: line)
        XCTAssertEqual(q.action, action, "action", file: file, line: line)
        XCTAssertEqual(q.modelId, modelId, "modelId", file: file, line: line)
        XCTAssertEqual(q.sn, sn, "sn", file: file, line: line)
        XCTAssertEqual(q.supportsAp, ap, "supportsAp", file: file, line: line)
        XCTAssertEqual(q.supportsP2p, p2p, "supportsP2p", file: file, line: line)
        XCTAssertEqual(q.supportsPhoneHotspot, hs, "supportsPhoneHotspot", file: file, line: line)
        XCTAssertEqual(q.raw, raw.trimmingCharacters(in: .whitespacesAndNewlines), "raw", file: file, line: line)
    }

    // MARK: §2.13 repo tests (QrDataTest.kt) with §2.14 full results

    func testParsesCarbitSsidPwd() {
        check("http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426&sn=Vasr&action=1&ssid=CFMOTO4288&pwd=e278450c&uid=abc",
              ssid: "CFMOTO4288", pwd: "e278450c", auth: nil, mac: nil, name: nil, action: 1, modelId: "37426",
              sn: "Vasr", ap: true, p2p: false, hs: false)
    }

    func testParsesMotoMoriniWifiHashFormat() {
        check("http://admin.motomorini.com/app.html?Wifi=ML174167#12345678#dc0d30da1b6c&MachineID=dc0d30da1b6c&ProductID=00297",
              ssid: "ML174167", pwd: "12345678", auth: "wpa2-psk", mac: "dc:0d:30:da:1b:6c", name: "ML174167",
              action: 1, modelId: "00297", sn: "dc0d30da1b6c", ap: true, p2p: false, hs: false)
    }

    func testRejectsVehicleInfoQr() {
        XCTAssertNil(BikeQR.parse("code:&engine:&vin:&color:Fuji White"))
        let hint = BikeQR.failureHint(for: "code:&engine:&vin:&color:Fuji White")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.lowercased().contains("bike info"))
        XCTAssertEqual(hint, "that QR is bike info (color/VIN), not Wi\u{2011}Fi pairing \u{2014} open MotoPlay / EasyConnect / MotoFun QR")
    }

    func testParsesPhoneHotspotAction128() {
        check("http://www.carbit.com.cn/down6/645/644/_ylqxos?modelid=21322&sn=t6J4&action=128&bm=DD%3A0D%3A30%3A24%3A87%3A6D",
              ssid: "PHONE-HOTSPOT-24876d", pwd: "", auth: nil, mac: "dd:0d:30:24:87:6d", name: "Phone hotspot (24:87:6d)",
              action: 128, modelId: "21322", sn: "t6J4", ap: false, p2p: false, hs: true)
    }

    func testParsesCarbitTokenQr() {
        check("CARBITDC0D3024876D", ssid: "PHONE-HOTSPOT-24876D", pwd: "", auth: nil, mac: "dc:0d:30:24:87:6d",
              name: "Phone hotspot (24:87:6d)", action: 128, modelId: nil, sn: nil, ap: false, p2p: false, hs: true)
    }

    func testParsesP2pOnlyZontesSoftApQr() {
        check("http://www.carbit.com.cn/down6/645/644/_ylqxos?modelid=34808&action=8&ssid=ZT5Gcf3b&pwd=secret&auth=WPA2&mac=34%3A28%3A4a%3A04%3Acf%3A3b&name=ZT5Gcf3b",
              ssid: "ZT5Gcf3b", pwd: "secret", auth: "WPA2", mac: "34:28:4a:04:cf:3b", name: "ZT5Gcf3b", action: 8,
              modelId: "34808", sn: nil, ap: false, p2p: true, hs: false)
    }

    func testParsesThinkerridePositionalSoftApQr() {
        check("http://g.thinkerride.com?CQKY_5e1c6cb10&81316044&ap=1", ssid: "CQKY_5e1c6cb10", pwd: "81316044",
              auth: "wpa2-psk", mac: nil, name: "CQKY_5e1c6cb10", action: 1, modelId: nil, sn: nil,
              ap: true, p2p: false, hs: false)
    }

    func testParsesBareThinkerrideCqkyToken() {
        check("CQKY_5e1c6cb10&81316044&ap=1", ssid: "CQKY_5e1c6cb10", pwd: "81316044", auth: "wpa2-psk", mac: nil,
              name: "CQKY_5e1c6cb10", action: 1, modelId: nil, sn: nil, ap: true, p2p: false, hs: false)
    }

    func testRejectsIncompleteThinkerrideQr() {
        let kove = "Kove/Thinkerride \u{2014} need the SoftAP pairing QR (SSID+password on the dash, or g.thinkerride.com?SSID&PWD&ap=1). Garage \u{2192} enter SSID/pwd if the QR is only \u{201C}download KOVE APP\u{201D}"
        for raw in ["http://g.thinkerride.com?CQKY_onlyssid&ap=1", "http://g.thinkerride.com?ap=1", "http://g.thinkerride.com/download"] {
            XCTAssertNil(BikeQR.parse(raw), raw)
            XCTAssertEqual(BikeQR.failureHint(for: raw), kove, raw)
        }
    }

    // MARK: §2.15 derived vectors

    func testDocQrCfdl16() {
        check("http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457",
              ssid: "CFMOTO-f46457", pwd: "59a9cddc94", auth: "wpa2-psk", mac: "6c:09:4a:0f:6c:f8", name: "CFMOTO-f46457",
              action: 9, modelId: "37416", sn: "peTz", ap: true, p2p: true, hs: false)
    }

    func testDirectMtxIllustrative() {
        check("http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426&action=9&ssid=DIRECT-CF-CFMOTO-805120&pwd=12345678&auth=wpa2-psk&mac=aa:bb:cc:dd:ee:ff&name=CFMOTO-805120",
              ssid: "DIRECT-CF-CFMOTO-805120", pwd: "12345678", auth: "wpa2-psk", mac: "aa:bb:cc:dd:ee:ff",
              name: "CFMOTO-805120", action: 9, modelId: "37426", sn: nil, ap: true, p2p: true, hs: false)
    }

    func testQjP2pOnly() {
        check("http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37501&action=8&ssid=qj-5G-ab12cd&pwd=12345678",
              ssid: "qj-5G-ab12cd", pwd: "12345678", auth: nil, mac: nil, name: nil, action: 8, modelId: "37501",
              sn: nil, ap: false, p2p: true, hs: false)
    }

    func testKeysCaseFoldedAndFormDecoded() {
        let q = BikeQR.parse("http://www.carbit.com.cn/x?SSID=Bike+One&PWD=a%2Bb+c&ACTION=1")
        XCTAssertEqual(q?.ssid, "Bike One")
        XCTAssertEqual(q?.password, "a+b c")
        XCTAssertEqual(q?.action, 1)
    }

    func testSoftApWithoutPasswordRejected() {
        XCTAssertNil(BikeQR.parse("http://www.carbit.com.cn/x?ssid=CFMOTO1&pwd=&action=1"))
        XCTAssertNil(BikeQR.failureHint(for: "http://www.carbit.com.cn/x?ssid=CFMOTO1&pwd=&action=1"))
        XCTAssertNil(BikeQR.parse("http://www.carbit.com.cn/x?ssid=CFMOTO1&action=1&bm=112233445566"))
    }

    func testBmWithoutSsidSynthesizesHotspot() {
        check("http://www.carbit.com.cn/x?action=1&bm=112233445566", ssid: "PHONE-HOTSPOT-445566", pwd: "", auth: nil,
              mac: "11:22:33:44:55:66", name: "Phone hotspot (44:55:66)", action: 129, modelId: nil, sn: nil,
              ap: true, p2p: false, hs: true)
    }

    func testFragmentDropsEverythingAfterHash() {
        let q = BikeQR.parse("http://www.carbit.com.cn/x?ssid=A&pwd=p#frag&action=8")
        XCTAssertEqual(q?.ssid, "A")
        XCTAssertEqual(q?.password, "p")
        XCTAssertEqual(q?.action, 0)
    }

    func testLowercaseCarbitToken() {
        let q = BikeQR.parse("carbitdc0d3024876d")
        XCTAssertEqual(q?.ssid, "PHONE-HOTSPOT-24876d")
        XCTAssertEqual(q?.mac, "dc:0d:30:24:87:6d")
        XCTAssertEqual(q?.action, 128)
        XCTAssertEqual(q?.name, "Phone hotspot (24:87:6d)")
    }

    func testMoriniPasswordWithSpaceAndMacFromMachineId() {
        let q = BikeQR.parse("http://admin.motomorini.com/app.html?Wifi=MLN_1234#pass word#&MachineID=dc0d30da1b6c")
        XCTAssertEqual(q?.ssid, "MLN_1234")
        XCTAssertEqual(q?.password, "pass word")
        XCTAssertEqual(q?.mac, "dc:0d:30:da:1b:6c")
        XCTAssertEqual(q?.sn, "dc0d30da1b6c")
        XCTAssertNil(q?.modelId)
        XCTAssertEqual(q?.action, 1)
    }

    func testMoriniWithoutWifiField() {
        let raw = "http://admin.motomorini.com/app.html?MachineID=dc0d30da1b6c"
        XCTAssertNil(BikeQR.parse(raw))
        XCTAssertEqual(BikeQR.failureHint(for: raw),
                       "Moto Morini QR has no Wifi= field \u{2014} open the phone-link / MotoFun QR on the dash")
    }

    func testThinkerrideKeyValueForm() {
        let q = BikeQR.parse("http://g.thinkerride.com?ssid=KOVE_1&password=abc%20def&ap=1")
        XCTAssertEqual(q?.ssid, "KOVE_1")
        XCTAssertEqual(q?.password, "abc def")
        XCTAssertEqual(q?.action, 1)
        XCTAssertEqual(q?.auth, "wpa2-psk")
    }

    func testCarbitDownloadQr() {
        let raw = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426"
        XCTAssertNil(BikeQR.parse(raw))
        XCTAssertEqual(BikeQR.failureHint(for: raw),
                       "that is the Carbit app-download QR, not pairing \u{2014} open MotoPlay / EasyConnect so the Wi-Fi QR (SSID + password) stays on screen")
    }

    func testPlainUrl() {
        XCTAssertNil(BikeQR.parse("http://example.com/app"))
        XCTAssertEqual(BikeQR.failureHint(for: "http://example.com/app"),
                       "URL QR without ssid/pwd \u{2014} need the dash pairing QR (Carbit / EasyConnect / MotoFun / Thinkerride SoftAP), or enable phone hotspot if the dash asks for it")
    }

    // MARK: Other parse rules

    func testEmptyAndWhitespace() {
        XCTAssertNil(BikeQR.parse(""))
        XCTAssertNil(BikeQR.parse("  \n\t "))
        XCTAssertNil(BikeQR.parse("\u{00A0}\u{3000}"))
    }

    func testRawIsKotlinTrimmed() {
        let q = BikeQR.parse("  \u{00A0}CARBITDC0D3024876D\n")
        XCTAssertEqual(q?.raw, "CARBITDC0D3024876D")
        // U+0085 is not Kotlin whitespace → stays and breaks the token match
        XCTAssertNil(BikeQR.parse("CARBITDC0D3024876D\u{0085}"))
    }

    func testDuplicateKeysLastWins() {
        let q = BikeQR.parse("http://x/?ssid=A&pwd=one&pwd=two&ssid=B")
        XCTAssertEqual(q?.ssid, "B")
        XCTAssertEqual(q?.password, "two")
    }

    func testMalformedEscapeKeepsRawValue() {
        // Android URLDecoder throws on a lone % → the raw (undecoded) value is kept, '+' included.
        let q = BikeQR.parse("http://x/?ssid=Bike+1&pwd=50%+off&action=1")
        XCTAssertEqual(q?.ssid, "Bike 1")
        XCTAssertEqual(q?.password, "50%+off")
        // Malformed UTF-8 → U+FFFD
        XCTAssertEqual(BikeQR.parse("http://x/?ssid=A%C3&pwd=p")?.ssid, "A\u{FFFD}")
    }

    func testActionParsing() {
        XCTAssertEqual(BikeQR.parse("http://x/?ssid=A&pwd=p&action=%2B9")?.action, 9)
        XCTAssertEqual(BikeQR.parse("http://x/?ssid=A&pwd=p&action=+9")?.action, 0)   // '+' form-decodes to ' '
        XCTAssertEqual(BikeQR.parse("http://x/?ssid=A&pwd=p&action=9.0")?.action, 0)
        XCTAssertEqual(BikeQR.parse("http://x/?ssid=A&pwd=p&action=x9")?.action, 0)
        XCTAssertEqual(BikeQR.parse("http://x/?ssid=A&pwd=p&action=2147483648")?.action, 0)
        // A negative action has bit 7 set (Kotlin Int) → phone hotspot path
        let neg = BikeQR.parse("http://x/?action=-1&ssid=A")
        XCTAssertEqual(neg?.action, -1)
        XCTAssertEqual(neg?.password, "")
    }

    func testSsidTrimmedPasswordNot() {
        let q = BikeQR.parse("http://x/?ssid=%20Bike%20&pwd=%20p%20")
        XCTAssertEqual(q?.ssid, "Bike")
        XCTAssertEqual(q?.password, " p ")
    }

    func testBlankNameIsAbsent() {
        XCTAssertNil(BikeQR.parse("http://x/?ssid=A&pwd=p&name=+")?.name)
        XCTAssertEqual(BikeQR.parse("http://x/?ssid=A&pwd=p&name=N")?.name, "N")
    }

    func testChannelAndAuthPassThrough() {
        let q = BikeQR.parse("http://x/?ssid=A&pwd=p&channel=6&auth=WPA2")
        XCTAssertEqual(q?.channel, "6")
        XCTAssertEqual(q?.auth, "WPA2")
    }

    func testMoriniRequiresHashAfterSsid() {
        XCTAssertNil(BikeQR.parse("http://admin.motomorini.com/app.html?Wifi=ML1&x=1"))
        XCTAssertNil(BikeQR.parse("http://admin.motomorini.com/app.html?Wifi=ML1##aa"))   // empty password
        let q = BikeQR.parse("http://admin.motomorini.com/app.html?wifi=ML1#pw#zz")       // case-insensitive key, bad MAC
        XCTAssertEqual(q?.ssid, "ML1")
        XCTAssertEqual(q?.password, "pw")
        XCTAssertNil(q?.mac)
    }

    func testThinkerrideAlternativeKeysAndFirstTokens() {
        XCTAssertEqual(BikeQR.parse("http://g.thinkerride.com?pass=xyz&ssid=S")?.password, "xyz")
        let q = BikeQR.parse("CQKY_a&b&c&AP")
        XCTAssertEqual(q?.ssid, "CQKY_a")
        XCTAssertEqual(q?.password, "b")
        XCTAssertNil(BikeQR.parse("cqky_a#&b"))   // query cut at '#' leaves no password
    }

    // MARK: Log lines

    func testLogLinesNeverContainThePassword() {
        let q = BikeQR.parse("http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457")!
        XCTAssertEqual(q.parsedLogLine,
                       "QR parsed: ssid=CFMOTO-f46457 mac=6c:09:4a:0f:6c:f8 action=9 (ap=true, p2p=true, hotspot=false) modelId=37416 sn=peTz")
        XCTAssertFalse(q.parsedLogLine.contains("59a9cddc94"))
        let t = BikeQR.parse("CQKY_5e1c6cb10&81316044&ap=1")!
        XCTAssertEqual(t.parsedLogLine,
                       "QR parsed: ssid=CQKY_5e1c6cb10 mac=null action=1 (ap=true, p2p=false, hotspot=false) modelId=null sn=null")
        XCTAssertEqual(BikeQR.parseFailedLogLine(for: "hello"), "QR parse FAILED \u{2014} missing ssid/pwd?")
        XCTAssertEqual(BikeQR.parseFailedLogLine(for: "http://example.com/app"),
                       "QR parse FAILED \u{2014} missing ssid/pwd? (URL QR without ssid/pwd \u{2014} need the dash pairing QR (Carbit / EasyConnect / MotoFun / Thinkerride SoftAP), or enable phone hotspot if the dash asks for it)")
    }

    // MARK: formatMac

    func testFormatMac() {
        XCTAssertEqual(BikeQR.formatMac("6C:09:4A:0F:6C:F8"), "6c:09:4a:0f:6c:f8")
        XCTAssertEqual(BikeQR.formatMac("dc0d30da1b6c"), "dc:0d:30:da:1b:6c")
        XCTAssertEqual(BikeQR.formatMac("aa-bb-cc-dd-ee-ff"), "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(BikeQR.formatMac("zz:zz:zz:zz:zz"), "zz:zz:zz:zz:zz")   // returned unchanged
        XCTAssertEqual(BikeQR.formatMac("AA:BB:CC:DD:EE"), "AA:BB:CC:DD:EE")   // 10 hex, has ':' and ≥ 11 → unchanged
        XCTAssertNil(BikeQR.formatMac("12:34:56"))
        XCTAssertNil(BikeQR.formatMac("aabbccddeeff00"))
        XCTAssertNil(BikeQR.formatMac(""))
        XCTAssertNil(BikeQR.formatMac("   "))
        XCTAssertNil(BikeQR.formatMac(nil))
        // Kotlin isDigit() accepts Unicode decimal digits (Arabic-Indic here)
        XCTAssertEqual(BikeQR.formatMac("\u{0660}\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}\u{0667}\u{0668}\u{0669}AB"),
                       "\u{0660}\u{0661}:\u{0662}\u{0663}:\u{0664}\u{0665}:\u{0666}\u{0667}:\u{0668}\u{0669}:ab")
    }

    // MARK: Hints

    func testHintOrderAndStrings() {
        XCTAssertEqual(BikeQR.failureHint(for: "http://www.carbit.com.cn/x?action=1&bm=zz"),
                       "this dash joins your phone hotspot \u{2014} turn on Android hotspot with the SSID/password shown on the dash, then Connect")
        XCTAssertEqual(BikeQR.failureHint(for: "CARBITDC0D3024876D"),
                       "Carbit ID QR \u{2014} enable Android hotspot with the SSID/password on the dash, then Connect")
        XCTAssertEqual(BikeQR.failureHint(for: "Download KOVE APP"),
                       "Kove/Thinkerride \u{2014} need the SoftAP pairing QR (SSID+password on the dash, or g.thinkerride.com?SSID&PWD&ap=1). Garage \u{2192} enter SSID/pwd if the QR is only \u{201C}download KOVE APP\u{201D}")
        XCTAssertEqual(BikeQR.failureHint(for: "kove ... DOWNLOAD"), BikeQR.failureHint(for: "Download KOVE APP"))
        XCTAssertNotNil(BikeQR.failureHint(for: "color:red vin:123"))      // rule 2 second form
        XCTAssertNil(BikeQR.failureHint(for: "hello world"))
        XCTAssertNil(BikeQR.failureHint(for: "https://example.com/?ssid=x"))
        XCTAssertNil(BikeQR.failureHint(for: "http://admin.motomorini.com/?wifi=x"))  // 'Wifi=' match ignores case
        // rule 1 wins over rule 7
        XCTAssertTrue(BikeQR.failureHint(for: "HTTP://ADMIN.MOTOMORINI.COM/x")!.hasPrefix("Moto Morini"))
        // first-match order: carbit download (3) before phone hotspot (4)
        XCTAssertTrue(BikeQR.failureHint(for: "http://www.carbit.com.cn/downsdk?bm=1")!.hasPrefix("that is the Carbit"))
    }

    func testIosHintWording() {
        XCTAssertEqual(BikeQR.iosFailureHint(for: "CARBITDC0D3024876D"),
                       "Carbit ID QR \u{2014} enable Personal Hotspot with the SSID/password on the dash, then Connect")
        XCTAssertEqual(BikeQR.iosFailureHint(for: "http://example.com/app"), BikeQR.failureHint(for: "http://example.com/app"))
        XCTAssertNil(BikeQR.iosFailureHint(for: "nothing"))
    }

    // MARK: Manual entry (§2.9, §2.15, app-features §4.3)

    func testBuildManualBasic() {
        XCTAssertEqual(BikeQR.manualPairingURL(ssid: "CFMOTO4288", password: "e278450c", displayName: "My bike"),
                       "http://manual.opencfmoto.local/?ssid=CFMOTO4288&pwd=e278450c&auth=wpa2-psk&action=1&name=My%20bike")
        let q = BikeQR.buildManual(ssid: "CFMOTO4288", password: "e278450c", displayName: "My bike")
        XCTAssertEqual(q?.raw, "http://manual.opencfmoto.local/?ssid=CFMOTO4288&pwd=e278450c&auth=wpa2-psk&action=1&name=My%20bike")
        XCTAssertEqual(q?.ssid, "CFMOTO4288")
        XCTAssertEqual(q?.password, "e278450c")
        XCTAssertEqual(q?.auth, "wpa2-psk")
        XCTAssertEqual(q?.name, "My bike")
        XCTAssertEqual(q?.action, 1)
        XCTAssertEqual(q?.supportsAp, true)
    }

    func testBuildManualEncodingRoundTrip() {
        XCTAssertEqual(BikeQR.manualPairingURL(ssid: " TRK702X ", password: "p@ss w+rd&#1", displayName: nil),
                       "http://manual.opencfmoto.local/?ssid=TRK702X&pwd=p%40ss%20w%2Brd%26%231&auth=wpa2-psk&action=1&name=TRK702X")
        let q = BikeQR.buildManual(ssid: " TRK702X ", password: "p@ss w+rd&#1")
        XCTAssertEqual(q?.password, "p@ss w+rd&#1")
        XCTAssertEqual(q?.ssid, "TRK702X")
        XCTAssertEqual(q?.name, "TRK702X")
        XCTAssertEqual(BikeQR.manualPairingURL(ssid: "CFMOTO-123", password: "pass word"),
                       "http://manual.opencfmoto.local/?ssid=CFMOTO-123&pwd=pass%20word&auth=wpa2-psk&action=1&name=CFMOTO-123")
    }

    func testBuildManualRequiresBoth() {
        XCTAssertNil(BikeQR.buildManual(ssid: "  ", password: "x"))
        XCTAssertNil(BikeQR.buildManual(ssid: "S", password: ""))
        // blank display name falls back to the SSID; password spaces kept
        let q = BikeQR.buildManual(ssid: "S", password: "  ", displayName: "   ")
        XCTAssertEqual(q?.name, "S")
        XCTAssertEqual(q?.password, "  ")
    }

    func testBuildManualUnicode() {
        let q = BikeQR.buildManual(ssid: "Moto é", password: "pässwörd€", displayName: "Mi moto \u{1F3CD}")
        XCTAssertEqual(q?.raw, "http://manual.opencfmoto.local/?ssid=Moto%20%C3%A9&pwd=p%C3%A4ssw%C3%B6rd%E2%82%AC&auth=wpa2-psk&action=1&name=Mi%20moto%20%F0%9F%8F%8D")
        XCTAssertEqual(q?.ssid, "Moto é")
        XCTAssertEqual(q?.password, "pässwörd€")
        XCTAssertEqual(q?.name, "Mi moto \u{1F3CD}")
    }
}
