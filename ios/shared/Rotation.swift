import CoreMotion
import Foundation
import UIKit

/// 智能旋转状态机（与 Android 端同规则，spec §5）：
/// - 跟随旋转：界面方向变化 -> 重建编码器（像素本身跟着系统转，rotation 字段恒 0）
/// - 重力转正：竖屏界面 + 横拿稳定 1s（平放不算）+ 流里有黑边 -> rotation 1/3
/// - 强制旋转：forceCycle 1/2/3 -> rotation 直接取它；4 次按回 auto
final class Rotation: NSObject {
    /// 当前该写进视频帧头的 rotation 值（顺时针 90° 个数）
    var field: UInt8 {
        if forceCycle != 0 { return UInt8(forceCycle) }
        if gravUpright { return gravSign > 0 ? 1 : 3 }
        return 0
    }

    /// 0=auto, 1/2/3=强制
    private(set) var forceCycle = 0 {
        didSet { onChange() }
    }

    /// 恢复会话时的初始档位（录屏扩展从配置读）
    func setForce(_ n: Int) {
        let n = n % 4
        if n != forceCycle { forceCycle = n }
    }
    /// 流里是否还带着黑边（Engine 由截取检测器喂入）
    var streamHasBars = false
    /// 界面是否竖屏（Engine 定时刷新；SCK 后台时取最后已知值）
    var uiPortrait = true
    var onChange: () -> Void = {}

    private let mm = CMMotionManager()
    private let oq = OperationQueue()
    private var gravHoldSign = 0
    private var gravSince = Date()
    private var gravLandscape = false
    private var gravSign = 0

    private var gravUpright: Bool {
        forceCycle == 0 && gravLandscape && uiPortrait && streamHasBars
    }

    func start() {
        guard mm.isAccelerometerAvailable else { return }
        mm.accelerometerUpdateInterval = 0.2
        mm.startAccelerometerUpdates(to: oq) { [weak self] d, _ in
            guard let self, let a = d?.acceleration else { return }
            let ax = a.x * 9.81, ay = a.y * 9.81, az = a.z * 9.81
            let landscape = abs(ax) > 6 && abs(ax) > abs(ay) && abs(ax) > abs(az)
            let sign = ax > 0 ? 1 : -1
            if landscape && sign == self.gravHoldSign {
                if !self.gravLandscape && Date().timeIntervalSince(self.gravSince) > 1 {
                    self.gravLandscape = true
                    self.gravSign = sign
                    L.i("gravity landscape sign=\(sign)")
                    self.onChange()
                }
            } else {
                self.gravSince = Date()
                self.gravHoldSign = landscape ? sign : 0
                if self.gravLandscape { self.gravLandscape = false; self.onChange() }
            }
        }
    }

    func cycle() {
        forceCycle = (forceCycle + 1) % 4
        L.i("forceRotate -> \(forceCycle)")
    }

    func reset() { forceCycle = 0; gravLandscape = false }

    func stop() { mm.stopAccelerometerUpdates() }
}
