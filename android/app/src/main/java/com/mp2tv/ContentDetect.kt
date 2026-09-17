package com.mp2tv

/**
 * Content-area detection from a small RGBA readback of the whole screen.
 *
 * Rules (spec §5 智能截取):
 * - only near-black borders are stripped;
 * - sparse subtitles/controls inside the border do not count as content;
 * - a nearly-all-black frame keeps the previous area (caller handles that by
 *   getting null back);
 * - callers debounce: apply a new rect only after it stays stable ~1s.
 */
object ContentDetect {

    /** Normalized rect, or null when the scene is too dark to measure. */
    class Rect(var l: Float, var t: Float, var r: Float, var b: Float) {
        fun isFull() = r - l > 0.98f && b - t > 0.98f
        fun similar(o: Rect, tol: Float = 0.05f) =
            kotlin.math.abs(l - o.l) < tol && kotlin.math.abs(t - o.t) < tol &&
                kotlin.math.abs(r - o.r) < tol && kotlin.math.abs(b - o.b) < tol
    }

    private const val LUMA_ON = 24       // pixel counts as lit
    private const val ROW_COL_ON = 0.12f // fraction of lit px to count a row/col as content
    private const val DARK_MEAN = 8f     // whole-frame mean below this = dark scene

    fun detect(rgba: ByteArray, w: Int, h: Int): Rect? {
        val colLit = IntArray(w)
        val rowLit = IntArray(h)
        var sum = 0L
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = (y * w + x) * 4
                val lum = (rgba[i].toInt() and 0xff) * 2 +
                    (rgba[i + 1].toInt() and 0xff) * 4 +
                    (rgba[i + 2].toInt() and 0xff)
                sum += lum / 7
                if (lum / 7 > LUMA_ON) {
                    colLit[x]++
                    rowLit[y]++
                }
            }
        }
        if (sum / (w * h) < DARK_MEAN) return null // dark scene: keep previous

        var l = 0
        while (l < w && colLit[l] < h * ROW_COL_ON) l++
        var r = w
        while (r > l && colLit[r - 1] < h * ROW_COL_ON) r--
        var t = 0
        while (t < h && rowLit[t] < w * ROW_COL_ON) t++
        var b = h
        while (b > t && rowLit[b - 1] < w * ROW_COL_ON) b--
        if (r - l < w / 8 || b - t < h / 8) return null // degenerate: treat as dark
        return Rect(l.toFloat() / w, t.toFloat() / h, r.toFloat() / w, b.toFloat() / h)
    }
}
