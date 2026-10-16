package com.harshkit.phonebridge

import android.Manifest
import android.animation.ValueAnimator
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// Dark iOS palette: true-black canvas, raised grey cards, system accent colours.
private const val BG = 0xFF000000.toInt()
private const val CARD = 0xFF1C1C1E.toInt()
private const val SEP = 0xFF38383A.toInt()
private const val GREY = 0xFF8E8E93.toInt()
private const val PINK = 0xFFFF375F.toInt()
private const val GREEN = 0xFF30D158.toInt()
private const val CYAN = 0xFF64D2FF.toInt()
private const val IOS_GREEN = 0xFF30D158.toInt()
private const val ORANGE = 0xFFFF9F0A.toInt()
private const val BLUE = 0xFF0A84FF.toInt()
private const val PURPLE = 0xFFBF5AF2.toInt()
private val BOLD = Typeface.create("sans-serif", Typeface.BOLD)
private val HEAVY = Typeface.create(Typeface.create("sans-serif", Typeface.NORMAL), 800, false)

/**
 * The hero: phone and Mac joined by the Harshkit bridge from the app icon. While connected the bar
 * glows and a soft light travels phone → Mac; when not, it sits grey and still.
 */
class BridgeView(c: Context) : View(c) {
    var connected = false
        set(v) { if (field != v) { field = v; if (v) pulse.start() else pulse.cancel(); invalidate() } }
    private var t = 0f
    private val pulse = ValueAnimator.ofFloat(0f, 1f).apply {
        duration = 1800; repeatCount = ValueAnimator.INFINITE
        interpolator = android.view.animation.AccelerateDecelerateInterpolator()
        addUpdateListener { t = it.animatedValue as Float; invalidate() }
    }
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)
    private val d = resources.displayMetrics.density

    override fun onDetachedFromWindow() { super.onDetachedFromWindow(); pulse.cancel() }

    override fun onDraw(cv: Canvas) {
        val h = height.toFloat(); val w = width.toFloat(); val cy = h / 2
        val metal = android.graphics.LinearGradient(0f, 0f, 0f, h, Color.WHITE, 0xFF9E9EA3.toInt(), android.graphics.Shader.TileMode.CLAMP)
        // phone
        val pw = h * 0.52f; val ph = h * 0.92f; val px = w * 0.16f
        val phone = RectF(px, cy - ph / 2, px + pw, cy + ph / 2)
        // Mac display + stand
        val mw = h * 1.05f; val mh = h * 0.68f; val mx = w * 0.84f - mw
        val screen = RectF(mx, cy - mh / 2 - h * 0.08f, mx + mw, cy + mh / 2 - h * 0.08f)
        // bridge
        val bar = RectF(phone.right - pw * 0.25f, cy - h * 0.085f, screen.left + mw * 0.12f, cy + h * 0.085f)

        if (connected) { // glow under the bar
            p.shader = null; p.color = 0xFF5E5CE6.toInt(); p.alpha = 90
            p.maskFilter = android.graphics.BlurMaskFilter(h * 0.16f, android.graphics.BlurMaskFilter.Blur.NORMAL)
            cv.drawRoundRect(bar, bar.height(), bar.height(), p)
            p.maskFilter = null; p.alpha = 255
        }
        p.shader = metal
        cv.drawRoundRect(phone, pw * 0.22f, pw * 0.22f, p)
        cv.drawRoundRect(screen, h * 0.1f, h * 0.1f, p)
        val stand = android.graphics.Path().apply {
            moveTo(screen.centerX() - h * 0.07f, screen.bottom); lineTo(screen.centerX() + h * 0.07f, screen.bottom)
            lineTo(screen.centerX() + h * 0.1f, screen.bottom + h * 0.17f); lineTo(screen.centerX() - h * 0.1f, screen.bottom + h * 0.17f); close()
        }
        cv.drawPath(stand, p)
        cv.drawRoundRect(RectF(screen.centerX() - h * 0.2f, screen.bottom + h * 0.15f, screen.centerX() + h * 0.2f, screen.bottom + h * 0.21f), h, h, p)
        p.shader = null; p.color = 0xFF111114.toInt()
        val bz = pw * 0.09f
        cv.drawRoundRect(RectF(phone.left + bz, phone.top + bz, phone.right - bz, phone.bottom - bz), pw * 0.15f, pw * 0.15f, p)
        cv.drawRoundRect(RectF(screen.left + bz, screen.top + bz, screen.right - bz, screen.bottom - bz), h * 0.06f, h * 0.06f, p)

        p.shader = if (connected) android.graphics.LinearGradient(bar.left, 0f, bar.right, 0f,
            intArrayOf(0xFF2997FF.toInt(), 0xFF5E5CE6.toInt(), 0xFFBF5AF2.toInt()), null, android.graphics.Shader.TileMode.CLAMP) else null
        p.color = 0xFF3A3A3C.toInt()
        cv.drawRoundRect(bar, bar.height(), bar.height(), p)
        if (connected) { // travelling light, clipped to the bar
            val x = bar.left + (bar.width() + bar.height() * 2) * t - bar.height()
            p.shader = android.graphics.RadialGradient(x, cy, bar.height() * 1.4f, 0xCCFFFFFF.toInt(), 0x00FFFFFF, android.graphics.Shader.TileMode.CLAMP)
            cv.save(); cv.clipPath(android.graphics.Path().apply { addRoundRect(bar, bar.height(), bar.height(), android.graphics.Path.Direction.CW) })
            cv.drawCircle(x, cy, bar.height() * 1.4f, p); cv.restore()
        }
        p.shader = null
    }
}

