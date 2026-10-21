#!/bin/bash
# Builds Kitbridge.app and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O main.swift -o /tmp/Kitbridge-bin -framework AppKit -framework SwiftUI
swiftc -O -D TEST main.swift -o /tmp/Kitbridge-test 2>/dev/null && /tmp/Kitbridge-test --test
A=build/Kitbridge.app
rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp Kitbridge.icns "$A/Contents/Resources/"
mv /tmp/Kitbridge-bin "$A/Contents/MacOS/Kitbridge"
cat > "$A/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.harshkit.phonebridge.mac</string>
  <key>CFBundleName</key><string>Kitbridge</string>
  <key>CFBundleExecutable</key><string>Kitbridge</string>
  <key>CFBundleIconFile</key><string>Kitbridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.5.2</string>
  <key>CFBundleVersion</key><string>13</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Kitbridge talks to your phone on this Wi-Fi.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Phone call</string>
    <key>CFBundleURLSchemes</key><array><string>tel</string></array>
  </dict></array>
  <key>NSBonjourServices</key><array><string>_phonebridge._tcp</string></array>
</dict></plist>
PLIST
# A stable local identity keeps macOS permissions across rebuilds; fall back to ad-hoc.
# A stable local certificate keeps macOS permissions (Bluetooth, notifications) across rebuilds; it needn't be
# "trusted" to sign. Without one, fall back to ad-hoc (each build then looks like a new app to macOS).
ID=$(security find-identity -p codesigning | grep -o '[0-9A-F]\{40\} "[^"]*Local Signing"' | head -1 | cut -d' ' -f1 || true)
codesign --force --sign "${ID:--}" "$A"
./install-app.sh "$A"
echo "Installed. Signed with: ${ID:-ad-hoc}"
