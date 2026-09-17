import AppIntents
import Foundation

/// 实时活动按钮。LiveActivityIntent 的 perform() 在 App 进程执行，
/// 通过 CmdBus 调到 Engine —— 不需要 App Groups（免费开发者账号可用）。

@available(iOS 17.0, *)
struct RotateIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "旋转"
    func perform() async throws -> some IntentResult {
        CmdBus.rotate()
        return .result()
    }
}

@available(iOS 17.0, *)
struct CropIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "截取"
    func perform() async throws -> some IntentResult {
        CmdBus.toggleCrop()
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopCastIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "退出投屏"
    func perform() async throws -> some IntentResult {
        CmdBus.stop()
        return .result()
    }
}
