import Foundation

/// 内容区域检测（Android ContentDetect 的 Swift 移植，阈值一致）。
/// 输入 96x54 亮度图；返回归一化内容矩形；暗场返回 nil（保持现状）。
enum ContentDetect {

    struct Rect {
        var l: Float, t: Float, r: Float, b: Float
        var isFull: Bool { r - l > 0.98 && b - t > 0.98 }
        var hasBars: Bool { !isFull }
        func similar(_ o: Rect, tol: Float = 0.05) -> Bool {
            abs(l - o.l) < tol && abs(t - o.t) < tol && abs(r - o.r) < tol && abs(b - o.b) < tol
        }
        var cg: CGRect { CGRect(x: CGFloat(l), y: CGFloat(t),
                                width: CGFloat(r - l), height: CGFloat(b - t)) }
    }

    private static let lumaOn: Int = 24      // 点亮阈值
    private static let rowColOn = 0.12       // 行/列点亮比例阈值
    private static let darkMean: Int = 8     // 整帧均值低于此 = 暗场

    static func detect(_ lum: [UInt8], w: Int, h: Int) -> Rect? {
        var colLit = [Int](repeating: 0, count: w)
        var rowLit = [Int](repeating: 0, count: h)
        var sum = 0
        for y in 0..<h {
            for x in 0..<w {
                let v = Int(lum[y * w + x])
                sum += v
                if v > lumaOn { colLit[x] += 1; rowLit[y] += 1 }
            }
        }
        if sum / (w * h) < darkMean { return nil }
        var l = 0; while l < w && Double(colLit[l]) < Double(h) * rowColOn { l += 1 }
        var r = w; while r > l && Double(colLit[r - 1]) < Double(h) * rowColOn { r -= 1 }
        var t = 0; while t < h && Double(rowLit[t]) < Double(w) * rowColOn { t += 1 }
        var b = h; while b > t && Double(rowLit[b - 1]) < Double(w) * rowColOn { b -= 1 }
        if r - l < w / 8 || b - t < h / 8 { return nil }
        return Rect(l: Float(l) / Float(w), t: Float(t) / Float(h),
                    r: Float(r) / Float(w), b: Float(b) / Float(h))
    }
}
