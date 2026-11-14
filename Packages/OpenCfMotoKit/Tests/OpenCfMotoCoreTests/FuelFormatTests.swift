// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: units, rounding and the rider-typed number parsers (decimal and grouping-aware prices).
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class FuelFormatTests: XCTestCase {
    func testRangeReferences() {
        XCTAssertEqual(FuelFormat.range(259.9, units: .metric).text, "~250 km")
        XCTAssertEqual(FuelFormat.range(259.9, units: .metric).number, "250 km")
        XCTAssertEqual(FuelFormat.range(259.9, units: .metric).value, 250)
        XCTAssertEqual(FuelFormat.range(260, units: .metric).text, "~260 km")
        XCTAssertEqual(FuelFormat.range(9.99, units: .metric).text, "<10 km")
        XCTAssertEqual(FuelFormat.range(9.99, units: .metric).number, "10 km")
        XCTAssertTrue(FuelFormat.range(9.99, units: .metric).isUnderStep)
        for bad: Double in [0, -5, .nan, -.infinity] {
            XCTAssertEqual(FuelFormat.range(bad, units: .metric).text, "<10 km", "\(bad)")
            XCTAssertEqual(FuelFormat.range(bad, units: .metric).value, 0)
        }
        XCTAssertFalse(FuelFormat.range(.infinity, units: .metric).text.isEmpty)
        let mi = FuelFormat.range(315.7, units: .imperial)
        XCTAssertEqual(mi.text, "~195 mi")
        XCTAssertEqual(mi.step, 5)
        XCTAssertEqual(mi.unit, "mi")
        XCTAssertEqual(FuelFormat.range(8, units: .imperial).text, "<5 mi")
        XCTAssertEqual(FuelFormat.range(70, units: .metric).number, "70 km")
        XCTAssertEqual(FuelFormat.range(70, units: .imperial).number, "40 mi")
    }

    func testUnitsAndFormatting() {
        XCTAssertEqual(FuelFormat.distanceUnit(.metric), "km")
        XCTAssertEqual(FuelFormat.distanceUnit(.imperial), "mi")
        XCTAssertEqual(FuelFormat.volumeUnit(.litre), "L")
        XCTAssertEqual(FuelFormat.volumeUnit(.usGallon), "gal")
        XCTAssertEqual(FuelFormat.economyUnit(.metric), "km/L")
        XCTAssertEqual(FuelFormat.economyUnit(.imperial), "mpg")
        XCTAssertEqual(FuelFormat.distance(120.4, units: .metric), "120 km")
        XCTAssertEqual(FuelFormat.distance(160.9344, units: .imperial), "100 mi")
        XCTAssertEqual(FuelFormat.volume(17.5, unit: .litre), "17.5 L")
        XCTAssertEqual(FuelFormat.volume(17.5, unit: .litre, decimalSeparator: ","), "17,5 L")
        XCTAssertEqual(FuelFormat.volume(17.5, unit: .usGallon), "4.6 gal")
        XCTAssertEqual(FuelFormat.economy(20.5, units: .metric), "20.5 km/L")
        XCTAssertEqual(FuelFormat.economy(20.5, units: .metric, decimalSeparator: ","), "20,5 km/L")
        XCTAssertEqual(FuelFormat.economy(20.5, units: .imperial), "48.2 mpg")
        XCTAssertEqual(FuelFormat.costPerDistance(0.2125, units: .metric), "0.213")
        XCTAssertEqual(FuelFormat.costPerDistance(4.25, units: .metric), "4.25")
        XCTAssertEqual(FuelFormat.costPerDistance(42.5, units: .metric, decimalSeparator: ","), "42,5")
        XCTAssertEqual(FuelFormat.costPerDistance(212.5, units: .metric), "213")
        XCTAssertEqual(FuelFormat.costPerDistance(1, units: .imperial), "1.61")
    }

    func testVolumeUnitDefaults() {
        XCTAssertEqual(FuelVolumeUnit.defaultFor(units: .imperial, regionCode: "US"), .usGallon)
        XCTAssertEqual(FuelVolumeUnit.defaultFor(units: .imperial, regionCode: nil), .usGallon)
        for r in ["CO", "EC", "PE", "co"] { XCTAssertEqual(FuelVolumeUnit.defaultFor(units: .metric, regionCode: r), .usGallon, r) }
        for r in ["MX", "AR", "ES", "CL"] { XCTAssertEqual(FuelVolumeUnit.defaultFor(units: .metric, regionCode: r), .litre, r) }
        XCTAssertEqual(FuelVolumeUnit.defaultFor(units: .metric, regionCode: nil), .litre)
        XCTAssertEqual(FuelVolumeUnit.litre.rawValue, "L")
        XCTAssertEqual(FuelVolumeUnit.usGallon.rawValue, "gal")
    }

    func testConversionsRoundTrip() {
        for v in [0.0, 1, 3.785411784, 17.5, 22.5, 123.456] {
            XCTAssertEqual(FuelFormat.litres(fromDisplay: FuelFormat.displayVolume(litres: v, unit: .usGallon), unit: .usGallon), v, accuracy: 1e-9)
            XCTAssertEqual(FuelFormat.litres(fromDisplay: v, unit: .litre), v)
            XCTAssertEqual(FuelFormat.km(fromDisplay: FuelFormat.displayDistance(km: v, units: .imperial), units: .imperial), v, accuracy: 1e-9)
            XCTAssertEqual(FuelFormat.kmPerL(fromDisplay: FuelFormat.displayEconomy(kmPerL: v, units: .imperial), units: .imperial), v, accuracy: 1e-9)
            XCTAssertEqual(FuelFormat.pricePerLitre(fromDisplay: FuelFormat.displayPrice(pricePerLitre: v, unit: .usGallon), unit: .usGallon), v, accuracy: 1e-9)
            XCTAssertEqual(FuelFormat.displayDistance(km: v, units: .metric), v)
            XCTAssertEqual(FuelFormat.displayEconomy(kmPerL: v, units: .metric), v)
        }
        XCTAssertEqual(FuelFormat.litres(fromDisplay: 1, unit: .usGallon), 3.785411784)
        XCTAssertEqual(FuelFormat.km(fromDisplay: 1, units: .imperial), 1.609344)
        XCTAssertEqual(FuelFormat.displayEconomy(kmPerL: 1, units: .imperial), 2.352145833)
        XCTAssertEqual(FuelFormat.mpgPerKmPerL, FuelFormat.litresPerGallon / FuelFormat.kmPerMile, accuracy: 1e-9)
        XCTAssertEqual(FuelFormat.pricePerLitre(fromDisplay: 3.785411784, unit: .usGallon), 1, accuracy: 1e-12)
    }

    func testParseDecimal() {
        XCTAssertEqual(FuelFormat.parseDecimal("17,5"), 17.5)
        XCTAssertEqual(FuelFormat.parseDecimal("17.5"), 17.5)
        XCTAssertEqual(FuelFormat.parseDecimal(" 3 "), 3)
        XCTAssertEqual(FuelFormat.parseDecimal("0,5"), 0.5)
        XCTAssertEqual(FuelFormat.parseDecimal(",5"), 0.5)
        for bad in ["", "  ", "1.234,5", "1,234.5", "1.2.3", "-2", "∞", "inf", "nan", "12a", "1e3", "+4", ","] {
            XCTAssertNil(FuelFormat.parseDecimal(bad), bad)
        }
    }

    func testParsePriceWithACommaDecimalLocale() {
        XCTAssertEqual(FuelFormat.parsePrice("15.900", decimalSeparator: ","), 15900)
        XCTAssertEqual(FuelFormat.parsePrice("1.500.000", decimalSeparator: ","), 1_500_000)
        XCTAssertEqual(FuelFormat.parsePrice("15.900,5", decimalSeparator: ","), 15900.5)
        XCTAssertEqual(FuelFormat.parsePrice("4,25", decimalSeparator: ","), 4.25)
        XCTAssertEqual(FuelFormat.parsePrice("4.25", decimalSeparator: ","), 4.25)
        XCTAssertEqual(FuelFormat.parsePrice("15,900", decimalSeparator: ","), 15.9)
        XCTAssertEqual(FuelFormat.parsePrice("15900", decimalSeparator: ","), 15900)
        XCTAssertNil(FuelFormat.parsePrice("1.23.456", decimalSeparator: ","))
        XCTAssertNil(FuelFormat.parsePrice("1,2,3", decimalSeparator: ","))
    }

    func testParsePriceWithADotDecimalLocale() {
        XCTAssertEqual(FuelFormat.parsePrice("15,900", decimalSeparator: "."), 15900)
        XCTAssertEqual(FuelFormat.parsePrice("1,234.5", decimalSeparator: "."), 1234.5)
        XCTAssertEqual(FuelFormat.parsePrice("15.900", decimalSeparator: "."), 15.9)
        XCTAssertEqual(FuelFormat.parsePrice("4,25", decimalSeparator: "."), 4.25)
        XCTAssertEqual(FuelFormat.parsePrice("1,500,000.25", decimalSeparator: "."), 1_500_000.25)
    }

    func testParsePriceRejectsJunk() {
        for sep: Character in [",", "."] {
            for bad in ["", " ", "-4", "4-", "abc", "1e3", "∞", "$4", "1,2.3,4", "1.234,56.7", ".", ","] {
                XCTAssertNil(FuelFormat.parsePrice(bad, decimalSeparator: sep), "\(bad) with \(sep)")
            }
        }
        XCTAssertEqual(FuelFormat.parsePrice(" 4,25 ", decimalSeparator: ","), 4.25, "trimmed")
    }
}
