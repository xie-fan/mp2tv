package com.mp2tv

import android.util.Base64
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

object TlsClient {
    /** Connect and pin the server cert by its SHA-256 (DER) fingerprint. */
    fun connect(host: String, port: Int, fp: ByteArray, timeoutMs: Int = 5000): SSLSocket {
        val tm = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}

            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val der = chain?.firstOrNull()?.encoded ?: throw CertificateException("no cert")
                val actual = MessageDigest.getInstance("SHA-256").digest(der)
                if (!actual.contentEquals(fp)) throw CertificateException("fingerprint mismatch")
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(null, arrayOf(tm), SecureRandom())
        val sock = ctx.socketFactory.createSocket() as SSLSocket
        sock.connect(InetSocketAddress(host, port), timeoutMs)
        sock.startHandshake()
        return sock
    }

    fun fpFromBase64Url(s: String): ByteArray = Base64.decode(s, Base64.URL_SAFE or Base64.NO_WRAP)
}
