// Pretends to be the phone (protocol v2) and attacks the Mac: proves encryption, OTP copy,
// clipboard both ways, replay rejection, wrong-key rejection. Usage: fakephone <key.hex> <port>
import Foundation
import CryptoKit
import AppKit
let a = CommandLine.arguments
let hex = try! String(contentsOfFile: a[1], encoding: .utf8)
let psk = SymmetricKey(data: Data((0..<32).map { UInt8(hex.dropFirst($0*2).prefix(2), radix: 16)! }))
let port = UInt16(a[2])!

final class Conn {
    let fd: Int32
    var key: SymmetricKey!, tx: UInt64 = 0, rx: UInt64 = 0
    var sent = [Data]()
    var hs = Data()
    init() {
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
        var tv = timeval(tv_sec: 3, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    func raw(_ f: Data) { var len = UInt32(f.count).bigEndian; let d = Data(bytes: &len, count: 4) + f; _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) } }
    func readN(_ n: Int) -> Data? { var d = Data(); var b = [UInt8](repeating: 0, count: n)
        while d.count < n { let r = read(fd, &b, n - d.count); if r <= 0 { return nil }; d.append(contentsOf: b[0..<r]) }; return d }
    func frame() -> Data? { guard let h = readN(4) else { return nil }; return readN(Int(h.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })) }
    func handshake(with k: SymmetricKey = psk) -> Bool {
        let eph = Curve25519.KeyAgreement.PrivateKey(), myPub = eph.publicKey.rawRepresentation
        hs = try! AES.GCM.seal(myPub, using: k).combined!
        raw(hs)
        guard let f = frame(), let macPub = try? AES.GCM.open(.init(combined: f), using: k) else { return false }
        let secret = try! eph.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: macPub))
        key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: k.withUnsafeBytes { Data($0) },
                                             sharedInfo: Data("phonebridge-v2".utf8) + myPub + macPub, outputByteCount: 32)
        return true
    }
    func nonce(_ dir: UInt8, _ n: UInt64) -> Data { Data([dir, 0, 0, 0]) + withUnsafeBytes(of: n.bigEndian) { Data($0) } }
    func send(_ j: [String: Any]) {
        let f = try! AES.GCM.seal(try! JSONSerialization.data(withJSONObject: j), using: key, nonce: .init(data: nonce(1, tx))).combined!
        tx += 1; sent.append(f); raw(f)
    }
    func recv() -> [String: Any]? {
        guard let f = frame() else { return nil }
        precondition(f.prefix(12) == nonce(2, rx), "Mac broke counter order"); rx += 1
        return try! JSONSerialization.jsonObject(with: AES.GCM.open(.init(combined: f), using: key)) as? [String: Any]
    }
    func closed() -> Bool { var b: UInt8 = 0; return read(fd, &b, 1) <= 0 }
}

let pb = NSPasteboard.general
let run = UUID().uuidString.prefix(8) // unique notification ids: an aborted run never poisons the next
func waitClip(_ s: String) -> Int { let t = Date()
    while pb.string(forType: .string) != s { precondition(Date().timeIntervalSince(t) < 2, "clipboard never became \(s)"); usleep(2000) }
    return Int(Date().timeIntervalSince(t) * 1000) }

