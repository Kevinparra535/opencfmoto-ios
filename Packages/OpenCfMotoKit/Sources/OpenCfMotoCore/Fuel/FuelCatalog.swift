// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP «Combustible»: the bundled bike catalog (tank litres + a conservative seed km/L, every
// figure with its source) and its exact-token search. The rows themselves are in
// FuelCatalogData.swift. Written fresh for OpenCfMoto: no dataset or matcher is ported from anywhere.
//
// Search rules (exact model tokens; never a prefix, a substring or a letter fragment):
// 1. fold: lower case, diacritics removed;
// 2. split into words on whitespace and "/";
// 3. brand words: "cf" "moto", "cf-moto", "cfmoto" → `cfmoto`; "moto" "morini", "motomorini", "morini" →
//    `motomorini`;
// 4. an entry's token set = for every word of its model and of each alias: the COMPACT form (every
//    character outside [a-z0-9] removed: "1000MT-X" → "1000mtx") and its MODEL NUMBERS (every maximal
//    run of ≥ 3 digits inside the word: "CL-C450" → "450"). Letter-only pieces ("mt", "x") and 1–2-digit
//    runs are not tokens.
// A query's brand words replace the brand prefilter; 4-digit words 1990…2099 filter by model year; the
// other words must be covered, in order, by consecutive groups whose concatenated compact form is IN
// the entry's token set ("1000 MT X" → "1000mtx"; "Ibex 450" → "ibex" + "450").

import Foundation

/// The brands of the catalog. The raw value is the id prefix and the canonical brand token.
public enum FuelBrand: String, Sendable, Codable, CaseIterable {
    case cfmoto = "cfmoto"
    case morini = "motomorini"

    public var displayName: String {
        switch self {
        case .cfmoto: return "CFMOTO"
        case .morini: return "Moto Morini"
        }
    }
}

/// What a catalog figure rests on.
public enum FuelSourceKind: String, Sendable, Codable, CaseIterable {
    /// Manufacturer / official importer page or spec sheet.
    case official
    /// Reputable press, a spec database, a press or long-term test.
    case published
    /// A class default: NOT a measurement.
    case estimate

    /// official > published > estimate.
    var strength: Int {
        switch self {
        case .official: return 2
        case .published: return 1
        case .estimate: return 0
        }
    }
}

/// One bundled bike model.
public struct FuelCatalogEntry: Sendable, Equatable, Hashable, Identifiable {
    /// Stable forever, e.g. "cfmoto-450mt", "motomorini-x-cape-700".
    public let id: String
    public let brand: FuelBrand
    /// "450MT", "800MT Sport / Touring", "X-Cape 700".
    public let model: String
    /// Full alternative names ("Ibex 450", "450SS"…).
    public let aliases: [String]
    /// The model years / market text, shown small ("2024+", "MY2025+ (20 L)").
    public let marketNote: String
    /// First model year (`FuelCatalog.yearRange(of:)` of `marketNote`).
    public let fromYear: Int?
    /// Last model year; nil = still sold / unknown.
    public let toYear: Int?
    /// Litres.
    public let tankL: Double
    /// The conservative starting km/L (replaced by the rider's own full-to-full fills).
    public let seedKmPerL: Double
    public let tankKind: FuelSourceKind
    /// The URL the tank figure comes from (https://…).
    public let tankSource: String
    public let consumptionKind: FuelSourceKind
    /// "https://…" or "estimate: <rule>".
    public let consumptionSource: String

    public init(id: String, brand: FuelBrand, model: String, aliases: [String], marketNote: String, fromYear: Int?,
                toYear: Int?, tankL: Double, seedKmPerL: Double, tankKind: FuelSourceKind, tankSource: String,
                consumptionKind: FuelSourceKind, consumptionSource: String) {
        self.id = id
        self.brand = brand
        self.model = model
        self.aliases = aliases
        self.marketNote = marketNote
        self.fromYear = fromYear
        self.toYear = toYear
        self.tankL = tankL
        self.seedKmPerL = seedKmPerL
        self.tankKind = tankKind
        self.tankSource = tankSource
        self.consumptionKind = consumptionKind
        self.consumptionSource = consumptionSource
    }

    /// "CFMOTO 450MT".
    public var displayName: String { "\(brand.displayName) \(model)" }

    /// The weakest of the two kinds (official > published > estimate).
    public var confidence: FuelSourceKind {
        tankKind.strength <= consumptionKind.strength ? tankKind : consumptionKind
    }
}

public enum FuelCatalog {
    /// Bundled rows in CATALOG.md order (that order is the search tie-break).
    public static let all: [FuelCatalogEntry] = rows

    private static let byId: [String: FuelCatalogEntry] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    public static func entry(id: String) -> FuelCatalogEntry? { byId[id] }

    // MARK: Normalising

