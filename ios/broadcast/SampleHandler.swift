import CoreFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ReplayKit
import VideoToolbox

/// 录屏扩展（iOS 17–26 路线）：扩展进程自持整条投屏会话。
/// App 只负责写会话配置 + 转发命令（IPC.swift），帧不跨进程。
/// 内存上限约 50MB：全部处理在 autoreleasepool 内，缓冲最小化。
final class SampleHandler: RPBroadcastSampleHandler {

    private enum S { static let idle = "idle"; static let connecting = "connecting"
        static let streaming = "streaming"; static let reconnecting = "reconnecting" }

    private var cfg: IPC.SessionCfg?
    private var conn: Conn?
    private let enc = VTEnc()
    private let conv = PcmConv()
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private let crop = CropCtl()
    private let rot = Rotation()

    private var streaming = false
    private var stopping = false
    private var helloWait: (([String: Any]) -> Void)?
    private var reconnectDeadline = Date()
    private var hb: DispatchSourceTimer?
    private var cmdTok = 0
    private var seen = ["rotate": 0, "crop": 0, "stop": 0, "keyframe": 0]
    private var frameN = 0
    private var cropRect: CGRect?
    private var srcW = 0
    private var srcH = 0
    private var rkRot: UInt8 = 0 // ReplayKit 附件报的画面方向（与重力转正叠加）
    private var cmdPoll: DispatchSourceTimer?

