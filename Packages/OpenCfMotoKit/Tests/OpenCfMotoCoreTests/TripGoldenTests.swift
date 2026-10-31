// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden vectors from the UPSTREAM Kotlin TripModel.kt / TripGpx.kt (Locale.US, UTC) and a verbatim
// JVM copy of TripRouteThumb's geometry.
// Stats lines: <distance bits> <movingMs> <maxSpeed float bits> <distanceText (_ = space)> <duration> <avg> <max>.

import XCTest
@testable import OpenCfMotoCore

final class TripGoldenTests: XCTestCase {
    func testStatsMatchKotlin() {
        var n = 0
        for line in Self.stats.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            let t = Trip(id: "x", start: 0, end: 0, distanceMeters: Double(bitPattern: UInt64(f[0], radix: 16)!),
                         movingTimeMs: Int64(f[1])!, maxSpeedMs: Float(bitPattern: UInt32(f[2], radix: 16)!), points: [])
            XCTAssertEqual(t.distanceText, f[3].replacingOccurrences(of: "_", with: " "), String(line))
            XCTAssertEqual(t.durationText, f[4], String(line))
            XCTAssertEqual(t.avgKmh, Int(f[5])!, String(line))
            XCTAssertEqual(t.maxKmh, Int(f[6])!, String(line))
            n += 1
        }
        XCTAssertEqual(n, 69)
    }

    private var gpxTrip: Trip {
        Trip(id: "1717000000123", start: 1_717_000_000_123, end: Self.gpxEnd, distanceMeters: 4321, movingTimeMs: 60_000, maxSpeedMs: 25,
             points: Self.gpxPoints.map { TripPoint(lat: Double(bitPattern: $0.lat), lon: Double(bitPattern: $0.lon), timeMs: $0.time,
                                                    speedMs: Float(bitPattern: $0.speed)) })
    }

    func testGpxMatchesKotlin() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TripGpx.toXML(gpxTrip, locale: Locale(identifier: "en_US"), timeZone: utc), Self.gpxXML + "\n")
        XCTAssertEqual(TripGpx.suggestedFileName(gpxTrip, timeZone: utc), Self.gpxFileName)
    }

    private func poly(_ s: String) -> [(Float, Float)] {
        s.split(separator: " ").map { pair in
            let p = pair.split(separator: ",")
            return (Float(bitPattern: UInt32(p[0], radix: 16)!), Float(bitPattern: UInt32(p[1], radix: 16)!))
        }
    }

    func testThumbnailMatchesKotlin() {
        let g = TripThumbnail.geometry(points: gpxTrip.points, widthPx: 240, heightPx: 112)
        XCTAssertEqual(Float(g.strokeWidth), Self.thumbStroke)
        XCTAssertEqual(Float(g.dotRadius), Self.thumbRadius)
        let want = poly(Self.thumbPoly)
        XCTAssertEqual(g.polyline.count, want.count)
        for (p, w) in zip(g.polyline, want) {
            XCTAssertEqual(Float(p.x), w.0)
            XCTAssertEqual(Float(p.y), w.1)
        }
        let big = (0 ..< 1000).map { i in TripPoint(lat: 45.0 + Double(i) * 1e-4, lon: 25.0 + sin(Double(i) / 50.0) * 0.01, timeMs: Int64(i), speedMs: 1) }
        let gb = TripThumbnail.geometry(points: big, widthPx: 333, heightPx: 150)
        XCTAssertEqual(Float(gb.strokeWidth), Self.bigThumbStroke)
        XCTAssertEqual(Float(gb.dotRadius), Self.bigThumbRadius)
        let wantBig = poly(Self.bigThumbPoly)
        XCTAssertEqual(gb.polyline.count, wantBig.count)
        var maxErr: Float = 0
        for (p, w) in zip(gb.polyline, wantBig) {
            maxErr = max(maxErr, abs(Float(p.x) - w.0), abs(Float(p.y) - w.1))
        }
        XCTAssertLessThanOrEqual(maxErr, 1e-4)   // libm sin/cos may differ from the JVM in the last ulp
    }
}

