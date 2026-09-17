package com.mp2tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.DisplayMetrics
import android.view.Display
import android.view.Surface
import android.view.WindowManager
import org.json.JSONObject
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class MirrorService : Service() {
    companion object {
        @Volatile
        var running = false
        var listener: ((String) -> Unit)? = null

        private const val CH = "mirror"
        private const val NOTIF_ID = 1
        private const val ACTION_STOP = "stop"
        private const val QUEUE_CAP = 256
        private const val PING_MS = 2000L
        private const val DEAD_MS = 6000L
        private const val RECONNECT_MS = 10000L

        fun start(ctx: Context, resultCode: Int, data: Intent, dev: PairedComputer) {
            ctx.startForegroundService(
                Intent(ctx, MirrorService::class.java)
                    .putExtra("resultCode", resultCode)
                    .putExtra("data", data)
                    .putExtra("receiverId", dev.receiverId)
            )
        }

        fun b64url(b: ByteArray) = Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_WRAP)
    }

    private lateinit var store: PairedStore
    private var dev: PairedComputer? = null
    private var projection: MediaProjection? = null
    private var encoder: MediaCodec? = null
    private var vd: VirtualDisplay? = null
    private var audioRec: AudioRecord? = null
    private var csd: ByteArray? = null
    private var bitrate = 6_000_000

    private var conn: Conn? = null
    private var worker: Thread? = null
    private var reader: Thread? = null
    private var writer: Thread? = null
    private var audioThread: Thread? = null
    private var codecThread: Thread? = null
    private val queue = LinkedBlockingQueue<Triple<Int, ByteArray, Boolean>>(QUEUE_CAP)
    @Volatile
    private var stopping = false
    @Volatile
    private var lastSeen = 0L
    @Volatile
    private var sessionDead = false
    private var lastRotation = -1
    private val handler = Handler(Looper.getMainLooper())
    private val rotationListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) {}
        override fun onDisplayRemoved(id: Int) {}
        override fun onDisplayChanged(id: Int) {
            if (id != Display.DEFAULT_DISPLAY) return
            val r = currentRotation()
            if (lastRotation != -1 && r != lastRotation) {
                handler.postDelayed({ rebuildCapture() }, 300)
            }
            lastRotation = r
        }
    }

    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopAll("user")
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        store = PairedStore(this)
        val rid = intent?.getStringExtra("receiverId") ?: return START_NOT_STICKY
        val d = store.list().find { it.receiverId == rid } ?: return START_NOT_STICKY
        val data: Intent = intent.getParcelableExtra("data") ?: return START_NOT_STICKY
        val resultCode = intent.getIntExtra("resultCode", 0)
        dev = d
        running = true
        stopping = false
        lastRotation = currentRotation()

        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        projection = mpm.getMediaProjection(resultCode, data)
        projection!!.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                L.i("projection stopped")
                stopAll("captureEnded")
            }
        }, handler)

        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH, "投屏", NotificationManager.IMPORTANCE_LOW)
        )
        val stopPi = PendingIntent.getService(
            this, 0,
            Intent(this, MirrorService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val notif = Notification.Builder(this, CH)
            .setContentTitle("mp2tv 正在投屏")
            .setContentText("投到 ${d.name}")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .addAction(Notification.Action.Builder(null, "停止投屏", stopPi).build())
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, notif)
        }
        getSystemService(DisplayManager::class.java)
            .registerDisplayListener(rotationListener, handler)

        worker = Thread { sessionLoop() }.also { it.start() }
        return START_STICKY
    }

    private fun status(s: String) {
        L.i("status: $s")
        listener?.invoke(s)
        handler.post {
            getSystemService(NotificationManager::class.java).notify(
                NOTIF_ID,
                Notification.Builder(this, CH)
                    .setContentTitle("mp2tv")
                    .setContentText(s)
                    .setSmallIcon(android.R.drawable.presence_video_online)
                    .build()
            )
        }
    }

    private fun sessionLoop() {
        val d = dev ?: return stopSelf()
        val token = store.token(d.receiverId)
        if (token == null) {
            status("配对信息缺失，请重新扫码")
            return stopSelf()
        }

        status("连接中…")
        var c = connectAndHello(d, token, 4000)
        when (c.second) {
            null -> {
                status("投屏中")
                startCapture()
            }
            "transport" -> {
                status("无法连接 ${d.lastHost}")
                return stopSelf()
            }
            else -> {
                status(helloFailText(c.second!!))
                return stopSelf()
            }
        }

        while (!stopping) {
            waitDrop()
            if (stopping) break
            status("重连中…")
            val deadline = SystemClock.elapsedRealtime() + RECONNECT_MS
            var resumed = false
            while (!stopping && SystemClock.elapsedRealtime() < deadline) {
                val r = connectAndHello(d, token, 2500)
                when (r.second) {
                    null -> {
                        requestKeyframe()
                        status("投屏中")
                        resumed = true
                    }
                    "transport" -> {
                    }
                    else -> {
                        status(helloFailText(r.second!!))
                        return stopSelf()
                    }
                }
                if (resumed) break
                SystemClock.sleep(300)
            }
            if (!resumed) {
                status("重连超时，投屏已结束")
                break
            }
        }
        stopSelf()
    }

    /** Blocks until the current connection drops or we are stopping. */
    private fun waitDrop() {
        while (!stopping && conn != null) {
            if (sessionDead || SystemClock.elapsedRealtime() - lastSeen > DEAD_MS) break
            SystemClock.sleep(100)
        }
        conn?.close()
        conn = null
        sessionDead = false
    }

    /**
     * Connect, send hello, wait for helloResult. The reader thread started here keeps running
     * for the life of the connection.
     * Returns (conn, null) on success, (null, "transport") on network failure,
     * or (null, reason) when the receiver rejected.
     */
    private fun connectAndHello(d: PairedComputer, token: ByteArray, timeoutMs: Int): Pair<Conn?, String?> {
        val c = try {
            Conn(TlsClient.connect(d.lastHost, d.lastPort, d.fp(), timeoutMs))
        } catch (e: Throwable) {
            L.i("connect failed: $e")
            return null to "transport"
        }
        val helloQ = java.util.concurrent.ArrayBlockingQueue<JSONObject>(1)
        val welcomed = java.util.concurrent.atomic.AtomicBoolean(false)
        lastSeen = SystemClock.elapsedRealtime()
        conn = c
        reader = Thread {
            c.readLoop(object : Conn.Listener {
                override fun onControl(msg: JSONObject) {
                    lastSeen = SystemClock.elapsedRealtime()
                    if (msg.optString("t") == "helloResult" && !welcomed.get()) helloQ.offer(msg)
                    else onRemoteControl(msg)
                }
                override fun onFrame(t: Int, p: ByteArray) {
                    lastSeen = SystemClock.elapsedRealtime()
                }
                override fun onClosed(e: Throwable?) {
                    sessionDead = true
                }
            })
        }.also { it.start() }
        writer = Thread {
            while (!stopping && conn === c) {
                val m = queue.poll(PING_MS, TimeUnit.MILLISECONDS)
                try {
                    if (m == null) c.sendControl(JSONObject().put("t", "ping"))
                    else c.sendFrame(m.first, m.second)
                } catch (e: Throwable) {
                    break
                }
            }
        }.also { it.start() }
        c.sendControl(
            JSONObject()
                .put("t", "hello").put("v", Proto.VERSION)
                .put("senderId", senderId())
                .put("senderName", "${Build.MANUFACTURER} ${Build.MODEL}")
                .put("token", b64url(token))
        )
        val r = helloQ.poll(6, TimeUnit.SECONDS)
        if (r == null) {
            c.close()
            return null to if (sessionDead) "transport" else "timeout"
        }
        if (!r.optBoolean("ok")) {
            c.close()
            return null to r.optString("reason", "failed")
        }
        welcomed.set(true)
        return c to null
    }

    private fun helloFailText(reason: String) = when (reason) {
        "notPaired" -> {
            dev?.let {
                it.invalid = true
                store.upsert(it)
            }
            "电脑已解除配对，请重新扫码"
        }
        "busy" -> "电脑正在投其他手机"
        "versionMismatch" -> "协议版本不匹配，请升级"
        "receiverLocked" -> "电脑已锁屏"
        else -> "连接失败: $reason"
    }

    private fun onRemoteControl(msg: JSONObject) {
        lastSeen = SystemClock.elapsedRealtime()
        when (msg.optString("t")) {
            "stop" -> {
                L.i("remote stop: ${msg.optString("reason")}")
                stopAll(null)
            }
            "command" -> when (msg.optString("action")) {
                "keyframe" -> requestKeyframe()
            }
        }
    }

    // ---------- capture pipeline ----------

    private fun currentRotation(): Int = try {
        (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.rotation
    } catch (e: Throwable) {
        -1
    }

    private fun targetSize(): Pair<Int, Int> {
        val dm = DisplayMetrics()
        @Suppress("DEPRECATION")
        (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(dm)
        var w = dm.widthPixels
        var h = dm.heightPixels
        val scale = minOf(1920f / maxOf(w, h), 1080f / minOf(w, h), 1f)
        w = ((w * scale).toInt() / 2) * 2
        h = ((h * scale).toInt() / 2) * 2
        return w to h
    }

    @Synchronized
    private fun startCapture() {
        stopCapture()
        val (w, h) = targetSize()
        L.i("capture ${w}x$h rot=$lastRotation")
        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 5)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_LATENCY, 0)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface: Surface = enc.createInputSurface()
        enc.start()
        encoder = enc
        val dm = DisplayMetrics()
        @Suppress("DEPRECATION")
        (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(dm)
        vd = projection?.createVirtualDisplay(
            "mp2tv", w, h, dm.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface, null, handler
        )
        codecThread = Thread { drainEncoder(enc) }.also { it.start() }
        startAudio()
    }

    @Synchronized
    private fun rebuildCapture() {
        if (stopping || conn == null) return
        L.i("rotation changed -> rebuild capture")
        startCapture()
    }

    private fun drainEncoder(enc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            try {
                val idx = enc.dequeueOutputBuffer(info, 10_000)
                when {
                    idx == MediaCodec.INFO_TRY_AGAIN_LATER -> if (encoder !== enc || stopping) break
                    idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                        L.i("encoder format: ${enc.outputFormat}")
                    idx >= 0 -> {
                        val buf = enc.getOutputBuffer(idx)!!
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            val b = ByteArray(info.size)
                            buf.position(info.offset)
                            buf.get(b)
                            csd = b
                        } else if (info.size > 0) {
                            var au = ByteArray(info.size)
                            buf.position(info.offset)
                            buf.get(au)
                            val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            if (key && !containsSps(au)) {
                                val c = csd
                                if (c != null) au = c + au
                            }
                            // payload: pts u64 + flags u8 + rotation u8 + AU
                            val p = ByteArray(10 + au.size)
                            var v = info.presentationTimeUs
                            for (i in 0..7) {
                                p[i] = (v ushr 56).toByte()
                                v = v shl 8
                            }
                            p[8] = (if (key) 1 else 0).toByte()
                            p[9] = 0 // rotation: content is already pixel-rotated by the virtual display
                            au.copyInto(p, 10)
                            enqueue(Proto.FRAME_VIDEO, p, key)
                        }
                        enc.releaseOutputBuffer(idx, false)
                    }
                }
            } catch (e: Throwable) {
                break
            }
        }
        L.i("encoder drain exited")
    }

    private fun containsSps(au: ByteArray): Boolean {
        var i = 0
        while (i + 4 < au.size) {
            if (au[i].toInt() == 0 && au[i + 1].toInt() == 0 &&
                (au[i + 2].toInt() == 1 || (au[i + 2].toInt() == 0 && au[i + 3].toInt() == 1))
            ) {
                val hdr = if (au[i + 2].toInt() == 1) i + 3 else i + 4
                if (hdr < au.size && au[hdr].toInt() and 0x1f == 7) return true
                i = hdr
            } else i++
        }
        return false
    }

    private fun startAudio() {
        audioThread = Thread {
            try {
                val cfg = AudioPlaybackCaptureConfiguration.Builder(projection!!)
                    .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                    .addMatchingUsage(AudioAttributes.USAGE_GAME)
                    .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                    .build()
                val fmt = AudioFormat.Builder()
                    .setSampleRate(48000)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
                val min = AudioRecord.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
                val rec = AudioRecord.Builder()
                    .setAudioPlaybackCaptureConfig(cfg)
                    .setAudioFormat(fmt)
                    .setBufferSizeInBytes(maxOf(min * 2, 19200))
                    .build()
                audioRec = rec
                rec.startRecording()
                val chunk = ByteArray(19200)
                var framesSent = 0L
                val startNs = System.nanoTime()
                while (!stopping) {
                    val n = rec.read(chunk, 0, chunk.size)
                    if (n <= 0) break
                    val frames = n / 4
                    val ptsUs = startNs / 1000 + framesSent * 1_000_000L / 48000
                    framesSent += frames
                    val p = ByteArray(8 + n)
                    var v = ptsUs
                    for (i in 0..7) {
                        p[i] = (v ushr 56).toByte()
                        v = v shl 8
                    }
                    chunk.copyInto(p, 8, 0, n)
                    enqueue(Proto.FRAME_AUDIO, p, false)
                }
            } catch (e: Throwable) {
                L.i("audio capture ended: $e")
            }
        }.also { it.start() }
    }

    private fun enqueue(type: Int, payload: ByteArray, isKey: Boolean) {
        if (conn == null || stopping) return
        if (!queue.offer(Triple(type, payload, isKey))) {
            // congested: drop all non-key video frames, drop audio backlog, lower bitrate
            val kept = ArrayList<Triple<Int, ByteArray, Boolean>>(QUEUE_CAP)
            queue.drainTo(kept)
            var dropped = 0
            for (m in kept) {
                if (m.first == Proto.FRAME_VIDEO && !m.third) {
                    dropped++
                    continue
                }
                queue.offer(m)
            }
            queue.offer(Triple(type, payload, isKey))
            if (dropped > 0 && bitrate > 1_500_000) {
                bitrate = (bitrate * 3) / 4
                try {
                    encoder?.setParameters(
                        Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate) }
                    )
                } catch (_: Throwable) {
                }
            }
        }
    }

    private fun requestKeyframe() {
        try {
            encoder?.setParameters(
                Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }
            )
        } catch (e: Throwable) {
            L.i("requestKeyframe: $e")
        }
    }

    @Synchronized
    private fun stopCapture() {
        audioRec?.let {
            try {
                it.stop()
                it.release()
            } catch (_: Throwable) {
            }
        }
        audioRec = null
        vd?.release()
        vd = null
        encoder?.let {
            try {
                it.stop()
                it.release()
            } catch (_: Throwable) {
            }
        }
        encoder = null
        csd = null
    }

    private fun stopAll(reason: String?) {
        if (stopping) return
        stopping = true
        reason?.let {
            try {
                conn?.sendControl(JSONObject().put("t", "stop").put("reason", it))
            } catch (_: Throwable) {
            }
        }
        Thread {
            SystemClock.sleep(150)
            conn?.close()
            conn = null
            stopCapture()
            projection?.stop()
            getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(rotationListener)
            running = false
            stopSelf()
        }.start()
    }

    override fun onDestroy() {
        stopping = true
        conn?.close()
        stopCapture()
        projection?.stop()
        try {
            getSystemService(DisplayManager::class.java).unregisterDisplayListener(rotationListener)
        } catch (_: Throwable) {
        }
        running = false
        super.onDestroy()
    }
}
