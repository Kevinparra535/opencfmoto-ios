# Session Lifecycle, Networking, Wi-Fi Join, QR Pairing, Discovery and Recovery — iOS implementation spec

Source of truth: OpenCfMoto Android **2.0.18** (`versionCode 77`, `app/build.gradle.kts:22-23`), repo HEAD
`0abbe2a`. This spec lets a Swift engineer re-implement everything between *"the rider has a pairing QR"*
and *"frames are flowing to the dash"* — plus how the link is kept alive, recovered, remembered and
logged — **without reading the Kotlin**.

The iOS app renders its own dash UI, encodes H.264 with VideoToolbox and streams it over PXC. On
Android the closest analogue of that is the **Map / GPX ("own content") path** and the **Mirror path**,
which skip the Android-Auto gating. Android-Auto-only orchestration (AA self-mode, the AA "park" of the
transcoder) is described only where it carries timing or recovery knowledge.

Sibling specs (same folder) — this spec does **not** repeat their wire details:

| Topic | Spec |
|---|---|
| CmdBaseHead codec, :10922 handshake, CLIENT_INFO, CHECK_SN, notify burst, profiles, clock | `control-plane.md` |
| :10921/:10920 ReqBase media plane, frame pull (114), H.264 rules, 9 s media budget | `media-video.md` |

Where this spec restates a fact owned by a sibling (probe bytes, reconnect loop), the values are
identical; where it adds nuance (e.g. §6.4 "budget exhausted" behaviour) that nuance is authoritative.

---

## 0. Conventions

**Citations.** `File.kt:N` = `app/src/main/java/dev/zanderp/opencfmoto/File.kt` line `N` (or `N-M`).
`test/File.kt:N` = `app/src/test/java/dev/zanderp/opencfmoto/File.kt`. Docs: `01-REVERSE-ENGINEERING.md:N`
(= `docs/01-REVERSE-ENGINEERING.md`), `README.md:N`, `SUPPORTED-BIKES.md:N`, `strings.xml:N`
(= `app/src/main/res/values/strings.xml`).

**Status tags** (same scheme as `control-plane.md`):

| Tag | Meaning |
|---|---|
| **V-HW** | Confirmed on real hardware: `docs/01` (declared ground truth), or a field result quoted in docs/README/code comments. |
| **V-CODE** | What the shipping 2.0.18 code does with default settings. Field-proven only insofar as the app works on the bikes in `SUPPORTED-BIKES.md`. |
| **I** | INFERRED — from code reading, comments or analysis here; never explicitly confirmed. Includes all iOS recommendations. |
| **X** | EXPERIMENTAL — behind a tester toggle, flagged experimental/"in progress" in code or docs. |
| **D** | DERIVED — test vector computed for this spec by re-running the exact Kotlin algorithm (faithful Java port run on JDK 21; hashes cross-checked in Python). Not a field capture. |
| **GAP** | Android behaviour that is missing/buggy/racy; iOS should handle it deliberately (recommendation given). |

Strings in `"…"` are verbatim. Several Android strings contain U+2011 NON-BREAKING HYPHEN in `Wi‑Fi`
(e.g. `EasyConnProber.kt:183`, `WifiGate.kt:48`); others use ASCII `Wi-Fi`. Copy verbatim only if
byte-exact log parity matters.

---

## 1. Architect's summary (read this first)

1. **The phone is the TCP server.** Join the dash Wi-Fi, listen on **10922, 10921, 10920** (bound to the
   phone's IPv4 on the bike network), send **one** probe frame to **bike:10930**, get `{"status":true}`,
   close; the dash then **connects back** (typically 4 sockets: 2× :10922, 1× :10921, 1× :10920).
   **V-HW** (`01-REVERSE-ENGINEERING.md:38-54`).
2. **The only transport iOS can use is "join the dash's Wi-Fi as a normal WPA2 client".** Android also
   has Wi-Fi Direct P2P (MAC/WPS join) and phone-hotspot modes. A `DIRECT-…` Wi-Fi-Direct group *was*
   joined as a plain client on the 1000 MT-X (**V-HW**, `01-REVERSE-ENGINEERING.md:207-211`); some other
   group owners (CL-C450) reportedly refuse that (`BikeWifiP2p.kt:26-29`, `README.md:671`) → possibly
   unreachable from iOS.
3. **QR → `ssid`/`pwd`** (plus `action`, `mac`, `modelid`, `name`). Six formats (§2). The
   Android/iOS("CarPlay") QR variants are **not** distinguished by the code; field reports say the iOS QR
   carries the same Wi-Fi and works with this protocol (`README.md:240-242, 670`).
4. **Addressing:** phone IP = IPv4 of the Wi-Fi interface; bike IP = default gateway, else
   `(ip & mask) | 1`, else first DNS server; Bonjour `_EasyConn._tcp` result preferred for the probe
   target. Known bikes: `192.168.0.1` (SoftAP), `192.168.49.1` (Wi-Fi Direct GO), `192.168.4.1` (Yunmo).
5. **Discovery ladder (first connect):** Bonjour (≤12 s) → `gateway:10930` ×5 → TCP scan 10915–10935 →
   Yunmo :8200 (X) → log-only scan → ERROR. Probe attempt = 3 s connect + 5 s read, sleep `750 ms × n`.
6. **Recovery:** all bike sockets closed → re-probe loop (20 attempts, backoff `min(500+500n, 4000) ms`,
   then `+2500 ms` wait each); watchdog every **5 s**: no frame for **>8 s** while STREAMING → drop
   sockets & re-probe (≥20 s apart); ERROR → re-arm every ≥20 s. PXC heartbeat **every 2 s on both
   :10922 sockets** (800NK drops after ~7 s of silence). Dash drops media after **~9 s** without a frame.
7. **Wi-Fi re-join after ignition cycles:** first re-request **300 ms** after loss, then
   `min(2500×(n−1), 15000) ms`, each request times out after **12 s** (first join: **90 s**, retry every
   **4 s**). Re-acquired Wi-Fi ⇒ full prober restart (rebind listeners + fresh probe).
8. **Grace before parking** (AA path only) is **180 s** in code (README still says "~1 minute" — stale).
   The own-content Map path **never parks**.
9. **Persisted per bike:** the raw QR string (contains the PSK), display name, photo, winning transport
   per SSID, learned dash canvas `"<w>x<h>"` per SSID; per-bike settings namespaced by
   `"b" + hex(javaHashCode(raw))`. Nothing about IPs/endpoints is persisted.
10. **Several Android gaps** iOS should fix: no connect-back timeout; no retry if the very first
    connection never happened; ERROR after reconnect-budget exhaustion is only set on a *later* close
    event; stale worker threads after stop→start; redaction leaks the password of Morini/Thinkerride QRs;
    re-scanning a bike creates a duplicate garage entry (`sn` nonce). Details in §6, §8, §9, §12.

---

## 2. Pairing input: QR codes and manual entry

### 2.1 Where the QR comes from

- The dash's **phone-connection / MotoPlay / EasyConnect** screen shows a pairing QR; "No QR → this app
  cannot join that dash" (`SUPPORTED-BIKES.md:10-11`, `README.md:190-193`). **V-HW**
- The dash should **stay on that screen** while connecting: the EasyConn endpoint is reported "offline"
  otherwise — ERROR detail `"Bike Wi‑Fi is up but EasyConn is offline — keep the pairing QR open on the dash"`
  (`strings.xml:550`, used at `EasyConnProber.kt:442-445`); README: "Make sure the dash is on its
  phone-connection screen" (`README.md:674`). **V-CODE** (that :10930 only listens while that screen is
  shown is **I**).
- Many dashes toggle between an **Android QR** and an **iOS (CarPlay) QR**. Toggling "restarts the hotspot";
  "scanning the **iOS QR** is fine — often works when the Android one is flaky" (`README.md:670`);
  "switch the dash to the **iOS / CarPlay QR** and scan that instead (same Wi‑Fi; often more reliable)"
  (`README.md:240-242`); scanner hint `"…If it won't scan — try the iOS / CarPlay QR, or enter Wi‑Fi manually (TRK)."`
  (`strings.xml:272`). **V-HW (field)**. Brands confirmed via the iOS/Apple QR with the Android
  protocol: Zontes 350E ("use the Apple QR; force-stop Carbit", `README.md:147`), Voge DS900X
  (`SUPPORTED-BIKES.md:65`), QJ SRK800RR (`SUPPORTED-BIKES.md:77`, `SHOWCASE.md:139`).
- **No raw sample of an iOS QR exists in the repo.** The parser has no iOS-specific branch, so the iOS QR
  must parse as one of the formats below (most likely format A). **I** — capture one (§13).
- Non-pairing QRs riders scan by mistake (handled by failure hints, §2.11): Carbit **app-download** QR
  (`carbit.com` + `downsdk`, no `ssid=`), **vehicle-info** QR (`code:…engine:…vin:…color:…`), Morini vehicle
  QR without `Wifi=` (`SUPPORTED-BIKES.md:96`), Kove "download KOVE APP" (`SUPPORTED-BIKES.md:108`).

### 2.2 Data model and parser pipeline — V-CODE

```
QrData(ssid: String, pwd: String, auth: String?, mac: String?, name: String?,
       action: Int, modelId: String?, sn: String?, channel: String?)        // QrData.kt:27-37
supportsAp           = (action & 1) != 0 || (action & 2) != 0                  // QrData.kt:38
supportsP2p          = (action & 8) != 0                                       // QrData.kt:39
supportsPhoneHotspot = (action & 128) != 0 || (ssid.isBlank() && !mac.isNullOrBlank())  // QrData.kt:41-42
```

`QrData.parse(raw)` (`QrData.kt:45-53`):
1. `t = raw.trim()` (Kotlin `trim()` = strips Unicode whitespace: `Character.isWhitespace || isSpaceChar`);
   empty → `nil`.
2. Try, in order, returning the first non-nil: **A** `parseCarbit` → **C** `parseCarbitToken` →
   **D** `parseMotoMorini` → **E** `parseThinkerride`. Otherwise `nil`.

`parseCarbit` runs first on *every* input (including Morini/Thinkerride URLs); it returns nil for those
because they carry neither `ssid=` nor `bm=`. After a successful parse `ssid` is **never empty** (formats B/C
synthesize one). `pwd` may be `""` (phone-hotspot formats only).

Downstream use of the fields (**V-CODE**): `ssid`+`pwd` → Wi-Fi join; `mac` → Wi-Fi-Direct MAC join and the
phone-hotspot dialog; `modelId` (+`ssid` prefix, `action` bit 3) → early bike-profile guess
(`BikeProfile.kt:188-205`); `name` → display name; `sn` → logged only; `auth` and `channel` → parsed but
**never used** (grep: no reader). The QR `auth` value is ignored: the join is always WPA2-PSK (§3.2).

### 2.3 Format A — Carbit / EasyConnect URL (the common case) — V-HW / V-CODE

Verified example (`01-REVERSE-ENGINEERING.md:26-30`, wrapped there for width — it is one line):

```
http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457
```

Host and path are irrelevant; only the query matters. Field semantics (**V-HW**, `01-REVERSE-ENGINEERING.md:32-36`):
`ssid`/`pwd`/`auth`/`mac`/`name` are **stable across scans** (the dash AP credentials); `sn` is a **random
nonce that changes on every QR** and is not used by the connection flow; `action` is a capability bitmask
(§2.4).

| Key (case-insensitive) | Type | Meaning / use | Source |
|---|---|---|---|
| `modelid` | string | dash model id → early profile guess (§2.15) | `QrData.kt:78` |
| `sn` | string | per-QR nonce; logged only | `QrData.kt:79`, `01-REVERSE-ENGINEERING.md:33` |
| `action` | int | capability bitmask (§2.4); missing/non-int → 0 | `QrData.kt:61` |
| `ssid` | string | dash Wi-Fi SSID (trimmed) | `QrData.kt:63` |
| `pwd` | string | WPA2 passphrase (**not** trimmed) | `QrData.kt:64` |
| `auth` | string | e.g. `wpa2-psk`, `WPA2` — ignored | `QrData.kt:74` |
| `mac` | MAC | dash MAC, normalized by `formatMac` (§2.10) | `QrData.kt:62` |
| `bm` | MAC | MAC on phone-hotspot QRs (likely "Bluetooth MAC", **I**); used when `mac` absent | `QrData.kt:62` |
| `name` | string | display name; blank → absent | `QrData.kt:68` |
| `channel` | string | parsed, unused | `QrData.kt:80` |
| anything else (`uid`, …) | — | ignored | `test/QrDataTest.kt:14-15` |

**Query extraction** (`queryParams`, `QrData.kt:102-120`):
1. `query` = text after the **first** `?` (no `?` → `""` → empty map), then cut at the **first** `#`.
2. Split on `&`; skip empty parts. `key` = text before the first `=` (whole part if no `=`), `value` = text
   after the first `=` (`""` if none). Skip empty keys.
3. `key` → lowercased (locale-invariant). `value` → `java.net.URLDecoder.decode(value, "UTF-8")`, i.e.
   **form decoding: `+` becomes a space**, `%XX` decoded as UTF-8 bytes (malformed UTF-8 → U+FFFD); if the
   decoder throws (e.g. lone `%`, bad hex) the **raw** value is kept.
4. Duplicate keys: **last wins** (map put).

**Validation & synthesis** (`parseCarbit`, `QrData.kt:59-82`):
```
action  = Int(q["action"]) ?? 0
mac     = formatMac(q["mac"]) ?? formatMac(q["bm"])
ssid    = trim(q["ssid"] ?? "");  pwd = q["pwd"] ?? ""
phoneHotspot = (action & 128) != 0 || (ssid.isEmpty && mac != nil && q has key "bm")
if ssid.isEmpty && !phoneHotspot                  -> nil
if !ssid.isEmpty && pwd.isEmpty && !phoneHotspot  -> nil        // SoftAP QR must carry a password
name    = q["name"] if not blank
          else (ssid.isEmpty ? (mac != nil ? "Phone hotspot (" + last8(mac) + ")" : nil) : nil)
ssid'   = ssid.isEmpty ? "PHONE-HOTSPOT-" + last6(mac without ":") : ssid
action' = (phoneHotspot && (action & 128) == 0) ? action | 128 : action
auth=q["auth"]; modelId=q["modelid"]; sn=q["sn"]; channel=q["channel"]
```

### 2.4 The `action` bitmask

| Bit | Value | Meaning | Status / source |
|---:|---:|---|---|
| 0 | 1 | basic SoftAP (dash is AP) | **V-HW** `01-REVERSE-ENGINEERING.md:34` |
| 1 | 2 | AP + internet | **V-HW** same line |
| 3 | 8 | Wi-Fi Direct (P2P) | **V-HW** same line |
| 6 | 64 | Bluetooth | **V-HW** same line; unused by the app |
| 7 | 128 | phone hosts the hotspot; dash is a Wi-Fi client (no `ssid`/`pwd` in QR) | **V-CODE** `QrData.kt:24-25`; field: Zontes |
| 2, 4, 5 | 4, 16, 32 | unknown | — |

Observed values: `9` (= AP + P2P, CFDL16 675SR-R, `01-REVERSE-ENGINEERING.md:27`), `1` (800MT CFDL26 /
`modelid=37426`, `05-DEBUG-KNOWLEDGE.md:291`, `test/QrDataTest.kt:14`), `8` (Zontes P2P-only,
`test/QrDataTest.kt:74`), `128` (Zontes phone hotspot, `test/QrDataTest.kt:51`).
**The bitmask is not reliable:** P2P-only QRs (`action=8`) with non-`DIRECT-` SSIDs (`ZT5G…`, `Voge-5G…`,
`qj-5G-…`) were joined successfully as plain SoftAP clients (`MainActivity.kt:1071-1077`,
`SUPPORTED-BIKES.md:81`). **V-CODE / I**

### 2.5 Format B — Carbit phone-hotspot URL (`action=128`, `bm=`) — V-CODE (field: Zontes)

`"Phone-hotspot QRs (Zontes etc.) often only carry action=128 + bm= (MAC) — no ssid/pwd"`
(`QrData.kt:56-58`). Same parser as A; the synthesis rules above produce `ssid = "PHONE-HOTSPOT-<6 hex>"`,
`pwd = ""`, `name = "Phone hotspot (xx:yy:zz)"`, `action |= 128`. Such a bike is connected via the
phone-hotspot flow (§7).

### 2.6 Format C — bare `CARBIT` token — V-CODE (field: "second QR on some Zontes units")

`(?i)^CARBIT([0-9A-F]{12})$` on the trimmed text (`QrData.kt:85-99`) →
`ssid = "PHONE-HOTSPOT-" + last6(<12 hex as written>)` (**case preserved**, unlike format B which uses the
lower-cased MAC), `pwd = ""`, `auth = nil`, `mac = formatMac(hex)`, `name = "Phone hotspot (" + last8(mac) + ")"`,
`action = 128`, `modelId/sn/channel = nil`.

### 2.7 Format D — Moto Morini / MotoFun (`Wifi=SSID#PWD#MAC`) — V-CODE (field: Morini)

`http://admin.motomorini.com/app.html?Wifi=ML174167#12345678#dc0d30da1b6c&MachineID=dc0d30da1b6c&ProductID=00297`
— `#` is a field separator, **not** a URL fragment, so generic URL parsing would lose the password
(`QrData.kt:15-18, 122-127`). Algorithm (`QrData.kt:128-156`):
1. Find `(?i)(?:^|[?&])Wifi=([^&#\s]+)` → `ssid` = group 1 trimmed; missing/empty → nil.
2. `after` = text right after the match; must start with `#`, else nil.
3. Drop the leading `#`, split on `#` into **at most 2** parts. `pwd` = part0 up to the first `&`, trimmed;
   empty → nil. `macToken` = part1 up to the first `&`, trimmed (empty → nil).
