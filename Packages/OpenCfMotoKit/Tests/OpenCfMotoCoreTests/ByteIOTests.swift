import XCTest
@testable import OpenCfMotoCore

final class ByteIOTests: XCTestCase {
    func testRoundTrip() throws {
        var w = ByteWriter()
        w.i32le(-2); w.u16le(0xBEEF); w.u8(7)
        var r = ByteReader(w.data)
        XCTAssertEqual(try r.i32le(), -2)
        XCTAssertEqual(try r.u16le(), 0xBEEF)
        XCTAssertEqual(try r.u8(), 7)
        XCTAssertThrowsError(try r.u8())
        XCTAssertEqual(Data(hexString: "fe ff ff ff")!, Data([0xfe,0xff,0xff,0xff]))
    }
}
