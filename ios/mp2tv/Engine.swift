import Combine
import Foundation
import Network
import ScreenCaptureKit
import UIKit

/// 会话状态机：发现 -> 连接 -> hello -> 采集推流 -> 重连/停止。
/// UI 全部通过 @Published 属性驱动。
final class Engine: NSObject, ObservableObject {

    static let shared = Engine()

    enum Phase { case idle, pairing, connecting, streaming, reconnecting }
    @Published private(set) var phase: Phase = .idle
    @Published var status = "未连接"
    @Published var devices: [PairedComputer] = []
    @Published var online: [String: Discovery.Found] = [:]
    @Published var cropOn = Store.smartCropDefault { didSet { Store.smartCropDefault = cropOn } }
    @Published var forceRot = 0

    let disc = Discovery()
    private let rot = Rotation()
    private var capAny: AnyObject?   // Capture 仅 iOS 27+，类型擦除存这里
    @available(iOS 27.0, *)
    private var cap: Capture? {
        get { capAny as? Capture }
        set { capAny = newValue }
    }
    private var conn: Conn?
    private var dev: PairedComputer?
    private var helloWait: (([String: Any]) -> Void)?
    private var stopping = false
    private var pingTimer: Timer?
    private var uiTimer: Timer?
    private var pickerObsAny: AnyObject?
    @available(iOS 27.0, *)
    private var pickerObs: PickerObs? {
        get { pickerObsAny as? PickerObs }
        set { pickerObsAny = newValue }
    }
    private var encW = 0, encH = 0
    // 智能截取防抖
    private var candRect: ContentDetect.Rect?
    private var candCount = 0
    private var curCrop: CGRect?

    private override init() {
        super.init()
        devices = Store.list()
        disc.onChange = { [weak self] m in
            DispatchQueue.main.async { self?.online = m }
        }
        disc.start()
        rot.onChange = { [weak self] in self?.rotChanged() }
        CmdBus.rotate = { [weak self] in self?.cycleRotate() }
        CmdBus.toggleCrop = { [weak self] in self?.toggleCrop() }
        CmdBus.stop = { [weak self] in self?.stop(userInitiated: true) }
        // 手动锁屏 -> 退出投屏（spec §iOS UX）
        NotificationCenter.default.addObserver(
            self, selector: #selector(onLock),
            name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    }

    @objc private func onLock() {
        if phase == .streaming || phase == .reconnecting {
            L.i("screen locked -> stop")
            stop(userInitiated: true)
        }
    }

    // ---------- 配对 ----------

    /// 扫描到的 mp2tv://pair URL
    func pair(url s: String) {
        guard phase == .idle else { status = "投屏中不能配对"; return }
        guard let u = URLComponents(string: s), u.scheme == "mp2tv", u.host == "pair" else {
            status = "二维码无效"; return
        }
        var q: [String: String] = [:]
        for item in u.queryItems ?? [] { q[item.name] = item.value ?? "" }
        guard let h = q["h"], let p = Int(q["p"] ?? ""),
              let fpB64 = q["fp"], let c = q["c"], let n = q["n"],
              let fp = b64d(fpB64)
        else { status = "二维码无效"; return }

        phase = .pairing
        status = "配对中…"
        // h 可能是逗号分隔的多个 IPv4
        tryPairHosts(h.split(separator: ",").map(String.init), port: p, fp: fp, code: c, name: n)
    }

    private func b64d(_ s: String) -> Data? {
        Data(base64Encoded: s.replacingOccurrences(of: "-", with: "+")
                              .replacingOccurrences(of: "_", with: "/"))
    }

    private func b64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func tryPairHosts(_ hosts: [String], port: Int, fp: Data, code: String, name: String) {
        DispatchQueue.main.async {
            guard let host = hosts.first else {
                self.phase = .idle; self.status = "配对失败：连不上电脑"; return
            }
            Conn.connect(host: host, port: port, fp: fp, timeout: 4) { [weak self] r in
                guard let self else { return }
                switch r {
                case .failure:
                    self.tryPairHosts(Array(hosts.dropFirst()), port: port, fp: fp, code: code, name: name)
                case .success(let c):
                    self.doPair(c, code: code, fp: fp, qrName: name)
                }
            }
        }
    }

    private func doPair(_ c: Conn, code: String, fp: Data, qrName: String) {
        c.onControl = { [weak self] m in
            guard let self else { return }
            guard m["t"] as? String == "pairResult" else { return }
            DispatchQueue.main.async {
                defer { c.close() }
                guard m["ok"] as? Bool == true,
                      let rid = m["receiverId"] as? String,
                      let tok64 = m["token"] as? String,
                      let tok = Data(base64Encoded: tok64
                        .replacingOccurrences(of: "-", with: "+")
                        .replacingOccurrences(of: "_", with: "/"))
                else {
                    let reason = m["reason"] as? String ?? "?"
                    self.phase = .idle
                    self.status = reason == "versionMismatch" ? "协议版本不匹配，请升级 App"
                        : reason == "codeInvalid" ? "二维码已失效，请重新扫" : "配对失败: \(reason)"
                    return
                }
                let rname = m["receiverName"] as? String ?? qrName
                Store.saveToken(rid, tok)
                Store.upsert(PairedComputer(
                    receiverId: rid, name: rname,
                    lastHost: c.remoteHost, lastPort: c.remotePort,
                    fpB64: fp.base64EncodedString()))
                self.devices = Store.list()
                self.phase = .idle
                self.status = "已与 \(rname) 配对"
                L.i("paired with \(rname) \(rid)")
            }
        }
        c.sendControl([
            "t": "pair", "v": Proto.version,
            "senderId": Store.senderId,
            "senderName": UIDevice.current.name,
            "platform": "ios",
            "code": code
        ])
        // 8 秒内没收到 pairResult 视为超时
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.phase == .pairing else { return }
            c.close()
            self.phase = .idle
            self.status = "配对超时"
        }
    }

