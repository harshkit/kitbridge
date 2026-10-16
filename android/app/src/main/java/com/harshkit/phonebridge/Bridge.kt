package com.harshkit.phonebridge

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.Settings
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.thread

const val SERVICE = "_phonebridge._tcp"
const val MAX_FRAME = 32 * 1024 * 1024

/** One persistent encrypted TCP link to the Mac. Frame = u32 length + nonce(12) + AES-256-GCM(ciphertext+tag). */
object Link {
    lateinit var ctx: Context
    @Volatile var status = "Starting…"
        set(v) { if (v != field) android.util.Log.i("PhoneBridge", v); field = v }
    @Volatile private var out: DataOutputStream? = null
    @Volatile private var sock: Socket? = null
    @Volatile var lastClip: String? = null
    @Volatile var clipMime = "image/png" // echo guard: what the Mac last sent us
    private val sendQ = Executors.newSingleThreadExecutor()
    private val rnd = SecureRandom()
    private var started = false
    private val main = Handler(Looper.getMainLooper())

    @Volatile var rttMs = -1L
    @Volatile var macName = ""
    val connected get() = out != null

    val prefs get() = ctx.getSharedPreferences("bridge", 0)
    private fun today() = SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())
    /** Today's count per ring: calls, msgs, apps, clip. Resets at midnight. */
    fun count(k: String) = if (prefs.getString("day", "") == today()) prefs.getInt("n_$k", 0) else 0
    @Synchronized fun bump(k: String) {
        val e = prefs.edit()
        if (prefs.getString("day", "") != today()) { e.putString("day", today()); listOf("calls", "msgs", "apps", "clip").forEach { e.remove("n_$it") } }
        e.putInt("n_$k", count(k) + 1).apply()
    }
    fun on(k: String) = prefs.getBoolean("master", true) && prefs.getBoolean(k, true)
    private fun key() = prefs.getString("key", null)?.let { SecretKeySpec(hex(it), "AES") }

    fun start(c: Context) {
        synchronized(this) { if (started) return; started = true }
        ctx = c.applicationContext
        // Round-trip ping: feeds the latency tile and spots a dead link sooner.
        Executors.newSingleThreadScheduledExecutor().scheduleWithFixedDelay(
            { if (connected) send(JSONObject().put("t", "ping").put("ts", System.nanoTime())) }, 1, 10, TimeUnit.SECONDS)
        thread(name = "link") {
            while (true) {
                out = null; session = null // never look connected while a new attempt is under way
                try {
                    if (key() == null) { status = "Not paired — run setup.sh on the Mac"; Thread.sleep(3000); continue }
                    if (!prefs.getBoolean("master", true)) { status = "Bridge off"; Thread.sleep(1000); continue }
                    val h = prefs.getString("host", null)
                    // Cached address first: reconnects in milliseconds instead of waiting on mDNS.
                    if (h != null) runCatching { connect(h, prefs.getInt("port", 0)) }
                    status = "Looking for Mac…"
                    val (dh, dp) = discover()
                    connect(dh, dp)
                } catch (e: Exception) {
                    status = "Looking for Mac… (${e.message})"
                }
                out = null; session = null; rttMs = -1
                Thread.sleep(1500)
            }
        }
    }

    fun reconnect() { runCatching { sock?.close() } }

    private fun discover(): Pair<String, Int> {
        val nsd = ctx.getSystemService(NsdManager::class.java)
        val latch = CountDownLatch(1)
        var res: Pair<String, Int>? = null
        val l = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(s: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                nsd.resolveService(s, object : NsdManager.ResolveListener {
                    override fun onServiceResolved(r: NsdServiceInfo) {
                        // Prefer IPv4: an IPv6 link-local answer often can't be dialled.
                        @Suppress("DEPRECATION")
                        val addrs = if (Build.VERSION.SDK_INT >= 34) r.hostAddresses else listOfNotNull(r.host)
                        val a = (addrs.firstOrNull { it is java.net.Inet4Address } ?: addrs.firstOrNull())?.hostAddress ?: return
                        res = a to r.port; latch.countDown()
                    }
                    override fun onResolveFailed(r: NsdServiceInfo, e: Int) {}
                })
            }
            override fun onStartDiscoveryFailed(t: String, e: Int) = latch.countDown()
            override fun onStopDiscoveryFailed(t: String, e: Int) {}
            override fun onDiscoveryStarted(t: String) {}
            override fun onDiscoveryStopped(t: String) {}
            override fun onServiceLost(s: NsdServiceInfo) {}
        }
        // Samsung filters Wi-Fi multicast unless someone holds this lock, which hides mDNS answers.
        val lock = ctx.getSystemService(android.net.wifi.WifiManager::class.java).createMulticastLock("phonebridge").apply { acquire() }
        nsd.discoverServices(SERVICE, NsdManager.PROTOCOL_DNS_SD, l)
        try {
            latch.await(15, TimeUnit.SECONDS)
        } finally {
            runCatching { nsd.stopServiceDiscovery(l) }
            lock.release()
        }
        return res ?: throw IOException("Mac not found on this Wi-Fi")
    }

    /*
     * Protocol v2. The paired key (PSK) never encrypts messages; it only authenticates a fresh
     * X25519 exchange on every connection:
     *   phone -> mac : PSK-sealed(phone ephemeral public key)
     *   mac -> phone : PSK-sealed(mac ephemeral public key)
     *   session key  = HKDF-SHA256(ikm = X25519 secret, salt = PSK, info = "phonebridge-v2" | phonePub | macPub)
     * Session frames use nonce = direction(1) | 000 | counter(8): each side accepts only the next counter,
     * so a captured frame can't be replayed, and old sessions stay sealed even if the PSK leaks later.
     */
    @Volatile private var session: SecretKeySpec? = null
    private var tx = 0L // touched only on sendQ
    private const val TO_MAC: Byte = 1
    private const val TO_PHONE: Byte = 2
    private val X25519_SPKI = hex("302a300506032b656e032100") // X.509 header before a raw 32-byte X25519 key

    private fun connect(host: String, port: Int) {
        Socket().use { s ->
            s.tcpNoDelay = true
            s.keepAlive = true
            s.connect(InetSocketAddress(host, port), 2000)
            s.soTimeout = 25_000 // we ping every 10 s and the Mac answers; 25 s of silence means the link is dead
            sock = s
            val i = DataInputStream(BufferedInputStream(s.getInputStream()))
            val o = DataOutputStream(BufferedOutputStream(s.getOutputStream()))

            val kpg = java.security.KeyPairGenerator.getInstance("XDH") // Conscrypt: X25519 is the only, default curve
            val kp = kpg.generateKeyPair()
            val myPub = kp.public.encoded.takeLast(32).toByteArray()
            val hn = ByteArray(12).also(rnd::nextBytes)
            writeFrame(o, hn + aes(Cipher.ENCRYPT_MODE, key()!!, hn, myPub))
            val f = readFrame(i, max = 1024) // handshake replies are tiny; a spoofed "Mac" can't make us allocate 32 MB
            val macPub = aes(Cipher.DECRYPT_MODE, key()!!, f.copyOf(12), f.copyOfRange(12, f.size)) // throws if not our Mac
            if (macPub.size != 32) throw IOException("bad handshake")
            val ka = javax.crypto.KeyAgreement.getInstance("XDH")
            ka.init(kp.private)
            ka.doPhase(java.security.KeyFactory.getInstance("XDH").generatePublic(java.security.spec.X509EncodedKeySpec(X25519_SPKI + macPub)), true)
            val sk = hkdf(salt = key()!!.encoded, ikm = ka.generateSecret(), info = "phonebridge-v2".toByteArray() + myPub + macPub)
            var rx = 0L

            sendQ.submit { tx = 0; session = SecretKeySpec(sk, "AES"); out = o }.get()
            send(JSONObject().put("t", "hello").put("name", Build.MODEL))
            thread { BridgeService.instance?.resync() } // catch up on anything posted while disconnected
            prefs.edit().putString("host", host).putInt("port", port).apply()
            status = "Connected to Mac ($host)"
            while (true) {
                val fr = readFrame(i)
                if (!fr.copyOf(12).contentEquals(nonce(TO_PHONE, rx))) throw IOException("replayed or out-of-order frame")
                rx++
                handle(JSONObject(String(aes(Cipher.DECRYPT_MODE, SecretKeySpec(sk, "AES"), fr.copyOf(12), fr.copyOfRange(12, fr.size)), Charsets.UTF_8)))
            }
        }
    }

    fun send(j: JSONObject) = sendQ.execute {
        val o = out ?: return@execute
        val k = session ?: return@execute
        try {
            val n = nonce(TO_MAC, tx++)
            writeFrame(o, n + aes(Cipher.ENCRYPT_MODE, k, n, j.toString().toByteArray()))
        } catch (e: Exception) { reconnect() }
    }

    private fun nonce(dir: Byte, counter: Long) =
        ByteArray(12).also { it[0] = dir; java.nio.ByteBuffer.wrap(it, 4, 8).putLong(counter) }

    /** AES-256-GCM; output/input is ciphertext+tag. Decrypt throws on wrong key or any tampering. */
    private fun aes(mode: Int, k: SecretKeySpec, n: ByteArray, data: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(mode, k, GCMParameterSpec(128, n))
        return c.doFinal(data)
    }

    private fun writeFrame(o: DataOutputStream, f: ByteArray) { o.writeInt(f.size); o.write(f); o.flush() }

    private fun readFrame(i: DataInputStream, max: Int = MAX_FRAME): ByteArray {
        val n = i.readInt()
        if (n !in 28..max) throw IOException("bad frame")
        return ByteArray(n).also(i::readFully)
    }

    /** RFC 5869 HKDF-SHA256, one 32-byte block (what CryptoKit's hkdfDerivedSymmetricKey produces). */
    private fun hkdf(salt: ByteArray, ikm: ByteArray, info: ByteArray): ByteArray {
        fun hmac(k: ByteArray, d: ByteArray) = javax.crypto.Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(k, "HmacSHA256")); doFinal(d) }
        return hmac(hmac(salt, ikm), info + byteArrayOf(1))
    }

    private fun handle(j: JSONObject) {
        when (j.optString("t")) {
            "pong" -> { rttMs = (System.nanoTime() - j.getLong("ts")) / 1_000_000; return }
            "hello" -> { macName = j.optString("name"); return }
            "reply" -> {
                val ok = Replies.send(ctx, j.getString("id"), j.getString("text"))
                send(JSONObject().put("t", "replied").put("id", j.getString("id")).put("ok", ok))
                return
            }
        }
        if (j.optString("t") != "clip" || !on("clip_in")) return
        bump("clip")
        val cm = ctx.getSystemService(ClipboardManager::class.java)
        val clip = if (j.has("text")) {
            lastClip = j.getString("text")
            ClipData.newPlainText("Mac", lastClip)
        } else {
            val bytes = Base64.decode(j.getString("img"), Base64.DEFAULT)
            // The Mac sends original PNG or JPEG bytes; label the file with what it really is.
            clipMime = if (bytes.size > 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()) "image/jpeg" else "image/png"
            File(ctx.cacheDir, "clip.png").writeBytes(bytes)
            lastClip = null
            ClipData.newUri(ctx.contentResolver, "Mac image", Uri.parse("content://com.harshkit.phonebridge.img/clip.png?" + System.nanoTime()))
        }
        main.post { cm.setPrimaryClip(clip) } // writing the clipboard from the background is allowed
        android.util.Log.i("PhoneBridge", "Clipboard from Mac: " + if (j.has("text")) "text" else "image")
    }

    fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}

