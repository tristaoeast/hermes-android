#!/usr/bin/env bash
set -euo pipefail

# Stage built APKs into dist/ under descriptive names, then serve them over HTTP
# so an Android device on the LAN (or Tailscale) can download and install them.
# Flutter names every split build "app-<abi>-release.apk", which is useless once
# several are sitting in the phone's Downloads folder.

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Flutter copies each APK here; Gradle's own output dir is the fallback.
FLUTTER_DIR="build/app/outputs/flutter-apk"
GRADLE_DIR="build/app/outputs/apk"
DIST_DIR="dist"
BASE_PORT=9110
MAX_PORT=9119

# Newest installed build-tools; aapt2 names the file, apksigner rejects unsigned APKs
BUILD_TOOLS="$(ls -d "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"/build-tools/* \
  2>/dev/null | sort -V | tail -1 || true)"
AAPT2="${BUILD_TOOLS:+$BUILD_TOOLS/aapt2}"
APKSIGNER="${BUILD_TOOLS:+$BUILD_TOOLS/apksigner}"

# hermes-android-<versionName>-<abi>-<buildType>.apk
describe() {
  local apk="$1" name buildtype version="" abi="" badging
  name="$(basename "$apk" .apk)"
  buildtype="${name##*-}"
  if [ -n "$AAPT2" ] && [ -x "$AAPT2" ]; then
    badging="$("$AAPT2" dump badging "$apk" 2>/dev/null || true)"
    version="$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$badging" | head -1)"
    abi="$(sed -n "s/^native-code: *//p" <<<"$badging" | head -1 | tr -d "'" | tr ' ' '+')"
  fi
  printf 'hermes-android%s%s-%s.apk' \
    "${version:+-$version}" "${abi:+-$abi}" "$buildtype"
}

# An unsigned release APK (built without key.properties) cannot be installed.
signed() {
  [ -z "$APKSIGNER" ] || [ ! -x "$APKSIGNER" ] || "$APKSIGNER" verify "$1" >/dev/null 2>&1
}

mkdir -p "$DIST_DIR"

shopt -s nullglob
BUILT=("$FLUTTER_DIR"/*.apk)
[ ${#BUILT[@]} -gt 0 ] || BUILT=("$GRADLE_DIR"/*/*.apk)
for apk in "${BUILT[@]}"; do
  target="$DIST_DIR/$(describe "$apk")"
  if [ ! -e "$target" ] || [ "$apk" -nt "$target" ]; then
    if ! signed "$apk"; then
      echo "skipped (unsigned): $apk"
      continue
    fi
    cp -f "$apk" "$target"
    echo "staged: $target"
  fi
done
APKS=("$DIST_DIR"/*.apk)
shopt -u nullglob

if [ ${#APKS[@]} -eq 0 ]; then
  echo "ERROR: no APK files found in $FLUTTER_DIR, $GRADLE_DIR or $DIST_DIR"
  echo "Build one first with:"
  echo "  bash .claude/skills/serve-apks/scripts/build-release-arm64.sh"
  exit 1
fi

(cd "$DIST_DIR" && sha256sum -- *.apk > SHA256SUMS)

PORT=$BASE_PORT
while ss -tln 2>/dev/null | grep -q ":${PORT} "; do
  PORT=$((PORT + 1))
  if [ "$PORT" -gt "$MAX_PORT" ]; then
    echo "ERROR: no available ports in range ${BASE_PORT}-${MAX_PORT}"
    exit 1
  fi
done

LOCAL_IP=$(ip -4 route get 1.0.0.0 2>/dev/null |
  awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
LOCAL_IP="${LOCAL_IP:-localhost}"

TS_DNS=$(tailscale status --json 2>/dev/null |
  python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" \
  2>/dev/null || echo "")

echo "=== Hermes Android APK Server ==="
echo ""
echo "Available APKs:"
ls -lht "$DIST_DIR"/*.apk | awk '{print "  " $NF " (" $5 ", " $6 " " $7 " " $8 ")"}'
echo ""
echo "SHA-256 (also at /SHA256SUMS):"
sed 's/^/  /' "$DIST_DIR/SHA256SUMS"
echo ""
echo "Access URLs:"
echo "  Local network: http://${LOCAL_IP}:${PORT}/"
if [ -n "$TS_DNS" ]; then
  echo "  Tailscale:     http://${TS_DNS}:${PORT}/"
fi
echo ""
echo "Open the URL on your Android device browser to download and install."
echo "Android will ask to allow installing unknown apps from the browser."
echo "Press Ctrl+C to stop the server."
echo ""

python3 -m http.server "$PORT" -d "$DIST_DIR"
