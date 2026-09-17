package com.mp2tv

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * GPU bridge: VirtualDisplay -> SurfaceTexture (OES) -> encoder input Surface.
 * Each incoming frame is drawn through an OES texture; a normalized crop rect
 * selects which part of the source reaches the encoder. A periodic 96x54
 * readback feeds the content-area detector.
 */
class GlPipe(outSurface: Surface, srcW: Int, srcH: Int) {

    interface SampleListener {
        fun onSample(rgba: ByteArray, w: Int, h: Int)
    }

    @Volatile var cropL = 0f
    @Volatile var cropT = 0f
    @Volatile var cropR = 1f
    @Volatile var cropB = 1f
    @Volatile var sampleListener: SampleListener? = null
    @Volatile var sampleEvery = 20 // render a small readback every N frames

    val inputSurface: Surface

    private val thread = HandlerThread("mp2tv-gl").apply { start() }
    private val h = Handler(thread.looper)
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var prog = 0
    private var aPos = -1
    private var aTex = -1
    private var uMtx = -1
    private var uCrop = -1
    private var texId = -1
    private var smallTex = -1
    private var fbo = -1
    private var st: SurfaceTexture? = null
    private val texMtx = FloatArray(16)
    private val frameReady = java.util.concurrent.atomic.AtomicBoolean(false)
    private var frameCount = 0
    private var closed = false

    private val quad = floatBufferOf(
        -1f, -1f, 0f, 0f,
        1f, -1f, 1f, 0f,
        -1f, 1f, 0f, 1f,
        1f, 1f, 1f, 1f
    )
    private val sampleBuf = ByteBuffer.allocateDirect(SAMPLE_W * SAMPLE_H * 4)

    init {
        // EGL init must happen on the GL thread
        val latch = CountDownLatch(1)
        var surf: Surface? = null
        h.post {
            eglInit(outSurface)
            st = SurfaceTexture(texId).also { t ->
                t.setDefaultBufferSize(srcW, srcH)
                t.setOnFrameAvailableListener({ frameReady.set(true) }, h)
            }
            surf = Surface(st)
            latch.countDown()
        }
        latch.await(5, TimeUnit.SECONDS)
        inputSurface = surf!!
        // render pump
        h.post { pump() }
    }

    fun setCrop(l: Float, t: Float, r: Float, b: Float) {
        cropL = l; cropT = t; cropR = r; cropB = b
    }

    fun release() {
        closed = true
        h.post {
            try {
                st?.release()
                if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
                if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
                if (eglDisplay != EGL14.EGL_NO_DISPLAY) EGL14.eglTerminate(eglDisplay)
            } catch (_: Throwable) {
            }
            thread.quitSafely()
        }
    }

    private fun pump() {
        if (closed) return
        if (frameReady.compareAndSet(true, false)) {
            draw()
        }
        h.postDelayed({ pump() }, 2)
    }

    private fun draw() {
        val t = st ?: return
        try {
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
            t.updateTexImage()
            t.getTransformMatrix(texMtx)
            GLES20.glViewport(0, 0, outW0, outH0)
            drawQuad(texMtx, cropL, cropT, cropR, cropB)
            EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, t.timestamp)
            EGL14.eglSwapBuffers(eglDisplay, eglSurface)
            if (++frameCount % sampleEvery == 0) sampleDown()
        } catch (_: Throwable) {
        }
    }

    private var outW0 = 0
    private var outH0 = 0

    private fun eglInit(out: Surface) {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val ver = IntArray(2)
        EGL14.eglInitialize(eglDisplay, ver, 0, ver, 1)
        val cfgAttrs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8, EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT, EGL14.EGL_NONE
        )
        val cfgs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, cfgAttrs, 0, cfgs, 0, 1, n, 0)
        eglContext = EGL14.eglCreateContext(
            eglDisplay, cfgs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0
        )
        eglSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, cfgs[0], out, intArrayOf(EGL14.EGL_NONE), 0
        )
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        val dim = IntArray(2)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_WIDTH, dim, 0)
        EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_HEIGHT, dim, 1)
        outW0 = dim[0]; outH0 = dim[1]

        prog = buildProg(VS, FS)
        aPos = GLES20.glGetAttribLocation(prog, "aPos")
        aTex = GLES20.glGetAttribLocation(prog, "aTex")
        uMtx = GLES20.glGetUniformLocation(prog, "uMtx")
        uCrop = GLES20.glGetUniformLocation(prog, "uCrop")

        val t = IntArray(2)
        GLES20.glGenTextures(2, t, 0)
        texId = t[0]
        smallTex = t[1]
        val fb = IntArray(1)
        GLES20.glGenFramebuffers(1, fb, 0)
        fbo = fb[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, smallTex)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, SAMPLE_W, SAMPLE_H, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null
        )
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
    }

    private fun drawQuad(mtx: FloatArray, l: Float, t: Float, r: Float, b: Float) {
        GLES20.glUseProgram(prog)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES20.glUniformMatrix4fv(uMtx, 1, false, mtx, 0)
        GLES20.glUniform4f(uCrop, l, t, r - l, b - t)
        quad.position(0)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(aPos)
        quad.position(2)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(aTex)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(aPos)
        GLES20.glDisableVertexAttribArray(aTex)
    }

    private fun sampleDown() {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, smallTex, 0
        )
        GLES20.glViewport(0, 0, SAMPLE_W, SAMPLE_H)
        drawQuad(texMtx, 0f, 0f, 1f, 1f) // full frame, uncropped
        sampleBuf.clear()
        GLES20.glReadPixels(0, 0, SAMPLE_W, SAMPLE_H, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, sampleBuf)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        val b = ByteArray(sampleBuf.remaining())
        sampleBuf.get(b)
        sampleListener?.onSample(b, SAMPLE_W, SAMPLE_H)
    }

    private fun buildProg(vs: String, fs: String): Int {
        fun sh(type: Int, src: String): Int {
            val s = GLES20.glCreateShader(type)
            GLES20.glShaderSource(s, src)
            GLES20.glCompileShader(s)
            return s
        }
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, sh(GLES20.GL_VERTEX_SHADER, vs))
        GLES20.glAttachShader(p, sh(GLES20.GL_FRAGMENT_SHADER, fs))
        GLES20.glLinkProgram(p)
        return p
    }

    private fun floatBufferOf(vararg v: Float): FloatBuffer =
        ByteBuffer.allocateDirect(v.size * 4).order(ByteOrder.nativeOrder())
            .asFloatBuffer().apply { put(v); position(0) }

    companion object {
        const val SAMPLE_W = 96
        const val SAMPLE_H = 54
        private const val VS =
            "uniform mat4 uMtx;uniform vec4 uCrop;" +
                "attribute vec4 aPos;attribute vec4 aTex;varying vec2 vTex;" +
                "void main(){gl_Position=aPos;" +
                "vTex=(uMtx*vec4(uCrop.xy+aTex.xy*uCrop.zw,0.,1.)).xy;}"
        private const val FS =
            "#extension GL_OES_EGL_image_external : require\n" +
                "precision mediump float;varying vec2 vTex;" +
                "uniform samplerExternalOES sTex;" +
                "void main(){gl_FragColor=texture2D(sTex,vTex);}"
    }
}
