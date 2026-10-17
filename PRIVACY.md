# Privacy

Kitbridge has no servers, no accounts, no analytics and no telemetry. It never connects to the internet.

- **What moves:** notifications (app name, title, text and the sender's photo when the app shows one), SMS you receive (for code detection), your replies typed on the Mac, and clipboard contents (text, links, images), only between your phone and your own Mac, over your local Wi-Fi, end-to-end encrypted.
- **What's stored:** the pairing key on both devices; on the phone, your Mac's local address and port, your on/off choices, today's counts, and the last 20 calls, messages and clipboard items you can see by tapping each counter. That history stays in the app's private storage on the phone; delete items one by one or with **Clear all**, and uninstalling removes it. Nothing else is kept. The last image copied from the Mac sits in the app's private cache so it can be pasted.
- **Diagnostics:** the Mac app keeps a small log at `~/Library/Logs/Kitbridge.log` (connections and which app a notification came from, never message text). The phone writes similar one-line events to Android's system log.
- **What's not collected:** nothing is sent to Harshkit or anyone else.
- **Your controls:** turn any feature off in the phone app, or quit the Mac app from its menu. Uninstall both apps and the data goes with them.

Questions: support@harshkit.com
