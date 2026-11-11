// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt, DashMapController.kt, res/drawable/bg_*.xml,
// res/values/colors.xml, VideoPipeline.kt (density) — docs/spec/navigation-dash.md §11.1-§11.2.
//
// Android: ONE chrome palette for day and night (night only inverts the map tiles, §10.3). iOS P0 (the UI/UX
// proposal's quick wins): opaque near-black cards with an edge, a white outline-only focus ring, a cased
// route and a white puck, muted map tiles, and dark search surfaces at night (D05, D06, D09, D12).

import Foundation

/// Every colour of the dash UI (navigation-dash.md §11.2), as `DashColor` (0xAARRGGBB).
///
/// Dimensions that belong to a style (radii, stroke widths) are in **dp**; multiply by
/// `DashDensity.scale(canvasWidth:)` to get canvas pixels.
public enum DashPalette {
    // MARK: Chrome background (behind the map)

    /// Root / chrome background for a `MapChrome` setting (Dark #101418, Black, Slate, Forest).
    public static func chrome(_ chrome: MapChrome) -> DashColor { DashColor(argb: chrome.argb) }
    public static let chromeDefault = DashColor(argb: 0xFF10_1418)

    // MARK: Cards (bg_nav_card / bg_nav_top_edge / bg_nav_bottom_edge)

    /// Opaque #0B0D10 (P0, D12: Android's 94 % #1A2332 let the map show through the numbers) — nav card
    /// (landscape), metrics card, preview, arrive, confirm, lap card, clock, speed gauge.
    public static let cardFill = DashColor(argb: 0xFF0B_0D10)
    /// The cards' 1.5-dp edge, so a near-black card still reads on the dark night map.
    public static let cardEdge = DashColor(argb: 0xFF26_2B32)
    public static let cardEdgeWidth: Double = 1.5
    public static let cardRadius: Double = 14
    /// Portrait nav banner (opaque, bottom corners only).
    public static let topBannerFill = DashColor(argb: 0xFF0B_0D10)
    /// Portrait metrics bar and lap card (top corners only).
    public static let bottomBarFill = DashColor(argb: 0xFF0B_0D10)

    // MARK: Text

    public static let primaryText = DashColor(argb: 0xFFFF_FFFF)
    /// Road name / instruction on the nav card.
    public static let roadText = DashColor(argb: 0xFF8A_B4F8)
    /// Lane arrows.
    public static let laneText = DashColor(argb: 0xFFFF_B74D)
    /// TIME / ARRIVE / LEFT / ALT labels.
    public static let metricLabel = DashColor(argb: 0xFF88_9098)
    /// Preview meta, arrive meta, gauge unit, Cancel/Done.
    public static let secondaryText = DashColor(argb: 0xFFB0_B8C0)
    /// Status line (normal) — also unselected route chip text and lap meta.
    public static let statusText = DashColor(argb: 0xFFC8_D0D8)
    /// Status line when off route > 80 m.
    public static let statusWarning = DashColor(argb: 0xFFFF_8A80)

    // MARK: Destructive action (the menu's "End route…" and the confirm card's End / Change; P0 D01)

    /// Red text for an action that ends or replaces the route (it only acts after a confirm).
    public static let endText = DashColor(argb: 0xFFFF_8A80)
    /// The confirm card's destructive button: red text on a dark red fill.
    public static let destructiveFill = DashColor(argb: 0xFF3A_1614)
    public static let destructiveStroke = DashColor(argb: 0xFF5C_2420)

    // MARK: Blue action (bg_go_button) — Go, Park here

    public static let blueAction = DashColor(argb: 0xFF1A_73E8)
    public static let blueActionRadius: Double = 24

    // MARK: Route chips (bg_route_chip / bg_route_chip_sel) — also "Find parking"

    public static let routeChipFill = DashColor(argb: 0x22FF_FFFF)
    public static let routeChipStroke = DashColor(argb: 0x33FF_FFFF)
    public static let routeChipSelectedFill = DashColor(argb: 0xFF1A_73E8)
    public static let routeChipSelectedStroke = DashColor(argb: 0xFF8A_B4F8)
    public static let routeChipRadius: Double = 18
    public static let routeChipText = DashColor(argb: 0xFFC8_D0D8)
    public static let routeChipSelectedText = DashColor(argb: 0xFFFF_FFFF)

    // MARK: FAB (bg_fab_circle)

