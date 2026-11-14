# OpenCfMoto iOS — CI e2e run

- commit: `7e8812214b5400c12dab0c2339dd324098bffc61` (wip/fuel)
- run: https://github.com/Kevinparra535/opencfmoto-ios/actions/runs/43571000677
- date: 2026-11-14T07:25:50Z
- Xcode: Xcode 16.4 Build version 16F6; macOS 15.8.2
- simulator: iPhone 16, iOS 26.2 (`309F4F0C-F632-4F5C-BB25-BD783E57455C`)
- app: `com.example.opencfmoto` built Debug for the simulator with `CODE_SIGNING_ALLOWED=NO`

| step | seconds | status |
|---|---|---|
| prepare | 46 | ok |
| build | 389 | ok |
| install | 26 | ok |
| screenshots | 678 | ok |
| ffmpeg | 1 | 0 |
| e2e cfdl16 | 77 | done |
| e2e cfdl26 | 56 | done |
| e2e reconnect | 53 | done |
| e2e stall | 48 | done |
| e2e touch | 42 | done |
| e2e music | 65 | done |
| e2e locked | 92 | done |

E2E results: cfdl16 PASS (required), cfdl26 PASS (required), music PASS (required), locked PASS, reconnect PASS, stall PASS, touch PASS

## Build: ok

## Screenshots (54)

[about](screens/about.png) [controls](screens/controls.png) [dash](screens/dash.png) [dash_landscape](screens/dash_landscape.png) [dash_music](screens/dash_music.png) [es_co_fuel_picker](screens/es_co_fuel_picker.png) [es_co_refuel](screens/es_co_refuel.png) [es_dash](screens/es_dash.png) [es_dash_music](screens/es_dash_music.png) [es_fuel](screens/es_fuel.png) [es_fuel_edit](screens/es_fuel_edit.png) [es_fuel_level](screens/es_fuel_level.png) [es_fuel_picker](screens/es_fuel_picker.png) [es_fuel_picker_ax](screens/es_fuel_picker_ax.png) [es_fuel_setup](screens/es_fuel_setup.png) [es_gpx_preview](screens/es_gpx_preview.png) [es_home](screens/es_home.png) [es_home_fuel_aged](screens/es_home_fuel_aged.png) [es_home_fuel_check](screens/es_home_fuel_check.png) [es_home_fuel_gap](screens/es_home_fuel_gap.png) [es_home_fuel_low](screens/es_home_fuel_low.png) [es_home_fuel_low_ax](screens/es_home_fuel_low_ax.png) [es_home_fuel_moving](screens/es_home_fuel_moving.png) [es_home_fuel_nogps](screens/es_home_fuel_nogps.png) [es_home_fuel_norefuel](screens/es_home_fuel_norefuel.png) [es_home_fuel_partial](screens/es_home_fuel_partial.png) [es_home_fuel_reserve](screens/es_home_fuel_reserve.png) [es_pocket_offer](screens/es_pocket_offer.png) [es_refuel](screens/es_refuel.png) [es_route_verdict](screens/es_route_verdict.png) [es_route_verdict_reserve](screens/es_route_verdict_reserve.png) [es_settings](screens/es_settings.png) [es_settings_music](screens/es_settings_music.png) [fuel](screens/fuel.png) [fuel_edit](screens/fuel_edit.png) [fuel_picker](screens/fuel_picker.png) [garage](screens/garage.png) [gpx_preview](screens/gpx_preview.png) [home](screens/home.png) [home_fuel_moving](screens/home_fuel_moving.png) [home_fuel_reserve](screens/home_fuel_reserve.png) [home_fuel_setup](screens/home_fuel_setup.png) [logs](screens/logs.png) [mirror](screens/mirror.png) [navigate](screens/navigate.png) [onboarding](screens/onboarding.png) [pocket_offer](screens/pocket_offer.png) [refuel](screens/refuel.png) [ride](screens/ride.png) [route_verdict](screens/route_verdict.png) [scan](screens/scan.png) [settings](screens/settings.png) [settings_music](screens/settings_music.png) [trips](screens/trips.png)

