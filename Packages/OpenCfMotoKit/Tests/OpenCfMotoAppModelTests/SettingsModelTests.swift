// SPDX-License-Identifier: AGPL-3.0-or-later
// SettingsModel: per-bike scoping that follows the garage, every setter persisted through the store
// with its side effects, settings-pack and map-data round trips, EN/ES result messages
// (docs/spec/app-features.md §2, §3).

import Foundation
import XCTest
import OpenCfMotoCore
@testable import OpenCfMotoAppModel

final class SettingsModelTests: XCTestCase {

    override func tearDown() {
        // Keep the process-wide log bus redacting for the other tests.
        LogRedactor.install(on: .shared, includeSecrets: false)
        super.tearDown()
    }

    @MainActor
    private func makeModels(_ env: LDTestEnv) -> (GarageModel, SettingsModel) {
        let garage = GarageModel(core: env.core)
        return (garage, SettingsModel(core: env.core, garage: garage))
    }

    // MARK: Scope

    @MainActor
    func testEmptyGarageUsesGlobalScope() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (_, settings) = makeModels(env)
        XCTAssertNil(settings.bikeId)
        XCTAssertEqual(settings.current, env.core.settings.settings(forBike: nil))
        XCTAssertEqual(settings.current.buttonMap, HandlebarPresets.iosDefaultMapping)
        XCTAssertEqual(settings.savedPlaces.count, 3)
        XCTAssertEqual(settings.presence, HandlebarPresence())

