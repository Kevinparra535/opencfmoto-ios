// SPDX-License-Identifier: AGPL-3.0-or-later
// Fuel MVP: the bundled catalog rows (Swift literals, no resource files). Transcribed as-is from the
// sourced catalog research (19 rows: 16 CFMOTO, 3 Moto Morini; CATALOG.md "Machine-readable copy").
//
// Rules every row meets (pinned by FuelCatalogTests):
// - tank litres 5…40, from a cited URL (`tankKind` official = manufacturer / official importer, published =
//   press / spec database); where sources disagree, the SMALLER tank (a bigger tank is the optimistic error);
// - seed km/L 10…45, a multiple of 0.5: the lowest independent test, else the minimum of the claims and
//   the class default, rounded DOWN to 0.5 km/L (class defaults: ≤ 300 cc 22.0 · 400–500 cc twin 19.0 ·
//   650–700 cc 17.0 · 800 cc 17.5 · 1000 cc 15.5 · unknown 15.5); `consumptionKind` .estimate ⇔ a class
//   default ("estimate: <rule>"), else the URL of the published figure;
// - the 450MT seeds at 20.5 km/L (published 4.5–4.8 L/100 km; never the optimistic 26 km/L of other apps);
// - `cfmoto-700cl-x` is searchable but in no dash-family candidate list (no pairing QR as a rule).
// Every figure was read from search-result text for the cited URL. Before a release that ships the catalog,
// open every tankSource (the press rows first: 700MT 18 L, 800NK Advanced, X-Cape 650, X-Cape 700,
// Seiemmezzo) and every consumptionSource, and check each seed is at or below the lowest real-riding figure
// on that page and on the other pages CATALOG.md cites for the row (docs/PRUEBA-EN-LA-MOTO.md release
// checklist).

import Foundation

