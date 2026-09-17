import Foundation

/// 分帧协议：与 docs/protocol.md 一致
/// [type u8][length u32 BE][payload]
enum Proto {
    static let version = 1
    static let frameControl: UInt8 = 1
    static let frameVideo: UInt8 = 2
    static let frameAudio: UInt8 = 3
    static let maxPayload = 8 * 1024 * 1024

    static func frame(_ type: UInt8, _ payload: Data) -> Data {
        var h = Data(count: 5)
        h[0] = type
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { h.replaceSubrange(1..<5, with: $0) }
        return h + payload
    }

    static func control(_ obj: [String: Any]) -> Data {
        frame(frameControl, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
    }

    /// 视频帧载荷：[pts u64][flags u8][rotation u8][AU]
    static func videoPayload(ptsUs: UInt64, key: Bool, rotation: UInt8, au: Data) -> Data {
        var p = Data(count: 10)
        var pts = ptsUs.bigEndian
        withUnsafeBytes(of: &pts) { p.replaceSubrange(0..<8, with: $0) }
        p[8] = key ? 1 : 0
        p[9] = rotation
        return p + au
    }

    /// 音频帧载荷：[pts u64][PCM s16le 48k stereo]
    static func audioPayload(ptsUs: UInt64, pcm: Data) -> Data {
        var p = Data(count: 8)
        var pts = ptsUs.bigEndian
        withUnsafeBytes(of: &pts) { p.replaceSubrange(0..<8, with: $0) }
        return p + pcm
    }

    /// 累积字节流 -> 逐帧回调
    final class Framer {
        private var buf = Data()
        func push(_ d: Data, _ on: (UInt8, Data) -> Void) {
            buf.append(d)
            while buf.count >= 5 {
                let len = Int(buf[1]) << 24 | Int(buf[2]) << 16 | Int(buf[3]) << 8 | Int(buf[4])
                guard len <= Proto.maxPayload else { buf.removeAll(); return }
                if buf.count < 5 + len { return }
                on(buf[0], buf.subdata(in: 5..<(5 + len)))
                buf.removeSubrange(0..<(5 + len))
            }
        }
    }
}
