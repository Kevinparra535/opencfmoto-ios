// SPDX-License-Identifier: AGPL-3.0-or-later
// AOSP org.json semantics (JSONTokener leniency, opt* coercions, toString / toString(2)) and the
// Java number helpers used by the settings pack, the garage import and the trip files.

import XCTest
@testable import OpenCfMotoCore

final class SettingsOrgJSONTests: XCTestCase {

    private func parse(_ s: String) throws -> JSONValue { try AndroidOrgJSON.parseValue(s) }

    private func message(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch { return "\(error)" }
    }

    // MARK: Writers

    func testCompactNumbersAndEscapes() {
        var o = OrderedJSONObject()
        o.put("a", 12_500.0)
        o.put("b", 45.01)
        o.put("c", 0.0001)
        o.put("d", -0.0)
        o.put("e", 1e20)
        o.put("f", Double(Float(12.3)))
        o.put("g", Int64(1_700_000_000_000))
        o.put("s", "a/b\"c\\d\u{2028}\u{1F}\n\té")
        o.put("n", JSONValue.null)
        o.put("t", true)
        XCTAssertEqual(AndroidOrgJSON.compact(.object(o)),
                       #"{"a":12500,"b":45.01,"c":1.0E-4,"d":-0,"e":1.0E20,"f":12.300000190734863,"g":1700000000000,"s":"a\/b\"c\\d\u2028\u001f\n\té","n":null,"t":true}"#)
    }

    func testPrettyMatchesJSONStringerIndent() {
        var inner = OrderedJSONObject()
        inner.put("x", 1)
        var o = OrderedJSONObject()
        o.put("k", "v")
        o.put("o", inner)
        o.put("e", OrderedJSONObject())
        o.put("a", JSONValue.array([.int(1), .string("z")]))
        o.put("ea", JSONValue.array([]))
        XCTAssertEqual(AndroidOrgJSON.pretty(.object(o)),
                       "{\n  \"k\": \"v\",\n  \"o\": {\n    \"x\": 1\n  },\n  \"e\": {},\n  \"a\": [\n    1,\n    \"z\"\n  ],\n  \"ea\": []\n}")
        XCTAssertEqual(AndroidOrgJSON.pretty(.object(OrderedJSONObject())), "{}")
    }

    // MARK: Tokener

    func testParseStandardAndLenient() throws {
        XCTAssertEqual(try parse(#"{"a":1,"b":[true,null,"x"],"c":{"d":-2.5}}"#),
                       .object(OrderedJSONObject([("a", .int(1)), ("b", .array([.bool(true), .null, .string("x")])),
                                                  ("c", .object(OrderedJSONObject([("d", .double(-2.5))])))])))
        // unquoted names/values, single quotes, '=' / '=>' separators, ';' separators, comments
        let lenient = "{format: 'opencfmoto.settings'; version = 1, k=>v /* c */ # hash\n // line\n }"
        XCTAssertEqual(try parse(lenient),
                       .object(OrderedJSONObject([("format", .string("opencfmoto.settings")), ("version", .int(1)), ("k", .string("v"))])))
        // case-insensitive literals, hex, octal, Java double forms
        XCTAssertEqual(try parse("[TRUE, Null, 0x1F, 017, 08, 1d, 1e3, .5]"),
                       .array([.bool(true), .null, .int(31), .int(15), .double(8), .double(1), .double(1000), .double(0.5)]))
        // separators without values mean null
        XCTAssertEqual(try parse("[,]"), .array([.null, .null]))
        XCTAssertEqual(try parse("[1,]"), .array([.int(1), .null]))
        XCTAssertEqual(try parse("[]"), .array([]))
        // escapes
        XCTAssertEqual(try parse(#""aA\/\q\t""#), .string("aA/q\t"))
        // leading BOM and trailing garbage ignored
        XCTAssertEqual(try parse("\u{FEFF}{\"a\":1} trailing"), .object(OrderedJSONObject([("a", .int(1))])))
        // duplicate keys: last wins, first slot kept
        XCTAssertEqual(try parse(#"{"a":1,"b":2,"a":3}"#), .object(OrderedJSONObject([("a", .int(3)), ("b", .int(2))])))
        // big integers become longs
        XCTAssertEqual(try parse("9223372036854775807"), .int(Int64.max))
        XCTAssertEqual(try parse("9223372036854775808"), .double(9.223372036854775808e18))
    }

    func testParseErrorsUseAOSPMessages() {
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject("") }, "End of input at character 0 of ")
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject("{") }, "End of input at character 1 of {")
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject(#"{"a":1,}"#) }, #"Expected literal value at character 7 of {"a":1,}"#)
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject(#"{"a" 1}"#) }, #"Expected ':' after a at character 6 of {"a" 1}"#)
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject(#"{"a":1 "b":2}"#) }, #"Unterminated object at character 8 of {"a":1 "b":2}"#)
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject(#"{"a":"x"#) }, #"Unterminated string at character 7 of {"a":"x"#)
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject("[1]") }, "Value [1] of type org.json.JSONArray cannot be converted to JSONObject")
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject("not json") }, "Value not of type java.lang.String cannot be converted to JSONObject")
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject("42") }, "Value 42 of type java.lang.Integer cannot be converted to JSONObject")
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject("null") }, "Value null of type org.json.JSONObject$1 cannot be converted to JSONObject")
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject("{1:2}") }, "Names must be strings, but 1 is of type java.lang.Integer at character 2 of {1:2}")
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject(#"{"a":NaN}"#) }, "Forbidden numeric value: NaN")
        XCTAssertEqual(message { try AndroidOrgJSON.parseObject("/* x") }, "Unterminated comment at character 2 of /* x")
        XCTAssertNil(message { try AndroidOrgJSON.parseArray("[NaN]") })      // arrays do not check
        XCTAssertEqual(message { try AndroidOrgJSON.parseArray("{}") }, "Value {} of type org.json.JSONObject cannot be converted to JSONArray")
    }

    // MARK: Coercions

    func testCoercions() {
        XCTAssertEqual(AndroidOrgJSON.toInteger(.string("1.9")), 1)
        XCTAssertEqual(AndroidOrgJSON.toInteger(.string(" 7 ")), 7)
        XCTAssertNil(AndroidOrgJSON.toInteger(.string("abc")))
        XCTAssertEqual(AndroidOrgJSON.toInteger(.double(3.99)), 3)
        XCTAssertEqual(AndroidOrgJSON.toInteger(.double(-3.99)), -3)
        XCTAssertEqual(AndroidOrgJSON.toInteger(.int(4_294_967_301)), 5)          // (int) truncation
        XCTAssertNil(AndroidOrgJSON.toInteger(.bool(true)))
        XCTAssertNil(AndroidOrgJSON.toInteger(.null))
        XCTAssertEqual(AndroidOrgJSON.toLong(.string("1e3")), 1000)
        XCTAssertEqual(AndroidOrgJSON.toDouble(.int(5)), 5)
        XCTAssertEqual(AndroidOrgJSON.toBoolean(.string("True")), true)
        XCTAssertEqual(AndroidOrgJSON.toBoolean(.string("FALSE")), false)
        XCTAssertNil(AndroidOrgJSON.toBoolean(.string("yes")))
        XCTAssertNil(AndroidOrgJSON.toBoolean(.int(1)))
        XCTAssertEqual(AndroidOrgJSON.toString(.double(1)), "1.0")
        XCTAssertEqual(AndroidOrgJSON.toString(.null), "null")
        XCTAssertEqual(AndroidOrgJSON.toString(.array([.int(1), .string("a/b")])), #"[1,"a\/b"]"#)
        let o = OrderedJSONObject([("n", .null), ("d", .double(2.5))])
        XCTAssertTrue(o.orgHas("n"))
        XCTAssertEqual(o.orgOptString("n"), "null")
        XCTAssertEqual(o.orgOptString("missing"), "")
        XCTAssertEqual(o.orgOptString("missing", "fb"), "fb")
        XCTAssertEqual(o.orgOptInt("d"), 2)
        XCTAssertTrue(o.orgOptDouble("missing").isNaN)
        XCTAssertNil(o.orgOptObject("d"))
        XCTAssertEqual([JSONValue.int(1)].orgOptLong(5), 0)
    }

    // MARK: Java numbers

    func testJavaParseDouble() {
        let cases: [(String, Double?)] = [
            ("1e3", 1000), (".5", 0.5), ("5.", 5), ("+.5", 0.5), ("0x1p3", 8), ("0x1.8p1", 3), ("1d", 1), ("2.5F", 2.5),
            ("  2.5  ", 2.5), ("-Infinity", -.infinity), ("1_0", nil), ("1e", nil), ("e1", nil), (".", nil),
            ("infinity", nil), ("0x10", nil), ("", nil), ("1 2", nil), ("١", nil), ("NaNd", nil),
        ]
        for (s, v) in cases {
            XCTAssertEqual(AppJavaNumber.parseDouble(s), v, s)
        }
        XCTAssertTrue(AppJavaNumber.parseDouble("NaN")!.isNaN)
    }

    func testJavaParseLong() {
        XCTAssertEqual(AppJavaNumber.parseLong("17", radix: 8), 15)
        XCTAssertEqual(AppJavaNumber.parseLong("ff", radix: 16), 255)
        XCTAssertEqual(AppJavaNumber.parseLong("-9223372036854775808"), Int64.min)
        XCTAssertNil(AppJavaNumber.parseLong("9223372036854775808"))
        XCTAssertNil(AppJavaNumber.parseLong("8", radix: 8))
        XCTAssertNil(AppJavaNumber.parseLong("+"))
        XCTAssertNil(AppJavaNumber.parseLong(""))
        XCTAssertEqual(AppJavaNumber.parseLong("+42"), 42)
    }

    func testJavaDoubleToString() {
        let cases: [(Double, String)] = [
            (0.001, "0.001"), (0.0001, "1.0E-4"), (1_234_567.0, "1234567.0"), (1e7, "1.0E7"), (12_345_678.9, "1.23456789E7"),
            (45.01, "45.01"), (-2.5, "-2.5"), (100, "100.0"), (1, "1.0"), (0.1, "0.1"), (1e-300, "1.0E-300"),
            (Double.greatestFiniteMagnitude, "1.7976931348623157E308"), (0, "0.0"), (-0.0, "-0.0"),
            (Double(Float(12.3)), "12.300000190734863"), (123_456.789, "123456.789"), (9_999_999.999, "9999999.999"),
        ]
        for (d, s) in cases { XCTAssertEqual(AppJavaNumber.doubleToString(d), s, "\(d)") }
        XCTAssertEqual(AppJavaNumber.doubleToString(.nan), "NaN")
        XCTAssertEqual(AppJavaNumber.doubleToString(-.infinity), "-Infinity")
    }

    func testJavaFormatFixedHalfUpOnShortestDecimal() {
        XCTAssertEqual(AppJavaNumber.formatFixed(1.005, precision: 2), "1.01")     // C printf gives 1.00
        XCTAssertEqual(AppJavaNumber.formatFixed(0.125, precision: 2), "0.13")     // C printf gives 0.12
        XCTAssertEqual(AppJavaNumber.formatFixed(12.345, precision: 2), "12.35")
        XCTAssertEqual(AppJavaNumber.formatFixed(12.5, precision: 2), "12.50")
        XCTAssertEqual(AppJavaNumber.formatFixed(0, precision: 2), "0.00")
        XCTAssertEqual(AppJavaNumber.formatFixed(-0.0, precision: 2), "-0.00")
        XCTAssertEqual(AppJavaNumber.formatFixed(-1.005, precision: 2), "-1.01")
        XCTAssertEqual(AppJavaNumber.formatFixed(9.999, precision: 2), "10.00")
        XCTAssertEqual(AppJavaNumber.formatFixed(0.004, precision: 2), "0.00")
        XCTAssertEqual(AppJavaNumber.formatFixed(0.005, precision: 2), "0.01")
        XCTAssertEqual(AppJavaNumber.formatFixed(0.0004, precision: 2), "0.00")
        XCTAssertEqual(AppJavaNumber.formatFixed(45.0, precision: 6), "45.000000")
        XCTAssertEqual(AppJavaNumber.formatFixed(45.01, precision: 6), "45.010000")
        XCTAssertEqual(AppJavaNumber.formatFixed(45.0078125, precision: 6), "45.007813")  // C: 45.007812
        XCTAssertEqual(AppJavaNumber.formatFixed(-122.4194155, precision: 6), "-122.419416")
        XCTAssertEqual(AppJavaNumber.formatFixed(1e-7, precision: 6), "0.000000")
        XCTAssertEqual(AppJavaNumber.formatFixed(6e-7, precision: 6), "0.000001")
        XCTAssertEqual(AppJavaNumber.formatFixed(1e20, precision: 2), "100000000000000000000.00")
        XCTAssertEqual(AppJavaNumber.formatFixed(2.5, precision: 0), "3")
        XCTAssertEqual(AppJavaNumber.formatFixed(.nan, precision: 2), "NaN")
    }

    func testCasts() {
        XCTAssertEqual(AppJavaNumber.d2i(.nan), 0)
        XCTAssertEqual(AppJavaNumber.d2i(1e10), Int32.max)
        XCTAssertEqual(AppJavaNumber.d2i(-1e10), Int32.min)
        XCTAssertEqual(AppJavaNumber.d2i(-2.9), -2)
        XCTAssertEqual(AppJavaNumber.d2l(1e19), Int64.max)
        XCTAssertEqual(AppJavaNumber.f2i(Float(120.240005)), 120)
        XCTAssertEqual(AppJavaNumber.roundFloat(2.5), 3)
        XCTAssertEqual(AppJavaNumber.roundFloat(-2.5), -2)
        XCTAssertEqual(AppJavaNumber.roundFloat(0.49999997), 0)     // Java 7+ (not floor(x + 0.5f))
        XCTAssertEqual(AppJavaNumber.roundFloat(.nan), 0)
    }
}
