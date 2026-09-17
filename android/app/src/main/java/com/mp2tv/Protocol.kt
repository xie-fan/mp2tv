package com.mp2tv

import org.json.JSONObject
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket

object Proto {
    const val FRAME_CONTROL = 1
    const val FRAME_VIDEO = 2
    const val FRAME_AUDIO = 3
    const val VERSION = 1
    const val MAX_PAYLOAD = 8 * 1024 * 1024
}

/** One TLS connection: blocking framed IO. Read via readLoop on a thread. */
class Conn(private val sock: Socket) {
    private val out: OutputStream = sock.getOutputStream()
    private val inp: InputStream = sock.getInputStream()
    private val writeLock = Any()

    fun sendControl(obj: JSONObject) = sendFrame(Proto.FRAME_CONTROL, obj.toString().toByteArray(Charsets.UTF_8))

    fun sendFrame(type: Int, payload: ByteArray) {
        val head = ByteArray(5)
        head[0] = type.toByte()
        head[1] = (payload.size ushr 24).toByte()
        head[2] = (payload.size ushr 16).toByte()
        head[3] = (payload.size ushr 8).toByte()
        head[4] = payload.size.toByte()
        synchronized(writeLock) {
            out.write(head)
            out.write(payload)
        }
    }

    fun close() {
        try {
            sock.close()
        } catch (_: Throwable) {
        }
    }

    interface Listener {
        fun onControl(msg: JSONObject)
        fun onFrame(type: Int, payload: ByteArray)
        fun onClosed(e: Throwable?)
    }

    /** Blocking; run on a dedicated thread. Calls listener.onClosed when the stream ends. */
    fun readLoop(l: Listener) {
        try {
            val head = ByteArray(5)
            while (true) {
                readFully(inp, head)
                val type = head[0].toInt()
                val len = ((head[1].toInt() and 0xff) shl 24) or
                    ((head[2].toInt() and 0xff) shl 16) or
                    ((head[3].toInt() and 0xff) shl 8) or
                    (head[4].toInt() and 0xff)
                if (len > Proto.MAX_PAYLOAD) throw IllegalStateException("frame too large: $len")
                val payload = ByteArray(len)
                readFully(inp, payload)
                if (type == Proto.FRAME_CONTROL) l.onControl(JSONObject(String(payload, Charsets.UTF_8)))
                else l.onFrame(type, payload)
            }
        } catch (e: Throwable) {
            l.onClosed(if (e is EOFException) null else e)
        }
    }

    private fun readFully(inp: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = inp.read(buf, off, buf.size - off)
            if (n < 0) throw EOFException()
            off += n
        }
    }
}