/**
 * Pairing entry point. Protected by android.permission.DUMP, which adb's shell holds and no
 * ordinary app can get — so another app on the phone can't re-pair Kitbridge to its own key.
 */
class PairActivity : Activity() {
    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        Link.ctx = applicationContext
        val key = intent.getStringExtra("key")
        if (key != null && key.matches(Regex("[0-9a-f]{64}"))) {
            Link.prefs.edit().putString("key", key).putString("host", intent.getStringExtra("host")).putInt("port", 47811).apply()
            Link.reconnect()
            Toast.makeText(this, "Paired with Mac", Toast.LENGTH_SHORT).show()
        }
        startActivity(Intent(this, MainActivity::class.java))
        finish()
    }
}

/** Shared look for Kitbridge's screens: dark iOS cards, type scale, rows, switches. */
abstract class KitActivity : Activity() {
    override fun onResume() { super.onResume(); ClipWatch.screens++ }
    override fun onPause() {
        super.onPause(); ClipWatch.screens--
        ClipWatch.probe(2000) // checks only if no Kitbridge screen is showing 2 s later
    }

    protected val d get() = resources.displayMetrics.density
    protected fun dp(v: Number) = (v.toFloat() * d).toInt()

    // ---- small view kit ----

    protected fun text(s: String, sp: Float, color: Int, tf: Typeface = Typeface.DEFAULT) =
        TextView(this).apply { text = s; textSize = sp; setTextColor(color); typeface = tf; includeFontPadding = false; letterSpacing = if (sp >= 22) -0.01f else 0f }