    /// Opaque (P0): the map no longer shows through the buttons.
    public static let fabFill = DashColor(argb: 0xFF16_191E)
    public static let fabStroke = DashColor(argb: 0x33FF_FFFF)
    public static let fabIcon = DashColor(argb: 0xFFFF_FFFF)
    /// Compass FAB alpha in north-up mode.
    public static let compassNorthUpAlpha: Double = 0.55

    // MARK: Speed gauge (bg_speed_gauge) and limit sign (bg_speed_limit_sign)

    public static let gaugeFill = DashColor(argb: 0xFF0B_0D10)
    public static let gaugeStroke = DashColor(argb: 0x66FF_FFFF)
    public static let gaugeStrokeWidth: Double = 3
    public static let limitRed = DashColor(argb: 0xFFE5_3935)
    public static let limitInner = DashColor(argb: 0xFFFF_FFFF)
    public static let limitText = DashColor(argb: 0xFF11_1111)
    /// White inner disc inset of the 56-dp sign (40-dp variant: 4).
    public static let limitInset: Double = 5

    // MARK: Search pill (bg_search_pill) and search sheet — day (Android) / night (P0, D06)

    public static let searchPillRadius: Double = 28
    public static let poiChipRadius: Double = 18

    /// The colours of the search pill, the search sheet and its POI chips. Android draws them white by day
    /// and night; at night (P0, D06) they are dark: no white surface on the dash after dark.
    public struct SearchSurface: Sendable, Equatable {
        public var pillFill: DashColor
        public var pillText: DashColor
        public var pillIcon: DashColor
        /// "Circuit" / "Lap" labels and the "Type on the phone" status.
        public var pillAccent: DashColor
        public var sheetBackground: DashColor
        public var sheetInput: DashColor
        public var sheetHint: DashColor
        public var sheetStatus: DashColor
        public var sheetRow: DashColor
        public var sheetName: DashColor
        public var sheetSubtitle: DashColor
        public var sheetAction: DashColor
        public var sheetDelete: DashColor
        public var sheetDivider: DashColor
        public var poiChipFill: DashColor
        public var poiChipStroke: DashColor
        public var poiChipText: DashColor
    }

    public static let searchDay = SearchSurface(
        pillFill: DashColor(argb: 0xF2FF_FFFF), pillText: DashColor(argb: 0xFF3C_4043), pillIcon: DashColor(argb: 0xFF5F_6368),
        pillAccent: DashColor(argb: 0xFFE6_5100),
        sheetBackground: DashColor(argb: 0xF8FF_FFFF), sheetInput: DashColor(argb: 0xFF20_2124), sheetHint: DashColor(argb: 0xFF80_868B),
        sheetStatus: DashColor(argb: 0xFF5F_6368), sheetRow: DashColor(argb: 0xFFFF_FFFF), sheetName: DashColor(argb: 0xFF20_2124),
        sheetSubtitle: DashColor(argb: 0xFF5F_6368), sheetAction: DashColor(argb: 0xFF1A_73E8), sheetDelete: DashColor(argb: 0xFFD9_3025),
        sheetDivider: DashColor(argb: 0xFFDA_DCE0),
        poiChipFill: DashColor(argb: 0xFFF1_F3F4), poiChipStroke: DashColor(argb: 0xFFDA_DCE0), poiChipText: DashColor(argb: 0xFF3C_4043))

    /// Night: the card colours, dimmed whites (#E9ECEF), grey secondary text, light accents.
    public static let searchNight = SearchSurface(
        pillFill: DashColor(argb: 0xFF16_191E), pillText: DashColor(argb: 0xFFE9_ECEF), pillIcon: DashColor(argb: 0xFFA2_A9B2),
        pillAccent: DashColor(argb: 0xFFFF_B74D),
        sheetBackground: DashColor(argb: 0xFF0B_0D10), sheetInput: DashColor(argb: 0xFFE9_ECEF), sheetHint: DashColor(argb: 0xFF7C_848E),
        sheetStatus: DashColor(argb: 0xFFA2_A9B2), sheetRow: DashColor(argb: 0xFF16_191E), sheetName: DashColor(argb: 0xFFE9_ECEF),
        sheetSubtitle: DashColor(argb: 0xFFA2_A9B2), sheetAction: DashColor(argb: 0xFF8A_B4F8), sheetDelete: DashColor(argb: 0xFFFF_8A80),
        sheetDivider: DashColor(argb: 0xFF26_2B32),
        poiChipFill: DashColor(argb: 0xFF16_191E), poiChipStroke: DashColor(argb: 0xFF26_2B32), poiChipText: DashColor(argb: 0xFFE9_ECEF))

    public static func search(night: Bool) -> SearchSurface { night ? searchNight : searchDay }

