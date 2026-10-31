// SPDX-License-Identifier: AGPL-3.0-or-later
// LogRedactor vectors (LogRedactorTest.kt, session-network.md §9.2, app-features.md §6.2) and the iOS
// parse-based QR password masking.

import XCTest
@testable import OpenCfMotoCore

final class RedactorTests: XCTestCase {

    func testRepoVectors() {
        let out = LogRedactor.redact("qr ssid=CFMOTO-x&pwd=supersecret&modelid=1")
        XCTAssertTrue(out.contains("pwd=\u{00AB}redacted\u{00BB}"))
        XCTAssertFalse(out.contains("supersecret"))
        XCTAssertTrue(out.contains("ssid=CFMOTO-x"))
        let serial = LogRedactor.redact(#"{"HUID":"CRCP230501740"}"#)
        XCTAssertTrue(serial.contains("CRCP"))
        XCTAssertFalse(serial.contains("CRCP230501740"))
    }

    func testExactOutputs() {
        let m = "\u{00AB}redacted\u{00BB}"
        let cases: [(String, String)] = [
            ("qr ssid=CFMOTO-x&pwd=supersecret&modelid=1", "qr ssid=CFMOTO-x&pwd=\(m)&modelid=1"),
            (#"{"HUID":"CRCP230501740"}"#, "{\"HUID\":\"CRCP\u{2026}********\"}"),
            ("QR raw: http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457",
             "QR raw: http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=\(m)&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457"),
            (#"CLIENT_INFO {"HUID":"6GUVA2C00100055","HUName":"CFMOTO-805120","btPin":"1234"}"#,
             "CLIENT_INFO {\"HUID\":\"6GUV\u{2026}********\",\"HUName\":\"CFMOTO-805120\",\"btPin\":\"\(m)\"}"),
            (#"{"password" : "hunter2", "psk":"abc"}"#, "{\"password\" : \"\(m)\", \"psk\":\"\(m)\"}"),
            (#"OTA {"port":11021,"userName":"carbit_ec_ftp_ota","pwd":"$Example2024@"}"#,
             "OTA {\"port\":11021,\"userName\":\"carbit_ec_ftp_ota\",\"pwd\":\"\(m)\"}"),
            (#"…len=70 {"port":11021,"userName":"carbit_ec_ftp_ota","pwd":"$Example2024@"}"#,
             "\u{2026}len=70 {\"port\":11021,\"userName\":\"carbit_ec_ftp_ota\",\"pwd\":\"\(m)\"}"),
            (#"check sn {"client_set":"easy_conn","sn":"DSXXZMHNFV3DEXEBB3PZ2"}"#,
             "check sn {\"client_set\":\"easy_conn\",\"sn\":\"DSXX\u{2026}********\"}"),
            (#"CHECK_SN from bike: {"client_set":"easy_conn","sn":"DSXXZMHNFV3DEXEBB3PZ2"}"#,
             "CHECK_SN from bike: {\"client_set\":\"easy_conn\",\"sn\":\"DSXX\u{2026}********\"}"),
            (#"{"uuid":"ab12"}"#, #"{"uuid":"ab12"}"#),
            ("carHuid=6WX0AT231300200 HUID=abc sn=peTz", "carHuid=6WX0\u{2026}******** HUID=abc sn=peTz"),
            ("carHuid=6GUVA2C00100055 HUName=CFDL16-6GUV", "carHuid=6GUV\u{2026}******** HUName=CFDL16-6GUV"),
            ("Passphrase=foo bar&PSK=x", "Passphrase=\(m) bar&PSK=\(m)"),
            ("mypwd=secret", "mypwd=secret"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(LogRedactor.redact(input), expected, input)
            XCTAssertEqual(LogRedactor.redactAll(input), expected, "redactAll " + input)
        }
    }

    func testAndroidLeaksAreFixedByParsing() {
        let m = "\u{00AB}redacted\u{00BB}"
        let morini = "QR raw: http://admin.motomorini.com/app.html?Wifi=ML174167#12345678#dc0d30da1b6c&MachineID=dc0d30da1b6c&ProductID=00297"
        let thinker = "QR raw: http://g.thinkerride.com?CQKY_5e1c6cb10&81316044&ap=1"
        // Android parity: the regexes leave these unchanged (GAP)
        XCTAssertEqual(LogRedactor.redact(morini), morini)
        XCTAssertEqual(LogRedactor.redact(thinker), thinker)
        // iOS: parse-based masking
        XCTAssertEqual(LogRedactor.redactAll(morini),
                       "QR raw: http://admin.motomorini.com/app.html?Wifi=ML174167#\(m)#dc0d30da1b6c&MachineID=dc0d30da1b6c&ProductID=00297")
        XCTAssertEqual(LogRedactor.redactAll(thinker), "QR raw: http://g.thinkerride.com?CQKY_5e1c6cb10&\(m)&ap=1")
        XCTAssertEqual(LogRedactor.redactAll("bare CQKY_5e1c6cb10&81316044&ap=1 scanned"), "bare CQKY_5e1c6cb10&\(m)&ap=1 scanned")
        XCTAssertEqual(LogRedactor.redactAll("x Wifi=MLN_1234#pass word#&MachineID=dc0d30da1b6c"),
                       "x Wifi=MLN_1234#\(m)#&MachineID=dc0d30da1b6c")
        XCTAssertEqual(LogRedactor.redactAll("kove http://g.thinkerride.com?ssid=KOVE_1&password=abc%20def&ap=1"),
                       "kove http://g.thinkerride.com?ssid=KOVE_1&password=\(m)&ap=1")
        // manual-entry URLs are covered by the pwd= rule
        XCTAssertEqual(LogRedactor.redactAll("http://manual.opencfmoto.local/?ssid=TRK702X&pwd=p%40ss%20w%2Brd%26%231&auth=wpa2-psk&action=1&name=TRK702X"),
                       "http://manual.opencfmoto.local/?ssid=TRK702X&pwd=\(m)&auth=wpa2-psk&action=1&name=TRK702X")
        // two QRs in one line
        XCTAssertEqual(LogRedactor.redactAll("a http://g.thinkerride.com?S1&P1secret&ap=1 b http://g.thinkerride.com?S2&P2secret&ap=1"),
                       "a http://g.thinkerride.com?S1&\(m)&ap=1 b http://g.thinkerride.com?S2&\(m)&ap=1")
        // only whole fields are masked: a 1-char password does not mangle the URL
        XCTAssertEqual(LogRedactor.redactAll("http://g.thinkerride.com?S1&p&ap=1"), "http://g.thinkerride.com?S1&\(m)&ap=1")
        XCTAssertEqual(LogRedactor.redactAll("http://admin.motomorini.com/app.html?Wifi=ML1#  pw  #aabbccddeeff"),
                       "http://admin.motomorini.com/app.html?Wifi=ML1#  \(m)  #aabbccddeeff")
        // lines without QRs are untouched
        XCTAssertEqual(LogRedactor.redactAll("[:10920] sent frame #5 (31442 b)"), "[:10920] sent frame #5 (31442 b)")
        XCTAssertEqual(LogRedactor.redactAll("see https://example.com/path"), "see https://example.com/path")
    }

    func testMaskTail() {
        XCTAssertEqual(LogRedactor.maskTail("ab12"), "ab12")
        XCTAssertEqual(LogRedactor.maskTail("abcde"), "abcd\u{2026}*")
        XCTAssertEqual(LogRedactor.maskTail("CRCP230501740"), "CRCP\u{2026}********")
        XCTAssertEqual(LogRedactor.maskTail(""), "")
        XCTAssertEqual(LogRedactor.mask, "\u{00AB}redacted\u{00BB}")
    }

    func testReplacementsAreLiteral() {
        // '$' and '\' in the matched text are copied literally (no template interpretation)
        XCTAssertEqual(LogRedactor.redact(#"{"sn":"$1\\0abc"}"#), "{\"sn\":\"$1\\\\\u{2026}****\"}")
    }

    func testInstallOnLogBus() {
        let log = Log()
        LogRedactor.install(on: log)
        log.log(.info, "QR", "raw http://g.thinkerride.com?CQKY_5e1c6cb10&81316044&ap=1")
        XCTAssertTrue(log.export(redacted: true).hasSuffix("I/QR: raw http://g.thinkerride.com?CQKY_5e1c6cb10&\u{00AB}redacted\u{00BB}&ap=1"))
        XCTAssertTrue(log.export(redacted: false).contains("81316044"))
        LogRedactor.install(on: log, includeSecrets: true)
        XCTAssertNil(log.redactor)
        XCTAssertTrue(log.export(redacted: true).contains("81316044"))
    }
}
