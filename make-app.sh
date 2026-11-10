#!/bin/zsh
# Builds a release binary and wraps it in "Snipe-IT Label Printer.app" next to this script.
#
# Signing:
#   - With a "Developer ID Application" certificate in the keychain, the app is signed with it
#     (hardened runtime + secure timestamp), which is what other Macs need to trust it.
#   - Without one, it falls back to an ad-hoc signature that only suits this Mac.
# Notarizing (Developer ID only): store credentials once with
#   xcrun notarytool store-credentials SnipeLabelPrinter --apple-id <id> --team-id <team>
# and the app is submitted to Apple, stapled, and zipped as "Snipe-IT Label Printer.zip" for sharing.
# Set NOTARY_PROFILE to use a different keychain profile, or NOTARY_PROFILE= to skip notarizing.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP="Snipe-IT Label Printer.app"
ZIP="Snipe-IT Label Printer.zip"
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SnipeLabelPrinter "$APP/Contents/MacOS/"
# Regenerate with: swift Icon/make-icon.swift && iconutil -c icns Icon/AppIcon.iconset -o Icon/AppIcon.icns
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Snipe-IT Label Printer</string>
    <key>CFBundleIdentifier</key><string>com.buckeyerec.snipelabelprinter</string>
    <key>CFBundleExecutable</key><string>SnipeLabelPrinter</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# No sandbox, so USB access needs no entitlement; the hardened runtime doesn't restrict USB either.
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
if [[ -z "$IDENTITY" ]]; then
    codesign --force --sign - "$APP"
    echo "Built $PWD/$APP (ad-hoc signed: fine on this Mac, other Macs will warn)"
    exit 0
fi

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Signed with $IDENTITY"

PROFILE=${NOTARY_PROFILE-SnipeLabelPrinter}
if [[ -z "$PROFILE" ]]; then
    echo "Built $PWD/$APP (signed, not notarized)"
    exit 0
fi

ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "Built $PWD/$APP and $PWD/$ZIP (signed and notarized, ready to share)"
