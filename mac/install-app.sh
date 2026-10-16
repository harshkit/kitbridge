#!/bin/bash
# Installs a built Kitbridge.app to /Applications and keeps it running:
# launchd starts it at login and restarts it after a crash; Quit (clean exit) keeps it closed.
set -euo pipefail
APP="${1:?usage: install-app.sh path/to/Kitbridge.app}"
LA="$HOME/Library/LaunchAgents/com.harshkit.kitbridge.plist"
launchctl bootout "gui/$(id -u)" "$LA" 2>/dev/null || true
pkill -x Kitbridge || true
# Renamed from PhoneBridge: retire the old app and its login item (its data folder moves on first launch).
OLD="$HOME/Library/LaunchAgents/com.harshkit.phonebridge.plist"
launchctl bootout "gui/$(id -u)" "$OLD" 2>/dev/null || true
rm -f "$OLD"; pkill -x PhoneBridge || true; rm -rf /Applications/PhoneBridge.app
rm -rf /Applications/Kitbridge.app && cp -R "$APP" /Applications/
mkdir -p "$(dirname "$LA")"
cat > "$LA" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.harshkit.kitbridge</string>
  <key>ProgramArguments</key><array><string>/Applications/Kitbridge.app/Contents/MacOS/Kitbridge</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
AGENT
# Tell macOS about the app (and its icon); launchd-started apps otherwise show a blank icon on alerts.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Kitbridge.app
launchctl bootstrap "gui/$(id -u)" "$LA"
echo "Kitbridge for Mac installed and running (menu bar)."
