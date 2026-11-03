# CI e2e: the real app in the iOS Simulator

The `e2e` job of `.github/workflows/ci.yml` (macos-15; pushes to `main` / `wip/e2e` and manual
runs) builds the app for an iPhone simulator, screenshots every screen and runs the **real** link
stack against the Python fake dash (`tools/fakedash/fakedash.py`). Everything it produces is
force-pushed to the orphan branch **`ci-artifacts`** (one commit, < 15 MB), so it can be read with
plain git even where job logs and artifacts are not downloadable:

```sh
git fetch origin ci-artifacts && git worktree add /tmp/ci-artifacts FETCH_HEAD
open /tmp/ci-artifacts/RUN.md
```

`RUN.md` lists the commit, Xcode, simulator, step timings, the build result, the screenshots and,
per fake-dash scenario, the fakedash verdict (violations / warnings / findings), frame counts, pull
rate and latency, SPS, IDR interval, the ffprobe/ffmpeg decode check, the app's own counters and
the tail of the app log.

## Scenario `locked` (locked iPhone, Phase 0)

Step `E2E locked` runs the app with `-e2eBackgroundCycle 15:30 -e2eBackgroundEncoder vtsw` against
fakedash's `locked` scenario (cfdl16, 60 s): 15 s after the first frame the app "locks" for 30 s and
the engine runs its background ladder with the Mac's VideoToolbox software encoder. fakedash records
every SPS/PPS variant (`sps_variants` in `summary.json`), checks that every new SPS/PPS starts at an
IDR and that `frame_num` stays continuous (`SWITCH_NOT_AT_IDR`: a P-frame of a second encoder whose
IDR never reached the dash breaks it, whatever the SPS/PPS bytes), and decodes strictly
(`-xerror -err_detect +crccheck+bitstream+buffer+explode`). The Simulator's only `avc1` encoder writes
the hardware encoder's SPS/PPS byte for byte, so the wire shows one variant; the CI step passes
`FAKEDASH_ARGS="--min-variants 1"`, which turns that into a note (`LOCKED_ONE_VARIANT`; without it,
fewer than two variants is `LOCKED_NO_SWITCH`). RUN.md shows the variants table with one picture per
variant and the lock lines of the app log (`[bg] …`, `background → …`, `[switch] …`, `[lock] …`), and
checks every `[switch] first <enc> IDR on the wire: <n>b … (dump frame #k)` line against frame #k of
the transcript (SPS+PPS+IDR of n bytes). It fails the scenario when a switch frame does not match or
the app warns of a switch on a non-IDR frame, when one variant comes without a verified vt-sw → vt-hw
switch back, or when the app log has no `background → backgroundSoftware … (encoder vt-sw` line or no
`[switch] first vt-sw IDR on the wire` line. The scenario is **not** in `--require` (only `cfdl16`,
`cfdl26`, `music` are): the Simulator does not background the app for real. The status JSON's
`engine` block also reports `encoder`, `background_s`, `budget_fps` and `demotions`.

## App launch arguments (App/Sources/Services/AppLaunchOptions.swift)

