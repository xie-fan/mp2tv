import Foundation

/// 简单文件日志：filesDir/mp2tv.log，UI 里可导出分享。
enum L {
    private static var url: URL? = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("mp2tv.log")
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