    // ---------- 会话 ----------

    func toggle(_ d: PairedComputer) {
        if phase == .streaming || phase == .reconnecting { stop(userInitiated: true); return }
        guard phase == .idle else { return }
        dev = d
        startSession()
    }

    func stop(userInitiated: Bool) {
        stopping = true
        if userInitiated, let c = conn {
            c.sendControl(["t": "stop", "reason": "user"])
            // 让 stop 帧先发出去再关 socket
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.teardown()
            }
        } else {
            teardown()
        }
        status = "已退出投屏"
    }

    private func teardown() {
        pingTimer?.invalidate(); pingTimer = nil
        uiTimer?.invalidate(); uiTimer = nil
        conn?.close(); conn = nil
        if #available(iOS 27.0, *) { cap?.stop(); cap = nil }
        rot.stop(); rot.reset()
        forceRot = 0
        curCrop = nil; candRect = nil; candCount = 0
        if #available(iOS 16.2, *) { LiveAct.end() }
        phase = .idle
        stopping = false
    }

    private func startSession() {
        guard let d = dev else { return }
        guard #available(iOS 27.0, *) else {
            status = "需要 iOS 27+（旧版本走 M4 录屏扩展，未实现）"
            return
        }
        guard Store.token(d.receiverId) != nil else {
            status = "配对凭据缺失，请重新配对"; return
        }
        stopping = false
        phase = .connecting
        status = "连接 \(d.name)…"
        connectAndHello(d)
    }

    private func resolveHost(_ d: PairedComputer) -> (String, Int) {
        if let f = disc.foundValue(d.receiverId) { return (f.host, f.port) }
        return (d.lastHost, d.lastPort)
    }

    private func connectAndHello(_ d: PairedComputer) {
        let (host, port) = resolveHost(d)
        Conn.connect(host: host, port: port, fp: d.fp(), timeout: 5) { [weak self] r in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                switch r {
                case .failure:
                    if self.phase == .reconnecting { self.scheduleReconnect() }
                    else { self.phase = .idle; self.status = "连不上 \(d.name)" }
                case .success(let c):
                    self.conn = c
                    c.onControl = { [weak self] m in self?.onControl(m) }
                    c.onClosed = { [weak self] in self?.onClosed() }
                    self.helloWait = { [weak self] m in self?.onHelloResult(m) }
                    c.sendControl([
                        "t": "hello", "v": Proto.version,
                        "senderId": Store.senderId,
                        "senderName": UIDevice.current.name,
                        "token": Store.token(d.receiverId).map(self.b64url) ?? ""
                    ])
                }
            }
        }
    }

    private func onHelloResult(_ m: [String: Any]) {
        helloWait = nil
        guard m["ok"] as? Bool == true else {
            let reason = m["reason"] as? String ?? "?"
            conn?.close(); conn = nil
            switch reason {
            case "notPaired":
                if var d = dev { d.invalid = true; Store.upsert(d); devices = Store.list() }
                phase = .idle; status = "电脑已解除配对，请重新扫码"
            case "busy":
                let who = m["busyWith"] as? String ?? "另一台手机"
                phase = .idle; status = "电脑正在投 \(who)"
            case "versionMismatch":
                phase = .idle; status = "协议版本不匹配，请升级 App"
            case "receiverLocked":
                phase = .idle; status = "电脑已锁屏"
            default:
                if phase == .reconnecting { scheduleReconnect() }
                else { phase = .idle; status = "连接失败: \(reason)" }
            }
            return
        }
        // 会话建立/恢复
        let wasReconnect = phase == .reconnecting
        phase = .streaming
        status = "投屏中 → \(dev?.name ?? "")"
        startHeartbeat()
        if wasReconnect {
            if #available(iOS 27.0, *) { cap?.requestKeyframe() } // 恢复后先补关键帧
            L.i("session resumed")
        } else {
            beginCapture()
        }
        updateLive()
    }

    private func onControl(_ m: [String: Any]) {
        DispatchQueue.main.async {
            if let w = self.helloWait { w(m); return }
            switch m["t"] as? String {
            case "stop":
                L.i("remote stop: \(m["reason"] ?? "")")
                self.stopping = true
                self.teardown()
                self.status = "电脑端已退出投屏"
            case "command":
                switch m["action"] as? String {
                case "rotate": self.cycleRotate()
                case "keyframe":
                    if #available(iOS 27.0, *) { self.cap?.requestKeyframe() }
                default: break
                }
            default: break // ping：收到即刷新 lastSeen（Net 层已更新）
            }
        }
    }

    private func onClosed() {
        DispatchQueue.main.async {
            guard !self.stopping else { return }
            guard self.phase == .streaming || self.phase == .connecting else { return }
            L.i("conn dropped -> reconnect window")
            self.phase = .reconnecting
            self.status = "连接中断，重连中…"
            self.updateLive()
            self.reconnectDeadline = Date().addingTimeInterval(10)
            self.scheduleReconnect()
        }
    }

    private var reconnectDeadline = Date()

    private func scheduleReconnect() {
        guard phase == .reconnecting, !stopping else { return }
        if Date() > reconnectDeadline {
            teardown()
            status = "重连超时，已退出投屏"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.phase == .reconnecting, let d = self.dev else { return }
            self.connectAndHello(d)
        }
    }

    // ---------- 采集 ----------

    private func beginCapture() {
        guard #available(iOS 27.0, *) else { return }
        let c = Capture()
        cap = c
        c.onAU = { [weak self] (au: Data, pts: UInt64, key: Bool) in
            self?.conn?.send(Proto.frame(Proto.frameVideo,
                Proto.videoPayload(ptsUs: pts, key: key,
                                   rotation: self?.rot.field ?? 0, au: au)))
        }
        c.onPCM = { [weak self] (pcm: Data, pts: UInt64) in
            self?.conn?.send(Proto.frame(Proto.frameAudio,
                Proto.audioPayload(ptsUs: pts, pcm: pcm)))
        }
        c.onSample = { [weak self] (lum: [UInt8], w: Int, h: Int) in self?.onLuma(lum, w: w, h: h) }
        c.onError = { [weak self] e in
            L.i("capture error: \(e)")
            DispatchQueue.main.async { self?.status = "录屏中断：\(e.localizedDescription)" }
        }
        presentPicker()
        rot.start()
        // 界面方向轮询（SCK 采集的是整个系统，拿不到回调就自己刷）
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first
            let portrait = scene?.interfaceOrientation.isPortrait ?? true
            if portrait != self.rot.uiPortrait {
                self.rot.uiPortrait = portrait
                self.rotChanged()
            }
        }
    }

    private func presentPicker() {
        guard #available(iOS 27.0, *) else { return }
        let p = SCContentSharingPicker.shared
        if pickerObs == nil {
            let obs = PickerObs { [weak self] filter in
                guard let self, let cap = self.cap else { return }
                Task {
                    do {
                        try await cap.begin(with: filter)
                        self.encW = cap.srcW; self.encH = cap.srcH
                    } catch {
                        L.i("SCK begin failed: \(error)")
                        DispatchQueue.main.async {
                            self.status = "录屏启动失败"; self.stop(userInitiated: false)
                        }
                    }
                }
            }
            pickerObs = obs
            p.add(obs)
        }
        p.isActive = true
        p.present()
    }

    // ---------- 智能截取 ----------

    private func onLuma(_ lum: [UInt8], w: Int, h: Int) {
        guard cropOn else {
            rot.streamHasBars = false
            if curCrop != nil { applyCropRect(nil) }
            return
        }
        guard let r = ContentDetect.detect(lum, w: w, h: h) else { return } // 暗场保持
        rot.streamHasBars = r.hasBars
        let target: ContentDetect.Rect? = r.isFull ? nil : r
        if let t = target, let c = candRect, t.similar(c) {
            candCount += 1
        } else {
            candRect = target; candCount = 1
        }
        if candCount >= 3 { // ~1s 稳定（每 20 帧采样 ≈ 3Hz）
            candCount = 0
            let cg = candRect?.cg
            if (cg == nil) != (curCrop == nil) || cg != curCrop {
                applyCropRect(cg)
            }
        }
    }

    private func applyCropRect(_ cg: CGRect?) {
        curCrop = cg
        guard encW > 0 else { return }
        if #available(iOS 27.0, *) { cap?.applyCrop(cg, srcW: encW, srcH: encH) }
        L.i("crop -> \(String(describing: cg))")
    }

    func toggleCrop() {
        cropOn.toggle()
        if !cropOn { applyCropRect(nil) }
        updateLive()
    }

    // ---------- 旋转 ----------

    func cycleRotate() {
        rot.cycle()
        forceRot = rot.forceCycle
        updateLive()
    }

    private func rotChanged() {
        if #available(iOS 27.0, *) { cap?.requestKeyframe() }
        forceRot = rot.forceCycle
        updateLive()
    }

    // ---------- 心跳 ----------

    private func startHeartbeat() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let c = self.conn else { return }
            if Date().timeIntervalSince(c.lastSeen) > 8 {
                L.i("no traffic 8s -> drop")
                c.close()
                return
            }
            c.sendControl(["t": "ping"])
        }
    }

    // ---------- 实时活动 ----------

    private func updateLive() {
        guard #available(iOS 16.2, *) else { return }
        let s = phase == .reconnecting ? "重连中…" : "投屏中"
        LiveAct.update(receiverName: dev?.name ?? "", status: s,
                       cropOn: cropOn, forceRot: forceRot)
    }

    // ---------- 解除配对 ----------

    func unpair(_ d: PairedComputer) {
        guard let tok = Store.token(d.receiverId) else {
            Store.remove(d.receiverId); devices = Store.list(); return
        }
        let (host, port) = resolveHost(d)
        Conn.connect(host: host, port: port, fp: d.fp(), timeout: 4) { r in
            if case .success(let c) = r {
                c.sendControl([
                    "t": "unpair", "senderId": Store.senderId,
                    "token": tok.base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                ])
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { c.close() }
            }
            DispatchQueue.main.async {
                Store.remove(d.receiverId)
                self.devices = Store.list()
            }
        }
    }
}

/// 系统录屏选择器回调
@available(iOS 27.0, *)
private final class PickerObs: NSObject, SCContentSharingPickerObserver {
    let onFilter: (SCContentFilter) -> Void
    init(_ f: @escaping (SCContentFilter) -> Void) { onFilter = f }
    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter,
                              for stream: SCStream?) {
        picker.isActive = false
        onFilter(filter)
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didCancelFor stream: SCStream?) {
        picker.isActive = false
        Engine.shared.status = "已取消选择"
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        L.i("picker failed: \(error)")
        Engine.shared.status = "录屏授权失败"
    }
}
