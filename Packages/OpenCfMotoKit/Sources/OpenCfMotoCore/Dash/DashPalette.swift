// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) GpxDashUi.kt, DashMapController.kt, res/drawable/bg_*.xml,
// res/values/colors.xml, VideoPipeline.kt (density) — docs/spec/navigation-dash.md §11.1-§11.2.
//
// The dash chrome has ONE palette for day and night (night only inverts the map tiles, §10.3).

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

    /// 94 % #1A2332 — nav card (landscape), metrics card, preview, arrive.
    public static let cardFill = DashColor(argb: 0xF01A_2332)
    public static let cardRadius: Double = 14
    /// Portrait nav banner (opaque, bottom corners only).
    public static let topBannerFill = DashColor(argb: 0xFF1A_2332)
    /// Portrait metrics bar and lap card (top corners only).
    public static let bottomBarFill = DashColor(argb: 0xF01A_2332)

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

    // MARK: End pill (bg_end_pill)

    public static let endPillFill = DashColor(argb: 0x33FF_5A52)
    public static let endPillStroke = DashColor(argb: 0x55FF_5A52)
    public static let endText = DashColor(argb: 0xFFFF_8A80)
    public static let endPillRadius: Double = 12

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

    public static let fabFill = DashColor(argb: 0xF01E_2430)
    public static let fabStroke = DashColor(argb: 0x33FF_FFFF)
    public static let fabIcon = DashColor(argb: 0xFFFF_FFFF)
    /// Compass FAB alpha in north-up mode.
    public static let compassNorthUpAlpha: Double = 0.55

    // MARK: Speed gauge (bg_speed_gauge) and limit sign (bg_speed_limit_sign)

    public static let gaugeFill = DashColor(argb: 0xF01A_2332)
    public static let gaugeStroke = DashColor(argb: 0x66FF_FFFF)
    public static let gaugeStrokeWidth: Double = 3
    public static let limitRed = DashColor(argb: 0xFFE5_3935)
    public static let limitInner = DashColor(argb: 0xFFFF_FFFF)
    public static let limitText = DashColor(argb: 0xFF11_1111)
    /// White inner disc inset of the 56-dp sign (40-dp variant: 4).
    public static let limitInset: Double = 5

    // MARK: Search pill (bg_search_pill)

    public static let searchPillFill = DashColor(argb: 0xF2FF_FFFF)
    public static let searchPillRadius: Double = 28
    public static let searchPillText = DashColor(argb: 0xFF3C_4043)
    public static let searchPillIcon = DashColor(argb: 0xFF5F_6368)
    /// "Circuit" / "Lap" labels and the "Type on PHONE" status.
    public static let searchPillAccent = DashColor(argb: 0xFFE6_5100)

    // MARK: Search sheet

    public static let sheetBackground = DashColor(argb: 0xF8FF_FFFF)
    public static let sheetInput = DashColor(argb: 0xFF20_2124)
    public static let sheetHint = DashColor(argb: 0xFF80_868B)
    public static let sheetStatus = DashColor(argb: 0xFF5F_6368)
    public static let sheetRow = DashColor(argb: 0xFFFF_FFFF)
    public static let sheetName = DashColor(argb: 0xFF20_2124)
    public static let sheetSubtitle = DashColor(argb: 0xFF5F_6368)
    public static let sheetAction = DashColor(argb: 0xFF1A_73E8)
    public static let sheetDelete = DashColor(argb: 0xFFD9_3025)
    public static let sheetDivider = DashColor(argb: 0xFFDA_DCE0)

    // MARK: POI chip (bg_chip_pill)

    public static let poiChipFill = DashColor(argb: 0xFFF1_F3F4)
    public static let poiChipStroke = DashColor(argb: 0xFFDA_DCE0)
    public static let poiChipText = DashColor(argb: 0xFF3C_4043)
    public static let poiChipRadius: Double = 18

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

    // MARK: Handlebar focus ring

    public static let focusFill = DashColor(argb: 0x66FF_9800)
    public static let focusStroke = DashColor(argb: 0xFFFF_9800)
    public static let focusStrokeWidth: Double = 5
    public static let focusRadius: Double = 12

    // MARK: Map overlays (DashMapController.kt:57-102)

    /// Remaining route, 7 dp.
    public static let routeRemain = DashColor(argb: 0xFF1A_73E8)
    public static let routeRemainWidth: Double = 7
    /// Completed route, 5.5 dp, alpha 200/255.
    public static let routeDone = DashColor(argb: 0xC89A_A0A6)
    public static let routeDoneWidth: Double = 5.5
    /// Selected preview route, 6.5 dp, alpha 220/255.
    public static let routePreview = DashColor(argb: 0xDC34_A853)
    public static let routePreviewWidth: Double = 6.5
    /// Alternative preview routes (≤ 4, under the preview), 5 dp, alpha 160/255.
    public static let routeAlternative = DashColor(argb: 0xA09A_A0A6)
    public static let routeAlternativeWidth: Double = 5
    /// Rider → destination straight line, 3.5 dp, dashed 8 on / 6 off.
    public static let routeToDestination = DashColor(argb: 0xFFFB_BC04)
    public static let routeToDestinationWidth: Double = 3.5
    public static let routeToDestinationDash: [Double] = [8, 6]
    /// Destination / saved-place pin (ic_dest_pin).
    public static let pinRed = DashColor(argb: 0xFFE5_3935)
    public static let pinInner = DashColor(argb: 0xFFFF_FFFF)
    /// Puck (ic_nav_arrow).
    public static let puckShadow = DashColor(argb: 0x6600_0000)
    public static let puckBlue = DashColor(argb: 0xFF1A_73E8)
    public static let puckWhite = DashColor(argb: 0xFFFF_FFFF)

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

    // MARK: iOS additions (toast, link banner, clock, hold card)

    public static let toastFill = DashColor(argb: 0xF020_2124)
    public static let toastText = DashColor(argb: 0xFFFF_FFFF)
    public static let bannerFill = DashColor(argb: 0xF0FF_B020)
    public static let bannerText = DashColor(argb: 0xFF20_2124)
    public static let holdDimmer = DashColor(argb: 0xB300_0000)
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