        settings.setVideoQuality(.sharp)
        XCTAssertEqual(env.core.services.keyValueStore.string(forKey: "video_quality"), "SHARP")
        XCTAssertEqual(settings.current.videoQuality, .sharp)
    }

    @MainActor
    func testRescopesWhenTheGarageSelectionChanges() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (garage, settings) = makeModels(env)
        var observed: [BikeSettings] = []
        settings.observe { observed.append($0) }

        guard case let .paired(a) = garage.pair(rawQR: LDTest.docQR) else { return XCTFail("pairing failed") }
        XCTAssertEqual(settings.bikeId, a.id)
        XCTAssertEqual(observed.count, 1)                 // re-scope notifies even with equal values
        settings.setVideoQuality(.sharp)
        settings.setPowerMode(.saver)
        XCTAssertEqual(env.core.services.keyValueStore.string(forKey: "video_quality#\(a.id)"), "SHARP")
        XCTAssertNil(env.core.services.keyValueStore.string(forKey: "video_quality"))
        env.core.settings.setVolumeRockerPresence(.absent, forBike: a.id)

        guard case let .paired(b) = garage.pair(rawQR: LDTest.qr4288) else { return XCTFail("pairing failed") }
        XCTAssertEqual(settings.bikeId, b.id)
        XCTAssertEqual(settings.current.videoQuality, .balanced)   // B inherits the global default
        XCTAssertEqual(settings.current.powerMode, .balanced)
        XCTAssertEqual(settings.presence.volumeRocker, .unknown)
        XCTAssertEqual(observed.last?.videoQuality, .balanced)

        garage.select(a.id)
        XCTAssertEqual(settings.bikeId, a.id)
        XCTAssertEqual(settings.current.videoQuality, .sharp)
        XCTAssertEqual(settings.current.powerMode, .saver)
        XCTAssertEqual(settings.presence.volumeRocker, .absent)
        XCTAssertEqual(observed.last, settings.current)

        // Renaming the selected bike keeps the scope: no re-scope notification.
        let count = observed.count
        garage.rename(a.id, to: "Renamed")
        XCTAssertEqual(settings.bikeId, a.id)
        XCTAssertEqual(observed.count, count)

        garage.remove(a.id)
        XCTAssertEqual(settings.bikeId, b.id)
        garage.remove(b.id)
        XCTAssertNil(settings.bikeId)
    }

    @MainActor
    func testReloadResyncsWithExternalWrites() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (garage, settings) = makeModels(env)
        guard case let .paired(bike) = garage.pair(rawQR: LDTest.docQR) else { return XCTFail("pairing failed") }
        var observed = 0
        settings.observe { _ in observed += 1 }

        env.core.settings.setTrackKeysPresence(.present, forBike: bike.id)
        env.core.settings.setSavedPlace(2, name: "Work", query: "4.65,-74.05")
        settings.reload()
        XCTAssertEqual(settings.presence.trackKeys, .present)
        XCTAssertEqual(settings.savedPlaces[2], SavedPlaceSlot(name: "Work", query: "4.65,-74.05"))
        XCTAssertEqual(observed, 0)    // `current` did not change

        env.core.settings.setScreenFit(.stretch, forBike: bike.id)
        settings.reload()
        XCTAssertEqual(settings.current.screenFit, .stretch)
        XCTAssertEqual(observed, 1)
    }

    // MARK: Setters

    @MainActor
    func testEverySetterPersistsAndNotifies() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (garage, settings) = makeModels(env)
        guard case let .paired(bike) = garage.pair(rawQR: LDTest.docQR) else { return XCTFail("pairing failed") }
        let store = env.core.settings
        let kv = env.core.services.keyValueStore
        var observed: [BikeSettings] = []
        settings.observe { observed.append($0) }
        func persisted() -> BikeSettings { store.settings(forBike: bike.id) }

        settings.setVideoQuality(.smooth)
        XCTAssertEqual(persisted().videoQuality, .smooth)
        XCTAssertEqual(kv.string(forKey: "video_quality#\(bike.id)"), "SMOOTH")
        settings.setScreenFit(.fit)
        XCTAssertEqual(persisted().screenFit, .fit)
        settings.setMirrorOrientation(.portrait)
        XCTAssertEqual(persisted().mirrorOrientation, .portrait)
        settings.setProfileOverride(.cfdl26Portrait)
        XCTAssertEqual(kv.string(forKey: "profile_override#\(bike.id)"), "cfdl26_port")
        settings.setProfileOverride(nil)
        XCTAssertNil(kv.string(forKey: "profile_override#\(bike.id)"))   // Auto removes the key
        XCTAssertNil(settings.current.profileOverride)

        settings.setForceNonTouch(true)
        XCTAssertTrue(settings.current.forceNonTouch)
        XCTAssertFalse(settings.current.forceTouch)
        settings.setForceTouch(true)
        XCTAssertTrue(settings.current.forceTouch)
        XCTAssertFalse(settings.current.forceNonTouch)   // mutually exclusive
        settings.setForceTouch(false)
        XCTAssertFalse(settings.current.forceTouch)

        settings.setScreenMargins(ScreenMargins(top: 300, bottom: 4, left: -5, right: 12))
        XCTAssertEqual(settings.current.screenMargins, ScreenMargins(customised: true, top: 200, bottom: 4, left: 0, right: 12))
        settings.resetScreenMargins()
        XCTAssertFalse(settings.current.screenMargins.customised)
        XCTAssertEqual(kv.bool(forKey: "screen_margins.customised"), false)

        settings.setPowerMode(.auto)
        XCTAssertEqual(persisted().powerMode, .auto)

        settings.setHandlebarControl(false)
        XCTAssertFalse(persisted().handlebarControl)
        settings.setButtonAction(.nav2, for: .selectLong)
        XCTAssertEqual(persisted().buttonMap[.selectLong], .nav2)
        XCTAssertEqual(kv.string(forKey: "button_map.selectLong#\(bike.id)"), "nav2")

        var timing = ButtonTiming()
        timing.doubleTapMs = 450
        timing.holdsEnabled = false
        timing.holdMs = 800
        settings.setButtonTiming(timing)
        XCTAssertEqual(settings.current.buttonTiming, timing)
        XCTAssertEqual(kv.int(forKey: "opencfmoto_btn_timing.double_tap_ms"), 450)

        settings.setAutoConnect(false)
        settings.setAutoRecovery(false)
        settings.setLogTrips(false)
        settings.setKeepScreenOn(false)
        let p = persisted()
        XCTAssertFalse(p.autoConnect)
        XCTAssertFalse(p.autoRecovery)
        XCTAssertFalse(p.logTrips)
        XCTAssertFalse(p.keepScreenOn)
        XCTAssertEqual(kv.bool(forKey: "auto_connect"), false)

        XCTAssertEqual(settings.current, persisted())
        XCTAssertEqual(observed.last, settings.current)
        XCTAssertEqual(observed.count, 18)   // one notification per effective change

        // Re-selecting the current value is not a change.
        let count = observed.count
        settings.setPowerMode(.auto)
        XCTAssertEqual(observed.count, count)
    }

    @MainActor
    func testMapPreferencesTileTemplateAndOrsKeySideEffects() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (_, settings) = makeModels(env)
        let before = Log.shared.lines().last?.id ?? 0

        var prefs = MapPreferences()
        prefs.units = .imperial
        prefs.theme = .night
        prefs.voiceOn = false
        prefs.routeMode = .fun
        prefs.avoidTolls = true
        prefs.circuitKm = 500
        settings.setMapPreferences(prefs)
        XCTAssertEqual(settings.current.map.units, .imperial)
        XCTAssertEqual(settings.current.map.circuitKm, 150)          // clamped by the store
        XCTAssertEqual(env.core.navigation.preferences, settings.current.map)
        XCTAssertEqual(env.core.services.keyValueStore.string(forKey: "map_theme"), "NIGHT")

        settings.setTileURLTemplate("  https://tiles.example.org/{z}/{x}/{y}.png ")
        XCTAssertEqual(settings.current.tileURLTemplate, "https://tiles.example.org/{z}/{x}/{y}.png")
        XCTAssertEqual(env.projection.tileURLTemplate, "https://tiles.example.org/{z}/{x}/{y}.png")
        settings.setTileURLTemplate("   ")
        XCTAssertEqual(settings.current.tileURLTemplate, BikeSettings().tileURLTemplate)

        settings.setOrsApiKey("  ors-SECRET-key-123  ")
        XCTAssertEqual(settings.current.orsApiKey, "ors-SECRET-key-123")
        XCTAssertEqual(env.core.navigation.router.orsApiKey, "ors-SECRET-key-123")
        settings.setOrsApiKey("")
        XCTAssertEqual(env.core.navigation.router.orsApiKey, "")
        let messages = Log.shared.lines().filter { $0.id > before }.map(\.message)
        XCTAssertFalse(messages.contains { $0.contains("ors-SECRET-key-123") }, "the ORS key must never be logged")
    }

    @MainActor
    func testIncludeSecretsInstallsTheRedactor() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (_, settings) = makeModels(env)
        settings.setIncludeSecretsInLogs(true)
        XCTAssertTrue(settings.current.includeSecretsInLogs)
        XCTAssertNil(Log.shared.redactor)
        settings.setIncludeSecretsInLogs(false)
        XCTAssertFalse(settings.current.includeSecretsInLogs)
        let redactor = try XCTUnwrap(Log.shared.redactor)
        XCTAssertEqual(redactor("pwd=supersecret"), "pwd=\u{00AB}redacted\u{00BB}")
    }

    @MainActor
    func testButtonMapPresetsAndPresence() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (garage, settings) = makeModels(env)
        guard case let .paired(bike) = garage.pair(rawQR: LDTest.docQR) else { return XCTFail("pairing failed") }

        settings.setHandlebarControl(false)
        settings.applyClusterPreset(.backSet)
        XCTAssertEqual(settings.current.clusterPreset, .backSet)
        XCTAssertEqual(settings.current.buttonMap, HandlebarPresets.iosMapping(for: .backSet))
        XCTAssertTrue(settings.current.handlebarControl)               // apply forces capture on
        settings.clearClusterPreset()
        XCTAssertNil(settings.current.clusterPreset)
        XCTAssertEqual(settings.current.buttonMap, HandlebarPresets.iosDefaultMapping)

        // A stale GLOBAL map (written while no bike was selected) must not survive "Reset to defaults".
        env.core.settings.setButtonAction(.up, for: .navBack, forBike: nil)
        settings.setButtonAction(.home, for: .navFwd)
        settings.applyClusterPreset(.fiveWay)
        settings.setButtonAction(.assistant, for: .selectDouble)
        settings.resetButtonMap()
        XCTAssertEqual(settings.current.buttonMap, HandlebarPresets.iosDefaultMapping)
        XCTAssertNil(settings.current.clusterPreset)

        env.core.settings.setVolumeRockerPresence(.absent, forBike: bike.id)
        env.core.settings.setTrackKeysPresence(.present, forBike: bike.id)
        settings.reload()
        XCTAssertEqual(settings.presence, HandlebarPresence(volumeRocker: .absent, trackKeys: .present))
        settings.resetHandlebarPresence()
        XCTAssertEqual(settings.presence, HandlebarPresence())
        XCTAssertEqual(env.core.settings.presence(forBike: bike.id), HandlebarPresence())
    }

    @MainActor
    func testTeachPresenceSettersScopeToTheSelectedBike() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (garage, settings) = makeModels(env)
        guard case let .paired(a) = garage.pair(rawQR: LDTest.docQR) else { return XCTFail("pairing failed") }
        var observed = 0
        settings.observe { _ in observed += 1 }

        // "Teach my handlebar": Present / Absent / Unknown per source, stored for the selected bike.
        settings.setVolumeRockerPresence(.present)
        XCTAssertEqual(settings.presence, HandlebarPresence(volumeRocker: .present, trackKeys: .unknown))
        settings.setTrackKeysPresence(.absent)
        XCTAssertEqual(settings.presence, HandlebarPresence(volumeRocker: .present, trackKeys: .absent))
        XCTAssertEqual(env.core.settings.presence(forBike: a.id), settings.presence)
        XCTAssertEqual(env.core.services.keyValueStore.string(forKey: "button_presence.volume_rocker#\(a.id)"), "PRESENT")
        XCTAssertEqual(env.core.services.keyValueStore.string(forKey: "button_presence.track_keys#\(a.id)"), "ABSENT")
        XCTAssertEqual(observed, 0, "presence is not part of `current`")

        // Every bike has its own presence.
        guard case let .paired(b) = garage.pair(rawQR: LDTest.qr4288) else { return XCTFail("pairing failed") }
        XCTAssertEqual(settings.presence, HandlebarPresence())
        settings.setVolumeRockerPresence(.absent)
        XCTAssertEqual(env.core.settings.presence(forBike: b.id).volumeRocker, .absent)
        XCTAssertEqual(env.core.settings.presence(forBike: a.id).volumeRocker, .present)
        garage.select(a.id)
        XCTAssertEqual(settings.presence, HandlebarPresence(volumeRocker: .present, trackKeys: .absent))

        // Unknown = untested again (the probe decides); Reset clears both sources.
        settings.setVolumeRockerPresence(.unknown)
        XCTAssertEqual(settings.presence.volumeRocker, .unknown)
        XCTAssertEqual(env.core.settings.presence(forBike: a.id).volumeRocker, .unknown)
        settings.resetHandlebarPresence()
        XCTAssertEqual(settings.presence, HandlebarPresence())
        XCTAssertEqual(env.core.settings.presence(forBike: b.id).volumeRocker, .absent)
    }

    @MainActor
    func testSavedPlacesAndDefaultMargins() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (garage, settings) = makeModels(env)

        settings.setSavedPlace(1, name: "  Home ", query: " Calle 80 # 10 ")
        XCTAssertEqual(settings.savedPlaces[1], SavedPlaceSlot(name: "Home", query: "Calle 80 # 10"))
        XCTAssertEqual(env.core.savedSlots.query(1), "Calle 80 # 10")   // same keys as the nav slots
        settings.setSavedPlace(3, name: "x", query: "y")                  // out of range: ignored
        settings.setSavedPlace(-1, name: "x", query: "y")
        XCTAssertEqual(settings.savedPlaces.count, 3)
        XCTAssertEqual(settings.savedPlaces.filter(\.isSet).count, 1)

        XCTAssertEqual(settings.defaultMargins(for: .nkAdvanced).top, 22)
        XCTAssertFalse(settings.defaultMargins(for: .nkAdvanced).customised)
        XCTAssertEqual(settings.defaultMargins(for: .cfdl26Portrait), ScreenMargins.zero)
        XCTAssertEqual(settings.defaultMargins(for: nil), ScreenMargins.zero)
        guard case let .paired(bike) = garage.pair(rawQR: LDTest.qr4288) else { return XCTFail("pairing failed") }
        env.core.garage.setProfileHint(bike.id, .nkAdvanced)
        garage.reload()
        XCTAssertEqual(settings.defaultMargins(for: nil).top, 22)   // Auto → the identified profile
    }

    @MainActor
    func testProfileNames() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (_, settings) = makeModels(env)
        XCTAssertEqual(settings.profileChoices.count, BikeProfileID.allCases.count + 1)
        XCTAssertNil(settings.profileChoices.first!)
        XCTAssertEqual(settings.profileName(nil), env.strings.auto)
        XCTAssertEqual(settings.profileName(.nkAdvanced), "CFDL26 / 800NK Advanced (touch, 720\u{00D7}712)")
        XCTAssertEqual(LogicData.Strings(.en).auto, "Auto")
        XCTAssertEqual(LogicData.Strings(.es).auto, "Automático")
    }

    // MARK: Settings pack

    @MainActor
    func testSettingsPackExportImportRoundTrip() async throws {
        let source = LDTestEnv()
        source.cleanUp(after: self)
        let (garageA, settingsA) = makeModels(source)
        settingsA.timeZone = TimeZone(identifier: "UTC")!
        guard case .paired = garageA.pair(rawQR: LDTest.qr4288) else { return XCTFail("pairing failed") }
        settingsA.setVideoQuality(.sharp)
        settingsA.setScreenFit(.fit)
        settingsA.setPowerMode(.auto)
        settingsA.setProfileOverride(.cfdl26Portrait)
        settingsA.setForceTouch(true)
        settingsA.setScreenMargins(ScreenMargins(top: 12, bottom: 0, left: 4, right: 4))
        settingsA.applyClusterPreset(.backSet)
        settingsA.setKeepScreenOn(false)

        let file = try settingsA.exportSettings()
        XCTAssertEqual(file.fileName, "OpenCfMoto-cfdl26_port-settings.json")
        XCTAssertEqual(file.typeIdentifier, "public.json")
        XCTAssertEqual(file.url.deletingLastPathComponent().standardizedFileURL.path,
                       source.services.files.exportsDirectory.standardizedFileURL.path)
        let text = LDTest.read(file)
        XCTAssertTrue(text.hasPrefix("{\n  \"format\": \"opencfmoto.settings\",\n  \"version\": 1,\n"), text)
        XCTAssertTrue(text.contains("\"exportedAt\": \"2026-10-31T15:42:07Z\""), text)
        XCTAssertTrue(text.contains("\"appVersion\": \"0.1.0\""), text)
        XCTAssertTrue(text.contains("\"profile\": \"CFDL26 \\/ MotoPlay Portrait (1000 MT-X)\""), text)
        XCTAssertFalse(text.contains(LDTest.qr4288Password))
        XCTAssertFalse(text.contains("CFMOTO4288"))   // no SSID / bike name in a tuning pack

        // Import on another phone with another bike.
        let target = LDTestEnv()
        target.cleanUp(after: self)
        let (garageB, settingsB) = makeModels(target)
        guard case let .paired(bike) = garageB.pair(rawQR: LDTest.docQR) else { return XCTFail("pairing failed") }
        garageB.rename(bike.id, to: "My 675")
        var observed = 0
        settingsB.observe { _ in observed += 1 }
        let result = settingsB.importSettings(text)
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.message, target.strings.settingsImportMessage(
            "Imported bike tuning (CFDL26 / MotoPlay Portrait (1000 MT-X)) onto My 675", ontoEnglish: "My 675"))
        XCTAssertGreaterThan(observed, 0)
        let imported = settingsB.current
        XCTAssertEqual(imported.videoQuality, .sharp)
        XCTAssertEqual(imported.screenFit, .fit)
        XCTAssertEqual(imported.powerMode, .auto)
        XCTAssertEqual(imported.profileOverride, .cfdl26Portrait)
        XCTAssertTrue(imported.forceTouch)
        XCTAssertEqual(imported.screenMargins, ScreenMargins(customised: true, top: 12, bottom: 0, left: 4, right: 4))
        XCTAssertEqual(imported.buttonMap, HandlebarPresets.iosMapping(for: .backSet))
        XCTAssertFalse(imported.keepScreenOn)
        XCTAssertEqual(imported, target.core.settings.settings(forBike: bike.id))
        // Per-bike values landed on the selected bike's scope.
        XCTAssertEqual(target.core.services.keyValueStore.string(forKey: "video_quality#\(bike.id)"), "SHARP")

        // Exporting again gives the same tuning.
        settingsB.timeZone = TimeZone(identifier: "UTC")!
        let again = LDTest.read(try settingsB.exportSettings())
        XCTAssertEqual(again, text)
    }

    @MainActor
    func testSettingsImportFailures() async throws {
        let env = LDTestEnv()
        env.cleanUp(after: self)
        let (_, settings) = makeModels(env)
        let s = env.strings
        XCTAssertEqual(settings.importSettings("  \n ").message, s.emptyFile)
        XCTAssertFalse(settings.importSettings("  \n ").ok)
        let notJSON = settings.importSettings("{ nope")
        XCTAssertFalse(notJSON.ok)
        XCTAssertTrue(notJSON.message.hasPrefix(env.core.language == .es ? "JSON no válido: " : "Not valid JSON: "), notJSON.message)
        XCTAssertEqual(settings.importSettings(#"{"format":"other","version":1,"settings":{}}"#).message,
                       s.settingsImportMessage("Not an OpenCfMoto settings file (format=other)", ontoEnglish: nil))
        XCTAssertEqual(settings.importSettings(#"{"format":"opencfmoto.settings","version":2,"settings":{}}"#).message,
                       s.settingsImportMessage("Unsupported settings version 2 (this app reads 1\u{2026}1)", ontoEnglish: nil))
        XCTAssertEqual(settings.importSettings(#"{"format":"opencfmoto.settings","version":1}"#).message,
                       s.settingsImportMessage("Missing settings object", ontoEnglish: nil))
        // No bike selected: global keys, Android's "selected bike" wording.
        let ok = settings.importSettings(#"{"format":"opencfmoto.settings","version":1,"settings":{"powerMode":"SAVER"}}"#)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.message, s.settingsImportMessage("Bike tuning imported onto selected bike", ontoEnglish: nil))
        XCTAssertEqual(settings.current.powerMode, .saver)
    }

    func testSettingsImportMessagesInSpanish() {
        let es = LogicData.Strings(.es)
        let en = LogicData.Strings(.en)
        let msg = "Imported bike tuning (CFDL26 / 800NK Advanced (touch, 720×712)) onto My Bike"
        XCTAssertEqual(en.settingsImportMessage(msg, ontoEnglish: "My Bike"), msg)
        XCTAssertEqual(es.settingsImportMessage(msg, ontoEnglish: "My Bike"),
                       "Ajustes de la moto importados (CFDL26 / 800NK Advanced (touch, 720×712)) en My Bike")
        XCTAssertEqual(es.settingsImportMessage("Bike tuning imported onto selected bike", ontoEnglish: nil),
                       "Ajustes de la moto importados en la moto seleccionada")
        XCTAssertEqual(es.settingsImportMessage("Imported bike tuning (auto) onto selected bike", ontoEnglish: nil),
                       "Ajustes de la moto importados (auto) en la moto seleccionada")
        XCTAssertEqual(es.settingsImportMessage("Not valid JSON: Unterminated object", ontoEnglish: nil),
                       "JSON no válido: Unterminated object")
        XCTAssertEqual(es.settingsImportMessage("Not an OpenCfMoto settings file (format=x)", ontoEnglish: nil),
                       "No es un archivo de ajustes de OpenCfMoto (format=x)")
        XCTAssertEqual(es.settingsImportMessage("Unsupported settings version 3 (this app reads 1\u{2026}1)", ontoEnglish: nil),
                       "Versión de ajustes no compatible: 3 (esta app lee 1\u{2026}1)")
        XCTAssertEqual(es.settingsImportMessage("Missing settings object", ontoEnglish: nil),
                       "Falta el objeto \u{00AB}settings\u{00BB}")
        XCTAssertEqual(es.settingsImportMessage("Import failed: boom", ontoEnglish: nil), "Error al importar: boom")
        XCTAssertEqual(es.emptyFile, "Archivo vacío")
        XCTAssertEqual(es.exportFailed("x"), "Error al exportar: x")
    }

    // MARK: Map data

    @MainActor
    func testMapDataExportImportRoundTrip() async throws {
        let source = LDTestEnv()
        source.cleanUp(after: self)
        let (_, settingsA) = makeModels(source)
        settingsA.timeZone = TimeZone(identifier: "UTC")!
        var prefs = MapPreferences()
        prefs.units = .imperial
        prefs.voiceOn = false
        prefs.chrome = .slate
        prefs.routeMode = .fun
        prefs.avoidHighways = true
        prefs.circuitKm = 90
        settingsA.setMapPreferences(prefs)
        let places = source.core.places
        places.addFavorite(Place(name: "Café Bogotá", lat: 4.6097, lon: -74.0817, category: "cafe", subtitle: "Centro"))
        places.addMarker(Place(name: "Viewpoint", lat: 4.7, lon: -74.1, category: "pin"))
        places.setHome(Place(name: "Home", lat: 4.65, lon: -74.05))
        places.setParked(Place(name: "Parked", lat: 4.66, lon: -74.06))
        settingsA.setOrsApiKey("ors-secret-never-exported")

        let file = try settingsA.exportMapData()
        XCTAssertEqual(file.fileName, "OpenCfMoto-map-20261031.json")
        XCTAssertEqual(file.typeIdentifier, "public.json")
        let text = LDTest.read(file)
        XCTAssertTrue(text.contains("\"format\": \"opencfmoto.map\""), text)
        XCTAssertFalse(text.contains("ors-secret-never-exported"))

        let target = LDTestEnv()
        target.cleanUp(after: self)
        let (_, settingsB) = makeModels(target)
        var observed: [BikeSettings] = []
        settingsB.observe { observed.append($0) }
        let result = settingsB.importMapData(text)
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.message, target.strings.mapImportMessage("Map data imported"))
        XCTAssertEqual(settingsB.current.map, settingsA.current.map)
        XCTAssertEqual(target.core.navigation.preferences, settingsA.current.map)
        XCTAssertEqual(observed.last?.map, settingsA.current.map)
        XCTAssertEqual(target.core.places.favorites(), places.favorites())
        XCTAssertEqual(target.core.places.markers(), places.markers())
        XCTAssertEqual(target.core.places.history(), places.history())
        XCTAssertEqual(target.core.places.home(), places.home())
        XCTAssertEqual(target.core.places.parked(), places.parked())

        XCTAssertEqual(settingsB.importMapData(" ").message, target.strings.emptyFile)
        let wrong = settingsB.importMapData(#"{"format":"opencfmoto.settings","version":1}"#)
        XCTAssertFalse(wrong.ok)
        XCTAssertEqual(wrong.message, target.strings.mapImportMessage("Not an OpenCfMoto map file"))
        XCTAssertEqual(settingsB.importMapData(#"{"format":"opencfmoto.map","version":9}"#).message,
                       target.strings.mapImportMessage("Unsupported map backup version 9"))
    }

    func testMapImportMessagesInSpanish() {
        let es = LogicData.Strings(.es)
        XCTAssertEqual(es.mapImportMessage("Map data imported"), "Datos del mapa importados")
        XCTAssertEqual(es.mapImportMessage("Not an OpenCfMoto map file"), "No es un archivo de mapa de OpenCfMoto")
        XCTAssertEqual(es.mapImportMessage("Unsupported map backup version 2"), "Versión de copia del mapa no compatible: 2")
        XCTAssertEqual(es.mapImportMessage("Not valid JSON: bad"), "JSON no válido: bad")
        XCTAssertEqual(es.mapImportMessage("Import failed: favorites contains a non-object entry"),
                       "Error al importar: favorites contains a non-object entry")
        XCTAssertEqual(LogicData.Strings(.en).mapImportMessage("Map data imported"), "Map data imported")
    }
}
