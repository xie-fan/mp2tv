import CryptoKit
import Foundation
import Network
import Security

/// TLS 连接：不校验 CA/主机名，只比对服务端证书 SHA-256 指纹（protocol.md §TLS）。
final class Conn {
    enum Fail: Error { case connect, fingerprint, closed }

    private var c: NWConnection?
    private let framer = Proto.Framer()
    var onControl: ([String: Any]) -> Void = { _ in }
    var onClosed: () -> Void = {}
    /// 最近收到任何字节的时间（心跳/断线判定用）
    private(set) var lastSeen = Date()
    private(set) var remoteHost = ""
    private(set) var remotePort = 0

    static func connect(host: String, port: Int, fp: Data, timeout: TimeInterval,
                        done: @escaping (Result<Conn, Fail>) -> Void) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { (_, trustRef, complete) in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                var ok = false
                if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                   let leaf = chain.first {
                    let der = SecCertificateCopyData(leaf) as Data
                    ok = Data(SHA256.hash(data: der)) == fp
                }
                complete(ok)
            },
            DispatchQueue.global()
        )
        let params = NWParameters(tls: tls)
        let nw = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: params
        )
        let conn = Conn()
        conn.c = nw
        conn.remoteHost = host
        conn.remotePort = port
        var handed = false
        let once: (Result<Conn, Fail>) -> Void = { r in
            guard !handed else { return }
            handed = true
            done(r)
        }
        nw.stateUpdateHandler = { st in
            switch st {
            case .ready:
                once(.success(conn))
            case .failed(let e):
                L.i("conn failed: \(e)")
                once(.failure(.connect))
                conn.onClosed()
            case .cancelled:
                once(.failure(.closed))
                conn.onClosed()
            default: break
            }
        }
        nw.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if nw.state != .ready { nw.cancel() }
        }
        conn.startRead()
    }

    private func startRead() {
        c?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, err in
            guard let self else { return }
            if let d, !d.isEmpty {
                self.lastSeen = Date()
                self.framer.push(d) { t, p in
                    if t == Proto.frameControl, let m = try? JSONSerialization.jsonObject(with: p) as? [String: Any] {
                        self.onControl(m)
                    }
                }
            }
            if err != nil || done { self.onClosed(); return }
            self.startRead()
        }
    }

    func send(_ d: Data) {
        c?.send(content: d, completion: .contentProcessed { _ in })
    }

    func sendControl(_ obj: [String: Any]) { send(Proto.control(obj)) }

    func close() { c?.cancel(); c = nil }
}