## E2E `cfdl16` (fake dash `cfdl16`, 45 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.245 s, canvas 800x384 |
| frames | 434 total, 44 keyframes (10% of session 1), avg 22093 B, first frame 0.076 s after 113 |
| pulls | stream 9.64 fps; 114→frame p50 0.35 ms, p95 575.76 ms, max 685.72 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.02 s, max 1.147 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x384, 434 decoded / 434 received, 0 error line(s)  |
| phone identity | phoneUUID=de4ed86d-638b-480a-8028-2509e2e239f9, pubkey=sha256:1bb99dcd11ee807f, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 22 beats, max gap 2.076 s; ctrl2: 22 beats, max gap 2.078 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 3), link reconnecting (3), ever streaming: True, frames sent 434 (max 434), keyframes 44, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 436, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 436}; engine {"avg_encode_ms": 5.2, "avg_render_ms": 5.8, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 436, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 436, "output_keyframes": 45, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 434, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 436, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 163 lines (`e2e-cfdl16/app-log.txt`)

Screenshots: [app_after.png](e2e-cfdl16/app_after.png), [app_streaming_1.png](e2e-cfdl16/app_streaming_1.png), [app_streaming_2.png](e2e-cfdl16/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-cfdl16/frames/dash_01.jpg), [dash_02.jpg](e2e-cfdl16/frames/dash_02.jpg), [dash_03.jpg](e2e-cfdl16/frames/dash_03.jpg), [dash_04.jpg](e2e-cfdl16/frames/dash_04.jpg), [dash_05.jpg](e2e-cfdl16/frames/dash_05.jpg), [dash_06.jpg](e2e-cfdl16/frames/dash_06.jpg), [dash_07.jpg](e2e-cfdl16/frames/dash_07.jpg), [dash_08.jpg](e2e-cfdl16/frames/dash_08.jpg), [dash_09.jpg](e2e-cfdl16/frames/dash_09.jpg), [dash_10.jpg](e2e-cfdl16/frames/dash_10.jpg), [dash_11.jpg](e2e-cfdl16/frames/dash_11.jpg), [dash_first.png](e2e-cfdl16/frames/dash_first.png), [dash_last.png](e2e-cfdl16/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
07:45:46.180 I/LINK: [:10922] bike closed
07:45:46.180 I/LINK: [state] reconnecting (1)
07:45:46.180 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
07:45:46.180 I/STATE: [state] Link dropped — reconnecting… — attempt 1
07:45:47.188 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:45:47.189 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:45:47.193 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:45:47.947 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:45:47.947 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:45:47.947 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:45:50.223 D/NAV: [speed] maxspeed lookup failed: Map service is busy (rate limited) — try again shortly
07:45:50.753 I/LINK: hb#10 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=0.0
07:45:51.961 I/LINK: [state] reconnecting (2)
07:45:51.961 I/STATE: [state] Link dropped — reconnecting… — attempt 2
07:45:51.961 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
07:45:53.464 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:45:53.465 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:45:53.465 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:45:54.252 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:45:54.253 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:45:54.253 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:45:55.759 I/LINK: hb#11 probed=false video=false framesSent=0 openServers=3 state=reconnecting (2) pulls/s=0.0
07:45:58.276 I/LINK: [state] reconnecting (3)
07:45:58.276 I/STATE: [state] Link dropped — reconnecting… — attempt 3
07:45:58.276 I/LINK: [reconnect] link lost — re-probing (attempt 3/20) in 2000ms
```
</details>

## E2E `cfdl26` (fake dash `cfdl26`, 30 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.554 s, canvas 800x944 |
| frames | 235 total, 29 keyframes (12% of session 1), avg 53737 B, first frame 0.076 s after 113 |
| pulls | stream 7.75 fps; 114→frame p50 18.1 ms, p95 611.62 ms, max 1435.17 ms |
| SPS | profile_idc 66, level_idc 31, 800x944, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.083 s, max 1.843 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x944, 235 decoded / 235 received, 0 error line(s)  |
| phone identity | phoneUUID=24fb2539-078f-4032-86a1-ceef4e60ebaa, pubkey=sha256:8f9119b42e4efdd3, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=128, supportScreenTouch=False |
| heartbeats | ctrl1: 15 beats, max gap 2.637 s; ctrl2: 15 beats, max gap 2.361 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 235 (max 235), keyframes 29, missed pulls 0, profile CFDL26 / MotoPlay Portrait (1000 MT-X), canvas 800x944, dash CFMOTO-805120 sdk=1.1.4; projection {"bitrate": 3375000, "encoded_frames": 236, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 236}; engine {"avg_encode_ms": 15.8, "avg_render_ms": 22, "background_s": 0, "budget_fps": null, "canvas": "800x944", "demotions": 0, "encode_submissions": 236, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 236, "output_keyframes": 29, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 235, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 236, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 158 lines (`e2e-cfdl26/app-log.txt`)

Screenshots: [app_after.png](e2e-cfdl26/app_after.png), [app_streaming_1.png](e2e-cfdl26/app_streaming_1.png), [app_streaming_2.png](e2e-cfdl26/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-cfdl26/frames/dash_01.jpg), [dash_02.jpg](e2e-cfdl26/frames/dash_02.jpg), [dash_03.jpg](e2e-cfdl26/frames/dash_03.jpg), [dash_04.jpg](e2e-cfdl26/frames/dash_04.jpg), [dash_05.jpg](e2e-cfdl26/frames/dash_05.jpg), [dash_06.jpg](e2e-cfdl26/frames/dash_06.jpg), [dash_07.jpg](e2e-cfdl26/frames/dash_07.jpg), [dash_08.jpg](e2e-cfdl26/frames/dash_08.jpg), [dash_09.jpg](e2e-cfdl26/frames/dash_09.jpg), [dash_10.jpg](e2e-cfdl26/frames/dash_10.jpg), [dash_11.jpg](e2e-cfdl26/frames/dash_11.jpg), [dash_first.png](e2e-cfdl26/frames/dash_first.png), [dash_last.png](e2e-cfdl26/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
07:46:46.218 I/LINK: hb#6 probed=true video=true framesSent=226 openServers=3 state=streaming pulls/s=6.8
07:46:46.536 I/LINK: [hb] → PXC CAR_CTRL heartbeat #15
07:46:46.846 I/LINK: [hb] → PXC CAR_DATA heartbeat #15
07:46:46.983 I/LINK: [:10922] CFDL26 ctrl 0x10750 (?) len=0  → ack 0x10751 (empty)
07:46:47.413 I/LINK: [:10922] bike closed
07:46:47.413 I/LINK: [:10922] bike closed
07:46:47.414 I/LINK: [:10921] media closed
07:46:47.414 I/LINK: [:10920] media closed
07:46:47.414 I/VIDEO: media sockets closed → queue flushed
07:46:47.414 I/LINK: [state] reconnecting (1)
07:46:47.414 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
07:46:47.414 I/STATE: [state] Link dropped — reconnecting… — attempt 1
07:46:48.418 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:46:48.420 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 1 ms
07:46:48.427 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:46:49.179 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:46:49.180 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:46:49.180 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:46:51.234 I/LINK: hb#7 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=1.6
07:46:53.209 I/LINK: [state] reconnecting (2)
07:46:53.209 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
07:46:53.212 I/STATE: [state] Link dropped — reconnecting… — attempt 2
07:46:54.721 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:46:54.722 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:46:54.722 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
```
</details>

## E2E `music` (fake dash `cfdl16`, 36 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.258 s, canvas 800x384 |
| frames | 202 total, 33 keyframes (16% of session 1), avg 19613 B, first frame 0.154 s after 113 |
| pulls | stream 5.6 fps; 114→frame p50 0.89 ms, p95 841.36 ms, max 935.68 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.113 s, max 1.912 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x384, 202 decoded / 202 received, 0 error line(s)  |
| phone identity | phoneUUID=10d45aa3-493e-4604-b7c1-faea8548cbc9, pubkey=sha256:576951119f846926, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 18 beats, max gap 2.042 s; ctrl2: 17 beats, max gap 2.063 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 202 (max 202), keyframes 33, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 204, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 199}; engine {"avg_encode_ms": 4.3, "avg_render_ms": 5.6, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 204, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 204, "output_keyframes": 33, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 202, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 199, "repeated_frames": 5, "using_hardware_encoder": null}

App alive after the run: yes; app log: 173 lines (`e2e-music/app-log.txt`)

Screenshots: [app_after.png](e2e-music/app_after.png), [app_streaming_1.png](e2e-music/app_streaming_1.png), [app_streaming_2.png](e2e-music/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-music/frames/dash_01.jpg), [dash_02.jpg](e2e-music/frames/dash_02.jpg), [dash_03.jpg](e2e-music/frames/dash_03.jpg), [dash_04.jpg](e2e-music/frames/dash_04.jpg), [dash_05.jpg](e2e-music/frames/dash_05.jpg), [dash_06.jpg](e2e-music/frames/dash_06.jpg), [dash_07.jpg](e2e-music/frames/dash_07.jpg), [dash_08.jpg](e2e-music/frames/dash_08.jpg), [dash_09.jpg](e2e-music/frames/dash_09.jpg), [dash_10.jpg](e2e-music/frames/dash_10.jpg), [dash_11.jpg](e2e-music/frames/dash_11.jpg), [dash_first.png](e2e-music/frames/dash_first.png), [dash_last.png](e2e-music/frames/dash_last.png), [music_1_map_playing.png](e2e-music/frames/music_1_map_playing.png), [music_2_sheet.png](e2e-music/frames/music_2_sheet.png), [music_3_sheet_next.png](e2e-music/frames/music_3_sheet_next.png), [music_4_sheet_paused.png](e2e-music/frames/music_4_sheet_paused.png), [music_5_map_paused.png](e2e-music/frames/music_5_map_paused.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
07:50:10.683 I/LINK: hb#7 probed=true video=true framesSent=185 openServers=3 state=streaming pulls/s=9.6
07:50:12.311 I/LINK: [:10920] media closed
07:50:12.311 I/LINK: [:10922] bike closed
07:50:12.311 I/LINK: [:10921] media closed
07:50:12.313 I/VIDEO: media sockets closed → queue flushed
07:50:12.313 I/LINK: [:10922] bike closed
07:50:12.313 I/LINK: [state] reconnecting (1)
07:50:12.313 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
07:50:12.314 I/STATE: [state] Link dropped — reconnecting… — attempt 1
07:50:13.331 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:50:13.332 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:50:13.348 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:50:14.131 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:50:14.131 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:50:14.131 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:50:15.724 I/LINK: hb#8 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=3.2
07:50:18.182 I/LINK: [state] reconnecting (2)
07:50:18.182 I/STATE: [state] Link dropped — reconnecting… — attempt 2
07:50:18.182 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
07:50:19.691 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:50:19.693 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:50:19.693 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:50:20.446 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:50:20.446 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:50:20.446 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
```
</details>

## E2E `locked` (fake dash `cfdl16`, 60 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.226 s, canvas 800x384 |
| frames | 400 total, 58 keyframes (14% of session 1), avg 24593 B, first frame 0.096 s after 113 |
| pulls | stream 6.64 fps; 114→frame p50 2.18 ms, p95 625.85 ms, max 833.76 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.045 s, max 1.629 s |
| decode (ffprobe/ffmpeg, strict: `-xerror -err_detect +crccheck+bitstream+buffer+explode`) | decodable: **True**, h264 Constrained Baseline 800x384, 400 decoded / 400 received, 0 error line(s) ; lenient decode clean: True |
| phone identity | phoneUUID=96060a8b-808f-4e72-a8ce-e6e052d49cf2, pubkey=sha256:bf66bfb9d25bf400, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 30 beats, max gap 2.102 s; ctrl2: 29 beats, max gap 2.175 s |

Findings:

| severity | rule | count | message |
|---|---|---|---|
| info | LOCKED_ONE_VARIANT | 1 | one SPS/PPS variant over the run: both encoders wrote the same SPS/PPS, or no switch happened (the app's `[switch] first … IDR on the wire … (dump frame #k)` lines tell) |

SPS/PPS variants on the wire (one per encoder that fed the dash):

| # | first frame | frames | profile | constraints | level | size | poc | refs | frame_num bits | vui | reorder | picture |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 400 | 66 | 0xE0 | 31 | 800x384 | 0 | 2 | 5 | True | - | [dash_variant_1.png](e2e-locked/frames/dash_variant_1.png) |

SPS #1 `2742e01fa91819063602d4080808c2b5ef7c04` PPS `28de09c8`

Encoder switches checked on the wire (L8 frame = SPS+PPS+IDR of the logged size): vt-hw at #1, vt-sw at #152, vt-hw at #266

One SPS/PPS variant: both encoders wrote the same SPS/PPS (switches verified at #152 and #266).

<details><summary>Lock lines of the app log (25)</summary>

```
07:50:43.466 I/VIDEO: [hold] first IDR 4279b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
07:50:44.026 I/VIDEO: [vt-list] avc1 encoders: anon-1 name=Dynamically Registered avc1 Video Encoder hw=false
07:50:44.057 I/VIDEO: [own] first IDR 5744b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
07:50:44.162 I/VIDEO: [switch] first vt-hw IDR on the wire: 7422b (dump frame #1)
07:50:59.235 I/E2E: simulated lock at +15.0s
07:50:59.236 I/APP: scene active → inactive (own UI session, streaming)
07:50:59.258 I/VIDEO: [hold] first IDR 4279b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
07:50:59.289 I/VIDEO: [own-sw-pre] first IDR 28880b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
07:50:59.289 I/VIDEO: [bg] pre-warm vt-sw at inactive: create=noErr hw=? probe=IDR 28880b in 11ms
07:50:59.735 I/APP: scene inactive → background (own UI session, streaming)
07:50:59.749 I/VIDEO: [bg] enter: canvas 800x384 policy=vtsw rungs=vt-sw,hold last-live-idr=71253b hold-idrs=2
07:50:59.757 I/VIDEO: [bg] try vt-sw (pre-warmed): create=noErr hw=? probe=IDR 31570b in 7ms sps=ok → accepted
07:50:59.757 I/VIDEO: [switch] vt-hw → vt-sw: gate closed; next frame on the wire is an IDR (dump frame #152)
07:50:59.757 I/VIDEO: background → backgroundSoftware @8fps (encoder vt-sw, 3375kbps)
07:50:59.774 I/VIDEO: [switch] first vt-sw IDR on the wire: 31570b, 0.02s after the switch (dump frame #152)
07:51:09.775 I/VIDEO: [bg] +10s mode=backgroundSoftware enc=vt-sw cap=8fps out=3.5fps pulls=3.5/s served=38 (hold 0, fallback 0, none 0) errs=0 render=6.0ms enc=5.8ms cpu=8% thermal=none lowPower=false q=0
07:51:12.135 I/APP: [lock] 12s locked link=streaming wifi=up pulls=4.0/s dash=backgroundSoftware vt-sw 4.0fps gps=1s heading=1s batt=?% unknown thermal=none lowPower=false
07:51:19.759 I/VIDEO: [bg] +20s mode=backgroundSoftware enc=vt-sw cap=8fps out=4.0fps pulls=4.0/s served=77 (hold 0, fallback 0, none 0) errs=0 render=4.8ms enc=4.3ms cpu=8% thermal=none lowPower=false q=0
07:51:29.258 I/E2E: simulated unlock at +45.0s
07:51:29.259 I/APP: scene background → inactive after 30s (own UI session, streaming)
07:51:29.259 I/APP: scene inactive → active (own UI session, streaming)
07:51:29.274 I/VIDEO: [switch] vt-sw → vt-hw: gate closed; next frame on the wire is an IDR (dump frame #266)
07:51:29.335 I/VIDEO: foreground → hardware encoder, IDR forced (background 30s: vt-sw 114 frames 27 IDR 0 errors enc 4.8ms; hold served 0)
07:51:29.347 I/VIDEO: [own] first IDR 30095b SPS 27 42 e0 1f a9 18 19 06 36 02 d4 08 08 08 c2 b5 ef 7c 04 PPS 28 de 09 c8 — profile 66 constraints 0xE0 level 31 800x384 poc 0 refs 2 frame_num_bits 5 vui=yes reorder=- | pps cavlc deblock_ctrl=1 qp=28
07:51:29.348 I/VIDEO: [switch] first vt-hw IDR on the wire: 30095b, 0.08s after the switch (dump frame #266)
```
</details>

App status (`app-status.json`, last write): phase **reconnecting** (attempt 3), link reconnecting (3), ever streaming: True, frames sent 400 (max 400), keyframes 58, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 402, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 403}; engine {"avg_encode_ms": 4.4, "avg_render_ms": 4.9, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 403, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 402, "output_keyframes": 59, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 400, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 403, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 191 lines (`e2e-locked/app-log.txt`)

Screenshots: [app_after.png](e2e-locked/app_after.png), [app_streaming_1.png](e2e-locked/app_streaming_1.png), [app_streaming_2.png](e2e-locked/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-locked/frames/dash_01.jpg), [dash_02.jpg](e2e-locked/frames/dash_02.jpg), [dash_03.jpg](e2e-locked/frames/dash_03.jpg), [dash_04.jpg](e2e-locked/frames/dash_04.jpg), [dash_05.jpg](e2e-locked/frames/dash_05.jpg), [dash_06.jpg](e2e-locked/frames/dash_06.jpg), [dash_07.jpg](e2e-locked/frames/dash_07.jpg), [dash_08.jpg](e2e-locked/frames/dash_08.jpg), [dash_09.jpg](e2e-locked/frames/dash_09.jpg), [dash_10.jpg](e2e-locked/frames/dash_10.jpg), [dash_first.png](e2e-locked/frames/dash_first.png), [dash_last.png](e2e-locked/frames/dash_last.png), [dash_variant_1.png](e2e-locked/frames/dash_variant_1.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
07:51:44.416 I/VIDEO: media sockets closed → queue flushed
07:51:44.416 I/LINK: [:10922] bike closed
07:51:44.417 I/LINK: [state] reconnecting (1)
07:51:44.417 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
07:51:44.417 I/STATE: [state] Link dropped — reconnecting… — attempt 1
07:51:45.444 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:51:45.446 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:51:45.461 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:51:46.235 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:51:46.235 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:51:46.236 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:51:48.692 I/LINK: hb#13 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=0.8
07:51:50.268 I/LINK: [state] reconnecting (2)
07:51:50.268 I/STATE: [state] Link dropped — reconnecting… — attempt 2
07:51:50.268 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
07:51:51.776 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:51:51.777 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:51:51.777 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:51:52.534 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:51:52.535 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:51:52.535 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:51:53.693 I/LINK: hb#14 probed=false video=false framesSent=0 openServers=3 state=reconnecting (2) pulls/s=0.0
07:51:56.577 I/LINK: [state] reconnecting (3)
07:51:56.577 I/STATE: [state] Link dropped — reconnecting… — attempt 3
07:51:56.577 I/LINK: [reconnect] link lost — re-probing (attempt 3/20) in 2000ms
```
</details>

## E2E `reconnect` (fake dash `cfdl16`, 10 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 2 / 2 |
| session 1 | end: completed, handshake 0.24 s, canvas 800x384 |
| frames | 182 total, 11 keyframes (12% of session 1), avg 23061 B, first frame 0.096 s after 113 |
| session 2 | end: completed, handshake 0.227 s, canvas 800x384, 91 frames (10 keyframes), probe at 18.077 s |
| re-probe | 1.03 s after the previous session ended (accepted) |
| pulls | stream 8.95 fps; 114→frame p50 0.53 ms, p95 594.32 ms, max 676.3 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.016 s, max 1.044 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x384, 182 decoded / 182 received, 0 error line(s)  |
| phone identity | phoneUUID=969f042a-8a1d-45da-93f8-11e0e9a68816, pubkey=sha256:a0137340f1b0bc64, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 5 beats, max gap 2.053 s; ctrl2: 5 beats, max gap 2.031 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 182 (max 182), keyframes 21, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 185, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 185}; engine {"avg_encode_ms": 4.4, "avg_render_ms": 6, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 185, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 185, "output_keyframes": 21, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 182, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 185, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 211 lines (`e2e-reconnect/app-log.txt`)

Screenshots: [app_after.png](e2e-reconnect/app_after.png), [app_streaming_1.png](e2e-reconnect/app_streaming_1.png), [app_streaming_2.png](e2e-reconnect/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-reconnect/frames/dash_01.jpg), [dash_02.jpg](e2e-reconnect/frames/dash_02.jpg), [dash_03.jpg](e2e-reconnect/frames/dash_03.jpg), [dash_04.jpg](e2e-reconnect/frames/dash_04.jpg), [dash_05.jpg](e2e-reconnect/frames/dash_05.jpg), [dash_06.jpg](e2e-reconnect/frames/dash_06.jpg), [dash_07.jpg](e2e-reconnect/frames/dash_07.jpg), [dash_08.jpg](e2e-reconnect/frames/dash_08.jpg), [dash_09.jpg](e2e-reconnect/frames/dash_09.jpg), [dash_10.jpg](e2e-reconnect/frames/dash_10.jpg), [dash_11.jpg](e2e-reconnect/frames/dash_11.jpg), [dash_first.png](e2e-reconnect/frames/dash_first.png), [dash_last.png](e2e-reconnect/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
07:47:38.819 I/LINK: [:10920] media closed
07:47:38.819 I/LINK: [:10922] bike closed
07:47:38.819 I/LINK: [:10922] bike closed
07:47:38.820 I/LINK: [:10921] media closed
07:47:38.820 I/VIDEO: media sockets closed → queue flushed
07:47:38.820 I/LINK: [state] reconnecting (1)
07:47:38.820 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
07:47:38.820 I/STATE: [state] Link dropped — reconnecting… — attempt 1
07:47:39.829 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:47:39.830 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:47:39.833 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:47:40.608 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:47:40.609 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:47:40.609 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:47:41.455 I/LINK: hb#5 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=5.2
07:47:44.663 I/LINK: [state] reconnecting (2)
07:47:44.663 I/STATE: [state] Link dropped — reconnecting… — attempt 2
07:47:44.663 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
07:47:46.203 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:47:46.204 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:47:46.204 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:47:46.496 I/LINK: hb#6 probed=false video=false framesSent=0 openServers=3 state=reconnecting (2) pulls/s=0.0
07:47:46.955 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:47:46.956 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:47:46.956 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
```
</details>

## E2E `stall` (fake dash `cfdl16`, 6 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 2 / 2 |
| session 1 | end: phone closed ctrl2 (EOF), handshake 0.266 s, canvas 800x384 |
| frames | 113 total, 7 keyframes (12% of session 1), avg 22927 B, first frame 0.085 s after 113 |
| session 2 | end: completed, handshake 0.291 s, canvas 800x384, 57 frames (7 keyframes), probe at 21.321 s |
| re-probe | 1.019 s after the previous session ended (accepted) |
| pulls | stream 9.01 fps; 114→frame p50 0.53 ms, p95 584.46 ms, max 856.61 ms |
| SPS | profile_idc 66, level_idc 31, 800x384, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.035 s, max 1.129 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 800x384, 113 decoded / 113 received, 0 error line(s)  |
| phone identity | phoneUUID=7f1704fc-468d-42fb-b340-07dc996c33cb, pubkey=sha256:b7e3fb30e896d429, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=0, supportScreenTouch=False |
| heartbeats | ctrl1: 7 beats, max gap 2.044 s; ctrl2: 7 beats, max gap 2.027 s |

Findings:

| severity | rule | count | message |
|---|---|---|---|
| info | WATCHDOG | 1 | the phone dropped every socket 8.17 s after the last frame (watchdog > 8 s, 5 s tick) |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 113 (max 113), keyframes 14, missed pulls 0, profile CFDL16 / legacy (BIKE A), canvas 800x384, dash CFDL16-6GUV sdk=0.9.29.1; projection {"bitrate": 3375000, "encoded_frames": 118, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 118}; engine {"avg_encode_ms": 5, "avg_render_ms": 7, "background_s": 0, "budget_fps": null, "canvas": "800x384", "demotions": 0, "encode_submissions": 118, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 118, "output_keyframes": 16, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 113, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 118, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 211 lines (`e2e-stall/app-log.txt`)

Screenshots: [app_after.png](e2e-stall/app_after.png), [app_streaming_1.png](e2e-stall/app_streaming_1.png), [app_streaming_2.png](e2e-stall/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-stall/frames/dash_01.jpg), [dash_02.jpg](e2e-stall/frames/dash_02.jpg), [dash_03.jpg](e2e-stall/frames/dash_03.jpg), [dash_04.jpg](e2e-stall/frames/dash_04.jpg), [dash_05.jpg](e2e-stall/frames/dash_05.jpg), [dash_06.jpg](e2e-stall/frames/dash_06.jpg), [dash_07.jpg](e2e-stall/frames/dash_07.jpg), [dash_08.jpg](e2e-stall/frames/dash_08.jpg), [dash_09.jpg](e2e-stall/frames/dash_09.jpg), [dash_10.jpg](e2e-stall/frames/dash_10.jpg), [dash_11.jpg](e2e-stall/frames/dash_11.jpg), [dash_first.png](e2e-stall/frames/dash_first.png), [dash_last.png](e2e-stall/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
07:48:29.480 I/LINK: [:10922] bike closed
07:48:29.480 I/LINK: [:10921] media closed
07:48:29.480 I/LINK: [:10922] bike closed
07:48:29.480 I/LINK: [:10920] media closed
07:48:29.481 I/VIDEO: media sockets closed → queue flushed
07:48:29.481 I/LINK: [state] reconnecting (1)
07:48:29.481 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
07:48:29.481 I/STATE: [state] Link dropped — reconnecting… — attempt 1
07:48:30.517 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:48:30.517 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:48:30.521 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:48:31.297 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:48:31.297 I/LINK: hb#5 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=5.4
07:48:31.298 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:48:31.298 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:48:35.309 I/LINK: [state] reconnecting (2)
07:48:35.309 I/STATE: [state] Link dropped — reconnecting… — attempt 2
07:48:35.309 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
07:48:36.309 I/LINK: hb#6 probed=false video=false framesSent=0 openServers=3 state=reconnecting (2) pulls/s=0.0
07:48:36.851 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:48:36.851 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:48:36.852 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:48:37.602 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:48:37.603 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:48:37.603 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
```
</details>

## E2E `touch` (fake dash `mt800`, 15 s streaming)

**PASS**


| | |
|---|---|
| fakedash result | **PASS** (goal reached: True) — 0 violation(s), 0 warning(s) |
| probes / sessions | 1 / 1 |
| session 1 | end: completed, handshake 0.336 s, canvas 1280x576 |
| frames | 155 total, 15 keyframes (9% of session 1), avg 19087 B, first frame 0.078 s after 113 |
| pulls | stream 10.17 fps; 114→frame p50 0.9 ms, p95 546.97 ms, max 627.69 ms |
| SPS | profile_idc 66, level_idc 31, 1280x576, reorder None, refs 2, vui fps None |
| IDR interval | mean 1.024 s, max 1.081 s |
| decode (ffprobe/ffmpeg) | decodable: **True**, h264 Constrained Baseline 1280x576, 155 decoded / 155 received, 0 error line(s)  |
| phone identity | phoneUUID=6e0101b2-d75e-4a0d-9240-df630dcbc906, pubkey=sha256:854a74561b1229f9, phoneBrand=Apple, phoneModel=iPhone17,3, phoneOsVersion=35, supportFunction=128, supportScreenTouch=True |
| heartbeats | ctrl1: 7 beats, max gap 2.041 s; ctrl2: 7 beats, max gap 2.032 s |

App status (`app-status.json`, last write): phase **reconnecting** (attempt 2), link reconnecting (2), ever streaming: True, frames sent 155 (max 155), keyframes 15, missed pulls 0, profile CFDL26 / MotoPlay Landscape (800MT), canvas 1280x576, dash CFMOTO1565 sdk=1.1.2; projection {"bitrate": 3375000, "encoded_frames": 156, "fps": 0, "last_error": null, "mode": "foreground", "rendered_frames": 156}; engine {"avg_encode_ms": 7.3, "avg_render_ms": 13, "background_s": 0, "budget_fps": null, "canvas": "1280x576", "demotions": 0, "encode_submissions": 156, "encoder": "vt-hw", "encoder_errors": 0, "fallback_keyframes_served": 0, "gated_drops": 0, "hold_frames_served": 0, "mode": "foreground", "output_fps": 0, "output_frames": 156, "output_keyframes": 15, "pool_exhausted": 0, "pull_rate": 0, "pulls_served": 155, "pulls_unanswered": 0, "queue_overflows": 0, "rendered_frames": 156, "repeated_frames": 0, "using_hardware_encoder": null}

App alive after the run: yes; app log: 172 lines (`e2e-touch/app-log.txt`)

Screenshots: [app_after.png](e2e-touch/app_after.png), [app_streaming_1.png](e2e-touch/app_streaming_1.png), [app_streaming_2.png](e2e-touch/app_streaming_2.png)

Decoded frames: [dash_01.jpg](e2e-touch/frames/dash_01.jpg), [dash_02.jpg](e2e-touch/frames/dash_02.jpg), [dash_03.jpg](e2e-touch/frames/dash_03.jpg), [dash_04.jpg](e2e-touch/frames/dash_04.jpg), [dash_05.jpg](e2e-touch/frames/dash_05.jpg), [dash_06.jpg](e2e-touch/frames/dash_06.jpg), [dash_07.jpg](e2e-touch/frames/dash_07.jpg), [dash_08.jpg](e2e-touch/frames/dash_08.jpg), [dash_09.jpg](e2e-touch/frames/dash_09.jpg), [dash_10.jpg](e2e-touch/frames/dash_10.jpg), [dash_11.jpg](e2e-touch/frames/dash_11.jpg), [dash_first.png](e2e-touch/frames/dash_first.png), [dash_last.png](e2e-touch/frames/dash_last.png)

The app-side wire dump (`e2e-app.h264`) decodes to the very same first picture as the dash side.

<details><summary>App log tail</summary>

```
07:49:08.978 I/LINK: [:10922] bike closed
07:49:08.980 I/LINK: [:10921] media closed
07:49:08.981 I/LINK: [:10920] media closed
07:49:08.981 I/VIDEO: media sockets closed → queue flushed
07:49:08.981 I/LINK: [state] reconnecting (1)
07:49:08.981 I/STATE: [state] Link dropped — reconnecting… — attempt 1
07:49:08.981 I/LINK: [reconnect] link lost — re-probing (attempt 1/20) in 1000ms
07:49:09.983 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:49:09.984 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:49:09.996 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:49:10.748 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:49:10.750 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:49:10.750 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:49:13.087 I/LINK: hb#4 probed=false video=false framesSent=0 openServers=3 state=reconnecting (1) pulls/s=1.2
07:49:14.759 I/LINK: [state] reconnecting (2)
07:49:14.759 I/LINK: [reconnect] link lost — re-probing (attempt 2/20) in 1500ms
07:49:14.761 I/STATE: [state] Link dropped — reconnecting… — attempt 2
07:49:16.268 I/LINK: [PROBE] connect #1 -> 127.0.0.1:10930
07:49:16.269 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:49:16.269 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:49:17.023 I/LINK: [PROBE] connect #2 -> 127.0.0.1:10930
07:49:17.023 D/NET: connect 127.0.0.1:10930 unbound (loopback destination) failed: ECONNREFUSED (Connection refused) (SO_ERROR) after 0 ms
07:49:17.024 I/LINK: [PROBE] failed: transport failure: ECONNREFUSED: connection refused (127.0.0.1:10930)
07:49:17.224 D/NAV: [speed] maxspeed lookup failed: Map service is busy (rate limited) — try again shortly
07:49:18.098 I/LINK: hb#5 probed=false video=false framesSent=0 openServers=3 state=reconnecting (2) pulls/s=0.0
```
</details>

PNGs quantized with pngquant: 29.6 MB → 9.6 MB.


Total artifact size: 9.6 MB