    /// The normalised words of a text: folded (lower case, no diacritics), split on whitespace and
    /// "/", brand words merged into `cfmoto` / `motomorini`.
    public static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let raw = folded.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).map(String.init).filter { !$0.isEmpty }
        var out: [String] = []
        var i = 0
        while i < raw.count {
            let w = raw[i]
            let next = i + 1 < raw.count ? compact(raw[i + 1]) : nil
            if compact(w) == "cf", next == "moto" {
                out.append(FuelBrand.cfmoto.rawValue)
                i += 2
                continue
            }
            if compact(w) == "moto", next == "morini" {
                out.append(FuelBrand.morini.rawValue)
                i += 2
                continue
            }
            if let b = brand(ofToken: compact(w)) {
                out.append(b.rawValue)
            } else {
                out.append(w)
            }
            i += 1
        }
        return out
    }

    /// The brand a token names ("cfmoto" → .cfmoto, "morini" / "motomorini" → .morini), nil otherwise.
    public static func brand(ofToken token: String) -> FuelBrand? {
        switch compact(token) {
        case "cfmoto": return .cfmoto
        case "motomorini", "morini": return .morini
        default: return nil
        }
    }

    /// Every character outside [a-z0-9] removed (the text is expected folded already).
    static func compact(_ word: String) -> String {
        String(String.UnicodeScalarView(word.unicodeScalars.filter {
            ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9")
        }))
    }

    /// Every maximal run of ≥ 3 ASCII digits inside a word.
    static func modelNumbers(_ word: String) -> [String] {
        var out: [String] = []
        var run = ""
        for u in word.unicodeScalars {
            if u >= "0" && u <= "9" {
                run.unicodeScalars.append(u)
            } else {
                if run.count >= 3 { out.append(run) }
                run = ""
            }
        }
        if run.count >= 3 { out.append(run) }
        return out
    }

    /// The names of an entry: its model, then its aliases (each as normalised words).
    static func names(of entry: FuelCatalogEntry) -> [[String]] {
        ([entry.model] + entry.aliases).map(words).map { $0.filter { brand(ofToken: $0) == nil } }
    }

    /// An entry's token set: compact words + model numbers of its model and aliases.
    public static func tokenSet(of entry: FuelCatalogEntry) -> Set<String> {
        var set = Set<String>()
        for name in names(of: entry) {
            for w in name {
                let c = compact(w)
                if !c.isEmpty { set.insert(c) }
                for n in modelNumbers(c) { set.insert(n) }
            }
        }
        return set
    }

    /// The model years of a `marketNote`: the 4-digit years 1990…2099 it names. Two or more → first…second;
    /// one followed by "+" → that year…nil; one alone → that year only; none → (nil, nil).
    public static func yearRange(of note: String) -> (from: Int?, to: Int?) {
        var years: [(year: Int, end: String.Index)] = []
        var i = note.startIndex
        while i < note.endIndex {
            if note[i].isASCII, note[i].isNumber {
                var j = i
                while j < note.endIndex, note[j].isASCII, note[j].isNumber { j = note.index(after: j) }
                let digits = note[i ..< j]
                if digits.count == 4, let y = Int(digits), (1990 ... 2099).contains(y) { years.append((y, j)) }
                i = j
            } else {
                i = note.index(after: i)
            }
        }
        guard let first = years.first else { return (nil, nil) }
        if years.count >= 2 { return (first.year, years[1].year) }
        let open = first.end < note.endIndex && note[first.end] == "+"
        return (first.year, open ? nil : first.year)
    }

    // MARK: Search

    /// Exact-token search. `brand` is a prefilter that a brand named in the query replaces; an empty query
    /// lists every entry of the filter. Order: fewer entry words left unnamed by the query first (the best
    /// of the model and its aliases), then catalog order.
    public static func search(_ query: String, brand: FuelBrand? = nil,
                              in entries: [FuelCatalogEntry] = FuelCatalog.all) -> [FuelCatalogEntry] {
        var brands = Set<FuelBrand>()
        var year: Int?
        var rest: [String] = []
        for w in words(query) {
            if let b = Self.brand(ofToken: w) {
                brands.insert(b)
                continue
            }
            let c = compact(w)
            if c.count == 4, c == w, let y = Int(c), (1990 ... 2099).contains(y) {
                year = y
                continue
            }
            if c.isEmpty { continue } // punctuation only ("-", "·")
            rest.append(c)
        }
        if brands.isEmpty, let brand { brands.insert(brand) }
        var scored: [(index: Int, unnamed: Int, entry: FuelCatalogEntry)] = []
        for (index, entry) in entries.enumerated() {
            if !brands.isEmpty, !brands.contains(entry.brand) { continue }
            if let year, !((entry.fromYear ?? 0) ... (entry.toYear ?? 9999)).contains(year) { continue }
            if rest.isEmpty {
                scored.append((index, 0, entry))
                continue
            }
            let tokens = tokenSet(of: entry)
            guard covers(rest, tokens) else { continue }
            scored.append((index, unnamedWords(entry, query: rest, tokens: tokens), entry))
        }
        return scored.sorted { $0.unnamed != $1.unnamed ? $0.unnamed < $1.unnamed : $0.index < $1.index }.map(\.entry)
    }

    /// True when `q` (compact words) splits into consecutive groups whose concatenations are all tokens.
    static func covers(_ q: [String], _ tokens: Set<String>) -> Bool {
        let n = q.count
        var ok = [Bool](repeating: false, count: n + 1)
        ok[0] = true
        for end in 1 ... n {
            var group = ""
            for start in stride(from: end - 1, through: 0, by: -1) {
                group = q[start] + group
                if ok[start], tokens.contains(group) {
                    ok[end] = true
                    break
                }
            }
        }
        return ok[n]
    }

    /// The fewest words of one of the entry's names that the query does not name.
    private static func unnamedWords(_ entry: FuelCatalogEntry, query q: [String], tokens: Set<String>) -> Int {
        var groups = Set<String>()
        for start in q.indices {
            var g = ""
            for end in start ..< q.count {
                g += q[end]
                if tokens.contains(g) { groups.insert(g) }
            }
        }
        var best = Int.max
        for name in names(of: entry) {
            let unnamed = name.filter { w in
                let c = compact(w)
                if c.isEmpty { return false }
                return !groups.contains(c) && !modelNumbers(c).contains(where: groups.contains)
            }.count
            best = min(best, unnamed)
        }
        return best == .max ? 0 : best
    }
}
