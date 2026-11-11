// SPDX-License-Identifier: AGPL-3.0-or-later
// P0 safety rules, over every dash state these tests can build (the P0 brief: "no destructive default focus,
// no destructive neighbour of the default, the speed / limit never covered, doubles never change meaning"):
// 1. ★ on the focus a state opens with never commits a destructive intent — End, a Go that replaces a running
//    route, Set home, Delete, Stop recording, Stop the lap timer — on the map (free ride, navigating, off
//    route, lap card, recording, banner + toast, night, music), in a preview (free ride or over a running
//    route), on the arrival card, in the menu, the search sheet (idle, with results) and the Music sheet.
// 2. Nor does ★ after one knob step either way from it (wrapping) — except on the confirm card, whose only
//    other button IS the action the rider asked for; its own default is the safe «Keep going».
// 3. The speed gauge and the limit sign are the scene's last drawing: nothing drawn after them (sheets,
//    cards, the focus ring, the link banner, a toast) paints over them, on every canvas, and their room is
//    the same with and without a limit sign.
// 4. End takes the menu, its confirmation, ▶ and ★; a Go that replaces a running route asks the same way;
//    the card closes by itself after 8 s without input, committing nothing.
// 5. Doubles never change meaning: on the iOS default map a quick ★★ is one ★ and ◀◀ / ▶▶ are two knob steps
//    at any tempo; on the single-button option (★ = next, ★★ = choose) ★★ activates the control the rider
//    sees focused, never the next one — through the real gesture engine.
// 6. Spanish dash and voice copy is neutral Latin-American.
// 7. Stepping the knob through a scrolled sheet (menu, search, Music) never focuses an item under the
//    gauge, and the ring is drawn; cards behind numbers are opaque; the confirm card shows its whole
//    consequence and nothing half-covered beside it.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class DashSafetyRulesTests: XCTestCase {
    private static let t0: TimeInterval = DashFixtures.musicNow

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

    /// One dash state: its model and how the rider got there from a fresh controller.
    struct State: CustomStringConvertible {
        var name: String
        var model: DashModel
        var setup: (DashUIController) -> Void = { _ in }
        var description: String { name }

        func make() -> DashUIController {
            let ui = DashUIController()
            ui.update(model)
            setup(ui)
            _ = ui.displayList(now: DashSafetyRulesTests.t0 + 0.5)
            return ui
        }
    }

    /// The map states of one canvas, then each of them with its sheets.
    private static func states(_ size: DashSize, _ margins: ScreenMargins) -> [State] {
        func m(_ base: DashModel) -> DashModel { var x = base; x.margins = margins; return x }
        let lap = DashLapTimer(title: "Lap 3 · 1:02.4", meta: "Best 0:59.8 · last 1:01.2")
        var lapFree = m(DashFixtures.freeRide(size)), lapNav = m(DashFixtures.navigating(size))
        lapFree.lapTimer = lap
        lapNav.lapTimer = lap
        var recording = m(DashFixtures.freeRide(size)), recordingNav = m(DashFixtures.navigating(size))
        recording.recording = true
        recordingNav.recording = true
        var overlays = m(DashFixtures.navigating(size))
        overlays.linkBanner = "Reconnecting… the dash keeps the last picture"
        overlays.toastText = "Handlebar buttons control the dash again"
        var night = m(DashFixtures.navigating(size))
        night.isNight = true
        var navPreview = m(DashFixtures.navigating(size))
        navPreview.nav.preview = DashFixtures.preview(size).nav.preview
        var noLimit = m(DashFixtures.navigating(size))
        noLimit.nav.speedLimit = nil
        var slowFix = m(DashFixtures.freeRide(size))
        slowFix.fix = DashFixtures.fix(kmh: 123)
        let maps: [State] = [
            State(name: "free ride", model: m(DashFixtures.freeRide(size))),
            State(name: "free ride, music", model: DashFixtures.withMusic(m(DashFixtures.freeRide(size)))),
            State(name: "free ride, lap timer", model: lapFree),
            State(name: "free ride, recording", model: recording),
            State(name: "free ride, 123 km/h", model: slowFix),
            State(name: "navigating", model: m(DashFixtures.navigating(size))),
            State(name: "navigating, music", model: DashFixtures.withMusic(m(DashFixtures.navigating(size)))),
            State(name: "off route", model: m(DashFixtures.navigating(size, offRoute: true))),
            State(name: "navigating, lap timer", model: lapNav),
            State(name: "navigating, recording", model: recordingNav),
            State(name: "navigating, banner + toast", model: overlays),
            State(name: "navigating, night", model: night),
            State(name: "navigating, no limit sign", model: noLimit),
            State(name: "preview", model: m(DashFixtures.preview(size))),
            State(name: "preview over a running route", model: navPreview),
            State(name: "arrival", model: m(DashFixtures.arrival(size))),
        ]
        var all = maps
        for s in maps where !s.model.inPreview && !s.model.showsArrival {
            all.append(State(name: "\(s.name) · menu", model: s.model) { ui in
                s.setup(ui)
                _ = ui.handle(.key(.home), now: t0)
            })
            all.append(State(name: "\(s.name) · search", model: s.model) { ui in
                s.setup(ui)
                _ = ui.perform(.openSearch, now: t0)
            })
            all.append(State(name: "\(s.name) · search results", model: DashFixtures.withSearchResults(s.model)) { ui in
                s.setup(ui)
                _ = ui.perform(.openSearch, now: t0)
            })
            if s.model.music != nil {
                all.append(State(name: "\(s.name) · Music sheet", model: s.model) { ui in
                    s.setup(ui)
                    _ = ui.perform(.openMusic, now: t0)
                })
            }
        }
        for s in maps where s.model.navigating && !s.model.inPreview {
            all.append(State(name: "\(s.name) · confirm End", model: s.model) { ui in
                s.setup(ui)
                Self.openEndConfirmation(ui)
            })
        }
        all.append(State(name: "preview over a running route · confirm Change", model: navPreview) { ui in
            XCTAssertEqual(ui.state.focusedId, "preview.go")
            XCTAssertEqual(ui.handle(.key(.enter), now: t0), [])
        })
        return all
    }

    /// From the map while navigating: HOME, the knob to «End route…», ★.
    private static func openEndConfirmation(_ ui: DashUIController, file: StaticString = #filePath, line: UInt = #line) {
        _ = ui.handle(.key(.home), now: t0)
        let order = ui.state.focusOrder
        guard let end = order.firstIndex(of: DashFocusEngine.menuEndId),
              let at = ui.state.focusedId.flatMap({ order.firstIndex(of: $0) }) else {
            return XCTFail("no End in the menu", file: file, line: line)
        }
        _ = ui.handle(.knob(end - at), now: t0 + 0.1)
        XCTAssertEqual(ui.handle(.key(.enter), now: t0 + 0.2), [], "End only asks", file: file, line: line)
        XCTAssertEqual(ui.state.sheet, .confirm, file: file, line: line)
    }

    /// The destructive intents, in the context of `m` (what is running).
    private static func destructive(_ intents: [DashIntent], _ m: DashModel) -> [DashIntent] {
        intents.filter {
            switch $0 {
            case .endNavigation, .setHomeHere, .setHome, .deletePlace: return true
            case .go: return m.routeRunning // replaces the running route
            // a new route from here replaces the running one (a circuit becomes its outbound leg, a picked
            // alternative the preferred route — review DASH-SAFE-2)
            case .recalc: return m.routeRunning
            case .toggleRecording: return m.recording // stops the trip log
            case .toggleLapTimer: return m.lapTimer != nil // stops the timer and clears its laps
            default: return false
            }
        }
    }

    private static var everyState: [(String, State)] {
        canvases.flatMap { name, size, margins in states(size, margins).map { (name, $0) } }
    }

    // MARK: 1–2. The default focus and its neighbours

    func testStarOnTheDefaultFocusOrOneKnobStepFromItIsNeverDestructive() {
        var checked = 0
        for (canvas, s) in Self.everyState {
            let tag = "\(canvas) \(s)"
            let probe = s.make()
            let order = probe.state.focusOrder
            guard let def = probe.state.focusedId, order.contains(def) else {
                XCTFail("\(tag): no focus")
                continue
            }
            if probe.state.sheet == .confirm {
                XCTAssertEqual(def, DashFocusEngine.confirmKeepId, "\(tag): the card opens on «Keep going»")
            }
            let ui = s.make()
            XCTAssertEqual(Self.destructive(ui.handle(.key(.enter), now: Self.t0 + 1), s.model), [], "\(tag): ★ on \(def)")
            for step in [-1, 1] where order.count > 1 {
                let n = s.make()
                _ = n.handle(.knob(step), now: Self.t0 + 1)
                let id = n.state.focusedId ?? "-"
                let out = n.handle(.key(.enter), now: Self.t0 + 1.2)
                if n.state.sheet == .confirm || id == DashFocusEngine.confirmActId {
                    // the card's other button is the action itself: exempt by design (asked for, «Keep» default)
                    XCTAssertEqual(id, DashFocusEngine.confirmActId, tag)
                    continue
                }
                XCTAssertEqual(Self.destructive(out, s.model), [], "\(tag): \(step > 0 ? "▶" : "◀") ★ on \(id)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 400)
    }

    func testTheDefaultFocusOfEachStateIsTheSafeOne() {
        let expected: [(String, String)] = [
            ("free ride", "pill"), ("navigating", DashFocusEngine.recenterId), ("preview", "preview.go"),
            ("preview over a running route", "preview.go"), ("arrival", "arrive.done"),
            ("navigating · menu", "menu.recenter"), ("free ride · menu", "menu.recenter"),
            ("navigating · confirm End", DashFocusEngine.confirmKeepId),
            ("preview over a running route · confirm Change", DashFocusEngine.confirmKeepId),
        ]
        let states = Self.states(DashFixtures.land, .zero)
        for (name, id) in expected {
            let s = try! XCTUnwrap(states.first { $0.name == name }, name)
            XCTAssertEqual(s.make().state.focusedId, id, name)
        }
    }

    // MARK: 3. The gauge and the limit sign are never covered

    func testTheSpeedGaugeAndLimitAreDrawnLastAndNeverCovered() {
        var checked = 0
        for (canvas, s) in Self.everyState {
            let tag = "\(canvas) \(s)"
            let ui = s.make()
            for t in [Self.t0 + 1, Self.t0 + 7] { // the ring hidden after a touch only: shown here
                let list = ui.displayList(now: t)
                guard let chip = list.hitRegions.last(where: { $0.id == "speed.chip" })?.rect else {
                    XCTFail("\(tag): no speed gauge")
                    continue
                }
                XCTAssertEqual(list.hitRegions.last?.id, "speed.chip", "\(tag): the last widget")
                XCTAssertEqual(list.hitTest(chip.center)?.id, "speed.chip", tag)
                // its drawing starts with the gauge disc; everything after it is its own drawing (inside it)
                // or an overlay (ring, banner, toast) that stays off it
                guard let start = list.commands.firstIndex(where: {
                    if case let .fill(p, c, _) = $0, c == DashPalette.gaugeFill, let b = p.controlPointBounds { return Self.within(b, chip) }
                    return false
                }) else {
                    XCTFail("\(tag): no gauge disc")
                    continue
                }
                var own = true
                for cmd in list.commands[start...] {
                    guard let p = Self.painted(cmd) else { continue }
                    if own, Self.within(p, chip) { continue }
                    own = false
                    XCTAssertFalse(p.intersects(chip.insetBy(dx: 0.01, dy: 0.01)), "\(tag): \(cmd) over the gauge \(chip)")
                    XCTAssertTrue(Self.isOverlay(cmd), "\(tag): \(cmd) drawn after the gauge")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 800)
    }

    func testTheLimitSignsRoomIsAlwaysReserved() {
        for (canvas, size, margins) in Self.canvases {
            for navigating in [false, true] {
                var with = navigating ? DashFixtures.navigating(size) : DashFixtures.freeRide(size)
                with.margins = margins
                var without = with
                without.nav.speedLimit = nil
                func chip(_ m: DashModel) -> DashRect? {
                    let ui = DashUIController()
                    ui.update(m)
                    return ui.displayList(now: Self.t0).hitRegions.last { $0.id == "speed.chip" }?.rect
                }
                XCTAssertEqual(chip(without), chip(with), "\(canvas) \(navigating ? "navigating" : "free ride")")
                XCTAssertNotNil(chip(with))
            }
        }
    }

    private static func within(_ r: DashRect, _ outer: DashRect, _ eps: Double = 1e-6) -> Bool {
        r.minX >= outer.minX - eps && r.maxX <= outer.maxX + eps && r.minY >= outer.minY - eps && r.maxY <= outer.maxY + eps
    }

    /// What a screen-space command paints (nil: no geometry of its own).
    private static func painted(_ c: DashDrawCommand) -> DashRect? {
        switch c {
        case let .fill(p, _, _): return p.controlPointBounds
        case let .stroke(p, s): return p.controlPointBounds?.insetBy(dx: -s.width / 2, dy: -s.width / 2)
        case let .text(_, r, _): return r
        case let .image(_, r, _): return r
        default: return nil
        }
    }

    /// The overlays the controller draws over the scene: the focus ring, the link banner, a toast.
    private static func isOverlay(_ c: DashDrawCommand) -> Bool {
        switch c {
        case let .stroke(_, s): return s.color == DashPalette.focusEdge || s.color == DashPalette.focusStroke
        case let .fill(_, color, _): return color == DashPalette.bannerFill || color == DashPalette.toastFill
        case let .text(_, _, style): return style.color == DashPalette.bannerText || style.color == DashPalette.toastText
        default: return true // save / clip / restore
        }
    }

    // MARK: 4. End and a route change ask first

    func testEndTakesTheMenuItsConfirmationRightAndStar() {
        for (canvas, size, margins) in Self.canvases {
            var m = DashFixtures.navigating(size)
            m.margins = margins
            let ui = DashUIController()
            ui.update(m)
            XCTAssertFalse(ui.state.focusOrder.contains { $0.hasPrefix("metrics.") }, "\(canvas): no End on the map")
            XCTAssertFalse(ui.displayList(now: Self.t0).hitRegions.contains { $0.id == "metrics.end" }, canvas)
            Self.openEndConfirmation(ui)
            XCTAssertEqual(ui.state.focusOrder, [DashFocusEngine.confirmKeepId, DashFocusEngine.confirmActId], canvas)
            XCTAssertEqual(ui.state.focusedId, DashFocusEngine.confirmKeepId, canvas)
            let list = ui.displayList(now: Self.t0 + 0.3)
            let texts = list.commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
            XCTAssertTrue(texts.contains("End the route?"), canvas)
            XCTAssertTrue(texts.contains("Guidance to Câmpina stops. You keep riding in free ride."), "\(canvas): \(texts)")
            XCTAssertTrue(texts.contains("Keep going") && texts.contains("End route"), canvas)
            // ★ again (a mistimed double's second press is swallowed by the engine; a slow one lands here)
            let keep = DashUIController()
            keep.update(m)
            Self.openEndConfirmation(keep)
            XCTAssertEqual(keep.handle(.key(.enter), now: Self.t0 + 0.5), [.closeSheets], canvas)
            XCTAssertEqual(keep.state.sheet, .none, canvas)
            XCTAssertEqual(keep.state.focusedId, DashFocusEngine.recenterId, canvas)
            // BACK keeps the route too
            let back = DashUIController()
            back.update(m)
            Self.openEndConfirmation(back)
            XCTAssertEqual(back.handle(.key(.back), now: Self.t0 + 0.5), [.closeSheets], canvas)
            // ▶ ★: the rider's explicit choice
            XCTAssertEqual(ui.handle(.knob(1), now: Self.t0 + 0.5), [])
            XCTAssertEqual(ui.state.focusedId, DashFocusEngine.confirmActId)
            XCTAssertEqual(ui.handle(.key(.enter), now: Self.t0 + 0.7), [.endNavigation], canvas)
            XCTAssertEqual(ui.state.sheet, .none, canvas)
        }
        // touch: the same two steps. «End route…» is the Ride section's last item: the rider drags the menu up
        // until it shows clear of the speed chip drawn over the panel's bottom, then taps it.
        let touchUI = DashUIController()
        touchUI.update(DashFixtures.navigating())
        _ = touchUI.perform(.openMenu, now: Self.t0)
        func touch(_ a: DashTouch.Action, _ p: DashPoint, _ t: TimeInterval) -> [DashIntent] {
            touchUI.handle(.touch(DashTouch(action: a, pointerId: 0, x: Int(p.x), y: Int(p.y), time: t)), now: t)
        }
        /// A point where a tap reaches `id` (nothing drawn over it there), or nil.
        func tappable(_ id: String, _ t: TimeInterval) -> DashPoint? {
            let list = touchUI.displayList(now: t)
            guard let r = list.hitRegions.last(where: { $0.id == id })?.rect else { return nil }
            for fy in stride(from: 0.2, through: 0.8, by: 0.3) {
                for fx in stride(from: 0.1, through: 0.9, by: 0.2) {
                    let p = DashPoint(r.minX + r.width * fx, r.minY + r.height * fy)
                    if list.hitTest(p)?.id == id { return p }
                }
            }
            return nil
        }
        var t = Self.t0 + 1
        for _ in 0 ..< 8 where tappable(DashFocusEngine.menuEndId, t) == nil {
            let panel = try! XCTUnwrap(touchUI.displayList(now: t).hitRegions.last { $0.id == "menu.panel" }).rect
            let from = DashPoint(panel.midX, panel.minY + panel.height * 0.6)
            _ = touch(.down, from, t)
            for k in 1 ... 6 { _ = touch(.move, DashPoint(from.x, from.y - Double(k) * 15), t + Double(k) * 0.02) }
            _ = touch(.up, DashPoint(from.x, from.y - 90), t + 0.14)
            t += 1
        }
        let endPoint = try! XCTUnwrap(tappable(DashFocusEngine.menuEndId, t), "«End route…» never shows clear of the gauge")
        XCTAssertEqual(touch(.down, endPoint, t) + touch(.up, endPoint, t + 0.05), [])
        XCTAssertEqual(touchUI.state.sheet, .confirm)
        let actPoint = try! XCTUnwrap(tappable(DashFocusEngine.confirmActId, t + 1))
        XCTAssertEqual(touch(.down, actPoint, t + 1) + touch(.up, actPoint, t + 1.05), [.endNavigation])
        // free ride: no End in the menu at all
        let free = DashUIController()
        free.update(DashFixtures.freeRide())
        _ = free.handle(.key(.home), now: Self.t0)
        XCTAssertFalse(free.state.focusOrder.contains(DashFocusEngine.menuEndId))
        // the dash's End intent asks however it arrives (the phone's own End button calls the navigation
        // directly: the rider is looking at the phone there)
        let viaPerform = DashUIController()
        viaPerform.update(DashFixtures.navigating())
        XCTAssertEqual(viaPerform.perform(.endNavigation, now: Self.t0), [])
        XCTAssertEqual(viaPerform.state.sheet, .confirm, "the dash's End intent always asks")
    }

    func testAGoThatReplacesARunningRouteAsksFirst() {
        var navPreview = DashFixtures.navigating()
        navPreview.nav.preview = DashFixtures.preview().nav.preview
        let ui = DashUIController()
        ui.update(navPreview)
        XCTAssertEqual(ui.state.focusedId, "preview.go")
        XCTAssertEqual(ui.handle(.key(.enter), now: Self.t0), [])
        XCTAssertEqual(ui.state.sheet, .confirm)
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.confirmKeepId)
        let texts = ui.displayList(now: Self.t0 + 0.1).commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
        XCTAssertTrue(texts.contains("Change route?"), "\(texts)")
        XCTAssertTrue(texts.contains("The route to Câmpina stops; guidance goes to Câmpina."), "\(texts)")
        // the card stands in for the preview card it asks about: no Go (nor any preview control) behind it
        XCTAssertFalse(ui.displayList(now: Self.t0 + 0.1).hitRegions.contains { $0.id.hasPrefix("preview.") })
        XCTAssertEqual(ui.handle(.key(.enter), now: Self.t0 + 0.5), [.closeSheets], "Keep: the running route stays")
        XCTAssertTrue(ui.state.focusOrder.contains("preview.go"), "back on the preview")
        _ = ui.handle(.key(.enter), now: Self.t0 + 1)
        _ = ui.handle(.knob(1), now: Self.t0 + 1.2)
        XCTAssertEqual(ui.handle(.key(.enter), now: Self.t0 + 1.4), [.go], "▶ ★: change")
        // a free-ride preview starts at once (nothing running to replace)
        let free = DashUIController()
        free.update(DashFixtures.preview())
        XCTAssertEqual(free.handle(.key(.enter), now: Self.t0), [.go])
    }

    func testTheCardClosesByItselfWithoutCommittingAndWhenItsQuestionGoes() {
        let ui = DashUIController()
        ui.update(DashFixtures.navigating())
        Self.openEndConfirmation(ui)
        XCTAssertEqual(ui.tick(now: Self.t0 + 8.1), [], "8 s since the last input")
        XCTAssertEqual(ui.state.sheet, .confirm)
        _ = ui.handle(.knob(1), now: Self.t0 + 8.1) // input restarts the 8 s
        XCTAssertEqual(ui.tick(now: Self.t0 + 16), [])
        XCTAssertEqual(ui.tick(now: Self.t0 + 16.2), [.closeSheets])
        XCTAssertEqual(ui.state.sheet, .none)
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.recenterId)
        // the route ends or arrives by itself: the question no longer applies, the card goes
        let gone = DashUIController()
        gone.update(DashFixtures.navigating())
        Self.openEndConfirmation(gone)
        gone.update(DashFixtures.arrival())
        XCTAssertEqual(gone.state.sheet, .none)
        XCTAssertEqual(gone.state.focusedId, "arrive.done")
        // «Change route?» asks about one place: another place previewed under it (the phone, a saved place)
        // is another question — the card closes, committing nothing, and the new preview's Go asks again
        var navPreview = DashFixtures.navigating()
        navPreview.nav.preview = DashFixtures.preview().nav.preview
        let change = DashUIController()
        change.update(navPreview)
        XCTAssertEqual(change.handle(.key(.enter), now: Self.t0), [])
        XCTAssertEqual(change.state.sheet, .confirm)
        var other = navPreview
        other.nav.preview?.place = Place(name: "Sinaia", lat: 45.35, lon: 25.55)
        change.update(other)
        XCTAssertEqual(change.state.sheet, .none, "a different place: the question went")
        XCTAssertEqual(change.state.focusedId, "preview.go")
        XCTAssertEqual(change.handle(.key(.enter), now: Self.t0 + 1), [], "its Go asks again")
        XCTAssertEqual(change.state.sheet, .confirm)
    }

    /// A handlebar saved place (nav1–3) never replaces a running route by itself: the controller passes it on,
    /// and the session opens the place as a preview while a route runs (NavSessionActionTests
    /// .testSavedPlaceSlots), whose Go asks like any other (review DASH-SAFE-5).
    func testASavedPlaceOverARunningRouteGoesThroughTheChangeCard() {
        let ui = DashUIController()
        ui.update(DashFixtures.navigating())
        XCTAssertEqual(ui.handle(.savedPlace(1), now: Self.t0), [.navigateSavedPlace(1)])
        var previewed = DashFixtures.navigating() // what the session publishes next: the place as a preview
        previewed.nav.preview = DashFixtures.preview().nav.preview
        ui.update(previewed)
        XCTAssertEqual(ui.state.focusedId, "preview.go")
        XCTAssertEqual(ui.handle(.key(.enter), now: Self.t0 + 1), [])
        XCTAssertEqual(ui.state.sheet, .confirm)
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.confirmKeepId)
    }

    // MARK: 5. Doubles never change meaning

    func testOnTheIOSDefaultMapAQuickStarIsOneStarAndKnobPressesAllCount() {
        let map = HandlebarPresets.iosDefaultMapping
        for g in [ButtonGesture.selectDouble, .selectLong] { XCTAssertEqual(map[g], ButtonAction.none, "\(g)") }
        XCTAssertEqual(map[.navFwdDouble], map[.navFwd])
        XCTAssertEqual(map[.navBackDouble], map[.navBack])
        // ★★ quick: one ★ (a stutter). ◀◀ / ▶▶ quick: two steps, like two slow presses (review DASH-REG-3: a
        // rider who counts presses lands where they counted, at any tempo)
        let channels: [(HandlebarGestureEngine.Channel, DashInput, Int)] = [(.select, .key(.enter), 1), (.forward, .knob(1), 2),
                                                                            (.backward, .knob(-1), 2)]
        for (channel, single, quickCount) in channels {
            for gap in [1, 50, 150, 299] as [Int64] {
                let e = HandlebarGestureEngine(configuration: .init(buttonMap: map))
                let inputs = e.tap(channel, atMs: 10_000).compactMap(\.input) + e.tap(channel, atMs: 10_000 + gap).compactMap(\.input)
                XCTAssertEqual(inputs, Array(repeating: single, count: quickCount), "\(channel) ×2, \(gap) ms apart")
            }
            for gap in [150, 350] as [Int64] { // six presses: six steps at any tempo (★: every other one at 150 ms)
                let e = HandlebarGestureEngine(configuration: .init(buttonMap: map))
                let inputs = (0 ..< 6).flatMap { e.tap(channel, atMs: 10_000 + Int64($0) * gap).compactMap(\.input) }
                XCTAssertEqual(inputs.count, channel == .select && gap < 300 ? 3 : 6, "\(channel) ×6, \(gap) ms apart")
            }
            let slow = HandlebarGestureEngine(configuration: .init(buttonMap: map))
            let two = slow.tap(channel, atMs: 10_000).compactMap(\.input) + slow.tap(channel, atMs: 10_300).compactMap(\.input)
            XCTAssertEqual(two, [single, single], "\(channel): slower, two singles")
        }
        // ★★ on the menu's End: the card opens once, on «Keep going» — the second ★ never confirms
        let ui = DashUIController()
        ui.update(DashFixtures.navigating())
        _ = ui.handle(.key(.home), now: Self.t0)
        let order = ui.state.focusOrder
        _ = ui.handle(.knob(order.firstIndex(of: DashFocusEngine.menuEndId)!), now: Self.t0 + 0.1)
        let e = HandlebarGestureEngine(configuration: .init(buttonMap: map))
        var out: [DashIntent] = []
        for t in [11_000, 11_150] as [Int64] {
            for c in e.tap(.select, atMs: t) { if let i = c.input { out += ui.handle(i, now: Double(t) / 1000) } }
        }
        XCTAssertEqual(out, [])
        XCTAssertEqual(ui.state.sheet, .confirm)
        XCTAssertEqual(ui.state.focusedId, DashFocusEngine.confirmKeepId)
    }

    // MARK: 6. Spanish copy

    func testSpanishCopyIsNeutralLatinAmerican() {
        // Spain-only words where a neutral one exists (owner decision): «aparcar» → estacionar, «autovía» →
        // autopista, «conducir» → manejar / viajar, «cajero» alone → cajero automático, «móvil» → teléfono.
        let banned = ["aparca", "autovía", "conduc", "móvil", "ordenador", "vale,", "coche", "cambio de sentido"]
        var es: [String] = DashText.allCases.map { $0.localized(.es) }
        es += [DashStrings.endConsequence("Câmpina", .es), DashStrings.endConsequence("", .es),
               DashStrings.changeConsequence(from: "A", to: "B", .es)]
        let nav = NavStrings(language: .es)
        es += ["Fuel", "Parking", "ATM", "Cafe", "Food", "Hotel"].map { nav.poiChipLabel($0) }
        es += [nav.phrase(.parkingMarked), nav.phrase(.parkingUpdated), nav.phrase(.destinationReached), nav.phrase(.noHomeSet),
               nav.phrase(.homeSetHere), nav.phrase(.noGpsForParking), nav.phrase(.arrived), nav.arrivalMeta]
        // the HUD's fallback words when a cue has no road name (review DASH-COPY-7)
        es += TurnDir.allCases.flatMap { [nav.maneuverWord($0), nav.joinRouteWord($0), DashStrings.maneuverWord($0, .es)] }
        XCTAssertEqual(nav.maneuverWord(.uturn), DashStrings.maneuverWord(.uturn, .es))
        for s in es {
            let low = s.lowercased()
            for w in banned { XCTAssertFalse(low.contains(w), "«\(s)» contains «\(w)»") }
            if low.contains("cajero") { XCTAssertTrue(low.contains("cajero automático"), "«\(s)»") }
        }
        XCTAssertEqual(DashText.parkHere.localized(.es), "Estacionar aquí")
        XCTAssertEqual(DashText.endNavigation.localized(.es), "Terminar la ruta…")
        XCTAssertEqual(DashText.confirmKeep.localized(.es), "Seguir")
        XCTAssertEqual(DashText.confirmEndQuestion.localized(.es), "¿Terminar la ruta?")
        XCTAssertEqual(DashText.confirmEndAction.localized(.es), "Terminar")
        XCTAssertEqual(nav.poiChipLabel("ATM"), "Cajero automático")
    }

    // MARK: 5b. The single-button option: ★★ chooses what the rider sees focused

    /// ★ = next, ★★ = choose (input-controls §9.3 A1): through the real engine, ★★ on every state's default does
    /// what ★ on it does on the iOS default map — never the item after it — and never commits a destructive
    /// intent; on «End the route?» it keeps the route (review DASH-SAFE-1: the snappy ★ moved the focus to
    /// «End route» first and the second ★ ended it). A lone ★ moves the focus once the double window ends.
    func testOnTheSingleButtonMapAStarStarChoosesTheFocusedControl() {
        let map = HandlebarPresets.iosSingleButtonMapping
        var checked = 0
        for (canvas, size, margins) in Self.canvases where canvas == "800×384" || canvas == "800×944" || canvas == "544×512" {
            for s in Self.states(size, margins) {
                let tag = "\(canvas) \(s)"
                let expected = s.make().handle(.key(.enter), now: Self.t0 + 1)
                let ui = s.make()
                let def = ui.state.focusedId
                let e = HandlebarGestureEngine(configuration: .init(buttonMap: map))
                var out: [DashIntent] = []
                func feed(_ cmds: [HandlebarCommand], _ ms: Int64) {
                    for c in cmds { if let i = c.input { out += ui.handle(i, now: Self.t0 + 1 + Double(ms - 10_000) / 1000) } }
                }
                feed(e.tap(.select, atMs: 10_000), 10_000)
                XCTAssertEqual(ui.state.focusedId, def, "\(tag): the first ★ waits for a possible ★★")
                feed(e.tap(.select, atMs: 10_150), 10_150)
                feed(e.tick(atMs: 11_000), 11_000)
                XCTAssertEqual(out, expected, "\(tag): ★★ on \(def ?? "-")")
                XCTAssertEqual(Self.destructive(out, s.model), [], tag)
                if s.model.navigating, s.name.hasSuffix("confirm End") { XCTAssertEqual(out, [.closeSheets], tag) }
                // a lone ★: the next item, once the window is over
                let lone = s.make()
                let order = lone.state.focusOrder
                let e1 = HandlebarGestureEngine(configuration: .init(buttonMap: map))
                XCTAssertEqual(e1.tap(.select, atMs: 10_000).compactMap(\.input), [], tag)
                let later = e1.tick(atMs: 10_400).compactMap(\.input)
                XCTAssertEqual(later, [.knob(1)], tag)
                if order.count > 1, let at = def.flatMap({ order.firstIndex(of: $0) }) {
                    _ = lone.handle(.knob(1), now: Self.t0 + 1.4)
                    XCTAssertEqual(lone.state.focusedId, order[(at + 1) % order.count], tag)
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    // MARK: 7. Scrolled sheets, opaque cards, the confirm card's text

    /// D03: every item the knob reaches in the menu (navigating and free ride), the search list and the Music
    /// sheet is scrolled clear of the speed gauge drawn over them, and its ring is drawn — the rider never
    /// presses ★ on something hidden under the gauge (review DASH-TEST-4). The one exception is by geometry: the
    /// full-width search rows at the top of the portrait list pass under the corner of the gauge drawn below the
    /// banner (at most a fifth of the row, its right end; the name and the ring's left part stay in view).
    func testTheKnobNeverFocusesAnItemUnderTheGauge() {
        var checked = 0
        for (canvas, size, margins) in Self.canvases {
            let sheets = Self.states(size, margins).filter {
                $0.name.hasSuffix("· menu") || $0.name.hasSuffix("· search results") || $0.name.hasSuffix("· Music sheet")
            }
            for s in sheets {
                let ui = s.make()
                let order = ui.state.focusOrder
                var t = Self.t0 + 1
                for step in 0 ..< order.count {
                    if step > 0 { _ = ui.handle(.knob(1), now: t) }
                    t += 0.05
                    let list = ui.displayList(now: t)
                    let tag = "\(canvas) \(s) step \(step)"
                    guard let id = ui.state.focusedId, let r = list.hitRegions.last(where: { $0.id == id })?.rect,
                          let chip = list.hitRegions.last(where: { $0.id == "speed.chip" })?.rect else {
                        XCTFail("\(tag): no focus or no gauge")
                        continue
                    }
                    let ow = max(0, min(r.maxX, chip.maxX) - max(r.minX, chip.minX))
                    let oh = max(0, min(r.maxY, chip.maxY) - max(r.minY, chip.minY))
                    let covered = ow * oh / (r.width * r.height)
                    let fullWidthRow = r.width >= size.width - 1 && !(size.width > size.height)
                    if fullWidthRow {
                        XCTAssertLessThanOrEqual(covered, 0.25, "\(tag): \(id) \(r) under the gauge \(chip)")
                        XCTAssertFalse(chip.contains(r.center), tag)
                    } else {
                        XCTAssertFalse(r.intersects(chip.insetBy(dx: 0.5, dy: 0.5)), "\(tag): \(id) \(r) under the gauge \(chip)")
                    }
                    let ring = list.commands.contains {
                        if case let .stroke(p, st) = $0, st.color == DashPalette.focusStroke, let b = p.controlPointBounds {
                            return b.intersects(r.insetBy(dx: -12, dy: -12))
                        }
                        return false
                    }
                    XCTAssertTrue(ring, "\(tag): no ring on \(id)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 400)
    }

    /// D12: the cards behind numbers and labels are opaque, so no map feature ghosts through them (review
    /// DASH-TEST-8).
    func testCardsBehindNumbersAreOpaque() {
        for (name, color) in [("cardFill", DashPalette.cardFill), ("fabFill", DashPalette.fabFill), ("gaugeFill", DashPalette.gaugeFill),
                              ("topBannerFill", DashPalette.topBannerFill), ("bottomBarFill", DashPalette.bottomBarFill)] {
            XCTAssertEqual(color.argb >> 24, 0xFF, name)
        }
    }

    /// The consequence line always shows its fixed part, however long the destination's name: the name is
    /// shortened, by whole words, never the «You keep riding in free ride» the rider decides on (review
    /// DASH-COPY-9). And in landscape nothing of the metrics card shows cut beside the card (DASH-LOOK-6).
    func testTheConfirmCardShowsItsWholeConsequenceAndNoCutNumbers() {
        let long = "Estación de servicio Autopista del Sol km 23 sentido norte"
        for (canvas, size, margins) in Self.canvases {
            for lang in [DashLanguage.en, .es] {
                var m = DashFixtures.navigating(size)
                m.margins = margins
                m.language = lang
                m.nav.destination?.name = long
                if case let .navTo(p) = m.nav.mode { var q = p; q.name = long; m.nav.mode = .navTo(q) }
                let ui = DashUIController()
                ui.update(m)
                let labels = [DashText.time, .arrive, .left].map { $0.localized(lang) }
                let before = ui.displayList(now: Self.t0).commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
                XCTAssertTrue(labels.allSatisfy(before.contains), "\(canvas): the metrics card on the map")
                Self.openEndConfirmation(ui)
                let list = ui.displayList(now: Self.t0 + 0.5)
                let fixed = lang == .es ? "Sigues en ruta libre." : "You keep riding in free ride."
                let tag = "\(canvas) \(lang)"
                guard case let .text(text, rect, style)? = list.commands.first(where: {
                    if case let .text(s, _, _) = $0 { return s.hasSuffix(fixed) }
                    return false
                }) else {
                    XCTFail("\(tag): no consequence ending «\(fixed)»")
                    continue
                }
                let lines = DashTextLayout.wrap(text, maxWidth: rect.width, font: style.font, maxLines: 3,
                                                measurer: ApproximateTextMeasurer())
                XCTAssertLessThanOrEqual(lines.count, 2, "\(tag): «\(text)» is cut")
                let full = DashStrings.endConsequence(long, lang)
                let fullLines = DashTextLayout.wrap(full, maxWidth: rect.width, font: style.font, maxLines: 3,
                                                    measurer: ApproximateTextMeasurer()).count
                XCTAssertEqual(text == full, fullLines <= 2, "\(tag): shortened only when it would be cut")
                if size.width == 544 { XCTAssertTrue(text.contains("\u{2026}"), "\(tag): the long name is shortened") }
                XCTAssertFalse(text.contains("\u{2026}."), tag)
                let texts = list.commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
                let shown = labels.filter(texts.contains)
                if size.width > size.height { XCTAssertEqual(shown, [], "\(tag): metrics labels beside the card") }
                else { XCTAssertEqual(shown, labels, "\(tag): portrait keeps the bar under the card") }
            }
        }
    }
}
