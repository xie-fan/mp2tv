import Foundation
import Network

/// mDNS 发现 `_mp2tv._tcp` 服务，按 TXT id= 匹配已配对电脑。
final class Discovery {
    struct Found {
        var id: String
        var host: String
        var port: Int
        var name: String
    }

    var onChange: ([String: Found]) -> Void = { _ in }
    private var browser: NWBrowser?
    // 串行队列：browse 回调和 resolve 回调都改 found，并发队列会踩字典
    private let q = DispatchQueue(label: "mp2tv.discovery")
    private var found: [String: Found] = [:] {
        didSet { onChange(found) }
    }

    func start() {
        let b = NWBrowser(for: .bonjour(type: "_mp2tv._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var seen = Set<String>()
            for r in results {
                guard case .bonjour(let txt) = r.metadata,
                      let id = txt.dictionary["id"] else { continue }
                seen.insert(id)
                if self.found[id] != nil { continue }
                var name = id
                if case .service(let n, _, _, _) = r.endpoint { name = n }
                self.resolve(r.endpoint) { host, port in
                    guard let host else { return }
                    self.found[id] = Found(id: id, host: host, port: port, name: name)
                }
            }
            self.found = self.found.filter { seen.contains($0.key) }
        }
        b.start(queue: q)
        browser = b
    }

    private func resolve(_ ep: NWEndpoint,
                         done: @escaping (String?, Int) -> Void) {
        // endpoint is service(name,type,domain); connect once to learn resolved addr/port
        let c = NWConnection(to: ep, using: .tcp)
        c.stateUpdateHandler = { st in
            if case .ready = st, case .hostPort(let h, let p) = c.currentPath?.remoteEndpoint {
                done("\(h)", Int(p.rawValue))
                c.cancel()
            }
        }
        c.start(queue: q)
    }

    func stop() { browser?.cancel(); browser = nil }

    func foundValue(_ id: String) -> Found? { found[id] }
}
