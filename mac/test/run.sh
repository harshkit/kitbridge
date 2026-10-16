#!/bin/bash
# Security tests against the installed, running Mac app. Uses this Mac's own pairing key.
set -euo pipefail
cd "$(dirname "$0")"
KEY="$HOME/Library/Application Support/Kitbridge/key.hex"
swiftc -O fakephone.swift -o /tmp/pb-fakephone
# The tests write to the Mac clipboard; put yours back afterwards.
SAVED=$(mktemp); osascript -e 'the clipboard as «class utf8»' > "$SAVED" 2>/dev/null || true
WIRE=$(mktemp); trap 'rm -f "$WIRE"; kill $SNIFF 2>/dev/null; [ -s "$SAVED" ] && pbcopy < "$SAVED"; rm -f "$SAVED"' EXIT
python3 -I sniff.py 47900 47811 "$WIRE" & SNIFF=$!
sleep 1
/tmp/pb-fakephone "$KEY" 47900
echo "--- captured $(wc -c < "$WIRE" | tr -d ' ') bytes on the wire"
fail=0
for s in 482913 OTP AX-HDFCBK "copied on" Messages hello clip notif '"t"'; do
  if LC_ALL=C grep -q -a -F "$s" "$WIRE"; then echo "✗ readable on the wire: $s"; fail=1; else echo "✓ not on the wire: $s"; fi
done
exit $fail