/** Kept alive by Android itself while notification access is granted — this is our always-on process. */
class BridgeService : NotificationListenerService() {
    companion object {
        @Volatile var instance: BridgeService? = null
        fun replyAction(n: Notification) = n.actions?.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }
    }

    override fun onListenerConnected() {
        instance = this
        Link.start(this)
        ClipWatch.start(this)
    }

    override fun onListenerDisconnected() { instance = null }

    override fun onNotificationPosted(sbn: StatusBarNotification) = forward(sbn, live = true)

    /** After every (re)connect: re-send what's still on the phone from the last 10 minutes. The Mac skips
     *  anything it already showed, so notifications that arrived while the link was down aren't lost. */
    fun resync() {
        val since = System.currentTimeMillis() - 10 * 60_000
        runCatching { activeNotifications }.getOrNull()?.filter { it.postTime > since }?.sortedBy { it.postTime }
            ?.forEach { runCatching { forward(it, live = false) } }
    }

    /** The category if this notification may go to the Mac (your switches allow it), else null. */
    fun shareable(sbn: StatusBarNotification): String? {
        val n = sbn.notification
        if (sbn.packageName == packageName || n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return null
        val cat = when {
            n.category == Notification.CATEGORY_CALL -> "call"
            n.category == Notification.CATEGORY_MESSAGE || n.extras.containsKey(Notification.EXTRA_MESSAGES) -> "msg" // WhatsApp chats
            else -> "app"
        }
        if (sbn.isOngoing && cat != "call") return null
        return cat.takeIf { Link.on(mapOf("call" to "calls", "msg" to "msgs", "app" to "apps").getValue(it)) }
    }

    private fun forward(sbn: StatusBarNotification, live: Boolean) {
        val n = sbn.notification
        val e = n.extras
        val cat = shareable(sbn) ?: return
        if (live && Replies.justReplied(sbn.key)) return // the app re-posts the thread with your own reply in it
        if (cat == "msg" && lastMessageIsMine(n)) return // "You: …" — your own message, nothing to alert
        val title = e.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (e.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: e.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return
        val pkg = sbn.packageName
        val app = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString() }.getOrDefault(pkg)
        if (live) {
            Link.bump(if (cat == "call") "calls" else if (cat == "msg") "msgs" else "apps")
            android.util.Log.i("PhoneBridge", "Forwarding $pkg ($cat)")
        }
        val reply = replyAction(n)
        if (reply != null) Replies.remember(sbn.key, reply)
        val j = JSONObject().put("t", "notif").put("id", sbn.key).put("app", app).put("pkg", pkg)
            .put("title", title).put("text", text).put("cat", cat).put("reply", reply != null)
        // Picture for the Mac alert, drawn like Android's: the sender's photo in a circle with the app's
        // icon as a badge, or just the app's icon when there's no photo.
        runCatching {
            avatar(n.getLargeIcon()?.loadDrawable(this), packageManager.getApplicationIcon(pkg))
        }.getOrNull()?.let { j.put("photo", it) }
        Link.send(j)
    }

    /** In a chat notification, a message with no sender is one you sent (Android's MessagingStyle). */
    private fun lastMessageIsMine(n: Notification): Boolean {
        @Suppress("DEPRECATION") val msgs = n.extras.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return false
        val last = msgs.lastOrNull() as? Bundle ?: return false
        return last.getCharSequence("sender") == null && last.get("sender_person") == null
    }

    private fun avatar(photo: android.graphics.drawable.Drawable?, icon: android.graphics.drawable.Drawable, size: Int = 192): String {
        val b = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(b)
        if (photo == null) {
            icon.setBounds(0, 0, size, size); icon.draw(c)
        } else {
            val circle = android.graphics.Path().apply { addCircle(size / 2f, size / 2f, size / 2f, android.graphics.Path.Direction.CW) }
            c.save(); c.clipPath(circle); photo.setBounds(0, 0, size, size); photo.draw(c); c.restore()
            val bs = (size * 0.42f).toInt(); val x = size - bs; val y = size - bs  // badge, bottom-right
            val ring = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE }
            c.drawCircle(x + bs / 2f, y + bs / 2f, bs / 2f + size * 0.025f, ring)
            c.save(); c.clipPath(android.graphics.Path().apply { addCircle(x + bs / 2f, y + bs / 2f, bs / 2f, android.graphics.Path.Direction.CW) })
            icon.setBounds(x, y, x + bs, y + bs); icon.draw(c); c.restore()
        }
        val out = java.io.ByteArrayOutputStream(); b.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        Replies.forget(sbn.key)
        Link.send(JSONObject().put("t", "notif_rm").put("id", sbn.key))
    }
}