4. `machineId` = `(?i)MachineID=([^&#\s]+)`, `productId` = `(?i)ProductID=([^&#\s]+)` anywhere in the raw text.
5. Result: `auth = "wpa2-psk"`, `mac = formatMac(macToken) ?? formatMac(machineId)`, `name = ssid`,
   `action = 1`, `modelId = productId`, `sn = machineId`, `channel = nil`.

### 2.8 Format E — Kove / Thinkerride SoftAP (positional) — X (SoftAP join only; no dash video)

`http://g.thinkerride.com?CQKY_5e1c6cb10&81316044&ap=1` or a bare `CQKY_5e1c6cb10&81316044&ap=1`
(`QrData.kt:20-23, 158-224`; Kove is "Experimental (SoftAP join only)", `SUPPORTED-BIKES.md:29, 108`).
1. Applies only if the text contains `thinkerride.com` (case-insensitive) or matches `(?i)^CQKY_[^\s&]+&`.
2. `query` = after the first `?` (cut at `#`) if a `?` exists; else, if it starts with `CQKY_`, the text up to
   the first `#`; else nil. Blank → nil.
3. For each non-empty `&` part: with `=` → key (trimmed, lowercased) / value (form-decoded, trimmed):
   `ssid` sets ssid, `pwd`|`password`|`pass` set pwd (non-empty only), `ap` ignored, other keys ignored.
   Without `=` → form-decoded, trimmed token; skip empty and `ap` (case-insensitive); first token → ssid,
   second → pwd.
4. Both non-empty → `auth = "wpa2-psk"`, `mac = nil`, `name = ssid`, `action = 1`; else nil.

### 2.9 Format F — manual SSID/password entry (synthetic URL) — V-CODE

For dashes that print SSID + password instead of a QR (Benelli TRK 702/702X, `SUPPORTED-BIKES.md:70`).
UI: dialog "Enter bike Wi‑Fi" with fields `Wi‑Fi name (SSID)`, `Password` (masked), `Bike name (optional)`;
both of the first two required, else toast `"SSID and password are required"` (`ManualWifiPairing.kt:20-82`).
Reachable from the QR scanner (`QrScanActivity.kt:59-65`) and the Garage (`GarageActivity.kt:87-93`).

`QrData.buildManual(ssid, pwd, displayName)` (`QrData.kt:275-293`): `s = ssid.trim()`, `p = pwd` (internal
and edge spaces kept), both non-empty else nil; `name = displayName.trim()` if non-empty else `s`. Builds with
Android `Uri.Builder` (`scheme http`, `authority manual.opencfmoto.local`, `path /`, query params appended in
this order: `ssid`, `pwd`, `auth=wpa2-psk`, `action=1`, `name`), then **re-parses** it with `QrData.parse`, so
manual bikes are stored exactly like scanned ones. `Uri.encode` keeps `A–Z a–z 0–9 _ - ! . ~ ' ( ) *` and
percent-encodes everything else as UTF-8 `%XX` (uppercase hex); space → `%20` (not `+`). The round trip is
lossless (`+` → `%2B`). Vectors in §2.15.

### 2.10 `formatMac` — V-CODE (`QrData.kt:227-235`)

```
if raw is nil/blank -> nil
hex = raw filtered to [0-9a-fA-F]            // Kotlin isDigit() (Unicode digits) — ASCII in practice
if hex.count != 12: return raw if (raw contains ":" && raw.count >= 11) else nil   // returned UNCHANGED
return hex in pairs, lowercased, joined with ":"                                     // "aa:bb:cc:dd:ee:ff"
```
(`BikeWifiP2p.normalizeMac`, `BikeWifiP2p.kt:302-307`, is the same but also lowercases the fallback.)

### 2.11 Parse-failure hints (exact strings, first match wins) — V-CODE (`QrData.kt:240-268`)

Evaluated on the trimmed text with case-insensitive `contains`:

| # | Condition | Hint (verbatim) |
|---:|---|---|
| 1 | contains `motomorini.com` and not `Wifi=` | `Moto Morini QR has no Wifi= field — open the phone-link / MotoFun QR on the dash` |
| 2 | matches `(?i)^code:.*engine:.*vin:` **or** (contains `color:` and `vin:`) | `that QR is bike info (color/VIN), not Wi‑Fi pairing — open MotoPlay / EasyConnect / MotoFun QR` (U+2011 in Wi‑Fi) |
| 3 | contains `carbit.com` and `downsdk` | `that is the Carbit app-download QR, not pairing — open MotoPlay / EasyConnect so the Wi-Fi QR (SSID + password) stays on screen` |
| 4 | contains `carbit.com`, not `ssid=`, and (`action=128` or `bm=`) | `this dash joins your phone hotspot — turn on Android hotspot with the SSID/password shown on the dash, then Connect` |
| 5 | matches `(?i)^CARBIT[0-9A-F]{12}$` | `Carbit ID QR — enable Android hotspot with the SSID/password on the dash, then Connect` |
| 6 | contains `thinkerride.com`, or (`kove` and `download`), or `KOVE APP` | `Kove/Thinkerride — need the SoftAP pairing QR (SSID+password on the dash, or g.thinkerride.com?SSID&PWD&ap=1). Garage → enter SSID/pwd if the QR is only “download KOVE APP”` |
| 7 | starts with `http`, not `ssid=`, not `Wifi=` | `URL QR without ssid/pwd — need the dash pairing QR (Carbit / EasyConnect / MotoFun / Thinkerride SoftAP), or enable phone hotspot if the dash asks for it` |
| — | otherwise | nil → generic toast `"Invalid QR"` (`strings.xml:557`) |

Hints are only computed when `parse` returned nil (`MainActivity.kt:74-84`). Note: the verified CFDL16 QR
itself contains `downsdk` (`01-REVERSE-ENGINEERING.md:27`) — hint 3 only fires because the parse failed.
Hints 4/5 mention "Android hotspot"; an iOS port should reword to "Personal Hotspot".

### 2.12 Scanner behaviour — V-CODE (`QrScanActivity.kt`)

- Back camera preview + ML Kit barcode analysis with "keep only latest" back-pressure; the **first**
  barcode whose format is QR wins (`rawValue`); an `AtomicBoolean` guarantees exactly one result; the activity
  returns the raw string under extra `"qr_url"` and closes (`QrScanActivity.kt:30, 89-96, 144-164`).
- **No validation in the scanner.** Any QR closes it; validation happens in the caller: Main screen shows the
  hint toast (§2.11) and the rider must re-open the scanner; Garage only toasts `"Invalid QR"`
  (`MainActivity.kt:65-84`, `GarageActivity.kt:43-56`).
