// SPDX-License-Identifier: AGPL-3.0-or-later
// Ported from OpenCfMoto (Android) res/layout-land/presentation_gpx.xml,
// res/layout/presentation_gpx.xml, include_gpx_dash_settings.xml and
// GpxDashUi.adaptChromeLayout (GpxDashUi.kt:2477-2771) — docs/spec/navigation-dash.md §11.3/§11.4.
//
// Deterministic rect computation for the landscape (W > H) and portrait canvases. All Android
// sizes are dp/sp; here they are multiplied by the density scale (1.0 on 800-wide dashes,
// 1.1375 on 1024, 1.425 on 1280). Wrap-content sizes come from the injected `DashTextMeasurer`
// (CoreText on iOS, `ApproximateTextMeasurer` on Linux), so cards fit their text exactly.
//
// iOS improvements over Android (documented in the spec as recommendations):
// - ScreenMargins are an unsafe area: chrome is laid out inside `safe` (Android ignores them).
// - The landscape metrics card never runs under the speed chip: it is compressed (gaps, minimum
//   widths, value font) and, on narrow canvases, the chip stacks above the card instead.
// - The portrait gauge sits under the measured nav banner (Android assumes a 100-dp banner).
// - The lap card sits above whatever bottom-left card is visible.

import Foundation

/// Dimension constants in dp (navigation-dash.md §11.3/§11.4, input-controls.md §6.3).
public enum DashDimens {
    public static let edge = 8.0
    /// Right lane kept free for the FAB column (landscape cards' marginEnd).
    public static let fabLane = 88.0
    public static let pillMarginStart = 12.0
    public static let pillMarginTop = 8.0
    public static let pillHeight = 48.0
    public static let pillPaddingStart = 4.0
    public static let pillPaddingEnd = 14.0
    public static let pillIcon = 20.0
    public static let pillIconGap = 8.0
    public static let pillTextWidth = 300.0
    public static let pillLabelHeight = 36.0
    public static let pillLabelPaddingX = 8.0
    public static let fabSize = 46.0
    public static let fabGap = 6.0
    public static let fabIcon = 24.0
    public static let fabMarginEndLandscape = 6.0
    public static let fabMarginEndPortrait = 8.0
    public static let fabCount = 5
    public static let maneuverIcon = 64.0
    public static let maneuverGap = 14.0
    public static let gaugeLandscape = 84.0
    public static let gaugePortrait = 96.0
    public static let limitSign = 56.0
    public static let limitGap = 12.0
    public static let menuWidth = 280.0
    public static let menuPadding = 12.0
    public static let menuButtonHeight = 48.0
    public static let segmentHeight = 44.0
    public static let goHeight = 44.0
    public static let goMinWidth = 110.0
    public static let previewActionsHeight = 40.0
    public static let searchHeaderHeight = 64.0
    // Apple Music (iOS addition): now-playing tile and Music sheet.
    public static let musicTile = 64.0, musicTileGap = 8.0, musicTileRadius = 10.0
    public static let musicSheetMargin = 16.0, musicSheetGap = 12.0, musicSheetTextMin = 300.0
    public static let musicArtMin = 96.0, musicArtRadius = 12.0, musicClose = 48.0
}

/// Text measurement + scale + safe area for one frame's layout.
public struct DashLayoutContext: Sendable {
    public var canvas: DashSize
    /// px per dp.
    public var scale: Double
    /// Canvas minus the screen margins.
    public var safe: DashRect
    public var measurer: any DashTextMeasurer

    public init(canvas: DashSize, margins: ScreenMargins = .zero, densityDpiOverride: Int? = nil,
                measurer: any DashTextMeasurer = ApproximateTextMeasurer()) {
        self.canvas = canvas
        self.scale = DashDensity.scale(canvasWidth: canvas.width, overrideDpi: densityDpiOverride)
        self.safe = DashModel.safeRect(canvas: canvas, margins: margins)
        self.measurer = measurer
    }

    public init(model: DashModel, measurer: any DashTextMeasurer) {
        self.init(canvas: model.canvas, margins: model.margins, densityDpiOverride: model.densityDpiOverride, measurer: measurer)
    }

    public var isLandscape: Bool { canvas.width > canvas.height }
    public func dp(_ v: Double) -> Double { v * scale }
    public func font(_ sp: Double, _ weight: DashFontWeight = .regular, digits: Bool = false) -> DashFont {
        DashFont(size: sp * scale, weight: weight, monospacedDigits: digits)
    }
    public func width(_ text: String, _ font: DashFont, letterSpacingEm: Double = 0) -> Double {
        DashTextLayout.width(text, font: font, letterSpacingEm: letterSpacingEm, measurer: measurer)
    }
    public func lineHeight(_ font: DashFont) -> Double { DashTextLayout.lineHeight(font: font, measurer: measurer) }
    func truncate(_ text: String, _ maxWidth: Double, _ font: DashFont, letterSpacingEm: Double = 0) -> String {
        DashTextLayout.truncate(text, maxWidth: maxWidth, font: font, letterSpacingEm: letterSpacingEm, measurer: measurer)
    }
}

// MARK: - Layout results

public struct DashSearchPillLayout: Sendable, Equatable {
    public var frame: DashRect
    public var iconRect: DashRect
    public var textRect: DashRect
    public var textFont: DashFont
    public var circuitRect: DashRect
    public var lapRect: DashRect
    public var labelFont: DashFont
}

public struct DashNavCardLayout: Sendable, Equatable {
    public var frame: DashRect
    /// Portrait full-width top banner (top-edge shape) vs landscape card.
    public var isBanner: Bool
    public var iconRect: DashRect
    public var distanceRect: DashRect
    public var distanceFont: DashFont
    public var distanceText: String
    public var roadRect: DashRect
    public var roadFont: DashFont
    public var roadLineCount: Int
    public var lanesRect: DashRect?
    public var lanesFont: DashFont
    public var lanesText: String?
}

public struct DashMetricColumnLayout: Sendable, Equatable {
    public var label: String
    public var value: String
    public var labelRect: DashRect
    public var valueRect: DashRect
    public var labelFont: DashFont
    public var valueFont: DashFont
}

public struct DashMetricsLayout: Sendable, Equatable {
    public var frame: DashRect
    /// Portrait full-width bottom bar (top corners only) vs landscape card.
    public var isBar: Bool
    public var columns: [DashMetricColumnLayout]
    public var endRect: DashRect
    public var endFont: DashFont
    /// Portrait status line (hidden in landscape).
    public var statusRect: DashRect?
    public var statusFont: DashFont
}

public struct DashSpeedChipLayout: Sendable, Equatable {
    public var frame: DashRect
    public var gaugeRect: DashRect
    public var speedFont: DashFont
    public var unitFont: DashFont
    public var limitRect: DashRect?
    public var limitFont: DashFont
}

public struct DashPreviewActionLayout: Sendable, Equatable {
    public var id: String
    public var label: String
    public var color: DashColor
    public var rect: DashRect
}

public struct DashPreviewCardLayout: Sendable, Equatable {
    public var frame: DashRect
    public var nameRect: DashRect
    public var nameFont: DashFont
    public var metaRect: DashRect
    public var metaFont: DashFont
    public var goRect: DashRect?
    public var goFont: DashFont
    /// Visible window of the horizontally scrollable route chips (nil = no chips row).
    public var chipsViewport: DashRect?
    /// Chip rects on screen (already offset by the scroll position; clip to `chipsViewport`).
    public var chipRects: [DashRect]
    public var chipLabels: [String]
    public var chipFont: DashFont
    public var chipsContentWidth: Double
    public var actions: [DashPreviewActionLayout]
    public var actionFont: DashFont
}

public struct DashArriveCardLayout: Sendable, Equatable {
    public var frame: DashRect
    public var titleRect: DashRect
    public var titleFont: DashFont
    public var metaRect: DashRect
    public var metaFont: DashFont
    public var parkRect: DashRect
    public var findRect: DashRect
    public var doneRect: DashRect
    public var buttonFont: DashFont
    public var doneFont: DashFont
}

public struct DashLapCardLayout: Sendable, Equatable {
    public var frame: DashRect
    public var titleRect: DashRect
    public var titleFont: DashFont
    public var metaRect: DashRect
    public var metaFont: DashFont
}

public struct DashMenuItem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Section title (Ride / Map / Settings).
        case title(String)
        /// Full-width (or half-width zoom) action button.
        case button(id: String, label: String, destructive: Bool, fontSp: Double)
        /// Setting label above a segmented row.
        case label(String)
        /// One segment of a segmented row.
        case segment(id: String, label: String, selected: Bool)
    }
    public var kind: Kind
    /// Rect in content coordinates: x on screen, y from the top of the scroll content.
    public var rect: DashRect
    public var id: String? {
        switch kind {
        case let .button(id, _, _, _), let .segment(id, _, _): return id
        default: return nil
        }
    }
}

public struct DashMenuLayout: Sendable, Equatable {
    /// The panel (right side, full safe height).
    public var panel: DashRect
    public var items: [DashMenuItem]
    public var contentHeight: Double
    public var maxScroll: Double { max(0, contentHeight - panel.height) }
}

/// What the menu shows (labels depend on UI + model state).
public struct DashMenuContent: Sendable, Equatable {
    public var language: DashLanguage
    public var follow: Bool
    public var headingUp: Bool
    public var recording: Bool
    public var preferences: MapPreferences
    /// The Ride section ends with "Music" (Apple Music now playing; iOS addition).
    public var showsMusic: Bool
    public init(language: DashLanguage, follow: Bool, headingUp: Bool, recording: Bool, preferences: MapPreferences,
                showsMusic: Bool = false) {
        self.language = language; self.follow = follow; self.headingUp = headingUp; self.recording = recording
        self.preferences = preferences; self.showsMusic = showsMusic
    }
}

