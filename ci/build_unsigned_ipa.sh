#!/usr/bin/env bash
# Builds an UNSIGNED Release .ipa. It must be re-signed (e.g. Sideloadly,
# AltStore) before it can be installed on an iPhone.
set -euo pipefail
OUT="${1:-build/out}"
mkdir -p "$OUT"
xcodebuild build \
  -project Envelope.xcodeproj \
  -scheme Envelope \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/unsigned \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  | xcpretty || exit "${PIPESTATUS[0]}"

APP="build/unsigned/Build/Products/Release-iphoneos/Envelope.app"
test -d "$APP"
# Confirm the App Intents metadata was generated, otherwise the actions will
# not show up in Shortcuts.
if [ ! -d "$APP/Metadata.appintents" ]; then
  echo "::error::Metadata.appintents missing from app bundle"; exit 1
fi
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry Envelope-unsigned.ipa Payload)
mv "$STAGE/Envelope-unsigned.ipa" "$OUT/"
echo "Built $OUT/Envelope-unsigned.ipa"