class SmsReceiver : BroadcastReceiver() {
    companion object {
        fun granted(c: Context) = c.checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED
    }

    override fun onReceive(c: Context, i: Intent) {
        if (!Link.on("msgs")) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(i) ?: return
        if (parts.isEmpty()) return
        // Android 15+ hides OTP text from notification listeners, so the SMS itself is sent for code
        // detection only. The message is shown on the Mac via the Messages app's notification (which can be replied to).
        Link.send(JSONObject().put("t", "otp").put("from", parts[0].displayOriginatingAddress)
            .put("text", parts.joinToString("") { it.displayMessageBody }))
    }
}

/**
 * Phone -> Mac clipboard. Android 10+ blocks background clipboard reads, but the system still logs
 * "Denying clipboard access to <our package>" every time the clipboard changes while we hold a listener.
 * With READ_LOGS (granted over adb) we see that line, flash an invisible activity to gain focus for a
 * few ms, read the clip, and close. Same trick KDE Connect uses.
 */
object ClipWatch {
    private var started = false
    @Volatile private var proc: Process? = null
    /** True once we've seen any system ClipboardService line, i.e. Android granted log access. */
    @Volatile var healthy = false

    fun start(c: Context) {
        synchronized(this) { if (started) return; started = true }
        val app = c.applicationContext
        val cm = app.getSystemService(ClipboardManager::class.java)
        Handler(Looper.getMainLooper()).post { cm.addPrimaryClipChangedListener {} }
        if (app.checkSelfPermission(Manifest.permission.READ_LOGS) != PackageManager.PERMISSION_GRANTED) return
        thread(name = "clipwatch") {
            var wait = 500L
            while (true) {
                val began = System.currentTimeMillis()
                runCatching {
                    val since = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
                    val p = Runtime.getRuntime().exec(arrayOf("logcat", "-T", since, "ClipboardService:E", "*:S"))
                    proc = p
                    p.inputStream.bufferedReader().forEachLine { line ->
                        if (line.contains("Denying clipboard access")) healthy = true
                        if (line.contains(app.packageName) && Link.on("clip_out")) {
                            app.startActivity(Intent(app, ClipActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION))
                        }
                    }
                }
                // A logcat that lived a while (or was restarted on purpose) comes back fast; one that keeps dying backs off to 30 s.
                wait = if (System.currentTimeMillis() - began > 60_000 || healthy) 500L else minOf(wait * 2, 30_000L)
                Thread.sleep(wait)
            }
        }
    }

