# OpenCfMoto iOS — CI e2e run

- commit: `ce4e59806a49909728e76fdaeac354510a4ce334` (main)
- run: https://github.com/Kevinparra535/opencfmoto-ios/actions/runs/41874690416
- date: 2026-11-04T17:09:43Z
- Xcode: Xcode 16.4 Build version 16F6; macOS 15.8.2
- simulator: iPhone 16, iOS 26.2 (`1CD403CB-B38F-447D-A90D-9985D4D2649C`)
- app: `com.example.opencfmoto` built Debug for the simulator with `CODE_SIGNING_ALLOWED=NO`

| step | seconds | status |
|---|---|---|
| prepare | 78 | ok |
| build | 217 | ok |
| install | 34 | ok |
| screenshots | 645 | ok |
| ffmpeg | 0 | 0 |
| e2e cfdl16 | 79 | done |
| e2e cfdl26 | 56 | done |
| e2e reconnect | 41 | done |
| e2e stall | 39 | done |
| e2e touch | 35 | done |
| e2e music | 61 | done |
| e2e locked | 93 | done |

E2E results: cfdl16 PASS (required), cfdl26 PASS (required), music PASS (required), locked PASS, reconnect PASS, stall PASS, touch PASS

## Build: ok

## Screenshots (21)

[about](screens/about.png) [controls](screens/controls.png) [dash](screens/dash.png) [dash_landscape](screens/dash_landscape.png) [dash_music](screens/dash_music.png) [es_dash](screens/es_dash.png) [es_dash_music](screens/es_dash_music.png) [es_home](screens/es_home.png) [es_settings](screens/es_settings.png) [es_settings_music](screens/es_settings_music.png) [garage](screens/garage.png) [home](screens/home.png) [logs](screens/logs.png) [mirror](screens/mirror.png) [navigate](screens/navigate.png) [onboarding](screens/onboarding.png) [ride](screens/ride.png) [scan](screens/scan.png) [settings](screens/settings.png) [settings_music](screens/settings_music.png) [trips](screens/trips.png)