/// The now-playing tile at the bottom of the FAB lane (Apple Music; iOS addition). No text.
public struct DashMusicTileLayout: Sendable, Equatable {
    public var frame: DashRect
    /// 10 dp.
    public var cornerRadius: Double
    /// The whole progress track: inset 6 dp left / right / bottom, 3 dp tall.
    public var progressRect: DashRect
    /// The paused badge: 20 dp, top-right corner inset 4 dp.
    public var badgeRect: DashRect
    /// Landscape: the clock chip gives way to the tile (no room for both under the FABs).
    public var hidesClock: Bool
}

/// How the Music sheet places the artwork and the text / controls block.
public enum DashMusicSheetArrangement: String, Sendable, Equatable {
    /// Artwork square on the right, text column on the left.
    case sideBySide
    /// Artwork centred at the top, block below.
    case stacked
    /// No room for a ≥ 96-dp artwork: block only (unreachable on the supported canvases).
    case textOnly
}

/// The Music sheet (Apple Music; iOS addition): artwork + title / artist / album / progress /
/// times / ⏮ ⏯ ⏭, ✕ on the artwork's corner. Rects in canvas px.
public struct DashMusicSheetLayout: Sendable, Equatable {
    public var arrangement: DashMusicSheetArrangement
    /// The whole canvas.
    public var sheet: DashRect
    /// `.zero` for `.textOnly`.
    public var artworkRect: DashRect
    /// 12 dp.
    public var artworkRadius: Double
    public var closeRect: DashRect
    public var titleRect: DashRect
    public var titleFont: DashFont
    public var titleMaxLines: Int
    /// nil: no artist line (empty artist or compressed away).
    public var artistRect: DashRect?
    public var artistFont: DashFont
    /// nil: no album line (empty album or compressed away).
    public var albumRect: DashRect?
    public var albumFont: DashFont
    /// nil: unknown duration (radio, live).
    public var progressRect: DashRect?
    /// Left / right halves of the times row (nil: unknown duration or compressed away).
    public var elapsedRect: DashRect?
    public var remainingRect: DashRect?
    public var timeFont: DashFont
    public var previousRect: DashRect
    public var playPauseRect: DashRect
    public var nextRect: DashRect
    /// 0 full · 1 no album · 2 title 1 line · 3 compact transport · 4 no artist · 5 no times.
    public var compressionStep: Int
}

public struct DashSearchRowLayout: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case typeOnPhone
        /// `resultIndex` = index in `DashSearchState.results` (nil for idle-list rows).
        case place(Place, resultIndex: Int?)
    }
    public var id: String
    public var kind: Kind
    /// Content coordinates (y from the top of the list content).
    public var rect: DashRect
    public var nameRect: DashRect
    public var subtitleRect: DashRect?
    public var subtitle: String
    public var actions: [DashPreviewActionLayout]
}

public struct DashSearchLayout: Sendable, Equatable {
    public var sheet: DashRect
    public var backRect: DashRect
    public var inputRect: DashRect
    public var inputTextRect: DashRect
    public var goRect: DashRect
    public var chipsViewport: DashRect
    /// Chip rects on screen (offset by the chip scroll position).
    public var chipRects: [DashRect]
    public var chipLabels: [String]
    public var chipsContentWidth: Double
    public var statusRect: DashRect
    public var statusText: String
    public var statusAccent: Bool
    public var listViewport: DashRect
    public var rows: [DashSearchRowLayout]
    public var listContentHeight: Double
    public var maxListScroll: Double { max(0, listContentHeight - listViewport.height) }
    // fonts
    public var backFont: DashFont
    public var inputFont: DashFont
    public var chipFont: DashFont
    public var statusFont: DashFont
    public var nameFont: DashFont
    public var subtitleFont: DashFont
    public var actionFont: DashFont
    public var typeOnPhoneFont: DashFont
}

// MARK: - Layout functions

public enum DashLayout {
    /// Letter spacing of the lanes line (em).
    public static let laneLetterSpacingEm = 0.12

    // MARK: FAB column

    /// Recenter, Zoom in, Zoom out, Compass, Menu. Landscape: top-right (margin 6, top 8);
    /// portrait: right margin 8, vertically centred.
    public static func fabColumn(_ c: DashLayoutContext) -> [DashRect] {
        let size = c.dp(DashDimens.fabSize), gap = c.dp(DashDimens.fabGap)
        let n = DashDimens.fabCount
        let total = Double(n) * size + Double(n - 1) * gap
        let x: Double, y0: Double
        if c.isLandscape {
            x = c.safe.maxX - c.dp(DashDimens.fabMarginEndLandscape) - size
            y0 = c.safe.minY + c.dp(DashDimens.edge)
        } else {
            x = c.safe.maxX - c.dp(DashDimens.fabMarginEndPortrait) - size
            y0 = c.safe.minY + (c.safe.height - total) / 2
        }
        return (0 ..< n).map { DashRect(x: x, y: y0 + Double($0) * (size + gap), width: size, height: size) }
    }

    // MARK: Search pill

    /// Top-left pill: x = 12, y = 8, h 48: icon 20 + 8 + text field 300 + "Circuit" + "Lap"
    /// labels (14 sp bold, h 36, padding 8) + 14 end padding. Shrinks the text field so the pill
    /// never enters the FAB lane (landscape) / right margin (portrait).
    public static func searchPill(_ c: DashLayoutContext, circuitLabel: String, lapLabel: String) -> DashSearchPillLayout {
        let x = c.safe.minX + c.dp(DashDimens.pillMarginStart)
        let y = c.safe.minY + c.dp(DashDimens.pillMarginTop)
        let h = c.dp(DashDimens.pillHeight)
        let labelFont = c.font(14, .bold)
        let textFont = c.font(16)
        let circuitW = c.width(circuitLabel, labelFont) + 2 * c.dp(DashDimens.pillLabelPaddingX)
        let lapW = c.width(lapLabel, labelFont) + 2 * c.dp(DashDimens.pillLabelPaddingX)
        var textW = c.dp(DashDimens.pillTextWidth)
        let fixed = c.dp(DashDimens.pillPaddingStart + DashDimens.pillIcon + DashDimens.pillIconGap + DashDimens.pillPaddingEnd)
            + circuitW + lapW
        let maxRight = c.isLandscape ? c.safe.maxX - c.dp(DashDimens.fabLane) : c.safe.maxX - c.dp(DashDimens.pillMarginStart)
        let maxW = maxRight - x
        if fixed + textW > maxW { textW = max(c.dp(60), maxW - fixed) }
        let w = fixed + textW
        let frame = DashRect(x: x, y: y, width: w, height: h)
        let icon = DashRect(x: x + c.dp(DashDimens.pillPaddingStart), y: y + (h - c.dp(DashDimens.pillIcon)) / 2,
                            width: c.dp(DashDimens.pillIcon), height: c.dp(DashDimens.pillIcon))
        let text = DashRect(x: icon.maxX + c.dp(DashDimens.pillIconGap), y: y, width: textW, height: h)
        let lh = c.dp(DashDimens.pillLabelHeight)
        let circuit = DashRect(x: text.maxX, y: y + (h - lh) / 2, width: circuitW, height: lh)
        let lap = DashRect(x: circuit.maxX, y: circuit.minY, width: lapW, height: lh)
        return DashSearchPillLayout(frame: frame, iconRect: icon, textRect: text, textFont: textFont,
                                    circuitRect: circuit, lapRect: lap, labelFont: labelFont)
    }

    // MARK: Nav card / banner

    /// Landscape: top-left card (x 8, y 8, max right W − 88), padding L18 T14 R22 B14, icon
    /// 64×64 + 14 + column [distance 30 sp bold / road 18 sp bold ≤ 2 lines, max width
    /// 24 × line height (maxEms) / lanes 16 sp bold, letter-spacing 0.12, top 4].
    /// Portrait: full-width top banner, padding L16 T10 R16 B12 (+ margins), content centred,
    /// distance 32 sp, road 20 sp (maxEms 20), lanes 18 sp (top 2).
    public static func navCard(_ c: DashLayoutContext, cue: HudCue) -> DashNavCardLayout {
        let land = c.isLandscape
        let distFont = c.font(land ? 30 : 32, .bold)
        let roadFont = c.font(land ? 18 : 20, .bold)
        let lanesFont = c.font(land ? 16 : 18, .bold)
        let icon = c.dp(DashDimens.maneuverIcon), gap = c.dp(DashDimens.maneuverGap)
        let roadTop = land ? c.dp(2) : 0
        let lanesTop = land ? c.dp(4) : c.dp(2)
        let maxEms = land ? 24.0 : 20.0
        let padL: Double, padT: Double, padR: Double, padB: Double
        let x: Double, y: Double, maxW: Double
        if land {
            padL = c.dp(18); padT = c.dp(14); padR = c.dp(22); padB = c.dp(14)
            x = c.safe.minX + c.dp(DashDimens.edge)
            y = c.safe.minY + c.dp(DashDimens.edge)
            maxW = c.safe.maxX - c.dp(DashDimens.fabLane) - x
        } else {
            padL = c.dp(16) + c.safe.minX; padT = c.dp(10) + c.safe.minY
            padR = c.dp(16) + (c.canvas.width - c.safe.maxX); padB = c.dp(12)
            x = 0; y = 0
            maxW = c.canvas.width
        }
        let colMax = max(c.dp(40), min(maxEms * c.lineHeight(roadFont), maxW - padL - padR - icon - gap))
        let distText = c.truncate(cue.distanceText, colMax, distFont)
        let distW = c.width(distText, distFont)
        let roadLines = DashTextLayout.wrap(cue.text, maxWidth: colMax, font: roadFont, maxLines: 2, measurer: c.measurer)
        let roadW = roadLines.map { c.width($0, roadFont) }.max() ?? 0
        let lanes = cue.lanes.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let lanesText = lanes.map { c.truncate($0, colMax, lanesFont, letterSpacingEm: laneLetterSpacingEm) }
        let lanesW = lanesText.map { c.width($0, lanesFont, letterSpacingEm: laneLetterSpacingEm) } ?? 0
        let colW = min(colMax, max(distW, roadW, lanesW))
        let distH = c.lineHeight(distFont)
        let roadH = Double(max(1, roadLines.count)) * c.lineHeight(roadFont)
        let lanesH = lanesText == nil ? 0 : c.lineHeight(lanesFont)
        let colH = distH + roadTop + roadH + (lanesText == nil ? 0 : lanesTop + lanesH)
        let contentH = max(icon, colH)
        let frame: DashRect
        let rowX: Double
        if land {
            frame = DashRect(x: x, y: y, width: padL + icon + gap + colW + padR, height: padT + contentH + padB)
            rowX = x + padL
        } else {
            frame = DashRect(x: 0, y: 0, width: c.canvas.width, height: padT + contentH + padB)
            let rowW = icon + gap + colW
            let innerX = padL, innerW = c.canvas.width - padL - padR
            rowX = innerX + max(0, (innerW - rowW) / 2)
        }
        let top = frame.minY + padT
        let iconRect = DashRect(x: rowX, y: top + (contentH - icon) / 2, width: icon, height: icon)
        let colX = iconRect.maxX + gap
        let colY = top + (contentH - colH) / 2
        let distRect = DashRect(x: colX, y: colY, width: colW, height: distH)
        let roadRect = DashRect(x: colX, y: distRect.maxY + roadTop, width: colW, height: roadH)
        let lanesRect = lanesText == nil ? nil : DashRect(x: colX, y: roadRect.maxY + lanesTop, width: colW, height: lanesH)
        return DashNavCardLayout(frame: frame, isBanner: !land, iconRect: iconRect, distanceRect: distRect,
                                 distanceFont: distFont, distanceText: distText, roadRect: roadRect, roadFont: roadFont,
                                 roadLineCount: max(1, roadLines.count), lanesRect: lanesRect, lanesFont: lanesFont,
                                 lanesText: lanesText)
    }

