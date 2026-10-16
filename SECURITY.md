# Security

## Reporting a vulnerability

Email **support@harshkit.com** with "PhoneBridge security" in the subject. Please don't open a public issue for security problems. You'll get a reply within two days.

## Design

**Pairing.** On first launch the Mac app creates a random 256-bit key (`~/Library/Application Support/PhoneBridge/key.hex`, readable only by your user). `setup.sh` hands it to the phone once over adb, through an activity protected by `android.permission.DUMP`, a permission the adb shell holds and ordinary apps cannot get. So no other app on the phone can re-pair PhoneBridge to its own key.

**Handshake (every connection).**

1. Phone → Mac: its fresh X25519 public key, sealed with AES-256-GCM under the pairing key.
2. Mac → phone: its fresh X25519 public key, sealed the same way.
3. Both derive the session key: `HKDF-SHA256(ikm = X25519 shared secret, salt = pairing key, info = "phonebridge-v2" ‖ phone key ‖ Mac key)`.

Only someone holding the pairing key can complete the handshake. The pairing key never encrypts messages, so a stolen pairing key does not decrypt recorded past sessions (forward secrecy).

**Messages.** Each frame is `length ‖ nonce ‖ AES-256-GCM(ciphertext ‖ tag)`, with `nonce = direction byte ‖ 000 ‖ 64-bit counter`. Each side accepts only the next counter in order, so captured frames can't be replayed, reordered or reflected back. Any failed check closes the connection.

**Hardening.** A connection is trusted only after its first valid encrypted message, so even a replayed handshake stays a stranger. Strangers get 5 seconds and 1 KB frames, and at most 8 can be pending at once. The pairing command copied from the Mac menu is marked as a concealed clip, so clipboard managers and PhoneBridge's own sync skip it. Clipboard items that password managers mark as secret (concealed on macOS, sensitive on Android) never leave the device they were copied on.

**Replies.** The Mac can only answer notifications the phone is sharing with it (your switches apply), and only through the app's own Reply action, the same one in your notification shade.

**Copy detector (Accessibility).** Optional and off until you switch it on. Its configuration (`res/xml/copy_watcher.xml`) receives only three event types (taps, pop-ups, window changes) with `canRetrieveWindowContent="false"`, so it can't read screen contents. It looks only at the event's own label to spot "Copy" / "Copied" / the clipboard pop-up, stores nothing, sends nothing itself, and logs only the source app's package name. Turning it off in Accessibility settings turns automatic copy back to the log-watcher fallback.

**Send to Mac.** Any app can open the share target, so it accepts only shared `content://` items (never PhoneBridge's own files), reads at most 20 MB, and asks you to tap **Send** first, which another app can't do for you.

## What PhoneBridge does not protect against

- **Someone with your unlocked Mac or phone.** The pairing key is stored in the Mac user's Application Support folder and in the app's private storage on Android.
- **What adb can do.** Setup uses wireless debugging, and anyone you pair with adb can control the phone. Turn Wireless debugging off after setup if you don't use it otherwise.
- **READ_LOGS is broad.** Android grants it as "read all device logs". PhoneBridge only starts `logcat` filtered to the `ClipboardService` tag and only looks for its own package name, but the permission itself is wider. Turn off "Send my copies to Mac" and revoke it (`adb shell pm revoke com.harshkit.phonebridge android.permission.READ_LOGS`) if you'd rather not grant it.
- **A determined flood on your Wi-Fi.** Someone on the network who keeps opening connections fast enough can delay your phone from connecting. They still can't read or send anything.
- **Who's on your Wi-Fi.** People on your network can see that a PhoneBridge connection exists, and when and how much data flows, but not the contents.

## Verifying

`mac/test/run.sh` runs a fake phone against the installed Mac app through a relay that records every byte, then checks:

- the handshake, OTP copy and clipboard both ways work;
- a replayed frame, a wrong pairing key and a frame from an old session are each rejected;
- no message text, codes or JSON field names appear anywhere in the captured traffic.
