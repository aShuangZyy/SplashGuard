import Foundation

/// 最小 IPv4/UDP 处理：只服务于隧道内的 DNS 转发。
public enum IPPacket {

    public struct UDPFlow {
        public let sourceIP: [UInt8]      // 4 bytes，客户端地址
        public let destIP: [UInt8]        // 4 bytes，目标地址
        public let sourcePort: UInt16
        public let destPort: UInt16
        public let payload: [UInt8]
    }

    public static func parseUDP(_ packet: [UInt8]) -> UDPFlow? {
        guard packet.count >= 20 else { return nil }
        let version = packet[0] >> 4
        guard version == 4 else { return nil }
        let ihl = Int(packet[0] & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl + 8 else { return nil }
        guard packet[9] == 17 else { return nil }          // UDP
        let totalLen = Int(DNSWire.u16(packet, 2))
        let end = min(totalLen == 0 ? packet.count : totalLen, packet.count)
        let srcPort = DNSWire.u16(packet, ihl)
        let dstPort = DNSWire.u16(packet, ihl + 2)
        let udpLen = Int(DNSWire.u16(packet, ihl + 4))
        var payloadEnd = ihl + max(udpLen, 8)
        if payloadEnd > end { payloadEnd = end }
        guard payloadEnd >= ihl + 8 else { return nil }
        let payload = Array(packet[(ihl + 8)..<payloadEnd])
        return UDPFlow(sourceIP: Array(packet[12..<16]),
                       destIP: Array(packet[16..<20]),
                       sourcePort: srcPort,
                       destPort: dstPort,
                       payload: payload)
    }

    /// 用原始报文的方向信息构造反向 UDP 包
    public static func buildUDPResponse(for flow: UDPFlow, payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 20 + 8 + payload.count)
        out[0] = 0x45
        out[1] = 0x00
        let total = out.count
        DNSWire.put16(&out, 2, UInt16(total))
        DNSWire.put16(&out, 4, 0)
        DNSWire.put16(&out, 6, 0x4000)     // DF
        out[8] = 64
        out[9] = 17
        // 12..16 = 源地址 = 原目标
        out[12] = flow.destIP[0]; out[13] = flow.destIP[1]
        out[14] = flow.destIP[2]; out[15] = flow.destIP[3]
        // 16..20 = 目标地址 = 原源
        out[16] = flow.sourceIP[0]; out[17] = flow.sourceIP[1]
        out[18] = flow.sourceIP[2]; out[19] = flow.sourceIP[3]
        DNSWire.put16(&out, 10, checksum(Array(out[0..<20]), start: 0))
        // UDP
        DNSWire.put16(&out, 20, flow.destPort)
        DNSWire.put16(&out, 22, flow.sourcePort)
        DNSWire.put16(&out, 24, UInt16(8 + payload.count))
        DNSWire.put16(&out, 26, 0)         // IPv4 UDP 校验和可省略
        out.replaceSubrange((28..<out.count), with: payload)
        return out
    }

    static func checksum(_ header: [UInt8], start: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = start
        var copy = header
        DNSWire.put16(&copy, 10, 0)
        while i + 1 < copy.count {
            sum += UInt32(DNSWire.u16(copy, i))
            i += 2
        }
        if i < copy.count { sum += UInt32(copy[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return UInt16((~sum) & 0xFFFF)
    }
}
