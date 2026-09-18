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

    /// 每 ~1/3s 喂一帧 96x54 亮度图。检测与截取开关无关——截取关着也跑检测
    ///（重力转正的"流里有黑边"判断的是手机原始画面，不是输出流）。
    func feed(_ lum: [UInt8], w: Int, h: Int) {
        guard let r = ContentDetect.detect(lum, w: w, h: h) else { return } // 暗场保持
        streamHasBars = r.hasBars
        guard on else {
            cand = nil; candCount = 0
            if cur != nil { cur = nil; apply(nil) }
            return
        }
        let target: ContentDetect.Rect? = r.isFull ? nil : r
        // 全屏（nil）也是合法候选：连续三次全屏要能把 cur 归位，
        // 否则 nil 候选每次都重置计数、永远回不到全屏
        if (target == nil) == (cand == nil) && (target == nil || target!.similar(cand!)) {
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
