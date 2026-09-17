package com.mp2tv

import android.Manifest
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import org.json.JSONObject

class MainActivity : ComponentActivity() {
    private lateinit var store: PairedStore
    private var devices = mutableListOf<PairedComputer>()
    private val online = mutableMapOf<String, FoundReceiver>()
    private lateinit var adapter: DevAdapter
    private lateinit var statusText: TextView
    private var nsd: NsdDiscovery? = null
    private var pendingMirror: PairedComputer? = null

    private val scanLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { refresh() }
    private val cameraPermLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scanLauncher.launch(Intent(this, PairingActivity::class.java))
        else toast("需要相机权限扫码配对")
    }
    private val notifPermLauncher = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }
    private val mirrorPermLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        if (res[Manifest.permission.RECORD_AUDIO] != true) {
            toast("需要麦克风权限才能采集系统声音")
            return@registerForActivityResult
        }
        launchProjection()
    }
    private val projectionLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        val dev = pendingMirror
        if (r.resultCode != RESULT_OK || r.data == null || dev == null) {
            statusText.text = "已取消"
            return@registerForActivityResult
        }
        MirrorService.start(this, r.resultCode, r.data!!, dev)
        statusText.text = "投屏中：${dev.name}"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        L.init(applicationContext)
        store = PairedStore(this)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(8))
        }
        root.addView(TextView(this).apply {
            text = "mp2tv"
            textSize = 22f
            setTypeface(Typeface.DEFAULT_BOLD)
        })
        statusText = TextView(this).apply { textSize = 14f }
        root.addView(statusText)
        root.addView(Button(this).apply {
            text = "扫码配对"
            setOnClickListener { startScan() }
        })
        root.addView(TextView(this).apply {
            text = "已配对电脑（点按开始投屏，长按管理）"
            textSize = 13f
            setPadding(0, dp(12), 0, dp(4))
        })
        adapter = DevAdapter()
        root.addView(ListView(this).apply {
            adapter = this@MainActivity.adapter
            setOnItemClickListener { _, _, pos, _ -> onDeviceClick(devices[pos]) }
            setOnItemLongClickListener { _, _, pos, _ -> onDeviceLongClick(devices[pos]); true }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        // 设置：智能截取默认开关 + 导出日志
        val prefs = getSharedPreferences("mp2tv", Context.MODE_PRIVATE)
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(android.widget.CheckBox(this@MainActivity).apply {
                text = "智能截取（默认开）"
                isChecked = prefs.getBoolean("smartCrop", true)
                setOnCheckedChangeListener { _, on -> prefs.edit().putBoolean("smartCrop", on).apply() }
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(Button(this@MainActivity).apply {
                text = "导出日志"
                setOnClickListener { exportLog() }
            })
        })
        setContentView(root)

        MirrorService.listener = { msg -> runOnUiThread { statusText.text = msg; refresh() } }
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notifPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    override fun onResume() {
        super.onResume()
        refresh()
        nsd = NsdDiscovery(
            this,
            onFound = { r -> runOnUiThread { online[r.id] = r; store.updateAddress(r.id, r.host, r.port); refresh() } },
            onLost = { id -> runOnUiThread { online.remove(id); refresh() } }
        ).also { it.start() }
    }

    override fun onPause() {
        nsd?.stop()
        nsd = null
        super.onPause()
    }

    private fun refresh() {
        devices = store.list().toMutableList()
        adapter.notifyDataSetChanged()
    }

    private fun startScan() {
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            scanLauncher.launch(Intent(this, PairingActivity::class.java))
        } else {
            cameraPermLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    private fun onDeviceClick(d: PairedComputer) {
        if (MirrorService.running) {
            toast("正在投屏，请先停止")
            return
        }
        if (d.invalid) {
            toast("电脑已解除配对，请重新扫码")
            return
        }
        if (online[d.receiverId] == null) {
            toast("电脑不在线")
            return
        }
        pendingMirror = d
        val need = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) need.add(Manifest.permission.POST_NOTIFICATIONS)
        val missing = need.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) launchProjection()
        else mirrorPermLauncher.launch(missing.toTypedArray())
    }

    private fun launchProjection() {
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val intent = if (Build.VERSION.SDK_INT >= 34) {
            mpm.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            @Suppress("DEPRECATION")
            mpm.createScreenCaptureIntent()
        }
        projectionLauncher.launch(intent)
    }

    private fun onDeviceLongClick(d: PairedComputer) {
        AlertDialog.Builder(this)
            .setTitle(d.name)
            .setItems(arrayOf("改名", "解除配对", "取消")) { _, which ->
                when (which) {
                    0 -> rename(d)
                    1 -> unpair(d)
                }
            }
            .show()
    }

    private fun rename(d: PairedComputer) {
        val et = EditText(this).apply { setText(d.name) }
        AlertDialog.Builder(this)
            .setTitle("改名")
            .setView(et)
            .setPositiveButton("确定") { _, _ ->
                d.name = et.text.toString().ifBlank { d.name }
                store.upsert(d)
                refresh()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun unpair(d: PairedComputer) {
        AlertDialog.Builder(this)
            .setMessage("解除与 ${d.name} 的配对？")
            .setPositiveButton("解除") { _, _ ->
                val f = online[d.receiverId]
                if (f != null) {
                    Thread {
                        try {
                            val token = store.token(d.receiverId)
                            if (token != null) {
                                val sock = TlsClient.connect(f.host, f.port, d.fp())
                                val conn = Conn(sock)
                                conn.sendControl(
                                    JSONObject().put("t", "unpair")
                                        .put("senderId", senderId()).put("token", b64url(token))
                                )
                                Thread.sleep(300)
                                conn.close()
                            }
                        } catch (e: Throwable) {
                            L.i("unpair notify failed: $e")
                        }
                    }.start()
                }
                store.remove(d.receiverId)
                refresh()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun exportLog() {
        val f = L.file()
        if (f == null || !f.exists()) {
            toast("暂无日志")
            return
        }
        Thread {
            try {
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Downloads.DISPLAY_NAME, "mp2tv-log.txt")
                    put(android.provider.MediaStore.Downloads.MIME_TYPE, "text/plain")
                }
                val uri = contentResolver.insert(
                    android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
                )
                contentResolver.openOutputStream(uri!!)?.use { it.write(f.readBytes()) }
                runOnUiThread { toast("已导出到 下载/mp2tv-log.txt") }
            } catch (e: Throwable) {
                L.i("export log failed: $e")
                runOnUiThread { toast("导出失败") }
            }
        }.start()
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    private inner class DevAdapter : BaseAdapter() {
        override fun getCount() = devices.size
        override fun getItem(p: Int) = devices[p]
        override fun getItemId(p: Int) = p.toLong()
        override fun getView(p: Int, cv: View?, parent: ViewGroup?): View {
            val d = devices[p]
            val ll = (cv as? LinearLayout) ?: LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(8), 0, dp(8))
                addView(TextView(this@MainActivity).apply { textSize = 16f })
                addView(TextView(this@MainActivity).apply { textSize = 12f })
            }
            val on = online[d.receiverId]
            (ll.getChildAt(0) as TextView).text = if (d.invalid) "${d.name}（已失效）" else d.name
            (ll.getChildAt(1) as TextView).text =
                if (on != null) "在线 · ${on.host}:${on.port}" else "离线 · ${d.lastHost}"
            return ll
        }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    companion object {
        fun b64url(b: ByteArray) =
            android.util.Base64.encodeToString(b, android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP)
    }
}

private var senderIdCache: String? = null
fun senderId(): String {
    senderIdCache?.let { return it }
    val ctx = App.ctx
    val p = ctx.getSharedPreferences("mp2tv", Context.MODE_PRIVATE)
    var id = p.getString("senderId", null)
    if (id == null) {
        id = java.util.UUID.randomUUID().toString()
        p.edit().putString("senderId", id).apply()
    }
    senderIdCache = id
    return id
}