    // MARK: Dimmer, menu, segments

    public static let dimmer = DashColor(argb: 0x6600_0000)
    public static let menuSheet = DashColor(argb: 0xF014_1A20)
    /// Selected segment (brand orange) / text.
    public static let segmentSelected = DashColor(argb: 0xFFFF_6A2C)
    public static let segmentSelectedText = DashColor(argb: 0xFFFF_FFFF)
    /// Unselected segment (surface_high) / text (text_primary).
    public static let segmentUnselected = DashColor(argb: 0xFF1F_242E)
    public static let segmentUnselectedText = DashColor(argb: 0xFFF2_F5FA)
    public static let segmentRadius: Double = 12
    /// Menu action buttons (iOS choice: dark tonal buttons; Android leaves the style to the platform).
    public static let menuButtonFill = DashColor(argb: 0xFF26_2D3A)
    public static let menuButtonStroke = DashColor(argb: 0x33FF_FFFF)
    public static let menuButtonText = DashColor(argb: 0xFFF2_F5FA)
    public static let menuButtonRadius: Double = 12

    // MARK: Preview action texts

    public static let previewSave = DashColor(argb: 0xFF90_CAF9)
    public static let previewHome = DashColor(argb: 0xFFFF_D54F)
    public static let previewMarker = DashColor(argb: 0xFFA5_D6A7)
    public static let previewCircuit = DashColor(argb: 0xFFFF_B74D)
    public static let previewCancel = DashColor(argb: 0xFFB0_B8C0)

    // MARK: Handlebar focus ring (P0, D09)

    /// Outline only, never a fill over the control — the music tile's outset ring (fix F3) for every control,
    /// in white: a 5-dp band just outside the control (0…5 dp, the footprint F3 validated against every
    /// neighbour and the safe-area edge on all canvases), black with a 3-dp white core — a 1-dp black edge on
    /// each side, so it reads on a light map and around a white pill. White is reserved for focus; orange no
    /// longer means focus.
    public static let focusStroke = DashColor(argb: 0xFFFF_FFFF)
    public static let focusEdge = DashColor(argb: 0xFF00_0000)
    public static let focusStrokeWidth: Double = 3
    public static let focusEdgeWidth: Double = 5
    /// Distance from the control's edge to the ring's centre line (dp): the ring covers 0…5 dp outside.
    public static let focusOutset: Double = 2.5
    public static let focusRadius: Double = 12

    // MARK: Map overlays (DashMapController.kt:57-102; P0 D05: cased lines, day / night colours)

    /// Remaining route: 10 dp over a 17-dp casing — blue on white by day, light blue on near-black at night —
    /// so it stands out from the muted map and from water and transit symbols (Android: 7 dp #1A73E8, no casing).
    public static func routeRemain(night: Bool) -> DashColor { DashColor(argb: night ? 0xFF4C_8DFF : 0xFF1A_66E0) }
    public static func routeCasing(night: Bool) -> DashColor { DashColor(argb: night ? 0xFF07_090B : 0xFFFF_FFFF) }
    public static let routeRemainWidth: Double = 10
    public static let routeCasingWidth: Double = 17
    /// Completed route: grey, 8 dp, no casing.
    public static func routeDone(night: Bool) -> DashColor { DashColor(argb: night ? 0xFF4A_5058 : 0xFF8C_929A) }
    public static let routeDoneWidth: Double = 8
    /// Selected preview route: green, 8 dp over a 13-dp casing.
    public static let routePreview = DashColor(argb: 0xFF34_A853)
    public static let routePreviewWidth: Double = 8
    public static let routePreviewCasingWidth: Double = 13
    /// Alternative preview routes (≤ 4, under the preview): grey, 7 dp over a 12-dp casing.
    public static func routeAlternative(night: Bool) -> DashColor { DashColor(argb: night ? 0xFF5A_626C : 0xFF8A_9099) }
    public static let routeAlternativeWidth: Double = 7
    public static let routeAlternativeCasingWidth: Double = 12
    /// Rider → destination straight line, 3.5 dp, dashed 8 on / 6 off.
    public static let routeToDestination = DashColor(argb: 0xFFFB_BC04)
    public static let routeToDestinationWidth: Double = 3.5
    public static let routeToDestinationDash: [Double] = [8, 6]
    /// Destination / saved-place pin (ic_dest_pin).
    public static let pinRed = DashColor(argb: 0xFFE5_3935)
    public static let pinInner = DashColor(argb: 0xFFFF_FFFF)
    /// Android puck (ic_nav_arrow): kept for the icon set; the dash map draws the P0 puck below.
    public static let puckShadow = DashColor(argb: 0x6600_0000)
    public static let puckBlue = DashColor(argb: 0xFF1A_73E8)
    public static let puckWhite = DashColor(argb: 0xFFFF_FFFF)
    /// The rider puck (P0, D05): a white chevron with a 3-dp dark outline over a halo disc — dark by day,
    /// white at night. Never route blue.
    public static let puckFill = DashColor(argb: 0xFFFF_FFFF)
    public static let puckEdge = DashColor(argb: 0xFF0B_0D10)
    public static let puckEdgeWidth: Double = 3
    public static func puckHalo(night: Bool) -> DashColor { DashColor(argb: night ? 0x29FF_FFFF : 0x2E0B_0D10) }
    /// The puck's box (dp): the halo's diameter.
    public static let puckSize: Double = 56