    /**
     * Android 13+ only grants log access to a logcat started while the app is on screen (the user taps
     * Allow). One started in the background after an update or reboot is silently blind, so the app
     * calls this from its screen until a real clipboard line has been seen.
     */
    fun restartIfBlind() { if (!healthy) proc?.destroy() }

    /** Manual send (Quick Settings tile, share sheet): an image URI or text, straight to the Mac. */
    fun sendImage(c: Context, uri: Uri): Boolean {
        val bytes = readCapped(c, uri, 20 * 1024 * 1024) ?: return false
        Link.bump("clip")
        Link.send(JSONObject().put("t", "clip").put("img", Base64.encodeToString(bytes, Base64.NO_WRAP)))
        android.util.Log.i("PhoneBridge", "Clipboard to Mac: image")
        return true
    }

    /** Reads at most [max] bytes; bigger files are refused without ever being held in memory. */
    private fun readCapped(c: Context, uri: Uri, max: Int): ByteArray? = c.contentResolver.openInputStream(uri)?.use { input ->
        val out = java.io.ByteArrayOutputStream(); val buf = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buf); if (n < 0) break
            if (out.size() + n > max) return null
            out.write(buf, 0, n)
        }
        out.toByteArray()
    }

    fun push(c: Context) {
        val clip = c.getSystemService(ClipboardManager::class.java).primaryClip?.takeIf { it.itemCount > 0 } ?: return
        // Password managers mark secrets as sensitive; those never leave the phone.
        val x = clip.description.extras
        if (x?.getBoolean(android.content.ClipDescription.EXTRA_IS_SENSITIVE) == true || x?.getBoolean("android.content.extra.IS_SENSITIVE") == true) return
        val item = clip.getItemAt(0)
        val uri = item.uri
        if (uri != null && c.contentResolver.getType(uri)?.startsWith("image/") == true) {
            if (uri.authority == "com.harshkit.phonebridge.img") return // our own copy of a Mac image
            sendImage(c, uri)
        } else {
            val t = item.coerceToText(c)?.toString() ?: return
            if (t.isEmpty() || t == Link.lastClip) return
            Link.lastClip = t
            Link.bump("clip")
            Link.send(JSONObject().put("t", "clip").put("text", t))
            android.util.Log.i("PhoneBridge", "Clipboard to Mac: text")
        }
    }
}

