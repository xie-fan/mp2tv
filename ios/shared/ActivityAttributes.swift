import ActivityKit
import Foundation

/// 实时活动（灵动岛/锁屏卡片）的数据模型。App 与 Widget 扩展共用。
struct Mp2tvAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String      // "投屏中" / "重连中…"
        var cropOn: Bool        // 智能截取开关（本次会话）
        var forceRot: Int       // 0=自动, 1/2/3=强制旋转 90°个数
    }
    var receiverName: String
}