// Manual mode: `fakephone <key> <port> reply` posts a message with a Reply button and waits for your answer.
if a.count > 3 && a[3] == "reply" {
    let r = Conn(); precondition(r.handshake())
    r.send(["t": "hello", "name": "Fake S26"])
    r.send(["t": "notif", "id": "reply-\(UUID().uuidString.prefix(6))", "app": "WhatsApp", "title": "PhoneBridge test",
            "text": "Reply to this from your Mac 👋", "cat": "msg", "reply": true])
    print("Posted. Reply from the Mac notification… (10 min)")
    var tv = timeval(tv_sec: 600, tv_usec: 0); setsockopt(r.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    while let m = r.recv() {
        if m["t"] as? String == "reply" { print("✓ Mac sent reply:", m["text"] ?? "", "for", m["id"] ?? ""); r.send(["t": "replied", "id": m["id"] ?? "", "ok": true]); exit(0) }
    }
    print("✗ no reply received"); exit(1)
}

// `fakephone <key> <port> img <file>`: send a photo as if copied on the phone, report what the Mac clipboard holds.
if a.count > 4 && a[3] == "img" {
    let r = Conn(); precondition(r.handshake())
    r.send(["t": "hello", "name": "Fake S26"])
    let photo = try! Data(contentsOf: URL(fileURLWithPath: a[4]))
    let before = NSPasteboard.general.changeCount
    r.send(["t": "clip", "img": photo.base64EncodedString()])
    let t = Date(); while NSPasteboard.general.changeCount == before { precondition(Date().timeIntervalSince(t) < 10, "image never arrived"); usleep(5000) }
    let ms = Int(Date().timeIntervalSince(t) * 1000)
    let types = NSPasteboard.general.types ?? []
    let png = NSPasteboard.general.data(forType: .png)!
    try! png.write(to: URL(fileURLWithPath: "/tmp/pb-pasted.png"))
    print("arrived in \(ms) ms; clipboard types:", types.map(\.rawValue), "png bytes:", png.count)
    exit(0)
}

let c = Conn(); precondition(c.handshake(), "handshake failed")
print("✓ X25519 handshake, fresh session key")
c.send(["t": "hello", "name": "Fake S26"])
c.send(["t": "notif", "id": "k1-\(run)", "app": "Messages", "title": "AX-HDFCBK", "text": "Your OTP is 482913. Do not share", "cat": "msg"])
print("✓ OTP copied to Mac clipboard in \(waitClip("482913")) ms")
c.send(["t": "clip", "text": "copied on phone ✓"])
print("✓ phone→Mac clipboard in \(waitClip("copied on phone ✓")) ms")
pb.clearContents(); pb.setString("copied on mac ✓", forType: .string)
var got: [String: Any]?
repeat { got = c.recv() } while got != nil && got?["t"] as? String != "clip"
precondition(got?["text"] as? String == "copied on mac ✓"); print("✓ Mac→phone clipboard, counter order checked")
c.send(["t": "notif_rm", "id": "k1-\(run)"])
c.raw(c.sent[2]) // replay the captured phone-clip frame
usleep(300_000); print(c.closed() ? "✓ replayed frame rejected, connection dropped" : "✗ FAIL: replay accepted")

let w = Conn(); print(!w.handshake(with: SymmetricKey(size: .bits256)) ? "✓ wrong pairing key rejected" : "✗ FAIL: wrong key accepted")

// Old session replayed on a brand-new connection: the attacker can resend frames but has no session key.
let r = Conn(); r.raw(c.sent[1]); usleep(300_000)
print(r.closed() ? "✓ old-session frame on new connection rejected" : "✗ FAIL: cross-session replay accepted")

// Replayed handshake: the Mac answers, but must still treat the peer as a stranger (1 KB cap).
// Declare a 2 KB frame and send no body: only the 1 KB pre-auth cap can close this connection.
let h = Conn(); h.raw(c.hs); _ = h.frame()
var big = UInt32(2048).bigEndian; _ = withUnsafeBytes(of: &big) { write(h.fd, $0.baseAddress, 4) }; usleep(300_000)
print(h.closed() ? "✓ replayed handshake stays untrusted (big frame refused)" : "✗ FAIL: replayed handshake lifted the limits")

// Flood: 12 idle strangers hold connections open; the real phone must still get in.
let flood = (0..<12).map { _ in Conn() }
usleep(200_000)
let f = Conn(); print(f.handshake() ? "✓ phone still connects during a connection flood" : "✗ FAIL: flood locked the phone out")
_ = flood
