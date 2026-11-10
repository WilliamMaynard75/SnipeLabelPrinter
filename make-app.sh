#!/bin/zsh
# Builds a release binary and wraps it in "Snipe-IT Label Printer.app" next to this script.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP="Snipe-IT Label Printer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SnipeLabelPrinter "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Snipe-IT Label Printer</string>
    <key>CFBundleIdentifier</key><string>com.buckeyerec.snipelabelprinter</string>
    <key>CFBundleExecutable</key><string>SnipeLabelPrinter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signature; no sandbox, so USB access needs no entitlement.
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
