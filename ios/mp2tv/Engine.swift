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
    // 智能截取（防抖逻辑在共享 CropCtl）
    private let crop = CropCtl()
    /// 会话级截取开关：快捷按钮只影响本次投屏（spec），默认设置走 cropOn
    private var sessionCrop = true
    // M4 旧路线状态
    /// true = iOS < 27，走录屏扩展；扩展自持会话，App 只做配置/命令转发/状态展示
    private(set) var legacyMode = false
    private var extStateTok = 0
    private var extPoll: Timer?

    private override init() {
        super.init()
        devices = Store.list()
        disc.onChange = { [weak self] m in
            DispatchQueue.main.async { self?.online = m }
        }
        disc.start()
        if #available(iOS 27.0, *) { legacyMode = false } else { legacyMode = true }
        crop.apply = { [weak self] r in self?.applyCropRect(r) }
        crop.on = cropOn
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

    private func b64d(_ s: String) -> Data? { Proto.b64d(s) }

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
                      let tok = Proto.b64d(tok64),
                      // receiverId 必须是证书指纹前 8 字节——伪造 id 会覆盖真电脑凭据
                      rid == String(fp.map { String(format: "%02x", $0) }.joined().prefix(16))
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
        if phase == .connecting && legacyMode { stop(userInitiated: true); return } // 取消等待录屏
        guard phase == .idle else { return }
        dev = d
        startSession()
    }

    func stop(userInitiated: Bool) {
        stopping = true
        if legacyMode {
            IPC.sendStop() // 通知扩展退出投屏
            teardown()
        } else if userInitiated, let c = conn {
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
        crop.reset()
        extPoll?.invalidate(); extPoll = nil
        if extStateTok != 0 { IPC.unobserve(extStateTok); extStateTok = 0 }
        if #available(iOS 16.2, *) { LiveAct.end() }
        phase = .idle
        stopping = false
    }

    private func startSession() {
        guard let d = dev else { return }
        guard let tok = Store.token(d.receiverId) else {
            status = "配对凭据缺失，请重新配对"; return
        }
        stopping = false
        phase = .connecting
        sessionCrop = cropOn
        if #available(iOS 27.0, *) {
            status = "连接 \(d.name)…"
            connectAndHello(d)
        } else {
            startLegacy(d, token: tok)
        }
    }

    // ---------- M4：录屏扩展路径（iOS 17–26） ----------

    /// App 写好会话配置 → 用户点系统录屏按钮 -> 扩展自持会话。
    /// App 只转发命令和展示扩展回写的状态。
    private func startLegacy(_ d: PairedComputer, token: Data) {
        let (host, port) = resolveHost(d)
        IPC.clearSession()
        IPC.writeSession(IPC.SessionCfg(
            receiverId: d.receiverId, receiverName: d.name,
            host: host, port: port,
            fpB64: d.fpB64, tokenB64: b64url(token),
            senderId: Store.senderId, senderName: UIDevice.current.name,
            cropOn: sessionCrop, forceRot: 0))
        IPC.writeUiPortrait(currentPortrait())
        lastExtState = ""
        status = "点下方录屏按钮开始"
        watchExtState()
        startUiPortraitWriter()
    }

    private func currentPortrait() -> Bool {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        return scene?.interfaceOrientation.isPortrait ?? true
    }

    /// 旧路线下持续把界面方向写进共享配置（扩展里重力转正条件①用）
    private func startUiPortraitWriter() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            IPC.writeUiPortrait(self.currentPortrait())
        }
    }

    /// 订阅扩展回写的状态（Darwin 通知 + 1s 兜底轮询）
    private func watchExtState() {
        if extStateTok == 0 {
            extStateTok = IPC.observe(IPC.nState) { [weak self] in
                DispatchQueue.main.async { self?.applyExtState() }
            }
        }
        extPoll?.invalidate()
        extPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.applyExtState()
        }
    }

    private var lastExtState = ""

    private func applyExtState() {
        let s = IPC.extState()
        guard s != lastExtState else { return }
        lastExtState = s
        switch s {
        case "connecting":
            phase = .connecting; status = "连接 \(dev?.name ?? "")…"
        case "streaming":
            phase = .streaming; status = "投屏中 → \(dev?.name ?? "")"
        case "reconnecting":
            phase = .reconnecting; status = "连接中断，重连中…"
        case "idle":
            if phase != .idle {
                phase = .idle; status = "已退出投屏"
                teardownLegacyUi()
            }
        default:
            if s.hasPrefix("err:") {
                phase = .idle
                status = String(s.dropFirst(4))
                teardownLegacyUi()
            }
        }
        if phase == .streaming || phase == .reconnecting { updateLive() }
        if phase == .idle, #available(iOS 16.2, *) { LiveAct.end() }
    }

    private func teardownLegacyUi() {
        lastExtState = ""
        extPoll?.invalidate(); extPoll = nil
        if extStateTok != 0 { IPC.unobserve(extStateTok); extStateTok = 0 }
        uiTimer?.invalidate(); uiTimer = nil
        forceRot = 0
        stopping = false
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
        crop.on = sessionCrop
        crop.feed(lum, w: w, h: h)
        rot.streamHasBars = crop.streamHasBars
    }

    private func applyCropRect(_ cg: CGRect?) {
        guard encW > 0 else { return }
        if #available(iOS 27.0, *) { cap?.applyCrop(cg, srcW: encW, srcH: encH) }
        L.i("crop -> \(String(describing: cg))")
    }

    func toggleCrop() {
        if phase == .streaming || phase == .reconnecting {
            // 投屏中：只影响本次会话（spec 快捷按钮语义）
            sessionCrop.toggle()
            if legacyMode {
                IPC.sendToggleCrop()
            } else {
                crop.on = sessionCrop
                if !sessionCrop { applyCropRect(nil) }
            }
        } else {
            cropOn.toggle() // 未投屏：改的是默认设置
        }
        updateLive()
    }

    // ---------- 旋转 ----------

    func cycleRotate() {
        if legacyMode {
            IPC.sendRotate()
            forceRot = (forceRot + 1) % 4 // 扩展自持档位，这里只同步显示
        } else {
            rot.cycle()
            forceRot = rot.forceCycle
        }
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
        let effectiveCrop = (phase == .streaming || phase == .reconnecting) ? sessionCrop : cropOn
        LiveAct.update(receiverName: dev?.name ?? "", status: s,
                       cropOn: effectiveCrop, forceRot: forceRot)
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
        // hello 已经发出、会话挂着——取消选择必须退出，否则电脑端黑屏全屏
        DispatchQueue.main.async {
            Engine.shared.stop(userInitiated: false)
            Engine.shared.status = "已取消选择"
        }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        L.i("picker failed: \(error)")
        DispatchQueue.main.async {
            Engine.shared.stop(userInitiated: false)
            Engine.shared.status = "录屏授权失败"
        }
    }
}