    // MARK: Metrics card / bar

    /// Reference values used to decide (per canvas / language) whether the landscape speed chip
    /// must stack above the metrics card.
    static let referenceValues = ["0h00m", "00:00", "000.0 km", "0000"]

    /// Landscape: bottom-left card (x 8, bottom H − 8), padding L22 T14 R22 B14, columns TIME
    /// (26 sp, min 80, gap 20), ARRIVE (26, 80, 20), LEFT (30, 90, 20), ALT (26, 80, 24), labels
    /// 13 sp, value top 4, then End (margin 8, padding-x 22, min h 48, 17 sp bold). Compressed to
    /// end at `maxRight`. Portrait: full-width bottom bar, 4 weighted columns (1, 1, 1.2, 1),
    /// labels 11 sp, values 22 sp (LEFT 24), row 2: status (13 sp) + End (h 40, 15 sp).
    /// - Parameter landscapeStatus: landscape only — a status row (14 sp, top 2) under the
    ///   columns. Android hides the landscape status line; the controller passes the status here
    ///   only for the off-route warning (> 80 m) so landscape riders see it too (iOS addition).
    public static func metricsCard(_ c: DashLayoutContext, labels: [String], values: [String], endLabel: String,
                                   maxRight: Double? = nil, landscapeStatus: String? = nil) -> DashMetricsLayout {
        precondition(labels.count == 4 && values.count == 4, "TIME, ARRIVE, LEFT, ALT")
        return c.isLandscape
            ? landscapeMetrics(c, labels: labels, values: values, endLabel: endLabel,
                               maxRight: maxRight ?? c.safe.maxX - c.dp(DashDimens.fabLane), status: landscapeStatus)
            : portraitMetrics(c, labels: labels, values: values, endLabel: endLabel)
    }

    /// Natural (uncompressed) and minimal (gaps 8, min widths dropped) landscape widths.
    static func landscapeMetricsWidths(_ c: DashLayoutContext, labels: [String], values: [String],
                                       endLabel: String) -> (natural: Double, minimal: Double) {
        let labelFont = c.font(13)
        let valueSp: [Double] = [26, 26, 30, 26]
        let minW: [Double] = [80, 80, 90, 80]
        let gaps: [Double] = [20, 20, 20, 24]
        var natural = 0.0, minimal = 0.0
        for i in 0 ..< 4 {
            let content = max(c.width(labels[i], labelFont), c.width(values[i], c.font(valueSp[i], .bold)))
            natural += max(c.dp(minW[i]), content) + c.dp(gaps[i])
            minimal += content + c.dp(8)
        }
        let end = c.dp(8) + 2 * c.dp(22) + c.width(endLabel, c.font(17, .bold)) + 2 * c.dp(22)
        return (natural + end, minimal + end)
    }

    /// Whether the landscape speed chip (with a limit sign) cannot sit beside the metrics card on
    /// this canvas even when the card is compressed — then the chip stacks above the card.
    public static func speedChipStacksAboveMetrics(_ c: DashLayoutContext, labels: [String], endLabel: String) -> Bool {
        guard c.isLandscape else { return false }
        let x = c.safe.minX + c.dp(DashDimens.edge)
        let chipLeft = c.safe.maxX - c.dp(DashDimens.fabLane)
            - c.dp(DashDimens.gaugeLandscape + DashDimens.limitGap + DashDimens.limitSign)
        let available = chipLeft - c.dp(DashDimens.edge) - x
        return landscapeMetricsWidths(c, labels: labels, values: referenceValues, endLabel: endLabel).minimal > available
    }

    private static func landscapeMetrics(_ c: DashLayoutContext, labels: [String], values: [String], endLabel: String,
                                         maxRight: Double, status: String?) -> DashMetricsLayout {
        let x = c.safe.minX + c.dp(DashDimens.edge)
        let bottom = c.safe.maxY - c.dp(DashDimens.edge)
        let padL = c.dp(22), padR = c.dp(22), padT = c.dp(14), padB = c.dp(14)
        let labelFont = c.font(13)
        let baseValueSp: [Double] = [26, 26, 30, 26]
        let minW: [Double] = [80, 80, 90, 80].map { c.dp($0) }
        let naturalGaps: [Double] = [20, 20, 20, 24].map { c.dp($0) }
        let endFont = c.font(17, .bold)
        let endW = 2 * c.dp(22) + c.width(endLabel, endFont)
        let endGap = c.dp(8)
        let maxW = max(c.dp(120), maxRight - x)

        func columnWidths(valueScale: Double, useMin: Bool) -> [Double] {
            (0 ..< 4).map { i in
                let content = max(c.width(labels[i], labelFont), c.width(values[i], c.font(baseValueSp[i] * valueScale, .bold)))
                return useMin ? max(minW[i], content) : content
            }
        }
        func total(_ cols: [Double], _ gaps: [Double]) -> Double {
            padL + cols.reduce(0, +) + gaps.reduce(0, +) + endGap + endW + padR
        }
        var valueScale = 1.0
        var gaps = naturalGaps
        var cols = columnWidths(valueScale: 1, useMin: true)
        if total(cols, gaps) > maxW {
            // 1. shrink the gaps (down to 8 dp)
            let excess = total(cols, gaps) - maxW
            let room = gaps.map { $0 - c.dp(8) }.reduce(0, +)
            let f = room > 0 ? max(0, 1 - excess / room) : 0
            gaps = gaps.map { c.dp(8) + ($0 - c.dp(8)) * f }
        }
        if total(cols, gaps) > maxW {
            // 2. drop the minimum widths
            cols = columnWidths(valueScale: 1, useMin: false)
        }
        if total(cols, gaps) > maxW {
            // 3. scale the value fonts down (to 75 %)
            var s = 1.0
            while s > 0.75, total(columnWidths(valueScale: s, useMin: false), gaps) > maxW { s -= 0.05 }
            valueScale = max(0.75, s)
            cols = columnWidths(valueScale: valueScale, useMin: false)
        }
        if total(cols, gaps) > maxW {
            // 4. last resort: share the remaining width proportionally (values get ellipsised)
            let avail = max(c.dp(40), maxW - (padL + gaps.reduce(0, +) + endGap + endW + padR))
            let sum = cols.reduce(0, +)
            cols = cols.map { $0 * avail / sum }
        }
        let valueFonts = baseValueSp.map { c.font($0 * valueScale, .bold) }
        let labelH = c.lineHeight(labelFont)
        let colH = valueFonts.map { labelH + c.dp(4) + c.lineHeight($0) }
        let endH = max(c.dp(48), c.lineHeight(endFont))
        let rowH = max(colH.max() ?? 0, endH)
        let statusFont = c.font(14)
        let hasStatus = !(status ?? "").isEmpty
        let statusH = hasStatus ? c.dp(2) + c.lineHeight(statusFont) : 0
        let h = padT + rowH + statusH + padB
        let w = total(cols, gaps)
        let frame = DashRect(x: x, y: bottom - h, width: w, height: h)
        let rowTop = frame.minY + padT
        var cx = frame.minX + padL
        var columns: [DashMetricColumnLayout] = []
        for i in 0 ..< 4 {
            let top = rowTop + (rowH - colH[i]) / 2
            let value = c.truncate(values[i], cols[i], valueFonts[i])
            let label = c.truncate(labels[i], cols[i], labelFont)
            columns.append(DashMetricColumnLayout(
                label: label, value: value,
                labelRect: DashRect(x: cx, y: top, width: cols[i], height: labelH),
                valueRect: DashRect(x: cx, y: top + labelH + c.dp(4), width: cols[i], height: c.lineHeight(valueFonts[i])),
                labelFont: labelFont, valueFont: valueFonts[i]))
            cx += cols[i] + gaps[i]
        }
        let endRect = DashRect(x: cx + endGap, y: rowTop + (rowH - endH) / 2, width: endW, height: endH)
        let statusRect = hasStatus
            ? DashRect(x: frame.minX + padL, y: rowTop + rowH + c.dp(2), width: w - padL - padR, height: c.lineHeight(statusFont))
            : nil
        return DashMetricsLayout(frame: frame, isBar: false, columns: columns, endRect: endRect, endFont: endFont,
                                 statusRect: statusRect, statusFont: statusFont)
    }

