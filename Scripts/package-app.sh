#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="EchoLedger"
APP_BUNDLE="dist/${APP_NAME}.app"
ZIP_PATH="dist/${APP_NAME}.zip"
VERIFY_DIR="dist/verify-extracted"
ICONSET_DIR="dist/AppIcon.iconset"

rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$ZIP_PATH.sha256" "$VERIFY_DIR" "$ICONSET_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "dist"

swift build --configuration release --product EchoLedgerApp
install -m 755 ".build/release/EchoLedgerApp" "$APP_BUNDLE/Contents/MacOS/EchoLedger"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
test -x "$APP_BUNDLE/Contents/MacOS/EchoLedger"

# Copy SwiftPM bundles, including the offline merchant artwork shared by the app and PDFs.
while IFS= read -r bundle_path; do
    cp -R "$bundle_path" "$APP_BUNDLE/Contents/Resources/"
done < <(find -L .build/release -maxdepth 2 -type d -name '*.bundle' -print)
MERCHANT_ICONS="$APP_BUNDLE/Contents/Resources/EchoLedger_EchoLedgerCore.bundle/MerchantIcons"
test -s "$MERCHANT_ICONS/catalog.json"
test -s "$MERCHANT_ICONS/spotify.png"

swift Scripts/create-app-icon.swift "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
test -s "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Compile the full-bleed modern icon; never silently ship a legacy-only Dock icon.
xcrun actool Resources/AppIcon.icon --compile "$APP_BUNDLE/Contents/Resources" \
    --app-icon AppIcon --output-partial-info-plist dist/icon-info.plist \
    --platform macosx --target-device mac --minimum-deployment-target 26.0
if [[ ! -s "$APP_BUNDLE/Contents/Resources/Assets.car" ]]; then
    echo 'error: Modern icon compiler did not produce Assets.car' >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'AppIcon'


codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'EchoLedger'
/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'EchoLedger'
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'EchoLedger'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx 'com.echoledger.app'
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx '0.4.0'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist" | grep -Fx '6'

mkdir -p "$VERIFY_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/${APP_NAME}.app"
test -s "$EXTRACTED_APP/Contents/Resources/EchoLedger_EchoLedgerCore.bundle/MerchantIcons/catalog.json"
test -x "$EXTRACTED_APP/Contents/MacOS/EchoLedger"
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$EXTRACTED_APP/Contents/Info.plist" | grep -Fx 'EchoLedger'
plutil -lint "$EXTRACTED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EXTRACTED_APP/Contents/Info.plist" | grep -Fx '0.4.0'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$EXTRACTED_APP/Contents/Info.plist" | grep -Fx '6'
codesign --verify --deep --strict "$EXTRACTED_APP"
(
    cd "$(dirname "$ZIP_PATH")"
    shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256"
    shasum -a 256 -c "$(basename "$ZIP_PATH").sha256"
)
printf 'Packaged and verified: %s\n' "$ZIP_PATH"
