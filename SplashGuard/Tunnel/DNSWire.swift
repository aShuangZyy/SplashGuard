import Foundation

public struct DNSQuestion {
    public let name: String
    public let qtype: UInt16
    public let qclass: UInt16
    public let wireEnd: Int   // 该问题段结束的字节偏移（不含答案）
}

public enum DNSWire {

    public static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        return (UInt16(b[o]) << 8) | UInt16(b[o + 1])
    }

    static func put16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
        b[o] = UInt8((v >> 8) & 0xFF)
        b[o + 1] = UInt8(v & 0xFF)
    }

    public static func parseQuestions(_ b: [UInt8]) -> [DNSQuestion] {
        guard b.count >= 12 else { return [] }
        let qdcount = Int(u16(b, 4))
        if qdcount == 0 || qdcount > 8 { return [] }
        var out: [DNSQuestion] = []
        var off = 12
        for _ in 0..<qdcount {
            guard let (name, next) = readName(b, off) else { return out }
            off = next
            guard off + 4 <= b.count else { return out }
            let qtype = u16(b, off)
            let qclass = u16(b, off + 2)
            off += 4
            out.append(DNSQuestion(name: name, qtype: qtype, qclass: qclass, wireEnd: off))
        }
        return out
    }

    static func readName(_ b: [UInt8], _ start: Int) -> (String, Int)? {
        var off = start
        var labels: [String] = []
        var jumps = 0
        var endOfName = -1          // 仅在没有发生指针跳转时有意义

        while off < b.count {
            let len = Int(b[off])
            if len == 0 {
                off += 1
                if jumps == 0 { endOfName = off }
                break
            }
            if len & 0xC0 == 0xC0 {
                guard off + 1 < b.count else { return nil }
                jumps += 1
                if jumps > 4 { return nil }
                if endOfName < 0 { endOfName = off + 2 }
                off = Int(u16(b, off) & 0x3FFF)
                continue
            }
            guard off + 1 + len <= b.count else { return nil }
            let bytes = Array(b[(off + 1)..<(off + 1 + len)])
            labels.append(String(decoding: bytes, as: UTF8.self))
            off += 1 + len
            if jumps == 0 { endOfName = off }
        }
        if endOfName < 0 { endOfName = off }
        return (labels.joined(separator: "."), endOfName)
    }

    /// 构造「域名被拦截」的应答：A 返回 0.0.0.0，AAAA 返回 ::，其余类型返回空答案
    public static func blockedResponse(query: [UInt8], question: DNSQuestion) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 12)
        guard query.count >= 12 else { return out }
        out[0] = query[0]
        out[1] = query[1]
        out[2] = 0x81   // QR=1, opcode=0, AA=0, TC=0, RD=1
        out[3] = 0x80   // RA=1, RCODE=0
        put16(&out, 4, 1)   // QDCOUNT
        if question.qtype == 1 || question.qtype == 28 {
            put16(&out, 6, 1)   // ANCOUNT
        } else {
            put16(&out, 6, 0)
        }
        put16(&out, 8, 0)
        put16(&out, 10, 0)

        guard question.wireEnd <= query.count else { return out }
        out.append(contentsOf: query[12..<question.wireEnd])

        if question.qtype == 1 {
            out.append(contentsOf: [0xC0, 0x0C])           // 名称指针
            out.append(contentsOf: [0x00, 0x01])           // TYPE A
            out.append(contentsOf: [0x00, 0x01])           // CLASS IN
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x3C]) // TTL 60
            out.append(contentsOf: [0x00, 0x04])           // RDLENGTH
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        } else if question.qtype == 28 {
            out.append(contentsOf: [0xC0, 0x0C])
            out.append(contentsOf: [0x00, 0x1C])
            out.append(contentsOf: [0x00, 0x01])
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x3C])
            out.append(contentsOf: [0x00, 0x10])
            out.append(contentsOf: [UInt8](repeating: 0, count: 16))
        }
        return out
    }

    public static func errorResponse(query: [UInt8], rcode: UInt8) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 12)
        guard query.count >= 12 else { return out }
        out[0] = query[0]
        out[1] = query[1]
        out[2] = 0x81
        out[3] = UInt8(0x80 | (rcode & 0x0F))
        put16(&out, 4, 0)
        return out
    }
}