    /** Big number + small grey unit, the Fitness "320/400 CAL" look. */
    protected fun value(big: String, unit: String) = SpannableStringBuilder(big).apply {
        val s = length; append(unit)
        setSpan(RelativeSizeSpan(0.6f), s, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        setSpan(ForegroundColorSpan(GREY), s, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    protected fun card() = LinearLayout(this).apply {
        background = GradientDrawable().apply { cornerRadius = dp(20).toFloat(); setColor(CARD) }
        setPadding(dp(18), dp(18), dp(18), dp(18))
    }

    protected fun tile(parent: LinearLayout, label: String, color: Int, endMargin: Int, onClick: () -> Unit = {}): TextView {
        val t = card().apply { orientation = LinearLayout.VERTICAL; setOnClickListener { onClick() } }
        t.addView(text(label, 15f, color, BOLD), lp(bottom = 8))
        val v = text("—", 28f, Color.WHITE, HEAVY).apply { maxLines = 1 }
        t.addView(v)
        parent.addView(t, LinearLayout.LayoutParams(0, -1, 1f).apply { marginEnd = dp(endMargin) })
        return v
    }

    protected fun row(label: String, color: Int, icon: Int, last: Boolean, trailing: (LinearLayout) -> Unit): View {
        val wrap = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val r = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(dp(16), dp(11), dp(16), dp(11)) }
        val sq = FrameLayout(this).apply { background = GradientDrawable().apply { cornerRadius = dp(8).toFloat(); setColor(color) } }
        sq.addView(ImageView(this).apply { setImageResource(icon); imageTintList = ColorStateList.valueOf(Color.WHITE) },
            FrameLayout.LayoutParams(dp(20), dp(20), Gravity.CENTER))
        r.addView(sq, LinearLayout.LayoutParams(dp(30), dp(30)))
        r.addView(text(label, 17f, Color.WHITE), LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = dp(14) })
        trailing(r)
        wrap.addView(r)
        if (!last) wrap.addView(View(this).apply { setBackgroundColor(SEP) },
            LinearLayout.LayoutParams(-1, maxOf(1, dp(0.5))).apply { marginStart = dp(60) })
        return wrap
    }

    /** iOS switch: 51×31 pill track, white knob, system green when on. */
    protected fun iosSwitch(on: Boolean, changed: (Boolean) -> Unit) = Switch(this).apply {
        val checked = intArrayOf(android.R.attr.state_checked)
        trackDrawable = StateListDrawable().apply {
            addState(checked, GradientDrawable().apply { cornerRadius = dp(16).toFloat(); setColor(IOS_GREEN); setSize(dp(51), dp(31)) })
            addState(intArrayOf(), GradientDrawable().apply { cornerRadius = dp(16).toFloat(); setColor(0xFF39393D.toInt()); setSize(dp(51), dp(31)) })
        }
        thumbDrawable = GradientDrawable().apply {
            shape = GradientDrawable.OVAL; setColor(Color.WHITE); setSize(dp(31), dp(31)); setStroke(dp(2), Color.TRANSPARENT)
        }
        trackTintList = null; thumbTintList = null; showText = false; switchMinWidth = dp(51)
        isChecked = on
        setOnCheckedChangeListener { v, b -> v.performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK); changed(b) }
    }

    protected fun lp(top: Int = 0, bottom: Int = 0) =
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(top); bottomMargin = dp(bottom) }
}

