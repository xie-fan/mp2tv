package com.mp2tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.PowerManager
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
        private const val ACTION_ROTATE = "rotate"
        private const val ACTION_CROP = "crop"
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
    private var glPipe: GlPipe? = null
    private val queue = LinkedBlockingQueue<Triple<Int, ByteArray, Boolean>>(QUEUE_CAP)
    @Volatile
    private var stopping = false
    @Volatile
    private var lastSeen = 0L
    @Volatile
    private var sessionDead = false
    private var lastRotation = -1

    // --- M2: smart crop ---
    @Volatile
    private var cropEnabled = true // session-scoped, default from settings
    @Volatile
    private var appliedCrop: ContentDetect.Rect? = null // null = full screen
    private var pendingRect: ContentDetect.Rect? = null
    private var pendingCount = 0
    private var lastCropApply = 0L
    @Volatile
    private var latestDetected: ContentDetect.Rect? = null

    // --- M2: smart rotation ---
    // forcedCycle: 0=auto, 1/2/3 = forced clockwise-90° count (spec: press 4th returns to auto)
    @Volatile
    private var forcedCycle = 0
    @Volatile
    private var gravLandscape = false
    @Volatile
    private var gravSign = 0
    private var gravSince = 0L
    private var gravHoldSign = 0
    private var sensorMgr: SensorManager? = null

    private var vdW = 0
    private var vdH = 0 // VD 缓冲尺寸：会话内固定，物理转屏后不随 targetSize 变化
    private var encW = 0
    private var encH = 0
    private var wakeLock: PowerManager.WakeLock? = null
    private var audioManager: AudioManager? = null
    private var prevVolume = -1
    private val handler = Handler(Looper.getMainLooper())
    private val rotationListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) {}
        override fun onDisplayRemoved(id: Int) {}
        override fun onDisplayChanged(id: Int) {
            if (id != Display.DEFAULT_DISPLAY) return
            val r = currentRotation()
            if (lastRotation != -1 && r != lastRotation) {
                // 物理转屏：VD 尺寸不变，系统把新方向画面信箱化进旧缓冲。
                // 旧截取区域必然失效，回全幅让检测器重新找条带。
                appliedCrop = null
                pendingRect = null
                pendingCount = 0
                handler.postDelayed({ resizeForRotation() }, 300)
            }
            lastRotation = r
        }
    }

    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { stopAll("user"); return START_NOT_STICKY }
            ACTION_ROTATE -> { cycleForceRotate(); return START_NOT_STICKY }
            ACTION_CROP -> { toggleCrop(); return START_NOT_STICKY }
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
        forcedCycle = 0
        appliedCrop = null
        pendingRect = null
        pendingCount = 0
        latestDetected = null
        gravLandscape = false
        cropEnabled = getSharedPreferences("mp2tv", Context.MODE_PRIVATE)
            .getBoolean("smartCrop", true)

        // Android 14+ 要求：先 startForeground(MEDIA_PROJECTION) 再 getMediaProjection，
        // 顺序反了会 SecurityException 闪退
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            // DEFAULT：LOW 在部分 ROM 会把通知折叠成一行，快捷按钮不可见
            NotificationChannel(CH, "投屏", NotificationManager.IMPORTANCE_DEFAULT)
        )
        val notif = buildNotification("投到 ${d.name}")
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIF_ID, notif)
        }

        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mp = try { mpm.getMediaProjection(resultCode, data) } catch (e: Throwable) {
            L.i("getMediaProjection failed: $e"); null
        }
        if (mp == null) {
            L.i("no projection, stopping")
            status("录屏授权失败")
            stopAll("noProjection")
            return START_NOT_STICKY
        }
        projection = mp
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                L.i("projection stopped")
                stopAll("captureEnded")
            }
        }, handler)
        getSystemService(DisplayManager::class.java)
            .registerDisplayListener(rotationListener, handler)

        // 投屏期间媒体音量归零（结束恢复）；屏幕只变暗不熄灭
        audioManager = getSystemService(AudioManager::class.java)
        audioManager?.let {
            prevVolume = it.getStreamVolume(AudioManager.STREAM_MUSIC)
            it.setStreamVolume(AudioManager.STREAM_MUSIC, 0, 0)
        }
        val pm = getSystemService(PowerManager::class.java)
        @Suppress("DEPRECATION")
        wakeLock = pm.newWakeLock(PowerManager.SCREEN_DIM_WAKE_LOCK, "mp2tv:dim")
            .also { it.acquire() }

        // 重力转正：加速度计
        sensorMgr = getSystemService(SensorManager::class.java)
        sensorMgr?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            sensorMgr?.registerListener(gravityListener, it, SensorManager.SENSOR_DELAY_NORMAL)
        }

        worker = Thread { sessionLoop() }.also { it.start() }
        return START_STICKY
    }

    private fun status(s: String) {
        L.i("status: $s")
        listener?.invoke(s)
        handler.post {
            getSystemService(NotificationManager::class.java)
                .notify(NOTIF_ID, buildNotification(s))
        }
    }

    private fun buildNotification(text: String): Notification {
        fun pi(action: String, req: Int) = PendingIntent.getService(
            this, req, Intent(this, MirrorService::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE
        )
        val rotLabel = if (forcedCycle == 0) "旋转" else "旋转 ${forcedCycle * 90}°"
        val cropLabel = if (cropEnabled) "截取:开" else "截取:关"
        return Notification.Builder(this, CH)
            .setContentTitle("mp2tv 正在投屏")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .addAction(Notification.Action.Builder(null, rotLabel, pi(ACTION_ROTATE, 1)).build())
            .addAction(Notification.Action.Builder(null, cropLabel, pi(ACTION_CROP, 2)).build())
            .addAction(Notification.Action.Builder(null, "停止投屏", pi(ACTION_STOP, 0)).build())
            .setOngoing(true)
            .build()
    }

    // ---------- M2: rotation ----------

    /** 强制旋转循环：0 auto -> 1(90°) -> 2(180°) -> 3(270°) -> 0 auto */
    private fun cycleForceRotate() {
        forcedCycle = (forcedCycle + 1) % 4
        L.i("forceRotate cycle -> $forcedCycle")
        status("投屏中")
    }

    private fun toggleCrop() {
        cropEnabled = !cropEnabled
        L.i("smartCrop -> $cropEnabled")
        if (!cropEnabled) appliedCrop = null
        pendingRect = null
        pendingCount = 0
        handler.post { rebuildCapture() }
        status("投屏中")
    }

    private val gravityListener = object : SensorEventListener {
        override fun onSensorChanged(e: SensorEvent) {
            val ax = e.values[0]
            val ay = e.values[1]
            val az = e.values[2]
            // 横着拿：重力主要在 x 轴；平放（z 主导）不算
            val landscape = kotlin.math.abs(ax) > 6f &&
                kotlin.math.abs(ax) > kotlin.math.abs(ay) &&
                kotlin.math.abs(ax) > kotlin.math.abs(az)
            val sign = if (ax > 0) 1 else -1
            if (landscape && sign == gravHoldSign) {
                if (!gravLandscape && SystemClock.elapsedRealtime() - gravSince > 1000) {
                    gravLandscape = true
                    gravSign = sign
                    L.i("gravity landscape, sign=$sign")
                }
            } else {
                gravSince = SystemClock.elapsedRealtime()
                gravHoldSign = if (landscape) sign else 0
                gravLandscape = false
            }
        }
        override fun onAccuracyChanged(s: Sensor?, a: Int) {}
    }

    /** 手机原始画面是否有黑边（与截取开关无关——截取后的侧画内容仍需转正） */
    private fun streamHasBars(): Boolean = latestDetected?.isFull() == false

    private fun gravityUpright(): Boolean =
        forcedCycle == 0 && gravLandscape && currentRotation() == 0 && streamHasBars()

    /** video header rotation byte: forced wins, else gravity upright, else 0 */
    private fun rotationField(): Int = when {
        forcedCycle != 0 -> forcedCycle
        // ax>0（左边朝下）时竖屏缓冲里的内容是顺时针转的，要逆时针转正 → 3
        gravityUpright() -> if (gravSign > 0) 3 else 1
        else -> 0
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
     * 依次尝试候选地址：上次连通地址优先，其次 mDNS 当前发现的地址
     *（发现的可能是 VPN/虚拟网卡地址）。只有 hello 成功的地址才回写存储。
     */
    private fun connectAndHello(d: PairedComputer, token: ByteArray, timeoutMs: Int): Pair<Conn?, String?> {
        val candidates = LinkedHashSet<Pair<String, Int>>()
        candidates.add(d.lastHost to d.lastPort)
        OnlineReceivers.map[d.receiverId]?.let { candidates.add(it.host to it.port) }
        var lastReason = "transport"
        for ((host, port) in candidates) {
            val r = tryHello(d, token, host, port, timeoutMs)
            if (r.first != null) {
                if (host != d.lastHost || port != d.lastPort) {
                    d.lastHost = host; d.lastPort = port
                    store.updateAddress(d.receiverId, host, port)
                }
                return r
            }
            lastReason = r.second ?: "transport"
            // 对方明确拒绝（busy/notPaired/…）时换地址重试没意义
            if (r.second != "transport") break
        }
        return null to lastReason
    }

    /**
     * Connect, send hello, wait for helloResult. The reader thread started here keeps running
     * for the life of the connection.
     * Returns (conn, null) on success, (null, "transport") on network failure,
     * or (null, reason) when the receiver rejected.
     */
    private fun tryHello(d: PairedComputer, token: ByteArray, host: String, port: Int, timeoutMs: Int): Pair<Conn?, String?> {
        val c = try {
            Conn(TlsClient.connect(host, port, d.fp(), timeoutMs))
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
                "rotate" -> cycleForceRotate()
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
        val (sw, sh) = targetSize()

        // Android 14+：同一 MediaProjection 只允许 createVirtualDisplay 一次，
        // VD + GL 桥整个会话只建一次；转屏走 resizeForRotation() 的 vd.resize()。
        var pipe = glPipe
        if (pipe == null || vd == null) {
            vdW = sw; vdH = sh
            pipe = GlPipe(sw, sh)
            pipe.sampleListener = object : GlPipe.SampleListener {
                override fun onSample(rgba: ByteArray, w: Int, h: Int) = onScreenSample(rgba, w, h)
            }
            glPipe = pipe
            val dm = DisplayMetrics()
            @Suppress("DEPRECATION")
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(dm)
            vd = projection?.createVirtualDisplay(
                "mp2tv", sw, sh, dm.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                pipe.inputSurface, null, handler
            )
            L.i("VD created ${vdW}x${vdH}")
        }

        // encoder dims = 内容区域 × VD 缓冲尺寸（裁剪比例作用在 VD 坐标系；
        // 不能用 targetSize——物理转屏后 VD 尺寸不变，会算出畸形尺寸）
        val crop = if (cropEnabled) appliedCrop else null
        var w = if (crop == null) vdW else (vdW * (crop.r - crop.l)).toInt()
        var h = if (crop == null) vdH else (vdH * (crop.b - crop.t)).toInt()
        w = maxOf(64, w / 2 * 2)
        h = maxOf(64, h / 2 * 2)
        L.i("capture screen=${sw}x$sh vd=${vdW}x$vdH enc=${w}x$h crop=$crop rot=$lastRotation")
        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 5)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_LATENCY, 0)
        }
        // 先建好新编码器再换旧的：start 失败保留旧管线，不至于断流/闪退
        val enc = try {
            MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).also {
                it.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
        } catch (e: Throwable) {
            L.i("encoder create/configure failed, keep old: $e")
            return
        }
        val encSurface = enc.createInputSurface()
        try {
            enc.start()
        } catch (e: Throwable) {
            L.i("encoder start failed, keep old: $e")
            try {
                enc.release()
            } catch (_: Throwable) {
            }
            return
        }
        stopEncoder()
        encoder = enc
        encW = w; encH = h
        pipe.setTarget(encSurface)
        if (crop != null) pipe.setCrop(crop.l, crop.t, crop.r, crop.b)
        else pipe.setCrop(0f, 0f, 1f, 1f)
        codecThread = Thread { drainEncoder(enc) }.also { it.start() }
        if (audioThread == null) startAudio()
    }

    /** 黑边检测回调（GL 线程）：稳定 ~1s 的新内容区域才会生效（重建编码器或仅换裁剪位） */
    private fun onScreenSample(rgba: ByteArray, w: Int, h: Int) {
        val r = ContentDetect.detect(rgba, w, h) ?: return // 暗场：保持现状
        latestDetected = r
        if (!cropEnabled) return
        // 退化矩形不采信（横屏信箱条带约占 18% 面积，阈值不能再高）
        if ((r.r - r.l) * (r.b - r.t) < 0.08f) return
        val pend = pendingRect
        if (pend != null && r.similar(pend)) pendingCount++
        else {
            pendingRect = r
            pendingCount = 1
        }
        val applied = appliedCrop
        val changed = if (applied == null) !r.isFull() else !applied.similar(r, 0.02f)
        if (changed && pendingCount >= 3 &&
            SystemClock.elapsedRealtime() - lastCropApply > 3000
        ) {
            L.i("content rect -> ${r.l},${r.t} ${r.r}x${r.b}")
            appliedCrop = r
            pendingCount = 0
            lastCropApply = SystemClock.elapsedRealtime()
            handler.post { applyCrop(r) }
        }
    }

    /** 新内容区域生效：尺寸不变只改 GL 裁剪位，尺寸变了才重建编码器 */
    @Synchronized
    private fun applyCrop(r: ContentDetect.Rect) {
        if (stopping || conn == null) return
        val nw = maxOf(64, (vdW * (r.r - r.l)).toInt() / 2 * 2)
        val nh = maxOf(64, (vdH * (r.b - r.t)).toInt() / 2 * 2)
        if (nw == encW && nh == encH) {
            glPipe?.setCrop(r.l, r.t, r.r, r.b)
        } else {
            rebuildCapture()
        }
    }

    @Synchronized
    private fun rebuildCapture() {
        if (stopping || conn == null) return
        L.i("rebuild capture")
        startCapture()
    }

    /**
     * 物理转屏后把 VD 和 SurfaceTexture 调到新方向尺寸再重建编码器：
     * Android 14+ 只禁止第二次 createVirtualDisplay，resize 是允许的。
     * 比信箱化进旧缓冲更好——不损失分辨率。
     */
    @Synchronized
    private fun resizeForRotation() {
        if (stopping || conn == null) return
        val (sw, sh) = targetSize()
        val v = vd
        if (v != null && (sw != vdW || sh != vdH)) {
            val dm = DisplayMetrics()
            @Suppress("DEPRECATION")
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(dm)
            try {
                v.resize(sw, sh, dm.densityDpi)
                glPipe?.resizeBuffer(sw, sh)
                vdW = sw; vdH = sh
                L.i("VD resized ${sw}x${sh}")
            } catch (e: Throwable) {
                L.i("VD resize failed: $e")
            }
        }
        rebuildCapture()
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
                            p[9] = rotationField().toByte() // 重力转正/强制旋转
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
                // 20ms 一包（原 100ms）：目标端到端延迟 100–200ms
                val chunk = ByteArray(3840)
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

    @Volatile
    private var dropUntilKey = false
    private var lastDropAt = 0L
    private var lastBumpAt = 0L

    private fun enqueue(type: Int, payload: ByteArray, isKey: Boolean) {
        if (conn == null || stopping) return
        // 拥塞丢帧后，后续 P 帧参考的是已丢的帧——一直丢到下一个关键帧
        if (dropUntilKey) {
            if (type == Proto.FRAME_VIDEO && !isKey) return
            if (type == Proto.FRAME_VIDEO) dropUntilKey = false
        }
        if (queue.offer(Triple(type, payload, isKey))) {
            // 队列有空闲：缓慢把码率调回去（协议约定"慢慢回升"）
            val now = SystemClock.elapsedRealtime()
            if (bitrate < 6_000_000 && now - lastDropAt > 5000 && now - lastBumpAt > 1000) {
                lastBumpAt = now
                bitrate = minOf(6_000_000, bitrate + bitrate / 8)
                try {
                    encoder?.setParameters(
                        Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate) }
                    )
                } catch (_: Throwable) {
                }
            }
            return
        }
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
        if (dropped > 0) {
            dropUntilKey = true
            lastDropAt = SystemClock.elapsedRealtime()
            requestKeyframe() // 尽快补关键帧，恢复接收端解码基线
            if (bitrate > 1_500_000) {
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

    /** 只停编码器（重建用）；VD + GlPipe 保持，避免重复 createVirtualDisplay */
    @Synchronized
    private fun stopEncoder() {
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
        audioThread = null
        stopEncoder()
        vd?.release()
        vd = null
        glPipe?.release()
        glPipe = null
    }

    private fun stopAll(reason: String?) {
        if (stopping) return
        stopping = true
        Thread {
            // 主线程写 socket 会抛 NetworkOnMainThreadException 被吞掉，
            // stop 帧发不出去（通知栏按钮、系统停止共享都走这条路）
            reason?.let {
                try {
                    conn?.sendControl(JSONObject().put("t", "stop").put("reason", it))
                } catch (_: Throwable) {
                }
            }
            SystemClock.sleep(150)
            conn?.close()
            conn = null
            stopCapture()
            projection?.stop()
            getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(rotationListener)
            // 恢复媒体音量、释放亮屏锁、摘传感器
            if (prevVolume >= 0) {
                try {
                    audioManager?.setStreamVolume(AudioManager.STREAM_MUSIC, prevVolume, 0)
                } catch (_: Throwable) {
                }
                prevVolume = -1
            }
            try {
                wakeLock?.release()
            } catch (_: Throwable) {
            }
            wakeLock = null
            try {
                sensorMgr?.unregisterListener(gravityListener)
            } catch (_: Throwable) {
            }
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
        if (prevVolume >= 0) {
            try {
                audioManager?.setStreamVolume(AudioManager.STREAM_MUSIC, prevVolume, 0)
            } catch (_: Throwable) {
            }
        }
        try {
            wakeLock?.release()
        } catch (_: Throwable) {
        }
        try {
            sensorMgr?.unregisterListener(gravityListener)
        } catch (_: Throwable) {
        }
        running = false
        super.onDestroy()
    }
}
