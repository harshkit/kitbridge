#!/bin/bash
# Installs a built PhoneBridge.app to /Applications and keeps it running:
# launchd starts it at login and restarts it after a crash; Quit (clean exit) keeps it closed.
set -euo pipefail
APP="${1:?usage: install-app.sh path/to/PhoneBridge.app}"
LA="$HOME/Library/LaunchAgents/com.harshkit.phonebridge.plist"
launchctl bootout "gui/$(id -u)" "$LA" 2>/dev/null || true
pkill -x PhoneBridge || true
rm -rf /Applications/PhoneBridge.app && cp -R "$APP" /Applications/
mkdir -p "$(dirname "$LA")"
cat > "$LA" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.harshkit.phonebridge</string>
  <key>ProgramArguments</key><array><string>/Applications/PhoneBridge.app/Contents/MacOS/PhoneBridge</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
AGENT
# Tell macOS about the app (and its icon); launchd-started apps otherwise show a blank icon on alerts.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PhoneBridge.app
launchctl bootstrap "gui/$(id -u)" "$LA"
echo "PhoneBridge for Mac installed and running (menu bar)."
