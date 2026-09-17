package com.mp2tv

import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.util.Base64
import android.util.Size
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import org.json.JSONObject
import java.util.concurrent.Executors

class PairingActivity : ComponentActivity() {
    private lateinit var status: TextView
    private var handling = false
    private val io = Executors.newSingleThreadExecutor()
    private val analysisExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = FrameLayout(this)
        val preview = PreviewView(this)
        root.addView(preview, FrameLayout.LayoutParams(-1, -1))
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 15f
            gravity = Gravity.CENTER
            text = "对准电脑上的二维码"
            setPadding(0, 0, 0, 40)
        }
        root.addView(
            status,
            FrameLayout.LayoutParams(-1, -2).apply { gravity = Gravity.BOTTOM }
        )
        setContentView(root)

        ProcessCameraProvider.getInstance(this).addListener({
            val provider = ProcessCameraProvider.getInstance(this).get()
            val p = Preview.Builder().build().also {
                it.surfaceProvider = preview.surfaceProvider
            }
            val analysis = ImageAnalysis.Builder()
                .setTargetResolution(Size(1280, 720))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
            val scanner = BarcodeScanning.getClient()
            analysis.setAnalyzer(analysisExecutor) { proxy ->
                val media = proxy.image
                if (media == null || handling) {
                    proxy.close()
                    return@setAnalyzer
                }
                @Suppress("UnsafeOptInUsageError")
                val img = InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees)
                scanner.process(img)
                    .addOnSuccessListener { codes ->
                        val qr = codes.firstOrNull { it.format == Barcode.FORMAT_QR_CODE }?.rawValue
                        if (qr != null && qr.startsWith("mp2tv://pair")) {
                            handling = true
                            doPair(qr)
                        }
                    }
                    .addOnCompleteListener { proxy.close() }
            }
            provider.unbindAll()
            provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, p, analysis)
        }, androidx.core.content.ContextCompat.getMainExecutor(this))
    }

    private fun setStatus(s: String) = runOnUiThread { status.text = s }

    private fun doPair(qr: String) {
        io.execute {
            try {
                val u = Uri.parse(qr)
                val v = u.getQueryParameter("v")?.toIntOrNull()
                if (v != Proto.VERSION) return@execute fail("二维码版本不支持 (v=$v)")
                val hosts = u.getQueryParameter("h")?.split(",")?.filter { it.isNotBlank() }.orEmpty()
                val port = u.getQueryParameter("p")?.toIntOrNull()
                val fp = u.getQueryParameter("fp")
                val code = u.getQueryParameter("c")
                val name = u.getQueryParameter("n") ?: "电脑"
                if (hosts.isEmpty() || port == null || fp == null || code == null) {
                    return@execute fail("二维码内容不完整")
                }
                val fpBytes = TlsClient.fpFromBase64Url(fp)

                var lastErr = "无法连接"
                for (h in hosts) {
                    setStatus("连接 $h:$port …")
                    try {
                        val r = tryPair(h, port, fpBytes, code)
                        if (r != null) {
                            if (r.optBoolean("ok")) {
                                finishOk(
                                    r.getString("receiverId"),
                                    r.optString("receiverName", name),
                                    h, port, fp,
                                    Base64.decode(r.getString("token"), Base64.URL_SAFE or Base64.NO_WRAP)
                                )
                                return@execute
                            }
                            lastErr = reason(r.optString("reason"))
                            break
                        }
                    } catch (e: Throwable) {
                        L.i("pair to $h failed: $e")
                        lastErr = "连接失败"
                    }
                }
                fail(lastErr)
            } catch (e: Throwable) {
                L.i("pair error: $e")
                fail("配对失败: ${e.message}")
            }
        }
    }

    private fun reason(r: String) = when (r) {
        "codeInvalid" -> "配对码无效、已过期或已使用"
        "versionMismatch" -> "协议版本不匹配，请升级"
        else -> "配对被拒绝: $r"
    }

    private fun tryPair(host: String, port: Int, fp: ByteArray, codeB64url: String): JSONObject? {
        val sock = TlsClient.connect(host, port, fp, 3000)
        try {
            val conn = Conn(sock)
            val result = java.util.concurrent.ArrayBlockingQueue<JSONObject>(1)
            val err = java.util.concurrent.ArrayBlockingQueue<Throwable>(1)
            Thread {
                conn.readLoop(object : Conn.Listener {
                    override fun onControl(msg: JSONObject) = result.offer(msg).let {}
                    override fun onFrame(t: Int, p: ByteArray) {}
                    override fun onClosed(e: Throwable?) = err.offer(e ?: Exception("closed")).let {}
                })
            }.start()
            conn.sendControl(
                JSONObject()
                    .put("t", "pair").put("v", Proto.VERSION)
                    .put("senderId", senderId())
                    .put("senderName", android.os.Build.MODEL ?: "android")
                    .put("platform", "android")
                    .put("code", codeB64url)
            )
            val r = result.poll(5, java.util.concurrent.TimeUnit.SECONDS)
            val e = err.poll(0, java.util.concurrent.TimeUnit.MILLISECONDS)
            if (r == null) throw e ?: Exception("timeout")
            return r.takeIf { it.optString("t") == "pairResult" }
        } finally {
            sock.close()
        }
    }

    private fun finishOk(receiverId: String, name: String, host: String, port: Int, fpB64: String, token: ByteArray) {
        val st = PairedStore(this)
        st.upsert(PairedComputer(receiverId, name, host, port, fpB64))
        st.saveToken(receiverId, token)
        runOnUiThread {
            Toast.makeText(this, "已配对 $name", Toast.LENGTH_LONG).show()
            finish()
        }
    }

    private fun fail(msg: String) {
        runOnUiThread {
            status.text = "$msg\n（对准二维码重试）"
            status.postDelayed({ handling = false }, 1200)
        }
    }

    override fun onDestroy() {
        io.shutdownNow()
        analysisExecutor.shutdownNow()
        super.onDestroy()
    }
}
