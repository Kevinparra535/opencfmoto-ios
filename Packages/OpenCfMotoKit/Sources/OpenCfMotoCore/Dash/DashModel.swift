// SPDX-License-Identifier: AGPL-3.0-or-later
// Everything the dash UI renders that it does not own itself. The app fills a `DashModel` every
// frame (or on change) and hands it to `DashUIController.update(_:)`. The navigation engine owns
// all navigation state (`NavSnapshot`); the controller owns only UI state (sheets, focus, camera,
// toasts, scroll offsets).

import Foundation

/// Saved places shown in the dash search sheet's idle list (navigation-dash.md §7.6, §12.1).
public struct DashPlaces: Sendable, Equatable {
    public var home: Place?
    public var parked: Place?
    /// Newest first.
    public var favorites: [Place]
    /// Newest first.
    public var markers: [Place]
    /// Newest first (recent places / tracks).
    public var history: [Place]

    public init(home: Place? = nil, parked: Place? = nil, favorites: [Place] = [], markers: [Place] = [], history: [Place] = []) {
        self.home = home; self.parked = parked; self.favorites = favorites; self.markers = markers; self.history = history
    }

    public static let empty = DashPlaces()

    /// The search sheet idle list (`showIdle`, GpxDashUi.kt:981-1009): home, parked, favorites,
    /// markers, history (minus category `mode`, `parking` and places at exactly (0,0)), distinct
    /// by `"<name>|%.4f|%.4f"`, first `limit` (12).
    public func idleList(limit: Int = 12) -> [Place] {
        let hist = history.filter { $0.category != "mode" && $0.category != "parking" && !($0.lat == 0 && $0.lon == 0) }
        let all = [home, parked].compactMap { $0 } + favorites + markers + hist
        var seen = Set<String>()
        var out: [Place] = []
        for p in all {
            let key = "\(p.name)|\(String(format: "%.4f", p.lat))|\(String(format: "%.4f", p.lon))"
            guard seen.insert(key).inserted else { continue }
            out.append(p)
            if out.count >= limit { break }
        }
        return out
    }

    /// Whether a search row offers "Delete" (GpxDashUi.kt:925-944): a saved marker / favorite /
    /// parked spot / history entry at the same location, or category pin / parking / home.
    public func canDelete(_ p: Place) -> Bool {
        if ["pin", "parking", "home"].contains(p.category) { return true }
        if markers.contains(where: { $0.isSameLocation(as: p) }) { return true }
        if favorites.contains(where: { $0.isSameLocation(as: p) }) { return true }
        if let parked, parked.isSameLocation(as: p) { return true }
        if let home, home.isSameLocation(as: p) { return true }
        return history.contains(where: { $0.isSameLocation(as: p) })
    }
}

/// Search sheet content provided by the app (results come from Photon / Nominatim / Overpass).
public struct DashSearchState: Sendable, Equatable {
    /// Android POI chips (NominatimSearch.POI_CHIPS) — the ids are also the English labels.
    public static let defaultPoiChips = ["Fuel", "Cafe", "Food", "Parking", "Hotel", "ATM", "Hospital", "Viewpoint"]

    /// Text typed on the phone (shown in the sheet's input field); empty = hint.
    public var query: String
    /// Results of the last search / POI chip; nil = show the idle list (recent & favorites).
    public var results: [Place]?
    /// Status line ("Searching…", "Finding Fuel nearby…", errors…). nil = default status
    /// ("⌨ Type on PHONE — results show here" while idle, "<n> places" / "No results" with results).
    public var status: String?
    /// POI chip ids, in order (tap → `DashIntent.searchChip(id)`).
    public var poiChips: [String]

    public init(query: String = "", results: [Place]? = nil, status: String? = nil,
                poiChips: [String] = DashSearchState.defaultPoiChips) {
        self.query = query; self.results = results; self.status = status; self.poiChips = poiChips
    }
}

/// Lap timer card content (shown while the lap timer is armed; the pill then reads "Stop").
public struct DashLapTimer: Sendable, Equatable {
    /// Line 1, e.g. "Pass start/finish" or "LAP 2  0:31.20".
    public var title: String
    /// Line 2, e.g. "LAST 0:30.00   BEST 0:30.00".
    public var meta: String
    public init(title: String, meta: String) { self.title = title; self.meta = meta }
}