/** Invisible, focus-grabbing activity: reads the clipboard the instant it has focus, then disappears. */
class ClipActivity : Activity() {
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        if (!hasFocus) return
        runCatching { ClipWatch.push(this) }
        finish()
        @Suppress("DEPRECATION") overridePendingTransition(0, 0)
    }
}

/** Quick Settings tile "Send to Mac": one tap sends whatever is on the clipboard, no log access needed. */
class ClipTile : android.service.quicksettings.TileService() {
    override fun onStartListening() {
        qsTile?.apply { state = android.service.quicksettings.Tile.STATE_INACTIVE; updateTile() }
    }
    override fun onClick() {
        val i = Intent(this, ClipActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34)
            startActivityAndCollapse(android.app.PendingIntent.getActivity(this, 0, i, android.app.PendingIntent.FLAG_IMMUTABLE))
        else @Suppress("DEPRECATION") startActivityAndCollapse(i)
    }
}

/**
 * Share → "Send to Mac" from any app. Any app can open this screen, so the input is untrusted:
 * only shared content:// items (never our own files or file:// paths), and you confirm with a tap,
 * which another app can't do for you.
 */
class SendActivity : Activity() {
    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        Link.ctx = applicationContext
        val uri = intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            ?.takeIf { it.scheme == "content" && it.authority != "com.harshkit.phonebridge.img" }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (uri == null && text.isNullOrEmpty()) return finish()
        android.app.AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle(if (uri != null) "Send this image to your Mac?" else "Send this text to your Mac?")
            .apply { if (uri == null) setMessage(text!!.take(200) + if (text.length > 200) "…" else "") else setView(
                android.widget.ImageView(this@SendActivity).apply {
                    adjustViewBounds = true; maxHeight = (240 * resources.displayMetrics.density).toInt()
                    runCatching { setImageURI(uri) }
                }) }
            .setPositiveButton("Send") { _, _ -> send(uri, text) }
            .setNegativeButton("Cancel") { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .show()
            // Ignore taps while another app draws over the dialog (tapjacking).
            .run { listOf(android.content.DialogInterface.BUTTON_POSITIVE, android.content.DialogInterface.BUTTON_NEGATIVE).forEach { getButton(it)?.filterTouchesWhenObscured = true } }
    }