## E2E `cfdl16` (fake dash `cfdl16`, 45 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.228 s, canvas 800x384 |
| frames | 424 total, 44 keyframes (10% of session 1), avg 43713 B, first frame 0.078 s after 113 |
| pulls | stream 9.42 fps; 114→frame p50 0.55 ms, p95 585.93 ms, max 656.28 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.024 s, max 1.188 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x384, 424 decoded / 424 received, 0 error line(s)  |
| phone identity | phoneUUID=3a5136ab-824b-48a7-8a50-ba2eb7d8402f, pubkey=sha256:10f8a14d7d6b4df0, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 22 beats, max gap 2.056 s; ctrl2: 22 beats, max gap 2.052 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 424 (max 424), keyframes 44, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 426, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 426}; engine {"avg_encode_ms": 6.5, "avg_render_ms": 6.2, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 426, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 426, "output_keyframes": 45, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 424, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 426, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 159 lines (`e2e-cfdl16/app-log.txt`)

Screenshots: [app_after.png](e2e-cfdl16/app_after.png), [app_streaming_1.png](e2e-cfdl16/app_streaming_1.png), [app_streaming_2.png](e2e-cfdl16/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-cfdl16/frames/dash_01.jpg), [dash_02.jpg](e2e-cfdl16/frames/dash_02.jpg), [dash_03.jpg](e2e-cfdl16/frames/dash_03.jpg), [dash_04.jpg](e2e-cfdl16/frames/dash_04.jpg), [dash_05.jpg](e2e-cfdl16/frames/dash_05.jpg), [dash_06.jpg](e2e-cfdl16/frames/dash_06.jpg), [dash_07.jpg](e2e-cfdl16/frames/dash_07.jpg), [dash_08.jpg](e2e-cfdl16/frames/dash_08.jpg), [dash_09.jpg](e2e-cfdl16/frames/dash_09.jpg), [dash_10.jpg](e2e-cfdl16/frames/dash_10.jpg), [dash_11.jpg](e2e-cfdl16/frames/dash_11.jpg), [dash_first.png](e2e-cfdl16/frames/dash_first.png), [dash_last.png](e2e-cfdl16/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
17:26:35.498 I/LINK: [:10922] bike closed
17:26:35.498 I/LINK: [:10921] media closed
17:26:35.498 I/LINK: [:10920] media closed
17:26:35.499 I/VIDEO: media sockets closed → queue flushed
17:26:35.499 I/LINK: [state] reconnecting (1)
17:26:35.499 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
17:26:35.500 I/STATE: [state] Link dropped — reconnecting… — attempt 1
17:26:36.511 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:26:36.512 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:26:36.517 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:26:37.270 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
17:26:37.271 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:26:37.271 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:26:39.541 D/NAV: [speed] maxspeed lookup failed: Map service temporarily unavailable (HTTP 502)
17:26:39.937 I/LINK: hb#10 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=0.0
17:26:41.272 I/LINK: [state] reconnecting (2)
17:26:41.273 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
17:26:41.273 I/STATE: [state] Link dropped — reconnecting… — attempt 2
17:26:42.790 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:26:42.791 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:26:42.791 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:26:43.555 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
17:26:43.556 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:26:43.556 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:26:44.939 I/LINK: hb#11 probed=false video=false framesSent=0 openServers=3 state=reconnecting (2) pulls/s=0.0
```
</details>

## E2E `cfdl26` (fake dash `cfdl26`, 30 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.283 s, canvas 800x944 |
| frames | 287 total, 30 keyframes (10% of session 1), avg 45988 B, first frame 0.137 s after 113 |
| pulls | stream 9.47 fps; 114→frame p50 0.95 ms, p95 583.29 ms, max 662.14 ms |
| SPS | profile_idc 66, level_idc 31, 800x944, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.019 s, max 1.066 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x944, 287 decoded / 287 received, 0 error line(s)  |
| phone identity | phoneUUID=e3b51e4a-d3d1-4ea4-82e2-138bdf29f25b, pubkey=sha256:3cd94712d5bcbb7f, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=128, supportScreenTouch=False |
| heartbeats | ctrl1: 15 beats, max gap 2.031 s; ctrl2: 15 beats, max gap 2.041 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 287 (max 287), keyframes 30, missed pulls 0, profile CFDL26 / MotoPlay Portrait (1000 MT-X), canvas 800x944, dash CFMOTO-805120 sdk=1.1.4; projection {"bitrate": 3375000, "encoded_frames": 288, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 288}; engine {"avg_encode_ms": 7.9, "avg_render_ms": 14.6, "background_s": 0, "budget_fps": null, "canvas": "800x944", "demotions": 0, "encode_submissions": 288, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 288, "output_keyframes": 30, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 287, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 288, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 159 lines (`e2e-cfdl26/app-log.txt`)

Screenshots: [app_after.png](e2e-cfdl26/app_after.png), [app_streaming_1.png](e2e-cfdl26/app_streaming_1.png), [app_streaming_2.png](e2e-cfdl26/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-cfdl26/frames/dash_01.jpg), [dash_02.jpg](e2e-cfdl26/frames/dash_02.jpg), [dash_03.jpg](e2e-cfdl26/frames/dash_03.jpg), [dash_04.jpg](e2e-cfdl26/frames/dash_04.jpg), [dash_05.jpg](e2e-cfdl26/frames/dash_05.jpg), [dash_06.jpg](e2e-cfdl26/frames/dash_06.jpg), [dash_07.jpg](e2e-cfdl26/frames/dash_07.jpg), [dash_08.jpg](e2e-cfdl26/frames/dash_08.jpg), [dash_09.jpg](e2e-cfdl26/frames/dash_09.jpg), [dash_10.jpg](e2e-cfdl26/frames/dash_10.jpg), [dash_11.jpg](e2e-cfdl26/frames/dash_11.jpg), [dash_first.png](e2e-cfdl26/frames/dash_first.png), [dash_last.png](e2e-cfdl26/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
17:27:38.565 I/LINK: [hb] → PXC CAR_CTRL heartbeat #15
17:27:38.737 I/LINK: [:10922] CFDL26 ctrl 0x10750 (?) len=0  → ack 0x10751 (empty)
17:27:38.762 I/LINK: [hb] → PXC CAR_DATA heartbeat #15
17:27:39.176 I/LINK: [:10921] media closed
17:27:39.176 I/LINK: [:10922] bike closed
17:27:39.176 I/LINK: [:10922] bike closed
17:27:39.176 I/LINK: [:10920] media closed
17:27:39.176 I/VIDEO: media sockets closed → queue flushed
17:27:39.176 I/LINK: [state] reconnecting (1)
17:27:39.176 I/STATE: [state] Link dropped — reconnecting… — attempt 1
17:27:39.176 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
17:27:40.182 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:27:40.183 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:27:40.192 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:27:40.955 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
17:27:40.955 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:27:40.956 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:27:43.204 I/LINK: hb#7 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=2.0
17:27:44.399 D/NAV: [speed] maxspeed lookup failed: Map service temporarily unavailable (HTTP 502)
17:27:44.997 I/LINK: [state] reconnecting (2)
17:27:44.997 I/STATE: [state] Link dropped — reconnecting… — attempt 2
17:27:44.997 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
17:27:46.510 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:27:46.510 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:27:46.511 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
```
</details>

## E2E `music` (fake dash `cfdl16`, 36 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.239 s, canvas 800x384 |
| frames | 204 total, 33 keyframes (16% of session 1), avg 39549 B, first frame 0.077 s after 113 |
| pulls | stream 5.67 fps; 114→frame p50 0.94 ms, p95 646.83 ms, max 921.48 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.121 s, max 1.924 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x384, 204 decoded / 204 received, 0 error line(s)  |
| phone identity | phoneUUID=e967e6ac-b250-4f08-af3b-666bba855888, pubkey=sha256:a72206a7710db6cb, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 18 beats, max gap 2.056 s; ctrl2: 17 beats, max gap 2.06 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 204 (max 204), keyframes 33, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 206, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 201}; engine {"avg_encode_ms": 3.9, "avg_render_ms": 4.1, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 206, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 206, "output_keyframes": 33, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 204, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 201, "repeated_frames": 5, "using_hardware_encoder": null}

App alive after the run: yes; app log: 166 lines (`e2e-music/app-log.txt`)

Screenshots: [app_after.png](e2e-music/app_after.png), [app_streaming_1.png](e2e-music/app_streaming_1.png), [app_streaming_2.png](e2e-music/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-music/frames/dash_01.jpg), [dash_02.jpg](e2e-music/frames/dash_02.jpg), [dash_03.jpg](e2e-music/frames/dash_03.jpg), [dash_04.jpg](e2e-music/frames/dash_04.jpg), [dash_05.jpg](e2e-music/frames/dash_05.jpg), [dash_06.jpg](e2e-music/frames/dash_06.jpg), [dash_07.jpg](e2e-music/frames/dash_07.jpg), [dash_08.jpg](e2e-music/frames/dash_08.jpg), [dash_09.jpg](e2e-music/frames/dash_09.jpg), [dash_10.jpg](e2e-music/frames/dash_10.jpg), [dash_11.jpg](e2e-music/frames/dash_11.jpg), [dash_first.png](e2e-music/frames/dash_first.png), [dash_last.png](e2e-music/frames/dash_last.png), [music_1_map_playing.png](e2e-music/frames/music_1_map_playing.png), [music_2_sheet.png](e2e-music/frames/music_2_sheet.png), [music_3_sheet_next.png](e2e-music/frames/music_3_sheet_next.png), [music_4_sheet_paused.png](e2e-music/frames/music_4_sheet_paused.png), [music_5_map_paused.png](e2e-music/frames/music_5_map_paused.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
17:30:26.586 I/LINK: [hb] → PXC CAR_CTRL heartbeat #15
17:30:26.791 I/LINK: [hb] → PXC CAR_DATA heartbeat #15
17:30:30.003 I/LINK: [:10920] sent frame #180 (2523b)
17:30:30.730 I/LINK: [CLOCK-LAB] HU_TIME_SYNC → echo
17:30:30.731 I/LINK: [:10922] HU_TIME_SYNC #18 len=45 → ack 0x10601 mode=echo time=2026-11-04 17:30:30.730000000
17:30:31.300 I/LINK: hb#7 probed=true video=true framesSent=190 openServers=3 state=streaming pulls/s=9.8
17:30:32.784 I/LINK: [:10921] media closed
17:30:32.784 I/LINK: [:10922] bike closed
17:30:32.784 I/LINK: [:10922] bike closed
17:30:32.785 I/LINK: [:10920] media closed
17:30:32.785 I/VIDEO: media sockets closed → queue flushed
17:30:32.785 I/LINK: [state] reconnecting (1)
17:30:32.785 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
17:30:32.785 I/STATE: [state] Link dropped — reconnecting… — attempt 1
17:30:33.723 D/NAV: [speed] maxspeed lookup failed: Map service is busy (rate limited) — try again shortly
17:30:33.788 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:30:33.788 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:30:33.805 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:30:34.557 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
17:30:34.557 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:30:34.557 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:30:36.304 I/LINK: hb#8 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=2.6
17:30:38.581 I/LINK: [state] reconnecting (2)
17:30:38.581 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
17:30:38.581 I/STATE: [state] Link dropped — reconnecting… — attempt 2
```
</details>

## E2E `locked` (fake dash `cfdl16`, 60 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.617 s, canvas 800x384 |
| frames | 408 total, 57 keyframes (13% of session 1), avg 48009 B, first frame 0.083 s after 113 |
| pulls | stream 6.79 fps; 114→frame p50 1.74 ms, p95 623.64 ms, max 761.89 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.066 s, max 1.734 s |
| decode (ffprobe/ffmpeg, strict: `-xerror -err_detect +crccheck+bitstream+buffer+explode`) | decodable: **True**, h264 Constrained Baseline 800x384, 408 decoded / 408 received, 0 error line(s) ; lenient decode clean: True |
| phone identity | phoneUUID=43adad19-96c1-48b4-ae9d-d6e8dc7ea4e7, pubkey=sha256:06e60c641accc00e, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 30 beats, max gap 2.122 s; ctrl2: 29 beats, max gap 2.114 s |

Findings:

| severity | rule | count | message |
|---|---|---|---|
| info | LOCKED_ONE_VARIANT | 1 | one SPS/PPS variant over the run: both encoders wrote the same SPS/PPS, or no switch happened (the app's `[switch] first … IDR on the wire … (dump frame #k)` lines tell) |

SPS/PPS variants on the wire (one per encoder that fed the dash):

| # | first frame | frames | profile | constraints | level | size | poc | refs | frame_num bits | vui | reorder | picture |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 408 | 66 | 0xE0 | 31 | 800x384 | 0 | 2 | 5 | True | - | [dash_variant_1.png](e2e-locked/frames/dash_variant_1.png) |

SPS #1 `2742e01fa91819063602d4080808c2b5ef7c04` PPS `28de09c8`

Encoder switches checked on the wire (L8 frame = SPS+PPS+IDR of the logged size): vt-hw at #1, vt-sw at #151, vt-hw at #267

One SPS/PPS variant: both encoders wrote the same SPS/PPS (switches verified at #151 and #267).

<details><summary>Lock lines of the app log (25)</summary>

```
17:31:10.631 I/VIDEO: [hold] first IDR 6038b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
17:31:11.536 I/VIDEO: [own] first IDR 52085b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
17:31:11.586 I/VIDEO: [vt-list] avc1 encoders: anon-1 name=Dynamically Registered avc1 Video Encoder hw=false
17:31:11.762 I/VIDEO: [switch] first vt-hw IDR on the wire: 63825b (dump frame #1)
17:31:26.876 I/E2E: simulated lock at +15.0s
17:31:26.876 I/APP: scene active → inactive (own UI session, streaming)
17:31:26.895 I/VIDEO: [hold] first IDR 20212b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
17:31:26.926 I/VIDEO: [own-sw-pre] first IDR 56700b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
17:31:26.926 I/VIDEO: [bg] pre-warm vt-sw at inactive: create=noErr hw=? probe=IDR 56700b in 10ms
17:31:27.356 I/APP: scene inactive → background (own UI session, streaming)
17:31:27.369 I/VIDEO: [bg] enter: canvas 800x384 policy=vtsw rungs=vt-sw,hold last-live-idr=116462b hold-idrs=2
17:31:27.375 I/VIDEO: [bg] try vt-sw (pre-warmed): create=noErr hw=? probe=IDR 61908b in 4ms sps=ok → accepted
17:31:27.375 I/VIDEO: [switch] vt-hw → vt-sw: gate closed; next frame on the wire is an IDR (dump frame #151)
17:31:27.376 I/VIDEO: background → backgroundSoftware @8fps (encoder vt-sw, 3375kbps)
17:31:27.376 I/VIDEO: [switch] first vt-sw IDR on the wire: 61908b, 0.00s after the switch (dump frame #151)
17:31:37.386 I/VIDEO: [bg] +10s mode=backgroundSoftware enc=vt-sw cap=8fps out=4.0fps pulls=4.0/s served=41 (hold 0, fallback 0, none 0) errs=0 render=6.3ms enc=5.8ms cpu=9% thermal=none lowPower=false q=0
17:31:39.253 I/APP: [lock] 12s locked link=streaming wifi=up pulls=4.0/s dash=backgroundSoftware vt-sw 4.0fps gps=1s heading=1s batt=?% unknown thermal=none lowPower=false
17:31:47.378 I/VIDEO: [bg] +20s mode=backgroundSoftware enc=vt-sw cap=8fps out=3.5fps pulls=3.5/s served=80 (hold 0, fallback 0, none 0) errs=0 render=4.7ms enc=5.4ms cpu=7% thermal=none lowPower=false q=0
17:31:56.879 I/E2E: simulated unlock at +45.0s
17:31:56.880 I/APP: scene background → inactive after 30s (own UI session, streaming)
17:31:56.882 I/APP: scene inactive → active (own UI session, streaming)
17:31:56.933 I/VIDEO: [switch] vt-sw → vt-hw: gate closed; next frame on the wire is an IDR (dump frame #267)
17:31:56.947 I/VIDEO: foreground → hardware encoder, IDR forced (background 30s: vt-sw 116 frames 27 IDR 0 errors enc 6.0ms; hold served 0)
17:31:56.968 I/VIDEO: [own] first IDR 61380b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
17:31:56.969 I/VIDEO: [switch] first vt-hw IDR on the wire: 61380b, 0.09s after the switch (dump frame #267)
```
</details>

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 408 (max 408), keyframes 57, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 411, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 410}; engine {"avg_encode_ms": 4.7, "avg_render_ms": 5.1, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 410, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 411, "output_keyframes": 58, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 408, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 410, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 186 lines (`e2e-locked/app-log.txt`)

Screenshots: [app_after.png](e2e-locked/app_after.png), [app_streaming_1.png](e2e-locked/app_streaming_1.png), [app_streaming_2.png](e2e-locked/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-locked/frames/dash_01.jpg), [dash_02.jpg](e2e-locked/frames/dash_02.jpg), [dash_03.jpg](e2e-locked/frames/dash_03.jpg), [dash_04.jpg](e2e-locked/frames/dash_04.jpg), [dash_05.jpg](e2e-locked/frames/dash_05.jpg), [dash_06.jpg](e2e-locked/frames/dash_06.jpg), [dash_07.jpg](e2e-locked/frames/dash_07.jpg), [dash_08.jpg](e2e-locked/frames/dash_08.jpg), [dash_09.jpg](e2e-locked/frames/dash_09.jpg), [dash_10.jpg](e2e-locked/frames/dash_10.jpg), [dash_11.jpg](e2e-locked/frames/dash_11.jpg), [dash_first.png](e2e-locked/frames/dash_first.png), [dash_last.png](e2e-locked/frames/dash_last.png), [dash_variant_1.png](e2e-locked/frames/dash_variant_1.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
17:32:11.601 I/LINK: [hb] → PXC CAR_CTRL heartbeat #30
17:32:11.817 I/LINK: [:10922] bike closed
17:32:11.817 I/LINK: [:10922] bike closed
17:32:11.817 I/LINK: [:10921] media closed
17:32:11.818 I/LINK: [:10920] media closed
17:32:11.818 I/VIDEO: media sockets closed → queue flushed
17:32:11.818 I/LINK: [state] reconnecting (1)
17:32:11.818 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
17:32:11.819 I/STATE: [state] Link dropped — reconnecting… — attempt 1
17:32:12.858 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:32:12.859 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:32:12.868 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:32:13.623 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
17:32:13.623 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:32:13.624 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:32:15.935 I/LINK: hb#13 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=1.4
17:32:17.641 I/LINK: [state] reconnecting (2)
17:32:17.641 I/STATE: [state] Link dropped — reconnecting… — attempt 2
17:32:17.641 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
17:32:19.143 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:32:19.144 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:32:19.144 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:32:19.930 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
17:32:19.931 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:32:19.932 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
```
</details>

## E2E `reconnect` (fake dash `cfdl16`, 10 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 2 / 2 |
| session 1 | end: completed, handshake 0.23 s, canvas 800x384 |
| frames | 191 total, 10 keyframes (10% of session 1), avg 42458 B, first frame 0.074 s after 113 |
| session 2 | end: completed, handshake 0.235 s, canvas 800x384, 96 frames (10 keyframes), probe at 16.916 s |
| re-probe | 1.002 s after the previous session ended (accepted) |
| pulls | stream 9.32 fps; 114→frame p50 0.39 ms, p95 578.07 ms, max 826.01 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.029 s, max 1.077 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x384, 191 decoded / 191 received, 0 error line(s)  |
| phone identity | phoneUUID=3c5fb21a-e6e9-4a4b-ae90-bbc0d67fa73a, pubkey=sha256:3d3c5d53917bdde9, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 5 beats, max gap 2.041 s; ctrl2: 5 beats, max gap 2.043 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 191 (max 191), keyframes 20, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 195, "fps": 4.5, "last_error": null, "mode": "foreground", "rendered_frames": 195}; engine {"avg_encode_ms": 4.1, "avg_render_ms": 4.6, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 195, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 195, "output_keyframes": 22, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 191, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 195, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 204 lines (`e2e-reconnect/app-log.txt`)

Screenshots: [app_after.png](e2e-reconnect/app_after.png), [app_streaming_1.png](e2e-reconnect/app_streaming_1.png), [app_streaming_2.png](e2e-reconnect/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-reconnect/frames/dash_01.jpg), [dash_02.jpg](e2e-reconnect/frames/dash_02.jpg), [dash_03.jpg](e2e-reconnect/frames/dash_03.jpg), [dash_04.jpg](e2e-reconnect/frames/dash_04.jpg), [dash_05.jpg](e2e-reconnect/frames/dash_05.jpg), [dash_06.jpg](e2e-reconnect/frames/dash_06.jpg), [dash_07.jpg](e2e-reconnect/frames/dash_07.jpg), [dash_08.jpg](e2e-reconnect/frames/dash_08.jpg), [dash_09.jpg](e2e-reconnect/frames/dash_09.jpg), [dash_10.jpg](e2e-reconnect/frames/dash_10.jpg), [dash_11.jpg](e2e-reconnect/frames/dash_11.jpg), [dash_first.png](e2e-reconnect/frames/dash_first.png), [dash_last.png](e2e-reconnect/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
17:28:17.698 I/LINK: [hb] → PXC CAR_CTRL heartbeat #2
17:28:17.912 I/LINK: [hb] → PXC CAR_DATA heartbeat #2
17:28:19.698 I/LINK: [hb] → PXC CAR_CTRL heartbeat #3
17:28:19.935 I/LINK: [hb] → PXC CAR_DATA heartbeat #3
17:28:20.103 I/LINK: [:10920] sent frame #60 (1289b)
17:28:21.727 I/LINK: hb#4 probed=true video=true framesSent=69 openServers=3 state=streaming pulls/s=8.8
17:28:24.082 I/LINK: [:10922] bike closed
17:28:24.082 I/LINK: [:10922] bike closed
17:28:24.082 I/LINK: [:10921] media closed
17:28:24.083 I/LINK: [:10920] media closed
17:28:24.083 I/VIDEO: media sockets closed → queue flushed
17:28:24.083 I/LINK: [state] reconnecting (1)
17:28:24.083 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
17:28:24.083 I/STATE: [state] Link dropped — reconnecting… — attempt 1
17:28:25.103 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:28:25.104 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:28:25.107 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:28:25.893 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
17:28:25.894 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:28:25.894 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:28:26.755 I/LINK: hb#5 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=5.0
17:28:26.873 D/NAV: [speed] maxspeed lookup failed: Map service temporarily unavailable (HTTP 502)
17:28:29.935 I/LINK: [state] reconnecting (2)
17:28:29.935 I/STATE: [state] Link dropped — reconnecting… — attempt 2
17:28:29.935 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
```
</details>

## E2E `stall` (fake dash `cfdl16`, 6 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 2 / 2 |
| session 1 | end: phone closed ctrl2 (EOF), handshake 0.233 s, canvas 800x384 |
| frames | 115 total, 7 keyframes (12% of session 1), avg 44828 B, first frame 0.072 s after 113 |
| session 2 | end: completed, handshake 0.237 s, canvas 800x384, 59 frames (7 keyframes), probe at 20.705 s |
| re-probe | 0.93 s after the previous session ended (accepted) |
| pulls | stream 8.87 fps; 114→frame p50 0.38 ms, p95 592.23 ms, max 713.96 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.052 s, max 1.23 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x384, 115 decoded / 115 received, 0 error line(s)  |
| phone identity | phoneUUID=21173733-e4aa-464f-9eff-c37550929b35, pubkey=sha256:0a13daa49e9348ff, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 7 beats, max gap 2.04 s; ctrl2: 7 beats, max gap 2.038 s |

Findings:

| severity | rule | count | message |
|---|---|---|---|
| info | WATCHDOG | 1 | the phone dropped every socket 8.21 s after the last frame (watchdog > 8 s, 5 s tick) |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 115 (max 115), keyframes 14, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 118, "fps": 1, "last_error": null, "mode": "foreground", "rendered_frames": 118}; engine {"avg_encode_ms": 4.2, "avg_render_ms": 5.7, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 118, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 118, "output_keyframes": 15, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 115, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 118, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 204 lines (`e2e-stall/app-log.txt`)

Screenshots: [app_after.png](e2e-stall/app_after.png), [app_streaming_1.png](e2e-stall/app_streaming_1.png), [app_streaming_2.png](e2e-stall/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-stall/frames/dash_01.jpg), [dash_02.jpg](e2e-stall/frames/dash_02.jpg), [dash_03.jpg](e2e-stall/frames/dash_03.jpg), [dash_04.jpg](e2e-stall/frames/dash_04.jpg), [dash_05.jpg](e2e-stall/frames/dash_05.jpg), [dash_06.jpg](e2e-stall/frames/dash_06.jpg), [dash_07.jpg](e2e-stall/frames/dash_07.jpg), [dash_08.jpg](e2e-stall/frames/dash_08.jpg), [dash_09.jpg](e2e-stall/frames/dash_09.jpg), [dash_10.jpg](e2e-stall/frames/dash_10.jpg), [dash_11.jpg](e2e-stall/frames/dash_11.jpg), [dash_first.png](e2e-stall/frames/dash_first.png), [dash_last.png](e2e-stall/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
17:29:00.956 I/LINK: [hb] → PXC CAR_CTRL heartbeat #1
17:29:01.130 I/LINK: [hb] → PXC CAR_DATA heartbeat #1
17:29:02.763 I/LINK: hb#4 probed=true video=true framesSent=30 openServers=3 state=streaming pulls/s=6.2
17:29:02.961 I/LINK: [hb] → PXC CAR_CTRL heartbeat #2
17:29:03.131 I/LINK: [hb] → PXC CAR_DATA heartbeat #2
17:29:04.971 I/LINK: [hb] → PXC CAR_CTRL heartbeat #3
17:29:05.137 I/LINK: [hb] → PXC CAR_DATA heartbeat #3
17:29:05.863 I/LINK: [:10922] bike closed
17:29:05.863 I/LINK: [:10922] bike closed
17:29:05.864 I/LINK: [:10921] media closed
17:29:05.864 I/LINK: [:10920] media closed
17:29:05.864 I/VIDEO: media sockets closed → queue flushed
17:29:05.864 I/LINK: [state] reconnecting (1)
17:29:05.864 I/STATE: [state] Link dropped — reconnecting… — attempt 1
17:29:05.864 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
17:29:06.888 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:29:06.890 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:29:06.902 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:29:07.656 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
17:29:07.657 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:29:07.657 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:29:07.804 I/LINK: hb#5 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=5.6
17:29:11.680 I/LINK: [state] reconnecting (2)
17:29:11.681 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
17:29:11.681 I/STATE: [state] Link dropped — reconnecting… — attempt 2
```
</details>

## E2E `touch` (fake dash `mt800`, 15 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.279 s, canvas 1280x576 |
| frames | 149 total, 15 keyframes (10% of session 1), avg 28567 B, first frame 0.076 s after 113 |
| pulls | stream 9.81 fps; 114→frame p50 3.94 ms, p95 581.76 ms, max 642.14 ms |
| SPS | profile_idc 66, level_idc 31, 1280x576, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.023 s, max 1.046 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 1280x576, 149 decoded / 149 received, 0 error line(s)  |
| phone identity | phoneUUID=7ff325e4-3767-4c52-9bd6-99ec9671c826, pubkey=sha256:1a08a134badf3fcc, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=128, supportScreenTouch=True |
| heartbeats | ctrl1: 7 beats, max gap 2.038 s; ctrl2: 7 beats, max gap 2.038 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 149 (max 149), keyframes 15, missed pulls 0, profile CFDL26 / MotoPlay Landscape (800MT), canvas 1280x576, dash CFMOTO1565 sdk=1.1.2; projection {"bitrate": 3375000, "encoded_frames": 150, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 150}; engine {"avg_encode_ms": 7.3, "avg_render_ms": 12.1, "background_s": 0, "budget_fps": null, "canvas": "1280x576", "demotions": 0, "encode_submissions": 150, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 150, "output_keyframes": 15, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 149, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 150, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 163 lines (`e2e-touch/app-log.txt`)

Screenshots: [app_after.png](e2e-touch/app_after.png), [app_streaming_1.png](e2e-touch/app_streaming_1.png), [app_streaming_2.png](e2e-touch/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-touch/frames/dash_01.jpg), [dash_02.jpg](e2e-touch/frames/dash_02.jpg), [dash_03.jpg](e2e-touch/frames/dash_03.jpg), [dash_04.jpg](e2e-touch/frames/dash_04.jpg), [dash_05.jpg](e2e-touch/frames/dash_05.jpg), [dash_06.jpg](e2e-touch/frames/dash_06.jpg), [dash_07.jpg](e2e-touch/frames/dash_07.jpg), [dash_08.jpg](e2e-touch/frames/dash_08.jpg), [dash_09.jpg](e2e-touch/frames/dash_09.jpg), [dash_10.jpg](e2e-touch/frames/dash_10.jpg), [dash_11.jpg](e2e-touch/frames/dash_11.jpg), [dash_first.png](e2e-touch/frames/dash_first.png), [dash_last.png](e2e-touch/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
17:29:27.685 I/LINK: [hb] → PXC CAR_DATA heartbeat #3
17:29:27.713 I/LINK: [:10922] CFDL26 ctrl 0x10750 (?) len=0  → ack 0x10751 (empty)
17:29:31.077 I/LINK: hb#2 probed=true video=true framesSent=95 openServers=3 state=streaming pulls/s=9.2
17:29:33.035 D/NAV: [speed] maxspeed lookup failed: Map service temporarily unavailable (HTTP 502)
17:29:33.314 I/LINK: [:10920] sent frame #120 (1710b)
17:29:33.716 I/LINK: [:10922] CFDL26 ctrl 0x10750 (?) len=0  → ack 0x10751 (empty)
17:29:36.085 I/LINK: hb#3 probed=true video=true framesSent=142 openServers=3 state=streaming pulls/s=9.2
17:29:37.036 I/LINK: [:10922] bike closed
17:29:37.037 I/LINK: [:10922] bike closed
17:29:37.039 I/LINK: [:10921] media closed
17:29:37.039 I/LINK: [:10920] media closed
17:29:37.039 I/VIDEO: media sockets closed → queue flushed
17:29:37.039 I/LINK: [state] reconnecting (1)
17:29:37.040 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
17:29:37.040 I/STATE: [state] Link dropped — reconnecting… — attempt 1
17:29:38.041 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
17:29:38.042 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:29:38.047 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:29:38.800 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
17:29:38.800 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
17:29:38.800 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
17:29:41.100 I/LINK: hb#4 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=1.4
17:29:42.811 I/LINK: [state] reconnecting (2)
17:29:42.811 I/STATE: [state] Link dropped — reconnecting… — attempt 2
17:29:42.811 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
```
</details>

PNGs quantized with pngquant: 27.3 MB → 12.8 MB.


Total artifact size: 12.8 MB
