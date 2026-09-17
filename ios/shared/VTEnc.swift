import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// VideoToolbox H.264 编码器：AVCC -> Annex B，关键帧前自动带 SPS/PPS。
/// App（SCK 路线）与录屏扩展（ReplayKit 路线）共用；扩展有约 50MB 内存上限，实现保持轻量。
final class VTEnc {

    /// (au, ptsUs, key)
    var onAU: (Data, UInt64, Bool) -> Void = { _, _, _ in }

    private var vt: VTCompressionSession?
    private var sps: Data?
    private var pps: Data?
    private var forceKey = true
    /// 当前编码尺寸
    private(set) var w = 0
    private(set) var h = 0

    /// 尺寸变化时重建（新 SPS/PPS 会随下一个关键帧发出）
    func ensure(w: Int, h: Int) {
        let w = w & ~1, h = h & ~1
        if vt != nil && w == self.w && h == self.h { return }
        if let vt { VTCompressionSessionInvalidate(vt) }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(w), height: Int32(h),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: vtOutCb,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let s = session else {
            L.i("VTCompressionSessionCreate failed: \(status)")
            return
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 5.0))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: 60))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: 6_000_000))
        vt = s
        self.w = w; self.h = h
        sps = nil; pps = nil
        forceKey = true
        L.i("encoder \(w)x\(h)")
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        guard let vt else { return }
        var props: NSDictionary? = nil
        if forceKey { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]; forceKey = false }
        let st = VTCompressionSessionEncodeFrame(
            vt, imageBuffer: pb, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: props,
            sourceFrameRefcon: nil, infoFlagsOut: nil)
        if st != noErr { L.i("encode err \(st)") }
    }

    func requestKeyframe() { forceKey = true }

    func invalidate() {
        if let vt { VTCompressionSessionInvalidate(vt) }
        vt = nil; sps = nil; pps = nil
    }

    // VT 输出回调：avcC -> Annex B
    fileprivate func didOutput(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb),
              let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
            as? [[String: Any]]
        let key = !(atts?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
        var setCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetCount(fd, parameterSetCountOut: &setCount)
        if setCount >= 2 {
            for i in 0..<min(setCount, 2) {
                var ptr: UnsafePointer<UInt8>?; var len = 0; var n = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &len, parameterSetCountOut: &n,
                    nalUnitHeaderLengthOut: nil)
                if let ptr {
                    if i == 0 { sps = Data(bytes: ptr, count: len) }
                    else { pps = Data(bytes: ptr, count: len) }
                }
            }
        }
        guard let db = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(db, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &len, dataPointerOut: &ptr)
        guard let p = ptr else { return }
        var au = Data()
        if key, let s = sps, let pp = pps {
            au.append(contentsOf: [0, 0, 0, 1]); au.append(s)
            au.append(contentsOf: [0, 0, 0, 1]); au.append(pp)
        }
        var off = 0
        let bytes = UnsafeRawBufferPointer(start: p, count: len)
        while off + 4 <= len {
            let nl = Int(bytes[off]) << 24 | Int(bytes[off+1]) << 16 |
                Int(bytes[off+2]) << 8 | Int(bytes[off+3])
            off += 4
            if nl <= 0 || off + nl > len { break }
            au.append(contentsOf: [0, 0, 0, 1])
            au.append(contentsOf: bytes[off..<off+nl])
            off += nl
        }
        onAU(au, UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1e6), key)
    }
}

private func vtOutCb(refcon: UnsafeMutableRawPointer?, _: UnsafeMutableRawPointer?,
                     status: OSStatus, _: VTEncodeInfoFlags, sb: CMSampleBuffer?) {
    guard status == noErr, let sb, let refcon else { return }
    Unmanaged<VTEnc>.fromOpaque(refcon).takeUnretainedValue().didOutput(sb)
}
