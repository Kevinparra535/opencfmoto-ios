// SPDX-License-Identifier: AGPL-3.0-or-later
// Kotlin / JVM / Android string semantics used by the QR parser and the persisted formats.

import XCTest
@testable import OpenCfMotoCore

final class QRJvmTextTests: XCTestCase {

    func testKotlinTrim() {
        XCTAssertEqual(AppJvmText.trim("  a b \t\n"), "a b")
        XCTAssertEqual(AppJvmText.trim("\u{00A0}x\u{2007}"), "x")        // no-break spaces are isSpaceChar
        XCTAssertEqual(AppJvmText.trim("\u{3000}x\u{2028}"), "x")        // ideographic space, line separator
        XCTAssertEqual(AppJvmText.trim("\u{001C}x\u{001F}"), "x")        // FS…US are Java whitespace
        XCTAssertEqual(AppJvmText.trim("\u{0085}x"), "\u{0085}x")        // NEL is not
        XCTAssertEqual(AppJvmText.trim("\u{200B}x\u{FEFF}"), "\u{200B}x\u{FEFF}") // ZWSP / BOM are not
        XCTAssertEqual(AppJvmText.trim(" \u{00A0} "), "")
        XCTAssertTrue(AppJvmText.isBlank(""))
        XCTAssertTrue(AppJvmText.isBlank(" \t\u{2003}"))
        XCTAssertFalse(AppJvmText.isBlank(" a "))
    }

    func testAndroidURLDecode() {
        XCTAssertEqual(AppJvmText.androidURLDecode("a+b"), "a b")
        XCTAssertEqual(AppJvmText.androidURLDecode("%41%42c"), "ABc")
        XCTAssertEqual(AppJvmText.androidURLDecode("%e2%82%ac"), "\u{20AC}")
        XCTAssertEqual(AppJvmText.androidURLDecode("%C3"), "\u{FFFD}")
        XCTAssertEqual(AppJvmText.androidURLDecode("%E2+%82"), "\u{FFFD} \u{FFFD}")
        XCTAssertEqual(AppJvmText.androidURLDecode("plain"), "plain")
        XCTAssertEqual(AppJvmText.androidURLDecode(""), "")
        // Android throws → nil
        XCTAssertNil(AppJvmText.androidURLDecode("%"))
        XCTAssertNil(AppJvmText.androidURLDecode("%4"))
        XCTAssertNil(AppJvmText.androidURLDecode("abc%"))
        XCTAssertNil(AppJvmText.androidURLDecode("%41%"))
        XCTAssertNil(AppJvmText.androidURLDecode("%zz"))
        XCTAssertNil(AppJvmText.androidURLDecode("%+1"))   // desktop Java would accept; Android rejects
        XCTAssertNil(AppJvmText.androidURLDecode("%-1"))
    }

    func testAndroidUriEncode() {
        XCTAssertEqual(AppJvmText.androidUriEncode("p@ss w+rd&#1"), "p%40ss%20w%2Brd%26%231")
        XCTAssertEqual(AppJvmText.androidUriEncode("AZaz09_-!.~'()*"), "AZaz09_-!.~'()*")
        XCTAssertEqual(AppJvmText.androidUriEncode("é€\u{1F600}"), "%C3%A9%E2%82%AC%F0%9F%98%80")
        XCTAssertEqual(AppJvmText.androidUriEncode("a/b?c=d"), "a%2Fb%3Fc%3Dd")
        XCTAssertEqual(AppJvmText.androidUriEncode(""), "")
    }

    func testToIntOrNull() {
        XCTAssertEqual(AppJvmText.toIntOrNull("9"), 9)
        XCTAssertEqual(AppJvmText.toIntOrNull("+9"), 9)
        XCTAssertEqual(AppJvmText.toIntOrNull("-9"), -9)
        XCTAssertEqual(AppJvmText.toIntOrNull("007"), 7)
        XCTAssertEqual(AppJvmText.toIntOrNull("2147483647"), 2_147_483_647)
        XCTAssertNil(AppJvmText.toIntOrNull("2147483648"))
        XCTAssertEqual(AppJvmText.toIntOrNull("-2147483648"), -2_147_483_648)
        XCTAssertNil(AppJvmText.toIntOrNull("-2147483649"))
        XCTAssertNil(AppJvmText.toIntOrNull(""))
        XCTAssertNil(AppJvmText.toIntOrNull("+"))
        XCTAssertNil(AppJvmText.toIntOrNull("-"))
        XCTAssertNil(AppJvmText.toIntOrNull(" 1"))
        XCTAssertNil(AppJvmText.toIntOrNull("1 "))
        XCTAssertNil(AppJvmText.toIntOrNull("0x10"))
        XCTAssertNil(AppJvmText.toIntOrNull("1.0"))
        XCTAssertEqual(AppJvmText.toIntOrNull("\u{0661}\u{0662}"), 12)   // Arabic-Indic digits (Character.digit)
    }