class MainActivity : KitActivity() {
    private val tick = Handler(Looper.getMainLooper())
    private lateinit var bridge: BridgeView
    private lateinit var heroTitle: TextView
    private lateinit var heroSub: TextView
    private lateinit var pill: TextView
    private lateinit var stats: List<TextView>
    private lateinit var perms: LinearLayout
    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        Link.ctx = applicationContext
        // A force-stop (reinstall, setup.sh) unbinds the listener; ask Android to bind it again.
        NotificationListenerService.requestRebind(ComponentName(this, BridgeService::class.java))
        window.statusBarColor = BG
        window.navigationBarColor = BG

        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(28), dp(16), dp(40)) }

        // Header: date eyebrow, large title, live status pill.
        col.addView(text(SimpleDateFormat("EEEE, d MMM", Locale.getDefault()).format(Date()).uppercase(), 13f, GREY, BOLD))
        val head = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        head.addView(text("Kitbridge", 34f, Color.WHITE, HEAVY), LinearLayout.LayoutParams(0, -2, 1f))
        pill = text("", 13f, Color.WHITE, BOLD).apply { setPadding(dp(12), dp(6), dp(12), dp(6)) }
        head.addView(pill)
        col.addView(head, lp(top = 2, bottom = 14))

        // Hero: the bridge itself, who it's linked to, and how fast.
        val hero = card().apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL; setPadding(dp(18), dp(22), dp(18), dp(20)) }
        bridge = BridgeView(this)
        hero.addView(bridge, LinearLayout.LayoutParams(-1, dp(118)))
        heroTitle = text("", 20f, Color.WHITE, BOLD).apply { gravity = Gravity.CENTER }
        hero.addView(heroTitle, lp(top = 16))
        heroSub = text("", 15f, GREY).apply { gravity = Gravity.CENTER }
        hero.addView(heroSub, lp(top = 4))
        col.addView(hero, lp(bottom = 26))

        // Today: three counters with big numbers.
        col.addView(text("Today", 22f, Color.WHITE, BOLD), lp(bottom = 8))
        val tiles = LinearLayout(this)
        stats = listOf(Triple("Calls", PINK, "calls"), Triple("Messages", GREEN, "msgs"), Triple("Clipboard", CYAN, "clip")).mapIndexed { i, (label, c, kind) ->
            tile(tiles, label, c, endMargin = if (i < 2) 10 else 0) {
                startActivity(Intent(this, HistoryActivity::class.java).putExtra("kind", kind))
            }
        }
        col.addView(tiles, lp(bottom = 26))

        // Settings, grouped iOS-style.
        col.addView(text("Sync", 22f, Color.WHITE, BOLD), lp(bottom = 8))
        val group = card().apply { orientation = LinearLayout.VERTICAL; setPadding(0, 0, 0, 0) }
        val rows = listOf(
            Triple("master", "Bridge", IOS_GREEN to android.R.drawable.ic_lock_power_off),
            Triple("calls", "Calls", PINK to android.R.drawable.ic_menu_call),
            Triple("msgs", "Messages & SMS", 0xFF34C759.toInt() to android.R.drawable.sym_action_chat),
            Triple("apps", "App notifications", ORANGE to android.R.drawable.ic_popup_reminder),
            Triple("clip_out", "Send my copies to Mac", BLUE to android.R.drawable.stat_sys_upload),
            Triple("clip_in", "Receive Mac copies", PURPLE to android.R.drawable.stat_sys_download),
        )
        rows.forEachIndexed { i, (k, label, icon) ->
            group.addView(row(label, icon.first, icon.second, last = i == rows.lastIndex) { r ->
                r.addView(iosSwitch(Link.prefs.getBoolean(k, true)) { v ->
                    Link.prefs.edit().putBoolean(k, v).apply()
                    if (k == "master") Link.reconnect()
                    refresh()
                })
            })
        }
        col.addView(group, lp(bottom = 26))

        // Security: says exactly what protects the link.
        col.addView(text("Privacy", 22f, Color.WHITE, BOLD), lp(bottom = 8))
        val sec = card().apply { orientation = LinearLayout.VERTICAL; setPadding(0, 0, 0, 0) }
        sec.addView(row("End-to-end encrypted", IOS_GREEN, android.R.drawable.ic_lock_lock, last = false) { r -> r.addView(text("On", 17f, GREY)) })
        sec.addView(text("A new key is agreed for every connection (X25519), and every message is sealed with AES-256-GCM and numbered, so nothing on your Wi-Fi can read, change or replay it. No server — your phone talks only to your Mac.",
            14f, GREY).apply { setLineSpacing(0f, 1.25f); setPadding(dp(60), dp(4), dp(16), dp(14)) })
        col.addView(sec, lp(bottom = 26))

        perms = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(perms)
        col.addView(text("Harshkit · Kitbridge", 13f, GREY).apply { gravity = Gravity.CENTER }, lp(top = 22))

        // Android 15+ draws edge-to-edge: keep content clear of the status and gesture bars.
        // Scroll area stops at the status bar, so content never slides under the clock.
        setContentView(ScrollView(this).apply {
            setBackgroundColor(BG); isVerticalScrollBarEnabled = false; clipToPadding = true; addView(col)
            setOnApplyWindowInsetsListener { v, ins ->
                val bars = ins.getInsets(android.view.WindowInsets.Type.systemBars())
                v.setPadding(0, bars.top, 0, 0)
                col.setPadding(dp(16), dp(16), dp(16), bars.bottom + dp(32)); ins
            }
        })
    }

    override fun onResume() {
        super.onResume()
        BlindNotice.hide(this)
        ClipWatch.restartIfBlind() // on screen now, so Android can ask "Allow log access?"
        buildPerms()
        tick.post(object : Runnable {
            override fun run() { refresh(); tick.postDelayed(this, 1000) }
        })
    }

    override fun onPause() {
        super.onPause(); tick.removeCallbacksAndMessages(null)
    }

    private fun refresh() {
        val listener = Settings.Secure.getString(contentResolver, "enabled_notification_listeners").orEmpty().contains(packageName)
        val (label, color) = when {
            !listener -> "Needs access" to ORANGE
            Link.connected -> "● Connected" to IOS_GREEN
            !Link.prefs.getBoolean("master", true) -> "Off" to GREY
            else -> "● Searching" to ORANGE
        }
        pill.text = label
        pill.background = GradientDrawable().apply { cornerRadius = dp(20).toFloat(); setColor(color and 0x00FFFFFF or 0x33000000) }
        pill.setTextColor(color)

        listOf("calls", "msgs", "clip").forEachIndexed { i, k ->
            val enabled = if (k == "clip") Link.on("clip_out") || Link.on("clip_in") else Link.on(k)
            stats[i].text = if (enabled) Link.count(k).toString() else value("Off", "")
        }
        bridge.connected = Link.connected
        heroTitle.text = when {
            Link.connected -> Link.macName.ifEmpty { "Your Mac" }
            !Link.prefs.getBoolean("master", true) -> "Bridge is off"
            else -> "Looking for your Mac"
        }
        heroSub.text = when {
            Link.connected && Link.rttMs >= 0 -> "Encrypted link · ${Link.rttMs} ms"
            Link.connected -> "Encrypted link"
            !Link.prefs.getBoolean("master", true) -> "Turn on Bridge below"
            else -> "Same Wi-Fi as your Mac"
        }
    }

    private fun buildPerms() {
        perms.removeAllViews()
        val listener = Settings.Secure.getString(contentResolver, "enabled_notification_listeners").orEmpty().contains(packageName)
        val sms = SmsReceiver.granted(this)
        val copies = ClipWatch.a11yOn(this)
        if (listener && sms && copies) return
        perms.addView(text("Setup", 22f, Color.WHITE, BOLD), lp(bottom = 8))
        val g = card().apply { orientation = LinearLayout.VERTICAL; setPadding(0, 0, 0, 0) }
        val items = listOfNotNull(
            if (!listener) Triple("Notification access", ORANGE, { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }) else null,
            if (!sms) Triple("Full SMS text for OTPs", 0xFF34C759.toInt(), { requestPermissions(arrayOf(Manifest.permission.RECEIVE_SMS), 1) }) else null,
            if (!copies) Triple("Send copies automatically", BLUE, {
                Toast.makeText(this, "Installed apps → Kitbridge: copy to Mac → On", Toast.LENGTH_LONG).show()
                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            }) else null,
        )
        items.forEachIndexed { i, (label, c, go) ->
            g.addView(row(label, c, android.R.drawable.ic_dialog_alert, last = i == items.lastIndex) { r ->
                r.addView(text("Allow  ›", 17f, BLUE))
            }.apply { setOnClickListener { go() } })
        }
        perms.addView(g)
    }

    override fun onRequestPermissionsResult(c: Int, p: Array<String>, r: IntArray) = buildPerms()

}