extension FuelCatalog {
    static let rows: [FuelCatalogEntry] = [
        FuelCatalogEntry(
            id: "cfmoto-450mt", brand: .cfmoto, model: "450MT",
            aliases: ["Ibex 450"],
            marketNote: "2024+", fromYear: 2024, toYear: nil,
            tankL: 17.5, seedKmPerL: 20.5,
            tankKind: .official, tankSource: "https://www.cfmoto.com.au/model/450mt",
            consumptionKind: .published,
            consumptionSource: "https://www.motoplanete.us/cfmoto/11119/450-MT-2025/contact.html"),
        FuelCatalogEntry(
            id: "cfmoto-450sr", brand: .cfmoto, model: "450SR",
            aliases: ["450SR-S", "450SR TC", "450SS"],
            marketNote: "2023+", fromYear: 2023, toYear: nil,
            tankL: 14.0, seedKmPerL: 20.0,
            tankKind: .official, tankSource: "https://www.cfmoto.com.au/model/450sr-abs",
            consumptionKind: .published,
            consumptionSource: "https://www.autocar.co.nz/2023-cfmoto-450-sr-review"),
        FuelCatalogEntry(
            id: "cfmoto-450nk", brand: .cfmoto, model: "450NK",
            aliases: [],
            marketNote: "2023+", fromYear: 2023, toYear: nil,
            tankL: 14.0, seedKmPerL: 19.0,
            tankKind: .official, tankSource: "https://www.cfmoto.com.au/model/450nk-abs",
            consumptionKind: .published,
            consumptionSource: "https://www.bennetts.co.uk/bikesocial/reviews/bikes/cfmoto/450nk-2024-review"),
        FuelCatalogEntry(
            id: "cfmoto-450cl-c", brand: .cfmoto, model: "450CL-C",
            aliases: ["CL-C450"],
            marketNote: "2024+", fromYear: 2024, toYear: nil,
            tankL: 12.0, seedKmPerL: 19.0,
            tankKind: .official, tankSource: "https://medias.cfmoto.ca/download/1239/2026/22107/450cl-c_2026_en.pdf?lang=en",
            consumptionKind: .estimate,
            consumptionSource: "estimate: twin 400-500 cc class default 19.0 km/L (no independent test)"),
        FuelCatalogEntry(
            id: "cfmoto-675sr-r", brand: .cfmoto, model: "675SR-R",
            aliases: ["675SS"],
            marketNote: "2025+", fromYear: 2025, toYear: nil,
            tankL: 15.0, seedKmPerL: 16.5,
            tankKind: .official, tankSource: "https://medias.cfmoto.ca/download/1239/2026/19116/675ss_2026_en.pdf?lang=en",
            consumptionKind: .published,
            consumptionSource: "https://www.1000ps.com/en-gb/model/12901/cfmoto-675sr-r/2026"),
        FuelCatalogEntry(
            id: "cfmoto-675nk", brand: .cfmoto, model: "675NK",
            aliases: [],
            marketNote: "2025+", fromYear: 2025, toYear: nil,
            tankL: 15.0, seedKmPerL: 17.0,
            tankKind: .official, tankSource: "https://www.cfmoto.com.au/model/675nk",
            consumptionKind: .estimate,
            consumptionSource: "estimate: twin/triple 650-700 cc class default 17.0 km/L (no independent test)"),
        FuelCatalogEntry(
            id: "cfmoto-700mt-18l", brand: .cfmoto, model: "700MT",
            aliases: ["700MT Adventure"],
            marketNote: "MY2023-2024 (18 L)", fromYear: 2023, toYear: 2024,
            tankL: 18.0, seedKmPerL: 17.0,
            tankKind: .published, tankSource: "https://www.bennetts.co.uk/bikesocial/reviews/bikes/cfmoto/700mt-2023-review",
            consumptionKind: .published,
            consumptionSource: "https://www.motoplanete.us/cfmoto/10717/700-MT-2024/contact.html"),
        FuelCatalogEntry(
            id: "cfmoto-700mt-20l", brand: .cfmoto, model: "700MT",
            aliases: ["700MT Adventure"],
            marketNote: "MY2025+ (20 L)", fromYear: 2025, toYear: nil,
            tankL: 20.0, seedKmPerL: 17.0,
            tankKind: .official, tankSource: "https://www.cfmoto.com.au/model/700mt",
            consumptionKind: .published,
            consumptionSource: "https://www.motoplanete.us/cfmoto/10717/700-MT-2024/contact.html"),
        FuelCatalogEntry(
            id: "cfmoto-700cl-x", brand: .cfmoto, model: "700CL-X",
            aliases: ["700CL-X Heritage", "700CL-X Sport", "700CL-X Adventure"],
            marketNote: "2021+", fromYear: 2021, toYear: nil,
            tankL: 13.0, seedKmPerL: 18.0,
            tankKind: .official, tankSource: "https://www.cfmoto.com.au/model/700cl-x-heritage",
            consumptionKind: .published,
            consumptionSource: "https://www.bikesales.com.au/editorial/details/2022-cfmoto-700cl-x-heritage-review-132099/"),
        FuelCatalogEntry(
            id: "cfmoto-800mt", brand: .cfmoto, model: "800MT Sport / Touring",
            aliases: ["800MT Sport", "800MT Touring", "Ibex 800 S", "Ibex 800 T"],
            marketNote: "2021+", fromYear: 2021, toYear: nil,
            tankL: 19.0, seedKmPerL: 17.5,
            tankKind: .official, tankSource: "https://www.cfmoto.com.au/model/800mt-touring",
            consumptionKind: .published,
            consumptionSource: "https://www.racq.com.au/articles/car-reviews/cfmoto-800mt-touring-motorcycle-review"),
        FuelCatalogEntry(
            id: "cfmoto-800mt-explore", brand: .cfmoto, model: "800MT Explore",
            aliases: ["800MT Explore GT", "Ibex 800 E"],
            marketNote: "2023+", fromYear: 2023, toYear: nil,
            tankL: 19.0, seedKmPerL: 17.5,
            tankKind: .official, tankSource: "https://cfmotobenelux.be/en/model/800mt-explore",
            consumptionKind: .published,
            consumptionSource: "https://www.advrider.com/cfmoto-800mt-explore/"),
        FuelCatalogEntry(
            id: "cfmoto-800mt-x", brand: .cfmoto, model: "800MT-X",
            aliases: [],
            marketNote: "2025+", fromYear: 2025, toYear: nil,
            tankL: 22.5, seedKmPerL: 17.5,
            tankKind: .official, tankSource: "https://www.cfmoto.com.au/model/800mt-x",
            consumptionKind: .published,
            consumptionSource: "https://www.brm.co.nz/cfmoto-800mt-x-review-affordable-adventurer"),
        FuelCatalogEntry(
            id: "cfmoto-800nk", brand: .cfmoto, model: "800NK",
            aliases: ["800NK Sport"],
            marketNote: "2023+", fromYear: 2023, toYear: nil,
            tankL: 15.0, seedKmPerL: 17.5,
            tankKind: .official, tankSource: "https://medias.cfmoto.ca/download/770/2024/10258/2024_ibex-800nk-en.pdf?lang=en",
            consumptionKind: .published,
            consumptionSource: "https://motorcyclenews.com/bike-reviews/cf-moto/800nk-advanced"),
        FuelCatalogEntry(
            id: "cfmoto-800nk-advanced", brand: .cfmoto, model: "800NK Advanced",
            aliases: ["800NK Advanced TC"],
            marketNote: "2023+", fromYear: 2023, toYear: nil,
            tankL: 15.0, seedKmPerL: 17.5,
            tankKind: .published, tankSource: "https://motorcyclenews.com/bike-reviews/cf-moto/800nk-advanced",
            consumptionKind: .published,
            consumptionSource: "https://motorcyclenews.com/bike-reviews/cf-moto/800nk-advanced"),
        FuelCatalogEntry(
            id: "cfmoto-1000mt-x", brand: .cfmoto, model: "1000MT-X",
            aliases: [],
            marketNote: "2026+", fromYear: 2026, toYear: nil,
            tankL: 22.5, seedKmPerL: 15.5,
            tankKind: .official, tankSource: "https://www.cfmoto.com.au/model/1000mt-x",
            consumptionKind: .published,
            consumptionSource: "https://www.1000ps.com/en-gb/article/3014010/first-ride-review-of-the-new-cfmoto-1000-mt-x"),
        FuelCatalogEntry(
            id: "cfmoto-300sr", brand: .cfmoto, model: "300SR",
            aliases: ["300SS"],
            marketNote: "2020+", fromYear: 2020, toYear: nil,
            tankL: 12.0, seedKmPerL: 22.0,
            tankKind: .official, tankSource: "https://medias.cfmoto.ca/download/1239/2026/19108/300ss_2026_en.pdf?lang=en",
            consumptionKind: .estimate,
            consumptionSource: "estimate: single <=300 cc class default 22.0 km/L (published 30-32 km/L lab-like, no mixed-riding test)"),
        FuelCatalogEntry(
            id: "motomorini-x-cape-650", brand: .morini, model: "X-Cape 650",
            aliases: ["X-Cape 649", "Xcape 649", "X-Cape 650X", "X-Cape 650T"],
            marketNote: "2021-2024", fromYear: 2021, toYear: 2024,
            tankL: 18.0, seedKmPerL: 15.5,
            tankKind: .published, tankSource: "https://www.autocarindia.com/bikes/moto-morini/x-cape/650",
            consumptionKind: .published,
            consumptionSource: "https://www.bennetts.co.uk/bikesocial/reviews/bikes/moto-morini/x-cape-650-2022-review"),
        FuelCatalogEntry(
            id: "motomorini-x-cape-700", brand: .morini, model: "X-Cape 700",
            aliases: [],
            marketNote: "2025+", fromYear: 2025, toYear: nil,
            tankL: 17.5, seedKmPerL: 19.5,
            tankKind: .published, tankSource: "https://www.insella.it/news/velocita-max-potenza-peso-ecco-tutti-dati-della-moto-morini-x-cape-700-68729",
            consumptionKind: .published,
            consumptionSource: "https://www.insella.it/news/velocita-max-potenza-peso-ecco-tutti-dati-della-moto-morini-x-cape-700-68729"),
        FuelCatalogEntry(
            id: "motomorini-seiemmezzo", brand: .morini, model: "Seiemmezzo",
            aliases: ["Seiemmezzo STR", "Seiemmezzo SCR", "Seiemmezzo 650"],
            marketNote: "2022+", fromYear: 2022, toYear: nil,
            tankL: 15.0, seedKmPerL: 19.5,
            tankKind: .published, tankSource: "https://www.motoplanete.us/morini/10667/seiemmezzo-650-str-2024/contact.html",
            consumptionKind: .published,
            consumptionSource: "https://www.insella.it/prova/moto-morini-seiemmezzo-str-2023"),
    ]
}
