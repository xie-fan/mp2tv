package com.mp2tv

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class PairedComputer(
    val receiverId: String,
    var name: String,
    var lastHost: String,
    var lastPort: Int,
    val fpB64: String,
    var invalid: Boolean = false
) {
    fun fp(): ByteArray = TlsClient.fpFromBase64Url(fpB64)
}

class PairedStore(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("mp2tv", Context.MODE_PRIVATE)

    fun list(): List<PairedComputer> {
        val arr = JSONArray(prefs.getString("devices", "[]"))
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            PairedComputer(
                o.getString("id"), o.getString("name"),
                o.optString("host"), o.optInt("port"), o.getString("fp"),
                o.optBoolean("inv")
            )
        }
    }

    private fun save(list: List<PairedComputer>) {
        val arr = JSONArray()
        for (d in list) {
            arr.put(
                JSONObject()
                    .put("id", d.receiverId).put("name", d.name)
                    .put("host", d.lastHost).put("port", d.lastPort).put("fp", d.fpB64)
                    .put("inv", d.invalid)
            )
        }
        prefs.edit().putString("devices", arr.toString()).apply()
    }

    fun upsert(d: PairedComputer) {
        save(list().filter { it.receiverId != d.receiverId } + d)
    }

    fun remove(receiverId: String) {
        save(list().filter { it.receiverId != receiverId })
        prefs.edit().remove("tok_$receiverId").apply()
    }

    fun updateAddress(receiverId: String, host: String, port: Int) {
        val l = list()
        l.find { it.receiverId == receiverId }?.let {
            it.lastHost = host
            it.lastPort = port
            save(l)
        }
    }

    // ---- token: AES/GCM encrypted with an AndroidKeyStore key ----

    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry("mp2tv_token", null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val kg = KeyGenerator.getInstance("AES", "AndroidKeyStore")
        kg.init(
            android.security.keystore.KeyGenParameterSpec.Builder(
                "mp2tv_token",
                android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return kg.generateKey()
    }

    fun saveToken(receiverId: String, token: ByteArray) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, secretKey())
        val ct = c.doFinal(token)
        prefs.edit().putString("tok_$receiverId", Base64.encodeToString(c.iv + ct, Base64.NO_WRAP)).apply()
    }

    fun token(receiverId: String): ByteArray? {
        val s = prefs.getString("tok_$receiverId", null) ?: return null
        return try {
            val raw = Base64.decode(s, Base64.NO_WRAP)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, raw.copyOfRange(0, 12)))
            c.doFinal(raw.copyOfRange(12, raw.size))
        } catch (e: Throwable) {
            null
        }
    }
}
