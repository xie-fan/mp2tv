import Foundation

/// 简单文件日志：mp2tv.log。优先写 App Group 容器（App 和录屏扩展共用一份日志），
/// 不可用则退回各自沙盒 documents。
enum L {
    private static var url: URL? = {
        let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: IPC.suiteName)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return dir?.appendingPathComponent("mp2tv.log")
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func i(_ msg: String) {
        NSLog("[mp2tv] %@", msg)
        guard let url else { return }
        let line = "[\(fmt.string(from: Date()))] \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    static func fileURL() -> URL? { url }
}
