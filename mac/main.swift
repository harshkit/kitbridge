import AppKit
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Network
import UserNotifications

// Wire format (same as the phone): u32 big-endian length, then nonce(12) + AES-256-GCM ciphertext + tag(16).
let maxFrame = 32 * 1024 * 1024
let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PhoneBridge")
let keyFile = dir.appendingPathComponent("key.hex")

func loadKeyHex() -> String {
    if let s = try? String(contentsOf: keyFile, encoding: .utf8), s.count == 64 { return s }
    let hex = SymmetricKey(size: .bits256).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: keyFile.path, contents: Data(hex.utf8), attributes: [.posixPermissions: 0o600])
    return hex
}

// A notification is treated as an OTP only if it also mentions a code-ish word.
let otpHint = try! NSRegularExpression(pattern: "otp|code|verif|password|passcode|pin|one.?time|2fa|login|sign.?in|कोड", options: .caseInsensitive)
let otpCode = try! NSRegularExpression(pattern: "(?<![\\d₹$])(?<!\\d[.,])(\\d{3}[- ]?\\d{3}|\\d{4,8})(?!\\d|[.,]\\d)")

/// Any image (HEIC/JPEG/PNG/TIFF, HDR or not) → an upright, standard-range PNG that keeps its colour profile.
/// HDR photos (e.g. Samsung/iPhone HEIC with a gain map) otherwise become 16-bit PQ images that most apps show washed out.
func sdrPNG(_ d: Data) -> Data? {
    guard let src = CGImageSourceCreateWithData(d as CFData, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
    let side = max(p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true, // apply EXIF rotation
                                 kCGImageSourceThumbnailMaxPixelSize: side]        // full size, no downscale
    guard side > 0, let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dst, img, nil)
    return CGImageDestinationFinalize(dst) ? out as Data : nil
}

/// Tiny diagnostic log at ~/Library/Logs/PhoneBridge.log: events and app names only, never message text.
func log(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PhoneBridge.log")
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(msg)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: url) }
}

func findCode(_ s: String) -> String? {
    let r = NSRange(s.startIndex..., in: s)
    guard otpHint.firstMatch(in: s, range: r) != nil, let m = otpCode.firstMatch(in: s, range: r),
          let g = Range(m.range(at: 1), in: s) else { return nil }
    return s[g].filter(\.isNumber)
}

/// One phone connection. Holds the per-connection session key and the two message counters.
final class Session {
    let c: NWConnection
    var key: SymmetricKey?
    var tx: UInt64 = 0, rx: UInt64 = 0
    var authed = false // true only after the first valid session frame: a replayed handshake never gets here
    init(_ c: NWConnection) { self.c = c }
}

let toMac: UInt8 = 1, toPhone: UInt8 = 2
func nonce(_ dir: UInt8, _ n: UInt64) -> Data { Data([dir, 0, 0, 0]) + withUnsafeBytes(of: n.bigEndian) { Data($0) } }

