import Foundation
import Darwin

/// DNS 是否真被隧道接管的现场自检。
///
/// 三个独立信号：
/// 1. 规则表判定（纯本地，与本机网络无关）
/// 2. 直连隧道 DNS 10.8.0.2:53 查询（直接证明隧道里那个解析器活着）
/// 3. 系统解析 getaddrinfo（证明 iOS 把 DNS 交给隧道了）
enum SelfTest {

    struct Probe {
        let host: String
        let note: String
    }

    // 前两条是典型广告域（应当在拦截表里），后两条是对照域（绝不能拦）。
    static let probes: [Probe] = [
        Probe(host: "doubleclick.net", note: "典型广告域，应被拦截"),
        Probe(host: "google-analytics.com", note: "典型统计域，应被拦截"),
        Probe(host: "www.apple.com", note: "对照域，必须正常解析"),
        Probe(host: "www.baidu.com", note: "对照域，必须正常解析")
    ]

    static func run() -> String {
        var out: [String] = []
        out.append("隧道 DNS  10.8.0.2:53")
        out.append(String(repeating: "-", count: 40))

        var tunnelOK = 0, blockOK = 0
        for p in probes {
            let blocked = RuleEngine.shared.shouldBlock(host: p.host)
            let viaTunnel = query(host: p.host, server: "10.8.0.2")
            let system = systemResolve(host: p.host)

            out.append(p.host)
            out.append("  规则表: \(blocked ? "拦截" : "放行")　(\(p.note))")
            out.append("  隧道DNS: \(viaTunnel)")
            out.append("  系统解析: \(system)")

            if viaTunnel.hasPrefix("0.0.0.0") || viaTunnel.hasPrefix("::") { tunnelOK += 1 }
            if blocked && viaTunnel.hasPrefix("0.0.0.0") { blockOK += 1 }
        }

        out.append(String(repeating: "-", count: 40))
        if tunnelOK == probes.count {
            out.append("结论：隧道 DNS 全部应答 → 接管成功")
        } else if tunnelOK == 0 {
            out.append("结论：隧道 DNS 无应答 → 隧道没接 DNS（看 NEDNSSettings）")
        } else {
            out.append("结论：隧道 DNS 部分应答（\(tunnelOK)/\(probes.count)）")
        }
        if blockOK > 0 {
            out.append("拦截生效：\(blockOK) 个广告域被解析成 0.0.0.0")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 自己组一个 A 查询，直接发给隧道 DNS

    private static func makeQuery(_ host: String) -> [UInt8] {
        var b: [UInt8] = [0x5A, 0x5A, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for label in host.split(separator: ".") {
            let bytes = Array(label.utf8)
            b.append(UInt8(min(bytes.count, 63)))
            b.append(contentsOf: bytes.prefix(63))
        }
        b.append(0)
        b.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        return b
    }

    private static func query(host: String, server: String, port: UInt16 = 53) -> String {
        let q = makeQuery(host)
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return "socket 失败" }
        defer { Darwin.close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, server, &addr.sin_addr)

        let sent = withUnsafePointer(to: &addr) { p -> Int in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.sendto(fd, q, q.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == q.count else { return "发送失败" }

        var buf = [UInt8](repeating: 0, count: 1500)
        let n = Darwin.recv(fd, &buf, buf.count, 0)
        guard n > 12 else { return "无响应（2s 超时）" }
        return parseAnswer(Array(buf[0..<n]))
    }

    private static func parseAnswer(_ b: [UInt8]) -> String {
        guard b.count >= 12 else { return "应答过短" }

        func u16(_ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }

        let flags = u16(2)
        let qd = u16(4), an = u16(6)
        if flags & 0x000F != 0 { return "rcode=\(flags & 0x000F)（被拒/失败）" }

        var off = 12
        for _ in 0..<qd {
            guard let next = skipName(b, off) else { return "问题段损坏" }
            off = next + 4
        }
        guard off <= b.count else { return "问题段越界" }

        var ips: [String] = []
        for _ in 0..<an {
            guard let next = skipName(b, off) else { break }
            off = next
            guard off + 10 <= b.count else { break }
            let type = u16(off), rdlen = u16(off + 8)
            off += 10
            guard off + rdlen <= b.count else { break }
            if type == 1 && rdlen == 4 {
                ips.append("\(b[off]).\(b[off + 1]).\(b[off + 2]).\(b[off + 3])")
            } else if type == 28 && rdlen == 16 {
                ips.append("IPv6")
            }
            off += rdlen
        }
        if ips.isEmpty { return an == 0 ? "无 A 记录（NXDOMAIN/空应答）" : "无可用地址" }
        return ips.joined(separator: ", ")
    }

    private static func skipName(_ b: [UInt8], _ start: Int) -> Int? {
        var off = start
        var guardCount = 0
        while off < b.count {
            let len = Int(b[off])
            if len == 0 { return off + 1 }
            if len & 0xC0 == 0xC0 { return off + 2 }   // 压缩指针
            off += 1 + len
            guardCount += 1
            if guardCount > 128 { return nil }
        }
        return nil
    }

    // MARK: - 系统解析（走 iOS 的解析器，会不会经过隧道就看这里）

    private static func systemResolve(host: String) -> String {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0, let first = res else {
            return "失败 rc=\(rc)"
        }
        defer { freeaddrinfo(first) }

        var ips: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let node = cur {
            if let sa = node.pointee.ai_addr {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                }
                let ip = String(cString: buf)
                if !ip.isEmpty { ips.append(ip) }
            }
            cur = node.pointee.ai_next
        }
        return ips.isEmpty ? "无结果" : ips.joined(separator: ", ")
    }
}
