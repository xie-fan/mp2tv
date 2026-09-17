package com.mp2tv

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object L {
    private var file: File? = null
    private val fmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    fun init(ctx: Context) {
        if (file == null) file = File(ctx.filesDir, "mp2tv.log")
    }

    @Synchronized
    fun i(msg: String) {
        Log.i("mp2tv", msg)
        try {
            file?.appendText("[${fmt.format(Date())}] $msg\n")
        } catch (_: Throwable) {
        }
    }

    fun file(): File? = file
}
