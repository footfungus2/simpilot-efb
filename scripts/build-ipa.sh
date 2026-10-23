#!/usr/bin/env bash
# Builds an unsigned SimPilotEFB.ipa for TrollStore or signing with SideStore.
# Needs: full Xcode (not just Command Line Tools) and XcodeGen (`brew install xcodegen`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/ios"
BUILD="$IOS/build/ipa" # separate from Xcode's own build folder so it isn't wiped

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode not found. Install Xcode from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo "XcodeGen not found: brew install xcodegen" >&2; exit 1; }
[[ "${GITHUB_RUN_NUMBER:-1}" =~ ^[1-9][0-9]*$ ]] || { echo "Build number must be a positive integer" >&2; exit 1; }

[ -d "$IOS/Vendor/MapLibre.xcframework" ] || "$ROOT/scripts/vendor-maplibre.sh"

cd "$IOS"
xcodegen --quiet

rm -rf "$BUILD"
xcodebuild \
  -project SimPilotEFB.xcodeproj \
  -scheme SimPilotEFB \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  build | { command -v xcpretty >/dev/null && xcpretty || cat; }

APP="$BUILD/DerivedData/Build/Products/Release-iphoneos/SimPilotEFB.app"
[ -d "$APP" ] || { echo "Build output not found at $APP" >&2; exit 1; }

STAGE="$BUILD/ipa"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$ROOT/SimPilotEFB.ipa"
(cd "$STAGE" && zip -qry "$ROOT/SimPilotEFB.ipa" Payload)
python3 "$ROOT/scripts/check_ipa.py" "$ROOT/SimPilotEFB.ipa" --manifest "$BUILD/update.json"
echo "Built $ROOT/SimPilotEFB.ipa — install with TrollStore or sign with SideStore."