/** Last 20 calls, messages or clipboard items: tap a copy to copy it again, × to delete one, or clear all. */
class HistoryActivity : KitActivity() {
    private lateinit var list: LinearLayout
    private val kind get() = intent.getStringExtra("kind") ?: "msgs"

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        Link.ctx = applicationContext
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE) // message/OTP text: keep out of recents previews and screenshots
        window.statusBarColor = BG; window.navigationBarColor = BG
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(12), dp(16), dp(32)) }
        val bar = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        bar.addView(text("‹ Kitbridge", 17f, BLUE).apply { setPadding(0, dp(8), dp(8), dp(8)); setOnClickListener { finish() } },
            LinearLayout.LayoutParams(0, -2, 1f))
        bar.addView(text("Clear all", 17f, PINK).apply {
            setPadding(dp(8), dp(8), 0, dp(8))
            setOnClickListener {
                android.app.AlertDialog.Builder(this@HistoryActivity, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                    .setTitle("Clear all ${title()}?").setMessage("This deletes the history from this phone.")
                    .setPositiveButton("Clear") { _, _ -> History.clear(kind); render() }
                    .setNegativeButton("Cancel", null).show()
            }
        })
        col.addView(bar)
        col.addView(text(title(), 34f, Color.WHITE, HEAVY), lp(top = 6, bottom = 4))
        col.addView(text("Last 20 · kept only on this phone", 14f, GREY), lp(bottom = 16))
        list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(list)
        setContentView(ScrollView(this).apply {
            setBackgroundColor(BG); isVerticalScrollBarEnabled = false; clipToPadding = true; addView(col)
            setOnApplyWindowInsetsListener { v, ins ->
                val bars = ins.getInsets(android.view.WindowInsets.Type.systemBars())
                v.setPadding(0, bars.top, 0, 0); col.setPadding(dp(16), dp(12), dp(16), bars.bottom + dp(32)); ins
            }
        })
        render()
    }

    private fun title() = mapOf("calls" to "Calls", "msgs" to "Messages", "clip" to "Clipboard")[kind] ?: "History"

    private fun render() {
        list.removeAllViews()
        val items = History.list(kind)
        if (items.length() == 0) { list.addView(text("Nothing yet.", 17f, GREY), lp(top = 24)); return }
        val group = card().apply { orientation = LinearLayout.VERTICAL; setPadding(0, 0, 0, 0) }
        for (i in 0 until items.length()) {
            val it = items.getJSONObject(i)
            val row = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL; setPadding(dp(16), dp(12), dp(8), dp(12)) }
            val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            val head = if (kind == "clip") (if (it.optString("dir") == "out") "To Mac" else "From Mac") else
                listOf(it.optString("title"), it.optString("app")).filter { s -> s.isNotEmpty() }.joinToString(" · ")
            val time = android.text.format.DateUtils.getRelativeTimeSpanString(it.optLong("t"), System.currentTimeMillis(), 60_000L)
            body.addView(text("$head  ·  $time", 13f, GREY, BOLD))
            body.addView(text(it.optString("text"), 16f, Color.WHITE).apply { maxLines = 3; ellipsize = android.text.TextUtils.TruncateAt.END }, lp(top = 4))
            row.addView(body, LinearLayout.LayoutParams(0, -2, 1f))
            row.addView(text("✕", 17f, GREY).apply {
                setPadding(dp(14), dp(6), dp(10), dp(6))
                contentDescription = "Delete"
                setOnClickListener { _ -> History.remove(kind, items.getJSONObject(i).optLong("t")); render() }
            })
            if (kind == "clip" && !it.optBoolean("img")) row.setOnClickListener { _ ->
                getSystemService(android.content.ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText("Kitbridge", it.optString("text")))
                Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show()
            }
            group.addView(row)
            if (i < items.length() - 1) group.addView(View(this).apply { setBackgroundColor(SEP) },
                LinearLayout.LayoutParams(-1, maxOf(1, dp(0.5))).apply { marginStart = dp(16) })
        }
        list.addView(group)
    }
}
