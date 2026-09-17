package com.mp2tv

import android.app.Application

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        ctx = this
        L.init(this)
    }

    companion object {
        lateinit var ctx: android.content.Context
            private set
    }
}
