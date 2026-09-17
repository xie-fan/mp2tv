import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// 采集管线（iOS 27+）：ScreenCaptureKit -> (智能截取) -> VTEnc -> Annex B AU
/// 声音：SCK audio -> PcmConv -> 48k s16le stereo
/// 编码器/音频转换/亮度采样/裁剪渲染均在 shared/，与录屏扩展共用。
@available(iOS 27.0, *)
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {

    var onAU: (_ au: Data, _ ptsUs: UInt64, _ key: Bool) -> Void = { _, _, _ in }
    var onPCM: (_ pcm: Data, _ ptsUs: UInt64) -> Void = { _, _ in }
    var onError: (Error) -> Void = { _ in }
    /// 每 20 帧给截取检测器一份 96x54 亮度图
    var onSample: (_ lum: [UInt8], _ w: Int, _ h: Int) -> Void = { _, _, _ in }

    private var stream: SCStream?
    private let enc = VTEnc()
    private let conv = PcmConv()
    private let ci = CIContext()
    private var pool: CVPixelBufferPool?
    private var frameCount = 0
    private let q = DispatchQueue(label: "mp2tv.cap", qos: .userInteractive)
    /// 编码器当前使用的归一化裁剪矩形（nil = 全屏）
    private(set) var cropRect: CGRect?
    /// 采集源尺寸（SCK 配置的实际宽高）
    private(set) var srcW = 0
    private(set) var srcH = 0

    // ---------- ScreenCaptureKit ----------

    /// 用户在选择器里选了内容后由 Engine 调进来
    func begin(with filter: SCContentFilter) async throws {
        let cfg = SCStreamConfiguration()
        let size = filter.pointSize
        // 长边<=1920 短边<=1080（protocol §媒体参数）
        let scale = min(1920 / max(size.width, size.height), 1080 / min(size.width, size.height), 1)
        cfg.width = Int(size.width * scale) & ~1
        cfg.height = Int(size.height * scale) & ~1
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 4
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.capturesAudio = true
        cfg.showsCursor = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
        srcW = cfg.width; srcH = cfg.height
        enc.onAU = { [weak self] au, pts, key in self?.onAU(au, pts, key) }
        L.i("SCK started \(cfg.width)x\(cfg.height)")
    }

    func stop() {
        let s = stream
        stream = nil
        if let s { Task { try? await s.stopCapture() } }
        enc.invalidate()
        pool = nil
    }

    /// 内容区域变化：更新裁剪矩形并按需重建编码器（新 SPS 随下个关键帧发出）
    func applyCrop(_ rect: CGRect?, srcW: Int, srcH: Int) {
        q.async {
            self.cropRect = rect
            var w = srcW & ~1, h = srcH & ~1
            if let r = rect {
                w = max(64, Int((r.width * CGFloat(srcW)).rounded()) & ~1)
                h = max(64, Int((r.height * CGFloat(srcH)).rounded()) & ~1)
            }
            if w != self.enc.w || h != self.enc.h {
                self.enc.ensure(w: w, h: h)
                self.makePool(w: w, h: h)
            }
        }
    }

    func requestKeyframe() { enc.requestKeyframe() }

    private func makePool(w: Int, h: Int) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p
    }

    // ---------- SCStreamOutput ----------

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sb) else { return }
        switch type {
        case .screen: handleVideo(sb)
        case .audio: handleAudio(sb)
        default: break
        }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        L.i("SCK stopped: \(error)")
        onError(error)
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let src = CMSampleBufferGetImageBuffer(sb) else { return }
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        if enc.w == 0 { enc.ensure(w: srcW & ~1, h: srcH & ~1) }

        frameCount += 1
        if frameCount % 20 == 0, let lum = FrameUtil.luma(src, ci: ci) {
            onSample(lum, 96, 54)
        }

        var pb = src
        if let r = cropRect, let pool,
           let cropped = FrameUtil.crop(src, rect: r, to: pool, ci: ci,
                                        w: enc.w, h: enc.h) {
            pb = cropped
        }
        enc.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let (pcm, pts) = conv.convert(sb) else { return }
        onPCM(pcm, pts)
    }
}
