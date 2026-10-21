import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Network
import UserNotifications

// Wire format (same as the phone): u32 big-endian length, then nonce(12) + AES-256-GCM ciphertext + tag(16).
let maxFrame = 32 * 1024 * 1024
let dir: URL = {
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let new = support.appendingPathComponent("Kitbridge"), old = support.appendingPathComponent("PhoneBridge")
    // Renamed from PhoneBridge: carry the pairing key and alert memory over, so nothing needs re-pairing.
    if !FileManager.default.fileExists(atPath: new.path), FileManager.default.fileExists(atPath: old.path) {
        try? FileManager.default.moveItem(at: old, to: new)
    }
    return new
}()
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
    let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
    // A tiny file can claim gigantic dimensions; refuse before decoding anything (64 MP / 16k px covers any phone photo).
    guard w > 0, h > 0, w * h <= 64_000_000, max(w, h) <= 16_384 else { return nil }
    let side = max(w, h)
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true, // apply EXIF rotation
                                 kCGImageSourceThumbnailMaxPixelSize: side]        // full size, no downscale
    guard side > 0, let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dst, img, nil)
    return CGImageDestinationFinalize(dst) ? out as Data : nil
}

/// Tiny diagnostic log at ~/Library/Logs/Kitbridge.log: events and app names only, never message text.
func log(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Kitbridge.log")
    let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(msg)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: url) }
}

/// This Mac's Wi-Fi/Ethernet IPv4 address (en0, then en1), for the "Connect code" shown in the menu.
func localIPv4() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    var found = [String: String]()
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        found[String(cString: p.pointee.ifa_name)] = String(cString: host)
    }
    return found["en0"] ?? found["en1"]
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

extension String { func ifEmpty(_ d: String) -> String { isEmpty ? d : self } }

// MARK: - iPhone-style call panel and device card

/// One live call as the phone describes it.
final class CallModel: ObservableObject {
    @Published var id = ""
    @Published var name = ""
    @Published var app = ""
    @Published var state = "ringing"
    @Published var photo: NSImage? = nil
    @Published var can: [String] = []
    @Published var since: Date? = nil
    @Published var pending = ""
}

