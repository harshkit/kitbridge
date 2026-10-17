#!/bin/bash
# Phone setup over Wireless debugging (or USB): installs Kitbridge on Android, grants the
# permissions a normal app can't get, and pairs it with this Mac's key.
# Usage: ./setup.sh [Kitbridge.apk]   (no argument: builds the APK from source)
set -euo pipefail
cd "$(dirname "$0")"
P=com.harshkit.phonebridge
KEY="$HOME/Library/Application Support/Kitbridge/key.hex"
[ -f "$KEY" ] || KEY="$HOME/Library/Application Support/PhoneBridge/key.hex" # before the rename
ask() { read -r -p "$1" REPLY </dev/tty; echo "$REPLY"; }

for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$KEY" ] && break; sleep 0.5; done
[ -f "$KEY" ] || { echo "Start Kitbridge on the Mac first (it creates the pairing key)."; exit 1; }
command -v adb >/dev/null || { echo "Needs adb: brew install --cask android-platform-tools"; exit 1; }

# Find the phone; if none, pair over Wi-Fi.
dev() { adb devices | awk 'NR>1 && $2=="device" {print $1; exit}'; }
if [ -z "$(dev)" ]; then
  echo "On the phone: Settings → Developer options → Wireless debugging → Pair device with pairing code."
  ADDR=$(ask "  IP address & port shown in that popup (e.g. 192.168.1.20:37123): ")
  CODE=$(ask "  6-digit Wi-Fi pairing code: ")
  adb pair "$ADDR" "$CODE"
  IP=${ADDR%:*}
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    C=$(adb mdns services | awk -v ip="$IP" '$2 ~ /_adb-tls-connect/ && index($3, ip":")==1 {print $3; exit}')
    [ -n "$C" ] && adb connect "$C" >/dev/null && break; sleep 1
  done
fi
if [ -z "${ANDROID_SERIAL:-}" ] && [ "$(adb devices | awk 'NR>1 && $2=="device"' | wc -l)" -gt 1 ]; then
  adb devices -l; echo "More than one device: run again with ANDROID_SERIAL=<serial> ./setup.sh"; exit 1
fi
export ANDROID_SERIAL="${ANDROID_SERIAL:-$(dev)}"
[ -n "$ANDROID_SERIAL" ] || { echo "Phone not connected. Check both are on the same Wi-Fi and try again."; exit 1; }
echo "Phone: $(adb shell getprop ro.product.model) (Android $(adb shell getprop ro.build.version.release))"

APK="${1:-android/app/build/outputs/apk/release/app-release.apk}"
[ -f "$APK" ] || (cd android && ./gradlew assembleRelease -q)
if ! adb install -r "$APK" 2>/dev/null; then
  echo "The installed Kitbridge was signed differently; reinstalling (its settings reset, pairing is redone below)."
  adb uninstall "$P" >/dev/null; adb install "$APK"
fi

ok() { "$@" >/dev/null 2>&1 && echo "  ✓ ${*: -1}" || echo "  · skipped: ${*: -2}"; }
ok adb shell cmd notification allow_listener "$P/$P.BridgeService"        # notifications, calls, messages
ok adb shell pm grant "$P" android.permission.READ_LOGS                     # background clipboard (see docs)
ok adb shell appops set "$P" SYSTEM_ALERT_WINDOW allow                      # invisible clipboard reader
ok adb shell pm grant "$P" android.permission.RECEIVE_SMS                   # full SMS text incl. OTP
ok adb shell pm grant "$P" android.permission.POST_NOTIFICATIONS            # "Turn on copy to Mac" reminder
ok adb shell appops set "$P" RECEIVE_SENSITIVE_NOTIFICATIONS allow          # Android 15+: unredacted OTPs
ok adb shell appops set "$P" RUN_ANY_IN_BACKGROUND allow
ok adb shell dumpsys deviceidle whitelist +"$P"                             # no battery-saver disconnects
MAC_IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || true)
adb shell am start -n "$P/.PairActivity" --es key "$(cat "$KEY")" --es host "$MAC_IP" >/dev/null
echo "Paired."
echo "If the phone shows \"Turn on copy to Mac\", tap it and choose Allow."
echo "Done. You can switch Wireless debugging off now (some banking apps refuse to open while it's on)."
