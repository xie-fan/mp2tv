import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// 音频重采样：任意输入格式 -> 48kHz s16le stereo 交错（protocol §音频帧）。
final class PcmConv {
    private var conv: AVAudioConverter?
    private var outFmt: AVAudioFormat?
    private var inFmt: AVAudioFormat?

    /// 输入是 CMSampleBuffer（SCK / ReplayKit 都是这个形态）；输出 nil = 丢弃
    func convert(_ sb: CMSampleBuffer) -> (Data, UInt64)? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        let fmt = AVAudioFormat(streamDescription: asbd)
        guard let fmt else { return nil }
        if conv == nil || inFmt != fmt {
            inFmt = fmt
            outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 48000, channels: 2, interleaved: true)
            guard let of = outFmt else { return nil }
            conv = AVAudioConverter(from: fmt, to: of)
        }
        guard let conv, let outFmt else { return nil }
        let cap = AVAudioFrameCount(sb.numSamples)
        guard cap > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap)
        else { return nil }
        inBuf.frameLength = cap
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(cap), into: inBuf.mutableAudioBufferList
        ) == noErr else { return nil }
        let outCap = AVAudioFrameCount(Double(cap) * 48000 / fmt.sampleRate + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)
        else { return nil }
        var err: NSError?
        var sent = false
        conv.convert(to: outBuf, error: &err, withInputFrom: { _, status in
            if sent { status.pointee = .endOfStream; return nil }
            sent = true
            status.pointee = .haveData
            return inBuf
        })
        let n = Int(outBuf.frameLength) * 4
        guard n > 0, let ch = outBuf.int16ChannelData else { return nil }
        return (Data(bytes: ch[0], count: n),
                UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1e6))
    }
}

/// 智能截取辅助：整帧缩到 96x54 读亮度图 + CIImage 裁剪渲染。
enum FrameUtil {
    /// 读亮度图（BGRA 像素 -> 近似亮度 r*2+g*4+b / 7）
    static func luma(_ src: CVPixelBuffer, ci: CIContext, w: Int = 96, h: Int = 54) -> [UInt8]? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { return nil }
        let img = CIImage(cvPixelBuffer: src).transformed(by:
            CGAffineTransform(scaleX: CGFloat(w) / CGFloat(CVPixelBufferGetWidth(src)),
                              y: CGFloat(h) / CGFloat(CVPixelBufferGetHeight(src))))
        ci.render(img, to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  colorSpace: CGColorSpaceCreateDeviceRGB())
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var lum = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let i = x * 4
                lum[y * w + x] = UInt8((Int(row[i + 2]) * 2 + Int(row[i + 1]) * 4 + Int(row[i])) / 7)
            }
        }
        return lum
    }

    /// 归一化裁剪矩形 -> 裁剪+缩放到目标尺寸的 pixel buffer
    static func crop(_ src: CVPixelBuffer, rect r: CGRect, to pool: CVPixelBufferPool,
                     ci: CIContext, w: Int, h: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return nil }
        let sw = CGFloat(CVPixelBufferGetWidth(src))
        let sh = CGFloat(CVPixelBufferGetHeight(src))
        let px = CGRect(x: r.minX * sw, y: r.minY * sh,
                        width: r.width * sw, height: r.height * sh)
        let img = CIImage(cvPixelBuffer: src).cropped(to: px)
            .transformed(by: CGAffineTransform(translationX: -px.minX, y: -px.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / px.width,
                                               y: CGFloat(h) / px.height))
        ci.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                  colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }
}
