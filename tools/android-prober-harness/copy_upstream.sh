#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copies the ORIGINAL Android sources verbatim into upstream/ (git-ignored) and checks them against
# upstream/SHA256SUMS (the exact files the published differential run used).
#   UPSTREAM=/path/to/open-cfmoto ./copy_upstream.sh          (default: ../../../open-cfmoto)
#   ./copy_upstream.sh --check                                   (verify nothing was edited)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
UPSTREAM=${UPSTREAM:-$HERE/../../../open-cfmoto}
SRC=$UPSTREAM/app/src/main/java/dev/zanderp/opencfmoto
DST=$HERE/upstream/dev/zanderp/opencfmoto
FILES=(
  EasyConnProber.kt PxcHandshake.kt PxcFrame.kt BikeProfile.kt VideoPipeline.kt RsaKeys.kt
  ClockLab.kt HuQueryTime.kt BleProtocol.kt ConnectionState.kt LogBus.kt LogRedactor.kt
  ProfileOverride.kt BikeScope.kt BikeMemory.kt QrData.kt DashMemory.kt AaVideoBridge.kt
  GpxSession.kt MapPlaces.kt EasyConnDiscovery.kt YunmoFrame.kt YunmoLink.kt VideoPrefs.kt
  ProjectionHolder.kt
)
if [[ "${1:-}" == "--check" ]]; then
  (cd "$DST" && sha256sum -c "$HERE/upstream/SHA256SUMS")
  exit 0
fi
mkdir -p "$DST"
rm -f "$DST"/*.kt
for f in "${FILES[@]}"; do cp "$SRC/$f" "$DST/$f"; done
if (cd "$DST" && sha256sum -c --quiet "$HERE/upstream/SHA256SUMS" 2>/dev/null); then
  echo "copied ${#FILES[@]} files — identical to the files used by docs/verification/pxc-differential.md"
else
  echo "copied ${#FILES[@]} files — NOTE: they differ from the recorded SHA256SUMS (newer upstream?)"
fi
echo "upstream git rev: $(git -C "$UPSTREAM" rev-parse HEAD 2>/dev/null || echo '?')"