extension TripGoldenTests {
    static let stats = #"""
40c86a0000000000 360000 41c80000 12.50_km 00:06:00 125 90
40c81ccccccccccd 1234567 4205999a 12.35_km 00:20:34 35 120
40c81c8000000000 0 0 12.35_km 00:00:00 0 0
0 999 3f4ccccd 0.00_km 00:00:00 0 2
4058f9999999999a 90061000 4231c28f 0.10_km 25:01:01 0 159
408f680000000000 15000 3a83126f 1.01_km 00:00:15 241 0
419d6f3454000000 3600000 42c7fae1 123456.79_km 01:00:00 123456 359
402e000000000000 -5 4144cccd 0.02_km 00:00:00 0 44
4014000000000000 7 40f66666 0.01_km 00:00:00 2571 27
41042d4d13217d04 8739942 423a22e0 165.29_km 02:25:39 68 167
410afe6a14bb3015 5200596 422f59d0 221.13_km 01:26:40 153 157
410d6b7e21f22a15 15301490 420c1f66 241.01_km 04:15:01 56 126
410d3fa5a0374739 2438182 4265c889 239.60_km 00:40:38 353 206
410bdce8aa1dcb82 6715638 419f5744 228.25_km 01:51:55 122 71
410e5a85d844ea1d 4343162 40cb95bb 248.66_km 01:12:23 206 22
409c33412f13b9cc 2017948 42669b3a 1.80_km 00:33:37 3 207
40f99080c48bd063 2500567 41986b3e 104.71_km 00:41:40 150 68
4104bf34cd224ccc 2069380 4115a35d 169.96_km 00:34:29 295 33
410716c96c2cfc89 15759127 41cf4233 189.15_km 04:22:39 43 93
40f577e8461cd71b 7346202 41db048c 87.93_km 02:02:26 43 98
40f81d6d3d9689ac 1736702 41b75b83 98.77_km 00:28:56 204 82
410e6ef3eebb938c 15600467 41e0ad30 249.31_km 04:20:00 57 101
40e22196f4034f9e 13459650 413cbc62 37.13_km 03:44:19 9 42
40d956fdf65bb249 159184 422cfe49 25.95_km 00:02:39 586 155
40c1b447ef77f3e7 10012607 426cf4d1 9.06_km 02:46:52 3 213
40d85f3692b40564 1920273 425ce8b8 24.96_km 00:32:00 46 198
40faedfcf405beab 15279116 41b89403 110.30_km 04:14:39 25 83
40fe2195fc5ffeaf 2581563 42532340 123.42_km 00:43:01 172 190
4107342b0844688f 10109895 41ddaca8 190.09_km 02:48:29 67 99
40e6b3d988010e7f 655071 41c16b01 46.49_km 00:10:55 255 87
40f36b4f6e34cd06 18886209 42483c2b 79.54_km 05:14:46 15 180
410adf8b6f1599cf 7938436 421b7598 220.15_km 02:12:18 99 139
410222fbd72a666b 14827705 4231ac8b 148.58_km 04:07:07 36 159
410ae4aa638f1c79 4927481 42070994 220.31_km 01:22:07 160 121
410551f61be6a604 7245883 425f308a 174.65_km 02:00:45 86 200
40d6dd6e0b4f8d48 4510834 3fca3d0a 23.41_km 01:15:10 18 5
40f2df952dda46bb 5084021 42343741 77.31_km 01:24:44 54 162
410b25a2c7412a31 6162671 4114a570 222.39_km 01:42:42 129 33
40f5129cae8a5940 15722542 4202e7bc 86.31_km 04:22:02 19 117
40edc378b543e4a2 19566731 41f5cec4 60.96_km 05:26:06 11 110
41021457808f2532 3353806 41467256 148.11_km 00:55:53 158 44
40f8212d4c88b2f1 3924255 4258383b 98.83_km 01:05:24 90 194
4106c6009ee003c0 6178586 4268f747 186.56_km 01:42:58 108 209
40e040c18addd0de 3764258 426614b6 33.29_km 01:02:44 31 207
40e6f98bc19e64f9 3135438 425d3248 47.05_km 00:52:15 54 199
40ece8e04aedfc64 14832009 4268976f 59.21_km 04:07:12 14 209
40e658739a776009 19496708 424abcb4 45.76_km 05:24:56 8 182
40e51a97f0a0d128 8646461 40f2d4ad 43.22_km 02:24:06 17 27
410823b007201807 2378000 422341f0 197.75_km 00:39:38 299 146
4103fa34cb050ac3 14828237 42250cb3 163.65_km 04:07:08 39 148
40ebffc272d97a87 5845528 40eb906e 57.34_km 01:37:25 35 26
40e50336e89d1d31 16884327 40ebf209 43.03_km 04:41:24 9 26
40e18dd173003b40 4787207 418903f0 35.95_km 01:19:47 27 61
410d3923c4a7cdb4 2946998 4248da5b 239.40_km 00:49:06 292 180
4100df7e2bd4d747 16082225 42070e5f 138.22_km 04:28:02 30 121
4100c0f7ba8798a0 18022830 42249bb3 137.25_km 05:00:22 27 148
410759b5a834270c 12249586 41c16013 191.29_km 03:24:09 56 87
410243822b064ab4 9661883 420f50a5 149.62_km 02:41:01 55 128
40efdb2857cc254d 980945 418b3eaf 65.24_km 00:16:20 239 62
4102d35bda0b4b62 16873535 41dc078b 154.22_km 04:41:13 32 99
40ef2ea46a82a298 4144268 41f1b242 63.86_km 01:09:04 55 108
4106afa14d092b2b 17067759 412d7807 185.84_km 04:44:27 39 39
40f9f4bb048b6dca 4649355 41f686e8 106.32_km 01:17:29 82 110
40ff743a02775266 16851250 3f99cd81 128.84_km 04:40:51 27 4
40d8229f108dad14 17794335 408a93a4 24.71_km 04:56:34 5 15
41059323235a0775 15305533 41de2cd3 176.74_km 04:15:05 41 99
40dc9ca3e60bb7d1 15106645 423a79fa 29.30_km 04:11:46 6 167
40f04f50d08a42d4 16035592 41558a4d 66.81_km 04:27:15 14 48
40f33e3312d53522 4796388 411c9b42 78.82_km 01:19:56 59 35
"""#
    static let gpxPoints: [(lat: UInt64, lon: UInt64, time: Int64, speed: UInt32)] = [
    (0x404636b3e1b6f7e2, 0x403a1a17b78bc1b3, 1717000000780, 0x3f751734),
    (0x404636c150ce5f8e, 0x403a1a5883db5a8e, 1717000002287, 0x41c4b88e),
    (0x404636d00c859d2c, 0x403a1a4510bb8630, 1717000005099, 0x418878bf),
    (0x404636b90da9c6eb, 0x403a1a4743ca8c1a, 1717000007351, 0x41b54a4b),
    (0x404636d8a35cc234, 0x403a1a65aab369f4, 1717000008564, 0x3eed5e3a),
    (0x404636cf63cf22fe, 0x403a1aa4125a27e4, 0, 0x402d69fd),
    (0x404636da85e64e31, 0x403a1a96f6ac1a81, 1717000014024, 0x41ca9b04),
    (0x404636bf2abee765, 0x403a1abce5d65465, 1717000015547, 0x404a9985),
    (0x404636af5967ad04, 0x403a1aa505f9d9f5, 1717000017169, 0x419fd0f8),
    (0x404636be89915681, 0x403a1ae235cb21b8, 1717000018220, 0x41765499),
    (0x404636d9d8aecd45, 0x403a1ac30c86a004, 1717000020086, 0x40f60676),
    (0x404636bb7d7c06eb, 0x403a1af2616c64ef, 1717000022213, 0x40258819),
    (0x404636d4e3e35f6a, 0x403a1acfd5c2bc9b, 1717000024430, 0x419f04d6),
    (0x404636ede5f8c115, 0x403a1aa4cbef2749, 1717000025812, 0x41b621bb),
    (0x404637071c8af76e, 0x403a1ac8a52e880d, 1717000028025, 0x41882353),
    (0x404636eb49485783, 0x403a1adf322f0e4b, 1717000030795, 0x41a5e9b4),
    (0x4046370b53155c3f, 0x403a1aba4563fa8c, 1717000033080, 0x41b61c24),
    (0x404636f55ac92c4d, 0x403a1a8af6909c9a, 1717000035142, 0x40c36a43),
    (0x404636d77d2c7734, 0x403a1a64e4d50cd7, 1717000037105, 0x414397a4),
    (0x404636bd3f2b6697, 0x403a1a5b7c3991e3, 1717000037995, 0x415418ac),
    (0x404636bc512f6007, 0x403a1a363068329f, 1717000039244, 0x41e4513f),
    (0x404636c00481b9cc, 0x403a19f98670f5a8, 1717000041193, 0x41cba3ba),
    (0x404636a29d01ce9a, 0x403a19c09ffcb5ec, 1717000043201, 0x41b6d3bb),
    (0x40463694faccbd37, 0x403a19803cf4b71b, 1717000045224, 0x41809f6c),
    (0x4046368e92bd14ea, 0x403a19a00d0d7b55, 1717000046499, 0x414edf40),
    (0x404636a19833f330, 0x403a19dde0b9a955, 1717000049256, 0x418e7447),
    (0x404636a5c99a4489, 0x403a19f8d8634a52, 1717000051635, 0x41b965c8),
    (0x404636bec73e38d3, 0x403a19e5ac52c807, 1717000053766, 0x414e5a94),
    (0x404636db9110fc23, 0x403a1a12004b7fa1, 1717000056685, 0x403af223),
    (0x404636e4279af6da, 0x403a19e124f2ea30, 1717000056978, 0x41839627),
    (0x40463701e7fda75d, 0x403a19c6ad775fad, 1717000058378, 0x40b24c57),
    (0x4046371972a1455d, 0x403a19860c1d43b4, 1717000058691, 0x40d75f23),
    (0x404636feec13244b, 0x403a195e6a5811c3, 1717000060088, 0x41641713),
    (0x40463719471f9678, 0x403a197a878ab47b, 1717000061911, 0x40309236),
    (0x404636fd3e7c46e0, 0x403a19769633f4e2, 1717000061928, 0x3f4ffa41),
    (0x404636e0456b5b21, 0x403a19a09d507f3f, 1717000062939, 0x4082a5ba),
    (0x404636db0c3aaa91, 0x403a196fcece5d17, 1717000064510, 0x41703ba3),
    (0x404636dc2b32a6d7, 0x403a19620e42877c, 1717000064919, 0x41e9f4e5),
    (0x404636d88f920f21, 0x403a19314ce05de6, 1717000067634, 0x41743e39),
    (0x404636bf5b683f49, 0x403a195f4b02754a, 1717000068884, 0x41972d00),
    ]
    static let gpxEnd: Int64 = 1717000069384
    static let gpxFileName = "opencfmoto_trip_20240529_1626.gpx"
    static let gpxXML = """
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="OpenCfMoto" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <name>OpenCfMoto Wed 29 May 2024 16:26 – 16:27</name>
    <time>2024-05-29T16:26:40Z</time>
  </metadata>
  <trk>
    <name>OpenCfMoto Wed 29 May 2024 16:26 – 16:27</name>
    <type>motorcycle</type>
    <trkseg>
      <trkpt lat="44.427365" lon="26.101924">
        <time>2024-05-29T16:26:40Z</time>
      </trkpt>
      <trkpt lat="44.427775" lon="26.102913">
        <time>2024-05-29T16:26:42Z</time>
      </trkpt>
      <trkpt lat="44.428224" lon="26.102616">
        <time>2024-05-29T16:26:45Z</time>
      </trkpt>
      <trkpt lat="44.427522" lon="26.102650">
        <time>2024-05-29T16:26:47Z</time>
      </trkpt>
      <trkpt lat="44.428486" lon="26.103114">
        <time>2024-05-29T16:26:48Z</time>
      </trkpt>
      <trkpt lat="44.428204" lon="26.104066">
      </trkpt>
      <trkpt lat="44.428544" lon="26.103866">
        <time>2024-05-29T16:26:54Z</time>
      </trkpt>
      <trkpt lat="44.427709" lon="26.104445">
        <time>2024-05-29T16:26:55Z</time>
      </trkpt>
      <trkpt lat="44.427226" lon="26.104081">
        <time>2024-05-29T16:26:57Z</time>
      </trkpt>
      <trkpt lat="44.427690" lon="26.105014">
        <time>2024-05-29T16:26:58Z</time>
      </trkpt>
      <trkpt lat="44.428523" lon="26.104539">
        <time>2024-05-29T16:27:00Z</time>
      </trkpt>
      <trkpt lat="44.427597" lon="26.105261">
        <time>2024-05-29T16:27:02Z</time>
      </trkpt>
      <trkpt lat="44.428372" lon="26.104734">
        <time>2024-05-29T16:27:04Z</time>
      </trkpt>
      <trkpt lat="44.429135" lon="26.104077">
        <time>2024-05-29T16:27:05Z</time>
      </trkpt>
      <trkpt lat="44.429905" lon="26.104624">
        <time>2024-05-29T16:27:08Z</time>
      </trkpt>
      <trkpt lat="44.429055" lon="26.104968">
        <time>2024-05-29T16:27:10Z</time>
      </trkpt>
      <trkpt lat="44.430033" lon="26.104405">
        <time>2024-05-29T16:27:13Z</time>
      </trkpt>
      <trkpt lat="44.429363" lon="26.103683">
        <time>2024-05-29T16:27:15Z</time>
      </trkpt>
      <trkpt lat="44.428451" lon="26.103102">
        <time>2024-05-29T16:27:17Z</time>
      </trkpt>
      <trkpt lat="44.427650" lon="26.102958">
        <time>2024-05-29T16:27:17Z</time>
      </trkpt>
      <trkpt lat="44.427622" lon="26.102389">
        <time>2024-05-29T16:27:19Z</time>
      </trkpt>
      <trkpt lat="44.427735" lon="26.101464">
        <time>2024-05-29T16:27:21Z</time>
      </trkpt>
      <trkpt lat="44.426838" lon="26.100595">
        <time>2024-05-29T16:27:23Z</time>
      </trkpt>
      <trkpt lat="44.426421" lon="26.099613">
        <time>2024-05-29T16:27:25Z</time>
      </trkpt>
      <trkpt lat="44.426226" lon="26.100098">
        <time>2024-05-29T16:27:26Z</time>
      </trkpt>
      <trkpt lat="44.426806" lon="26.101042">
        <time>2024-05-29T16:27:29Z</time>
      </trkpt>
      <trkpt lat="44.426934" lon="26.101453">
        <time>2024-05-29T16:27:31Z</time>
      </trkpt>
      <trkpt lat="44.427697" lon="26.101161">
        <time>2024-05-29T16:27:33Z</time>
      </trkpt>
      <trkpt lat="44.428576" lon="26.101837">
        <time>2024-05-29T16:27:36Z</time>
      </trkpt>
      <trkpt lat="44.428838" lon="26.101092">
        <time>2024-05-29T16:27:36Z</time>
      </trkpt>
      <trkpt lat="44.429746" lon="26.100688">
        <time>2024-05-29T16:27:38Z</time>
      </trkpt>
      <trkpt lat="44.430464" lon="26.099702">
        <time>2024-05-29T16:27:38Z</time>
      </trkpt>
      <trkpt lat="44.429655" lon="26.099097">
        <time>2024-05-29T16:27:40Z</time>
      </trkpt>
      <trkpt lat="44.430459" lon="26.099526">
        <time>2024-05-29T16:27:41Z</time>
      </trkpt>
      <trkpt lat="44.429603" lon="26.099466">
        <time>2024-05-29T16:27:41Z</time>
      </trkpt>
      <trkpt lat="44.428719" lon="26.100107">
        <time>2024-05-29T16:27:42Z</time>
      </trkpt>
      <trkpt lat="44.428560" lon="26.099362">
        <time>2024-05-29T16:27:44Z</time>
      </trkpt>
      <trkpt lat="44.428594" lon="26.099152">
        <time>2024-05-29T16:27:44Z</time>
      </trkpt>
      <trkpt lat="44.428484" lon="26.098409">
        <time>2024-05-29T16:27:47Z</time>
      </trkpt>
      <trkpt lat="44.427715" lon="26.099110">
        <time>2024-05-29T16:27:48Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>
"""
    static let thumbStroke: Float = Float(bitPattern: 0x40800000)
    static let thumbRadius: Float = Float(bitPattern: 0x40a147ae)
    static let thumbPoly = "42f26fd4,42954ff3 4306a741,4285b603 43029ee8,42693391 430313a6,428f4e67 43096152,42554062 431651a2,426abb6e 431399e2,4250df9b 431b7759,428834d1 43168425,429a9376 432333ce,4288efff 431cbdd6,425271ef 43268e18,428c79f0 431f647e,425df4ed 4316781c,4223defd 431de6e0,41d29e49 432293d3,4229f022 431aebed,41bf0c18 43111ced,42128d71 4309384b,4257ebb0 430744e8,428a6fb3 42ff129d,428b8415 42e5eacc,428737ec 42ce5286,42a95de0 42b39f80,42b9332e 42c0d09d,42c0a3d7 42da73e1,42aa8cc2 42e5a2a0,42a5ae2e 42ddaf65,4288a85f 42f01110,424e7311 42dbcea3,423a8095 42d0d50c,41eacc72 42b6082e,417ae148 42a59908,41f8a919 42b1417f,417c757d 42af9ef4,42003a58 42c10c70,424385c0 42accf56,424fa79a 42a71b78,424d0d12 4292e3cf,42556e5a 42a5f631,4287fc4e"
    static let bigThumbStroke: Float = Float(bitPattern: 0x40a80000)
    static let bigThumbRadius: Float = Float(bitPattern: 0x40d80001)
    static let bigThumbPoly = "43267fd6,43010000 43274309,4300759f 43282a88,42ff9f23 4328e6e5,42fe8a61 4329c0a9,42fd3e45 432a6d1b,42fc2983 432b2ea4,42fadd68 432bdeee,42f9914c 432c62d5,42f87c8a 432ced21,42f7306f 432d4e61,42f61bad 432dac05,42f4cf91 432de5ed,42f3bad0 432e1265,42f26eb4 432e22fb,42f12298 432e1b52,42f00dd6 432df877,42eec1bb 432dc65f,42edacf9 432d71c0,42ec60dd 432d038e,42eb14c2 432c9554,42ea0000 432bfc9f,42e8b3e4 432b6dd4,42e79f23 432ab1f8,42e65307 432a097f,42e53e45 4329338a,42e3f22a 432853a1,42e2a60e 432793c3,42e1914c 4326aa0d,42e04530 4325e6b0,42df306f 4324fe70,42dde453 43241bbc,42dc9837 43236567,42db8376 4322953d,42da375a 4321f2aa,42d92298 43213f13,42d7d67d 4320b817,42d6c1bb 432029bc,42d5759f 431fb2b6,42d42983 431f6297,42d314c2 431f1a86,42d1c8a6 431ef33d,42d0b3e4 431edd9a,42cf67c9 431ee10b,42ce5307 431efee3,42cd06eb 431f385c,42cbbad0 431f7cc5,42caa60e 431fe678,42c959f2 43205130,42c84530 4320e604,42c6f915 43218f78,42c5acf9 43222aae,42c49837 4322f36b,42c34c1c 4323a4d0,42c2375a 43248329,42c0eb3e 4325422e,42bfd67d 43262b6d,42be8a61 432715e2,42bd3e45 4327d7c2,42bc2983 4328bbb4,42badd68 43297383,42b9c8a6 432a45f5,42b87c8a 432b0a82,42b7306f 432ba1a3,42b61bad 432c458b,42b4cf91 432cbdfd,42b3bad0 432d3959,42b26eb4 432d8d4d,42b159f2 432dda2b,42b00dd6 432e0bf6,42aec1bb 432e203f,42adacf9 432e1ed6,42ac60dd 432e0836,42ab4c1c 432dd3aa,42aa0000 432d9338,42a8eb3e 432d2e11,42a79f23 432cb050,42a65307 432c3607,42a53e45 432b901d,42a3f22a 432af780,42a2dd68 432a316d,42a1914c 43295dc0,42a04530 4328a528,429f306f 4327c090,429de453 4326fe68,429ccf91 432613eb,429b8376 4325518e,429a6eb4 43246c79,42992298 43238f09,4297d67d 4322dea5,4296c1bb 43221761,4295759f 43217d9b,429460dd 4320d61e,429314c2 4320437b,4291c8a6 431fdabe,4290b3e4 431f7392,428f67c9 431f315e,428e5307 431efaa3,428d06eb 431ee229,428bf22a 431ede82,428aa60e 431ef6f3,428959f2 431f2089,42884530 431f6b49,4286f915 431fbd8b,4285e453 432036fe,42849837 4320c795,42834c1c 43215042,4282375a 432205a6,4280eb3e 4322a984,427facf9 43237af7,427d14c2 43243221,427aeb3e 4325158a,42785307 4325fe29,4275bad0 4326c194,4273914c 4327ab0b,4270f915 43286a73,426ecf91 43294980,426c375a 4329fbab,426a0dd6 432ac58e,4267759f 432b7fb7,4264dd68 432c0ce4,4262b3e4 432ca371,42601bad 432d0fb8,425df22a 432d7b6a,425b59f2 432dcd65,4258c1bb 432dfd37,42569837 432e1d47,42540000 432e2296,4251d67d 432e0f2f,424f3e45 432de9bb,424d14c2 432da3cc,424a7c8a 432d4394,4247e453 432ce04c,4245bad0 432c53ba,42432298 432bce19,4240f915 432b1bf6,423e60dd 432a58d9,423bc8a6 4329ab4e,42399f23 4328d083,423706eb 43281389,4234dd68 43272b9b,42324530 4326684d,42301bad 43257e6c,422d8376 4324983d,422aeb3e 4323dda5,4228c1bb 432306c7,42262983 43225d5e,42240000 4321a02c,422167c9 4321101d,421f3e45 432075b6,421ca60e 431ff18c,421a0dd6 431f95c8,4217e453 431f3f13,42154c1c 431f0b2d,42132298 431ee61b,42108a61 431edd05,420df22a 431eeaee,420bc8a6 431f1532,4209306f 431f4d51,420706eb 431fa8e6,42046eb4 43200886,42024530 43209102,41ff59f2 43212f56,41fa2983 4321c254,41f5d67d 43228297,41f0a60e 43232e26,41ec5307 43240712,41e72298 4324e918,41e1f22a 4325aa0e,41dd9f23 43269442,41d86eb4 43275758,41d41bad 43283e70,41ceeb3e 4328fa3f,41ca9837 4329d317,41c567c9 432a9fb0,41c0375a 432b3eb5,41bbe453 432bed5f,41b6b3e4 432c6fc2,41b260dd 432cf813,41ad306f 432d6891,41a80000"
}
