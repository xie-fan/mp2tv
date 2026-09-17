import CoreGraphics
import Foundation

/// 智能截取防抖：亮度图 -> 内容区域 -> 稳定 ~1s 才回调 apply。
/// App（Engine）与录屏扩展（SampleHandler）共用。
final class CropCtl {

    var on = true
    /// 当前流里是否有黑边（重力转正条件③）
    private(set) var streamHasBars = false
    /// 稳定后的新裁剪矩形回调（nil = 恢复全屏）
    var apply: (CGRect?) -> Void = { _ in }

    private var cand: ContentDetect.Rect?
    private var candCount = 0
    private var cur: CGRect?

    /// 每 ~1/3s 喂一帧 96x54 亮度图
    func feed(_ lum: [UInt8], w: Int, h: Int) {
        guard on else {
            streamHasBars = false
            if cur != nil { cur = nil; apply(nil) }
            return
        }
        guard let r = ContentDetect.detect(lum, w: w, h: h) else { return } // 暗场保持
        streamHasBars = r.hasBars
        let target: ContentDetect.Rect? = r.isFull ? nil : r
        if let t = target, let c = cand, t.similar(c) {
            candCount += 1
        } else {
            cand = target; candCount = 1
        }
        if candCount >= 3 {
            candCount = 0
            let cg = cand?.cg
            if (cg == nil) != (cur == nil) || cg != cur {
                cur = cg
                apply(cg)
            }
        }
    }

    func reset() {
        cand = nil; candCount = 0; cur = nil; streamHasBars = false
    }
}
