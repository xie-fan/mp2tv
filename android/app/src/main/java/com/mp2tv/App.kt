package com.mp2tv

import android.app.Application

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        ctx = this
        L.init(this)
        // 未捕获异常写进日志文件，"导出日志"可拿到崩溃栈
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                L.i("CRASH ${t.name}: ${e.stackTraceToString()}")
            } catch (_: Throwable) {
            }
            prev?.uncaughtException(t, e)
        }
    }

    companion object {
        lateinit var ctx: android.content.Context
            private set
    }
}
