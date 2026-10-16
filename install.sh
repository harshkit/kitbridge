#!/bin/bash
# Kitbridge one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/harshkit/kitbridge/main/install.sh | bash
# Installs the Mac app (menu bar, starts at login), then pairs your Android phone over Wi-Fi.
set -euo pipefail
REPO=harshkit/kitbridge
[ "$(uname)" = Darwin ] || { echo "Run this on your Mac."; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "Downloading Kitbridge…"
# Apps and scripts all come from the same release and are checked against its SHA256SUMS.txt.
for f in Kitbridge-mac.zip Kitbridge.apk setup.sh install-app.sh SHA256SUMS.txt; do
  curl -fsSL -o "$T/$f" "https://github.com/$REPO/releases/latest/download/$f"
done
(cd "$T" && shasum -a 256 -c SHA256SUMS.txt) || { echo "Download check failed; nothing was installed."; exit 1; }
ditto -x -k "$T/Kitbridge-mac.zip" "$T"
bash "$T/install-app.sh" "$T/Kitbridge.app"
if ! command -v adb >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew (https://brew.sh), then run this again."; exit 1; }
  read -r -p "Kitbridge needs Android's adb tool. Install it with Homebrew now? [Y/n] " A </dev/tty
  [[ "$A" =~ ^[Nn] ]] && { echo "Run: brew install --cask android-platform-tools — then this installer again."; exit 1; }
  brew install --cask android-platform-tools
fi
bash "$T/setup.sh" "$T/Kitbridge.apk"