    private static func portraitMetrics(_ c: DashLayoutContext, labels: [String], values: [String], endLabel: String) -> DashMetricsLayout {
        let padL = c.dp(12) + c.safe.minX, padR = c.dp(12) + (c.canvas.width - c.safe.maxX)
        let padT = c.dp(10), padB = c.dp(10)
        let labelFont = c.font(11)
        let valueFonts = [c.font(22, .bold), c.font(22, .bold), c.font(24, .bold), c.font(22, .bold)]
        let weights = [1.0, 1.0, 1.2, 1.0]
        let innerW = c.canvas.width - padL - padR
        let labelH = c.lineHeight(labelFont)
        let row1H = (0 ..< 4).map { labelH + c.lineHeight(valueFonts[$0]) }.max() ?? 0
        let statusFont = c.font(13)
        let endFont = c.font(15, .bold)
        let endH = c.dp(40)
        let row2H = max(c.lineHeight(statusFont), endH)
        let h = padT + row1H + c.dp(6) + row2H + padB
        let bottom = c.safe.maxY
        let frame = DashRect(x: 0, y: bottom - h, width: c.canvas.width, height: h)
        var cx = padL
        var columns: [DashMetricColumnLayout] = []
        for i in 0 ..< 4 {
            let w = innerW * weights[i] / weights.reduce(0, +)
            let colH = labelH + c.lineHeight(valueFonts[i])
            let top = frame.minY + padT + (row1H - colH) / 2
            columns.append(DashMetricColumnLayout(
                label: c.truncate(labels[i], w, labelFont), value: c.truncate(values[i], w, valueFonts[i]),
                labelRect: DashRect(x: cx, y: top, width: w, height: labelH),
                valueRect: DashRect(x: cx, y: top + labelH, width: w, height: c.lineHeight(valueFonts[i])),
                labelFont: labelFont, valueFont: valueFonts[i]))
            cx += w
        }
        let row2Top = frame.minY + padT + row1H + c.dp(6)
        let endW = 2 * c.dp(16) + c.width(endLabel, endFont)
        let endRect = DashRect(x: c.canvas.width - padR - endW, y: row2Top + (row2H - endH) / 2, width: endW, height: endH)
        let statusRect = DashRect(x: padL, y: row2Top, width: max(0, endRect.minX - c.dp(8) - padL), height: row2H)
        return DashMetricsLayout(frame: frame, isBar: true, columns: columns, endRect: endRect, endFont: endFont,
                                 statusRect: statusRect, statusFont: statusFont)
    }

    // MARK: Speed chip

    /// Landscape: gauge 84 (+ 12 + limit 56 to its right), right edge W − 88, bottom H − 8.
    /// Portrait: gauge 96; navigating → top-right under the banner (`belowY`), else bottom-left
    /// (x 12, bottom H − 12). `stackAboveY` (iOS): bottom-anchored chips sit 8 above that y
    /// instead (narrow landscape canvases: above the metrics card; above a preview/arrive card
    /// that would otherwise cover the gauge).
    public static func speedChip(_ c: DashLayoutContext, hasLimit: Bool, navigating: Bool,
                                 belowY: Double? = nil, stackAboveY: Double? = nil) -> DashSpeedChipLayout {
        let land = c.isLandscape
        let g = c.dp(land ? DashDimens.gaugeLandscape : DashDimens.gaugePortrait)
        let lim = c.dp(DashDimens.limitSign), gap = c.dp(DashDimens.limitGap)
        let w = hasLimit ? g + gap + lim : g
        let x: Double, y: Double
        if land {
            x = c.safe.maxX - c.dp(DashDimens.fabLane) - w
            let bottom = stackAboveY.map { $0 - c.dp(DashDimens.edge) } ?? c.safe.maxY - c.dp(DashDimens.edge)
            y = bottom - g
        } else if navigating {
            x = c.safe.maxX - c.dp(8) - w
            y = (belowY ?? c.safe.minY + c.dp(100)) + c.dp(8)
        } else {
            x = c.safe.minX + c.dp(12)
            let bottom = stackAboveY.map { $0 - c.dp(DashDimens.edge) } ?? c.safe.maxY - c.dp(12)
            y = bottom - g
        }
        let gauge = DashRect(x: x, y: y, width: g, height: g)
        let limitRect = hasLimit ? DashRect(x: gauge.maxX + gap, y: gauge.midY - lim / 2, width: lim, height: lim) : nil
        return DashSpeedChipLayout(frame: DashRect(x: x, y: y, width: w, height: g), gaugeRect: gauge,
                                   speedFont: c.font(land ? 32 : 36, .bold, digits: true),
                                   unitFont: c.font(land ? 11 : 12, .bold),
                                   limitRect: limitRect, limitFont: c.font(20, .bold, digits: true))
    }

    // MARK: Preview card

    /// Selected chips carry a "★ " prefix (unless the nav engine already added it).
    public static func chipDisplayLabel(_ label: String, selected: Bool) -> String {
        guard selected else { return label }
        return label.hasPrefix("★") ? label : "★ " + label
    }

    /// Landscape: bottom-left (x 10, bottom H − 10, max right W − 96), padding 16×12; row 1 =
    /// name (17 sp bold) / meta (13 sp) max width 280 + Go (h 44, min w 110, margin 16); row 2
    /// (top 8) = route chips (13 sp bold, padding 28×14, gap 16, horizontally scrollable);
    /// row 3 (top 8, h 40) = text actions (14 sp bold, padding-x 12).
    /// Portrait: full width (10…W − 10), actions row ends with Cancel/Done + Go.
    public static func previewCard(_ c: DashLayoutContext, preview: RoutePreview, language: DashLanguage,
                                   chipScroll: Double = 0) -> DashPreviewCardLayout {
        let land = c.isLandscape
        let pad = c.dp(16), padV = c.dp(12)
        let x = c.safe.minX + c.dp(10)
        let bottom = c.safe.maxY - c.dp(10)
        let maxRight = land ? c.safe.maxX - c.dp(96) : c.safe.maxX - c.dp(10)
        let availInner = max(c.dp(120), maxRight - x - 2 * pad)
        let nameFont = c.font(17, .bold), metaFont = c.font(13), goFont = c.font(16, .bold)
        let chipFont = c.font(13, .bold), actionFont = c.font(14, .bold)
        let showGo = !preview.pinMode
        let goW = max(c.dp(DashDimens.goMinWidth), 2 * c.dp(20) + c.width(DashText.go.localized(language), goFont))
        let goH = c.dp(DashDimens.goHeight)

        // Actions row
        var actionSpecs: [(String, String, DashColor)] = [("preview.save", DashText.save.localized(language), DashPalette.previewSave)]
        if preview.pinMode {
            actionSpecs.append(("preview.home", DashText.home.localized(language), DashPalette.previewHome))
            actionSpecs.append(("preview.marker", DashText.marker.localized(language), DashPalette.previewMarker))
        } else {
            actionSpecs.append(("preview.circuit", DashText.circuit.localized(language), DashPalette.previewCircuit))
        }
        let cancelLabel = (preview.pinMode ? DashText.done : DashText.cancel).localized(language)
        actionSpecs.append(("preview.cancel", cancelLabel, DashPalette.previewCancel))
        let actionPadX = c.dp(12)
        let actionWidths = actionSpecs.map { 2 * actionPadX + c.width($0.1, actionFont) }
        let actionsH = land ? c.dp(DashDimens.previewActionsHeight) : max(c.dp(DashDimens.previewActionsHeight), goH)
        var actionsNaturalW = actionWidths.reduce(0, +)
        if !land && showGo { actionsNaturalW += c.dp(4) + goW }

        // Chips row
        let showChips = !preview.pinMode && !preview.chipLabels.isEmpty
        let chipPadX = c.dp(28), chipPadY = c.dp(14), chipGap = c.dp(16)
        let labels = preview.chipLabels.enumerated().map { chipDisplayLabel($1, selected: $0 == preview.selectedIndex) }
        let chipWidths = labels.map { 2 * chipPadX + c.width($0, chipFont) }
        let chipH = 2 * chipPadY + c.lineHeight(chipFont)
        let chipsContentW = showChips ? chipWidths.reduce(0, +) + chipGap * Double(chipWidths.count) : 0

        // Row 1
        let textMax = land ? min(c.dp(280), availInner - (showGo ? c.dp(16) + goW : 0)) : availInner
        let nameW = min(textMax, c.width(preview.place.name, nameFont))
        let metaW = min(textMax, c.width(preview.meta, metaFont))
        let textColW = land ? max(nameW, metaW) : availInner
        let nameH = c.lineHeight(nameFont), metaH = c.lineHeight(metaFont)
        let textColH = nameH + c.dp(2) + metaH
        let row1W = land ? textColW + (showGo ? c.dp(16) + goW : 0) : availInner
        let row1H = land ? max(textColH, showGo ? goH : 0) : textColH

        let innerW: Double = land
            ? min(availInner, max(row1W, showChips ? chipsContentW : 0, actionsNaturalW))
            : availInner
        let gapRow = c.dp(8)
        let h = padV + row1H + (showChips ? gapRow + chipH : 0) + gapRow + actionsH + padV
        let frame = DashRect(x: x, y: bottom - h, width: innerW + 2 * pad, height: h)
        let top = frame.minY + padV
        let left = frame.minX + pad

        let textTop = top + (row1H - textColH) / 2
        let nameRect = DashRect(x: left, y: textTop, width: land ? textColW : innerW, height: nameH)
        let metaRect = DashRect(x: left, y: nameRect.maxY + c.dp(2), width: land ? textColW : innerW, height: metaH)
        var goRect: DashRect?
        if land && showGo {
            goRect = DashRect(x: left + textColW + c.dp(16), y: top + (row1H - goH) / 2, width: goW, height: goH)
        }
        var y = top + row1H
        var chipsViewport: DashRect?
        var chipRects: [DashRect] = []
        if showChips {
            y += gapRow
            let vp = DashRect(x: left, y: y, width: innerW, height: chipH)
            chipsViewport = vp
            let maxScroll = max(0, chipsContentW - innerW)
            let scroll = min(max(0, chipScroll), maxScroll)
            var cx = left - scroll
            for w in chipWidths {
                chipRects.append(DashRect(x: cx, y: y, width: w, height: chipH))
                cx += w + chipGap
            }
            y += chipH
        }
        y += gapRow
        var actions: [DashPreviewActionLayout] = []
        var ax = left
        for (i, spec) in actionSpecs.enumerated() {
            if !land && spec.0 == "preview.cancel" {
                // Portrait: spacer pushes Cancel/Done (+ Go) to the right edge.
                let tail = actionWidths[i] + (showGo ? c.dp(4) + goW : 0)
                ax = max(ax, left + innerW - tail)
            }
            actions.append(DashPreviewActionLayout(id: spec.0, label: spec.1, color: spec.2,
                                                   rect: DashRect(x: ax, y: y + (actionsH - c.dp(40)) / 2, width: actionWidths[i], height: c.dp(40))))
            ax += actionWidths[i]
        }
        if !land && showGo {
            goRect = DashRect(x: ax + c.dp(4), y: y + (actionsH - goH) / 2, width: goW, height: goH)
        }
        return DashPreviewCardLayout(frame: frame, nameRect: nameRect, nameFont: nameFont, metaRect: metaRect,
                                     metaFont: metaFont, goRect: goRect, goFont: goFont, chipsViewport: chipsViewport,
                                     chipRects: chipRects, chipLabels: showChips ? labels : [], chipFont: chipFont,
                                     chipsContentWidth: chipsContentW, actions: actions, actionFont: actionFont)
    }