/// The per-frame input of the dash UI.
public struct DashModel: Sendable, Equatable {
    /// Negotiated video canvas (exactly the encoder size), e.g. 800×384, 800×944, 1280×576.
    public var canvas: DashSize
    /// Effective screen margins (profile default already resolved, e.g. 800NK Advanced top 22).
    /// The dash chrome and hit-testing stay inside; touches inside the margins are ignored.
    public var margins: ScreenMargins
    /// Fixed density for OEM paths (Yunmo / Ride MO: 187 dpi); nil = 160·W/900 rule.
    public var densityDpiOverride: Int?
    /// Navigation state published by the nav engine.
    public var nav: NavSnapshot
    /// Latest GPS fix (nil until the first fix).
    public var fix: LocationFix?
    /// Smoothed device heading (degrees, 0…360) — used while stopped in heading-up mode.
    public var compassHeadingDeg: Double?
    public var preferences: MapPreferences
    /// Night = tiles inverted (see `DashFormat.isNight`). Chrome is unchanged.
    public var isNight: Bool
    /// Wall clock for the clock chip.
    public var date: Date
    public var timeZone: TimeZone
    public var language: DashLanguage
    public var places: DashPlaces
    public var search: DashSearchState
    /// Manual trip recording active ("Stop recording" in the menu).
    public var recording: Bool
    /// Lap timer armed → card + "Stop" label; nil = disarmed.
    public var lapTimer: DashLapTimer?
    /// Persistent status text from the app (shown as a toast while non-nil). Transient toasts:
    /// `DashUIController.showToast(_:now:)`.
    public var toastText: String?
    /// Link state banner, e.g. "Reconnecting…" (nil = hidden).
    public var linkBanner: String?
    /// When set, every frame is the "hold" picture (dimmed scene + this message card), e.g.
    /// while the app is going to the background and VideoToolbox may stop encoding.
    public var holdMessage: String?
    /// Small HH:mm clock chip (iOS addition).
    public var showClock: Bool
    /// Handlebar focus engine enabled (handlebar control on): the orange ring is drawn.
    public var handlebarFocus: Bool
    /// Highest zoom of the raster tile source (OSM: 19); higher zooms over-zoom.
    public var maxTileZoom: Int

    public init(canvas: DashSize = DashSize(width: 800, height: 384), margins: ScreenMargins = .zero,
                densityDpiOverride: Int? = nil, nav: NavSnapshot = NavSnapshot(), fix: LocationFix? = nil,
                compassHeadingDeg: Double? = nil, preferences: MapPreferences = MapPreferences(), isNight: Bool = false,
                date: Date = Date(timeIntervalSince1970: 0), timeZone: TimeZone = TimeZone(identifier: "UTC") ?? .current,
                language: DashLanguage = .en, places: DashPlaces = .empty, search: DashSearchState = DashSearchState(),
                recording: Bool = false, lapTimer: DashLapTimer? = nil, toastText: String? = nil, linkBanner: String? = nil,
                holdMessage: String? = nil, showClock: Bool = true, handlebarFocus: Bool = true,
                maxTileZoom: Int = MapProjection.defaultMaxTileZoom) {
        self.canvas = canvas
        self.margins = margins
        self.densityDpiOverride = densityDpiOverride
        self.nav = nav
        self.fix = fix
        self.compassHeadingDeg = compassHeadingDeg
        self.preferences = preferences
        self.isNight = isNight
        self.date = date
        self.timeZone = timeZone
        self.language = language
        self.places = places
        self.search = search
        self.recording = recording
        self.lapTimer = lapTimer
        self.toastText = toastText
        self.linkBanner = linkBanner
        self.holdMessage = holdMessage
        self.showClock = showClock
        self.handlebarFocus = handlebarFocus
        self.maxTileZoom = maxTileZoom
    }

    /// Canvas size for a negotiated `VideoCanvas`.
    public static func canvasSize(_ c: VideoCanvas) -> DashSize { DashSize(width: Double(c.width), height: Double(c.height)) }

    public var units: MapUnits { preferences.units }
    /// Background behind the map (MapChrome).
    public var chromeColor: DashColor { DashPalette.chrome(preferences.chrome) }
    /// px per dp (density rule).
    public var scale: Double { DashDensity.scale(canvasWidth: canvas.width, overrideDpi: densityDpiOverride) }
    /// Landscape layout when W > H (Android `layout-land`).
    public var isLandscape: Bool { canvas.width > canvas.height }
    /// Raster tile pixel size (256 × density, osmdroid `isTilesScaledToDpi`).
    public var tileSize: Double { 256 * scale }

    /// The canvas minus the margins (at least 1 px each way).
    public var safeRect: DashRect { Self.safeRect(canvas: canvas, margins: margins) }

    public static func safeRect(canvas: DashSize, margins: ScreenMargins) -> DashRect {
        let m = margins.clamped()
        let l = min(Double(m.left), max(0, canvas.width - 1))
        let r = min(Double(m.right), max(0, canvas.width - 1 - l))
        let t = min(Double(m.top), max(0, canvas.height - 1))
        let b = min(Double(m.bottom), max(0, canvas.height - 1 - t))
        return DashRect(x: l, y: t, width: canvas.width - l - r, height: canvas.height - t - b)
    }

    // MARK: Derived UI state (navigation-dash.md §11.6)

    /// A route preview / pin setup is shown.
    public var inPreview: Bool { nav.preview != nil }
    /// `navigating = !inPreview && liveMode != FREE_RIDE` (GPX counts as navigating).
    public var navigating: Bool { !inPreview && nav.mode.isNavigating }
    /// The arrive card is shown (never together with a preview).
    public var showsArrival: Bool { nav.arrival != nil && !inPreview }
    /// The rider position for the map: snapped puck from the nav engine, else the raw fix.
    public var riderPosition: GeoPoint? { nav.puck ?? fix?.point }
}