/// Floating dark-glass card in the top-right corner, modelled on how a Mac shows an iPhone call.
struct CallView: View {
    @ObservedObject var m: CallModel
    var act: (String) -> Void
    @State private var now = Date()
    @State private var pulse = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if m.state == "ringing" {
                    Circle().stroke(Color.green.opacity(0.55), lineWidth: 2)
                        .frame(width: 52, height: 52).scaleEffect(pulse ? 1.25 : 1).opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                }
                Group {
                    if let p = m.photo { Image(nsImage: p).resizable().scaledToFill() }
                    else {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [Color(white: 0.62), Color(white: 0.42)], startPoint: .top, endPoint: .bottom))
                            Text(initials).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 48, height: 48).clipShape(Circle())
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(m.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 6)
            if m.state == "ringing" {
                if m.can.contains("decline") { round("phone.down.fill", .red, "Decline") { act("decline") } }
                if m.can.contains("answer") { round("phone.fill", .green, "Accept") { act("answer") } }
            } else if m.can.contains("hangup") {
                round("phone.down.fill", .red, "End") { act("hangup") }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 372)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.82)))  // near-black, like the iPhone call card on a Mac
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .onReceive(tick) { now = $0 }
        .onAppear { pulse = true }
    }

    private var initials: String {
        let parts = m.name.split(separator: " ").filter { $0.first?.isLetter == true }
        return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased().ifEmpty("#")
    }

    private var subtitle: String {
        if !m.pending.isEmpty { return m.pending }
        switch m.state {
        case "ringing": return m.app == "Phone" || m.app.isEmpty ? "Incoming call · mobile" : "\(m.app) audio · incoming"
        case "dialing": return "Calling…"
        default:
            guard let s = m.since else { return m.app == "Phone" ? "On call" : "On \(m.app) call" }
            let t = max(0, Int(now.timeIntervalSince(s)))
            return String(format: "%d:%02d", t / 60, t % 60)
        }
    }

    private func round(_ symbol: String, _ color: Color, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 42, height: 42).background(Circle().fill(color.gradient))
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// The phone shown as a connected device at the top of the menu, like AirPods or an iPhone.
struct DeviceCard: View {
    let name: String, connected: Bool, battery: Int?, charging: Bool, onCall: Bool
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(connected ? (onCall ? Color.green : Color.accentColor) : Color.gray.opacity(0.5)).frame(width: 34, height: 34)
                Image(systemName: onCall ? "phone.fill" : "smartphone").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(connected ? name : "Phone not connected").font(.system(size: 13, weight: .semibold))
                Text(onCall ? "On a call" : connected ? "Connected · Kitbridge" : "Same Wi-Fi needed")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if connected, let b = battery {
                HStack(spacing: 3) {
                    if charging { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.green) }
                    Text("\(b)%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    Image(systemName: b > 87 ? "battery.100percent" : b > 62 ? "battery.75percent" : b > 37 ? "battery.50percent" : b > 12 ? "battery.25percent" : "battery.0percent")
                        .foregroundStyle(b <= 12 && !charging ? .red : .secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8).frame(width: 300)
    }
}

final class Bridge: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let keyHex = loadKeyHex()
    lazy var key = SymmetricKey(data: Data((0..<32).map { i in
        UInt8(keyHex.dropFirst(i * 2).prefix(2), radix: 16)!
    }))
    var item: NSStatusItem!
    var listener: NWListener!
    var finder: NWListener? // answers the phone's "where's my Mac?" broadcast
    var pending = [Session]() // strangers still inside their 5-second handshake window, oldest first
    var conn: Session? // the live phone; set only once it has sent a valid session frame
    var phone = ""
    var battery: Int? = nil, charging = false
    let call = CallModel()
    var callPanel: NSPanel?
    var ring: NSSound?
    var alertsOff = false // macOS notifications for Kitbridge are turned off
    // Alerts already shown, kept across restarts so a reconnect's catch-up never re-shows ones you cleared.
    // Stored as id → "HMAC-SHA256(pairing key, content)|time": keyed fingerprints, never text, and not guessable without the key.
    let seenFile = dir.appendingPathComponent("seen.json")
    lazy var seen: [String: String] = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: seenFile))) ?? [:]
    func fingerprint(_ s: String) -> String { HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key).map { String(format: "%02x", $0) }.joined() }
    func remember(_ id: String, _ content: String?) {
        seen[id] = content.map { "\(fingerprint($0))|\(Int(Date().timeIntervalSince1970))" }
        if seen.count > 1000 { // keep the newest 500
            let keep = seen.sorted { ($0.value.split(separator: "|").last ?? "") > ($1.value.split(separator: "|").last ?? "") }.prefix(500)
            seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        try? JSONEncoder().encode(seen).write(to: seenFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seenFile.path) // owner-only, like key.hex
    }
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

        // The phone broadcasts "KB?1" when it can't reach its remembered address; we answer "KB!1".
        // Bonjour stays on too, but Samsung phones often filter its multicast. Pairing is still
        // checked by the encrypted handshake, so answering reveals nothing.
        finder = try? NWListener(using: .udp, on: 47811)
        finder?.newConnectionHandler = { [unowned self] c in
            c.start(queue: .main)
            c.receiveMessage { [unowned self] d, _, _, _ in
                // "KB?1" + 16-byte challenge → "KB!1" + HMAC(pairing key, "kb-discover" + challenge), first 16 bytes.
                // Only the paired Mac can answer correctly, so nobody else on the Wi-Fi can pose as it.
                guard let d, d.count == 20, d.starts(with: Data("KB?1".utf8)) else {
                    log("discovery: ignored \(d?.count ?? 0)-byte message"); return c.cancel()
                }
                let proof = Data(HMAC<SHA256>.authenticationCode(for: Data("kb-discover".utf8) + d.dropFirst(4), using: key)).prefix(16)
                log("discovery request from \(c.endpoint)")
                c.send(content: Data("KB!1".utf8) + proof, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        finder?.start(queue: .main)

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [unowned self] _ in pollClipboard() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [unowned self] _ in send(["t": "ping"]) } // keeps a locked phone's link alive (it gives up after 25 s of silence)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [unowned self] _ in checkAlerts() } // notices when you turn alerts on
        refresh()
    }

    // MARK: menu

    func refresh() {
        let onCall = callPanel != nil
        item.button?.image = NSImage(systemSymbolName: onCall ? "phone.fill" : conn == nil ? "iphone.slash" : "iphone.radiowaves.left.and.right",
                                     accessibilityDescription: "Kitbridge")
        item.button?.contentTintColor = onCall ? .systemGreen : nil
        let m = NSMenu()
        let card = NSMenuItem()
        let host = NSHostingView(rootView: DeviceCard(name: phone.isEmpty ? "Phone" : phone, connected: conn != nil,
                                                      battery: battery, charging: charging, onCall: callPanel != nil))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        card.view = host
        m.addItem(card)
        m.addItem(.separator())
        let dial = m.addItem(withTitle: "Call a Number…", action: #selector(askNumber), keyEquivalent: "")
        dial.image = NSImage(systemSymbolName: "phone", accessibilityDescription: nil)
        dial.isEnabled = conn != nil
        let def = m.addItem(withTitle: "Use Kitbridge for Phone Links", action: #selector(claimTel), keyEquivalent: "")
        def.state = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "tel:1")!)?.lastPathComponent == "Kitbridge.app" ? .on : .off
        m.addItem(.separator())
        if let ip = localIPv4() {
            let code = m.addItem(withTitle: "Connect code: \(ip.split(separator: ".").last ?? "")   (\(ip))", action: nil, keyEquivalent: "")
            code.toolTip = "If your phone can't find this Mac, open Kitbridge on the phone → Enter Mac code."
        }
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

    // MARK: calls

    func showCall(_ j: [String: Any]) {
        guard let id = j["id"] as? String else { return }
        let state = j["state"] as? String ?? "ringing"
        if call.id != id { call.pending = "" }
        call.id = id; call.state = state
        call.name = j["name"] as? String ?? "Unknown"; call.app = j["app"] as? String ?? "Phone"
        call.can = j["can"] as? [String] ?? []
        if let b = j["photo"] as? String, let d = Data(base64Encoded: b) { call.photo = NSImage(data: d) }
        if state == "active" {
            call.pending = ""
            if let ms = j["since"] as? Double, ms > 0 { call.since = Date(timeIntervalSince1970: ms / 1000) }
            else if call.since == nil { call.since = Date() }
        } else { call.since = nil }
        log("call \(state) from \(call.app); shape \((j["shape"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? "-")")
        if state == "ringing" { startRing() } else { stopRing() }
        if callPanel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 80), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .statusBar; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = true
            let v = NSHostingView(rootView: CallView(m: call) { [unowned self] a in callAct(a) })
            p.contentView = v
            let size = v.fittingSize
            if let f = NSScreen.main?.visibleFrame {
                p.setFrame(NSRect(x: f.maxX - size.width - 14, y: f.maxY - size.height - 10, width: size.width, height: size.height), display: true)
            }
            p.alphaValue = 0; p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
            callPanel = p; refresh()
        }
    }

    func callAct(_ a: String) {
        stopRing()
        call.pending = a == "answer" ? "Answering on your phone…" : a == "decline" ? "Declining…" : "Ending…"
        send(["t": "callact", "id": call.id, "act": a])
        if a != "answer" { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.closeCall() } }
    }

    func closeCall() {
        stopRing()
        guard let p = callPanel else { return }
        callPanel = nil; call.id = ""; refresh()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    func startRing() {
        guard ring == nil else { return }
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Opening.m4r")
        ring = NSSound(contentsOf: url, byReference: true) ?? NSSound(named: "Glass")
        ring?.loops = true; ring?.play()
    }
    func stopRing() { ring?.stop(); ring = nil }

    func notice(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Dial on the phone, always after you confirm on the Mac (phone links can come from any app or web page).
    func confirmDial(_ raw: String) {
        // Only plain phone numbers: no * or #, which would make a link a USSD/MMI code (e.g. call forwarding).
        var number = raw.hasPrefix("tel:") ? String(raw.dropFirst(4)) : raw
        number = (number.removingPercentEncoding ?? number).components(separatedBy: CharacterSet(charactersIn: ";?")).first ?? ""
        guard number.range(of: #"^\+?[0-9 ().\-]{3,32}$"#, options: .regularExpression) != nil else {
            return notice("That link isn't a phone number", "Kitbridge only calls plain numbers, not codes with * or #.")
        }
        guard conn != nil else { return notice("Your phone isn't connected", "Kitbridge needs your phone on the same Wi-Fi.") }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Call \(number)?"
        a.informativeText = "Your phone (\(phone)) will place the call. Use your phone or its earbuds to talk."
        a.addButton(withTitle: "Call"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { send(["t": "dial", "number": number]) }
    }

    @objc func askNumber() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = "Call a Number"; a.informativeText = "Your phone will dial it."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); f.placeholderString = "+91 98765 43210"
        a.accessoryView = f; a.addButton(withTitle: "Call"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty {
            let n = f.stringValue.trimmingCharacters(in: .whitespaces)
            if n.range(of: #"^\+?[0-9 ().\-]{3,32}$"#, options: .regularExpression) != nil, conn != nil { send(["t": "dial", "number": n]) }
        }
    }

    /// Makes Kitbridge open tel: links (macOS asks you to confirm).
    @objc func claimTel() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "tel") { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        urls.filter { $0.scheme == "tel" }.forEach { confirmDial($0.absoluteString) }
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
        case "battery":
            battery = j["level"] as? Int; charging = j["charging"] as? Bool ?? false; refresh()
        case "call":
            showCall(j)
        case "callacted":
            if j["ok"] as? Bool != true, (j["id"] as? String) == call.id { call.pending = "Couldn't reach the phone's call buttons" }
        case "dialed":
            if j["ok"] as? Bool != true { notice("Couldn't start the call", "Check that Kitbridge is set up on your phone.") }
        case "hello":
            phone = j["name"] as? String ?? "Phone"; refresh()
        case "notif":
            guard let id = j["id"] as? String else { return }
            log("notification received from phone: \(j["app"] as? String ?? "?")")
            let app = j["app"] as? String ?? "", title = j["title"] as? String ?? "", text = j["text"] as? String ?? ""
            // Android re-posts the same notification often, and every reconnect re-sends recent ones.
            guard seen[id]?.hasPrefix(fingerprint(title + text)) != true else { return }
            remember(id, title + text)
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
                else { try? FileManager.default.removeItem(at: f) }
            }
            if let code = findCode(title + " " + text) {
                setClip(code)
                pb.setString("", forType: .init("org.nspasteboard.TransientType")) // clipboard managers: don't keep codes in history
                lastChange = pb.changeCount
                content.subtitle = "Code \(code) copied — press ⌘V"
            }
            let tmp = content.attachments.first?.url
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { e in
                if e != nil, let tmp { try? FileManager.default.removeItem(at: tmp) } // on success macOS has moved it
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
            if id == call.id { closeCall() }
            // Keep the fingerprint: apps often remove and re-post the same notification when refreshing it.
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        case "clip":
            log("clipboard from phone: " + (j["text"] != nil ? "text" : "image"))
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
