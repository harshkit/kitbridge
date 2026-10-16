#!/bin/bash
# Builds PhoneBridge.app and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O main.swift -o /tmp/PhoneBridge-bin -framework AppKit
swiftc -O -D TEST main.swift -o /tmp/PhoneBridge-test 2>/dev/null && /tmp/PhoneBridge-test --test
A=build/PhoneBridge.app
rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cp PhoneBridge.icns "$A/Contents/Resources/"
mv /tmp/PhoneBridge-bin "$A/Contents/MacOS/PhoneBridge"
cat > "$A/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.harshkit.phonebridge.mac</string>
  <key>CFBundleName</key><string>PhoneBridge</string>
  <key>CFBundleExecutable</key><string>PhoneBridge</string>
  <key>CFBundleIconFile</key><string>PhoneBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>PhoneBridge talks to your phone on this Wi-Fi.</string>
  <key>NSBonjourServices</key><array><string>_phonebridge._tcp</string></array>
</dict></plist>
PLIST
# A stable local identity keeps macOS permissions across rebuilds; fall back to ad-hoc.
ID=$(security find-identity -v -p codesigning | grep -o '"[^"]*Local Signing"' | head -1 | tr -d '"' || true)
codesign --force --sign "${ID:--}" "$A"
./install-app.sh "$A"
echo "Installed. Signed with: ${ID:-ad-hoc}"
