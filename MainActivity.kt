package placeholder

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.IBinder
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.Charset
import java.util.concurrent.Executors

private const val NOTIF_CHANNEL = "ocr_progress"

private fun ensureChannel(ctx: Context) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(NOTIF_CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(NOTIF_CHANNEL, "Proses OCR", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }
}

private fun buildNotif(ctx: Context, text: String, cur: Int, max: Int, ongoing: Boolean): Notification {
    ensureChannel(ctx)
    val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(ctx, NOTIF_CHANNEL)
    else Notification.Builder(ctx)
    val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
    if (launch != null) {
        b.setContentIntent(
            PendingIntent.getActivity(ctx, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        )
    }
    b.setSmallIcon(android.R.drawable.stat_sys_download)
        .setContentTitle("Hardsub OCR")
        .setContentText(text)
        .setOngoing(ongoing)
    if (ongoing) {
        b.setProgress(max, cur, max <= 0)
    } else {
        b.setAutoCancel(true)
    }
    return b.build()
}

/** Service latar depan: menjaga proses OCR tetap hidup saat app ditinggal. */
class OcrService : Service() {
    private var wl: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hardsub:ocr")
        wl?.acquire(12 * 60 * 60 * 1000L)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra("text") ?: "Memproses..."
        val n = buildNotif(this, text, 0, 0, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1, n)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try {
            wl?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }
}

/** Statistik satu kotak teks pada gambar abu-abu: porsi piksel teks, porsi bertepi gelap (outline), dan teks di sisi kiri/kanan kotak. */
private fun boxStat(g: ByteArray, w: Int, h: Int, l0: Int, t0: Int, r0: Int, b0: Int, light: Boolean, bright: Int): Map<String, Double> {
    if (w <= 1 || h <= 1) return mapOf("fill" to -1.0, "outline" to -1.0, "extL" to 0.0, "extR" to 0.0)
    val l = l0.coerceIn(0, w - 1)
    val t = t0.coerceIn(0, h - 1)
    val r = r0.coerceIn(l + 1, w)
    val b = b0.coerceIn(t + 1, h)
    val bh = b - t
    val rad = maxOf(2, bh / 14)
    val ext = maxOf(8, (bh * 2.5).toInt())
    fun lumAt(x: Int, y: Int): Int = g[y * w + x].toInt() and 255
    fun isText(x: Int, y: Int): Boolean = if (light) lumAt(x, y) >= bright else lumAt(x, y) <= 255 - bright
    fun isDark(x: Int, y: Int): Boolean = if (light) lumAt(x, y) <= 80 else lumAt(x, y) >= 175
    var text = 0
    var withEdge = 0
    for (y in t until b) {
        for (x in l until r) {
            if (!isText(x, y)) continue
            text++
            var found = false
            for (dy in -1..1) {
                for (dx in -1..1) {
                    if (dx == 0 && dy == 0) continue
                    for (m in 1..3) {
                        val xx = x + dx * rad * m
                        val yy = y + dy * rad * m
                        if (xx >= 0 && xx < w && yy >= 0 && yy < h && isDark(xx, yy)) found = true
                    }
                }
            }
            if (found) withEdge++
        }
    }
    fun strip(x0: Int, x1: Int): Double {
        if (x1 - x0 < 4) return 0.0
        var c = 0
        for (y in t until b) {
            for (x in x0 until x1) {
                if (isText(x, y)) c++
            }
        }
        return c.toDouble() / ((x1 - x0) * bh)
    }
    val area = (r - l) * bh
    return mapOf(
        "fill" to text.toDouble() / area,
        "outline" to (if (text > 20) withEdge.toDouble() / text else -1.0),
        "extL" to strip(maxOf(0, l - ext), l),
        "extR" to strip(r, minOf(w, r + ext))
    )
}

class MainActivity : FlutterActivity() {
    private val channelName = "hardsub/native"
    private val pickCode = 4711
    private val textCode = 4713
    private var pendingPick: MethodChannel.Result? = null
    private var pendingText: MethodChannel.Result? = null
    private var retriever: MediaMetadataRetriever? = null
    private val worker = Executors.newSingleThreadExecutor()

    // keadaan per area OCR (kunci = id area)
    private val prevMask = HashMap<Int, ByteArray>()
    private val lastGrayMap = HashMap<Int, ByteArray>()
    private val lastWMap = HashMap<Int, Int>()
    private val lastHMap = HashMap<Int, Int>()
    private var lastLight = true
    private var lastBright = 200
    private var vidW = 0
    private var vidH = 0
    private var vidRot = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    // Ambil frame; untuk video besar pakai dekode berskala (lebih hemat memori & lebih cepat)
    private fun frameAt(r: MediaMetadataRetriever, tUs: Long): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1 && vidRot == 0 && vidW > 1280 && vidH > 0) {
            val dw = 1280
            val dh = (vidH.toLong() * dw / vidW).toInt()
            try {
                val b = r.getScaledFrameAtTime(tUs, MediaMetadataRetriever.OPTION_CLOSEST, dw, dh)
                if (b != null) return b
            } catch (_: Throwable) {
            }
        }
        return r.getFrameAtTime(tUs, MediaMetadataRetriever.OPTION_CLOSEST)
    }

    private fun num(call: MethodCall, key: String): Number = call.argument<Number>(key)!!

    private fun ok(result: MethodChannel.Result, v: Any?) = runOnUiThread { result.success(v) }
    private fun fail(result: MethodChannel.Result, code: String, e: Throwable) =
        runOnUiThread { result.error(code, e.message ?: e.toString(), null) }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> {
                pendingPick = result
                val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/*", "application/x-matroska"))
                }
                startActivityForResult(i, pickCode)
            }
            "open" -> {
                val uriStr = call.argument<String>("uri")!!
                worker.execute {
                    try {
                        retriever?.release()
                        val uri = Uri.parse(uriStr)
                        val r = MediaMetadataRetriever()
                        r.setDataSource(this@MainActivity, uri)
                        retriever = r
                        prevMask.clear()
                        val dur = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                        var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                        var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                        val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                        if (rot == 90 || rot == 270) { val t = w; w = h; h = t }
                        vidW = w
                        vidH = h
                        vidRot = rot
                        var name = "video"
                        var size = 0L
                        contentResolver.query(uri, null, null, null, null)?.use { c ->
                            if (c.moveToFirst()) {
                                val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                val si = c.getColumnIndex(OpenableColumns.SIZE)
                                if (ni >= 0) name = c.getString(ni) ?: name
                                if (si >= 0) size = c.getLong(si)
                            }
                        }
                        if (dur <= 0L) throw IllegalStateException("Durasi video tidak terbaca (format tidak didukung HP ini?)")
                        ok(result, mapOf("durationMs" to dur, "width" to w, "height" to h, "name" to name, "size" to size))
                    } catch (e: Throwable) {
                        fail(result, "open", e)
                    }
                }
            }
            "frame" -> {
                val tMs = num(call, "timeMs").toLong()
                val maxW = num(call, "maxW").toInt()
                worker.execute {
                    try {
                        val r = retriever ?: throw IllegalStateException("Video belum dibuka")
                        val full = r.getFrameAtTime(tMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
                            ?: throw IllegalStateException("Frame tidak bisa dibaca pada waktu itu")
                        var bmp = full
                        if (full.width > maxW) {
                            val nh = (full.height.toLong() * maxW / full.width).toInt()
                            bmp = Bitmap.createScaledBitmap(full, maxW, nh, true)
                        }
                        val bos = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.JPEG, 85, bos)
                        val w = bmp.width
                        val h = bmp.height
                        if (bmp !== full) bmp.recycle()
                        full.recycle()
                        ok(result, mapOf("bytes" to bos.toByteArray(), "w" to w, "h" to h))
                    } catch (e: Throwable) {
                        fail(result, "frame", e)
                    }
                }
            }
            "grab" -> {
                val tMs = num(call, "timeMs").toLong()
                val areas = call.argument<List<Map<String, Any>>>("areas")!!
                val light = call.argument<Boolean>("light") ?: true
                val bright = num(call, "bright").toInt()
                val changeFrac = num(call, "changeFrac").toDouble()
                val force = call.argument<Boolean>("force") ?: false
                worker.execute {
                    try {
                        val r = retriever ?: throw IllegalStateException("Video belum dibuka")
                        val full = frameAt(r, tMs * 1000)
                        if (full == null) {
                            ok(result, areas.map { mapOf("id" to (it["id"] as Number).toInt(), "ok" to false) })
                            return@execute
                        }
                        val fw = full.width
                        val fh = full.height
                        lastLight = light
                        lastBright = bright
                        val out = ArrayList<Map<String, Any?>>()
                        for (a in areas) {
                            val id = (a["id"] as Number).toInt()
                            val x0 = (a["x0"] as Number).toDouble()
                            val x1 = (a["x1"] as Number).toDouble()
                            val y0 = (a["y0"] as Number).toDouble()
                            val y1 = (a["y1"] as Number).toDouble()
                            val minFrac = (a["minFrac"] as Number).toDouble()
                            val cx = (x0 * fw).toInt().coerceIn(0, fw - 16)
                            val cy = (y0 * fh).toInt().coerceIn(0, fh - 8)
                            val cw = ((x1 - x0) * fw).toInt().coerceIn(16, fw - cx)
                            val ch = ((y1 - y0) * fh).toInt().coerceIn(8, fh - cy)
                            val crop = Bitmap.createBitmap(full, cx, cy, cw, ch)
                            val px = IntArray(cw * ch)
                            crop.getPixels(px, 0, cw, 0, 0, cw, ch)
                            val gray = ByteArray(cw * ch)
                            val mask = ByteArray(cw * ch)
                            var cnt = 0
                            for (i in px.indices) {
                                val p = px[i]
                                val lum = (((p shr 16) and 255) * 299 + ((p shr 8) and 255) * 587 + (p and 255) * 114) / 1000
                                gray[i] = lum.toByte()
                                if (if (light) lum >= bright else lum <= 255 - bright) {
                                    cnt++
                                    mask[i] = 1
                                }
                            }
                            val frac = cnt.toDouble() / px.size
                            var changed = -1.0
                            val pg = prevMask[id]
                            if (pg != null && pg.size == mask.size) {
                                var d = 0
                                for (i in mask.indices) {
                                    if (mask[i] != pg[i]) d++
                                }
                                changed = d.toDouble() / mask.size
                            }
                            prevMask[id] = mask
                            lastGrayMap[id] = gray
                            lastWMap[id] = cw
                            lastHMap[id] = ch
                            var path: String? = null
                            val need = force || (frac >= minFrac && (changed < 0 || changed >= changeFrac))
                            if (need) {
                                val f = File(cacheDir, "crop_raw_$id.png")
                                FileOutputStream(f).use { crop.compress(Bitmap.CompressFormat.PNG, 100, it) }
                                path = f.absolutePath
                            }
                            if (crop !== full) crop.recycle()
                            out.add(
                                mapOf(
                                    "id" to id, "ok" to true, "frac" to frac, "changed" to changed, "path" to path,
                                    "cw" to cw, "ch" to ch,
                                    "nx0" to cx.toDouble() / fw, "ny0" to cy.toDouble() / fh,
                                    "nx1" to (cx + cw).toDouble() / fw, "ny1" to (cy + ch).toDouble() / fh
                                )
                            )
                        }
                        full.recycle()
                        ok(result, out)
                    } catch (e: Throwable) {
                        fail(result, "grab", e)
                    }
                }
            }
            "binarize" -> {
                val id = num(call, "id").toInt()
                worker.execute {
                    try {
                        val g = lastGrayMap[id] ?: throw IllegalStateException("Belum ada frame")
                        val lw = lastWMap[id] ?: 0
                        val lh = lastHMap[id] ?: 0
                        val scale = if (lw > 900) 1 else 2
                        val pad = 10
                        val w2 = lw * scale + pad * 2
                        val h2 = lh * scale + pad * 2
                        val out = IntArray(w2 * h2) { Color.WHITE }
                        for (yy in 0 until lh * scale) {
                            val sy = yy / scale
                            for (xx in 0 until lw * scale) {
                                val lum = g[sy * lw + xx / scale].toInt() and 255
                                val isText = if (lastLight) lum >= lastBright else lum <= 255 - lastBright
                                if (isText) out[(yy + pad) * w2 + xx + pad] = Color.BLACK
                            }
                        }
                        val bmp = Bitmap.createBitmap(w2, h2, Bitmap.Config.ARGB_8888)
                        bmp.setPixels(out, 0, w2, 0, 0, w2, h2)
                        val f = File(cacheDir, "crop_bin_$id.png")
                        FileOutputStream(f).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        bmp.recycle()
                        ok(result, mapOf("path" to f.absolutePath, "scale" to scale, "pad" to pad, "w" to w2, "h" to h2))
                    } catch (e: Throwable) {
                        fail(result, "binarize", e)
                    }
                }
            }
            "boxStats" -> {
                val id = num(call, "id").toInt()
                val boxes = call.argument<List<List<Number>>>("boxes")!!
                worker.execute {
                    try {
                        val g = lastGrayMap[id] ?: throw IllegalStateException("Belum ada frame")
                        val w = lastWMap[id] ?: 0
                        val h = lastHMap[id] ?: 0
                        val out = ArrayList<Map<String, Double>>()
                        for (b in boxes) {
                            out.add(boxStat(g, w, h, b[0].toInt(), b[1].toInt(), b[2].toInt(), b[3].toInt(), lastLight, lastBright))
                        }
                        ok(result, out)
                    } catch (e: Throwable) {
                        fail(result, "boxStats", e)
                    }
                }
            }
            "pickText" -> {
                pendingText = result
                val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }
                startActivityForResult(i, textCode)
            }
            "resetPrev" -> {
                prevMask.clear()
                result.success(null)
            }
            "keepAwake" -> {
                val on = call.argument<Boolean>("on") ?: false
                runOnUiThread {
                    if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
            }
            "serviceStart" -> {
                val text = call.argument<String>("text") ?: "Memproses..."
                try {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4712)
                    }
                    val i = Intent(this, OcrService::class.java).putExtra("text", text)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
                    result.success(null)
                } catch (e: Throwable) {
                    result.error("service", e.message, null)
                }
            }
            "serviceUpdate" -> {
                val text = call.argument<String>("text") ?: ""
                val cur = call.argument<Number>("cur")?.toInt() ?: 0
                val max = call.argument<Number>("max")?.toInt() ?: 0
                try {
                    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.notify(1, buildNotif(this, text, cur, max, true))
                } catch (_: Throwable) {
                }
                result.success(null)
            }
            "serviceStop" -> {
                try {
                    stopService(Intent(this, OcrService::class.java))
                } catch (_: Throwable) {
                }
                result.success(null)
            }
            "notifyDone" -> {
                val text = call.argument<String>("text") ?: "Selesai"
                try {
                    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.notify(2, buildNotif(this, text, 0, 0, false))
                } catch (_: Throwable) {
                }
                result.success(null)
            }
            "dirs" -> result.success(filesDir.absolutePath)
            "save" -> {
                val name = call.argument<String>("name")!!
                val text = call.argument<String>("text")!!
                val mime = call.argument<String>("mime") ?: "application/x-subrip"
                worker.execute {
                    try {
                        val bytes = text.toByteArray(Charsets.UTF_8)
                        val where: String
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val cv = ContentValues().apply {
                                put(MediaStore.Downloads.DISPLAY_NAME, name)
                                put(MediaStore.Downloads.MIME_TYPE, mime)
                                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                            }
                            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv)
                                ?: throw IllegalStateException("Gagal membuat file di Download")
                            contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }
                            where = "Download/$name"
                        } else {
                            val f = File(getExternalFilesDir(null), name)
                            f.writeBytes(bytes)
                            where = f.absolutePath
                        }
                        ok(result, where)
                    } catch (e: Throwable) {
                        fail(result, "save", e)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickCode) {
            val res = pendingPick
            pendingPick = null
            val uri = data?.data
            if (resultCode == RESULT_OK && uri != null) {
                try {
                    contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (_: Throwable) {
                }
                res?.success(uri.toString())
            } else {
                res?.success(null)
            }
        } else if (requestCode == textCode) {
            val res = pendingText
            pendingText = null
            val uri = data?.data
            if (resultCode == RESULT_OK && uri != null) {
                worker.execute {
                    try {
                        val bytes = contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                        if (bytes.size > 8 * 1024 * 1024) throw IllegalStateException("File terlalu besar untuk subtitle")
                        var txt = String(bytes, Charsets.UTF_8)
                        if (txt.indexOf(0xFFFD.toChar()) >= 0) txt = String(bytes, Charset.forName("windows-1252"))
                        var nm = "subtitle.srt"
                        contentResolver.query(uri, null, null, null, null)?.use { c ->
                            if (c.moveToFirst()) {
                                val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                if (ni >= 0) nm = c.getString(ni) ?: nm
                            }
                        }
                        ok(res!!, mapOf("name" to nm, "text" to txt))
                    } catch (e: Throwable) {
                        runOnUiThread { res?.error("pickText", e.message ?: e.toString(), null) }
                    }
                }
            } else {
                res?.success(null)
            }
        }
    }
}