| Argument | Effect |
|---|---|
| `-demo` | simulated bike side (always on in the Simulator unless `-e2eFakeDash`) |
| `-demoSeed` | demo bike, three saved trips on the demo route, home + favourites, onboarding done, auto-connect off |
| `-e2eFakeDash [-e2eDash cfdl16\|cfdl26\|mt800] [-e2eHost 127.0.0.1]` | real `POSIXNetworkProvider` (the bike-link transport; loopback connects unbound), `EasyConnLink`, SecKey RSA identity, `DashProjectionEngine` + VideoToolbox + `DashRenderer` + tiles; fake Wi-Fi "already joined" and local-only like the dash's access point (gateway = the fake dash, phone = 127.0.0.2 on `lo0` via `ConnectionTestingOverrides.loopback()`), demo GPS, a seeded bike matching the fakedash model, auto-connect. Writes `Documents/e2e-log.txt`, `e2e-status.json` (every 2 s) and `e2e-app.h264` |
| `-uiScreen home\|dash\|navigate\|trips\|settings\|controls\|logs\|garage\|about\|mirror\|onboarding\|scan\|ride` | RootView opens that screen after launch |
| `-uiOrientation landscape` | rotates the interface (the screenshot is rotated back by the job) |
| `-e2eMusic` | with `-e2eFakeDash`: a fake Apple Music (three songs with drawn covers) and a script on the dash — Music sheet at +9 s, next song +15 s, pause +21 s, close +27 s after the first frame |
| `-e2eBackgroundCycle <start>:<duration>` | with `-e2eFakeDash`: a simulated phone lock `start` s after the session first streams, for `duration` s — the scene goes `.inactive`, 0.5 s later `.background`, then `.inactive` and `.active` at the unlock, through the real AppModel → RideModel → ProjectionAdapter → engine path (`E2E: simulated lock at +15.0s` / `simulated unlock at +45.0s`). The Simulator never really backgrounds the app: VideoToolbox keeps working and there is no CPU monitor or Wi-Fi sleep, so this exercises the switching machinery only |
| `-e2eBackgroundEncoder auto\|vtsw\|cpu\|hold\|cpu-always` | the locked-phone policy of the run (`LockedStreamPolicy` raw values), winning over the build default (`vtsw` in the Phase 0 diagnostics build) and any stored value; an invalid value is ignored with a warning in the log |
| `-uiDashSheet music` | with `-uiScreen dash`: opens the dash's Music sheet once the demo music shows on the dash |
| `-uiSettingsAnchor music` | with `-uiScreen settings`: scrolls Settings to the "Apple Music on the dash" section |

## Scripts

| Script | Does |
|---|---|
| `simctl_pick.py` | picks the newest-runtime iPhone simulator (`udid=… name=… runtime=…`) |
| `screenshots.sh <udid> <bundle> <out>` | `simctl launch -demo -demoSeed -uiScreen <name>` + `simctl io screenshot` for every screen, landscape dash view, the dash's Music sheet (`dash_music`), Settings at "Apple Music on the dash" (`settings_music`), Spanish home / settings / Apple Music settings / dash / Music sheet |
| `run-fakedash.sh <udid> <bundle> <scenario> <dash> <seconds> <out> [app args]` | fakedash on 127.0.0.1 ↔ the app with `-e2eFakeDash`; screenshots while streaming, the app's Documents dumps, decoded frames (`ffmpeg`, every 60th frame) plus the pictures the app's E2E script marks (`E2E: frame mark <name> = <index>` → `frames/<name>.png`; `-e2eMusic`: `music_1_map_playing` … `music_5_map_paused`); scenario `locked`: `frames/dash_variant_N.png` (5 frames after SPS/PPS variant N first reached the dash) and `frames/headers.txt` (the SPS/PPS ffmpeg parsed) |
| `transcript_digest.py` | readable digest of a fakedash `--transcript` (per-frame traffic folded) |
| `assemble.py <out> <artifacts>` | artifacts tree + `RUN.md` + GitHub annotations (`E2E <scenario> PASS/FAIL`) |
| `test_assemble.py` | unit tests of the `locked` report (variants table, switch frames checked on the wire, failure reasons): `python3 tools/ci/e2e/test_assemble.py` |
| `publish.sh <dir>` | force-pushes the tree as the single commit of `ci-artifacts` (`GITHUB_TOKEN`, `contents: write`) |

## Running it on a Mac

```sh
brew install xcodegen ffmpeg
xcodegen generate
eval "$(python3 tools/ci/e2e/simctl_pick.py | grep '^udid=')"; xcrun simctl boot "$udid"
xcodebuild -project OpenCfMoto.xcodeproj -scheme OpenCfMoto -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
xcrun simctl install "$udid" build/dd/Build/Products/Debug-iphonesimulator/OpenCfMoto.app
bash tools/ci/e2e/screenshots.sh "$udid" com.example.opencfmoto out
bash tools/ci/e2e/run-fakedash.sh "$udid" com.example.opencfmoto cfdl16 cfdl16 45 out
python3 tools/ci/e2e/assemble.py out art && open art/RUN.md
```

By hand: `python3 tools/fakedash/fakedash.py --bind 127.0.0.1 --scenario cfdl16 --seconds 30 --decode`
in one terminal, then `xcrun simctl launch --console booted com.example.opencfmoto -e2eFakeDash`.
