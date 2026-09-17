import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// 采集管线：ScreenCaptureKit -> (智能截取) -> VideoToolbox -> Annex B AU
/// 声音：SCK audio -> AVAudioConverter -> 48k s16le stereo
@available(iOS 27.0, *)
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {

    var onAU: (_ au: Data, _ ptsUs: UInt64, _ key: Bool) -> Void = { _, _, _ in }
    var onPCM: (_ pcm: Data, _ ptsUs: UInt64) -> Void = { _, _ in }
    var onError: (Error) -> Void = { _ in }
    /// 每 20 帧给截取检测器一份 96x54 亮度图
    var onSample: (_ lum: [UInt8], _ w: Int, _ h: Int) -> Void = { _, _, _ in }

    private var stream: SCStream?
    private var vt: VTCompressionSession?
    private var vtw = 0 // 编码器当前尺寸（判断要不要重建）
    private var vth = 0
    private var pool: CVPixelBufferPool?
    private var sps: Data?
    private var pps: Data?
    private var forceKey = false
    private var frameCount = 0
    private let ciCtx = CIContext()
    private var audioConv: AVAudioConverter?
    private var audioOutFmt: AVAudioFormat?
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
        L.i("SCK started \(cfg.width)x\(cfg.height)")
    }

    func stop() {
        let s = stream
        stream = nil
        if let s { Task { try? await s.stopCapture() } }
        if let vt { VTCompressionSessionInvalidate(vt) }
        vt = nil
        sps = nil; pps = nil; pool = nil
    }

    /// 内容区域变化：更新裁剪矩形并按需重建编码器（新 SPS 随下个关键帧发出）
    func applyCrop(_ rect: CGRect?, srcW: Int, srcH: Int) {
        q.async {
            self.cropRect = rect
            var w = srcW, h = srcH
            if let r = rect {
                w = max(64, Int((r.width * CGFloat(srcW)).rounded()) & ~1)
                h = max(64, Int((r.height * CGFloat(srcH)).rounded()) & ~1)
            }
            if w != self.vtw || h != self.vth { self.rebuildEncoder(w: w, h: h) }
        }
    }

    // ---------- VideoToolbox ----------

    private func rebuildEncoder(w: Int, h: Int) {
        if let vt { VTCompressionSessionInvalidate(vt) }
        var session: VTCompressionSession?
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(w), height: Int32(h),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: vtOutCb, refcon: ctx,
            compressionSessionOut: &session
        )
        guard status == noErr, let s = session else {
            L.i("VTCompressionSessionCreate failed: \(status)")
            return
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 5.0))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 6_000_000))
        vt = s
        vtw = w; vth = h
        sps = nil; pps = nil
        makePool(w: w, h: h)
        forceKey = true
        L.i("encoder rebuilt \(w)x\(h)")
    }

    func requestKeyframe() { forceKey = true }

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

    // VT 输出回调：avcC -> Annex B
    fileprivate func didOutput(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb),
              let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        // 关键帧判断：附件里没有 NotSync=true 即为关键帧
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]]
        let key = !(atts?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
        var setCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetCount(fd, parameterSetCountOut: &setCount)
        if setCount >= 2 {
            var sp = Data(); var pp = Data()
            for i in 0..<min(setCount, 2) {
                var ptr: UnsafePointer<UInt8>?; var len = 0; var n = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &len, parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil)
                if let ptr { if i == 0 { sp = Data(bytes: ptr, count: len) } else { pp = Data(bytes: ptr, count: len) } }
            }
            if !sp.isEmpty { sps = sp }
            if !pp.isEmpty { pps = pp }
        }
        guard let db = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(db, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &len, dataPointerOut: &ptr)
        guard let p = ptr else { return }
        // AVCC: [naluLen u32 BE][nalu]... -> Annex B: 00000001 + nalu
        var au = Data()
        if key, let s = sps, let pp = pps {
            au.append(contentsOf: [0, 0, 0, 1]); au.append(s)
            au.append(contentsOf: [0, 0, 0, 1]); au.append(pp)
        }
        var off = 0
        let bytes = UnsafeRawBufferPointer(start: p, count: len)
        while off + 4 <= len {
            let nl = Int(bytes[off]) << 24 | Int(bytes[off+1]) << 16 | Int(bytes[off+2]) << 8 | Int(bytes[off+3])
            off += 4
            if nl <= 0 || off + nl > len { break }
            au.append(contentsOf: [0, 0, 0, 1])
            au.append(contentsOf: bytes[off..<off+nl])
            off += nl
        }
        let pts = UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1e6)
        onAU(au, pts, key)
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
        if vt == nil { rebuildEncoder(w: srcW & ~1, h: srcH & ~1) }

        frameCount += 1
        if frameCount % 20 == 0 { sampleLuma(src) }

        var pb = src
        if let r = cropRect, pool != nil {
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &out)
            if let out {
                let rect = CGRect(x: r.minX * CGFloat(srcW), y: r.minY * CGFloat(srcH),
                                  width: r.width * CGFloat(srcW), height: r.height * CGFloat(srcH))
                let img = CIImage(cvPixelBuffer: src).cropped(to: rect)
                    .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                    .transformed(by: CGAffineTransform(scaleX: CGFloat(vtw) / rect.width,
                                                       y: CGFloat(vth) / rect.height))
                ciCtx.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: vtw, height: vth),
                             colorSpace: CGColorSpaceCreateDeviceRGB())
                pb = out
            }
        }
        guard let vt else { return }
        var props: NSDictionary? = nil
        if forceKey { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]; forceKey = false }
        let st = VTCompressionSessionEncodeFrame(
            vt, imageBuffer: pb, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
            duration: .invalid, frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: nil
        )
        if st != noErr { L.i("encode err \(st)") }
    }

    // ---------- audio ----------

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let inFmt = AVAudioFormat(streamDescription: asbd) else { return }
        if audioOutFmt == nil {
            audioOutFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                        sampleRate: 48000, channels: 2, interleaved: true)
            if let of = audioOutFmt { audioConv = AVAudioConverter(from: inFmt, to: of) }
        }
        guard let conv = audioConv, let outFmt = audioOutFmt else { return }
        let cap = AVAudioFrameCount(sb.numSamples)
        guard cap > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: cap) else { return }
        inBuf.frameLength = cap
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(cap), into: inBuf.mutableAudioBufferList
        ) == noErr else { return }
        let outCap = AVAudioFrameCount(Double(cap) * 48000 / inFmt.sampleRate + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return }
        var err: NSError?
        var sent = false
        conv.convert(to: outBuf, error: &err, withInputFrom: { _, status in
            if sent { status.pointee = .endOfStream; return nil }
            sent = true
            status.pointee = .haveData
            return inBuf
        })
        let n = Int(outBuf.frameLength) * 4 // s16 stereo
        guard n > 0, let ch = outBuf.int16ChannelData else { return }
        onPCM(Data(bytes: ch[0], count: n),
              UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1e6))
    }

    // ---------- luma sampling for smart crop ----------

    private func sampleLuma(_ src: CVPixelBuffer) {
        let w = 96, h = 54
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { return }
        let img = CIImage(cvPixelBuffer: src).transformed(by:
            CGAffineTransform(scaleX: CGFloat(w) / CGFloat(CVPixelBufferGetWidth(src)),
                              y: CGFloat(h) / CGFloat(CVPixelBufferGetHeight(src))))
        ciCtx.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                     colorSpace: CGColorSpaceCreateDeviceRGB())
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var lum = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let i = x * 4
                lum[y * w + x] = UInt8((Int(row[i + 2]) * 2 + Int(row[i + 1]) * 4 + Int(row[i])) / 7)
            }
        }
        onSample(lum, w, h)
    }
}

/// C 回调 -> Swift 方法
private func vtOutCb(refcon: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?,
                     status: OSStatus, _: VTEncodeInfoFlags, sb: CMSampleBuffer?) {
    guard status == noErr, let sb, let refcon else { return }
    Unmanaged<Capture>.fromOpaque(refcon).takeUnretainedValue().didOutput(sb)
}