    // MARK: Arrive card

    /// Landscape: bottom-left (x 10, bottom H − 10, max right W − 76), padding 16×12, title 17 sp
    /// bold, meta 13 sp, buttons (top 10, h 44): Park here (min 120, blue), Find parking (min 120,
    /// route-chip style), Done (transparent). Portrait: full width, title 18 sp, Park/Find equal
    /// weights (min h 48, gap 8), full-width "Done · free ride" (h 44, top 8).
    public static func arriveCard(_ c: DashLayoutContext, arrival: ArrivalCard, language: DashLanguage) -> DashArriveCardLayout {
        let land = c.isLandscape
        let pad = c.dp(16), padV = c.dp(land ? 12 : 14)
        let x = c.safe.minX + c.dp(10)
        let bottom = c.safe.maxY - c.dp(10)
        let maxRight = land ? c.safe.maxX - c.dp(76) : c.safe.maxX - c.dp(10)
        let availInner = max(c.dp(120), maxRight - x - 2 * pad)
        let titleFont = c.font(land ? 17 : 18, .bold), metaFont = c.font(13)
        let buttonFont = c.font(14, .bold), doneFont = c.font(14)
        let parkLabel = DashText.parkHere.localized(language), findLabel = DashText.findParking.localized(language)
        let doneLabel = (land ? DashText.done : DashText.doneFreeRide).localized(language)
        let btnPad = c.dp(16)
        let parkW = max(c.dp(120), 2 * btnPad + c.width(parkLabel, buttonFont))
        let findW = max(c.dp(120), 2 * btnPad + c.width(findLabel, buttonFont))
        let doneW = 2 * btnPad + c.width(doneLabel, doneFont)
        let titleH = c.lineHeight(titleFont)
        let metaLines = DashTextLayout.lineCount(arrival.meta, maxWidth: availInner, font: metaFont, maxLines: 2, measurer: c.measurer)
        let metaH = Double(metaLines) * c.lineHeight(metaFont)
        if land {
            let buttonsW = parkW + c.dp(8) + findW + c.dp(8) + doneW
            let innerW = min(availInner, max(c.width(arrival.title, titleFont), c.width(arrival.meta, metaFont), buttonsW))
            let h = padV + titleH + c.dp(2) + metaH + c.dp(10) + c.dp(44) + padV
            let frame = DashRect(x: x, y: bottom - h, width: innerW + 2 * pad, height: h)
            let left = frame.minX + pad
            let titleRect = DashRect(x: left, y: frame.minY + padV, width: innerW, height: titleH)
            let metaRect = DashRect(x: left, y: titleRect.maxY + c.dp(2), width: innerW, height: metaH)
            let by = metaRect.maxY + c.dp(10)
            let park = DashRect(x: left, y: by, width: parkW, height: c.dp(44))
            let find = DashRect(x: park.maxX + c.dp(8), y: by, width: findW, height: c.dp(44))
            let done = DashRect(x: find.maxX + c.dp(8), y: by, width: doneW, height: c.dp(44))
            return DashArriveCardLayout(frame: frame, titleRect: titleRect, titleFont: titleFont, metaRect: metaRect,
                                        metaFont: metaFont, parkRect: park, findRect: find, doneRect: done,
                                        buttonFont: buttonFont, doneFont: doneFont)
        }
        let innerW = availInner
        let rowH = c.dp(48)
        let h = padV + titleH + c.dp(2) + metaH + c.dp(12) + rowH + c.dp(8) + c.dp(44) + padV
        let frame = DashRect(x: x, y: bottom - h, width: innerW + 2 * pad, height: h)
        let left = frame.minX + pad
        let titleRect = DashRect(x: left, y: frame.minY + padV, width: innerW, height: titleH)
        let metaRect = DashRect(x: left, y: titleRect.maxY + c.dp(2), width: innerW, height: metaH)
        let by = metaRect.maxY + c.dp(12)
        let half = (innerW - c.dp(8)) / 2
        let park = DashRect(x: left, y: by, width: half, height: rowH)
        let find = DashRect(x: park.maxX + c.dp(8), y: by, width: half, height: rowH)
        let done = DashRect(x: left, y: park.maxY + c.dp(8), width: innerW, height: c.dp(44))
        return DashArriveCardLayout(frame: frame, titleRect: titleRect, titleFont: titleFont, metaRect: metaRect,
                                    metaFont: metaFont, parkRect: park, findRect: find, doneRect: done,
                                    buttonFont: buttonFont, doneFont: doneFont)
    }

    // MARK: Lap card

    /// x = 12, bottom = H − 88 (or 8 above `aboveY`, the top of the visible bottom-left card),
    /// padding 14×8, line 1 22 sp bold, line 2 13 sp (top 2), bottom-edge shape.
    public static func lapCard(_ c: DashLayoutContext, lap: DashLapTimer, aboveY: Double? = nil) -> DashLapCardLayout {
        let titleFont = c.font(22, .bold), metaFont = c.font(13)
        let padX = c.dp(14), padY = c.dp(8)
        let maxW = c.safe.width - c.dp(24) - 2 * padX
        let innerW = min(maxW, max(c.width(lap.title, titleFont), c.width(lap.meta, metaFont)))
        let titleH = c.lineHeight(titleFont), metaH = c.lineHeight(metaFont)
        let h = padY + titleH + c.dp(2) + metaH + padY
        var bottom = c.safe.maxY - c.dp(88)
        if let a = aboveY { bottom = min(bottom, a - c.dp(8)) }
        let frame = DashRect(x: c.safe.minX + c.dp(12), y: bottom - h, width: innerW + 2 * padX, height: h)
        let titleRect = DashRect(x: frame.minX + padX, y: frame.minY + padY, width: innerW, height: titleH)
        let metaRect = DashRect(x: frame.minX + padX, y: titleRect.maxY + c.dp(2), width: innerW, height: metaH)
        return DashLapCardLayout(frame: frame, titleRect: titleRect, titleFont: titleFont, metaRect: metaRect, metaFont: metaFont)
    }

    // MARK: Menu sheet