    // ---------- 生命周期 ----------

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let c = IPC.readSession() else {
            IPC.writeExtState("err:无会话配置")
            finishBroadcastWithError(NSError(domain: "mp2tv", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "请先在 App 里选择电脑再投屏"]))
            return
        }
        cfg = c
        crop.on = c.cropOn
        rot.setForce(c.forceRot)
        rot.uiPortrait = IPC.uiPortrait()
        crop.apply = { [weak self] r in self?.applyCrop(r) }
        enc.onAU = { [weak self] au, pts, key in self?.sendVideo(au, pts, key) }
        rot.onChange = { [weak self] in self?.enc.requestKeyframe() }
        rot.start()
        startCmdWatch()
        IPC.writeExtState(S.connecting)
        connectHello()
    }

    override func broadcastFinished() {
        L.i("broadcast finished")
        stopping = true
        // 尽力通知电脑端
        conn?.sendControl(["t": "stop", "reason": "user"])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.teardown()
        }
    }

    override func broadcastPaused() { L.i("broadcast paused") }
    override func broadcastResumed() { L.i("broadcast resumed") }

    private func teardown() {
        hb?.cancel(); hb = nil
        cmdPoll?.cancel(); cmdPoll = nil
        if cmdTok != 0 { IPC.unobserve(cmdTok); cmdTok = 0 }
        conn?.close(); conn = nil
        enc.invalidate()
        rot.stop(); rot.reset()
        crop.reset()
        pool = nil; cropRect = nil
        streaming = false
        IPC.clearSession()
        IPC.writeExtState(S.idle)
    }

    // ---------- 网络 ----------

    private func connectHello() {
        guard let c = cfg else { return }
        let fp = Proto.b64d(c.fpB64) ?? Data()
        Conn.connect(host: c.host, port: c.port, fp: fp, timeout: 5) { [weak self] r in
            guard let self, !self.stopping else { return }
            switch r {
            case .failure:
                self.onConnectFail()
            case .success(let cn):
                self.conn = cn
                cn.onControl = { [weak self] m in self?.onControl(m) }
                cn.onClosed = { [weak self] in self?.onClosed() }
                self.helloWait = { [weak self] m in self?.onHello(m) }
                cn.sendControl([
                    "t": "hello", "v": Proto.version,
                    "senderId": c.senderId, "senderName": c.senderName,
                    "token": c.tokenB64
                ])
            }
        }
    }

    private func onConnectFail() {
        if IPC.extState() == S.reconnecting {
            scheduleReconnect()
        } else {
            IPC.writeExtState("err:连不上电脑")
            finishBroadcastWithError(NSError(domain: "mp2tv", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "连不上电脑"]))
        }
    }

    private func onHello(_ m: [String: Any]) {
        helloWait = nil
        guard m["ok"] as? Bool == true else {
            let reason = m["reason"] as? String ?? "?"
            conn?.close(); conn = nil
            let text: String
            switch reason {
            case "notPaired": text = "电脑已解除配对"
            case "busy": text = "电脑正在投 \(m["busyWith"] as? String ?? "另一台手机")"
            case "versionMismatch": text = "协议版本不匹配"
            case "receiverLocked": text = "电脑已锁屏"
            default: text = "连接失败"
            }
            IPC.writeExtState("err:\(text)")
            finishBroadcastWithError(NSError(domain: "mp2tv", code: 3,
                userInfo: [NSLocalizedDescriptionKey: text]))
            return
        }
        streaming = true
        IPC.writeExtState(S.streaming)
        startHeartbeat()
        enc.requestKeyframe() // 新会话/重连恢复都先补关键帧
        L.i("extension streaming")
    }

    private func onControl(_ m: [String: Any]) {
        if let w = helloWait { w(m); return }
        switch m["t"] as? String {
        case "stop":
            stopping = true
            teardown()
            finishBroadcastWithError(nil)
        case "command":
            if m["action"] as? String == "rotate" { rotate() }
            if m["action"] as? String == "keyframe" { enc.requestKeyframe() }
        default: break
        }
    }

    private func onClosed() {
        guard !stopping else { return }
        guard streaming || IPC.extState() == S.connecting else { return }
        streaming = false
        IPC.writeExtState(S.reconnecting)
        reconnectDeadline = Date().addingTimeInterval(10)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopping else { return }
        if Date() > reconnectDeadline {
            IPC.writeExtState("err:重连超时")
            finishBroadcastWithError(NSError(domain: "mp2tv", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "重连超时"]))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, IPC.extState() == S.reconnecting else { return }
            self.connectHello()
        }
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, let c = self.conn else { return }
            if Date().timeIntervalSince(c.lastSeen) > 8 { c.close(); return }
            c.sendControl(["t": "ping"])
        }
        t.resume()
        hb = t
    }

    // ---------- 命令（App -> 扩展） ----------

    private func startCmdWatch() {
        cmdTok = IPC.observe(IPC.nCmd) { [weak self] in self?.pollCmd() }
        // 兜底轮询：Darwin 通知偶发丢失时 1s 兜底 + 顺带刷新 uiPortrait
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            self?.pollCmd()
            self?.rot.uiPortrait = IPC.uiPortrait()
        }
        t.resume()
        cmdPoll = t
    }

    private func pollCmd() {
        for k in ["rotate", "crop", "stop", "keyframe"] {
            let n = IPC.cmdCount(k)
            if n > (seen[k] ?? 0) {
                seen[k] = n
                switch k {
                case "rotate": rotate()
                case "crop":
                    crop.on.toggle()
                    if !crop.on { applyCrop(nil) }
                case "keyframe": enc.requestKeyframe()
                case "stop":
                    stopping = true
                    conn?.sendControl(["t": "stop", "reason": "user"])
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        self?.finishBroadcastWithError(nil)
                    }
                default: break
                }
            }
        }
    }

    private func rotate() {
        rot.cycle()
        enc.requestKeyframe()
        L.i("rotate -> \(rot.field)")
    }

    // ---------- 采集 ----------

    override func processSampleBuffer(_ sb: CMSampleBuffer, with type: RPSampleBufferType) {
        guard streaming, !stopping, CMSampleBufferDataIsReady(sb) else { return }
        autoreleasepool {
            switch type {
            case .screen: video(sb)
            case .audioApp: audio(sb)
            default: break // .audioMic 不用：我们要的是 App 声音
            }
        }
    }

    private func video(_ sb: CMSampleBuffer) {
        guard let src = CMSampleBufferGetImageBuffer(sb) else { return }
        srcW = CVPixelBufferGetWidth(src); srcH = CVPixelBufferGetHeight(src)
        rkRot = rkOrientation(sb)

        frameN += 1
        if frameN % 20 == 0, let lum = FrameUtil.luma(src, ci: ci) {
            crop.feed(lum, w: 96, h: 54)
            rot.streamHasBars = crop.streamHasBars
        }

        var pb = src
        var ew = srcW & ~1, eh = srcH & ~1
        if let r = cropRect {
            ew = max(64, Int((r.width * CGFloat(srcW)).rounded()) & ~1)
            eh = max(64, Int((r.height * CGFloat(srcH)).rounded()) & ~1)
            if poolW != ew || poolH != eh { makePool(w: ew, h: eh) }
            if let pool, let cropped = FrameUtil.crop(src, rect: r, to: pool, ci: ci,
                                                    w: ew, h: eh) {
                pb = cropped
            }
        }
        enc.ensure(w: ew, h: eh)
        enc.encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    /// ReplayKit 的方向附件（TIFF orientation）-> 接收端需顺时针转的 90° 个数。
    /// 横屏 App 时缓冲仍是竖向尺寸、内容侧躺，靠这个字段让电脑端正过来。
    /// （映射方向待真机验证：左/右两个档位若反了就把 1/3 对调）
    private func rkOrientation(_ sb: CMSampleBuffer) -> UInt8 {
        guard let n = CMGetAttachment(sb, key: RPVideoSampleOrientationKey as String,
                                      attachmentModeOut: nil) as? NSNumber else { return 0 }
        switch n.uint32Value {
        case 1, 2: return 0    // up / upMirrored
        case 3, 4: return 2    // down / downMirrored
        case 5, 8: return 3    // left(Mirrored)：存的是转正图顺时针转的 → 逆时针转回
        default: return 1      // 6,7 right(Mirrored)
        }
    }

    private var poolW = 0
    private var poolH = 0

    private func makePool(w: Int, h: Int) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p; poolW = w; poolH = h
    }

    private func applyCrop(_ r: CGRect?) {
        cropRect = r
        // 尺寸变化由 video() 里 enc.ensure 完成（新 SPS 随下个关键帧发）
    }

    private func audio(_ sb: CMSampleBuffer) {
        guard let (pcm, pts) = conv.convert(sb) else { return }
        conn?.send(Proto.frame(Proto.frameAudio, Proto.audioPayload(ptsUs: pts, pcm: pcm)))
    }

    private func sendVideo(_ au: Data, _ pts: UInt64, _ key: Bool) {
        conn?.send(Proto.frame(Proto.frameVideo,
            Proto.videoPayload(ptsUs: pts, key: key,
                               rotation: (rot.field &+ rkRot) % 4, au: au)))
    }
}
