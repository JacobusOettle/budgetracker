#!/usr/bin/env bash
# Builds an UNSIGNED Release .ipa. It must be re-signed (e.g. Sideloadly,
# AltStore) before it can be installed on an iPhone.
set -euo pipefail
OUT="${1:-build/out}"
mkdir -p "$OUT"
xcodebuild build \
  -project Spaar.xcodeproj \
  -scheme Spaar \
  -configuration Release \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/unsigned \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  SPAAR_CLOUDKIT_CONTAINER= CODE_SIGN_ENTITLEMENTS= \
  | xcpretty || exit "${PIPESTATUS[0]}"

APP="build/unsigned/Build/Products/Release-iphoneos/Spaar.app"
test -d "$APP"
# Confirm the App Intents metadata was generated, otherwise the actions will
# not show up in Shortcuts.
if [ ! -d "$APP/Metadata.appintents" ]; then
  echo "::error::Metadata.appintents missing from app bundle"; exit 1
fi
# Sideloading strips the iCloud entitlement, so this build must not use CloudKit.
if [ -n "$(/usr/libexec/PlistBuddy -c 'Print :SpaarCloudKitContainer' "$APP/Info.plist" 2>/dev/null)" ]; then
  echo "::error::Unsigned build must not enable iCloud sync"; exit 1
fi
# Show what the phone will see: name, version and icon.
PL="$APP/Info.plist"
for k in CFBundleDisplayName CFBundleName CFBundleShortVersionString CFBundleVersion; do
  echo "$k = $(/usr/libexec/PlistBuddy -c "Print :$k" "$PL")"
done
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PL")" != "Spaar" ]; then
  echo "::error::App name is not Spaar"; exit 1
fi
/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$PL" | grep -qx AppIcon \
  || { echo "::error::App icon missing from Info.plist"; exit 1; }
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry Spaar-unsigned.ipa Payload)
mv "$STAGE/Spaar-unsigned.ipa" "$OUT/"
echo "Built $OUT/Spaar-unsigned.ipa"
