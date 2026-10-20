// 在 Linux / macOS 上单独验证 DNS 报文编解码与 IP/UDP 组包。
// 用法见同目录 run.sh。
import Foundation

func makeQuery(_ name: String, qtype: UInt16, txid: UInt16) -> [UInt8] {
    var b: [UInt8] = [UInt8(txid >> 8), UInt8(txid & 0xFF), 0x01, 0x00,
                      0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    for label in name.split(separator: ".") {
        let bytes = Array(label.utf8)
        b.append(UInt8(bytes.count))
        b.append(contentsOf: bytes)
    }
    b.append(0)
    b.append(UInt8(qtype >> 8)); b.append(UInt8(qtype & 0xFF))
    b.append(0x00); b.append(0x01)
    return b
}

func hex(_ a: [UInt8]) -> String { a.map { String(format: "%02x", $0) }.joined() }

let names = [
    "a.co",
    "ad.toutiao.com",
    "p1-ad-sign.byteimg.com",
    "very-long-subdomain-name-for-splash-advertising-sdk-delivery.cnzz.com",
    "x.y.z.w.v.u.t.s.r.q.p.o.n.m.l.k.j.i.h.g.f.e.d.c.b.a.example",
    "single",
]
for (i, n) in names.enumerated() {
    let q = makeQuery(n, qtype: 1, txid: UInt16(i + 1))
    guard let f = DNSWire.parseQuestions(q).first else { print("FAIL parse \(n)"); continue }
    let r = DNSWire.blockedResponse(query: q, question: f)
    print("name[\(i)] \(f.name == n ? "ok" : "MISMATCH:\(f.name)") type=\(f.qtype) respLen=\(r.count)")
}

// AAAA 应答
let q6 = makeQuery("ad.toutiao.com", qtype: 28, txid: 0x1234)
if let f = DNSWire.parseQuestions(q6).first {
    let r = DNSWire.blockedResponse(query: q6, question: f)
    print("AAAA len=\(r.count) answers=\(DNSWire.u16(r, 6))")
}

// 组包 → 校验
let q = makeQuery("ad.toutiao.com", qtype: 1, txid: 0x1234)
var ip: [UInt8] = [0x45, 0x00, 0, 0, 0x00, 0x00, 0x40, 0x00, 64, 17, 0, 0]
ip += [10, 8, 0, 1]
ip += [10, 8, 0, 2]
let total = UInt16(ip.count + 8 + q.count)
ip[2] = UInt8(total >> 8); ip[3] = UInt8(total & 0xFF)
ip += [0x30, 0x39, 0x00, 0x35]
let ulen = UInt16(8 + q.count)
ip += [UInt8(ulen >> 8), UInt8(ulen & 0xFF), 0x00, 0x00]
ip += q
if let flow = IPPacket.parseUDP(ip), let f = DNSWire.parseQuestions(q).first {
    let resp = IPPacket.buildUDPResponse(for: flow, payload: DNSWire.blockedResponse(query: q, question: f))
    print("built resp len=\(resp.count) head=\(hex(Array(resp.prefix(20))))")
}

// 模糊测试
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> UInt8 {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return UInt8((seed >> 33) & 0xFF)
}
for _ in 0..<200000 {
    let len = Int(rnd()) % 80
    var buf = [UInt8](repeating: 0, count: len)
    for i in 0..<len { buf[i] = rnd() }
    if let f = DNSWire.parseQuestions(buf).first {
        _ = DNSWire.blockedResponse(query: buf, question: f)
    }
    _ = IPPacket.parseUDP(buf)
}
print("fuzz 200k: no trap")
