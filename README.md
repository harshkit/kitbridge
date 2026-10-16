<p align="center"><img src="assets/icon.png" width="128" alt="Kitbridge app icon: a silver and a blue-purple link interlocked"></p>

<h1 align="center">Kitbridge</h1>

<p align="center"><sub>by <a href="https://www.harshkit.com/">Harshkit</a></sub></p>

<p align="center"><b>Apple-style continuity between your Android phone and your Mac.</b><br>
Calls, messages and notifications on your Mac. OTP codes copied for you. One clipboard across both.<br>
Free, open source, end-to-end encrypted, and it never touches the internet.</p>

<p align="center">
  <a href="https://github.com/harshkit/kitbridge/releases/latest"><img src="https://img.shields.io/github/v/release/harshkit/kitbridge?label=download&color=5e5ce6" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/Android-13%2B-3ddc84?logo=android&logoColor=white" alt="Android 13+">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/encryption-X25519%20%2B%20AES--256--GCM-2ea44f" alt="X25519 + AES-256-GCM">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center"><a href="https://www.harshkit.com/apps/kitbridge/">Website</a> · <a href="#install-one-line">Install</a> · <a href="#features">Features</a> · <a href="#how-it-works">How it works</a> · <a href="SECURITY.md">Security</a> · <a href="PRIVACY.md">Privacy</a></p>

---

iPhone owners get Continuity for free: texts on the Mac, codes that paste themselves, copy on one device and paste on the other. If your phone is a Samsung, Pixel or any other Android, you don't. **Kitbridge closes that gap**: a small Android app and a Mac menu-bar app that talk directly to each other over your Wi-Fi, with no cloud, no account and no subscription.

<p align="center"><img src="assets/android-app.png" width="300" alt="Kitbridge on a Samsung Galaxy S26 Ultra: connected to a MacBook Air over an encrypted link at 17 ms, with today's counts and sync switches"></p>

## Install (one line)

On your Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/harshkit/kitbridge/main/install.sh | bash
```

It installs the Mac app (menu bar, starts at login), then pairs your phone over Wi-Fi. For automatic copy from the phone, finally switch on **Settings → Accessibility → Installed apps → Kitbridge: copy to Mac** (if Samsung greys it out: **Settings → Apps → Kitbridge → ⋮ → Allow restricted settings**). On the phone you'll need **Settings → Developer options → Wireless debugging → Pair device with pairing code** once. The installer asks for the code shown there. After that, there's nothing to run: both sides connect on their own whenever they're on the same Wi-Fi.

**Requirements:** a Mac on macOS 14 or later, an Android phone on Android 13 or later, both on the same Wi-Fi network. Tested on a Samsung Galaxy S26 Ultra (Android 17) with a MacBook Air.

## Features

- 📞 **Calls on your Mac.** Incoming calls appear as time-sensitive Mac alerts, showing the caller the way your phone does.
- 💬 **Messages and SMS.** WhatsApp, Messages, Telegram and everything else your phone shows, as native macOS notifications with the sender's photo and the app's badge. Swipe one away on the phone and it disappears from the Mac.
- ↩️ **Reply from your Mac.** Hover a WhatsApp, SMS or Telegram alert, click **Reply**, type, send. The phone answers through the app's own reply button, so it's a real reply in the chat.
- 🔐 **OTP auto-copy.** When a verification code arrives, it's already on your Mac's clipboard: just press **⌘V**. Works with bank SMS, Google, and "123 456"-style codes; ignores amounts like "₹1500".
- 📋 **One clipboard.** Copy text, links or images on either device and paste on the other. HDR photos from your phone paste in true colour, upright and full size. Passwords copied in password managers (on either side) are never sent.
- 📤 **Send to Mac.** Share any photo or text to **Send to Mac**, or tap the **Send to Mac** Quick Settings tile to send whatever you just copied.
- 🕘 **History.** Tap Calls, Messages or Clipboard in the phone app to see the last 20, copy a past clip again, delete one, or clear all. Kept only on the phone.
- 🎛️ **You're in control.** Turn each piece on or off from the phone: calls, messages, other apps, sending copies, receiving copies.
- ⚡ **Fast.** One persistent connection with no batching: in tests an OTP lands on the Mac clipboard in about 20 ms, and a round trip on home Wi-Fi measured 17 ms.
- 🔁 **Seamless.** The Mac app starts at login and relaunches itself if it ever crashes; the Android side runs as a system-managed notification listener, keeps its link while the phone is locked, reconnects in milliseconds to a known Mac and, after any drop, re-sends what you missed.

## How it works

```
 Android (Kotlin, no libraries)                     Mac (Swift, menu bar)
 ┌──────────────────────────────┐   same Wi-Fi    ┌──────────────────────────────┐
 │ NotificationListenerService  │  TCP :47811     │ Bonjour  _phonebridge._tcp   │
 │ SMS receiver (full OTP text) │ ◀─────────────▶ │ macOS notifications          │
 │ Clipboard watcher            │  X25519 + AES   │ OTP → clipboard              │
 │ Toggles, status              │  -256-GCM       │ Clipboard watcher            │
 └──────────────────────────────┘                 └──────────────────────────────┘
