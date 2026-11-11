// SPDX-License-Identifier: AGPL-3.0-or-later
// Behaviour of the dash UI controller: §11.6 visibility, §11.8 tap targets, §11.9 handlebar focus,
// §4.9 camera policy, input-controls.md §6 gestures.
import Foundation
import XCTest
@testable import OpenCfMotoCore

final class DashUIControllerTests: XCTestCase {
    // MARK: Helpers

    private func region(_ list: DashDisplayList, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> DashHitRegion? {
        let r = list.hitRegions.last(where: { $0.id == id })
        if r == nil { XCTFail("no region \(id)", file: file, line: line) }
        return r
    }

    private func touch(_ ui: DashUIController, _ a: DashTouch.Action, _ p: DashPoint, _ t: TimeInterval, id: Int = 0) -> [DashIntent] {
        ui.handle(.touch(DashTouch(action: a, pointerId: id, x: Int(p.x), y: Int(p.y), time: t)), now: t)
    }

    private func tap(_ ui: DashUIController, _ p: DashPoint, at t: TimeInterval) -> [DashIntent] {
        touch(ui, .down, p, t) + touch(ui, .up, p, t + 0.05)
    }

    private func tapRegion(_ ui: DashUIController, _ id: String, at t: TimeInterval, file: StaticString = #filePath, line: UInt = #line) -> [DashIntent] {
        let list = ui.displayList(now: t)
        guard let r = region(list, id, file: file, line: line) else { return [] }
        return tap(ui, r.rect.center, at: t)
    }

    private func controller(_ model: DashModel, options: DashUIController.Options = .init()) -> DashUIController {
        let ui = DashUIController(options: options)
        ui.update(model)
        return ui
    }

    private func hasFocusRing(_ list: DashDisplayList) -> Bool {
        list.commands.contains { cmd in
            if case let .stroke(_, st) = cmd { return st.color == DashPalette.focusEdge && st.width == DashPalette.focusEdgeWidth }
            return false
        }
    }

    private func texts(_ list: DashDisplayList) -> [String] {
        list.commands.compactMap { if case let .text(s, _, _) = $0 { return s }; return nil }
    }

    // MARK: Free ride, focus order, FABs

    func testFreeRideFocusOrderAndRegions() {
        let ui = controller(DashFixtures.freeRide())
        let st = ui.state
        XCTAssertEqual(st.focusOrder, ["pill", "pill.circuit", "pill.lap", "fab.recenter", "fab.zoomIn", "fab.zoomOut", "fab.compass", "fab.menu"])
        XCTAssertEqual(st.focusedId, "pill") // default → first
        XCTAssertEqual(st.sheet, .none)
        let list = ui.displayList(now: 0)
        XCTAssertEqual(list.size, DashSize(width: 800, height: 384))
        XCTAssertEqual(list.background, DashPalette.chrome(.dark))
        XCTAssertTrue(region(list, "fab.menu")!.focusable)
        XCTAssertFalse(region(list, "speed.chip")!.focusable)
        // Parity: the Lap label is not reachable by the handlebar on Android
        var parity = DashUIController.Options()
        parity.lapReachableByHandlebar = false
        XCTAssertFalse(controller(DashFixtures.freeRide(), options: parity).state.focusOrder.contains("pill.lap"))
    }

    func testPillTargets() {
        let ui = controller(DashFixtures.freeRide())
        XCTAssertEqual(tapRegion(ui, "pill.circuit", at: 1), [.startCircuit])
        XCTAssertEqual(tapRegion(ui, "pill.lap", at: 2), [.toggleLapTimer])
        XCTAssertEqual(tapRegion(ui, "pill", at: 3), [.openSearch])
        XCTAssertEqual(ui.state.sheet, .search)
    }

    func testZoomFabFreePanAndAutoRecenterToFixedZoom() {
        let ui = controller(DashFixtures.freeRide()) // 42 km/h → follow zoom min(15.4 + 1.1, 18.6) = 16.5
        XCTAssertEqual(ui.state.camera.zoom, 16.5, accuracy: 1e-9)
        XCTAssertEqual(tapRegion(ui, "fab.zoomIn", at: 10), [.zoomIn])
        XCTAssertEqual(tapRegion(ui, "fab.zoomIn", at: 10.5), [.zoomIn])
        var cam = ui.state.camera
        XCTAssertFalse(cam.follow)
        XCTAssertFalse(cam.speedZoom)
        XCTAssertEqual(cam.zoom, 18.5, accuracy: 1e-9)
        ui.update(DashFixtures.freeRide()) // a fix while panning does not move the camera
        XCTAssertEqual(ui.state.camera.zoom, 18.5, accuracy: 1e-9)
        _ = ui.tick(now: 10.55 + 11.9)
        XCTAssertFalse(ui.state.camera.follow)
        _ = ui.tick(now: 10.55 + 12.01)
        cam = ui.state.camera
        XCTAssertTrue(cam.follow)
        // after the auto-recenter the bike follows at the fixed 17.2 (speed zoom stays off)
        XCTAssertEqual(cam.zoom, 17.2, accuracy: 1e-9)
        XCTAssertEqual(tapRegion(ui, "fab.zoomOut", at: 30), [.zoomOut])
        XCTAssertEqual(ui.state.camera.zoom, 16.2, accuracy: 1e-9)
    }

    func testZoomClampsToBikeRange() {
        let ui = controller(DashFixtures.freeRide())
        for i in 0 ..< 10 { _ = ui.perform(.zoomIn, now: Double(i)) }
        XCTAssertEqual(ui.state.camera.zoom, 20)
        for i in 0 ..< 30 { _ = ui.perform(.zoomOut, now: Double(i)) }
        XCTAssertEqual(ui.state.camera.zoom, 5)
    }

    func testRecenterToastsAndRestoresFollow() {
        let ui = controller(DashFixtures.freeRide())
        _ = ui.perform(.zoomIn, now: 1)
        XCTAssertFalse(ui.state.camera.follow)
        XCTAssertEqual(tapRegion(ui, "fab.recenter", at: 2), [.recenter])
        XCTAssertTrue(ui.state.camera.follow)
        XCTAssertNil(ui.state.camera.autoRecenterAt)
        XCTAssertEqual(ui.state.toast, "Centered on GPS")
        XCTAssertTrue(texts(ui.displayList(now: 3)).contains("Centered on GPS"))
        XCTAssertNil(ui.displayList(now: 5).commands.first { if case let .text(s, _, _) = $0 { return s == "Centered on GPS" }; return false })
        var noFix = DashFixtures.freeRide()
        noFix.fix = nil
        noFix.nav.puck = nil
        let ui2 = controller(noFix)
        _ = ui2.perform(.recenter, now: 0)
        XCTAssertEqual(ui2.state.toast, "No GPS yet — wait for a fix")
    }

    func testCompassToggle() {
        let ui = controller(DashFixtures.freeRide())
        XCTAssertEqual(ui.state.camera.bearingDeg, 20, accuracy: 1e-9) // GPS course while moving
        XCTAssertEqual(tapRegion(ui, "fab.compass", at: 1), [.toggleCompass])
        var cam = ui.state.camera
        XCTAssertFalse(cam.headingUp)
        XCTAssertEqual(cam.bearingDeg, 0)
        XCTAssertEqual(ui.state.toast, "North up")
        ui.update(DashFixtures.freeRide())
        XCTAssertEqual(ui.state.camera.bearingDeg, 0) // north-up follow
        XCTAssertEqual(ui.state.puckBearingDeg, 20) // puck still shows travel
        _ = ui.perform(.toggleCompass, now: 2)
        cam = ui.state.camera
        XCTAssertTrue(cam.headingUp)
        XCTAssertEqual(cam.bearingDeg, 20, accuracy: 1e-9)
        XCTAssertEqual(ui.state.toast, "Heading up")
        // the menu toggle does not toast
        _ = ui.perform(.toggleHeadingUp, now: 10)
        XCTAssertNil(ui.state.toast)
        XCTAssertFalse(ui.state.camera.headingUp)
    }

    func testBearingSourcesWhenStopped() {
        var m = DashFixtures.freeRide()
        m.fix = DashFixtures.fix(kmh: 0, course: 200) // stopped: course ignored
        let ui = controller(m)
        XCTAssertEqual(ui.state.camera.bearingDeg, 18, accuracy: 1e-9) // compass in heading-up
        m.compassHeadingDeg = nil
        m.nav.puckBearingDeg = 33
        ui.update(m)
        XCTAssertEqual(ui.state.camera.bearingDeg, 33, accuracy: 1e-9) // nav engine fallback
        var nav = DashFixtures.navigating()
        nav.fix = DashFixtures.fix(nav.nav.puck!, kmh: 0, course: nil)
        nav.compassHeadingDeg = nil
        XCTAssertEqual(controller(nav).state.camera.bearingDeg, 15, accuracy: 1e-9) // progress.trackBearingDeg
    }

    func testFollowLookAheadPutsPuckBelowAnchorAndAboveMetrics() throws {
        let ui = controller(DashFixtures.freeRide())
        let proj = try XCTUnwrap(ui.mapProjection())
        let puck = proj.screenPoint(DashFixtures.rider)
        XCTAssertEqual(puck.x, 400, accuracy: 0.5)
        XCTAssertGreaterThan(puck.y, 192 + 30) // 70 m ahead at zoom 16.5
        // navigating slowly (zoom 18.1, 40 m ≈ 102 px): the look-ahead is capped so the puck
        // stays above the metrics card (§4.9 worked example / R9)
        var slow = DashFixtures.navigating()
        slow.fix = DashFixtures.fix(slow.nav.puck!, kmh: 15, course: 15)
        let nav = controller(slow)
        XCTAssertEqual(nav.state.camera.zoom, 18.1, accuracy: 1e-9)
        let list = nav.displayList(now: 0)
        let card = try XCTUnwrap(region(list, "metrics.card"))
        let p = try XCTUnwrap(nav.mapProjection()).screenPoint(slow.nav.puck!)
        XCTAssertEqual(p.y, card.rect.minY - 32, accuracy: 0.5)
        // parity: no cap → the puck lands ≈ 102 px below the anchor, on the card's top edge
        var parity = DashUIController.Options()
        parity.clampLookAheadToVisibleMap = false
        let raw = controller(slow, options: parity)
        let p2 = try XCTUnwrap(raw.mapProjection()).screenPoint(slow.nav.puck!)
        XCTAssertEqual(p2.y - 192, 101.5, accuracy: 1)
        XCTAssertGreaterThan(p2.y, p.y)
    }

    func testPuckDrawnUprightInHeadingUp() throws {
        let ui = controller(DashFixtures.freeRide())
        let list = ui.displayList(now: 0)
        // the puck's white chevron tip points straight up in heading-up
        let chevron = try XCTUnwrap(DashFixtures.drawnPuck(list)?.chevron)
        guard case let .move(tip)? = chevron.elements.first else { return XCTFail("no tip") }
        let b = try XCTUnwrap(chevron.controlPointBounds)
        XCTAssertEqual(tip.x, b.midX, accuracy: 0.01)
        XCTAssertEqual(tip.y, b.minY, accuracy: 0.01)
    }

    // MARK: Long-press, pan, pinch, double tap

    func testLongPressDropsPin() throws {
        let ui = controller(DashFixtures.freeRide())
        let p = DashPoint(300, 200)
        let expected = try XCTUnwrap(ui.mapProjection()).geoPoint(atScreen: p)
        XCTAssertEqual(touch(ui, .down, p, 1), [])
        XCTAssertEqual(ui.tick(now: 1.3), [])
        let out = ui.tick(now: 1.46)
        guard case let .dropPin(g)? = out.first, out.count == 1 else { return XCTFail("expected dropPin, got \(out)") }
        XCTAssertEqual(g.lat, expected.lat, accuracy: 1e-9)
        XCTAssertEqual(g.lon, expected.lon, accuracy: 1e-9)
        XCTAssertEqual(touch(ui, .up, p, 1.6), [])
    }

    func testLongPressOnCardDoesNothing() {
        let ui = controller(DashFixtures.navigating())
        let card = region(ui.displayList(now: 0), "nav.card")!
        _ = touch(ui, .down, card.rect.center, 1)
        XCTAssertEqual(ui.tick(now: 2), [])
        XCTAssertEqual(touch(ui, .up, card.rect.center, 2.1), [])
    }

    func testPanIsFreePan() throws {
        let ui = controller(DashFixtures.freeRide())
        let before = try XCTUnwrap(ui.mapProjection())
        let g = before.geoPoint(atScreen: DashPoint(300, 200))
        _ = touch(ui, .down, DashPoint(300, 200), 1)
        _ = touch(ui, .move, DashPoint(330, 220), 1.05)
        _ = touch(ui, .move, DashPoint(360, 230), 1.1)
        _ = touch(ui, .up, DashPoint(360, 230), 1.15)
        XCTAssertFalse(ui.state.camera.follow)
        XCTAssertTrue(ui.state.camera.speedZoom) // panning keeps the speed ladder
        let s = try XCTUnwrap(ui.mapProjection()).screenPoint(g)
        XCTAssertEqual(s.x, 360, accuracy: 1e-6)
        XCTAssertEqual(s.y, 230, accuracy: 1e-6)
        // parity: dragging never stops follow (next fix re-centres)
        var parity = DashUIController.Options()
        parity.panStopsFollow = false
        let ui2 = controller(DashFixtures.freeRide(), options: parity)
        _ = touch(ui2, .down, DashPoint(300, 200), 1)
        _ = touch(ui2, .move, DashPoint(360, 230), 1.1)
        _ = touch(ui2, .up, DashPoint(360, 230), 1.15)
        XCTAssertTrue(ui2.state.camera.follow)
    }

    func testPinchZoom() {
        let ui = controller(DashFixtures.freeRide())
        let z0 = ui.state.camera.zoom
        _ = touch(ui, .down, DashPoint(300, 200), 1, id: 0)
        _ = touch(ui, .down, DashPoint(400, 200), 1.02, id: 1)
        _ = touch(ui, .move, DashPoint(500, 200), 1.1, id: 1) // distance 100 → 200
        _ = touch(ui, .up, DashPoint(500, 200), 1.2, id: 1)
        _ = touch(ui, .up, DashPoint(300, 200), 1.25, id: 0)
        let cam = ui.state.camera
        XCTAssertEqual(cam.zoom, z0 + 1, accuracy: 1e-9)
        XCTAssertFalse(cam.follow)
        XCTAssertFalse(cam.speedZoom)
    }

    func testDoubleTapZoomsInAroundPoint() throws {
        let ui = controller(DashFixtures.freeRide())
        let z0 = ui.state.camera.zoom
        let p = DashPoint(250, 150)
        let g = try XCTUnwrap(ui.mapProjection()).geoPoint(atScreen: p)
        _ = tap(ui, p, at: 1)
        _ = touch(ui, .down, p, 1.2)
        _ = touch(ui, .up, p, 1.25)
        XCTAssertEqual(ui.state.camera.zoom, z0 + 1, accuracy: 1e-9)
        let s = try XCTUnwrap(ui.mapProjection()).screenPoint(g)
        XCTAssertEqual(s.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(s.y, p.y, accuracy: 1e-6)
    }

    func testTouchesInsideMarginsAreIgnored() {
        var m = DashFixtures.freeRide()
        m.margins = ScreenMargins(top: 22)
        let ui = controller(m)
        let list = ui.displayList(now: 0)
        XCTAssertEqual(region(list, "pill")?.rect.minY, 30)
        _ = touch(ui, .down, DashPoint(400, 10), 1)
        XCTAssertEqual(ui.tick(now: 2), []) // no long-press in the unsafe area
        XCTAssertEqual(touch(ui, .up, DashPoint(400, 10), 2.1), [])
    }

    // MARK: Menu & handlebar

    func testMenuViaHandlebar() {
        let ui = controller(DashFixtures.navigating())
        XCTAssertEqual(ui.state.focusedId, "fab.recenter") // navigating → Recenter first (P0, D01; Android: End)
        XCTAssertEqual(ui.handle(.key(.home), now: 1), [.openMenu])
        XCTAssertEqual(ui.state.sheet, .menu)
        XCTAssertEqual(ui.state.focusedId, "menu.recenter") // the menu opens on a harmless item (Android: End)
        XCTAssertEqual(ui.handle(.knob(1), now: 2), [])
        XCTAssertEqual(ui.state.focusedId, "menu.circuit")
        let park = try! XCTUnwrap(ui.state.focusOrder.firstIndex(of: "menu.park"))
        XCTAssertEqual(ui.handle(.knob(park - 1), now: 2.5), [])
        XCTAssertEqual(ui.state.focusedId, "menu.park")
        XCTAssertEqual(ui.handle(.key(.enter), now: 3), [.parkHere])
        XCTAssertEqual(ui.state.sheet, .none) // Park here closes the menu
        XCTAssertEqual(ui.state.focusedId, "fab.recenter")
    }

    func testMenuFocusWrapsAndScrollsIntoView() {
        let ui = controller(DashFixtures.navigating())
        _ = ui.handle(.key(.home), now: 1)
        _ = ui.handle(.knob(-1), now: 2) // wraps to the last item: Close
        XCTAssertEqual(ui.state.focusedId, "menu.close")
        XCTAssertGreaterThan(ui.state.menuScroll, 0)
        let list = ui.displayList(now: 3)
        let close = region(list, "menu.close")!
        XCTAssertGreaterThanOrEqual(close.rect.minY, 0)
        XCTAssertLessThanOrEqual(close.rect.maxY, 384)
        XCTAssertEqual(ui.handle(.key(.enter), now: 4), [.closeSheets])
        XCTAssertEqual(ui.state.sheet, .none)
    }

    func testMenuSettingsReachableByHandlebar() {
        let ui = controller(DashFixtures.freeRide())
        _ = ui.handle(.key(.home), now: 1)
        let order = ui.state.focusOrder
        // "menu.music" (Apple Music, iOS addition) is only listed while music shows on the dash, "menu.recalc" and
        // "menu.end" only while navigating (P0, D01)
        let base = DashSceneBuilder.menuFocusBase.filter { $0 != "menu.music" && $0 != "menu.end" && $0 != "menu.recalc" }
        XCTAssertEqual(Array(order.prefix(base.count)), base)
        XCTAssertTrue(order.contains("menu.units.imperial"))
        XCTAssertEqual(order.last, "menu.close")
        let steps = order.firstIndex(of: "menu.units.imperial")!
        _ = ui.handle(.knob(steps), now: 2)
        XCTAssertEqual(ui.state.focusedId, "menu.units.imperial")
        XCTAssertEqual(ui.handle(.key(.enter), now: 3), [.setUnits(.imperial)])
        XCTAssertEqual(ui.state.sheet, .menu) // settings keep the menu open
        var parity = DashUIController.Options()
        parity.handlebarReachesSettings = false
        let p = controller(DashFixtures.freeRide(), options: parity)
        _ = p.handle(.key(.home), now: 1)
        XCTAssertEqual(p.state.focusOrder, base + ["menu.close"])
    }

    func testMenuDragScrollsAndDimmerCloses() {
        let ui = controller(DashFixtures.navigating())
        _ = ui.perform(.openMenu, now: 1)
        // (above the speed chip, drawn over the menu from y 292: P0 D03 — a touch on the chip reaches no item)
        _ = touch(ui, .down, DashPoint(660, 260), 2)
        _ = touch(ui, .move, DashPoint(660, 210), 2.05)
        _ = touch(ui, .move, DashPoint(660, 160), 2.1)
        XCTAssertEqual(touch(ui, .up, DashPoint(660, 160), 2.15), []) // a drag is not a tap
        XCTAssertEqual(ui.state.menuScroll, 100, accuracy: 1e-9)
        XCTAssertEqual(ui.state.sheet, .menu)
        XCTAssertEqual(tap(ui, DashPoint(200, 200), at: 3), [.closeSheets]) // dimmer
        XCTAssertEqual(ui.state.sheet, .none)
    }

    func testMenuItemsEmitTheirIntents() {
        let expected: [(String, DashIntent)] = [
            ("menu.end", .endNavigation), ("menu.goHome", .goHome), ("menu.setHome", .setHomeHere), ("menu.recalc", .recalc),
            ("menu.recenter", .recenter),
            ("menu.record", .toggleRecording), ("menu.circuit", .startCircuit), ("menu.follow", .toggleFollow),
            ("menu.heading", .toggleHeadingUp), ("menu.voice", .toggleVoice), ("menu.zoomOut", .zoomOut), ("menu.zoomIn", .zoomIn),
            ("menu.theme.night", .setTheme(.night)), ("menu.voiceSeg.off", .setVoice(false)), ("menu.nextStop.off", .setNextStop(false)),
            ("menu.autoFinish.off", .setAutoFinish(false)), ("menu.chrome.slate", .setChrome(.slate)),
            ("menu.routeMode.fun", .setRouteMode(.fun)), ("menu.avoidTolls.on", .setAvoidTolls(true)),
            ("menu.avoidHighways.on", .setAvoidHighways(true)), ("menu.close", .closeSheets),
        ]
        for (id, intent) in expected {
            XCTAssertEqual(DashSceneBuilder.menuIntent(id), intent, id)
        }
        XCTAssertNil(DashSceneBuilder.menuIntent("menu.nope"))
    }

    func testFollowToggleFromMenu() {
        let ui = controller(DashFixtures.freeRide())
        _ = ui.perform(.zoomIn, now: 0)
        XCTAssertNotNil(ui.state.camera.autoRecenterAt)
        _ = ui.perform(.toggleFollow, now: 1)
        XCTAssertTrue(ui.state.camera.follow)
        XCTAssertNil(ui.state.camera.autoRecenterAt)
        _ = ui.perform(.toggleFollow, now: 2)
        XCTAssertFalse(ui.state.camera.follow)
        XCTAssertFalse(ui.tick(now: 100).contains(.recenter))
        XCTAssertFalse(ui.state.camera.follow) // manual free pan has no auto-recenter
    }

    // MARK: Search

    func testSearchViaAssistantChipsAndTypeOnPhone() {
        let ui = controller(DashFixtures.freeRide())
        XCTAssertEqual(ui.handle(.key(.assistant), now: 1), [.openSearch])
        XCTAssertEqual(ui.state.sheet, .search)
        XCTAssertEqual(ui.state.focusedId, "search.chip.0")
        XCTAssertEqual(ui.handle(.key(.enter), now: 2), [.searchChip("Fuel")])
        let order = ui.state.focusOrder
        XCTAssertEqual(Array(order.prefix(9)), (0 ..< 8).map { "search.chip.\($0)" } + ["search.typeOnPhone"])
        XCTAssertEqual(order.last, "search.back")
        _ = ui.handle(.knob(8), now: 3)
        XCTAssertEqual(ui.handle(.key(.enter), now: 4), [.typeOnPhone])
        XCTAssertEqual(tapRegion(ui, "search.input", at: 5), [.typeOnPhone])
        XCTAssertEqual(ui.handle(.key(.assistant), now: 6), [.closeSheets])
        XCTAssertEqual(ui.state.sheet, .none)
    }

    func testSearchRowsResultsAndIdle() {
        let m = DashFixtures.withSearchResults(DashFixtures.freeRide())
        let ui = controller(m)
        _ = ui.perform(.openSearch, now: 1)
        XCTAssertEqual(tapRegion(ui, "search.result.0.save", at: 2), [.savePlace(m.search.results![0])])
        XCTAssertEqual(ui.state.sheet, .search) // row actions keep the sheet
        XCTAssertEqual(tapRegion(ui, "search.result.1", at: 3), [.selectSearchResult(1)])
        XCTAssertEqual(ui.state.sheet, .none)
        let idle = controller(DashFixtures.freeRide())
        _ = idle.perform(.openSearch, now: 1)
        XCTAssertEqual(tapRegion(idle, "search.idle.0", at: 2), [.previewPlace(DashFixtures.base().places.home!)])
        XCTAssertEqual(idle.state.sheet, .none)
    }

    func testSearchListScrollsAndResetsOnNewResults() {
        var m = DashFixtures.freeRide()
        m.search = DashSearchState(results: (0 ..< 12).map { Place(name: "Place \($0)", lat: 45 + Double($0) / 100, lon: 25) })
        let ui = controller(m)
        _ = ui.perform(.openSearch, now: 1)
        let list = ui.displayList(now: 1)
        let row = region(list, "search.result.0")!
        _ = touch(ui, .down, row.rect.center, 2)
        _ = touch(ui, .move, DashPoint(row.rect.midX, row.rect.midY - 120), 2.1)
        _ = touch(ui, .up, DashPoint(row.rect.midX, row.rect.midY - 120), 2.2)
        XCTAssertEqual(ui.state.searchListScroll, 120, accuracy: 1e-9)
        m.search.results = [DashFixtures.campina]
        ui.update(m)
        XCTAssertEqual(ui.state.searchListScroll, 0)
    }

    // MARK: Preview & navigation transitions

    func testPreviewCameraAndFocus() {
        let ui = controller(DashFixtures.freeRide())
        ui.update(DashFixtures.preview())
        let st = ui.state
        XCTAssertFalse(st.camera.follow)
        XCTAssertFalse(st.camera.headingUp) // overview is always north-up
        XCTAssertFalse(st.camera.speedZoom)
        XCTAssertEqual(st.camera.bearingDeg, 0)
        XCTAssertEqual(st.focusedId, "preview.go")
        XCTAssertEqual(st.focusOrder, ["preview.go", "preview.circuit", "preview.cancel", "preview.save", "preview.chip.0", "preview.chip.1"])
        // every route point, the rider and the destination are on screen, clear of the cards
        let list = ui.displayList(now: 1)
        let proj = ui.mapProjection()!
        let card = region(list, "preview.card")!.rect
        for p in DashFixtures.preview().nav.preview!.routes.flatMap(\.points) + [TrackPoint(lat: DashFixtures.rider.lat, lon: DashFixtures.rider.lon)] {
            let s = proj.screenPoint(p.point)
            XCTAssertTrue(DashRect(x: 0, y: 0, width: 800, height: 384).contains(s), "\(s)")
            XCTAssertFalse(card.contains(s), "route point under the preview card \(s)")
        }
        XCTAssertEqual(tapRegion(ui, "preview.chip.1", at: 2), [.selectRoute(1)])
        XCTAssertEqual(tapRegion(ui, "preview.save", at: 3), [.saveFavorite])
        XCTAssertEqual(tapRegion(ui, "preview.circuit", at: 4), [.startCircuit])
        XCTAssertEqual(tapRegion(ui, "preview.cancel", at: 5), [.cancelPreview])
        XCTAssertEqual(ui.state.focusedId, "preview.cancel") // touch moved the focus
        _ = ui.handle(.knob(-2), now: 6) // cancel → circuit → go
        XCTAssertEqual(ui.state.focusedId, "preview.go")
        XCTAssertEqual(ui.handle(.key(.enter), now: 7), [.go])
        XCTAssertTrue(ui.state.camera.follow)
    }

    func testCancelledPreviewRestoresCamera() {
        let ui = controller(DashFixtures.freeRide())
        ui.update(DashFixtures.preview())
        XCTAssertEqual(ui.handle(.key(.back), now: 1), [.cancelPreview])
        ui.update(DashFixtures.freeRide()) // nav engine cancelled the preview
        let cam = ui.state.camera
        XCTAssertTrue(cam.follow)
        XCTAssertTrue(cam.headingUp)
        XCTAssertTrue(cam.speedZoom)
        XCTAssertEqual(cam.bearingDeg, 20, accuracy: 1e-9)
        XCTAssertEqual(ui.state.focusedId, "pill")
        // Android parity: the camera stays on the north-up overview
        var parity = DashUIController.Options()
        parity.restoreCameraAfterPreview = false
        let p = controller(DashFixtures.freeRide(), options: parity)
        p.update(DashFixtures.preview())
        p.update(DashFixtures.freeRide())
        XCTAssertFalse(p.state.camera.follow)
        XCTAssertFalse(p.state.camera.headingUp)
    }

    func testPinSetupKeepsRotationAndFocusesFirst() {
        var m = DashFixtures.freeRide()
        let ui = controller(m)
        let pin = Place(name: "Dropped pin", lat: 45.1285, lon: 25.7365, category: "pin", subtitle: "45.12850, 25.73650")
        m.nav.preview = RoutePreview(place: pin, meta: pin.subtitle, pinMode: true)
        ui.update(m)
        let st = ui.state
        XCTAssertFalse(st.camera.follow)
        XCTAssertTrue(st.camera.headingUp) // showPinSetup does not reset heading-up
        XCTAssertEqual(st.camera.zoom, 16)
        XCTAssertEqual(st.camera.center, pin.point)
        XCTAssertEqual(st.focusOrder, ["preview.cancel", "preview.save", "preview.home", "preview.marker"])
        XCTAssertEqual(st.focusedId, "preview.cancel") // "go" absent → first
        XCTAssertEqual(tapRegion(ui, "preview.home", at: 1), [.setHome])
        XCTAssertEqual(tapRegion(ui, "preview.marker", at: 2), [.addMarker])
    }

    func testNavigationStartFocusesRecenterAndFollows() {
        let ui = controller(DashFixtures.freeRide())
        ui.update(DashFixtures.preview())
        ui.update(DashFixtures.navigating())
        let st = ui.state
        XCTAssertTrue(st.camera.follow)
        XCTAssertTrue(st.camera.headingUp)
        XCTAssertTrue(st.camera.speedZoom)
        // P0 (D01): Recenter, never End (Android focused its End button: a ★ ended the route)
        XCTAssertEqual(st.focusedId, "fab.recenter")
        XCTAssertEqual(st.focusOrder, ["fab.recenter", "fab.zoomIn", "fab.zoomOut", "fab.compass", "fab.menu"])
        XCTAssertEqual(ui.handle(.key(.enter), now: 1), [.recenter])
        let list = ui.displayList(now: 1)
        XCTAssertNil(list.hitRegions.first { $0.id == "pill" }) // search pill hidden while navigating
        XCTAssertNotNil(list.hitRegions.first { $0.id == "nav.card" })
    }

    func testNavigationEndReturnsToDefaultFocus() {
        let ui = controller(DashFixtures.navigating())
        ui.update(DashFixtures.freeRide())
        XCTAssertEqual(ui.state.focusedId, "pill")
    }

    func testSeededCueWhileNavigatingWithoutCue() {
        var m = DashFixtures.navigating()
        m.nav.cue = nil
        let ui = controller(m)
        let t = texts(ui.displayList(now: 0))
        XCTAssertTrue(t.contains("GPS"))
        XCTAssertTrue(t.contains("To Câmpina"))
    }

    func testMetricsCardNeverUnderSpeedChip() {
        var m = DashFixtures.navigating()
        m.nav.metrics = HudMetrics(time: "1h05m", arrive: "14:20", left: "123.4 km", alt: "1234", altUnit: "m", status: "")
        let list = controller(m).displayList(now: 0)
        let card = region(list, "metrics.card")!.rect
        let chip = region(list, "speed.chip")!.rect
        XCTAssertFalse(card.intersects(chip))
        XCTAssertTrue(texts(list).contains("123.4 km"))
    }

    func testOffRouteWarningShownInLandscape() {
        let list = controller(DashFixtures.navigating(offRoute: true)).displayList(now: 0)
        let warn = list.commands.contains { cmd in
            if case let .text(s, _, style) = cmd { return s.contains("OFF 95 m") && style.color == DashPalette.statusWarning }
            return false
        }
        XCTAssertTrue(warn)
        let calm = controller(DashFixtures.navigating()).displayList(now: 0)
        XCTAssertFalse(texts(calm).contains { $0.hasPrefix("Route ·") }) // status hidden in landscape when not warning
        let port = controller(DashFixtures.navigating(DashFixtures.port)).displayList(now: 0)
        XCTAssertTrue(texts(port).contains("Route · 12.3 km · avg 41")) // portrait always shows it
    }

    // MARK: Arrival

    func testArrivalCardFocusAndActions() {
        let ui = controller(DashFixtures.navigating())
        ui.update(DashFixtures.arrival())
        // P0 (D22): «Done» first and focused (Android: Park here, so ★ marked a parked spot)
        XCTAssertEqual(ui.state.focusOrder, ["arrive.done", "arrive.park", "arrive.find"])
        XCTAssertEqual(ui.state.focusedId, "arrive.done")
        XCTAssertEqual(ui.handle(.key(.back), now: 1), [.dismissArrival])
        _ = ui.handle(.knob(2), now: 2)
        XCTAssertEqual(ui.state.focusedId, "arrive.find")
        XCTAssertEqual(ui.handle(.key(.enter), now: 3), [.findParking])
        XCTAssertEqual(ui.state.sheet, .search) // Find parking opens the search sheet
        let ui2 = controller(DashFixtures.arrival())
        XCTAssertEqual(tapRegion(ui2, "arrive.park", at: 1), [.markArrivalParking])
        XCTAssertEqual(tapRegion(ui2, "arrive.done", at: 2), [.dismissArrival])
    }

    func testBackOrderTopMostFirst() {
        // a sheet over the preview closes first (Android would cancel the preview underneath)
        let ui = controller(DashFixtures.preview())
        _ = ui.handle(.key(.assistant), now: 1)
        XCTAssertEqual(ui.handle(.key(.back), now: 2), [.closeSheets])
        XCTAssertEqual(ui.handle(.key(.back), now: 3), [.cancelPreview])
        XCTAssertEqual(controller(DashFixtures.freeRide()).handle(.key(.back), now: 1), [])
    }

    // MARK: Focus ring, toasts, banner, hold

    func testFocusRingHiddenAfterTouchUntilKey() {
        let ui = controller(DashFixtures.freeRide())
        XCTAssertTrue(hasFocusRing(ui.displayList(now: 0)))
        _ = tap(ui, DashPoint(300, 200), at: 1) // map tap
        XCTAssertFalse(hasFocusRing(ui.displayList(now: 2)))
        XCTAssertTrue(hasFocusRing(ui.displayList(now: 6.1)))
        _ = tap(ui, DashPoint(300, 200), at: 10)
        _ = ui.handle(.knob(1), now: 11)
        XCTAssertTrue(hasFocusRing(ui.displayList(now: 11)))
        var m = DashFixtures.freeRide()
        m.handlebarFocus = false
        XCTAssertFalse(hasFocusRing(controller(m).displayList(now: 0)))
    }

    func testTouchMovesFocusToControl() {
        let ui = controller(DashFixtures.freeRide())
        _ = tapRegion(ui, "fab.compass", at: 1)
        XCTAssertEqual(ui.state.focusedId, "fab.compass")
    }

    func testToastsAndBanner() {
        var m = DashFixtures.navigating()
        m.linkBanner = "Reconnecting…"
        let ui = controller(m)
        ui.showToast("Parking marked", now: 10)
        var t = texts(ui.displayList(now: 11))
        XCTAssertTrue(t.contains("Reconnecting…"))
        XCTAssertTrue(t.contains("Parking marked"))
        t = texts(ui.displayList(now: 12.6))
        XCTAssertFalse(t.contains("Parking marked"))
        m.toastText = "Routing…"
        ui.update(m)
        XCTAssertTrue(texts(ui.displayList(now: 20)).contains("Routing…"))
        XCTAssertEqual(ui.state.toast, "Routing…")
    }

    func testHoldScreen() {
        var m = DashFixtures.navigating()
        m.holdMessage = "Paused — open the app"
        let ui = controller(m)
        let list = ui.displayList(now: 0)
        XCTAssertTrue(list.hitRegions.isEmpty)
        XCTAssertTrue(texts(list).contains("Paused — open the app"))
        XCTAssertEqual(tap(ui, DashPoint(400, 200), at: 1), [])
        // P0 (D17): keys and the knob act on nothing either; no map, no gauge, no stale numbers
        XCTAssertEqual(ui.handle(.key(.enter), now: 2), [])
        XCTAssertEqual(ui.handle(.knob(1), now: 2.1), [])
        XCTAssertEqual(ui.handle(.key(.home), now: 2.2), [])
        XCTAssertEqual(ui.state.sheet, .none)
        XCTAssertFalse(list.commands.contains { if case .tile = $0 { return true }; return false })
        XCTAssertFalse(texts(list).contains("47"), "no speed")
        XCTAssertFalse(texts(list).contains("350 m"), "no turn distance")
        XCTAssertFalse(texts(list).contains("14:23"), "no arrival time")
        let explicit = controller(DashFixtures.freeRide()).displayList(forHoldScreen: nil, now: 0)
        XCTAssertEqual(texts(explicit), ["Map paused", "Resumes when you open the app, stopped"])
        // the voice line only while a route runs with the voice on
        XCTAssertEqual(texts(controller(DashFixtures.navigating()).displayList(forHoldScreen: nil, now: 0)),
                       ["Map paused", "Voice keeps guiding", "Resumes when you open the app, stopped"])
        var muted = DashFixtures.navigating()
        muted.preferences.voiceOn = false
        muted.language = .es
        XCTAssertEqual(texts(controller(muted).displayList(forHoldScreen: nil, now: 0)),
                       ["Mapa en pausa", "Se reanuda al abrir la app, detenido"])
    }

    // MARK: Map content

    func testTileTreatmentFollowsNightAndStyle() {
        // P0 (D05): the muted treatments by default; the classic style keeps the tiles as downloaded by day and
        // inverted at night
        var m = DashFixtures.navigating()
        func treatments(_ m: DashModel) -> Set<DashTileTreatment> {
            Set(controller(m).displayList(now: 0).commands.compactMap { if case let .tile(_, _, _, _, t) = $0 { return t }; return nil })
        }
        XCTAssertEqual(treatments(m), [.mutedDay])
        m.isNight = true
        XCTAssertEqual(treatments(m), [.mutedNight])
        m.mapStyle = .classic
        XCTAssertEqual(treatments(m), [.inverted])
        m.isNight = false
        XCTAssertEqual(treatments(m), [.normal])
        XCTAssertEqual(DashTileTreatment.of(night: true), .mutedNight)
        XCTAssertTrue(DashTileTreatment.inverted.isNight && DashTileTreatment.mutedNight.isNight)
        XCTAssertFalse(DashTileTreatment.normal.isNight || DashTileTreatment.mutedDay.isNight)
        var night = DashFixtures.navigating()
        night.isNight = true
        XCTAssertEqual(controller(DashFixtures.navigating()).displayList(now: 0).background,
                       controller(night).displayList(now: 0).background) // chrome background unchanged at night
    }

    func testRouteLinesStyles() {
        let list = controller(DashFixtures.navigating()).displayList(now: 0)
        let strokes = list.commands.compactMap { cmd -> DashStroke? in
            if case let .stroke(_, s) = cmd { return s }
            return nil
        }
        // P0 (D05): the remaining route over its casing (white by day), the travelled part grey
        let remain = try! XCTUnwrap(strokes.firstIndex { $0.color == DashPalette.routeRemain(night: false) && $0.width == 10 && $0.cap == .round })
        let casing = try! XCTUnwrap(strokes.firstIndex { $0.color == DashPalette.routeCasing(night: false) && $0.width == 17 })
        XCTAssertLessThan(casing, remain, "the casing under the line")
        XCTAssertTrue(strokes.contains { $0.color == DashPalette.routeDone(night: false) && $0.width == 8 })
        let preview = controller(DashFixtures.preview()).displayList(now: 0).commands.compactMap { cmd -> DashStroke? in
            if case let .stroke(_, s) = cmd { return s }
            return nil
        }
        XCTAssertTrue(preview.contains { $0.color == DashPalette.routePreview && $0.width == 8 })
        XCTAssertTrue(preview.contains { $0.color == DashPalette.routeAlternative(night: false) && $0.width == 7 })
        XCTAssertTrue(preview.contains { $0.color == DashPalette.routeCasing(night: false) && $0.width == 13 })
        var nightModel = DashFixtures.navigating()
        nightModel.isNight = true
        let night = controller(nightModel).displayList(now: 0).commands.compactMap { cmd -> DashStroke? in
            if case let .stroke(_, s) = cmd { return s }
            return nil
        }
        XCTAssertTrue(night.contains { $0.color == DashPalette.routeRemain(night: true) && $0.width == 10 })
        XCTAssertTrue(night.contains { $0.color == DashPalette.routeCasing(night: true) && $0.width == 17 })
        // preview without routes yet: dashed yellow rider → destination line
        var loading = DashFixtures.preview()
        loading.nav.preview?.routes = []
        loading.nav.preview?.chipLabels = []
        let dashed = controller(loading).displayList(now: 0).commands.contains { cmd in
            if case let .stroke(_, s) = cmd { return s.color == DashPalette.routeToDestination && s.dash == [8, 6] && s.width == 3.5 }
            return false
        }
        XCTAssertTrue(dashed)
    }

    func testCameraPositionsOnDestinationWithoutFix() {
        var m = DashFixtures.navigating()
        m.fix = nil
        m.nav.puck = nil
        m.nav.route = nil
        let ui = controller(m)
        XCTAssertEqual(ui.state.camera.center, DashFixtures.campina.point)
        XCTAssertFalse(ui.visibleTiles().isEmpty)
        var empty = DashModel()
        empty.fix = nil
        let none = controller(empty)
        XCTAssertNil(none.mapProjection())
        XCTAssertFalse(none.displayList(now: 0).commands.contains { if case .tile = $0 { return true }; return false })
    }

    func testOverviewFitsRemainingRouteNorthUp() throws {
        let m = DashFixtures.navigating()
        let ui = controller(m)
        XCTAssertEqual(ui.perform(.overview, now: 5), [.overview])
        let cam = ui.state.camera
        XCTAssertFalse(cam.follow)
        XCTAssertFalse(cam.headingUp)
        XCTAssertEqual(cam.bearingDeg, 0)
        XCTAssertEqual(cam.autoRecenterAt, 17)
        XCTAssertEqual(ui.state.toast, "Route overview · north up")
        let proj = try XCTUnwrap(ui.mapProjection())
        let list = ui.displayList(now: 5)
        let nav = region(list, "nav.card")!.rect, metrics = region(list, "metrics.card")!.rect
        for p in m.nav.route!.points[6...] {
            let s = proj.screenPoint(p.point)
            XCTAssertGreaterThanOrEqual(s.y, nav.maxY - 0.5)
            XCTAssertLessThanOrEqual(s.y, metrics.minY + 0.5)
        }
        // no route: centre on the rider at zoom 14
        let free = controller(DashFixtures.freeRide())
        _ = free.perform(.overview, now: 1)
        XCTAssertEqual(free.state.camera.zoom, 14)
        XCTAssertEqual(free.state.camera.center, DashFixtures.rider)
        XCTAssertEqual(free.state.toast, "Overview · north up")
    }

    func testSpanishChrome() {
        var m = DashFixtures.preview()
        m.language = .es
        let t = texts(controller(m).displayList(now: 0))
        XCTAssertTrue(t.contains("Ir"))
        XCTAssertTrue(t.contains("★ Guardar"))
        XCTAssertTrue(t.contains("Circuito"))
        XCTAssertTrue(t.contains("Cancelar"))
        var nav = DashFixtures.navigating()
        nav.language = .es
        let ui = controller(nav)
        _ = ui.perform(.openMenu, now: 0)
        let top = texts(ui.displayList(now: 0))
        _ = ui.handle(.knob(ui.state.focusOrder.firstIndex(of: "menu.end")!), now: 0.1) // scrolled into view
        let menu = texts(ui.displayList(now: 0.2))
        // P0 (D23): neutral Latin-American Spanish (was «Finalizar navegación», «Conducir»)
        XCTAssertTrue(menu.contains("Terminar la ruta…"), "\(menu)")
        XCTAssertTrue(top.contains("Viaje"), "\(top)")
        XCTAssertTrue(top.contains("Recentrar"), "\(top)")
        XCTAssertFalse((top + menu).contains("Conducir"))
    }

    func testFirstFixPositionsCameraEvenWhenNotFollowing() {
        var m = DashModel()
        let ui = controller(m)
        _ = ui.perform(.zoomIn, now: 0) // rider zooms before any fix → free pan
        XCTAssertNil(ui.mapProjection())
        m = DashFixtures.freeRide()
        ui.update(m)
        XCTAssertFalse(ui.state.camera.follow)
        XCTAssertEqual(ui.state.camera.center, DashFixtures.rider)
        XCTAssertEqual(ui.state.camera.zoom, 17)
    }

    func testButtonActionMapping() {
        XCTAssertNil(DashInput(buttonAction: .none))
        XCTAssertEqual(DashInput(buttonAction: .knobFwd), .knob(1))
        XCTAssertEqual(DashInput(buttonAction: .knobBack), .knob(-1))
        XCTAssertEqual(DashInput(buttonAction: .select), .key(.enter))
        XCTAssertEqual(DashInput(buttonAction: .back), .key(.back))
        XCTAssertEqual(DashInput(buttonAction: .home), .key(.home))
        XCTAssertEqual(DashInput(buttonAction: .assistant), .key(.assistant))
        XCTAssertEqual(DashInput(buttonAction: .up), .key(.up))
        XCTAssertEqual(DashInput(buttonAction: .down), .key(.down))
        XCTAssertEqual(DashInput(buttonAction: .left), .key(.left))
        XCTAssertEqual(DashInput(buttonAction: .right), .key(.right))
        XCTAssertEqual(DashInput(buttonAction: .nav1), .savedPlace(1))
        XCTAssertEqual(DashInput(buttonAction: .nav3), .savedPlace(3))
        // default ButtonMap: Select-hold = HOME → menu; ×2 → D-pad focus
        let ui = controller(DashFixtures.freeRide())
        XCTAssertEqual(ui.handle(DashInput(buttonAction: ButtonGesture.selectLong.defaultAction)!, now: 0), [.openMenu])
    }

    func testSavedPlaceAndUIOnlyFlags() {
        let ui = controller(DashFixtures.freeRide())
        XCTAssertEqual(ui.handle(.savedPlace(2), now: 0), [.navigateSavedPlace(2)])
        XCTAssertTrue(DashIntent.openMenu.isUIOnly)
        XCTAssertTrue(DashIntent.zoomIn.isUIOnly)
        XCTAssertFalse(DashIntent.go.isUIOnly)
        XCTAssertFalse(DashIntent.dropPin(GeoPoint(lat: 0, lon: 0)).isUIOnly)
    }

    func testScaledCanvasUsesDensity() {
        let ui = controller(DashFixtures.navigating(DashFixtures.wide))
        let list = ui.displayList(now: 0)
        XCTAssertEqual(region(list, "fab.recenter")!.rect.width, 46 * 1.425, accuracy: 1e-9)
        let tiles = list.commands.compactMap { cmd -> DashRect? in if case let .tile(_, _, _, r, _) = cmd { return r }; return nil }
        XCTAssertGreaterThan(tiles.first!.width, 256) // osmdroid isTilesScaledToDpi
    }

    func testConcurrentAccess() {
        let ui = controller(DashFixtures.navigating())
        let models = [DashFixtures.navigating(), DashFixtures.freeRide(), DashFixtures.preview(), DashFixtures.arrival()]
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            switch i % 4 {
            case 0: ui.update(models[(i / 4) % models.count])
            case 1: _ = ui.displayList(now: Double(i))
            case 2: _ = ui.handle(.knob(1), now: Double(i))
            default: _ = ui.tick(now: Double(i))
            }
        }
        XCTAssertFalse(ui.displayList(now: 1000).commands.isEmpty)
    }
}

final class DashNavTransitionTests: XCTestCase {
    func testDestinationRefreshDoesNotRestartNavigation() {
        let ui = DashUIController()
        var m = DashFixtures.navigating()
        ui.update(m)
        _ = ui.perform(.zoomIn, now: 1) // rider pans / zooms during the ride
        XCTAssertFalse(ui.state.camera.follow)
        m.nav.destination?.subtitle = "Prahova, România · updated"
        if case let .navTo(p) = m.nav.mode {
            var q = p
            q.subtitle = "updated"
            m.nav.mode = .navTo(q)
        }
        ui.update(m)
        XCTAssertFalse(ui.state.camera.follow) // no camera reset: same navigation
        // a different destination is a new navigation
        var other = Place(name: "Sinaia", lat: 45.35, lon: 25.55)
        other.category = "city"
        m.nav.mode = .navTo(other)
        m.nav.destination = other
        ui.update(m)
        XCTAssertTrue(ui.state.camera.follow)
        XCTAssertEqual(ui.state.focusedId, "fab.recenter")
    }

    func testNavIdentity() {
        XCTAssertNil(DashUIController.navIdentity(DashFixtures.freeRide()))
        XCTAssertEqual(DashUIController.navIdentity(DashFixtures.navigating()), "nav:45.13000,25.74000")
        var g = DashFixtures.freeRide()
        g.nav.mode = .gpx(name: "Transfăgărășan")
        XCTAssertEqual(DashUIController.navIdentity(g), "gpx:Transfăgărășan")
    }
}
