package placeholder

import android.content.ContentValues
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
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
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "hardsub/native"
    private val pickCode = 4711
    private var pendingPick: MethodChannel.Result? = null
    private var retriever: MediaMetadataRetriever? = null
    private val worker = Executors.newSingleThreadExecutor()

    private var prevGray: ByteArray? = null
    private var lastGray: ByteArray? = null
    private var lastW = 0
    private var lastH = 0
    private var lastLight = true
    private var lastBright = 200

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result -> handle(call, result) }
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
                        prevGray = null
                        val dur = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                        var w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                        var h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                        val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                        if (rot == 90 || rot == 270) { val t = w; w = h; h = t }
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
                val x0 = num(call, "x0").toDouble()
                val y0 = num(call, "y0").toDouble()
                val x1 = num(call, "x1").toDouble()
                val y1 = num(call, "y1").toDouble()
                val light = call.argument<Boolean>("light") ?: true
                val bright = num(call, "bright").toInt()
                val minFrac = num(call, "minFrac").toDouble()
                val changeFrac = num(call, "changeFrac").toDouble()
                val force = call.argument<Boolean>("force") ?: false
                worker.execute {
                    try {
                        val r = retriever ?: throw IllegalStateException("Video belum dibuka")
                        val full = r.getFrameAtTime(tMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
                        if (full == null) {
                            ok(result, mapOf("ok" to false))
                            return@execute
                        }
                        val fw = full.width
                        val fh = full.height
                        val cx = (x0 * fw).toInt().coerceIn(0, fw - 16)
                        val cy = (y0 * fh).toInt().coerceIn(0, fh - 8)
                        val cw = ((x1 - x0) * fw).toInt().coerceIn(16, fw - cx)
                        val ch = ((y1 - y0) * fh).toInt().coerceIn(8, fh - cy)
                        val crop = Bitmap.createBitmap(full, cx, cy, cw, ch)
                        val px = IntArray(cw * ch)
                        crop.getPixels(px, 0, cw, 0, 0, cw, ch)
                        val gray = ByteArray(cw * ch)
                        var cnt = 0
                        for (i in px.indices) {
                            val p = px[i]
                            val lum = (((p shr 16) and 255) * 299 + ((p shr 8) and 255) * 587 + (p and 255) * 114) / 1000
                            gray[i] = lum.toByte()
                            if (if (light) lum >= bright else lum <= 255 - bright) cnt++
                        }
                        val frac = cnt.toDouble() / px.size
                        var changed = -1.0
                        val pg = prevGray
                        if (pg != null && pg.size == gray.size) {
                            var d = 0
                            for (i in gray.indices) {
                                val a = gray[i].toInt() and 255
                                val b = pg[i].toInt() and 255
                                if (Math.abs(a - b) > 40) d++
                            }
                            changed = d.toDouble() / gray.size
                        }
                        prevGray = gray
                        lastGray = gray
                        lastW = cw
                        lastH = ch
                        lastLight = light
                        lastBright = bright
                        var path: String? = null
                        val need = force || (frac >= minFrac && (changed < 0 || changed >= changeFrac))
                        if (need) {
                            val f = File(cacheDir, "crop_raw.png")
                            FileOutputStream(f).use { crop.compress(Bitmap.CompressFormat.PNG, 100, it) }
                            path = f.absolutePath
                        }
                        if (crop !== full) crop.recycle()
                        full.recycle()
                        ok(result, mapOf("ok" to true, "frac" to frac, "changed" to changed, "path" to path))
                    } catch (e: Throwable) {
                        fail(result, "grab", e)
                    }
                }
            }
            "binarize" -> {
                worker.execute {
                    try {
                        val g = lastGray ?: throw IllegalStateException("Belum ada frame")
                        val scale = 2
                        val pad = 10
                        val w2 = lastW * scale + pad * 2
                        val h2 = lastH * scale + pad * 2
                        val out = IntArray(w2 * h2) { Color.WHITE }
                        for (yy in 0 until lastH * scale) {
                            val sy = yy / scale
                            for (xx in 0 until lastW * scale) {
                                val lum = g[sy * lastW + xx / scale].toInt() and 255
                                val isText = if (lastLight) lum >= lastBright else lum <= 255 - lastBright
                                if (isText) out[(yy + pad) * w2 + xx + pad] = Color.BLACK
                            }
                        }
                        val bmp = Bitmap.createBitmap(w2, h2, Bitmap.Config.ARGB_8888)
                        bmp.setPixels(out, 0, w2, 0, 0, w2, h2)
                        val f = File(cacheDir, "crop_bin.png")
                        FileOutputStream(f).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        bmp.recycle()
                        ok(result, f.absolutePath)
                    } catch (e: Throwable) {
                        fail(result, "binarize", e)
                    }
                }
            }
            "resetPrev" -> {
                prevGray = null
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
            "dirs" -> result.success(filesDir.absolutePath)
            "save" -> {
                val name = call.argument<String>("name")!!
                val text = call.argument<String>("text")!!
                worker.execute {
                    try {
                        val bytes = text.toByteArray(Charsets.UTF_8)
                        val where: String
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val cv = ContentValues().apply {
                                put(MediaStore.Downloads.DISPLAY_NAME, name)
                                put(MediaStore.Downloads.MIME_TYPE, "application/x-subrip")
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
        }
    }
}
