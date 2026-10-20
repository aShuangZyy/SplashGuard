import Foundation
import Network

/// 单条 UDP 上游连接 + 事务号改写分发。
///
/// 系统里多个 App 可能同时用同一个 txid 发查询，直接按 txid 排队会串包。
/// 这里给每条外发查询分配独立的 txid，收到应答后把 txid 改回原值再回写隧道。
final class UpstreamResolver {

    private let queue = DispatchQueue(label: "com.splashguard.upstream")
    private let hostString: String
    private let portValue: UInt16
    private var connection: NWConnection?
    private var ready = false
    private var waitingSends: [[UInt8]] = []
    private var pending: [UInt16: (Result<[UInt8], Error>) -> Void] = [:]
    private var timeouts: [UInt16: DispatchWorkItem] = [:]
    private var nextID: UInt16 = 1

    init(host: String, port: UInt16 = 53) {
        self.hostString = host
        self.portValue = port
    }

    struct UpstreamError: Error {}

    func resolve(query: [UInt8], timeout: TimeInterval = 4.0,
                 completion: @escaping (Result<[UInt8], Error>) -> Void) {
        guard query.count >= 12 else {
            completion(.failure(UpstreamError()))
            return
        }
        let originalID = DNSWire.u16(query, 0)

        queue.async {
            let upstreamID = self.allocateID()
            var outbound = query
            outbound[0] = UInt8(upstreamID >> 8)
            outbound[1] = UInt8(upstreamID & 0xFF)

            self.pending[upstreamID] = { result in
                switch result {
                case .success(var response):
                    if response.count >= 2 {
                        response[0] = UInt8(originalID >> 8)
                        response[1] = UInt8(originalID & 0xFF)
                    }
                    completion(.success(response))
                case .failure(let error):
                    completion(.failure(error))
                }
            }

            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                if let cb = self.pending.removeValue(forKey: upstreamID) {
                    self.timeouts.removeValue(forKey: upstreamID)
                    cb(.failure(UpstreamError()))
                }
            }
            self.timeouts[upstreamID] = item
            self.queue.asyncAfter(deadline: .now() + timeout, execute: item)

            if self.ready, let conn = self.connection {
                conn.send(content: Data(outbound), completion: .contentProcessed { _ in })
            } else {
                self.waitingSends.append(outbound)
                self.ensureConnection()
            }
        }
    }

    private func allocateID() -> UInt16 {
        var candidate = nextID
        var guardCount = 0
        while pending[candidate] != nil && guardCount < 65536 {
            candidate = candidate &+ 1
            if candidate == 0 { candidate = 1 }
            guardCount += 1
        }
        nextID = candidate &+ 1
        if nextID == 0 { nextID = 1 }
        return candidate
    }

    private func ensureConnection() {
        if connection != nil { return }
        guard let port = NWEndpoint.Port(rawValue: portValue) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(hostString), port: port, using: .udp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.ready = true
                let queued = self.waitingSends
                self.waitingSends.removeAll()
                for q in queued {
                    conn.send(content: Data(q), completion: .contentProcessed { _ in })
                }
                self.receiveLoop(on: conn)
            case .failed, .cancelled:
                self.ready = false
                self.connection = nil
                self.failAllPending()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func failAllPending() {
        let callbacks = pending
        pending.removeAll()
        for (_, item) in timeouts { item.cancel() }
        timeouts.removeAll()
        for (_, cb) in callbacks {
            cb(.failure(UpstreamError()))
        }
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, data.count >= 12 {
                let bytes = [UInt8](data)
                let upstreamID = DNSWire.u16(bytes, 0)
                if let cb = self.pending.removeValue(forKey: upstreamID) {
                    self.timeouts.removeValue(forKey: upstreamID)?.cancel()
                    cb(.success(bytes))
                }
            }
            if error == nil {
                self.receiveLoop(on: conn)
            } else {
                self.ready = false
                self.connection = nil
            }
        }
    }
}
