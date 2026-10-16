#!/bin/bash
# PhoneBridge one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/harshkit/phonebridge/main/install.sh | bash
# Installs the Mac app (menu bar, starts at login), then pairs your Android phone over Wi-Fi.
set -euo pipefail
REPO=harshkit/phonebridge
[ "$(uname)" = Darwin ] || { echo "Run this on your Mac."; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "Downloading PhoneBridge…"
for f in PhoneBridge-mac.zip PhoneBridge.apk; do curl -fsSL -o "$T/$f" "https://github.com/$REPO/releases/latest/download/$f"; done
for f in setup.sh mac/install-app.sh; do curl -fsSL -o "$T/$(basename $f)" "https://raw.githubusercontent.com/$REPO/main/$f"; done
ditto -x -k "$T/PhoneBridge-mac.zip" "$T"
bash "$T/install-app.sh" "$T/PhoneBridge.app"
if ! command -v adb >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew (https://brew.sh), then run this again."; exit 1; }
  brew install --cask android-platform-tools
fi
bash "$T/setup.sh" "$T/PhoneBridge.apk"