    private fun send(uri: Uri?, text: String?) {
        val ok = Link.connected && runCatching {
            when {
                uri != null -> ClipWatch.sendImage(this, uri)
                !text.isNullOrEmpty() -> { Link.lastClip = text; Link.bump("clip"); Link.send(JSONObject().put("t", "clip").put("text", text)); true }
                else -> false
            }
        }.getOrDefault(false)
        Toast.makeText(this, if (ok) "Sent to your Mac — press ⌘V" else "Your Mac isn't connected", Toast.LENGTH_SHORT).show()
        finish()
    }
}

/** Serves the last image the Mac copied, so it can sit on the Android clipboard as a content:// URI. */
class ImageProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri) = Link.clipMime
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
        ParcelFileDescriptor.open(File(context!!.cacheDir, "clip.png"), ParcelFileDescriptor.MODE_READ_ONLY)
    override fun query(u: Uri, p: Array<String>?, s: String?, a: Array<String>?, o: String?) = null
    override fun insert(u: Uri, v: ContentValues?) = null
    override fun update(u: Uri, v: ContentValues?, s: String?, a: Array<String>?) = 0
    override fun delete(u: Uri, s: String?, a: Array<String>?) = 0
}

/**
 * Reply from the Mac. Apps like WhatsApp and Messages put a "Reply" action with a text field
 * (RemoteInput) on their notifications; we keep it and, when the Mac sends text, fire it exactly
 * as the notification shade would.
 */
object Replies {
    private val actions = object : LinkedHashMap<String, Notification.Action>() {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Notification.Action>) = size > 200
    }
    private val repliedAt = object : LinkedHashMap<String, Long>() {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Long>) = size > 200
    }

    @Synchronized fun remember(key: String, a: Notification.Action) { actions[key] = a }
    @Synchronized fun forget(key: String) { actions.remove(key) }
    @Synchronized fun justReplied(key: String) = (repliedAt[key] ?: 0) > System.currentTimeMillis() - 4000

    fun send(c: Context, key: String, text: String): Boolean {
        // Remembered action, or (after a restart/update wiped memory) the live notification's own Reply action.
        val a = synchronized(this) { actions[key] }
            ?: runCatching {
                val svc = BridgeService.instance
                svc?.activeNotifications?.firstOrNull { it.key == key && svc.shareable(it) != null } // only what you share with the Mac
            }.getOrNull()?.notification?.let(BridgeService::replyAction)
            ?: return false.also { android.util.Log.w("PhoneBridge", "Reply failed: notification no longer on the phone") }
        return try {
            val inputs = a.remoteInputs
            val results = Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, text) } }
            val fill = Intent()
            android.app.RemoteInput.addResultsToIntent(inputs, fill, results)
            synchronized(this) { repliedAt[key] = System.currentTimeMillis() }
            a.actionIntent.send(c, 0, fill)
            android.util.Log.i("PhoneBridge", "Reply sent via ${a.actionIntent.creatorPackage}")
            true
        } catch (e: Exception) { android.util.Log.w("PhoneBridge", "Reply failed: ${e.javaClass.simpleName}"); false }
    }
}
