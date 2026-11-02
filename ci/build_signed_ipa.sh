#!/usr/bin/env bash
# Builds a SIGNED .ipa from secrets. Requires a paid Apple Developer account.
# Env: BUILD_CERTIFICATE_BASE64, P12_PASSWORD, BUILD_PROVISION_PROFILE_BASE64,
#      KEYCHAIN_PASSWORD, EXPORT_METHOD (development | ad-hoc; default development)
set -euo pipefail
OUT="${1:-build/out}"
METHOD="${EXPORT_METHOD:-development}"
mkdir -p "$OUT"

KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
CERT="$RUNNER_TEMP/cert.p12"
PROFILE="$RUNNER_TEMP/profile.mobileprovision"
echo -n "$BUILD_CERTIFICATE_BASE64" | base64 --decode > "$CERT"
echo -n "$BUILD_PROVISION_PROFILE_BASE64" | base64 --decode > "$PROFILE"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERT" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychain -d user -s "$KEYCHAIN"

PLIST="$RUNNER_TEMP/profile.plist"
security cms -D -i "$PROFILE" > "$PLIST"
UUID=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PLIST")
TEAM=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PLIST")
APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PLIST")
BUNDLE_ID="${APP_ID#"$TEAM".}"
if [[ "$BUNDLE_ID" == *"*"* ]]; then
  BUNDLE_ID="com.jacobusoettle.envelope"   # wildcard profile: keep project default
fi
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROFILE" "$HOME/Library/MobileDevice/Provisioning Profiles/$UUID.mobileprovision"
echo "Signing $BUNDLE_ID with team $TEAM, profile $UUID, method $METHOD"

if [ "$METHOD" = "development" ]; then IDENTITY="Apple Development"; else IDENTITY="Apple Distribution"; fi

xcodebuild archive \
  -project Envelope.xcodeproj \
  -scheme Envelope \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Envelope.xcarchive \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  PROVISIONING_PROFILE_SPECIFIER="$UUID" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  | xcpretty || exit "${PIPESTATUS[0]}"

cat > "$RUNNER_TEMP/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$METHOD</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>provisioningProfiles</key>
  <dict><key>$BUNDLE_ID</key><string>$UUID</string></dict>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath build/Envelope.xcarchive \
  -exportOptionsPlist "$RUNNER_TEMP/ExportOptions.plist" \
  -exportPath build/export
mv build/export/*.ipa "$OUT/Envelope-signed.ipa"
echo "Built $OUT/Envelope-signed.ipa"
