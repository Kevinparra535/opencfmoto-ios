// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the dash's low-range toast and voice copy (EN / ES), and its fit: at most two lines of the toast
// pill, every word kept (no ellipsis), never over the speed chip — on the 8 dash canvases.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class DashFuelTextTests: XCTestCase {
    private static let canvases: [(String, DashSize, ScreenMargins)] = [
        ("800×384", DashFixtures.land, .zero),
        ("800×384 margins", DashFixtures.land, ScreenMargins(top: 22, bottom: 10, left: 12, right: 14)),
        ("800×400", DashSize(width: 800, height: 400), .zero),
        ("800×944", DashFixtures.port, .zero),
        ("720×704", DashSize(width: 720, height: 704), ScreenMargins(customised: false, top: 22)),
        ("544×512", DashSize(width: 544, height: 512), .zero),
        ("1024×464", DashSize(width: 1024, height: 464), .zero),
        ("1280×576", DashFixtures.wide, .zero),
    ]

    private let km70 = FuelFormat.range(70, units: .metric)
    private let km8 = FuelFormat.range(8, units: .metric)
    private let mi40 = FuelFormat.range(70, units: .imperial)

    func testToastCopy() {
        XCTAssertEqual(DashStrings.fuelToast(.low, range: km70, .en), "Low range: ~70 km to reserve")
        XCTAssertEqual(DashStrings.fuelToast(.low, range: km70, .es), "Autonomía baja: ~70 km hasta la reserva")
        XCTAssertEqual(DashStrings.fuelToast(.low, range: km8, .en), "Low range: under 10 km to reserve")
        XCTAssertEqual(DashStrings.fuelToast(.low, range: km8, .es), "Autonomía baja: menos de 10 km hasta la reserva")
        XCTAssertEqual(DashStrings.fuelToast(.low, range: mi40, .en), "Low range: ~40 mi to reserve")
        XCTAssertEqual(DashStrings.fuelToast(.low, range: mi40, .es), "Autonomía baja: ~40 mi hasta la reserva")
        XCTAssertEqual(DashStrings.fuelToast(.low, range: FuelFormat.range(4, units: .imperial), .en), "Low range: under 5 mi to reserve")
        XCTAssertEqual(DashStrings.fuelToast(.reserve, range: km70, .en), "On reserve: refuel soon")
        XCTAssertEqual(DashStrings.fuelToast(.reserve, range: km70, .es), "En reserva: carga gasolina pronto")
        XCTAssertEqual(DashStrings.fuelToast(.low, range: km8, .es).count, 47, "the longest toast")
    }

    func testVoiceCopy() {
        XCTAssertEqual(DashStrings.fuelVoice(.low, range: km70, .en), "Low range. About 70 kilometers to reserve.")
        XCTAssertEqual(DashStrings.fuelVoice(.low, range: km70, .es), "Autonomía baja. Unos 70 kilómetros hasta la reserva.")
        XCTAssertEqual(DashStrings.fuelVoice(.low, range: mi40, .en), "Low range. About 40 miles to reserve.")
        XCTAssertEqual(DashStrings.fuelVoice(.low, range: mi40, .es), "Autonomía baja. Unas 40 millas hasta la reserva.")
        XCTAssertEqual(DashStrings.fuelVoice(.low, range: km8, .en), "Low range. Under 10 kilometers to reserve.")
        XCTAssertEqual(DashStrings.fuelVoice(.low, range: km8, .es), "Autonomía baja. Menos de 10 kilómetros hasta la reserva.")
        XCTAssertEqual(DashStrings.fuelVoice(.reserve, range: km70, .en), "You're on reserve. Refuel soon.")
        XCTAssertEqual(DashStrings.fuelVoice(.reserve, range: km70, .es), "Estás en reserva. Carga gasolina pronto.")
    }

    func testEveryToastFitsTwoLinesAndNeverCoversTheSpeedChip() {
        var checked = 0
        for (canvas, size, margins) in Self.canvases {
            for lang in DashLanguage.allCases {
                for level in [FuelAlertLevel.low, .reserve] {
                    for range in [km70, km8, mi40] {
                        let text = DashStrings.fuelToast(level, range: range, lang)
                        for navigating in [true, false] {
                            var m = navigating ? DashFixtures.navigating(size) : DashFixtures.freeRide(size)
                            m.margins = margins
                            m.language = lang
                            let tag = "\(canvas) \(lang) \(navigating ? "navigating" : "free ride") «\(text)»"
                            let measurer = ApproximateTextMeasurer()
                            // the layout rule itself
                            let c = DashLayoutContext(model: m, measurer: measurer)
                            let (_, lines) = DashLayout.overlayPill(c, text: text, font: c.font(15, .medium), topY: 0)
                            XCTAssertLessThanOrEqual(lines, 2, tag)
                            // what the controller draws
                            let ui = DashUIController(measurer: measurer)
                            ui.update(m)
                            ui.showToast(text, now: 10, duration: FuelAlertPolicy.toastSeconds)
                            let list = ui.displayList(now: 11)
                            guard case let .text(_, rect, style)? = list.commands.first(where: {
                                if case let .text(s, _, st) = $0 { return s == text && st.color == DashPalette.toastText }
                                return false
                            }) else {
                                XCTFail("\(tag): no toast text")
                                continue
                            }
                            XCTAssertLessThanOrEqual(style.maxLines, 2, tag)
                            let wrapped = DashTextLayout.wrap(text, maxWidth: rect.width + 0.001, font: style.font,
                                                              maxLines: style.maxLines, measurer: measurer)
                            XCTAssertEqual(wrapped.joined(separator: " "), text, "\(tag): every word kept")
                            XCTAssertFalse(wrapped.joined().contains("\u{2026}"), tag)
                            guard let chip = list.hitRegions.last(where: { $0.id == "speed.chip" })?.rect else {
                                XCTFail("\(tag): no speed chip")
                                continue
                            }
                            for cmd in list.commands {
                                switch cmd {
                                case let .fill(p, color, _) where color == DashPalette.toastFill:
                                    let pill = try! XCTUnwrap(p.controlPointBounds)
                                    XCTAssertFalse(pill.intersects(chip), "\(tag): pill \(pill) over the gauge \(chip)")
                                case let .text(s, r, _) where s == text:
                                    XCTAssertFalse(r.intersects(chip), tag)
                                default:
                                    break
                                }
                            }
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 8 * 2 * 2 * 3 * 2)
    }
}