final class Bridge: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let keyHex = loadKeyHex()
    lazy var key = SymmetricKey(data: Data((0..<32).map { i in
        UInt8(keyHex.dropFirst(i * 2).prefix(2), radix: 16)!
    }))
    var item: NSStatusItem!
    var listener: NWListener!
    var pending = [Session]() // strangers still inside their 5-second handshake window, oldest first
    var conn: Session? // the live phone; set only once it has sent a valid session frame
    var phone = ""
    var alertsOff = false // macOS notifications for PhoneBridge are turned off
    var seen = [String: String]()
    let pb = NSPasteboard.general
    lazy var lastChange = pb.changeCount
    var syncClipboard = UserDefaults.standard.object(forKey: "clip") as? Bool ?? true

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // "Reply" text field on message notifications that the phone says can be answered.
        let reply = UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        center.setNotificationCategories([UNNotificationCategory(identifier: "reply", actions: [reply], intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in self?.checkAlerts() }

        let p = NWParameters.tcp
        (p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        listener = try! NWListener(using: p, on: 47811) // fixed port: the phone can reconnect without discovery
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: "_phonebridge._tcp")
        listener.newConnectionHandler = { [unowned self] c in
            // At most 8 strangers at once. When full, the oldest is evicted rather than the newcomer
            // refused, so a flood can't lock the real phone out.
            if pending.count >= 8 { drop(pending[0]) }
            let s = Session(c)
            pending.append(s)
            c.start(queue: .main); read(s)
            // Strangers get 5 s to complete the handshake, then they're gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [unowned self] in if !s.authed { drop(s) } }
        }
        listener.start(queue: .main)

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [unowned self] _ in pollClipboard() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [unowned self] _ in send(["t": "ping"]) } // keeps a locked phone's link alive (it gives up after 25 s of silence)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [unowned self] _ in checkAlerts() } // notices when you turn alerts on
        refresh()
    }

    // MARK: menu

    func refresh() {
        item.button?.image = NSImage(systemSymbolName: conn == nil ? "iphone.slash" : "iphone.radiowaves.left.and.right",
                                     accessibilityDescription: "PhoneBridge")
        let m = NSMenu()
        m.addItem(withTitle: conn == nil ? "Waiting for phone…" : "Connected: \(phone)", action: nil, keyEquivalent: "")
        if alertsOff { m.addItem(withTitle: "⚠ Turn on notifications…", action: #selector(openAlertSettings), keyEquivalent: "") }
        m.addItem(.separator())
        let clip = m.addItem(withTitle: "Share clipboard with phone", action: #selector(toggleClip), keyEquivalent: "")
        clip.state = syncClipboard ? .on : .off
        m.addItem(withTitle: "Copy pairing command", action: #selector(copyPair), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        item.menu = m
    }

    func checkAlerts() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { [self] in
                let off = s.authorizationStatus != .authorized
                guard off != alertsOff || item.menu == nil else { return }
                log("macOS notifications " + (off ? "NOT allowed (status \(s.authorizationStatus.rawValue))" : "allowed"))
                alertsOff = off; refresh()
            }
        }
    }
    @objc func openAlertSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    @objc func toggleClip() { syncClipboard.toggle(); UserDefaults.standard.set(syncClipboard, forKey: "clip"); refresh() }
    @objc func copyPair() {
        // Contains the secret: marked concealed so clipboard managers (and our own sync) skip it.
        pb.clearContents()
        pb.setString("adb shell am start -n com.harshkit.phonebridge/.PairActivity --es key \(keyHex)", forType: .string)
        pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        lastChange = pb.changeCount
    }

    // MARK: network

    // Protocol v2 — see Bridge.kt for the full description. The paired key only authenticates
    // a fresh X25519 exchange; messages use a per-connection key and strict counters (no replays).
    func read(_ s: Session) {
        s.c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [unowned self] d, _, _, _ in
            guard let d, d.count == 4 else { return drop(s) }
            let n = Int(d.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard (28...(s.authed ? maxFrame : 1024)).contains(n) else { return drop(s) } // unauthenticated: tiny frames only
            s.c.receive(minimumIncompleteLength: n, maximumLength: n) { [unowned self] body, _, _, _ in
                guard let body, body.count == n, frame(s, body) else { return drop(s) }
                read(s)
            }
        }
    }

    /// Returns false to drop the connection: wrong key, tampering, replay or reordering.
    func frame(_ s: Session, _ body: Data) -> Bool {
        guard let sk = s.key else {
            // Handshake: the phone's ephemeral key, sealed with the paired key.
            guard let box = try? AES.GCM.SealedBox(combined: body),
                  let phonePub = try? AES.GCM.open(box, using: key), // wrong key = stranger
                  let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePub) else { return false }
            let eph = Curve25519.KeyAgreement.PrivateKey()
            let macPub = eph.publicKey.rawRepresentation
            guard let reply = try? AES.GCM.seal(macPub, using: key).combined,
                  let secret = try? eph.sharedSecretFromKeyAgreement(with: peer) else { return false }
            s.key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: key.withUnsafeBytes { Data($0) },
                                                   sharedInfo: Data("phonebridge-v2".utf8) + phonePub + macPub, outputByteCount: 32)
            write(s, reply)
            return true
        }
        guard body.prefix(12) == nonce(toMac, s.rx), // only the next message in order is accepted
              let box = try? AES.GCM.SealedBox(combined: body),
              let plain = try? AES.GCM.open(box, using: sk),
              let j = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return false }
        s.rx += 1
        if !s.authed { s.authed = true; pending.removeAll { $0 === s } }
        if conn !== s { conn?.c.cancel(); conn = s; refresh(); send(["t": "hello", "name": Host.current().localizedName ?? "Mac"]) }
        handle(j)
        return true
    }

    func drop(_ s: Session) {
        s.c.cancel()
        pending.removeAll { $0 === s }
        if conn === s { conn = nil; refresh() }
    }

    func write(_ s: Session, _ f: Data) {
        var len = UInt32(f.count).bigEndian
        s.c.send(content: Data(bytes: &len, count: 4) + f, completion: .contentProcessed { [unowned self] e in
            if e != nil { drop(s) }
        })
    }

    func send(_ j: [String: Any]) {
        guard let s = conn, let sk = s.key, let plain = try? JSONSerialization.data(withJSONObject: j),
              let n = try? AES.GCM.Nonce(data: nonce(toPhone, s.tx)),
              let sealed = try? AES.GCM.seal(plain, using: sk, nonce: n).combined else { return }
        s.tx += 1
        write(s, sealed)
    }

    func handle(_ j: [String: Any]) {
        switch j["t"] as? String {
        case "ping":
            send(["t": "pong", "ts": j["ts"] ?? 0])
        case "hello":
            phone = j["name"] as? String ?? "Phone"; refresh()
        case "notif":
            guard let id = j["id"] as? String else { return }
            log("notification received from phone: \(j["app"] as? String ?? "?")")
            let app = j["app"] as? String ?? "", title = j["title"] as? String ?? "", text = j["text"] as? String ?? ""
            guard seen[id] != title + text else { return } // Android re-posts the same notification often
            if seen.count > 500 { seen.removeAll() } // bounded: ids are unique per SMS
            seen[id] = title + text
            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? app : title
            content.subtitle = title.isEmpty ? "" : app
            content.body = text
            content.sound = .default
            if j["cat"] as? String == "call" { content.interruptionLevel = .timeSensitive }
            if j["reply"] as? Bool == true { content.categoryIdentifier = "reply"; content.userInfo = ["id": id] }
            content.threadIdentifier = j["pkg"] as? String ?? app // group alerts per app, like the phone does
            // The phone draws the picture: sender's photo with the app badge, or the app's icon.
            if let b = j["photo"] as? String, let d = Data(base64Encoded: b) {
                let f = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID().uuidString).png")
                if (try? d.write(to: f)) != nil, let a = try? UNNotificationAttachment(identifier: "photo", url: f) { content.attachments = [a] }
            }
            if let code = findCode(title + " " + text) {
                setClip(code)
                pb.setString("", forType: .init("org.nspasteboard.TransientType")) // clipboard managers: don't keep codes in history
                lastChange = pb.changeCount
                content.subtitle = "Code \(code) copied — press ⌘V"
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { e in
                log("showing notification from \(app)" + (e.map { " — failed: \($0.localizedDescription)" } ?? ""))
            }
        case "otp": // full SMS text, sent only so codes Android hides from listeners can still be copied
            let text = j["text"] as? String ?? ""
            guard let code = findCode(text) else { return }
            setClip(code)
            pb.setString("", forType: .init("org.nspasteboard.TransientType"))
            lastChange = pb.changeCount
            let content = UNMutableNotificationContent()
            content.title = "Code \(code) copied — press ⌘V"
            content.subtitle = j["from"] as? String ?? ""
            content.body = text
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "otp-\(code)", content: content, trigger: nil))
        case "replied":
            guard j["ok"] as? Bool != true else { return } // success is silent, like Messages on a Mac
            let content = UNMutableNotificationContent()
            content.title = "Couldn't send your reply"
            content.body = "Open the app on your phone to reply."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        case "notif_rm":
            guard let id = j["id"] as? String else { return }
            seen[id] = nil
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        case "clip":
            guard syncClipboard else { return }
            if let t = j["text"] as? String { setClip(t) }
            else if let b = j["img"] as? String, let d = Data(base64Encoded: b), let png = sdrPNG(d) {
                let item = NSPasteboardItem()
                item.setData(png, forType: .png) // what most apps paste: true colours, upright
                if let src = CGImageSourceCreateWithData(d as CFData, nil), let t = CGImageSourceGetType(src) as String?,
                   t != UTType.png.identifier { item.setData(d, forType: .init(t)) } // untouched original (keeps HDR) for apps that want it
                pb.clearContents(); pb.writeObjects([item]); lastChange = pb.changeCount
            }
        default: break
        }
    }

    // MARK: clipboard

    func setClip(_ s: String) {
        pb.clearContents(); pb.setString(s, forType: .string); lastChange = pb.changeCount
    }

    func pollClipboard() {
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard syncClipboard, conn != nil else { return }
        let types = pb.types ?? []
        // Password managers mark secrets; those never leave the Mac.
        if types.contains(where: { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"].contains($0.rawValue) }) { return }
        if let s = pb.string(forType: .string) {
            send(["t": "clip", "text": s])
        } else if let d = pb.data(forType: .png) ?? pb.data(forType: .init(UTType.jpeg.identifier))
                    ?? pb.data(forType: .init(UTType.heic.identifier)).flatMap(sdrPNG)
                    ?? pb.data(forType: .tiff).flatMap(sdrPNG), d.count < 20_000_000 {
            // The original PNG/JPEG bytes when the clipboard has them (no re-encode); otherwise a standard-range PNG.
            send(["t": "clip", "img": d.base64EncodedString()])
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let t = r as? UNTextInputNotificationResponse, let id = t.notification.request.content.userInfo["id"] as? String,
           !t.userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DispatchQueue.main.async { [self] in
                guard conn != nil else {
                    let content = UNMutableNotificationContent()
                    content.title = "Your reply wasn't sent"
                    content.body = "Your phone isn't connected right now."
                    return UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                }
                send(["t": "reply", "id": id, "text": t.userText])
            }
        }
        done()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }
}

if CommandLine.arguments.dropFirst().first == "--test" {
    assert(findCode("Your OTP is 482913. Do not share") == "482913")
    assert(findCode("G-123456 is your Google verification code") == "123456")
    assert(findCode("Use 734 821 to sign in") == "734821")
    assert(findCode("Paid ₹1500 at Swiggy") == nil)
    assert(findCode("Meeting at 1030") == nil)
    print("ok"); exit(0)
}

let app = NSApplication.shared
let bridge = Bridge()
app.delegate = bridge
app.setActivationPolicy(.accessory)
app.run()