    /// Right-side panel (w 280, full safe height, padding 12): Ride / Map / Settings / Close
    /// (navigation-dash.md §11.8). The "3D" row (no-op on the bike) and the unused legacy scenic
    /// length row are omitted.
    public static func menu(_ c: DashLayoutContext, content m: DashMenuContent) -> DashMenuLayout {
        let L = m.language
        let w = c.dp(DashDimens.menuWidth)
        let panel = DashRect(x: c.safe.maxX - w, y: c.safe.minY, width: w, height: c.safe.height)
        let pad = c.dp(DashDimens.menuPadding)
        let left = panel.minX + pad, innerW = w - 2 * pad
        let titleFont = c.font(15, .bold), labelFont = c.font(13, .bold)
        let btnH = c.dp(DashDimens.menuButtonHeight), segH = c.dp(DashDimens.segmentHeight)
        var items: [DashMenuItem] = []
        var y = pad
        func title(_ t: DashText, first: Bool) {
            if !first { y += c.dp(14) }
            let h = c.lineHeight(titleFont)
            items.append(DashMenuItem(kind: .title(t.localized(L)), rect: DashRect(x: left, y: y, width: innerW, height: h)))
            y += h + c.dp(8)
        }
        var firstInSection = true
        func button(_ id: String, _ label: String, destructive: Bool = false) {
            if !firstInSection { y += c.dp(6) }
            firstInSection = false
            items.append(DashMenuItem(kind: .button(id: id, label: label, destructive: destructive, fontSp: 15),
                                      rect: DashRect(x: left, y: y, width: innerW, height: btnH)))
            y += btnH
        }
        func segments(_ label: DashText, _ options: [(String, String, Bool)], first: Bool) {
            if !first { y += c.dp(12) }
            let lh = c.lineHeight(labelFont)
            items.append(DashMenuItem(kind: .label(label.localized(L)), rect: DashRect(x: left, y: y, width: innerW, height: lh)))
            y += lh + c.dp(6)
            let gap = c.dp(8)
            let n = Double(options.count)
            let sw = (innerW - gap * (n - 1)) / n
            for (i, o) in options.enumerated() {
                items.append(DashMenuItem(kind: .segment(id: o.0, label: o.1, selected: o.2),
                                          rect: DashRect(x: left + Double(i) * (sw + gap), y: y, width: sw, height: segH)))
            }
            y += segH
        }
        let p = m.preferences
        title(.ride, first: true)
        firstInSection = true
        button("menu.end", DashText.endNavigation.localized(L), destructive: true)
        button("menu.park", DashText.parkHere.localized(L))
        button("menu.goHome", DashText.goHome.localized(L))
        button("menu.setHome", DashText.setHomeHere.localized(L))
        button("menu.recalc", DashText.recenterRecalc.localized(L))
        button("menu.record", (m.recording ? DashText.stopRecording : DashText.recordRide).localized(L))
        button("menu.circuit", DashText.circuit.localized(L))
        if m.showsMusic { button("menu.music", DashText.music.localized(L)) }
        title(.map, first: false)
        firstInSection = true
        button("menu.follow", (m.follow ? DashText.followOn : DashText.freePan).localized(L))
        button("menu.heading", (m.headingUp ? DashText.headingUp : DashText.northUp).localized(L))
        button("menu.voice", (p.voiceOn ? DashText.voiceOn : DashText.voiceMuted).localized(L))
        // － | ＋ row (weights 1:1, gap 6, 18 sp)
        y += c.dp(6)
        let half = (innerW - c.dp(6)) / 2
        items.append(DashMenuItem(kind: .button(id: "menu.zoomOut", label: DashText.zoomOutGlyph.localized(L), destructive: false, fontSp: 18),
                                  rect: DashRect(x: left, y: y, width: half, height: btnH)))
        items.append(DashMenuItem(kind: .button(id: "menu.zoomIn", label: DashText.zoomInGlyph.localized(L), destructive: false, fontSp: 18),
                                  rect: DashRect(x: left + half + c.dp(6), y: y, width: half, height: btnH)))
        y += btnH
        title(.settings, first: false)
        let on = DashText.on.localized(L), off = DashText.off.localized(L)
        segments(.units, [("menu.units.metric", DashText.metric.localized(L), p.units == .metric),
                          ("menu.units.imperial", DashText.imperial.localized(L), p.units == .imperial)], first: true)
        segments(.theme, [("menu.theme.auto", DashText.auto.localized(L), p.theme == .auto),
                          ("menu.theme.day", DashText.day.localized(L), p.theme == .day),
                          ("menu.theme.night", DashText.night.localized(L), p.theme == .night)], first: false)
        segments(.voice, [("menu.voiceSeg.on", on, p.voiceOn), ("menu.voiceSeg.off", off, !p.voiceOn)], first: false)
        segments(.nextStop, [("menu.nextStop.on", on, p.showNextStop), ("menu.nextStop.off", off, !p.showNextStop)], first: false)
        segments(.autoFinish, [("menu.autoFinish.on", on, p.autoFinish), ("menu.autoFinish.off", off, !p.autoFinish)], first: false)
        segments(.chrome, [("menu.chrome.dark", DashText.dark.localized(L), p.chrome == .dark),
                           ("menu.chrome.black", DashText.black.localized(L), p.chrome == .black),
                           ("menu.chrome.slate", DashText.slate.localized(L), p.chrome == .slate),
                           ("menu.chrome.forest", DashText.forest.localized(L), p.chrome == .forest)], first: false)
        segments(.routeMode, [("menu.routeMode.fast", DashText.fast.localized(L), p.routeMode == .fast),
                              ("menu.routeMode.fun", DashText.fun.localized(L), p.routeMode == .fun)], first: false)
        segments(.avoidTolls, [("menu.avoidTolls.on", on, p.avoidTolls), ("menu.avoidTolls.off", off, !p.avoidTolls)], first: false)
        segments(.avoidHighways, [("menu.avoidHighways.on", on, p.avoidHighways),
                                  ("menu.avoidHighways.off", off, !p.avoidHighways)], first: false)
        y += c.dp(16)
        items.append(DashMenuItem(kind: .button(id: "menu.close", label: DashText.close.localized(L), destructive: false, fontSp: 15),
                                  rect: DashRect(x: left, y: y, width: innerW, height: btnH)))
        y += btnH + pad
        return DashMenuLayout(panel: panel, items: items, contentHeight: y)
    }

    // MARK: Search sheet

