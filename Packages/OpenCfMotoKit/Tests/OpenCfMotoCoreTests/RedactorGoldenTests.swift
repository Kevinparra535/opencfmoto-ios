// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden vectors from the UPSTREAM Kotlin LogRedactor.kt on a JVM (ASCII inputs: java.util.regex and
// ICU agree there).

import XCTest
@testable import OpenCfMotoCore

final class RedactorGoldenTests: XCTestCase {
    func testRedactMatchesKotlin() {
        for (input, output) in Self.redactions {
            XCTAssertEqual(LogRedactor.redact(input), output, input)
        }
    }
}

extension RedactorGoldenTests {
    static let redactions: [(input: String, output: String)] = [
        ("qr ssid=CFMOTO-x&pwd=supersecret&modelid=1", "qr ssid=CFMOTO-x&pwd=\u{ab}redacted\u{bb}&modelid=1"),
        ("{\"HUID\":\"CRCP230501740\"}", "{\"HUID\":\"CRCP\u{2026}********\"}"),
        ("PWD=abc&x=1", "PWD=\u{ab}redacted\u{bb}&x=1"),
        ("password=\"quoted\"", "password=\u{ab}redacted\u{bb}\"quoted\""),
        ("{\"pwd\":\"\"}", "{\"pwd\":\"\u{ab}redacted\u{bb}\"}"),
        ("{\"PSK\" :  \"x y z\", \"btpin\":\"0000\"}", "{\"PSK\" :  \"\u{ab}redacted\u{bb}\", \"btpin\":\"\u{ab}redacted\u{bb}\"}"),
        ("sn=ABCDEF sn=ABCDE carhuid=XYZ12345678901234567 huid=1", "sn=ABCD\u{2026}** sn=ABCDE carhuid=XYZ1\u{2026}******** huid=1"),
        ("{\"sn\":\"\", \"uuid\":\"12345\", \"carHuid\":\"abcdefghijklmnop\"}", "{\"sn\":\"\", \"uuid\":\"1234\u{2026}*\", \"carHuid\":\"abcd\u{2026}********\"}"),
        ("a pwd= b", "a pwd=\u{ab}redacted\u{bb} b"),
        ("pwd=&psk=", "pwd=\u{ab}redacted\u{bb}&psk=\u{ab}redacted\u{bb}"),
        ("x.pwd=1 _pwd=2 -pwd=3", "x.pwd=\u{ab}redacted\u{bb} _pwd=2 -pwd=\u{ab}redacted\u{bb}"),
        ("{\"password\":\"a\\\"b\"}", "{\"password\":\"\u{ab}redacted\u{bb}\"b\"}"),
        ("passphrase=p1 passphrase=p2", "passphrase=\u{ab}redacted\u{bb} passphrase=\u{ab}redacted\u{bb}"),
        ("[:10922] CLIENT_INFO {\"HUID\":\"6GUVA2C00100055\",\"HUName\":\"CFMOTO-805120\"}", "[:10922] CLIENT_INFO {\"HUID\":\"6GUV\u{2026}********\",\"HUName\":\"CFMOTO-805120\"}"),
        ("sn=123456789012345678901234567890", "sn=1234\u{2026}********"),
        ("{\"sn\": \"x\"}", "{\"sn\": \"x\"}"),
        ("{\"sn\" : 5}", "{\"sn\" : 5}"),
        ("nothing to see here", "nothing to see here"),
        ("", ""),
    ]
}
