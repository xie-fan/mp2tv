import Foundation
import CoreFoundation

/// App 与录屏扩展（Broadcast Upload Extension）之间的 IPC。
///
/// 机制：App Groups 共享 UserDefaults 传数据 + Darwin 通知做信号。
/// 扩展里不能读 App 的 Keychain（除非另配 keychain-access-groups），
/// 所以会话参数（含配对 token）由 App 在投屏前整体写进 group defaults，
/// 结束后清除。group 容器只对自家 App/扩展可见。
///
/// 注意：免费开发者账号能否用 App Groups 待真机实测；若不可用，
/// 旧路线需要回退方案（见 handoff M4 节）。
enum IPC {

    static let suiteName = "group.com.mp2tv.app"
    static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    // ---------- Darwin 通知名 ----------

    static let nCmd = "com.mp2tv.cmd"       // App -> 扩展：有命令可读
    static let nState = "com.mp2tv.state"   // 扩展 -> App：状态变化

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }

    /// 返回观察 token，用 remove(token) 注销
    @discardableResult
    static func observe(_ name: String, _ cb: @escaping () -> Void) -> Int {
        var token = 0
        let ctx = Unmanaged.passRetained(Box(cb)).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), ctx,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue().f()
            },
            name as CFString, nil, .deliverImmediately)
        // CFNotificationCenterAddObserver 没有 token 返回；移除用 removeObserver(center, observer: ctx, ...)
        // 这里把 ctx 的 Int 值当 token
        token = Int(bitPattern: ctx)
        return token
    }

    static func unobserve(_ token: Int) {
        guard let p = UnsafeMutableRawPointer(bitPattern: token) else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), p,
            CFNotificationName(nCmd as CFString), nil)
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), p,
            CFNotificationName(nState as CFString), nil)
        Unmanaged<Box>.fromOpaque(p).release()
    }

    final class Box { let f: () -> Void; init(_ f: @escaping () -> Void) { self.f = f } }

    // ---------- 会话配置（App 写，扩展读） ----------

    struct SessionCfg: Codable {
        var receiverId: String
        var receiverName: String
        var host: String
        var port: Int
        var fpB64: String      // 证书指纹 base64
        var tokenB64: String   // 配对 token base64
        var senderId: String
        var senderName: String
        var cropOn: Bool
        var forceRot: Int
    }

    private static let kSession = "sessionCfg"
    private static let kExtState = "extState"
    private static let kUiPortrait = "uiPortrait"
    private static let kCmdRotate = "cmdRotate"
    private static let kCmdCrop = "cmdCrop"
    private static let kCmdStop = "cmdStop"
    private static let kCmdKeyframe = "cmdKeyframe"

    static func writeSession(_ c: SessionCfg) {
        defaults?.set(try? JSONEncoder().encode(c), forKey: kSession)
    }

    static func readSession() -> SessionCfg? {
        guard let d = defaults?.data(forKey: kSession) else { return nil }
        return try? JSONDecoder().decode(SessionCfg.self, from: d)
    }

    static func clearSession() {
        defaults?.removeObject(forKey: kSession)
        defaults?.removeObject(forKey: kExtState)
        for k in [kCmdRotate, kCmdCrop, kCmdStop, kCmdKeyframe] {
            defaults?.removeObject(forKey: k)
        }
    }

    // ---------- 命令（App 写计数器 + 通知，扩展轮询） ----------

    static func sendRotate() { bump(kCmdRotate); post(nCmd) }
    static func sendToggleCrop() { bump(kCmdCrop); post(nCmd) }
    static func sendStop() { bump(kCmdStop); post(nCmd) }
    static func sendKeyframe() { bump(kCmdKeyframe); post(nCmd) }

    private static func bump(_ k: String) {
        defaults?.set((defaults?.integer(forKey: k) ?? 0) + 1, forKey: k)
    }

    static func cmdCount(_ which: String) -> Int {
        let k = which == "rotate" ? kCmdRotate
            : which == "crop" ? kCmdCrop
            : which == "stop" ? kCmdStop : kCmdKeyframe
        return defaults?.integer(forKey: k) ?? 0
    }

    // ---------- 状态（扩展写，App 读） ----------

    /// idle / connecting / streaming / reconnecting / stopped / err:xxx
    static func writeExtState(_ s: String) {
        defaults?.set(s, forKey: kExtState)
        post(nState)
    }

    static func extState() -> String { defaults?.string(forKey: kExtState) ?? "idle" }

    // ---------- 界面方向（App 写，扩展读，重力转正用） ----------

    static func writeUiPortrait(_ p: Bool) { defaults?.set(p, forKey: kUiPortrait) }
    static func uiPortrait() -> Bool { defaults?.bool(forKey: kUiPortrait) ?? true }
}