    func testIgnoreCaseMatching() {
        XCTAssertTrue(AppJvmText.containsIgnoreCase("Download KOVE APP", "kove app"))
        XCTAssertTrue(AppJvmText.containsIgnoreCase("x SSID=y", "ssid="))
        XCTAssertTrue(AppJvmText.containsIgnoreCase("\u{017F}sid=", "ssid="))          // ſ ~ s
        XCTAssertTrue(AppJvmText.containsIgnoreCase("\u{212A}ove", "kove"))            // KELVIN SIGN ~ k
        XCTAssertTrue(AppJvmText.containsIgnoreCase("v\u{0130}n:", "vin:"))           // İ ~ i
        XCTAssertTrue(AppJvmText.containsIgnoreCase("v\u{0131}n:", "vin:"))           // ı ~ i
        XCTAssertFalse(AppJvmText.containsIgnoreCase("ss1d=", "ssid="))
        XCTAssertFalse(AppJvmText.containsIgnoreCase("ab", "abc"))
        XCTAssertTrue(AppJvmText.containsIgnoreCase("abc", ""))
        XCTAssertTrue(AppJvmText.startsWithIgnoreCase("HtTp://x", "http"))
        XCTAssertFalse(AppJvmText.startsWithIgnoreCase(" http", "http"))
        XCTAssertTrue(AppJvmText.equalsIgnoreCase("AP", "ap"))
        XCTAssertFalse(AppJvmText.equalsIgnoreCase("ap ", "ap"))
    }

    func testJavaHashCode() {
        XCTAssertEqual(AppJvmText.javaHashCode(""), 0)
        XCTAssertEqual(AppJvmText.javaHashCode("a"), 97)
        XCTAssertEqual(AppJvmText.javaHashCode("http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457"),
                       1_489_888_115)
        XCTAssertEqual(AppJvmText.javaHashCode("http://manual.opencfmoto.local/?ssid=CFMOTO-123&pwd=pass%20word&auth=wpa2-psk&action=1&name=CFMOTO-123"),
                       1_909_166_269)
        XCTAssertEqual(AppJvmText.javaHashCode("CARBIT0123456789AB"), -1_584_102_369)
        // UTF-16 units, not scalars: "😀" = D83D DE00
        XCTAssertEqual(AppJvmText.javaHashCode("\u{1F600}"), Int32(0xD83D) &* 31 &+ Int32(0xDE00))
    }

    func testTakeLastUTF16() {
        XCTAssertEqual(AppJvmText.takeLastUTF16("dd:0d:30:24:87:6d", 8), "24:87:6d")
        XCTAssertEqual(AppJvmText.takeLastUTF16("abc", 8), "abc")
        XCTAssertEqual(AppJvmText.takeLastUTF16("a\u{1F600}", 1), "\u{FFFD}")   // half a surrogate pair
    }

    func testSplitHelpers() {
        XCTAssertEqual(AppJvmText.split("a&&b&", "&"), ["a", "", "b", ""])
        XCTAssertEqual(AppJvmText.split2("p#m#x", "#"), ["p", "m#x"])
        XCTAssertEqual(AppJvmText.split2("p", "#"), ["p"])
        XCTAssertEqual(AppJvmText.substringAfter("a?b?c", "?", missing: "-"), "b?c")
        XCTAssertEqual(AppJvmText.substringAfter("abc", "?", missing: "-"), "-")
        XCTAssertEqual(AppJvmText.substringBefore("a#b#c", "#"), "a")
        // a delimiter followed by a combining mark is still a delimiter (UTF-16 semantics)
        XCTAssertEqual(AppJvmText.substringBefore("x#\u{0301}y", "#"), "x")
    }
}
