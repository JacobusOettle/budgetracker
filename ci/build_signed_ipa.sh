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

# iCloud sync only if the profile allows it (App ID with the iCloud/CloudKit
# capability); otherwise build without it so signing doesn't fail.
CLOUD=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers:0' "$PLIST" 2>/dev/null || true)
APS=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$PLIST" 2>/dev/null || true)
if [ -n "$CLOUD" ] && [ "$CLOUD" != "*" ]; then
  ENT=Envelope/Envelope.entitlements
  if [ -z "$APS" ]; then
    # Sync still works without push; other devices' changes arrive when the
    # app opens instead of straight away. Signing with aps-environment would fail.
    echo "::warning::Profile has iCloud but no Push Notifications; building without push"
    ENT="$RUNNER_TEMP/Envelope-nopush.entitlements"
    cp Envelope/Envelope.entitlements "$ENT"
    /usr/libexec/PlistBuddy -c 'Delete :aps-environment' "$ENT"
  fi
  echo "iCloud sync on: $CLOUD (push: ${APS:-none})"
  CLOUD_ARGS=(SPAAR_CLOUDKIT_CONTAINER="$CLOUD" CODE_SIGN_ENTITLEMENTS="$ENT")
else
  echo "::warning::Provisioning profile has no iCloud container; building without iCloud sync"
  CLOUD_ARGS=(SPAAR_CLOUDKIT_CONTAINER= CODE_SIGN_ENTITLEMENTS=)
fi

if [ "$METHOD" = "development" ]; then IDENTITY="Apple Development"; else IDENTITY="Apple Distribution"; fi

xcodebuild archive \
  -project Envelope.xcodeproj \
  -scheme Envelope \
  -configuration Release \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-1}" \
  -destination 'generic/platform=iOS' \
  -archivePath build/Envelope.xcarchive \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  PROVISIONING_PROFILE_SPECIFIER="$UUID" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  "${CLOUD_ARGS[@]}" \
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
mv build/export/*.ipa "$OUT/Spaar-signed.ipa"
echo "Built $OUT/Spaar-signed.ipa"
