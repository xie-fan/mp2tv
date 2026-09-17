import Foundation

/// App 与 Widget 扩展共用的命令总线。
/// Intent 在两个 target 里都编译；perform() 实际在 App 进程执行，
/// 走的是 App target 编译进二进制的那份 CmdBus —— App 启动时装配实现。
public enum CmdBus {
    public static var rotate: () -> Void = {}
    public static var toggleCrop: () -> Void = {}
    public static var stop: () -> Void = {}
}