```

Android deliberately makes a few of these things hard for apps. Here's what Kitbridge does about each, all with your consent over `adb` during setup:

| Android limit | What Kitbridge does |
|---|---|
| Apps can't read other apps' notifications | Uses the official **notification access** permission, granted by setup (sideloaded apps can't flip it on themselves on Android 13+). |
| Android 10+ blocks reading the clipboard in the background | A narrow **Accessibility** detector notices when you copy (a "Copy" tap or the system's "Copied" pop-up; it checks event text only for those words and never stores, logs or sends it), then Kitbridge shows an invisible window for a few milliseconds to gain focus, reads the clip and closes. You switch it on once and it survives reboots and updates. Without it, a fallback watches the system's `Denying clipboard access` log line (READ_LOGS, the technique KDE Connect uses), which Android 13+ asks you to re-allow after each restart. |
| Android 15+ hides OTP text from notification listeners | Kitbridge reads the **SMS itself** (RECEIVE_SMS), so the full code reaches your Mac. |
| Samsung filters Wi-Fi multicast, hiding Bonjour | Takes a **multicast lock** during discovery, and remembers the Mac's address so it rarely needs discovery at all. |
| Battery savers drop background connections | Setup adds Kitbridge to the battery-optimisation allowlist; the Mac pings every 10 s and the phone re-sends anything missed after a reconnect. |
| Log access is granted only on screen (Android 13+) | Not needed when the Accessibility detector is on. Otherwise Kitbridge shows a "Turn on copy to Mac" reminder after a reboot or update. The Send to Mac tile and share option never need either. |
| HDR photos look washed out on a Mac clipboard | The Mac converts them with Apple's ImageIO to a standard-range PNG (keeping the colour profile and rotation) and also keeps the original. |

**Permissions the Android app uses:** notification access, RECEIVE_SMS, the optional **Accessibility copy detector** (Android passes it tap labels and pop-up/notification text; it checks only for Copy/Copied and keeps nothing), READ_LOGS (fallback copy detection, granted over adb), SYSTEM_ALERT_WINDOW (lets the invisible clipboard reader open from the background), POST_NOTIFICATIONS (the setup reminder), QUERY_ALL_PACKAGES (to show app names on the Mac), INTERNET and Wi-Fi state (local network only).

## Security and privacy

- **End-to-end encrypted, no server.** Your phone talks only to your Mac. Every connection runs a fresh **X25519** key exchange, authenticated by a 256-bit key that's created on your Mac and handed to your phone once over adb. Messages are sealed with **AES-256-GCM** and carry strict sequence numbers, so nothing on your network can read, alter or replay them. Old sessions stay sealed even if the pairing key leaks later (forward secrecy).
- **Locked pairing.** Only `adb` (your computer, with your consent) can pair the app; other apps on the phone can't re-pair it to themselves.
- **No telemetry, no account, no internet.** See [PRIVACY.md](PRIVACY.md).
- **Tested against attacks.** `mac/test/run.sh` runs a fake phone against the real Mac app: it checks the handshake, OTP copy and clipboard, then tries a replayed message, a wrong key and an old-session message (all rejected), and captures the traffic to prove no content crosses the wire readable.

What it doesn't protect against, and the exact design, is in [SECURITY.md](SECURITY.md).

## Build from source

```bash
git clone https://github.com/harshkit/kitbridge && cd kitbridge
./mac/build.sh          # builds and installs the Mac app (needs Xcode Command Line Tools)
./setup.sh              # builds the Android app and pairs your phone (needs JDK 17 + Android SDK)
./mac/test/run.sh       # security tests against the running Mac app
```

Install the Android build tools with `brew install openjdk@17 && brew install --cask android-commandlinetools android-platform-tools`, then set `ANDROID_HOME` to the SDK folder.

## Project layout

| Path | What |
|---|---|
| `android/app/src/main/java/com/harshkit/kitbridge/Bridge.kt` | Link, encryption, notification listener, SMS, clipboard |
| `android/app/src/main/java/com/harshkit/kitbridge/Ui.kt` | The phone app's screen |
| `mac/main.swift` | The whole Mac app |
| `install.sh`, `setup.sh`, `mac/install-app.sh` | Installer, phone setup, Mac install |
| `mac/test/` | Fake-phone attack tests and wire sniffer |
| `icon/` | Icon master (`icon.svg`) and the script that renders every platform size |

## Roadmap

- Drop files between phone and Mac (AirDrop-style)
- Answer or decline calls from the Mac
- One-click hotspot from the Mac menu bar

Ideas and bug reports are welcome in [Issues](https://github.com/harshkit/kitbridge/issues).

## License

[MIT](LICENSE) © 2026 Harsh Sharma · [Harshkit](https://www.harshkit.com/). Not affiliated with Apple, Google or Samsung.