    /// Full-canvas white sheet: header h 64 (← 44×44, input pill h 48 with a 40×40 magnifier),
    /// POI chips row (padding 10×8, horizontally scrollable), status line, then the list: a
    /// "Type on your phone" row followed by place rows (name 16 sp bold, subtitle 13 sp,
    /// ★ Save / ＋ Marker / Delete actions on the right).
    public static func searchSheet(_ c: DashLayoutContext, search: DashSearchState, places: DashPlaces,
                                   language L: DashLanguage, chipScroll: Double = 0) -> DashSearchLayout {
        let s = c.safe
        let backFont = c.font(24), inputFont = c.font(17), chipFont = c.font(14)
        let nameFont = c.font(16, .bold), subFont = c.font(13), actionFont = c.font(14, .bold)
        let typeFont = c.font(16, .bold)
        let headerH = c.dp(DashDimens.searchHeaderHeight)
        let padX = c.dp(10)
        let back = DashRect(x: s.minX + padX, y: s.minY + (headerH - c.dp(44)) / 2, width: c.dp(44), height: c.dp(44))
        let input = DashRect(x: back.maxX + c.dp(4), y: s.minY + (headerH - c.dp(48)) / 2,
                             width: max(c.dp(80), s.maxX - padX - back.maxX - c.dp(4)), height: c.dp(48))
        let go = DashRect(x: input.maxX - c.dp(6) - c.dp(40), y: input.midY - c.dp(20), width: c.dp(40), height: c.dp(40))
        let inputText = DashRect(x: input.minX + c.dp(14), y: input.minY, width: max(0, go.minX - input.minX - c.dp(14)),
                                 height: input.height)
        // Chips
        let chipPadX = c.dp(18), chipPadY = c.dp(10), chipGap = c.dp(10)
        let chipH = 2 * chipPadY + c.lineHeight(chipFont)
        let chipsVP = DashRect(x: s.minX + padX, y: s.minY + headerH + c.dp(8), width: s.width - 2 * padX, height: chipH)
        let chipLabels = search.poiChips.map { DashStrings.poiChipLabel($0, L) }
        let chipWidths = chipLabels.map { 2 * chipPadX + c.width($0, chipFont) }
        let chipsContentW = chipWidths.reduce(0, +) + chipGap * Double(max(0, chipWidths.count - 1))
        let chipScrollClamped = min(max(0, chipScroll), max(0, chipsContentW - chipsVP.width))
        var chipRects: [DashRect] = []
        var cx = chipsVP.minX - chipScrollClamped
        for w in chipWidths {
            chipRects.append(DashRect(x: cx, y: chipsVP.minY, width: w, height: chipH))
            cx += w + chipGap
        }
        // Status
        let rowsPlaces: [(Place, Int?)]
        let statusText: String
        var accent = false
        if let results = search.results {
            rowsPlaces = results.enumerated().map { ($1, $0) }
            statusText = search.status ?? (results.isEmpty ? DashText.noResults.localized(L) : DashStrings.places(results.count, L))
        } else {
            rowsPlaces = places.idleList().map { ($0, nil) }
            if let st = search.status {
                statusText = st
            } else {
                statusText = DashText.typeOnPhoneStatus.localized(L)
                accent = true
            }
        }
        let statusFont = accent ? c.font(16) : c.font(13)
        let statusW = s.width - 2 * c.dp(16)
        let statusLines = DashTextLayout.lineCount(statusText, maxWidth: statusW, font: statusFont, maxLines: 2, measurer: c.measurer)
        let statusRect = DashRect(x: s.minX + c.dp(16), y: chipsVP.maxY + c.dp(8), width: statusW,
                                  height: Double(statusLines) * c.lineHeight(statusFont))
        let listTop = statusRect.maxY + c.dp(4)
        let listVP = DashRect(x: s.minX, y: listTop, width: s.width, height: max(0, s.maxY - listTop))
        // Rows (content coordinates)
        var rows: [DashSearchRowLayout] = []
        var y = 0.0
        let rowPadX = c.dp(16), rowPadY = c.dp(10)
        let typeH = c.dp(48)
        rows.append(DashSearchRowLayout(id: "search.typeOnPhone", kind: .typeOnPhone,
                                        rect: DashRect(x: listVP.minX, y: y, width: listVP.width, height: typeH),
                                        nameRect: DashRect(x: listVP.minX + rowPadX, y: y, width: listVP.width - 2 * rowPadX, height: typeH),
                                        subtitleRect: nil, subtitle: "", actions: []))
        y += typeH + 1
        let actionH = c.dp(36), actionPadX = c.dp(10)
        for (i, entry) in rowsPlaces.enumerated() {
            let (place, resultIndex) = entry
            var specs: [(String, String, DashColor)] = [
                ("save", DashText.save.localized(L), DashPalette.sheetAction),
                ("marker", DashText.marker.localized(L), DashPalette.sheetAction),
            ]
            if places.canDelete(place) { specs.append(("delete", DashText.delete.localized(L), DashPalette.sheetDelete)) }
            let widths = specs.map { 2 * actionPadX + c.width($0.1, actionFont) }
            let actionsW = widths.reduce(0, +)
            let textW = max(c.dp(80), listVP.width - 2 * rowPadX - actionsW - c.dp(8))
            let subtitle = [place.category, place.subtitle].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: " · ")
            let nameH = c.lineHeight(nameFont), subH = subtitle.isEmpty ? 0 : c.lineHeight(subFont)
            let textH = nameH + (subtitle.isEmpty ? 0 : c.dp(2) + subH)
            let rowH = max(c.dp(56), textH + 2 * rowPadY)
            let id = resultIndex != nil ? "search.result.\(i)" : "search.idle.\(i)"
            let row = DashRect(x: listVP.minX, y: y, width: listVP.width, height: rowH)
            let ty = y + (rowH - textH) / 2
            let nameRect = DashRect(x: row.minX + rowPadX, y: ty, width: textW, height: nameH)
            let subRect = subtitle.isEmpty ? nil : DashRect(x: row.minX + rowPadX, y: nameRect.maxY + c.dp(2), width: textW, height: subH)
            var ax = row.maxX - rowPadX - actionsW
            var actions: [DashPreviewActionLayout] = []
            for (k, spec) in specs.enumerated() {
                actions.append(DashPreviewActionLayout(id: "\(id).\(spec.0)", label: spec.1, color: spec.2,
                                                       rect: DashRect(x: ax, y: y + (rowH - actionH) / 2, width: widths[k], height: actionH)))
                ax += widths[k]
            }
            rows.append(DashSearchRowLayout(id: id, kind: .place(place, resultIndex: resultIndex), rect: row, nameRect: nameRect,
                                            subtitleRect: subRect, subtitle: subtitle, actions: actions))
            y += rowH + 1 // 1 px divider
        }
        y += c.dp(24)
        return DashSearchLayout(sheet: DashRect(x: 0, y: 0, width: c.canvas.width, height: c.canvas.height),
                                backRect: back, inputRect: input, inputTextRect: inputText, goRect: go,
                                chipsViewport: chipsVP, chipRects: chipRects, chipLabels: chipLabels,
                                chipsContentWidth: chipsContentW, statusRect: statusRect, statusText: statusText,
                                statusAccent: accent, listViewport: listVP, rows: rows, listContentHeight: y,
                                backFont: backFont, inputFont: inputFont, chipFont: chipFont, statusFont: statusFont,
                                nameFont: nameFont, subtitleFont: subFont, actionFont: actionFont, typeOnPhoneFont: typeFont)
    }

    // MARK: Small overlays (iOS additions)

    /// A centred pill (toast / link banner) below `topY` within the map area left of the FAB lane.
    public static func overlayPill(_ c: DashLayoutContext, text: String, font: DashFont, topY: Double) -> (rect: DashRect, lines: Int) {
        let areaMinX = c.safe.minX + c.dp(8)
        let areaMaxX = c.isLandscape ? c.safe.maxX - c.dp(DashDimens.fabLane) : c.safe.maxX - c.dp(8)
        let maxTextW = max(c.dp(80), (areaMaxX - areaMinX) * 0.9 - 2 * c.dp(16))
        let lines = DashTextLayout.wrap(text, maxWidth: maxTextW, font: font, maxLines: 2, measurer: c.measurer)
        let textW = lines.map { c.width($0, font) }.max() ?? 0
        let w = textW + 2 * c.dp(16)
        let h = Double(lines.count) * c.lineHeight(font) + 2 * c.dp(9)
        let x = (areaMinX + areaMaxX) / 2 - w / 2
        return (DashRect(x: x, y: topY, width: w, height: h), lines.count)
    }

    /// The clock chip: landscape → bottom of the FAB lane; portrait → under the FAB column.
    public static func clockChip(_ c: DashLayoutContext, text: String, font: DashFont, fabs: [DashRect]) -> DashRect {
        let w = c.width(text, font) + 2 * c.dp(9)
        let h = c.lineHeight(font) + 2 * c.dp(5)
        guard let last = fabs.last, let first = fabs.first else {
            return DashRect(x: c.safe.maxX - c.dp(8) - w, y: c.safe.maxY - c.dp(8) - h, width: w, height: h)
        }
        if c.isLandscape {
            // Centred under the FAB column, but never past its right edge (the lane is only 88 dp).
            let x = min(first.midX - w / 2, first.maxX - w)
            return DashRect(x: x, y: c.safe.maxY - c.dp(DashDimens.edge) - h, width: w, height: h)
        }
        return DashRect(x: c.safe.maxX - c.dp(8) - w, y: last.maxY + c.dp(10), width: w, height: h)
    }

    // MARK: Apple Music (iOS addition)

    /// The now-playing tile: a square of min(64 dp, room) (at least the 46-dp FAB size), right-aligned
    /// with the FAB column, 8 dp under the last FAB.
    /// - Landscape: down to 8 dp above the clock chip; when that leaves < 46 dp the clock gives way
    ///   (`hidesClock`) and the room is measured to 8 dp above the safe bottom; still < 46 dp → nil
    ///   (the menu entry remains).
    /// - Portrait (the clock sits under the FAB column): 8 dp under the clock (or the last FAB), down
    ///   to 12 dp above the safe bottom.
    /// - `avoiding`: every rect that intersects the tile shrinks it to end 8 dp above that rect;
    ///   < 46 dp → nil.
    public static func musicTile(_ c: DashLayoutContext, fabs: [DashRect], clock: DashRect?,
                                 avoiding: [DashRect] = []) -> DashMusicTileLayout? {
        guard let last = fabs.last else { return nil }
        let gap = c.dp(DashDimens.musicTileGap)
        let preferred = c.dp(DashDimens.musicTile), minimum = c.dp(DashDimens.fabSize)
        let right = last.maxX
        let top: Double
        var side: Double
        var hidesClock = false
        if c.isLandscape {
            top = last.maxY + gap
            let toSafeBottom = c.safe.maxY - c.dp(DashDimens.edge) - top
            if let clock, clock.minY - gap - top >= minimum {
                side = min(preferred, clock.minY - gap - top)
            } else {
                side = min(preferred, toSafeBottom)
                hidesClock = clock != nil
            }
        } else {
            top = (clock?.maxY ?? last.maxY) + gap
            side = min(preferred, c.safe.maxY - c.dp(12) - top)
        }
        guard side >= minimum else { return nil }
        func frame(_ s: Double) -> DashRect { DashRect(x: right - s, y: top, width: s, height: s) }
        for r in avoiding where frame(side).intersects(r) {
            side = r.minY - gap - top
            guard side >= minimum else { return nil }
        }
        let f = frame(side)
        let inset = c.dp(6), barH = c.dp(3), badge = c.dp(20)
        return DashMusicTileLayout(
            frame: f, cornerRadius: c.dp(DashDimens.musicTileRadius),
            progressRect: DashRect(x: f.minX + inset, y: f.maxY - inset - barH, width: f.width - 2 * inset, height: barH),
            badgeRect: DashRect(x: f.maxX - c.dp(4) - badge, y: f.minY + c.dp(4), width: badge, height: badge),
            hidesClock: hidesClock)
    }

    /// Metadata as drawn on one line: line breaks / tabs become spaces, surrounding blanks trimmed.
    static func musicText(_ s: String) -> String {
        String(s.map { $0.isNewline || $0 == "\t" ? " " : $0 }).trimmingCharacters(in: .whitespaces)
    }

    /// The title as drawn: "" (or blanks) → "Unknown song".
    static func musicTitle(_ m: DashNowPlaying, _ L: DashLanguage) -> String {
        let t = musicText(m.title)
        return t.isEmpty ? DashText.unknownSong.localized(L) : t
    }

    /// Title 22 sp bold (24 sp stacked on a portrait canvas), artist 17 sp medium, album 15 sp,
    /// times 14 sp tabular digits.
    static func musicTitleFont(_ c: DashLayoutContext, stacked: Bool) -> DashFont {
        c.font(stacked && !c.isLandscape ? 24 : 22, .bold)
    }

    /// What the block shows; the compression ladder drops lines from it.
    private struct MusicContent {
        var title: String
        var hasArtist: Bool
        var hasAlbum: Bool
        var hasDuration: Bool
    }

    /// One step of the compression ladder: the block's height and its transport row.
    private struct MusicBlock {
        var step: Int
        var height: Double
        var titleLines: Int
        var artist: Bool
        var album: Bool
        var bar: Bool
        var times: Bool
        /// ⏯ diameter / ⏮ ⏭ diameter.
        var play: Double
        var side: Double
        var rowWidth: Double
    }

    /// Lines of the full title (≤ 2) at `width`: steps 0 and 1 of the ladder.
    private static func musicTitleLines(_ c: DashLayoutContext, _ m: MusicContent, width: Double, stacked: Bool) -> Int {
        DashTextLayout.lineCount(m.title, maxWidth: width, font: musicTitleFont(c, stacked: stacked), maxLines: 2,
                                 measurer: c.measurer)
    }

    private static func musicBlock(_ c: DashLayoutContext, _ m: MusicContent, step: Int, width: Double,
                                   stacked: Bool, titleLines: Int) -> MusicBlock {
        let titleFont = musicTitleFont(c, stacked: stacked)
        let lines = step >= 2 ? 1 : titleLines
        let artist = m.hasArtist && step < 4, album = m.hasAlbum && step < 1
        let bar = m.hasDuration, times = m.hasDuration && step < 5
        let play = c.dp(step >= 3 ? 64 : 80), side = c.dp(step >= 3 ? 52 : 64)
        var h = Double(lines) * c.lineHeight(titleFont)
        if artist { h += c.dp(4) + c.lineHeight(c.font(17, .medium)) }
        if album { h += c.dp(2) + c.lineHeight(c.font(15)) }
        if bar { h += c.dp(14) + c.dp(6) }
        if times { h += c.dp(4) + c.lineHeight(c.font(14, digits: true)) }
        h += c.dp(14) + play
        return MusicBlock(step: step, height: h, titleLines: lines, artist: artist, album: album, bar: bar, times: times,
                          play: play, side: side, rowWidth: side + c.dp(20) + play + c.dp(20) + side)
    }

    /// The least compressed step whose block fits `width` × `maxHeight` (nil: none does).
    private static func musicBlock(_ c: DashLayoutContext, _ m: MusicContent, width: Double, maxHeight: Double,
                                   stacked: Bool, titleLines: Int) -> MusicBlock? {
        for step in 0 ... 5 {
            let b = musicBlock(c, m, step: step, width: width, stacked: stacked, titleLines: titleLines)
            if b.height <= maxHeight && b.rowWidth <= width { return b }
        }
        return nil
    }

    /// The Music sheet over the whole canvas; `reserved` = the nav card kept on top while
    /// navigating (the artwork never goes under it). Margin 16 dp, gap 12 dp, text column ≥ 300 dp,
    /// artwork ≥ 96 dp. Two candidates, the larger artwork wins (tie within 0.5 px: side-by-side in
    /// landscape, stacked in portrait):
    /// - side-by-side: artwork square on the right (side = min(safe.h − 2m, safe.w − 3m − 300 dp)),
    ///   moved below `reserved` when that reaches into its column; text column on the left, the
    ///   block vertically centred in it;
    /// - stacked: artwork centred at the top, block under it at the least compressed step that fits
    ///   60 % (then 55 % … 30 %) of the height left.
    /// Neither fits → `.textOnly` (block at step 5, no artwork).
    /// Block (centred text): title ≤ 2 lines · +4 artist · +2 album · +14 bar (6 dp) · +4 times ·
    /// +14 transport ⏮ 64 · 20 · ⏯ 80 · 20 · ⏭ 64 dp; empty artist / album and an unknown duration
    /// drop their lines and spacing. ✕ (48 dp) on the artwork's top-right corner, inset 8 dp.
    public static func musicSheet(_ c: DashLayoutContext, music: DashNowPlaying, language: DashLanguage,
                                  reserved: DashRect?) -> DashMusicSheetLayout {
        let s = c.safe
        let m = c.dp(DashDimens.musicSheetMargin), gap = c.dp(DashDimens.musicSheetGap)
        let textMin = c.dp(DashDimens.musicSheetTextMin), artMin = c.dp(DashDimens.musicArtMin)
        let closeSide = c.dp(DashDimens.musicClose), closeInset = c.dp(8)
        let content = MusicContent(title: musicTitle(music, language), hasArtist: !musicText(music.artist).isEmpty,
                                   hasAlbum: !musicText(music.album).isEmpty, hasDuration: music.knownDuration != nil)

        struct Candidate {
            var arrangement: DashMusicSheetArrangement
            var art: DashRect
            var column: DashRect
            var block: MusicBlock
        }
        var candidates: [Candidate] = []
        // Side by side: text column left, artwork right.
        do {
            var colTop = s.minY + m
            if let r = reserved { colTop = max(colTop, r.maxY + gap) }
            var artTop = s.minY + m
            var side = min(s.height - 2 * m, s.width - 3 * m - textMin)
            var artX = s.maxX - m - side
            if let r = reserved, r.maxX > artX - 0.5 { // never under the nav card
                artTop = r.maxY + gap
                side = min(side, s.maxY - m - artTop)
                artX = s.maxX - m - side
            }
            if side >= artMin {
                let artY = max(artTop, min(s.midY - side / 2, s.maxY - m - side))
                let art = DashRect(x: artX, y: artY, width: side, height: side)
                let colX = s.minX + m
                let col = DashRect(x: colX, y: colTop, width: art.minX - m - colX, height: s.maxY - m - colTop)
                let lines = musicTitleLines(c, content, width: col.width, stacked: false)
                if let b = musicBlock(c, content, width: col.width, maxHeight: col.height, stacked: false, titleLines: lines) {
                    candidates.append(Candidate(arrangement: .sideBySide, art: art, column: col, block: b))
                }
            }
        }
        // Stacked: artwork centred at the top, block below.
        do {
            let top = reserved.map { $0.maxY + gap } ?? s.minY + m
            let w = s.width - 2 * m
            let avail = s.maxY - m - top
            let lines = musicTitleLines(c, content, width: w, stacked: true)
            for share in [0.60, 0.55, 0.50, 0.45, 0.40, 0.35, 0.30] {
                guard let b = musicBlock(c, content, width: w, maxHeight: avail * share, stacked: true, titleLines: lines) else { continue }
                let side = min(w, avail - gap - b.height)
                guard side >= artMin else { continue }
                let art = DashRect(x: s.midX - side / 2, y: top, width: side, height: side)
                candidates.append(Candidate(arrangement: .stacked, art: art,
                                            column: DashRect(x: s.minX + m, y: art.maxY + gap, width: w, height: b.height), block: b))
                break
            }
        }
        var best: Candidate?
        for cand in candidates {
            guard let b = best else { best = cand; continue }
            if abs(cand.art.width - b.art.width) < 0.5 {
                if cand.arrangement == (c.isLandscape ? .sideBySide : .stacked) { best = cand }
            } else if cand.art.width > b.art.width {
                best = cand
            }
        }

        let arrangement: DashMusicSheetArrangement
        let art: DashRect, column: DashRect, block: MusicBlock, close: DashRect
        if let best {
            arrangement = best.arrangement
            art = best.art
            column = best.column
            block = best.block
            close = DashRect(x: art.maxX - closeInset - closeSide, y: art.minY + closeInset, width: closeSide, height: closeSide)
        } else {
            // Text only: ✕ at the top-right of the free area; the block (step 5) centred under it when
            // there is room, else in the whole free area.
            arrangement = .textOnly
            art = .zero
            let top = reserved.map { max(s.minY + m, $0.maxY + gap) } ?? s.minY + m
            let free = DashRect(x: s.minX + m, y: top, width: max(0, s.width - 2 * m), height: max(0, s.maxY - m - top))
            block = musicBlock(c, content, step: 5, width: free.width, stacked: false, titleLines: 1)
            close = DashRect(x: free.maxX - closeSide, y: free.minY, width: closeSide, height: closeSide)
            let below = close.maxY + gap
            column = free.maxY - below >= block.height
                ? DashRect(x: free.minX, y: below, width: free.width, height: free.maxY - below) : free
        }

        // Block internals, top → bottom, vertically centred in the column.
        let titleFont = musicTitleFont(c, stacked: arrangement == .stacked)
        let artistFont = c.font(17, .medium), albumFont = c.font(15), timeFont = c.font(14, digits: true)
        let x = column.minX, w = column.width
        var y = column.minY + (column.height - block.height) / 2
        var titleRect = DashRect(x: x, y: y, width: w, height: Double(block.titleLines) * c.lineHeight(titleFont))
        if arrangement == .textOnly, titleRect.intersects(close) {
            // Keep the (centred) title clear of the ✕: the same inset on both sides.
            let inset = min(w / 2, titleRect.maxX - close.minX + gap)
            titleRect = DashRect(x: x + inset, y: titleRect.minY, width: w - 2 * inset, height: titleRect.height)
        }
        y = titleRect.maxY
        var artistRect: DashRect?, albumRect: DashRect?
        if block.artist {
            y += c.dp(4)
            artistRect = DashRect(x: x, y: y, width: w, height: c.lineHeight(artistFont))
            y += c.lineHeight(artistFont)
        }
        if block.album {
            y += c.dp(2)
            albumRect = DashRect(x: x, y: y, width: w, height: c.lineHeight(albumFont))
            y += c.lineHeight(albumFont)
        }
        var progressRect: DashRect?, elapsedRect: DashRect?, remainingRect: DashRect?
        if block.bar {
            y += c.dp(14)
            progressRect = DashRect(x: x, y: y, width: w, height: c.dp(6))
            y += c.dp(6)
            if block.times {
                y += c.dp(4)
                let h = c.lineHeight(timeFont)
                elapsedRect = DashRect(x: x, y: y, width: w / 2, height: h)
                remainingRect = DashRect(x: x + w / 2, y: y, width: w / 2, height: h)
                y += h
            }
        }
        y += c.dp(14)
        let rowX = x + (w - block.rowWidth) / 2
        let previous = DashRect(x: rowX, y: y + (block.play - block.side) / 2, width: block.side, height: block.side)
        let playPause = DashRect(x: previous.maxX + c.dp(20), y: y, width: block.play, height: block.play)
        let next = DashRect(x: playPause.maxX + c.dp(20), y: previous.minY, width: block.side, height: block.side)
        return DashMusicSheetLayout(
            arrangement: arrangement, sheet: DashRect(x: 0, y: 0, width: c.canvas.width, height: c.canvas.height),
            artworkRect: art, artworkRadius: c.dp(DashDimens.musicArtRadius), closeRect: close,
            titleRect: titleRect, titleFont: titleFont, titleMaxLines: block.titleLines,
            artistRect: artistRect, artistFont: artistFont, albumRect: albumRect, albumFont: albumFont,
            progressRect: progressRect, elapsedRect: elapsedRect, remainingRect: remainingRect, timeFont: timeFont,
            previousRect: previous, playPauseRect: playPause, nextRect: next, compressionStep: block.step)
    }
}
