#!/bin/bash
# Renders every platform icon from icon.svg (the single master). Uses only macOS built-ins.
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
GRAY="/System/Library/ColorSync/Profiles/Generic Gray Profile.icc"
render() { qlmanage -t -s "$2" -o "$T" "$1" >/dev/null 2>&1; mv "$T/$(basename "$1").png" "$3"; }

# Variants of the master, cut by line:
#   square = full-bleed, no rounded corners (iOS masks the corners itself)
#   art    = devices + bridge + spark on transparent, shrunk into Android's 66% safe zone
#   bg     = just the graphite tile, square
sed -e 's/rx="228"/rx="0"/' -e '/stroke-opacity=".10"/d' icon.svg > "$T/square.svg"
sed -e '/url(#bg)"/d' -e '/url(#glowbg)"/d' -e '/sparkglow)"/d' -e '/filter="url(#blur)"/d' -e '/url(#sheen)"/d' -e '/stroke-opacity=".10"/d' \
    -e 's|<g clip-path="url(#tile)">|<g transform="translate(512 512) scale(.72) translate(-540 -420)">|' icon.svg > "$T/art.svg"
sed -e 's/rx="228"/rx="0"/' -e '/stroke-opacity=".10"/d' -e '/<!-- bridge glow/,/<!-- AI spark -->/d' -e '/href="#sparkle"/d' icon.svg > "$T/bg.svg"

render icon.svg 1024 icon-1024.png

# iOS / iPadOS: single-size 1024 asset (Xcode 14+) with light, dark and tinted appearances.
I=ios/AppIcon.appiconset; mkdir -p "$I"
render "$T/square.svg" 1024 "$T/sq.png"
sips -s format jpeg "$T/sq.png" --out "$T/sq.jpg" >/dev/null           # iOS rejects alpha: flatten
sips -s format png "$T/sq.jpg" --out "$I/AppIcon-1024.png" >/dev/null
sed 's/scale(\.72)/scale(.85)/' "$T/art.svg" > "$T/art-ios.svg"
render "$T/art-ios.svg" 1024 "$I/AppIcon-1024-dark.png"
sips --matchTo "$GRAY" "$I/AppIcon-1024-dark.png" --out "$I/AppIcon-1024-tinted.png" >/dev/null
cat > "$I/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "AppIcon-1024-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
      "filename" : "AppIcon-1024-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# macOS: Big Sur grid — 824px body centred on a 1024 canvas, then every .iconset size.
S="$T/PhoneBridge.iconset"; mkdir -p "$S"
sips -Z 824 icon-1024.png --out "$T/body.png" >/dev/null
sips -p 1024 1024 "$T/body.png" --out "$T/mac-1024.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/mac-1024.png" --out "$S/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/mac-1024.png" --out "$S/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$S" -o ../mac/PhoneBridge.icns

# Android adaptive icon (Samsung One UI masks it to its own squircle).
R=../android/app/src/main/res; mkdir -p "$R/mipmap-xxxhdpi" "$R/mipmap-anydpi-v26"
render "$T/art.svg" 432 "$R/mipmap-xxxhdpi/ic_launcher_foreground.png"
render "$T/bg.svg" 432 "$R/mipmap-xxxhdpi/ic_launcher_background.png"
cat > "$R/mipmap-anydpi-v26/ic_launcher.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
XML
echo "icons done"