- Zoom buttons 1×/2×/3× (clamped to the camera's min/max ratio) (`QrScanActivity.kt:105-116`).
- "Import QR from photo": gallery image → same detector, first QR; none → toast "Invalid QR"
  (`QrScanActivity.kt:118-141`).
- Camera permission is only required for scanning, not for reconnecting a saved bike
  (`SetupHelper.kt:43-44`).

On a successful parse (Main screen) the app logs `"QR raw: <raw>"` and
`"QR parsed: ssid=… mac=… action=… (ap=…, p2p=…, hotspot=…) modelId=… sn=…"`, **saves the bike**
(§8.1) and starts connecting (`MainActivity.kt:73-110`).

### 2.13 Repo test vectors (copied verbatim from `test/QrDataTest.kt`) — V-CODE

```kotlin
@Test fun parsesCarbitSsidPwd() {
    val raw = "http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426&sn=Vasr&action=1" +
              "&ssid=CFMOTO4288&pwd=e278450c&uid=abc"
    val qr = QrData.parse(raw)!!
    assertEquals("CFMOTO4288", qr.ssid); assertEquals("e278450c", qr.pwd); assertEquals(1, qr.action)
    assertTrue(qr.supportsAp); assertFalse(qr.supportsP2p)
}
@Test fun parsesMotoMoriniWifiHashFormat() {
    val raw = "http://admin.motomorini.com/app.html?Wifi=ML174167#12345678#dc0d30da1b6c" +
              "&MachineID=dc0d30da1b6c&ProductID=00297"
    val qr = QrData.parse(raw)
    assertNotNull(qr)
    assertEquals("ML174167", qr!!.ssid); assertEquals("12345678", qr.pwd)
    assertEquals("dc:0d:30:da:1b:6c", qr.mac); assertEquals("00297", qr.modelId)
    assertEquals("dc0d30da1b6c", qr.sn); assertTrue(qr.supportsAp); assertFalse(qr.supportsP2p)
}
@Test fun rejectsVehicleInfoQr() {
    assertNull(QrData.parse("code:&engine:&vin:&color:Fuji White"))
    val hint = QrData.parseFailureHint("code:&engine:&vin:&color:Fuji White")
    assertNotNull(hint); assertTrue(hint!!.contains("bike info", ignoreCase = true))
}
@Test fun parsesPhoneHotspotAction128() {
    val raw = "http://www.carbit.com.cn/down6/645/644/_ylqxos?modelid=21322&sn=t6J4&action=128" +
              "&bm=DD%3A0D%3A30%3A24%3A87%3A6D"
    val qr = QrData.parse(raw)
    assertNotNull(qr); assertTrue(qr!!.supportsPhoneHotspot); assertFalse(qr.supportsAp)
    assertEquals("dd:0d:30:24:87:6d", qr.mac); assertEquals("21322", qr.modelId)
    assertTrue(qr.ssid.startsWith("PHONE-HOTSPOT")); assertTrue(qr.pwd.isEmpty())
}
@Test fun parsesCarbitTokenQr() {
    val qr = QrData.parse("CARBITDC0D3024876D")
    assertNotNull(qr); assertTrue(qr!!.supportsPhoneHotspot); assertEquals("dc:0d:30:24:87:6d", qr.mac)
}
@Test fun parsesP2pOnlyZontesSoftApQr() {
    val raw = "http://www.carbit.com.cn/down6/645/644/_ylqxos?modelid=34808&action=8" +
              "&ssid=ZT5Gcf3b&pwd=secret&auth=WPA2&mac=34%3A28%3A4a%3A04%3Acf%3A3b&name=ZT5Gcf3b"
    val qr = QrData.parse(raw)!!
    assertEquals("ZT5Gcf3b", qr.ssid); assertTrue(qr.supportsP2p); assertFalse(qr.supportsAp)
    assertFalse(qr.supportsPhoneHotspot); assertEquals("34:28:4a:04:cf:3b", qr.mac)
}
@Test fun parsesThinkerridePositionalSoftApQr() {
    val raw = "http://g.thinkerride.com?CQKY_5e1c6cb10&81316044&ap=1"
    val qr = QrData.parse(raw)
    assertNotNull(qr); assertEquals("CQKY_5e1c6cb10", qr!!.ssid); assertEquals("81316044", qr.pwd)
    assertEquals(1, qr.action); assertTrue(qr.supportsAp); assertFalse(qr.supportsP2p)
    assertEquals("CQKY_5e1c6cb10", qr.name)
}
@Test fun parsesBareThinkerrideCqkyToken() {
    val qr = QrData.parse("CQKY_5e1c6cb10&81316044&ap=1")
    assertNotNull(qr); assertEquals("CQKY_5e1c6cb10", qr!!.ssid); assertEquals("81316044", qr.pwd)
    assertTrue(qr.supportsAp)
}
@Test fun rejectsIncompleteThinkerrideQr() {
    assertNull(QrData.parse("http://g.thinkerride.com?CQKY_onlyssid&ap=1"))
    assertNull(QrData.parse("http://g.thinkerride.com?ap=1"))
    val hint = QrData.parseFailureHint("http://g.thinkerride.com/download")
    assertNotNull(hint)
    assertTrue(hint!!.contains("Thinkerride", ignoreCase = true) || hint.contains("Kove", ignoreCase = true))
}
```

### 2.14 Full expected parse results for the repo vectors — D

All fields (`nil` = null). `Ap/P2p/Hs` = `supportsAp / supportsP2p / supportsPhoneHotspot`.

| Input (abbrev.) | ssid | pwd | auth | mac | name | action | modelId | sn | Ap/P2p/Hs |
|---|---|---|---|---|---|---:|---|---|---|
| `…_sdk?modelid=37426&sn=Vasr&action=1&ssid=CFMOTO4288&pwd=e278450c&uid=abc` | `CFMOTO4288` | `e278450c` | nil | nil | nil | 1 | `37426` | `Vasr` | T/F/F |
| `…app.html?Wifi=ML174167#12345678#dc0d30da1b6c&MachineID=…&ProductID=00297` | `ML174167` | `12345678` | `wpa2-psk` | `dc:0d:30:da:1b:6c` | `ML174167` | 1 | `00297` | `dc0d30da1b6c` | T/F/F |
| `code:&engine:&vin:&color:Fuji White` | **nil** (hint #2) | | | | | | | | |
| `…_ylqxos?modelid=21322&sn=t6J4&action=128&bm=DD%3A0D%3A30%3A24%3A87%3A6D` | `PHONE-HOTSPOT-24876d` | `""` | nil | `dd:0d:30:24:87:6d` | `Phone hotspot (24:87:6d)` | 128 | `21322` | `t6J4` | F/F/T |
| `CARBITDC0D3024876D` | `PHONE-HOTSPOT-24876D` | `""` | nil | `dc:0d:30:24:87:6d` | `Phone hotspot (24:87:6d)` | 128 | nil | nil | F/F/T |
| `…_ylqxos?modelid=34808&action=8&ssid=ZT5Gcf3b&pwd=secret&auth=WPA2&mac=34%3A28…&name=ZT5Gcf3b` | `ZT5Gcf3b` | `secret` | `WPA2` | `34:28:4a:04:cf:3b` | `ZT5Gcf3b` | 8 | `34808` | nil | F/T/F |
| `http://g.thinkerride.com?CQKY_5e1c6cb10&81316044&ap=1` | `CQKY_5e1c6cb10` | `81316044` | `wpa2-psk` | nil | `CQKY_5e1c6cb10` | 1 | nil | nil | T/F/F |
| `CQKY_5e1c6cb10&81316044&ap=1` | same as above | | | | | | | | |
| `http://g.thinkerride.com?CQKY_onlyssid&ap=1` | **nil** (hint #6) | | | | | | | | |
| `http://g.thinkerride.com?ap=1` | **nil** (hint #6) | | | | | | | | |
| `http://g.thinkerride.com/download` | **nil** (hint #6) | | | | | | | | |

Note: the Zontes vector's password `secret` is 6 characters — **not a valid WPA2 passphrase** (8–63). It is a
synthetic parser test; a real join with it would fail (§3.2).

### 2.15 Additional derived vectors — D

| Input | Result |
|---|---|
| `http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457` (doc 01) | ssid `CFMOTO-f46457`, pwd `59a9cddc94`, auth `wpa2-psk`, mac `6c:09:4a:0f:6c:f8`, name `CFMOTO-f46457`, action 9, modelId `37416`, sn `peTz`; Ap=T P2p=T Hs=F |
| `…?modelid=37426&action=9&ssid=DIRECT-CF-CFMOTO-805120&pwd=12345678&auth=wpa2-psk&mac=aa:bb:cc:dd:ee:ff&name=CFMOTO-805120` (illustrative 1000 MT-X; real SSID/pwd from `01-REVERSE-ENGINEERING.md:208`, other fields invented) | ssid `DIRECT-CF-CFMOTO-805120`, pwd `12345678`, Ap=T P2p=T |
| `…?modelid=37501&action=8&ssid=qj-5G-ab12cd&pwd=12345678` (illustrative QJ 600SX) | ssid `qj-5G-ab12cd`, mac nil, name nil, action 8; Ap=F P2p=T |
| `http://www.carbit.com.cn/x?SSID=Bike+One&PWD=a%2Bb+c&ACTION=1` | ssid `Bike One`, pwd `a+b c` (keys case-folded, `+`→space, `%2B`→`+`), action 1 |
| `…/x?ssid=CFMOTO1&pwd=&action=1` | **nil** (SoftAP without password); hint nil |
| `…/x?ssid=CFMOTO1&action=1&bm=112233445566` | **nil** (ssid present, no pwd, no bit 7) |
| `…/x?action=1&bm=112233445566` | ssid `PHONE-HOTSPOT-445566`, pwd `""`, mac `11:22:33:44:55:66`, name `Phone hotspot (44:55:66)`, action **129**; Ap=T Hs=T |
| `…/x?ssid=A&pwd=p#frag&action=8` | ssid `A`, pwd `p`, action **0** (everything after `#` is dropped) |
| `carbitdc0d3024876d` | ssid `PHONE-HOTSPOT-24876d`, mac `dc:0d:30:24:87:6d`, action 128 |
| `http://admin.motomorini.com/app.html?Wifi=MLN_1234#pass word#&MachineID=dc0d30da1b6c` | ssid `MLN_1234`, pwd `pass word`, mac `dc:0d:30:da:1b:6c` (from MachineID), sn `dc0d30da1b6c`, modelId nil |
| `http://admin.motomorini.com/app.html?MachineID=dc0d30da1b6c` | **nil**, hint #1 |
| `http://g.thinkerride.com?ssid=KOVE_1&password=abc%20def&ap=1` | ssid `KOVE_1`, pwd `abc def`, action 1 |
| `http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426` | **nil**, hint #3 |
| `http://example.com/app` | **nil**, hint #7 |
| `buildManual("CFMOTO4288","e278450c","My bike")` | raw `http://manual.opencfmoto.local/?ssid=CFMOTO4288&pwd=e278450c&auth=wpa2-psk&action=1&name=My%20bike` → ssid `CFMOTO4288`, pwd `e278450c`, auth `wpa2-psk`, name `My bike`, action 1 |
| `buildManual(" TRK702X ","p@ss w+rd&#1",nil)` | raw `http://manual.opencfmoto.local/?ssid=TRK702X&pwd=p%40ss%20w%2Brd%26%231&auth=wpa2-psk&action=1&name=TRK702X` → pwd `p@ss w+rd&#1` |

### 2.16 QR → early bike-profile guess (for completeness) — V-CODE

The profile (owned by `control-plane.md` §12) is guessed from the QR before connecting and refined from
CLIENT_INFO (`BikeProfile.kt:174-205`, `MainActivity.kt:115-149`):

| QR condition | Early profile |
|---|---|
| Setup profile override ≠ Auto | the override |
| `ssid` starts with `MLN_` (any modelId), or starts with `ML` and `modelid ∈ {21333, 00297}` (prefixes case-insensitive) | Morini SoftAP / Alltrhike (MLN) |
| `modelid = 37416` | CFDL16 legacy |
| `modelid ∈ {66660703, 66660721, 66660732}` | US 800NK (CRCP) |
| `modelid = 66660742` | CFDL16 MotoPlay Landscape |
| `modelid ∈ {66660736, CLC450}` | CL-C450 |
| `modelid ∈ {21333, 21322}` | Morini SoftAP |
| `modelid = 37426` (shared by 1000 MT-X, 800MT, 800NK Advanced) | P2P bit set **or** ssid starts `DIRECT-` (case-sensitive here) → CFDL26 Portrait (1000 MT-X), else CFDL26 Landscape (800MT) |
| anything else (e.g. QJ `37501`, Zontes `34808`) | CFDL16 legacy |
| then: if a learned canvas exists for this SSID (§8.2) and differs from the profile's panel | wrap with the learned geometry (`[panel] using measured …`) |

---

## 3. Wi-Fi: transport choice, join, loss, re-join, release

### 3.1 Transport decision — V-CODE (`MainActivity.kt:1029-1114`)

Setting `wifi_transport` ∈ `auto` (default) / `ap` / `p2p` (`AppSettings.kt:78-81, 171-181`). Per-SSID memory
`transport_<ssid>` ∈ `"AP"`/`"P2P"` = the transport that last produced a live Wi-Fi link (§8.1).

```
guard WifiGate.ensureEnabledOrPrompt() else return           // §3.7, MainActivity.kt:1030
phase = JOINING_WIFI                                          // :1031
if qr.supportsPhoneHotspot && qr.pwd.isEmpty  -> phone-hotspot flow (§7); return     // :1034-1037
isDirect = ssid.lowercased().hasPrefix("direct-")
useP2p = switch setting {                                     // :1042-1049
  p2p : qr.supportsP2p || !qr.supportsAp
  ap  : false
  auto: (qr.supportsP2p && !qr.supportsAp) || (isDirect && (qr.supportsP2p || !qr.supportsAp))
}
remembered = (setting == auto) ? transport_<ssid> : nil       // :1054
eff = remembered=="AP" && qr.supportsAp ? false
    : remembered=="P2P" && qr.supportsP2p ? true : useP2p     // :1055-1059
if eff:
   if !isDirect && qr.mac is blank && !qr.pwd.isEmpty -> SoftAP join (skip P2P)      // :1073-1077
   else -> Wi-Fi Direct (§3.4)                                                       // :1085
else -> SoftAP join via reuseOrJoin (§3.2, §3.6)                                     // :1089-1113
```
Derived decisions (**D**) for the vectors of §2.14/§2.15 with `auto` and no memory: CFDL16 `action=9`
→ **AP**; `DIRECT-CF-CFMOTO-805120` `action=9` → **P2P credential join, 12 s, SoftAP fallback**; Zontes
`action=8` with MAC → **P2P by MAC, 40 s, SoftAP fallback**; QJ `qj-5G-…` `action=8` without MAC → **AP**;
phone-hotspot QRs → **hotspot flow**. With `p2p` forced, the CFDL16 QR → P2P by MAC, 12 s.

**iOS:** only the SoftAP branch exists (§11.1). P2P-only QRs simply get a SoftAP join attempt.

### 3.2 SoftAP join (dash = access point, phone = client) — V-HW / V-CODE

`BikeWifi.join(ssid, psk)` (`BikeWifi.kt:79-114`):
- `WifiNetworkSpecifier.Builder().setSsid(ssid).setWpa2Passphrase(psk)` — exact SSID, **WPA2-PSK only**
  (no open/WEP/WPA3-only, **no hidden-SSID flag**). The QR `auth` field is ignored. (`BikeWifi.kt:102-105`)
- `NetworkRequest`: transport Wi-Fi, **`removeCapability(INTERNET)`**, with the specifier
  (`BikeWifi.kt:106-110`) → a local-only network that never becomes the system default; other apps keep
  cellular (`02-CURRENT-APP.md:128-130`).
- Android shows a system "connect to <SSID>?" device picker; once approved, later requests are satisfied
  silently (`BikeWifi.kt:19-24`). Fine location is requested first: "Some OEMs require fine location to
  associate via WifiNetworkSpecifier" (`MainActivity.kt:1350-1358`).
- **Request timeout (mandatory):** **90 000 ms** for the first acquisition (the picker must stay usable —
  timing out while it is open makes Android say "The app canceled the request to choose a device"),
  **12 000 ms** for silent re-joins (`BikeWifi.kt:66-77, 208-215`). Without a timeout the request can hang
  7+ min after the AP dies (`BikeWifi.kt:67-70`).
- Passphrase validity (**I**): `setWpa2Passphrase` throws for a passphrase that is not 8–63 ASCII; `join()`
  doesn't catch it; it surfaces as ERROR `"Connect failed — see Logs / Share Logs"` via the catch in
  `MainActivity.kt:256-260` (AA path) — Map/Mirror paths have no catch.

Callbacks (`BikeWifi.kt:146-205`):

| Event | Actions |
|---|---|
| `onAvailable(net)` | `currentNetwork = net`; **do not** bind the process yet (binding kills loopback for AA; bind happens when PXC starts, §3.9); ensure cellular uplink request; `rejoinAttempts = 0`; log link info once (`[wifi] link: …`); **first** delivery → `"Wi-Fi joined: <ssid> (network=…, bind deferred until AA video)"` + caller's `onAvailable`; **later** deliveries → `"Wi-Fi re-acquired: <ssid> — restarting bike link on fresh network"` + `BikeLink.onWifiReacquired(net)` (§3.5). |
| `onLost(net)` | `"Wi-Fi lost: <net>"`; `currentNetwork = nil`; unbind process immediately (a dead bind breaks loopback binds and probes); caller's `onLost` (only logs `"bike network lost"`, `MainActivity.kt:1111`) — **the prober is not stopped**; if still active → schedule re-join (§3.5). |
| `onUnavailable()` (request timed out) | log `"Wi-Fi join unavailable after <N>s (bike off, out of range, declined, or system picker timed out) — will retry"` (N = 90 before the first success, else 12); if the first join never succeeded: log `"→ TAP the phone's Wi‑Fi / device picker NOW …"` and ERROR detail `"Approve the phone's Wi‑Fi / device picker (don't leave it open), then Connect again"` (`strings.xml:549`); unbind if no network; re-join if active. |

Band: the code imposes **no band restriction** (2.4 or 5 GHz). SSIDs such as `qj-5G-*`, `ZT5G…` and
`Voge-5G…` suggest 5 GHz dash APs (**I**, from names only); the band is only logged, and 2.4 GHz is flagged.

Link logging (`BikeWifi.kt:220-235`), once per join: `"[wifi] link: <MHz>MHz (<band>), rssi=<dBm>dBm, tx=<Mbps>Mbps, rx=<Mbps>Mbps"`
where band = `"2.4GHz — SHARED WITH BLUETOOTH"` for 2400–2500 MHz else `"<MHz/1000>GHz"`. **V-CODE**
(2.4 GHz video shares the radio with the handlebar/helmet Bluetooth — a known jitter source.)

### 3.3 `DIRECT-…` Wi-Fi-Direct groups joined as a legacy client — V-HW

1000 MT-X (CFDL26): QR SSID `DIRECT-CF-CFMOTO-805120`, pwd `12345678`; the phone landed on
`192.168.49.132/24`, gateway/bike `192.168.49.1`, iface `wlan1`; "Our `WifiNetworkSpecifier` join +
`bindProcessToNetwork` handled this **unchanged** — no code change was needed for P2P"
(`01-REVERSE-ENGINEERING.md:207-211`). Probe, connect-back and framing are identical.
Counter-evidence: `BikeWifiP2p` says a specifier "cannot associate to a GO" for CL-C450-class dashes
(`BikeWifiP2p.kt:26-29`), and README advises Setup → P2P when "CL‑C450 / DIRECT‑… never joins"
(`README.md:671`). Both are true for different dashes → **iOS risk** (§13).

### 3.4 Wi-Fi Direct P2P path (Android-only; not portable) — V-CODE / partly X

Shown so the iOS team understands field logs and the decision table; iOS has no Wi-Fi Direct API.

- When: §3.1 (`P2P-only` QR, or `DIRECT-…` SSID, or forced, or remembered). Topology: dash = **group owner
  at 192.168.49.1**, phone = client `192.168.49.x` on a `p2p-*` iface; no `Network` object, so sockets are
  bound to the phone's P2P IPv4 instead of process-binding (`BikeWifiP2p.kt:31-38`).
- Steps (`BikeWifiP2p.kt:70-120`): `discoverPeers` (failure → try MAC join immediately); SSID `DIRECT-…` →
  **credential join** `WifiP2pConfig.Builder().setNetworkName(ssid).setPassphrase(pwd).enablePersistentMode(false)`
  (log `"joining group name='…' as legacy client"`; empty pwd/builder error/connect failure → MAC join)
  (`:123-159`); else **MAC join**: stop discovery, `WifiP2pConfig{deviceAddress = qr.mac; wps = PBC}`
  (`:166-214`). Peer list updates: match by MAC (**exact or ±1 on the last octet**, "seen on some Carbit units
  where the QR mac= and the P2P device address differ by one") or device name containing the SSID → MAC join
  (`:242-280, 313-323`).
- **There is no mode in which the phone is the group owner.** The dash is always expected to be GO; if the phone
  ends up GO it is only logged: `"[P2P] !! WE became the Group Owner â€” the bike is expected to be the GO. This
  usually means the join fell back to creating a new group. Share this log."` (`BikeWifiP2p.kt:334-338`; the source
  literally contains the mojibake `â€”` instead of `—` here and in the "connected" line below).
- Group formed → GO address must be IPv4 (else fail `"group formed but GO address is not IPv4"`); poll our `192.168.49.x` address every **500 ms** for up to **10 s**
  (fail `"group formed but could not resolve our 192.168.49.x address on <iface>"`); success →
  `"[P2P] *** connected: phone=… bike(GO)=… â€” starting PXC ***"` → prober started with
  `bindIpOverride/gatewayOverride` (`:326-390`).
- Timeout: **40 000 ms** default (`CONNECT_TIMEOUT_MS`, `:49`); **12 000 ms** if the QR also advertises AP
  and has a password (fallback exists) unless P2P is the remembered winner (`MainActivity.kt:1249-1254`).
  Failure `"no P2P group formed within <n>s"` → if pwd empty or SSID `PHONE-HOTSPOT…` → ERROR
  `"Wi‑Fi Direct failed"`; else `"P2P join failed: <reason> — falling back to AP join"` + fresh SoftAP join
  (`MainActivity.kt:1280-1309`).
- Wi-Fi P2P disabled broadcast → fail `"Wi-Fi P2P is disabled — enable Wi-Fi and retry"` (`:236-241`).
- **GAP:** no auto re-join for P2P — on group loss only `connected=false` + `"[P2P] group lost"` is logged
  (`:287-290`); nothing re-forms the group.

### 3.5 Re-join after loss (ignition cycles) — V-CODE (README: "auto re-join after ignition cycles", `README.md:77`)

A specifier request is terminal on loss, so `BikeWifi` re-issues it until the rider taps Stop
(`BikeWifi.kt:26-34, 237-257`):

```
on loss/unavailable, if active:
  rejoinAttempts += 1
  delay = !firstDelivered     ? 4000 ms                         // FIRST_JOIN_RETRY_MS (never fast before first success)
        : rejoinAttempts <= 1 ? 300 ms                          // REJOIN_FAST_MS
        :                       min(2500 × (rejoinAttempts−1), 15000) ms
  after delay: log "re-requesting bike Wi-Fi (attempt N) …";
               if phase != WAITING_FOR_BIKE: phase = RECONNECTING("waiting for bike Wi-Fi")
               requestNetwork(timeout = firstDelivered ? 12 s : 90 s)
```

| Attempt n (after a first success) | 1 | 2 | 3 | 4 | 5 | 6 | ≥7 |
|---|---:|---:|---:|---:|---:|---:|---:|
| delay before request (ms) — **D** | 300 | 2500 | 5000 | 7500 | 10000 | 12500 | 15000 |

Each request then waits up to 12 s → steady-state period ≈ 27 s while the bike is off. `rejoinAttempts`
resets to 0 on every `onAvailable`. Why 300 ms: "at home the phone races to re-join a saved network the moment
the bike's AP blips, and if we don't re-grab the bike AP fast the dash's EasyConn times out ('device is not
on the network')" (`BikeWifi.kt:57-60`). README: some firmwares still need the pairing/QR screen once after
an ignition cycle (`README.md:670`).

**Re-acquire handling** (`BikeLink.onWifiReacquired`, `BikeLink.kt:117-141`): if the AA service is parked →
ask it to resume (AA-only, §6.6); else `"→ restarting bike link on re-acquired Wi-Fi"`,
phase `PXC_CONNECTING("reconnecting")`, **`prober.stop()` then `prober.start(newNetwork)`** (fresh IP,
listeners rebound, full discovery). Failure → ERROR `"prober restart failed"`.

### 3.6 Reuse on mode switch — V-CODE (`BikeWifi.kt:121-139`)

Switching AA↔Map↔Mirror keeps Wi-Fi and rebuilds only PXC. `reuseOrJoin`: if active, `currentNetwork != nil`
and the same SSID (case-insensitive) → log `"Wi-Fi already joined: <ssid> — skipping re-join (mode switch)"`
and call `onAvailable` immediately; else full `join`. (Re-requesting "added multi-second stalls and 'already
running' races".)

### 3.7 "Phone Wi-Fi is off" gate — V-CODE (`WifiGate.kt`)

`isWifiEnabled` = `WifiManager.isWifiEnabled` (unknown → treated as on) (`WifiGate.kt:31-36`). Off →
log `"[WIFI] phone Wi‑Fi is OFF — prompting for Wi‑Fi settings"`, ERROR `"phone Wi‑Fi is off"`, modal
"Turn on Wi‑Fi" / "OpenCfMoto joins the bike over Wi‑Fi, but your phone’s Wi‑Fi is off.\n\nTurn it on, then tap
Connect again." with **Wi‑Fi settings** / **Dismiss** (once at a time) (`WifiGate.kt:42-51, 97-126`).
Without an Activity: one notification "Turn on Wi‑Fi" / "OpenCfMoto can’t reach the bike — tap to open Wi‑Fi
settings." (channel `opencfmoto_wifi`, id 4) (`WifiGate.kt:56-68, 128-152`). Checked at Connect
(`MainActivity.kt:186`), each join (`:1030`, `:1242`), the P2P→AP fallback (`:1287`), auto-connect (`:763-767`,
does not latch so it retries); notification cancelled on resume / successful join (`:694, 1094`).

### 3.8 "Is the bike in range?" — V-CODE (`BikeWifi.kt:271-298`)

Used only to gate auto-connect / resume. Deliberately biased to "unknown → try anyway":
`nil` if SSID blank, no WifiManager, Wi-Fi off, or no fine-location permission; `true` if currently associated
to that SSID or any (fresh or cached) scan result has it; `false` only if there are **fresh** results
(seen < **30 s** ago, `FRESH_SCAN_US = 30_000_000`) and none matches; else `nil`. Also fires a best-effort
`startScan()` for next time.

### 3.9 Network-binding model (bike traffic on Wi-Fi, internet on cellular) — V-CODE

- The bike Wi-Fi has no internet and is requested without INTERNET capability (§3.2).
- **Process binding is deferred**: `onAvailable` does not bind; `BikeLink.maybeStartProbe` (AA path),
  `EasyConnProber.start`, `discoverAndProbe` and **every probe attempt** call `rebindProcessToBike()`
  (`bindProcessToNetwork(currentNetwork)`) (`BikeWifi.kt:149-152, 369-378`; `EasyConnProber.kt:171, 382,
  496`; `BikeLink.kt:95-97`). Reason: binding removes the `127.0.0.1` route the AA receiver needs.
- Probe/scan sockets are pinned to the bike network even without the process bind (VPN bypass):
  `Network.socketFactory.createSocket()` → else `Network.bindSocket(Socket())` → else plain `Socket()` (process
  bind); with no `Network` (P2P/hotspot) → `Socket()` bound to `(myIp, 0)`. "CRITICAL: do NOT `Socket.bind(local)`
  before `Network.bindSocket`" (`EasyConnProber.kt:498-500, 547-588`).
- Listeners bind explicitly to `myIp` (§5.1).
- Internet for maps/routing is pinned to **cellular**: a standing `requestNetwork(INTERNET + CELLULAR)` keeps
  mobile data up (fallback: any INTERNET network) (`AppHttp.kt:62-101`); HTTP clients pick validated
  cellular → unvalidated cellular → other validated → other internet, skipping VPN networks and
  **unvalidated Wi-Fi (the bike AP)** (`AppHttp.kt:109-136`). Logged as `[NET] …`.
- On loss: unbind immediately (`BikeWifi.kt:174-176`). Before AA starts and after a park: unbind if no live
  bike network (`BikeWifi.kt:359-362`, `AndroidAutoService.kt:510-511`).
- **VPN interplay** (`BikeWifi.kt:380-460`, `EasyConnProber.kt:169-187, 427-447, 524-531`): a "live internet
  VPN" = any network with transport VPN **and** INTERNET capability. EPERM / "Operation not permitted" from
  `socketFactory`/`bindSocket` **while such a VPN exists** = kill-switch ("Block connections without VPN") →
  ERROR `"VPN kill-switch blocking bike Wi‑Fi"` + stop (at start) or ERROR (probe path, unless the bike already
  connected this session — then ignored as a blip). A VPN alone only logs warnings. UI then shows "VPN is
  blocking the bike" with a VPN-settings shortcut (`MainActivity.kt:890-897, 977-1003`).

### 3.10 Ending the session's Wi-Fi: leave vs park — V-CODE (`BikeWifi.kt:300-337`)

`releaseSession()` on Stop/teardown: if Setup "Stay on bike Wi-Fi after disconnect" (`keep_wifi_after_disconnect`,
default **off**, `AppSettings.kt:119-127`; description: "Some dashes forget the clock when SoftAP / Wi-Fi Direct
drops", `strings.xml:402-403`) → **park**: unbind the process but keep the request (stay associated) and keep the
P2P group (`BikeWifiP2p.park`, `BikeWifiP2p.kt:416-421`), log `"Wi-Fi kept after disconnect (dash clock) — process
unbound, SoftAP still associated"`. Else **leave**: `active=false`, cancel pending re-joins, unregister the request
(Android disassociates), unbind, log `"Wi-Fi released"`; P2P `stop` = cancelConnect + removeGroup.
**GAP (I):** in park mode `active` stays true, so a later loss/re-acquire still calls `BikeLink.onWifiReacquired`,
which **restarts the prober after the rider pressed Stop**. iOS: make "keep Wi-Fi" purely about association.

### 3.11 Wi-Fi quirks by brand (summary; see §10 for the full table)

CFDL16 SoftAP `CFMOTO-xxxxxx` 192.168.0.1; CFDL26/1000 MT-X `DIRECT-CF-…` legacy-joinable GO 192.168.49.1;
US 800NK and 450NK dashes at 192.168.49.1 (Wi-Fi Direct family); CL-C450 often needs real P2P; Zontes/Voge/QJ
`*5G*` SSIDs flagged P2P-only but SoftAP-joinable; QJ 600SX/550SX "use Setup → Wi‑Fi **AP** if Auto mis-picks
P2P" (`SUPPORTED-BIKES.md:81`); Morini X-Cape 1200 SoftAP at 192.168.4.1 speaking Yunmo (X).

---

## 4. Addressing

### 4.1 Phone IPv4 (`pickBikeInterfaceIp`, `EasyConnProber.kt:1019-1035`) — V-CODE

1. `bindIpOverride` if given (P2P, hotspot).
2. Else the first **IPv4, non-loopback** link address of the bike `Network`.
3. Else the first IPv4 non-loopback address of any up, non-loopback interface (could be the cellular IP —
   only reachable when no `Network` is known).
Failure → log `"could not resolve our IPv4 on the bike network; aborting"` and return (phase unchanged)
(`EasyConnProber.kt:151-152`). Link-local (169.254/16) is **not** excluded here.

### 4.2 Bike IPv4 (`resolveGateway`, `EasyConnProber.kt:966-1017`) — V-CODE (V-HW for the AP case)

1. `gatewayOverride` if given (P2P GO address, hotspot peer).
2. The bike network's (else the active network's) **default-route IPv4 gateway** (not 0.0.0.0).
3. Else, for each IPv4 link address that is not loopback/link-local: `gatewayForSubnet(addr, prefix)` =
   `(ip & mask) | 1` for prefix 1…31, **nil if that equals our own IP** — log
   `"no default route — assuming Wi-Fi Direct group owner <ip>"` (seen on Samsung/Android 16 P2P groups with
   no default route).
4. Else the first IPv4 DNS server.
Failure → `"could not resolve bike gateway IP; aborting"` (+ `" — if Wi‑Fi is up, open MotoPlay / show the pairing QR on the dash"` when a Network exists).

`gatewayForSubnet` vectors (**D**):

| Our address | Result |
|---|---|
| `192.168.0.50/24` | `192.168.0.1` |
| `192.168.49.132/24` | `192.168.49.1` |
| `192.168.4.2/24` | `192.168.4.1` |
| `172.20.10.2/28` | `172.20.10.1` |
| `10.0.0.7/8` | `10.0.0.1` |
| `192.168.49.1/24` | nil (we are `.1`) |

### 4.3 Known address plans

| Situation | Bike | Phone | Status / source |
|---|---|---|---|
| CFDL16 SoftAP (`CFMOTO-f46457`) | `192.168.0.1` (gateway) | `192.168.0.50/24` (DHCP) | **V-HW** `01-REVERSE-ENGINEERING.md:42-43` |
| 800MT CFDL26 SoftAP (`CFMOTO1565`) | `192.168.0.1` | DHCP | **V-HW** `05-DEBUG-KNOWLEDGE.md:291-293` |
| 1000 MT-X `DIRECT-CF-CFMOTO-805120` | `192.168.49.1` | `192.168.49.132/24`, iface `wlan1` | **V-HW** `01-REVERSE-ENGINEERING.md:208-209` |
| 450NK (2027, no T-Box) during projection | `192.168.49.1`; full TCP scan 1–65535: only :10930 open, transiently; **no mDNS** | — | **V-HW** `RE-VEHICLE-TELEMETRY.md:47-54` |
| Android P2P (MAC/credential join) | GO `192.168.49.1` | `192.168.49.x` on `p2p-*` | **V-CODE** `BikeWifiP2p.kt:31-38` |
| Morini X-Cape 1200 Yunmo SoftAP | `192.168.4.1:8200` | DHCP | **X** `YunmoFrame.kt:26-27` |
| Android phone hotspot (dash = client) | DHCP client on e.g. `192.168.43.x` | gateway e.g. `192.168.43.1/24` | **X** `PhoneHotspotScan.kt:19-20` |
| **iPhone Personal Hotspot** (iOS proposal) | `172.20.10.2–.14` | `172.20.10.1/28` | **I** (§7.3) |

### 4.4 What the listeners bind to — V-CODE

The phone IPv4 from §4.1, ports **10922, 10921, 10920** (creation order), backlog **50**, `SO_REUSEADDR` set
before `bind` — never the wildcard address (`EasyConnProber.kt:189-207`).

### 4.5 Connect-back address — I

The probe JSON contains no IP/port (§5.3), and the phone CLIENT_INFO reply contains no IP either
(`BikeProfile.kt:288-309`). The dash therefore calls back **the source address of the probe connection**
on the fixed ports. Consequence: the probe must leave from the same interface/IP the listeners are bound to.

---

## 5. Listeners, discovery, the probe, connect-back

### 5.1 `EasyConnProber.start(network, gatewayOverride, bindIpOverride)` — V-CODE (`EasyConnProber.kt:131-229`)

1. If already running: `"already running — forcing PXC restart for clean mode switch"` → `stop()` (mode switches
   must never no-op on a half-dead session).
2. Reset session state: `probed=false, framesSent=0, lastFrameAt=0, everConnected=false, reconnectAttempts=0,
   liveConns=0`; remember `network`; dump environment (`---- environment ----`, `Build: …`,
   `linkProps iface=… addrs=… routes=…`, `---------------------`).
3. Resolve `myIp` (§4.1) and `bikeIp` (§4.2); log `"our IP=<myIp>  bike IP=<bikeIp>"` (two spaces).
4. `running = true`; acquire Wi-Fi multicast lock `"opencfmoto"` (non-ref-counted) for NSD.
5. Re-bind process to bike network; VPN warnings / kill-switch check (§3.9).
6. **Listen before probing**: for port in `[10922, 10921, 10920]`: new server socket, `reuseAddress=true`,
   `bind((myIp, port), 50)`, start accept thread `ec-accept-<port>`. Any failure → `"bind :<port> failed: <msg>"`.
   Then `"listening on <myIp> ports [10922, 10921, 10920] (<n> open)"`.
7. **Any** bind failure ⇒ `"!! link ports are held by another app (usually the official CFMoto/EasyConnect app).
   Close it (force-stop) and reconnect — OpenCfMoto needs ports [10922, 10921, 10920]."`, ERROR
   `"close the official CFMoto app, then reconnect"`, `stop()`. (Every bind error is attributed to the rival app,
   even EADDRNOTAVAIL.) The UI then offers "Close & retry" (best-effort `killBackgroundProcesses
   ("com.cfmoto.cfmotointernational")`, reconnect after **1500 ms**) and "App settings" (force-stop)
   (`MainActivity.kt:883-887, 946-971`; `RivalClient.kt:24-49`).
8. Start thread `ec-probe` → `discoverAndProbe` (§5.2); start the 5 s heartbeat logger (§9.4); start the
   touch-stitch scheduler.

### 5.2 Initial discovery ladder (`discoverAndProbe`, `EasyConnProber.kt:381-448`) — V-CODE

| Step | Action | Probe attempts | Worst case (no answers) |
|---|---|---:|---|
| 1 | Bonjour/NSD browse `_EasyConn._tcp.` ≤ **12 000 ms**, first service that resolves to a usable IPv4:port | — | 12 s |
| 1a | if found: probe it | 3 | 3×(3+5) s + 4.5 s sleeps |
| 1b | if not accepted: log `"[DISC] NSD endpoint did not accept probe — re-discovering…"`, browse again, probe | 3 | +12 s + same |
| 2 | probe `bikeIp:10930` (classic wake port) | 5 | 5×(3+5) s + **11.25 s** sleeps |
| 3 | TCP connect-scan `bikeIp` ports **10915…10935** (21 ports, sequential, **350 ms** connect timeout each), then probe each open port, 10930 first | 2 each | 7.35 s scan |
| 4 | only if no bike socket ever connected: **Yunmo** `bikeIp:8200` (connect 5 s, canvas reply wait 5 s) — **X** (Morini X-Cape 1200) | — | ~10 s |
| 5 | only if still nothing: log-only "thinkerride" scan — 251 ports (80, 443, 554, 8080, 8888, 9000, 9999, 5000–5010, 7000–7010, 8000–8210, 10000–10010; 8080 listed twice), **250 ms** each — **X** (Kove RE aid) | — | 62.75 s |
| 6 | kill-switch → ERROR `"VPN kill-switch blocking bike Wi‑Fi"`; VPN present → warning only; else `"!! SoftAP is up but EasyConn never answered (NSD empty, :10930 refused, nearby ports quiet) and Yunmo :8200 also failed. Keep Nav QR open on the dash. If this is Kove/Thinkerride, check [DISC] thinkerride-scan in Share Logs."` + ERROR `"Bike Wi‑Fi is up but EasyConn is offline — keep the pairing QR open on the dash"` | — | — |

Sources: `EasyConnDiscovery.kt:30-46, 55-114, 160-221`, `EasyConnProber.kt:384-447`, `YunmoLink.kt:112, 145`.
"Worst case" is **D** (sum of timeouts/sleeps; refused connections fail fast so real runs are shorter).
Rationale for the order: "Many SoftAP dashes (e.g. Morini ML*) do not accept the classic wake probe on :10930 even
while Wi-Fi is fine — they advertise `_EasyConn._tcp.` (or listen on a nearby port)" (`EasyConnDiscovery.kt:21-23`);
"SoftAP: wake sometimes only re-arms mDNS — try NSD once more" (`EasyConnProber.kt:389`).
**Note:** on dashes without mDNS (450NK, `RE-VEHICLE-TELEMETRY.md:53-54`) every fresh connect waits the full 12 s
before touching :10930 (`control-plane.md` §18.5 proposes racing both on iOS).

**NSD details** (`EasyConnDiscovery.kt:55-154`) — V-CODE: type `"_EasyConn._tcp."`, protocol DNS-SD; on the
first found service resolve it; accept if port ∈ 1…65535 and the host is IPv4 (`hostAddresses` on API ≥ 34, else
`host`) and not loopback/any/multicast; stop discovery after success or timeout. TXT read only for logging:
`packagename`, then `packageName`, then `package` (exact key, then case-insensitive), UTF-8, trimmed, blank → nil.
The dash's TXT record carries `huid, huname, channel, flavor, port, ip` (**V-HW**,
`01-REVERSE-ENGINEERING.md:44-45`); the app does **not** use TXT `ip`/`port`. Logs: `[DISC] discovering
_EasyConn._tcp.…`, `[DISC] found service name=<n> — resolving`, `[DISC] NSD → <ip>:<port>[ pkg=<pkg>]`,
`[DISC] resolve failed for <n>: <code>`, `[DISC] NSD timed out / no usable EasyConn advertisement`.

### 5.3 The probe (`probeTarget`, `EasyConnProber.kt:485-537`) — V-HW payload, V-CODE timing

Per attempt (`attempt` = 1…N, loop exits early on `probed` or `!running`):
1. re-bind process; log `"[PROBE] connect #<attempt> -> <host>:<port>"`; open a bike-pinned socket (§3.9).
2. `connect` timeout **3000 ms**; read timeout **5000 ms**.
3. Write CmdBaseHead `cmd = 0x70000010` (ECP_PXC_MDNS_RESPOND) with the **fixed** payload (built as a literal,
   key order fixed): `{"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}`
   (`EasyConnProber.kt:44, 590-591`; **V-HW** `01-REVERSE-ENGINEERING.md:72-74`).
4. Read one frame. EOF → `"[PROBE] bike closed before responding"`. Else log `"[PROBE] <- cmd=0x… <body>"`;
   **accepted iff `cmd == 0x70000011` and the UTF-8 body contains the substring `true`** → `"[PROBE] *** accepted —
   bike should now connect back to our ports ***"`, `probed = true`. Otherwise `"[PROBE] !! not accepted: <body>"`.
   Bad magic etc. → exception → failed attempt.
5. Close the probe socket (always).
6. If not accepted: sleep **750 ms × attempt** (also after the last attempt): 750, 1500, 2250, 3000, 3750 ms.
   Totals: 2 attempts 2250 ms, 3 → 4500 ms, 5 → 11 250 ms (**D**).
7. A VPN-bypass EPERM aborts the attempt loop with ERROR, unless the bike already connected this session
   (`"!! ignoring VPN bind blip — bike already linked this session; will retry"`).

Bytes (**D**, identical to `control-plane.md` §2.3):
```
probe   0x70000010, payload 70 B, totalLen 86 (0x56), magic 0x70000046
0000  10 00 00 70 56 00 00 00 46 00 00 70 00 00 00 00  |...pV...F..p....|
0010  7b 22 70 68 6f 6e 65 54 79 70 65 22 3a 22 41 6e  |{"phoneType":"An|
0020  64 72 6f 69 64 22 2c 22 70 61 63 6b 61 67 65 4e  |droid","packageN|
0030  61 6d 65 22 3a 22 63 6f 6d 2e 63 66 6d 6f 74 6f  |ame":"com.cfmoto|
0040  2e 63 66 6d 6f 74 6f 69 6e 74 65 72 6e 61 74 69  |.cfmotointernati|
0050  6f 6e 61 6c 22 7d                                |onal"}|
accept  0x70000011 {"status":true}  totalLen 31 (0x1f), magic 0x7000000e
0000  11 00 00 70 1f 00 00 00 0e 00 00 70 00 00 00 00  7b 22 73 74 61 74 75 73 22 3a 74 72 75 65 7d
reject  0x70000011 {"status":false} totalLen 32 (0x20), magic 0x70000031
0000  11 00 00 70 20 00 00 00 31 00 00 70 00 00 00 00  7b 22 73 74 61 74 75 73 22 3a 66 61 6c 73 65 7d
```

### 5.4 Connect-back expectations — V-HW sequence, GAP on timing

After acceptance the dash opens, in this order (**V-HW**, `01-REVERSE-ENGINEERING.md:75-95, 232-233`):
:10922 (CAR_CTRL select `0x10000`) → CLIENT_INFO → QUERY_SPEED → a **second** :10922 (CAR_DATA `0x20000`) →
CHECK_SN (+ on CFDL26/newer units a notify burst that must be acked, else the dash "goes silent and closes after
the ~9s timeout") → :10921 (media control) → :10920 (media data, frame pulls). Details: `control-plane.md` §5–§11,
`media-video.md`.

- Each accepted socket: log `"[:<port>] <<< bike connected from <addr>"`, `everConnected = true`,
  **`reconnectAttempts = 0`**, `liveConns += 1`, tracked in `activeClients`, reader thread `ec-conn-<port>`
  (`EasyConnProber.kt:593-612`). Accepted sockets: no read timeout, `TCP_NODELAY` (`:664-665`).
- Framing by **local port**: 10922 → CmdBaseHead control loop; 10921/10920 → ReqBase media loop (`:668-682`).
- First frame written to the dash ⇒ phase **STREAMING** (`:806-818`).
- **GAP:** there is **no timeout** between "probe accepted" and the first call-back. If the dash accepts but
  never calls back, the phase stays `PXC_CONNECTING` indefinitely (the 5 s log line keeps printing
  `probed=true … framesSent=0`); the watchdog does not act on that phase. **iOS: add a connect-back timer
  (recommend 10 s) → re-run discovery.**

### 5.5 Session keep-alives that drive timers — V-HW / V-CODE

- **Phone-initiated PXC heartbeat** `0x70000000` (empty) **every 2000 ms on each :10922 channel socket**
  (CAR_CTRL and CAR_DATA), one sender per socket, started when the dash selects the channel, stopped when the
  socket closes or the session stops. The US 800NK (CRCP, sdk 0.9.23.x) sends none itself and tears the session
  down after **~7 s** of silence on either socket (`EasyConnProber.kt:49-50, 73-77, 1044-1079`).
- Dash heartbeats `0x70000000` → reply `0x70000001`; media heartbeat 64 → 65 (`control-plane.md` §10.3, `media-video.md`).
- The dash drops the media connection if it gets **no frame for ~9 s** (`socketTimeoutPeriodWifi = 9`)
  (**V-HW** `01-REVERSE-ENGINEERING.md:19-20`). If no frame is ready for a pull (`pollFrame(1500)` → nil) Android
  sends **nothing** for that request (`EasyConnProber.kt:806-818`); the dash does not re-request, so the stall
  ends in the dash's 9 s timeout or the phone watchdog (§6.5). See `media-video.md` §5.4–§5.5.

---

## 6. Session state machine and every timer

### 6.1 Phases — V-CODE (`ConnectionState.kt:15-27`)

| Phase | UI label (`strings.xml:529-539`) / log label | busy |
|---|---|:-:|
| `IDLE` | Ready / `Ready` | no |
| `STARTING_AA` | Starting Android Auto… (AA only) | yes |
| `AA_VIDEO_LIVE` | Android Auto live — joining bike… (AA only) | yes |
| `JOINING_WIFI` | Connecting to bike Wi-Fi… | yes |
| `PXC_CONNECTING` | Linking to dashboard… | yes |
| `STREAMING` | Connected — projecting to dash | no |
| `MIRRORING` | Mirroring screen to dash (also used as the *starting* label of Map/Mirror sessions) | no |
| `RECONNECTING` | Link dropped — reconnecting… | yes |
| `WAITING_FOR_BIKE` | Bike out of range — waiting… (AA park only) | yes |
| `STOPPED` | Stopped | no |
| `ERROR` | Error — see logs | no |

`ConnectionState.set(phase, detail?)`: a nil detail **keeps** the previous detail (`ConnectionState.kt:48-58`);
every transition logs `"[state] <logLabel>"` or `"[state] <logLabel> — <detail>"`. The Connect button acts as
**Stop** while `busy`, STREAMING or MIRRORING (`MainActivity.kt:527-532, 898-912`).
**Quirk (GAP):** after a reconnect `STREAMING` is set without detail, so the label keeps `"attempt N"`
(`EasyConnProber.kt:628, 814`). iOS: set the bike name as detail on STREAMING.

### 6.2 Every transition (who sets what) — V-CODE

| From → To (detail) | Trigger | Source |
|---|---|---|
| any → `MIRRORING` (bike name or ssid) | Map or Mirror session start | `MainActivity.kt:101, 1702, 1749` |
| any → `STARTING_AA` (bike name) | AA connect / resume | `MainActivity.kt:194`, `AndroidAutoService.kt:254` |
| → `AA_VIDEO_LIVE` | AA steady video | `MainActivity.kt:205`, `AndroidAutoService.kt:265` |
| → `JOINING_WIFI` (keep / `"Waiting for bike on phone hotspot…"`) | joinWifi / hotspot flow | `MainActivity.kt:1031, 1125, 1148` |
| → `PXC_CONNECTING` | Wi-Fi bound (Map/Mirror), both AA gates ready, P2P/hotspot bound | `MainActivity.kt:1102, 1218, 1267, 1298`, `BikeLink.kt:100` |
| → `PXC_CONNECTING ("reconnecting")` | Wi-Fi re-acquired | `BikeLink.kt:129` |
| → `STREAMING` | first frame sent this (re)connection; soft Map attach | `EasyConnProber.kt:814, 292`, `AndroidAutoService.kt:604` |
| → `RECONNECTING ("attempt N")` | all bike sockets closed after ≥1 call-back | `EasyConnProber.kt:628` |
| → `RECONNECTING ("waiting for bike Wi-Fi")` | Wi-Fi re-request fired (unless WAITING_FOR_BIKE) | `BikeWifi.kt:252-254` |
| → `WAITING_FOR_BIKE ("will resume when the bike is back" / "tap to resume")` | AA park / resume fallback | `AndroidAutoService.kt:232, 289` |
| → `STOPPED ("")` | Stop button / notification Stop / AA exit | `MainActivity.kt:1472`, `AndroidAutoService.kt:651` |
| → `ERROR` | see list below | — |

ERROR details (verbatim): `"VPN kill-switch blocking bike Wi‑Fi"` (`EasyConnProber.kt:183, 430, 529`);
`"close the official CFMoto app, then reconnect"` (`:216`); `"Bike Wi‑Fi is up but EasyConn is offline — keep the
pairing QR open on the dash"` (`:442-445`); `"lost bike link"` (`:624`); `"phone Wi‑Fi is off"` (`WifiGate.kt:48, 62`);
`"Approve the phone's Wi‑Fi / device picker (don't leave it open), then Connect again"` (`BikeWifi.kt:194-196`);
`"Wi‑Fi Direct failed"` (`MainActivity.kt:1283`); `"prober start failed"`, `"prober restart failed"`
(`BikeLink.kt:106, 139`); `"Phone hotspot setup cancelled"`, `"No phone hotspot found — enable Android hotspot with the
dash SSID/password, then Connect again"`, `"Hotspot is up but the dash wasn't found — keep the pairing screen open and
retry"`, `"hotspot scan failed"` (`MainActivity.kt:1131, 1176, 1199, 1234`); `"Map switch failed — Stop, then Map"`
(`AndroidAutoService.kt:607`); `"Yunmo link dropped"` (`YunmoLink.kt:471`, X); AA-only details
(`MainActivity.kt:252, 259, 293, 798`).

### 6.3 Start flows

**(a) Own-content Map path and Mirror path — the iOS-relevant flow** (`MainActivity.kt:1694-1755`) — V-CODE
```
tearDownForModeSwitch (stop AA service, stop prober, keep Wi-Fi; mirror path keeps its capture token)
applyProfile(saved QR)                      // §2.16
phase = MIRRORING(bike name)
joinWifi(qr, gateOnAaSteady = false)        // §3.1
  SoftAP onAvailable -> remember "AP"; phase = PXC_CONNECTING; prober.start(network)
  P2P onConnected    -> remember "P2P"; phase = PXC_CONNECTING; prober.start(nil, gw, bindIp)
  hotspot peer found ->                     phase = PXC_CONNECTING; prober.start(nil, peer, bindIp)
discovery + probe (§5.2) -> call-back -> handshake -> REQ_RV_DATA_START(112) creates the owned
video pipeline at the negotiated canvas -> first frame -> STREAMING
```
The Map Presentation also starts the foreground service in "GPX wake" mode, which runs the watchdog of §6.5
but never the AA park supervisor (`VideoPipeline.kt:510-512`, `AndroidAutoService.kt:75-89, 169-175`).

**(b) Android-Auto path (reference only)** — parallel start: Wi-Fi join runs **in parallel** with AA boot; the
prober starts only when **both** "AA video steady" and "bike network ready" are signalled (`BikeLink.kt:26-108`),
so the dash is never probed before there are frames to serve. AA self-mode trigger at **900 ms**, one retry at
**4500 ms**, give-up ERROR at **18 000 ms** (`MainActivity.kt:215-253`). Not applicable to iOS.

### 6.4 Link-drop recovery: the re-probe loop — V-CODE (`EasyConnProber.kt:614-660`)

Entry: the **last** live bike socket closed (`liveConns` → 0) **and** `running` **and** `everConnected` **and**
not already re-probing. Budget **20** attempts (`MAX_RECONNECT_ATTEMPTS`, `:48`).
```
if reconnectAttempts >= 20: log "[reconnect] gave up after N attempts — tap Connect to retry";
                            phase = ERROR("lost bike link"); return
reprobing = true; phase = RECONNECTING("attempt " + (reconnectAttempts+1))
thread ec-reprobe:
  while running && liveConns == 0 && reconnectAttempts < 20:
     reconnectAttempts += 1
     backoff = min(500 + 500*reconnectAttempts, 4000) ms
     log "[reconnect] link lost — re-probing (attempt n/20) in <backoff>ms"; sleep(backoff)
     if !running || liveConns > 0: exit
     if cached IPs missing: log "[reconnect] no cached IPs — abort"; exit
     probed = false; framesSent = 0 (so the next first frame re-signals STREAMING); stop Yunmo
     probe bikeIp:10930, 2 attempts                         // fast path
     if not accepted: NSD browse (<=12 s) -> probe result, 2 attempts
     if not accepted: Yunmo :8200 fallback (X)
     sleep 2500 ms   // "Give the dash a moment to connect back"
  finally reprobing = false
```
Backoff table (**D**): 1000, 1500, 2000, 2500, 3000, 3500, then 4000 ms (sum over 20 attempts = 69.5 s). With
refused probes and an empty NSD each iteration costs ≈ backoff + 2.25 s + 12 s + 2.5 s → ≈ **6.7 min** for the
whole budget (**D**). The port scan is **not** part of the reconnect loop. A new call-back resets the counter
(`:601`).

**GAP (important):** when the loop exits because the budget is exhausted, it does **not** set ERROR. ERROR
`"lost bike link"` is only set the *next* time `onAllConnectionsClosed()` runs — which needs another socket close
or a watchdog re-arm (which itself resets the budget). In practice the phase can stay
`RECONNECTING ("attempt 1")` forever after ~6.7 min of failures while Wi-Fi stays up. iOS: set
`ERROR("lost bike link")` directly when the budget is exhausted.

**GAP:** if the **first** connection never happened (`everConnected == false`), nothing retries: the initial
ladder ends in ERROR, and `rearmFromError` → `onAllConnectionsClosed` returns immediately (`:370-375, 620-621`).
The watchdog then logs `"[watchdog] re-arming reconnect after error"` every ≥20 s while doing nothing. iOS:
retry discovery periodically (e.g. every 20 s) while on the bike Wi-Fi — the rider may simply not have opened the
QR screen yet.

### 6.5 Watchdog (5 s tick) — V-CODE (`AndroidAutoService.kt:104-154, 695-698`)

Runs while the foreground service runs (AA sessions, and Map sessions via the GPX-wake start). Every
**5000 ms** (first tick 5 s after start), only if Setup "Auto-recovery watchdog" is on (`auto_recovery`, default
**on**, `AppSettings.kt:45`) and the prober is running and not inside a soft-switch grace window:

| Condition | Action | Cooldown |
|---|---|---|
| phase `STREAMING` and `msSinceLastFrame() > 8000 ms` (STALL_MS) | log `"[watchdog] streaming stalled (<ms>ms, no frames) — recovering"`; `forceReconnect()`: close every live bike socket → the re-probe loop runs when the last one closes (`EasyConnProber.kt:346-364`) | `now − lastRecoveryAt > 20 000 ms` (ACTION_COOLDOWN_MS) |
| phase `ERROR` | `rearmFromError()`: if running and no live sockets → `reconnectAttempts = 0` → `onAllConnectionsClosed()` | `now − lastRecoveryAt > 20 000 ms` (ERROR_COOLDOWN_MS) |

**Mirror sessions do not get this watchdog** (I, from code): the Mirror path stops this service on the mode
switch and runs a separate MediaProjection service with no watchdog (`MainActivity.kt:164, 1699`,
`ProjectionService.kt`), so only the prober's own re-probe loop (§6.4) protects it.

`msSinceLastFrame()` = now − max(last EasyConn frame time, last Yunmo frame time); `Long.MAX` if none yet
(`EasyConnProber.kt:335-339`). The stall threshold (8 s) sits just under the dash's ~9 s media timeout. Both
actions share `lastRecoveryAt`. Soft AA→Map switch sets an **8000 ms** grace in which the stall check is skipped
(`AndroidAutoService.kt:591`). The watchdog does **not** act on `PXC_CONNECTING`, `RECONNECTING` or `MIRRORING`.
README: "Link drops — auto-recovery re-probes the bike with a larger reconnect budget and faster early retries;
after the budget is spent, the watchdog re-arms…" (`README.md:520-522`).

### 6.6 Wi-Fi-outage supervisor, "park" and "seamless resume" (Android-Auto path) — V-CODE

`tickReconnectSupervisor` (same 5 s tick, `AndroidAutoService.kt:156-196`): remember that STREAMING was reached;
requires auto-recovery, not parked, `sawStream`. **If a Map/GPX session is active it never parks** (resets the
timer, keeps the screen wake) — so on Android the own-content path has no park. Otherwise, if neither the AP
network nor a P2P group is up (`bikeTransportConnected(ap, p2p) = ap || p2p`, `:702-703`):
- "keep Wi-Fi after disconnect" on → never park;
- first observation → `"[AA] bike transport unavailable (ap=… p2p=…) — starting grace"`;
- after **GRACE_MS = 180 000 ms** → **park**: `"[AA] bike Wi-Fi gone > 180s — parking Android Auto to save battery;
  watching for the bike"`, `WAITING_FOR_BIKE("will resume when the bike is back")`, tear down AA + prober, release
  wake/Wi-Fi locks, keep the service so `BikeWifi` keeps re-requesting the AP (`:198-238`).
- Transport back before the grace ends → `"[AA] bike transport recovered (…)"`.
Code comment: `GRACE_MS = 180_000L // SoftAP blinks; 60s was parking mid-ride` (`:699`). **The README's
"~1 minute grace window" (`README.md:345-350`) is stale; the shipping value is 180 s.**

Resume (`:240-292, 715-730`): Wi-Fi re-acquired while parked → `requestResume()` → rebuild AA, re-arm the start
gate, trigger AA; if no steady video after **12 000 ms** (RESUME_STEADY_TIMEOUT_MS) re-trigger once; after another
12 000 ms → re-park, `WAITING_FOR_BIKE("tap to resume")` and a "Bike reconnected / Tap to resume projection to the
dash" notification (Android 12+ forbids background activity launch unless "Display over other apps" is granted,
`SetupHelper.kt:63-69`). Opening the app while parked also resumes if the bike is not clearly out of range
(`MainActivity.kt:702-721`). **iOS:** there is no AA to park; see §11.6 for the equivalent battery policy.

### 6.7 Mode switches — V-CODE

- **Hard switch** (Map/Mirror/AA start): stop the previous projection and prober, keep Wi-Fi, fresh
  `prober.start()` → new probe → dash re-connects (`MainActivity.kt:151-180`; reason: "Map / Mirror / stale PXC
  must die first — half-switches leave framesSent=0", `:190`).
- **Soft switch** (AA→Map while live, `AndroidAutoService.kt:576-610`, `EasyConnProber.kt:231-294`): keep PXC
  sockets, detach the old video source (`lastFrameAt = now`), attach a new owned pipeline (retry start once),
  `framesSent = 0`, request an IDR **immediately** and **again after 200 ms**, phase STREAMING, 8 s stall grace.
  Relevant if the iOS app swaps video sources inside one PXC session.
- Mirror duplicate-tap guard: while `MIRRORING`/`RECONNECTING` and the last frame was < **15 000 ms** ago, a second
  Mirror tap is ignored (`MainActivity.kt:1493-1508`).

### 6.8 Auto-start triggers — V-CODE

**Auto-connect on launch** (`MainActivity.kt:740-801`; called from `onCreate` once the setup wizard has been seen
and from every `onResume`): Setup "Auto-connect on launch" (`auto_connect`, default **on**, `AppSettings.kt:41`).
Conditions in order — not already latched this process; setting on; AA service not running; phase not busy /
STREAMING / MIRRORING; a saved bike exists (else log once `"→ Auto-connect idle: no bike paired."`); AA installed
(Android-only); phone Wi-Fi on (else prompt, **don't latch**, so it retries); `isSsidInRange(ssid) != false` (else
log once `"… not in range — will retry when its Wi-Fi appears"`). Then latch, log `"→ Auto-connect: '<name>'
(<Wi-Fi in range | range unknown — trying anyway>). Disable in Setup ▸ Startup."` and start the connect flow after
**1200 ms** (if the activity was recreated meanwhile, unlatch so the new instance retries).

**Bluetooth trigger** (`BtConnectTrigger.kt:17-41`, `MainActivity.kt:723-738`): optional bonded device MAC
(`bt_trigger_mac`); on its ACL connect, if no projection is running and a bike is saved, open the app and run
Connect. Not portable to iOS (no classic-BT ACL broadcasts).

### 6.9 Stop / teardown — V-CODE

`stopEverything()` (`MainActivity.kt:1459-1473`) and the notification Stop (`AndroidAutoService.kt:643-655`): stop
AA service, `prober.stop()`, stop mirror capture, clear the Map session, stop BLE clock, `BikeWifi.releaseSession()`
(§3.10), phase `STOPPED("")`. Closing the app (activity destroyed while no AA service runs) also stops the prober
and leaves Wi-Fi/P2P (`MainActivity.kt:810-834`). Swiping the task away keeps an AA/Map projection alive
(`AndroidAutoService.kt:657-665`).

`EasyConnProber.stop()` (`EasyConnProber.kt:296-323`): `running=false`, `probed=false`, `everConnected=false`,
`reprobing=false`; stop Yunmo; stop the video pipeline **only if owned**; interrupt the 5 s logger; reset touch
state; interrupt every per-socket heartbeat sender; close all client sockets; close all listeners; release the
multicast lock; log `"stopped"`.
**GAP (race, I):** the discovery and re-probe threads are not interrupted; they only re-check `running` after
their current sleep/timeout. After a quick `stop()`→`start()` (mode switch, Wi-Fi re-acquire) an old thread sees
`running == true` again and keeps probing with the **old** captured IPs and the shared counters. iOS: give each
session a generation token / `Task` and cancel all children on stop.

### 6.10 Master timer table

| Timer / threshold | Value | Status | Source |
|---|---|---|---|
| Wi-Fi first-join request timeout | 90 000 ms | V-CODE | `BikeWifi.kt:76` |
| Wi-Fi re-join request timeout | 12 000 ms | V-CODE | `BikeWifi.kt:77` |
| Retry after failed first join | 4 000 ms | V-CODE | `BikeWifi.kt:65` |
| First re-request after loss | 300 ms | V-CODE | `BikeWifi.kt:61` |
| Later re-requests | `min(2500 × (n−1), 15000)` ms | V-CODE | `BikeWifi.kt:62-63, 243-247` |
| Scan result "fresh" window | 30 s | V-CODE | `BikeWifi.kt:298` |
| P2P group-formation timeout | 40 000 ms (12 000 ms if SoftAP fallback) | V-CODE | `BikeWifiP2p.kt:49`, `MainActivity.kt:1250-1254` |
| P2P local-IP poll | every 500 ms, max 10 000 ms | V-CODE | `BikeWifiP2p.kt:50-51` |
| NSD browse | 12 000 ms | V-CODE | `EasyConnDiscovery.kt:31` |
| Port scan connect (10915–10935) | 350 ms per port | V-CODE | `EasyConnDiscovery.kt:32-34` |
| Wide (thinkerride) scan connect | 250 ms per port, 251 entries | X | `EasyConnDiscovery.kt:33, 40-46` |
| Probe connect / read | 3 000 / 5 000 ms | V-CODE | `EasyConnProber.kt:501-502` |
| Probe retry sleep | 750 ms × attempt (also after last) | V-CODE | `EasyConnProber.kt:535` |
| Probe attempts | NSD 3 (+3 after re-browse), gateway:10930 5, scanned port 2, reconnect 2+2 | V-CODE | `EasyConnProber.kt:387, 395, 401, 412, 645, 648` |
| Connect-back timeout | **none** (GAP; recommend 10 s) | GAP | — |
| Reconnect budget | 20 attempts | V-CODE | `EasyConnProber.kt:48` |
| Reconnect backoff | `min(500 + 500 n, 4000)` ms | V-CODE | `EasyConnProber.kt:634` |
| Wait for call-back after each re-probe | 2 500 ms | V-CODE | `EasyConnProber.kt:654` |
| PXC heartbeat (phone → dash, each :10922 socket) | 2 000 ms | V-HW (800NK fix) | `EasyConnProber.kt:50` |
| 800NK teardown after :10922 silence | ~7 s | V-HW (field) | `EasyConnProber.kt:1048-1051` |
| Dash media timeout without frames | ~9 s (`socketTimeoutPeriodWifi = 9`) | V-HW | `01-REVERSE-ENGINEERING.md:19-20` |
| Frame poll per pull (114) | 1 500 ms | V-CODE | `EasyConnProber.kt:807` |
| Diagnostic heartbeat log | 5 000 ms | V-CODE | `EasyConnProber.kt:1085` |
| Watchdog tick | 5 000 ms | V-CODE | `AndroidAutoService.kt:695` |
| Stall threshold (STREAMING, no frame) | 8 000 ms | V-CODE | `AndroidAutoService.kt:696` |
| Min gap between forced reconnects | 20 000 ms | V-CODE | `AndroidAutoService.kt:697` |
| Min gap between ERROR re-arms | 20 000 ms | V-CODE | `AndroidAutoService.kt:698` |
| Soft-switch stall grace | 8 000 ms | V-CODE | `AndroidAutoService.kt:591` |
| Second IDR after soft attach | +200 ms | V-CODE | `EasyConnProber.kt:288-291` |
| Wi-Fi-outage grace before AA park | 180 000 ms (README says ~60 s: stale) | V-CODE | `AndroidAutoService.kt:699` |
| AA resume steady-video wait | 12 000 ms, twice | V-CODE | `AndroidAutoService.kt:700, 273-281` |
| Auto-connect delay | 1 200 ms | V-CODE | `MainActivity.kt:785-800` |
| Rival-app "Close & retry" reconnect delay | 1 500 ms | V-CODE | `MainActivity.kt:960` |
| Mirror duplicate-tap guard | 15 000 ms since last frame | V-CODE | `MainActivity.kt:1500` |
| Phone-hotspot tether poll | 30 rounds × 1 500 ms (~45 s) | X | `MainActivity.kt:1152-1166` |
| Phone-hotspot host probe | 250 ms per host:port, ≤48 hosts × 4 ports | X | `PhoneHotspotScan.kt:25-26, 84` |
| Yunmo connect / canvas reply | 5 000 / 5 000 ms | X | `YunmoLink.kt:112, 145` |
| Touch: UP hold (stitch) / stale pointer | 80 ms / 300 ms | V-CODE | `EasyConnProber.kt:57, 64` (see `media-video.md`) |
| Wake lock (Android) | 4 h | V-CODE | `AndroidAutoService.kt:302` |

### 6.11 Threads and concurrency (Android) — V-CODE

Per session: `ec-accept-10922/10921/10920` (blocking accept), `ec-conn-<port>` per bike socket (blocking reads),
`ec-probe` (discovery), `ec-reprobe` (one at a time, guarded by `reprobing`), `ec-pxc-hb-CAR_CTRL` /
`ec-pxc-hb-CAR_DATA` (2 s senders), `ec-hb` (5 s log), `ec-touch-stitch` (scheduler); plus `p2p-timeout`,
`p2p-ip-poll`, `phone-hotspot-scan`, `yunmo-send`/`yunmo-recv`. Shared state uses `@Volatile` flags,
`AtomicInteger liveConns` and a synchronized client list; writes to one socket are serialized by
`synchronized(out)` so heartbeats and replies never interleave (`PxcFrame.kt:29-33`). The watchdog and supervisor
run on the main looper. The process-global `BikeLink.prober` survives Activity recreation (`BikeLink.kt:10-23`).

---

## 7. Phone-hotspot mode (`action=128`: the dash joins the phone) — X

### 7.1 How it works on Android — V-CODE, unconfirmed in the field

1. QR is format B/C (`supportsPhoneHotspot && pwd.isEmpty`) → `joinPhoneHotspot` (`MainActivity.kt:1116-1134`);
   phase `JOINING_WIFI("Waiting for bike on phone hotspot…")`.
2. Android apps cannot create a hotspot with a chosen SSID/password, so a dialog **"Phone hotspot setup"** asks the
   rider to type the SSID/password **shown on the dash** ("reminder only"), then open system hotspot settings and
   set exactly those values; it shows the QR MAC (`PhoneHotspotAssist.kt:17-24, 75-125`; text `strings.xml:562-570`).
   The typed values are stored in plain text (§8.5). Buttons: Cancel → ERROR `"Phone hotspot setup cancelled"`;
   "Open hotspot settings" (tries `android.settings.TETHER_SETTINGS`, `com.android.settings/.TetherSettings`,
   wireless, Wi-Fi, settings) → continue; "Hotspot is on — scan" → continue.
3. Poll for a tethering subnet: up to **30 × 1500 ms** (`MainActivity.kt:1137-1187`). `tetheringSubnets()`
   (`PhoneHotspotScan.kt:57-81`): interfaces up, not loopback, not point-to-point; IPv4, not loopback/link-local/
   any, **site-local** (10/8, 172.16/12, 192.168/16), prefix **24…30**; sorted by interface-name prefix rank
   `ap`, `swlan`, `wlan1`, `softap`, `rndis`, `tether`, then others. None → ERROR "No phone hotspot found…".
4. Take the first subnet; NSD browse (≤12 s) → peer host; else `findEasyConnPeer`: hosts nearest the phone first,
   up to **48**, each tried on ports **10930, 10920, 10921, 10922** with **250 ms** connects; first open port wins
   (`PhoneHotspotScan.kt:83-131`). None → ERROR "Hotspot is up but the dash wasn't found…".
5. Start the prober with `network = nil, gatewayOverride = peer, bindIpOverride = <phone's tether IP>` →
   the normal ladder of §5.2 against the peer (`MainActivity.kt:1208-1229`).

Gaps (**I**): the poll accepts *any* qualifying subnet, so a phone also connected to some other Wi-Fi (`wlan0`,
not in the rank list but still qualifying) can be picked immediately and the dash searched on the wrong network;
there is no re-join logic and the cached peer IP is reused on reconnect (a new DHCP lease breaks it); and the
"phone Wi-Fi is off" gate (§3.7) runs before the hotspot branch, so on phones that switch Wi-Fi (client) off while
the hotspot is on, a second Connect is blocked with `"phone Wi‑Fi is off"`. Field status:
no doc confirms a working phone-hotspot session (Zontes 368G "TFT often keeps the pairing QR", `README.md:162`).

### 7.2 Test vectors (`test/PhoneHotspotScanTest.kt`, verbatim) — V-CODE

```kotlin
@Test fun prefersApPrefixedInterfaces() {
    val ap = iface("ap0", "192.168.43.1", 24)
    val wlan = iface("wlan0", "192.168.1.10", 24)
    val subnets = PhoneHotspotScan.tetheringSubnets(listOf(wlan, ap))
    assertEquals(2, subnets.size)
    assertEquals("ap0", subnets.first().interfaceName)
}
@Test fun candidateHostsPreferNearPhone() {
    val subnet = PhoneHotspotScan.Subnet(
        localAddress = InetAddress.getByName("192.168.43.1") as Inet4Address,
        prefixLength = 24, interfaceName = "ap0")
    val hosts = PhoneHotspotScan.candidateHosts(subnet, limit = 5)
    assertEquals(5, hosts.size)
    assertEquals("192.168.43.2", hosts[0].hostAddress)
    assertTrue(hosts.none { it.hostAddress == "192.168.43.1" })
}
// iface(name, ip, prefix) = InterfaceSnapshot(name, isUp=true, isLoopback=false, isPointToPoint=false,
//                                             addresses=listOf(InetAddress.getByName(ip) to prefix))
```

`candidateHosts(subnet, limit = 48)`: all host addresses `network+1 … network+size−2` except our own, **stable**-sorted
by `|addr − ours|` (ties keep ascending order), first `limit` (`PhoneHotspotScan.kt:84-106`). Derived (**D**):

| Subnet / limit | Result |
|---|---|
| `192.168.43.1/24`, 5 | `.2, .3, .4, .5, .6` |
| `192.168.43.1/24`, 48 | `.2 … .49` |
| `192.168.43.100/24`, 8 | `.99, .101, .98, .102, .97, .103, .96, .104` |
| `172.20.10.1/28`, 48 (iPhone hotspot plan) | `.2, .3, …, .14` (13 hosts) |

### 7.3 Is it viable on iOS (Personal Hotspot)? — I

- **Mechanics fit:** an iPhone Personal Hotspot is `172.20.10.1/28` (clients `.2–.14`); the hotspot bridge interface
  (usually `bridge100`) is visible to `getifaddrs`; prefix 28 passes the 24…30 filter; a full host sweep is
  13 hosts × 4 ports × 250 ms ≈ 13 s worst case. Listeners and outbound probes over the bridge need the Local
  Network permission. Internet stays on cellular naturally (no Wi-Fi association).
- **Friction:** iOS apps cannot enable the hotspot or set its SSID/password. The SSID **is the device name** and
  the password is user-set (≥ 8 chars), so the rider must rename the iPhone to the SSID shown on the dash and set
  the password — awkward. Carriers may block tethering. Newer iPhones default the hotspot to 5 GHz unless
  "Maximize Compatibility" is on (a 2.4 GHz-only dash would not see it). "Allow Others to Join" must be on.
- **Verdict:** technically plausible, **unverified on Android and iOS**, poor UX. Treat as a low-priority,
  experimental transport that reuses the same prober with `gatewayOverride = discovered dash`,
  `bindIp = 172.20.10.1`. It is the only way to reach `action=128`-only dashes.

---

## 8. What is persisted

All Android preferences below are `SharedPreferences` files in the app sandbox, **plain text**, and the app has
`allowBackup="true"` with empty backup rules (so they are cloud-backed up) (`AndroidManifest.xml:64-66`,
`res/xml/backup_rules.xml`). **V-CODE**

### 8.1 Garage — `BikeMemory` (file `opencfmoto_bike`, `BikeMemory.kt:25-158`)

| Key | Format | Meaning |
|---|---|---|
| `bikes_json` | JSON array, most-recently-saved first: `[{"raw":"<raw QR text>","name":"<display name>","photo":"<abs path>"}, …]` (`photo` omitted when none) | the garage. The **raw QR string** is stored, not parsed fields: re-parsing reproduces the exact `QrData` and profile choice (`:20-23`). Entries with blank `raw` are skipped; blank `name` → `raw`. |
| `selected_raw` | string = one entry's `raw` | the bike one-tap Connect/auto-connect uses; if missing or stale → the first entry (`:56-61`) |
| `last_qr_raw`, `last_bike_name` | legacy single-bike keys | migrated once into `bikes_json` when that key doesn't exist; left in place (`:30-32, 143-154`) |
| `transport_<ssid>` | `"AP"` or `"P2P"` | transport that last brought Wi-Fi up for this SSID (written on success only; never cleared on failure) (`:34-35, 108-124`; writers `MainActivity.kt:1096, 1262, 1295`) |

Operations: `save(raw, qr)` moves/creates the entry at the front, keeps an existing custom name/photo, otherwise
name = `qr.name` if not blank else `qr.ssid`, and selects it (`:63-75`); `select`, `rename` (blank keeps), `setPhoto`,
`remove` (clears selection if it was selected), `clear`. Photos: downscaled JPEG (quality 85, ≤ ~1440 px) at
`files/bike_photos/<BikeScope id>.jpg` (`GarageActivity.kt:243-258`).

**Quirk (GAP):** identity is the full raw string, but the QR `sn` is a per-scan nonce (`01-REVERSE-ENGINEERING.md:33`),
so **re-scanning the same bike adds a second garage entry** with a new per-bike settings namespace (§8.3). The
SSID-keyed data (transport, canvas) survives. iOS: identify a bike by SSID (or SSID + MAC), keep the latest raw.

### 8.2 Learned dash geometry — `DashMemory` (same file, `DashMemory.kt:14-82`)

| Key | Format | Meaning |
|---|---|---|
| `dash_geo_<ssid>` | `"<w>x<h>"`, decimal, e.g. `"800x951"` | the **unrounded** `REQ_RV_CONFIG_CAPTURE` width×height the dash asked for (`EasyConnProber.kt:740-743`). Written on every config-capture with w,h > 0 when an SSID is known; logs `"[panel] learned: this bike's screen is <w>x<h> — next connect will fit AA resolution + match-aspect margins to it"` on change. Read back only if both parse and lie in 1…8192. Keyed by the *selected* bike's QR SSID (exact string, case-sensitive). |
| `last_dash_touch` | boolean | whether the active profile advertised a touchscreen at the last connect (UI hint) |

On the next connect the learned canvas can replace the profile's panel guess (§2.16). **iOS:** keep the same key
semantics to pre-size the renderer/encoder before the dash asks.

### 8.3 Per-bike settings namespace — `BikeScope` (`BikeScope.kt:9-62`)

Scoped key = `"<base>#<id>"`, `id = "b" + Integer.toHexString(raw.hashCode())` — Java `String.hashCode` over UTF-16
code units (`h = 31*h + c`, 32-bit wrap), printed as **unsigned lowercase hex, no padding**. Reads fall back to the
unscoped global key; writes go to the scoped key (global if no bike selected). Scoped bases: `video_quality`,
`screen_fit`, `power_mode`, `resolution_mode`, `mirror_orientation`, `aa_dpi_override`, `match_aspect_mode`,
`match_aspect_on` (legacy), `match_aspect_w`, `match_aspect_h`, `profile_override`, the button-gesture keys,
`controlAa`, `volume_rocker`, `track_keys`, cluster preset `active` (`VideoPrefs.kt:114-128`, `ProfileOverride.kt:40-53`,
`ButtonMap.kt:81-146`, `ButtonMode.kt:19-29`, `ButtonPresencePrefs.kt:24-84`, `ButtonClusterPreset.kt:94-112`).
**Not** per bike: Wi-Fi transport, auto-connect, auto-recovery, keep-Wi-Fi, screen margins (file `screen_margins`).

Vectors (**D**, Java and Python agree):

| raw | id |
|---|---|
| `http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37426&sn=Vasr&action=1&ssid=CFMOTO4288&pwd=e278450c&uid=abc` | `bae532b19` |
| `CARBITDC0D3024876D` | `b2c2476f8` |
| `http://g.thinkerride.com?CQKY_5e1c6cb10&81316044&ap=1` | `bcd8769cf` |
| `a` | `b61` |
| (empty string) | `b0` |

(iOS needs this only to import Android data; otherwise prefer a stable bike UUID.)

### 8.4 Connection-related global settings — `AppSettings` (file `opencfmoto_bike`, `AppSettings.kt:21-181`)

| Key | Type / default | Meaning |
|---|---|---|
| `auto_connect` | bool / **true** | auto-connect on launch (§6.8) |
| `auto_recovery` | bool / **true** | watchdog + Wi-Fi supervisor (§6.5–6.6) |
| `wifi_transport` | `"auto"`/`"ap"`/`"p2p"` / **auto** | §3.1 (unknown → auto) |
| `keep_wifi_after_disconnect` | bool / **false** | park instead of leave (§3.10) |
| `include_secrets_in_logs` | bool / **false** | disables redaction (§9.2) |
| `bt_trigger_mac`, `bt_trigger_name` | string / unset | BT-trigger device (§6.8) |
| `anonymous_telemetry` | bool / **true** | ERROR details are uploaded (redacted, ≤ 2000 chars, ≥ 30 min apart) (`AnonymousTelemetry.kt:56-68`) |
| `bluetooth_clock_sync`, `clock_lab_query`, `clock_lab_timesync` | — | clock experiments (`control-plane.md` §13) |

### 8.5 Phone-hotspot reminder — `PhoneHotspotAssist` (file `opencfmoto_phone_hotspot`)

`dash_hotspot_ssid` (trimmed), `dash_hotspot_pwd` — **plain text** (`PhoneHotspotAssist.kt:27-46`). Logged only as
`ssid='…' pwdLen=<n>`.

### 8.6 Not persisted

Phone/bike IPs, NSD endpoints, probe results, P2P addresses, hotspot peer — all re-discovered every session.
The phone CLIENT_INFO `phoneUUID` is regenerated per process (`PxcHandshake.kt:23`).

### 8.7 Settings export — `SettingsBackup` (`SettingsBackup.kt:21-177`)

`{"format":"opencfmoto.settings","version":1,…,"settings":{…,"wifiTransport":"auto|ap|p2p",…}}` — exports the
transport but **never** QR passwords, SSIDs, serials, bike names or photos. Import applies to the selected bike.

---

## 9. Diagnostics and logging

### 9.1 Log sink — V-CODE (`LogBus.kt`)

- One process-wide buffer. Each line: `"HH:mm:ss.SSS  <message>"` (two spaces, `Locale.US`), redacted first unless
  secrets are enabled (`LogBus.kt:29-38`). Buffer > 512 KiB → keep the last 256 KiB. Mirrored to logcat tag
  `"OpenCfMoto"`. `logThrottled(key, msg, 500 ms default)` for hot paths (touch MOVE uses 400 ms).
- Session banner on start / after Clear: `[BUILD] versionName=… versionCode=… git=… flags=…`, a `[CLOCK-LAB]` line,
  `[BUILD] --- session start ---` (`LogBus.kt:67-80`).
- Crash safety: the session log is persisted (≤ 256 KiB) to `files/last_session.log` on pause and restored once on
  the next start; fatal crashes to `files/last_crash.txt` (`CrashGuard.kt:27-33, 67-120`).
- Share: `cache/logs/opencfmoto-yyyyMMdd-HHmmss.log` (+ crash file, + H.264 dumps) via the share sheet
  (`MainActivity.kt:1531-1567`); "Report a problem" adds `profile=`, `override=`, `transport=`, `margins=`,
  `forceNonTouch=`, `forceTouch=`, `ssid=`, `phase=` (`MainActivity.kt:1651-1666`).

### 9.2 Redaction — V-CODE (`LogRedactor.kt:14-43`, test `test/LogRedactorTest.kt`)

Applied in this order to every line when `include_secrets_in_logs` is false (default). Patterns are Kotlin
raw strings (= literal regex text), all compiled case-insensitive:

```
1 JSON secrets   ("(?:password|pwd|passphrase|psk|btPin)"\s*:\s*)"[^"]*"    ->  <g1>"«redacted»"
2 URL/kv secrets \b(pwd|password|psk|passphrase)=([^&\s"]*)                 ->  <g1>=«redacted»
3 JSON serials   ("(?:HUID|sn|uuid|carHuid)"\s*:\s*)"([^"]*)"               ->  <g1>"<maskTail(g2)>"
4 bare serials   \b(carHuid|HUID|sn)=([A-Za-z0-9]{6,})                      ->  <g1>=<maskTail(g2)>
```

`maskTail(v)` = `v` if ≤ 4 chars, else first 4 chars + `"…"` (U+2026) + `"*"` × min(len − 4, 8). The mask is
`"«redacted»"` (U+00AB / U+00BB). Replacements are literal (no `$` interpretation). SSIDs and model ids are kept on
purpose.

Repo tests: `"qr ssid=CFMOTO-x&pwd=supersecret&modelid=1"` → contains `pwd=«redacted»`, not `supersecret`, keeps
`ssid=CFMOTO-x`; `{"HUID":"CRCP230501740"}` → contains `CRCP`, not the full serial (`test/LogRedactorTest.kt:10-23`).

Derived (**D**):

| Input | Output |
|---|---|
| `{"HUID":"CRCP230501740"}` | `{"HUID":"CRCP…********"}` |
| `QR raw: http://…_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=…` | `…&pwd=«redacted»&auth=…` (`sn=peTz` kept: < 6 chars) |
| `…len=70 {"port":11021,"userName":"carbit_ec_ftp_ota","pwd":"$Example2024@"}` | `…"pwd":"«redacted»"}` |
| `CHECK_SN from bike: {"client_set":"easy_conn","sn":"DSXXZMHNFV3DEXEBB3PZ2"}` | `…"sn":"DSXX…********"}` |
| `carHuid=6GUVA2C00100055 HUName=CFDL16-6GUV` | `carHuid=6GUV…******** HUName=CFDL16-6GUV` |
| **`QR raw: http://admin.motomorini.com/app.html?Wifi=ML174167#12345678#dc0d30da1b6c&…`** | **unchanged — password `12345678` leaks** (GAP) |
| **`QR raw: http://g.thinkerride.com?CQKY_5e1c6cb10&81316044&ap=1`** | **unchanged — password leaks** (GAP) |

iOS: redact by **parsing** the QR (mask `pwd` in every format) instead of regex only, and never log the raw QR.

### 9.3 Stage tags (what each stage logs) — V-CODE

| Tag / prefix | Stage | Representative lines (verbatim templates) |
|---|---|---|
| `→ …` | UI flow decisions (MainActivity) | `→ Connect: reusing saved bike '<name>' (no scan needed)`, `→ transport memory: '<AP or P2P>' connected before for '<ssid>' — using it, skipping the dead path`, `→ QR says P2P-only; SSID '<s>' has no MAC — joining SoftAP first (skip Wi‑Fi Direct by MAC)`, `→ Wi-Fi bound; starting EasyConn PXC flow …`, `→ restarting bike link on re-acquired Wi-Fi`, `→ stopping everything (Android Auto + bike)` |
| (none) | Wi-Fi join (BikeWifi) | `requesting Wi-Fi join: <ssid> …`, `Wi-Fi joined: …`, `Wi-Fi re-acquired: …`, `Wi-Fi lost: …`, `re-requesting bike Wi-Fi (attempt N) …`, `Wi-Fi join unavailable after Ns …`, `Wi-Fi released` |
| `[wifi]` | link quality | `[wifi] link: 5180MHz (5GHz), rssi=-48dBm, tx=…Mbps, rx=…Mbps` |
| `[WIFI]` | Wi-Fi-off gate | `[WIFI] phone Wi‑Fi is OFF — prompting for Wi‑Fi settings` |
| `[P2P]` | Wi-Fi Direct | `[P2P] starting Wi-Fi Direct connect`, `[P2P] peer: name='…' addr=… status=… isGO=…`, `[P2P] conn: groupFormed=… isGO=… goAddr=…`, `[P2P] FAILED: <reason>` |
| `[HOTSPOT]` | phone hotspot | `[HOTSPOT] waiting for tether interface… (i/30) …`, `[HOTSPOT] using <iface> <ip>/<prefix>`, `[HOTSPOT] scanning N hosts on …`, `[HOTSPOT] peer <ip>:<port> open` |
| `[NET]` | cellular uplink | `[NET] requested cellular uplink (map/routing pin)`, `[NET] cellular/internet uplink available for map/routing` |
| (none) | prober start | `---- environment ----` … `our IP=<a>  bike IP=<b>`, `listening on <ip> ports [10922, 10921, 10920] (3 open)`, `bind :<port> failed: …`, `!! link ports are held by another app …`, `!! VPN …` |
| `[DISC]` | discovery | §5.2 |
| `[PROBE]` | probe | §5.3; plus socket-choice lines `[PROBE] socket via Network.socketFactory (VPN bypass)` etc. |
| `[:10922]`, `[:10921]`, `[:10920]` | per-port protocol | `[:10922] <<< bike connected from /192.168.0.1:…`, `[:10922] framing=CmdBaseHead (PXC control)`, `[:10921] framing=ReqBase (media plane) profile=…`, `[:10920] sent frame #N (Sb)` (N ≤ 5 or every 60th), `[:10920] REQ_RV_DATA_NEXT(114): no frame ready`, `[:10922] bike closed`, `[:10921] media closed` |
| `[hb]` | PXC heartbeat senders | `[hb] PXC CAR_CTRL heartbeat started (0x70000000 every 2000ms)`, `[hb] → PXC CAR_DATA heartbeat #N` (N ≤ 3 or every 15th) |
| `hb#` | 5 s status line | `hb#<i> probed=<bool> video=<bool> framesSent=<n>[ yunmoFrames=<n>] openServers=<n>` |
| `[reconnect]` | re-probe loop | §6.4 |
| `[watchdog]` | watchdog | `[watchdog] streaming stalled (…ms, no frames) — recovering`, `[watchdog] forcing reconnect — dropping N live socket(s)[ + Yunmo]`, `[watchdog] re-arming reconnect after error` |
| `[state]` | phase changes | `[state] Link dropped — reconnecting… — attempt 1` |
| `[AA]`, `[AA→MAP]`, `[MAP]`, `[GPX]` | service / mode switches | §6.6–6.7 |
| `[panel]`, `[match-aspect]`, `[profile]` | geometry/profile | `[panel] learned: …`, `[profile] scores=…` |
| `[YUNMO]` | Yunmo fallback (X) | `[YUNMO] EasyConn quiet — trying SoftAP Yunmo <ip>:8200` |
| `[VIDEO]`, `[CLOCK-LAB]`, `[BTN]`, `[BUILD]` | other specs | — |

### 9.4 Counters worth reproducing

`framesSent` (reset per (re)connection), `lastFrameAt`, `liveConns`, `reconnectAttempts`, `probed`, `everConnected`,
open listener count, per-socket heartbeat count. The 5 s `hb#` line is the main health signal in field logs.

---

## 10. Per-brand / per-dash connection quirks

| Dash / brand | Connection-relevant facts | Status | Source |
|---|---|---|---|
| CFMoto CFDL16 (675SR-R, 450SR, …) | SoftAP `CFMOTO-xxxxxx`, `192.168.0.1`, QR `action=9`, mDNS advertised; bike-initiated heartbeats | V-HW | `01-REVERSE-ENGINEERING.md:11-14, 26-54` |
| CFMoto CFDL26 800MT (AP) | `modelid=37426`, `action=1`, SoftAP `CFMOTO1565` at `192.168.0.1` | V-HW | `05-DEBUG-KNOWLEDGE.md:290-293` |
| CFMoto CFDL26 1000 MT-X | `DIRECT-CF-CFMOTO-805120` / `12345678`, legacy client join works, `192.168.49.1`; notify burst must be acked or media never opens (~9 s close) | V-HW | `01-REVERSE-ENGINEERING.md:207-237` |
| CFMoto US 800NK (CRCP) | Wi-Fi Direct family; dash sends no heartbeats; phone must heartbeat **both** :10922 sockets every 2 s or the dash drops after ~7 s | V-HW (field) | `EasyConnProber.kt:1044-1056` |
| CFMoto 450NK (no T-Box) | dash `192.168.49.1`, **no mDNS**, only :10930 open (transiently) | V-HW | `RE-VEHICLE-TELEMETRY.md:47-54` |
| CFMoto 450CL-C / CL-C450 | "Often Wi‑Fi Direct (P2P) — Setup → Wi‑Fi Auto or P2P"; GO may refuse a normal join | V-HW (field) / I | `SUPPORTED-BIKES.md:50`, `README.md:671`, `BikeWifiP2p.kt:26-29` |
| Any: official CFMoto / Carbit app running | holds 10920–10922 → bind failure / bike calls the other app → force-stop it | V-HW (field) | `EasyConnProber.kt:209-219`, `RivalClient.kt:13-22` |
| Zontes (P2P-only QR) | `action=8`, SSID `ZT5G…`, may carry `mac=`; SoftAP join with the SSID/pwd works | V-CODE | `MainActivity.kt:1071-1077`, `test/QrDataTest.kt:72-82` |
| Zontes (phone hotspot) | `action=128` + `bm=`, or `CARBIT<12 hex>` second QR; dash joins phone hotspot | X | `QrData.kt:56-58, 84` |
| Zontes 350E | "use the Apple QR; force-stop Carbit" | V-HW (field) | `README.md:147` |
| Zontes 368G (2025) | handshake + frames, TFT often keeps the pairing QR; 2026 units OK | X | `README.md:162` |
| Voge DS900X | Apple QR / Carbit path | V-HW (field) | `SUPPORTED-BIKES.md:65` |
| Voge "-5G" units | P2P-only QR without MAC burned ~40 s on MAC join → now SoftAP first | V-CODE | `MainActivity.kt:1071-1072` |
| QJ SRK800RR (2025) | iOS QR | V-HW (field) | `SUPPORTED-BIKES.md:77` |
| QJ 600SX / 550SX (2026) | QR works, SSID `qj-5G-*`, `modelid=37501`; force AP if Auto picks P2P | X (in progress) | `SUPPORTED-BIKES.md:81`, `README.md:163` |
| Moto Morini X-Cape 649/700, Seiemmezzo | `Wifi=SSID#PWD#MAC` QR; SoftAP `ML…`/`MLN_…`; may refuse :10930 → NSD / nearby-port scan | V-HW (field) / V-CODE | `SUPPORTED-BIKES.md:96`, `EasyConnDiscovery.kt:21-23` |
| Moto Morini X-Cape 1200 | SoftAP `192.168.4.1`, speaks **Yunmo :8200**, not EasyConn | X | `SUPPORTED-BIKES.md:69`, `YunmoLink.kt:19-30` |
| Benelli TRK 702/702X | dash shows SSID+password (no QR) → manual entry | V-HW (field) | `SUPPORTED-BIKES.md:70` |
| Longjia (V-Bob 650) | close the official companion app first (port holder) | I (unconfirmed brand) | `SUPPORTED-BIKES.md:101` |
| Kove (Thinkerride) | positional QR, SoftAP join only, neither EasyConn nor Yunmo; log-only port scan | X | `SUPPORTED-BIKES.md:108` |
| Ignition cycles (all) | Wi-Fi re-requested automatically; some firmwares need the QR screen once; dash may show "device is not on the network" → toggle Android ↔ iOS QR | V-HW (field) | `README.md:670`, `BikeWifi.kt:57-60` |

---

## 11. iOS implementation notes

Everything in this section is **I**: recommendations plus iOS platform behaviour stated from general Apple
platform knowledge, not from the Android repo. Verify each platform claim on a device early.

### 11.1 Wi-Fi join (`NEHotspotConfiguration`)
- One transport: `NEHotspotConfiguration(ssid: qr.ssid, passphrase: qr.pwd, isWEP: false)` (WPA/WPA2 Personal;
  WPA3/transition networks expected to work — verify). Validate first: passphrase 8–63 characters, SSID ≤ 32 bytes;
  else show a clear error instead of Android's generic failure. The entitlement `com.apple.developer.networking.HotspotConfiguration` is already in
  `project.yml`.
- **Use `joinOnce = false`.** With `joinOnce = true` iOS drops the network when the app is backgrounded for long or
  **the device sleeps** — fatal for pocketed riding (Apple documentation; verify on device). Remove the configuration
  (`removeConfiguration(forSSID:)`) on Stop unless the rider chose "keep Wi-Fi" (Android `leave` vs `park`, §3.10).
- `apply()` must be called **in the foreground** (`.applicationIsNotInForeground` otherwise). Ignition-cycle
  re-joins therefore rely on iOS auto-joining the saved configuration; the app only detects it (NWPathMonitor on
  `.wifi` + `NEHotspotNetwork.fetchCurrent` SSID check) and then restarts the prober exactly like
  `BikeLink.onWifiReacquired` (stop + start, fresh IP, rebound listeners).
- Treat `.alreadyAssociated` as success; `.userDenied` → "approve the join prompt" (Android picker ERROR analogue).
  The completion handler can report success without association — always confirm with `fetchCurrent` and wait for
  an IPv4 on `en0` (poll 500 ms up to 10 s, like `BikeWifiP2p.kt:50-51`; ignore 169.254/16).
- **Wi-Fi up does not need a satisfied path.** First field test (iOS 27): on the dash AP, which has no internet,
  `NWPathMonitor(requiredInterfaceType: .wifi)` stays unsatisfied (`notAvailable`, no interface listed) while `en0`
  holds its DHCP address. A usable IPv4 on the Wi-Fi interface (the path's, else the `SIOCGIFFUNCTIONALTYPE` Wi-Fi
  one, else `en0`) counts as up, "local-only", gateway = subnet `.1`: the SSID is read, the join confirmed, the
  session supervised and the Local Network check browses `_EasyConn._tcp` there. Logs:
  `wifi=up(local-only, path=unsatisfied:notAvailable)`. The link itself needs BSD sockets there (§11.2).
- `DIRECT-…` SSIDs: join like any SSID (worked on the 1000 MT-X via Android's specifier, §3.3). P2P-only QRs: still
  try the SSID/PSK join; if it fails, explain that this dash may need Wi-Fi Direct, which iOS lacks.
- Hidden SSIDs are not used by any known dash (Android cannot join them either); expose `hidden = true` only as a
  manual-entry option if ever needed.
- There is no public API to read whether the Wi-Fi radio is on, to scan for SSIDs, or to deep-link to Wi-Fi settings.
  Replace `WifiGate` with: if `apply()`/association fails, tell the rider to enable Wi-Fi and stay near the bike.
- `isSsidInRange` cannot be ported (no scanning). Use "currently associated to the bike SSID?" as the only positive
  signal; otherwise "unknown".

### 11.2 Sockets, interface pinning, permissions
- **Use BSD sockets for the link** (`POSIXNetworkProvider`, OpenCfMotoCore `Link/POSIXTransport.swift`). First field
  test (iOS 27): on the dash AP, which has no internet, `NWPathMonitor(requiredInterfaceType: .wifi)` stays
  unsatisfied (`notAvailable`) although `en0` holds its DHCP address, and every `NWConnection` pinned to Wi-Fi
  (probe, port scan) times out, while Bonjour still resolves the dash. The kernel's connected route works: a BSD socket
  bound with `IP_BOUND_IF` to the interface whose subnet contains the dash reaches it.
- Listeners on 10922/10921/10920: `0.0.0.0:<port>`, `SO_REUSEADDR`, backlog 16 (accepting needs no Local Network
  access). Expect two concurrent connections on 10922.
- Probe/scan connections: IPv4, `IP_BOUND_IF` = the interface whose IPv4/netmask contains the destination (longest
  prefix, `getifaddrs`; never by name), so the source address is the Wi-Fi IPv4 the dash will call back (§4.5).
  Loopback destinations and destinations outside every local subnet connect unbound. TCP connect timeout 3 s, own 5 s
  read timer. Accept rule: `cmd == 0x70000011 && body.contains("true")`. Send exactly the bytes of §5.3.
- Local Network privacy: `NSLocalNetworkUsageDescription` + `NSBonjourServices = [_EasyConn._tcp]` (both already in
  `project.yml`). Denial blocks the probe **and** inbound call-backs; trigger the prompt early (e.g. right after a
  QR scan) and detect `.localNetworkDenied` path reasons. A BSD-sockets connect denied by it fails at once with
  `EHOSTUNREACH` (XNU drops the SYN inside `connect(2)`; no dedicated errno exists): retry until the connect timeout
  (the alert may still be open), then report the denial. Bonjour via `NWBrowser` needs no multicast entitlement.
- Bonjour: `NWBrowser(.bonjourWithTXTRecord(type: "_EasyConn._tcp", domain: nil))`; connect the probe directly to the
  result endpoint (resolution happens in `NWConnection`, IPv4 forced), or use TXT `ip`/`port` as a fallback. Never
  wait on Bonjour alone: race it with `gateway:10930` (`control-plane.md` §18.5). Keep the 10915–10935 scan as the
  last resort (Morini). Skip the 251-port Thinkerride scan in v1.
- Bike address: Bonjour host → routing-table gateway (`sysctl NET_RT_FLAGS`, structs copied from `route.h`) →
  `(ip & mask) | 1` (§4.2, `control-plane.md` §18.4).
- `EADDRINUSE` on a listener ⇒ another process holds the ports (official CFMoto / Carbit iOS app, or our own
  ReplayKit extension). iOS cannot kill other apps: tell the rider to close the official app (swipe it away), retry.
- VPN: a profile with `includeAllNetworks` and without `excludeLocalNetworks` can black-hole bike traffic like the
  Android kill-switch. Detect "Wi-Fi up, probe fails" + active VPN and explain.

### 11.3 Session engine
- Model one session as a structured-concurrency tree with a generation id; cancel everything on stop (fixes the
  Android stale-thread race, §6.9). Keep all timers of §6.10 as named constants.
- States: reuse the Android phases minus the AA ones (`IDLE, JOINING_WIFI, PXC_CONNECTING, STREAMING, RECONNECTING,
  WAITING_FOR_BIKE, STOPPED, ERROR`); add an internal `AWAIT_CALLBACK` sub-state with a **10 s** timeout → re-run
  discovery (Android GAP §5.4).
- Reconnect: port §6.4 exactly, but set `ERROR("lost bike link")` the moment the budget is exhausted, and keep
  retrying discovery every ~20 s while on the bike Wi-Fi even if the first connection never happened (§6.4 GAPs).
- Watchdog: 5 s tick; STREAMING and no frame for > 8 s ⇒ close all bike connections ⇒ reconnect loop; 20 s cooldowns;
  ERROR ⇒ re-arm. Consider deriving the stall threshold from the dash's `socketTimeoutPeriodWifi` (keep ≤ 8 s).
- 2 s PXC heartbeat on **each** :10922 connection from the moment the dash selects the channel.
- Pull handling (`media-video.md` §5.4): never leave a 114 unanswered for long — wait for the next encoded frame (or
  resend the last one) instead of Android's give-up after 1.5 s, which turns encoder hiccups into 9 s drops.
- Reset the visible detail to the bike name on STREAMING (§6.1 quirk).

### 11.4 Background execution and the screen
- iOS suspends backgrounded apps within seconds; the dash then drops (no heartbeats → ~7 s on 800NK, no frames →
  ~9 s on all). `project.yml` declares `UIBackgroundModes = [location, audio]`: keep continuous location updates
  running while projecting (legitimate for a navigation HUD) and set `isIdleTimerDisabled = true` while in the
  foreground (Android equivalent: SCREEN_BRIGHT wake lock for the Map path, `AndroidAutoService.kt:307-335`).
- Risk: VideoToolbox hardware encoding and GPU work are commonly refused in the background (e.g. `kVTInvalidSessionErr`
  after backgrounding). If that happens, projection must be a foreground (screen-on) activity. Verify early on device
  (`media-video.md` owns the encoder).

### 11.5 ReplayKit mirror mode and port ownership
- Only one process may listen on 10920–10922. If the broadcast extension owns the PXC session in mirror mode, the
  app must **stop its listeners first** (Android always does a hard PXC restart on mode switch, §6.7) and restart
  them when the broadcast ends. Wi-Fi join (`NEHotspotConfiguration`) stays in the app.
- Bike touch is not delivered to mirrored content on Android either (dialog text, `MainActivity.kt:384-385`).

### 11.6 Battery policy after the bike disappears (replaces the AA "park")
- Android never parks its own-content Map path. Recommended for iOS: when the bike Wi-Fi has been gone for
  **180 s** (Android `GRACE_MS`), stop rendering/encoding and show "Bike out of range — waiting…"
  (`WAITING_FOR_BIKE`); resume automatically when the Wi-Fi returns (NWPathMonitor) by restarting the prober.

### 11.7 Persistence on iOS
- Store each bike as `{id (UUID), ssid, mac?, raw QR, name, photo?, createdAt}`; dedupe by SSID (+MAC) and update
  `raw` on re-scan (fixes §8.1 quirk). Keep `transport_<ssid>` only if a second transport ever exists.
- The raw QR contains the PSK: keep it (or at least the PSK) in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), not in `UserDefaults`/iCloud backups.
- Keep `dash_geo_<ssid>` = `"<w>x<h>"` (unrounded config-capture size) to pre-size rendering on the next connect.
- Defaults to mirror: auto-connect **on**, auto-recovery **on**, keep-Wi-Fi **off**, include-secrets **off**.

### 11.8 Auto-connect on iOS
- Conditions as §6.8, minus the Android-only checks. Because iOS cannot check range, calling `apply()` on every
  launch can surface "Unable to join the network" alerts when the bike is off. Suggested rule: auto-start the session
  if the phone is **already** on the bike SSID (iOS auto-joined it), otherwise only when the rider taps Connect
  (or offer "try anyway" as an opt-in). Delay 1200 ms after launch like Android.

### 11.9 Logging parity
- Keep the stage tags and the `hb#` 5 s line (§9.3) so Android-trained helpers can read iOS logs. Port the four
  redaction rules verbatim **and** redact QR passwords by parsing (fixes §9.2 leaks); never log `raw` QR text.
- Use `os.Logger` (subsystem `dev.zanderp.opencfmoto` or the iOS bundle id) plus an in-memory ring buffer with the same
  512 KiB / 256 KiB trimming for Share Logs.

### 11.10 Internet while on bike Wi-Fi
- On Android the bike network is local-only and the process pins HTTP to cellular (§3.9). On iOS joining the bike
  makes it the **system** Wi-Fi. Whether iOS keeps routing internet over cellular for a Wi-Fi without internet is
  device/OS behaviour to verify (§13). Mitigation: fetch tiles/routes with Network.framework connections that set
  `requiredInterfaceType = .cellular` (or `prohibitedInterfaceTypes = [.wifi]`) when on the bike SSID, and keep an
  offline tile cache.

### 11.11 Phone-hotspot transport (optional, X)
- Detect the hotspot bridge (`bridge100`, `172.20.10.1/28`) with `getifaddrs`; sweep `.2–.14` on ports 10930, 10920,
  10921, 10922 (250 ms each) and Bonjour in parallel; start the same session with `bindIp = 172.20.10.1` and
  `bike = found host`. Re-sweep on every reconnect (DHCP may move the dash). Guide the rider through device-name/password
  setup and "Maximize Compatibility".

---

## 12. Discrepancies, quirks and gaps (Android) — summary

| # | Item | Detail | Source |
|---:|---|---|---|
| 1 | Grace window | README "~1 minute", code **180 s** | `README.md:346` vs `AndroidAutoService.kt:699` |
| 2 | Budget exhaustion | ERROR only set on a *later* `onAllConnectionsClosed()`; loop exits silently, phase stays RECONNECTING | `EasyConnProber.kt:620-660` |
| 3 | First-connect failure | no automatic retry; watchdog re-arm is a no-op while `everConnected == false` | `EasyConnProber.kt:370-375, 621` |
| 4 | Connect-back | no timeout after an accepted probe | `EasyConnProber.kt:485-537` |
| 5 | Stop→start race | discovery/re-probe threads not cancelled; may run against a new session | `EasyConnProber.kt:296-323, 381-448, 629-659` |
| 6 | Bind errors | every listener bind failure is reported as "official CFMoto app" | `EasyConnProber.kt:202-219` |
| 7 | Keep-Wi-Fi + re-acquire | can restart the prober after Stop | `BikeWifi.kt:318-322`, `BikeLink.kt:117-141` |
| 8 | P2P | no re-join after group loss | `BikeWifiP2p.kt:287-290` |
| 9 | Hotspot poll | any qualifying subnet (e.g. a home-Wi-Fi `wlan0`) ends the wait | `MainActivity.kt:1153-1157`, `PhoneHotspotScan.kt:57-75` |
| 10 | Garage identity | raw QR includes the per-scan `sn` → duplicate entries, new settings namespace | `BikeMemory.kt:65-75`, `01-REVERSE-ENGINEERING.md:33` |
| 11 | Redaction | Morini (`#pwd#`) and Thinkerride (positional) passwords are not masked | `LogRedactor.kt:17-31` |
| 12 | Detail text | STREAMING after a reconnect keeps `"attempt N"` | `ConnectionState.kt:48-51` |
| 13 | NSD first | 12 s wait on dashes without mDNS before trying :10930 | `EasyConnProber.kt:384-401` |
| 14 | WifiNetworkSpecifier vs GO | doc 01 says a GO was joined unchanged; `BikeWifiP2p` says specifiers cannot join a GO | `01-REVERSE-ENGINEERING.md:210-211` vs `BikeWifiP2p.kt:26-29` |
| 15 | PSK validation | invalid passphrase length throws inside `join()` (unhandled on Map/Mirror paths) | `BikeWifi.kt:102-105` |
| 16 | IP resolution failure | `start()` logs "could not resolve …; aborting" and returns **without** setting ERROR or `running`; UI stays on "Linking to dashboard…" | `EasyConnProber.kt:151-161` |
| 17 | Mirror path | no watchdog (no stall recovery, no ERROR re-arm) | §6.5 |

---

## 13. Open questions / risks

1. **iOS QR content.** No raw iOS/"CarPlay" QR is in the repo. Capture several (CFMoto, Zontes, Voge, QJ) and confirm
   they parse as format A with the same SSID/PSK, and whether the dash in "iOS mode" behaves differently after the
   join (e.g. expects `phoneType:"iOS"` or a different package). Android's spoof (`"Android"`,
   `com.cfmoto.cfmotointernational`) is the only verified identity (`control-plane.md` §18.7, §19.1).
2. **Wi-Fi-Direct group owners on iOS.** 1000 MT-X `DIRECT-…` accepted a legacy join on Android; CL-C450 and other
   GOs reportedly don't. iOS has no Wi-Fi Direct API → those dashes may be unreachable unless they offer an iOS/SoftAP
   QR mode. Test CL-C450, US 800NK, 450NK with `NEHotspotConfiguration`.
3. **`NEHotspotConfiguration` behaviour** to verify on device: re-prompting on repeated `apply()`, error when Wi-Fi is
   off or the SSID is out of range (system alert?), auto-join latency after an ignition cycle with `joinOnce = false`,
   whether iOS ever auto-joins the bike network at home and steals Wi-Fi internet.
4. **Internet over cellular while associated** to a no-internet Wi-Fi: verify iOS routing for URLSession/MapKit/tiles;
   design for explicit `.cellular` pinning.
5. **Background survival** (sockets, timers, VideoToolbox, rendering) with location background mode and the screen
   off. If not viable, projection is foreground-only with the idle timer disabled.
6. **Connect-back source address.** Inferred to be the probe's source IP; multi-homed iPhones (Wi-Fi + cellular + VPN)
   must pin the probe to Wi-Fi. A dash calling back a different address would silently fail.
7. **Connect-back timing** is undocumented; the proposed 10 s timeout is a guess.
8. **Dash-side mDNS** is inconsistent (CFDL16 advertises `_EasyConn._tcp` with TXT `huid, huname, channel, flavor,
   port, ip`; 450NK advertises nothing). Bonjour can only be an accelerator.
9. **EasyConn availability** appears tied to the dash showing its pairing/QR screen; how long it stays reachable after
   leaving that screen, and after an ignition cycle, is unknown (README: some firmwares need the QR screen once).
10. **Phone-hotspot mode** is unverified even on Android; whether a dash accepts an iPhone hotspot (SSID = device name,
    5 GHz by default, WPA2/WPA3 transition) is unknown; `bm` semantics ("Bluetooth MAC"?) unknown.
11. **Port conflicts** with the official CFMoto/Carbit iOS apps (suspended apps' listeners) and with our own ReplayKit
    extension.
12. **`action` bits 2, 4, 5** and the reliability of bits 1/3 are unknown; do not gate the iOS flow on them.
13. **Yunmo (X-Cape 1200) and Thinkerride (Kove)** are experimental on Android; out of scope for iOS v1 except
    logging.
14. **TXT `packagename`** might name the companion app a dash expects; Android only logs it. If some brand rejects the
    CFMoto package, spoofing the advertised package is an untested idea.
15. **2.4 GHz coexistence:** video over a 2.4 GHz dash AP shares the radio with Bluetooth handlebar/helmet traffic
    (Android logs a warning); iOS cannot read the band via public API, so this cannot be surfaced directly.

---

## Appendix A — Nominal Map/own-content session, reconstructed log (illustrative, not a capture)

Built from the code's log statements in the order the code emits them (SoftAP CFDL16 example; timestamps omitted):

```
→ Map: <mode> '<track>' → '<bike>' (hard switch)
→ mode switch: stop previous projection (keep Wi‑Fi)
→ bike profile (QR ssid=CFMOTO-f46457 modelId=37416): CFDL16 / legacy (BIKE A) → AA 800x480 @160dpi
[state] Mirroring screen to dash — <bike>
[state] Connecting to bike Wi-Fi… — <bike>
requesting Wi-Fi join: CFMOTO-f46457 …
→ approve the phone's Wi‑Fi / device picker if it appears (do not leave it open past 90s)
[wifi] link: 2437MHz (2.4GHz — SHARED WITH BLUETOOTH), rssi=-41dBm, tx=72Mbps, rx=65Mbps
Wi-Fi joined: CFMOTO-f46457 (network=…, bind deferred until AA video)
[state] Linking to dashboard… — <bike>
→ Wi-Fi bound; starting EasyConn PXC flow …
---- environment ---- … ---------------------
our IP=192.168.0.50  bike IP=192.168.0.1
listening on 192.168.0.50 ports [10922, 10921, 10920] (3 open)
[DISC] discovering _EasyConn._tcp.…
[DISC] found service name=… — resolving
[DISC] NSD → 192.168.0.1:10930
[PROBE] connect #1 -> 192.168.0.1:10930
[PROBE] socket via Network.socketFactory (VPN bypass)
[PROBE] -> MDNS_RESPOND (0x70000010) {"phoneType":"Android","packageName":"com.cfmoto.cfmotointernational"}
[PROBE] <- cmd=0x70000011 {"status":true}
[PROBE] *** accepted — bike should now connect back to our ports ***
[:10922] <<< bike connected from /192.168.0.1:…
[:10922] framing=CmdBaseHead (PXC control)
[:10922] bike selected CAR_CTRL (0x10000) → ack 0x10001
[hb] PXC CAR_CTRL heartbeat started (0x70000000 every 2000ms)
… CLIENT_INFO / QUERY_SPEED / CAR_DATA / CHECK_SN (control-plane.md) …
[:10921] <<< bike connected from /192.168.0.1:…
[:10921] framing=ReqBase (media plane) profile=CFDL16 / legacy (BIKE A)
[:10921] REQ_CONFIG_CAPTURE w=800 h=386 fps=… wantEncoder=2 ext=… len=…
[:10921] → RLY_CONFIG_CAPTURE(17) encoder=2 w=800 h=384
[:10921] REQ_RV_DATA_START(112): starting video 800x384      (socket of 112 inferred, media-video.md §4.1)
[VIDEO] bike attached → flushed queue + requested IDR (first frame will be a keyframe)
[:10921] → RLY 113
[:10920] <<< bike connected from /192.168.0.1:…
[:10920] framing=ReqBase (media plane) profile=CFDL16 / legacy (BIKE A)
[state] Connected — projecting to dash — <bike>               (set just before the frame-#1 log line)
[:10920] sent frame #1 (…b)
hb#1 probed=true video=true framesSent=… openServers=3
```

## Appendix B — Reconnect after a dash-side drop (reconstructed, illustrative)

```
[:10920] media closed            … all four sockets end …
[state] Link dropped — reconnecting… — attempt 1
[reconnect] link lost — re-probing (attempt 1/20) in 1000ms
[PROBE] connect #1 -> 192.168.0.1:10930
[PROBE] *** accepted — bike should now connect back to our ports ***
[:10922] <<< bike connected from /192.168.0.1:…        (reconnectAttempts reset to 0)
… handshake …
[state] Connected — projecting to dash — attempt 1       (detail quirk, §6.1)
[:10920] sent frame #1 (…b)
```
