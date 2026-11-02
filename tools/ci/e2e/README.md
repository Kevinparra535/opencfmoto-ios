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

## App launch arguments (App/Sources/Services/AppLaunchOptions.swift)

| Argument | Effect |
|---|---|
| `-demo` | simulated bike side (always on in the Simulator unless `-e2eFakeDash`) |
| `-demoSeed` | demo bike, three saved trips on the demo route, home + favourites, onboarding done, auto-connect off |
| `-e2eFakeDash [-e2eDash cfdl16\|cfdl26\|mt800] [-e2eHost 127.0.0.1]` | real `POSIXNetworkProvider` (the bike-link transport; loopback connects unbound), `EasyConnLink`, SecKey RSA identity, `DashProjectionEngine` + VideoToolbox + `DashRenderer` + tiles; fake Wi-Fi "already joined" and local-only like the dash's access point (gateway = the fake dash, phone = 127.0.0.2 on `lo0` via `ConnectionTestingOverrides.loopback()`), demo GPS, a seeded bike matching the fakedash model, auto-connect. Writes `Documents/e2e-log.txt`, `e2e-status.json` (every 2 s) and `e2e-app.h264` |
| `-uiScreen home\|dash\|navigate\|trips\|settings\|controls\|logs\|garage\|about\|mirror\|onboarding\|scan\|ride` | RootView opens that screen after launch |
| `-uiOrientation landscape` | rotates the interface (the screenshot is rotated back by the job) |
| `-e2eMusic` | with `-e2eFakeDash`: a fake Apple Music (three songs with drawn covers) and a script on the dash — Music sheet at +9 s, next song +15 s, pause +21 s, close +27 s after the first frame |
| `-uiDashSheet music` | with `-uiScreen dash`: opens the dash's Music sheet once the demo music shows on the dash |
| `-uiSettingsAnchor music` | with `-uiScreen settings`: scrolls Settings to the "Apple Music on the dash" section |

## Scripts

| Script | Does |
|---|---|
| `simctl_pick.py` | picks the newest-runtime iPhone simulator (`udid=… name=… runtime=…`) |
| `screenshots.sh <udid> <bundle> <out>` | `simctl launch -demo -demoSeed -uiScreen <name>` + `simctl io screenshot` for every screen, landscape dash view, the dash's Music sheet (`dash_music`), Settings at "Apple Music on the dash" (`settings_music`), Spanish home / settings / Apple Music settings / dash / Music sheet |
| `run-fakedash.sh <udid> <bundle> <scenario> <dash> <seconds> <out> [app args]` | fakedash on 127.0.0.1 ↔ the app with `-e2eFakeDash`; screenshots while streaming, the app's Documents dumps, decoded frames (`ffmpeg`, every 60th frame) plus the pictures the app's E2E script marks (`E2E: frame mark <name> = <index>` → `frames/<name>.png`; `-e2eMusic`: `music_1_map_playing` … `music_5_map_paused`) |
| `transcript_digest.py` | readable digest of a fakedash `--transcript` (per-frame traffic folded) |
| `assemble.py <out> <artifacts>` | artifacts tree + `RUN.md` + GitHub annotations (`E2E <scenario> PASS/FAIL`) |
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
