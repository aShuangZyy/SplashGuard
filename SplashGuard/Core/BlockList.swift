import Foundation

/// 只读、内存映射的有序域名表。
///
/// 文件布局（小端）：
///   magic    4 bytes  "SGBL"
///   version  UInt32   == 1
///   count    UInt32
///   offsets  UInt32 * count   每条记录在 blob 中的字节偏移
///   blob     count 条记录，每条 = UInt32 长度 + UTF-8 字节
///
/// 用 mmap 而不是把整个文件读成数组：22 万条 6 MB 的表在扩展进程里
/// 只会按需 fault-in 页，常驻内存远低于 jetsam 阈值。
/// 查询路径上不构造 String，只比对字节。
public final class BlockList {

    private let data: Data
    private let offsets: [UInt32]
    private let blobBase: Int
    public let count: Int

    public init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        guard d.count >= 12 else { return nil }

        let headerOK = d.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return false }
            let p = base.assumingMemoryBound(to: UInt8.self)
            return p[0] == 0x53 && p[1] == 0x47 && p[2] == 0x42 && p[3] == 0x4C
                && BlockList.u32(p, 4) == 1
        }
        guard headerOK else { return nil }

        let n = d.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Int(BlockList.u32(base.assumingMemoryBound(to: UInt8.self), 8))
        }
        guard n >= 0, d.count >= 12 + n * 4 else { return nil }

        var table = [UInt32](repeating: 0, count: n)
        d.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            let p = base.assumingMemoryBound(to: UInt8.self)
            for i in 0..<n {
                table[i] = BlockList.u32(p, 12 + i * 4)
            }
        }

        self.count = n
        self.offsets = table
        self.blobBase = 12 + n * 4
        self.data = d
    }

    private static func u32(_ p: UnsafePointer<UInt8>, _ o: Int) -> UInt32 {
        return UInt32(p[o])
            | (UInt32(p[o + 1]) << 8)
            | (UInt32(p[o + 2]) << 16)
            | (UInt32(p[o + 3]) << 24)
    }

    /// 调用方需传入已小写化的主机名。
    public func contains(_ host: String) -> Bool {
        if count == 0 || host.isEmpty { return false }
        let h = [UInt8](host.utf8)
        if h.isEmpty { return false }

        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return false }
            let p = base.assumingMemoryBound(to: UInt8.self)
            let total = data.count

            var lo = 0
            var hi = count - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let rec = blobBase + Int(offsets[mid])
                if rec + 4 > total { return false }
                let len = Int(BlockList.u32(p, rec))
                let start = rec + 4
                if start + len > total { return false }

                let cmp = BlockList.compare(p, start, len, h)
                if cmp == 0 { return true }
                if cmp < 0 { lo = mid + 1 } else { hi = mid - 1 }
            }
            return false
        }
    }

    private static func compare(_ p: UnsafePointer<UInt8>, _ off: Int, _ len: Int, _ b: [UInt8]) -> Int {
        return b.withUnsafeBufferPointer { (bp: UnsafeBufferPointer<UInt8>) -> Int in
            guard let bb = bp.baseAddress else { return 0 }
            let n = len < bp.count ? len : bp.count
            var i = 0
            while i < n {
                let x = p[off + i]
                let y = bb[i]
                if x != y { return x < y ? -1 : 1 }
                i += 1
            }
            if len == bp.count { return 0 }
            return len < bp.count ? -1 : 1
        }
    }
}