    // MARK: Apple Music (iOS addition): now-playing tile and Music sheet

    /// Opaque sheet background.
    public static let musicSheet = DashColor(argb: 0xFF12_171E)
    /// Artwork placeholder (no image yet / none) and its note icon.
    public static let musicPlaceholder = DashColor(argb: 0xFF26_3040)
    public static let musicPlaceholderIcon = DashColor(argb: 0xFF8A_96A8)
    public static let musicArtist = DashColor(argb: 0xFFE8_EEF5)
    /// Sheet progress bar: track / fill.
    public static let musicTrack = DashColor(argb: 0x40FF_FFFF)
    public static let musicFill = DashColor(argb: 0xFFFF_FFFF)
    /// Tile progress track (the fill is white).
    public static let musicTileBarTrack = DashColor(argb: 0x5900_0000)
    /// 1-dp outline of the tile and the ✕ button.
    public static let musicTileStroke = DashColor(argb: 0x33FF_FFFF)
    /// Paused tile: dim overlay + ❚❚ badge.
    public static let musicPausedDim = DashColor(argb: 0x7300_0000)
    public static let musicBadge = DashColor(argb: 0xCC00_0000)
    /// ✕ close button on the artwork.
    public static let musicClose = DashColor(argb: 0x9900_0000)
    /// Night: artwork dimmed (never inverted).
    public static let musicNightDim = DashColor(argb: 0x2600_0000)

    // MARK: Map credit (iOS addition): "© OpenStreetMap" on OSMF tiles (navigation-dash.md §10.4)

    /// Plate behind the credit: 75 % of the card colour, so the small text reads on day and night tiles.
    public static let attributionFill = DashColor(argb: 0xBF1A_2332)
    public static let attributionText = DashColor(argb: 0xFFE8_EEF5)
    /// Plate corner radius (dp).
    public static let attributionRadius: Double = 6

    // MARK: iOS additions (toast, link banner, clock, hold card)

    public static let toastFill = DashColor(argb: 0xF020_2124)
    public static let toastText = DashColor(argb: 0xFFFF_FFFF)
    public static let bannerFill = DashColor(argb: 0xF0FF_B020)
    public static let bannerText = DashColor(argb: 0xFF20_2124)
    /// The hold card's secondary lines (P0, D17: the card sits on the plain chrome colour, no map).
    public static let holdSecondary = DashColor(argb: 0xFFA2_A9B2)
}

/// Dash density (navigation-dash.md §11.1, input-controls.md §3.2): the Android VirtualDisplay
/// uses `dpi = clamp(round(160·W/900), 160, 640)` (Yunmo/Ride MO: fixed 187), so 1 dp = 1 px on
/// 800-wide dashes, 1.1375 px on 1024, 1.425 px on 1280.
public enum DashDensity {
    /// Logical dash width in dp targeted by Android (`TARGET_DASH_WIDTH_DP`).
    public static let targetWidthDp: Double = 900

    /// `Math.round(160·W/900)` clamped to 160…640, or `overrideDpi` (Yunmo 187) when given.
    public static func densityDpi(canvasWidth: Double, overrideDpi: Int? = nil) -> Int {
        if let o = overrideDpi { return o }
        let raw = (160.0 * canvasWidth / targetWidthDp)
        let rounded = Int((raw + 0.5).rounded(.down)) // Java Math.round = floor(x + 0.5)
        return min(640, max(160, rounded))
    }

    /// px per dp for a canvas width (1.0 for 544/720/800, 1.1375 for 1024, 1.425 for 1280).
    public static func scale(canvasWidth: Double, overrideDpi: Int? = nil) -> Double {
        Double(densityDpi(canvasWidth: canvasWidth, overrideDpi: overrideDpi)) / 160.0
    }
}
