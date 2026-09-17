package com.mp2tv

import android.content.Context
import android.net.ConnectivityManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo

data class FoundReceiver(val id: String, val host: String, val port: Int)

class NsdDiscovery(
    ctx: Context,
    private val onFound: (FoundReceiver) -> Unit,
    private val onLost: (String) -> Unit
) {
    private val nsdm = ctx.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val byName = mutableMapOf<String, String>() // serviceName -> receiverId
    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        stop()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {}
            override fun onDiscoveryStopped(regType: String) {}
            override fun onStartDiscoveryFailed(regType: String, code: Int) {}
            override fun onStopDiscoveryFailed(regType: String, code: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                nsdm.resolveService(
                    info,
                    object : NsdManager.ResolveListener {
                        override fun onResolveFailed(i: NsdServiceInfo, code: Int) {}
                        override fun onServiceResolved(i: NsdServiceInfo) {
                            val id = txt(i, "id") ?: return
                            val host = i.hostAddresses?.firstOrNull()?.hostAddress
                                ?: @Suppress("DEPRECATION") i.host?.hostAddress
                                ?: return
                            byName[i.serviceName] = id
                            onFound(FoundReceiver(id, host, i.port))
                        }
                    }
                )
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                byName.remove(info.serviceName)?.let(onLost)
            }
        }
        listener = l
        nsdm.discoverServices("_mp2tv._tcp.", NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun stop() {
        listener?.let {
            try {
                nsdm.stopServiceDiscovery(it)
            } catch (_: Throwable) {
            }
        }
        listener = null
        byName.clear()
    }

    private fun txt(info: NsdServiceInfo, key: String): String? {
        val v = info.attributes[key] ?: return null
        return String(v, Charsets.UTF_8)
    }
}
