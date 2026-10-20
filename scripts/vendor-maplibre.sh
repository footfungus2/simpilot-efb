#!/usr/bin/env bash
# Puts MapLibre (globe pre-release) in ios/Vendor/MapLibre.xcframework, with its minimum iOS changed from 15.5 to 15.0.
#
# The release declares iOS 15.5, which makes the linker warn for our iOS 15.0 target (the iPad runs 15.3.1).
# Its binary imports no system symbol newer than iOS 15.0 (checked against the SDK headers on 2026-10-20), so the
# label is lowered: LC_BUILD_VERSION via vtool + MinimumOSVersion in each framework's Info.plist. dSYMs are dropped.
#
#   ./scripts/vendor-maplibre.sh          (re)creates the vendored copy; build-ipa.sh runs it when missing
set -euo pipefail

URL="https://github.com/maplibre/maplibre-native/releases/download/ios-v2026.10.19-globe/MapLibre.dynamic.xcframework.zip"
SHA256="ae9c967acf220111d8fb1c8f066d23cff0d91c5ec827c8f68770d4cd55f799e8"
MIN_OS="15.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/ios/Vendor/MapLibre.xcframework"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading MapLibre…"
curl -fsSL -o "$WORK/maplibre.zip" "$URL"
echo "$SHA256  $WORK/maplibre.zip" | shasum -a 256 -c - >/dev/null || { echo "MapLibre checksum mismatch" >&2; exit 1; }
mkdir "$WORK/x"
unzip -q "$WORK/maplibre.zip" -d "$WORK/x" -x "*/dSYMs/*"
SRC="$(find "$WORK/x" -maxdepth 2 -name "*.xcframework" -type d | head -1)"
[ -n "$SRC" ] || { echo "No xcframework in the MapLibre zip" >&2; exit 1; }

for fw in "$SRC"/*/MapLibre.framework; do
  bin="$fw/MapLibre"
  case "$(basename "$(dirname "$fw")")" in *simulator*) platform=iossim ;; *) platform=ios ;; esac
  sdk="$(xcrun vtool -show-build "$bin" | awk '/sdk/ {print $2; exit}')"
  xcrun vtool -set-build-version "$platform" "$MIN_OS" "$sdk" -replace -output "$bin.patched" "$bin"
  mv "$bin.patched" "$bin"
  plutil -replace MinimumOSVersion -string "$MIN_OS" "$fw/Info.plist"
  codesign --remove-signature "$bin" 2>/dev/null || true # re-signed when embedded in the app
done

# dSYMs were left out, so drop their entries from the xcframework manifest.
n="$(plutil -extract AvailableLibraries raw "$SRC/Info.plist")"
for ((i = 0; i < n; i++)); do plutil -remove "AvailableLibraries.$i.DebugSymbolsPath" "$SRC/Info.plist" 2>/dev/null || true; done

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$SRC" "$OUT"
echo "MapLibre ready at ios/Vendor/MapLibre.xcframework (minimum iOS $MIN_OS)."
