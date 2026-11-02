# PXC differential test — Swift `EasyConnLink` vs. the original Android `EasyConnProber`

Date: 2026-10-31 · Environment: Linux sandbox (loopback 127.0.0.1, real TCP sockets on the PXC ports),
Swift 6.0.3 (Swift 5 mode), JDK 21 + Kotlin 2.0.21, Python 3.13.

## Why

Nobody on the project could test on a real dash while writing the iOS port. The Android app
([zanderp/open-cfmoto](https://github.com/zanderp/open-cfmoto)) is known to work on real bikes, so the next best thing is
to put **both phone implementations in front of the same independent dash simulator** and compare,
byte for byte, what each of them sends.

## Method

| Piece | What it is |
|---|---|
| `tools/fakedash/fakedash.py` | An independent PXC **dash** written from `docs/spec/*` (stdlib Python). Probe server on :10930, connects back to the phone's :10922 (CAR_CTRL + CAR_DATA), :10921 and :10920, runs the real dash sequences (CFDL16, CFDL26 with the notify burst, 800MT wide/touch), dash heartbeats, clock-frame variants, media config capture, 112/113 and 114 pulls at 20 fps, touch injection (incl. ghost contacts and fuzz), reconnect and stall scenarios. It **validates** every phone frame (rule ids: framing/magic, cmd+1 replies, CLIENT_INFO key order and values, RSA-1024 SPKI pubkey and the PKCS#1 v1.5 type-1 `encryptedHUID` verified with the pubkey, clock echo rules, media replies, one `[size][Annex-B AU]` per 114, IDR first after 112, SPS+PPS before every IDR, no repeated P-frames, SPS size = canvas) and decodes the received H.264 with ffmpeg. 64 self-tests + a smoke phone with injected bugs (each caught by its rule). |
| `tools/linkrunner` | Runs the real Swift `EasyConnLink` (OpenCfMotoCore) with a POSIX-socket `NetworkProvider` and a frame source serving real H.264 Baseline clips (`tools/fakedash/clips`). |
| `tools/android-prober-harness` | Runs the **unmodified** Android `EasyConnProber.kt`, `PxcHandshake.kt`, `PxcFrame.kt`, `BikeProfile.kt`, … (copied verbatim by `copy_upstream.sh`, checked by `upstream/SHA256SUMS`) on a desktop JVM with thin Android stubs and the AOSP `org.json` sources (so CLIENT_INFO bytes match Android exactly), serving the same clips. |
| `tools/fakedash/diff_transcripts.py` | Diffs the phone→dash frames of two runs per connection and in order, masking per-run randomness (RSA key/signature, phone UUID, phone-time clock stamps; video compared by NAL structure). |

Reproduce (Linux or macOS, Python 3.8+, Swift 5.9+, JDK 21, ffmpeg):

```sh
cd tools/linkrunner && swift build && ./run_scenarios.sh            # Swift
cd tools/android-prober-harness && UPSTREAM=/path/to/open-cfmoto ./copy_upstream.sh \
  && gradle installDist && ./run_scenarios.sh                       # Android
python3 tools/fakedash/diff_transcripts.py tools/linkrunner/out/swift-cfdl16.jsonl \
  tools/android-prober-harness/out/kotlin-cfdl16.jsonl --labels=swift,kotlin
```

## Results

Every scenario: **both implementations PASS with 0 violations and 0 warnings**, the received streams
decode at the negotiated size.

| Scenario | Implementation | Result | Violations | Warnings | Sessions | Frames | Canvas | Handshake s | 1st frame after 113 (ms) | Decodable |
|---|---|---|---|---|---|---|---|---|---|---|
| cfdl16 | Swift (EasyConnLink) | PASS | 0 | 0 | 1 | 300 | 800x384 | 0.47 | 72 | yes |
| cfdl16 | Android (EasyConnProber) | PASS | 0 | 0 | 1 | 300 | 800x384 | 0.46 | 73 | yes |
| cfdl26 | Swift (EasyConnLink) | PASS | 0 | 0 | 1 | 300 | 800x944 | 0.44 | 72 | yes |
| cfdl26 | Android (EasyConnProber) | PASS | 0 | 0 | 1 | 300 | 800x944 | 0.42 | 72 | yes |
| mt800 | Swift (EasyConnLink) | PASS | 0 | 0 | 1 | 300 | 1280x576 | 0.43 | 72 | yes |
| mt800 | Android (EasyConnProber) | PASS | 0 | 0 | 1 | 300 | 1280x576 | 0.66 | 77 | yes |
| reconnect | Swift (EasyConnLink) | PASS | 0 | 0 | 2 | 200 | 800x384,800x384 | 0.38,0.21 | 71,71 | yes |
| reconnect | Android (EasyConnProber) | PASS | 0 | 0 | 2 | 200 | 800x384,800x384 | 0.40,0.22 | 73,73 | yes |
| stall | Swift (EasyConnLink) | PASS | 0 | 0 | 2 | 160 | 800x384,800x384 | 0.38,0.21 | 73,73 | yes |
| stall | Android (EasyConnProber) | PASS | 0 | 0 | 2 | 160 | 800x384,800x384 | 0.44,0.21 | 73,72 | yes |
| touch | Swift (EasyConnLink) | PASS | 0 | 0 | 1 | 200 | 1280x576 | 0.47 | 72 | yes |
| touch | Android (EasyConnProber) | PASS | 0 | 0 | 1 | 200 | 1280x576 | 0.42 | 72 | yes |

Stall scenario: both phones' watchdogs dropped every bike socket after the 12 s stall (8 s stall
threshold + 5 s tick), re-probed and completed a second session.

## Differences found (phone → dash bytes)

The control sequence (channel acks, CLIENT_INFO reply key order and values, QUERY_SPEED, CHECK_SN,
every notify-burst ack, clock replies — echo and phone-time variants, heartbeats every 2.0 s on both
:10922 sockets, media replies 17/49/65/97/113, the first frames' NAL structure and the keyframe
structure) is **identical** in all six scenarios, apart from:

| # | Difference | Verdict |
|---|---|---|
| 1 | CLIENT_INFO `phoneBrand`/`phoneModel`: `"Apple"/"iPhone"` (iOS) vs. the Android device's own values (`"samsung"/"SM-G991B"` in the harness). | Intentional (`docs/spec/control-plane.md` §18.7: brand/model vary freely across Android phones; everything else is spoofed exactly like Android). Unverified on a real dash → kept as a field-test lever (a compatibility option to send an Android brand/model is planned). |
| 2 | Pinch release with a ghost/second contact (touch scenario): iOS forwards an UP for **both** pointers, Android forwards one (the other pointer stays down in its input sink). | Intentional iOS fix (`docs/spec/input-controls.md` §4.6, `GhostTouchFilter` fixes F1–F3; `GhostTouchFilter.Configuration.androidCompatible` reproduces Android). |
| 3 | Stall: the order in which the phone closes its sockets after the watchdog fires (CAR_DATA first on iOS, CAR_CTRL first on Android). | Cosmetic. |

**No Swift bugs were found by this test.**

## Limits

- Real dashes were not available: the fake dash encodes the specs' description of real dash
  behaviour; where both phones agree with it, a remaining risk is a spec gap shared by both.
- The Swift run used POSIX sockets. The app now uses the same transport (`POSIXNetworkProvider`,
  OpenCfMotoCore) on iOS; the Simulator end-to-end run exercises it there.
- Video content came from pre-encoded clips; the app's own VideoToolbox encoder output is checked by
  the Simulator end-to-end run and the macOS encoder tests.
