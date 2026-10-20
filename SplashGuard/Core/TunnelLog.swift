import Foundation

/// 隧道进程（appex）与宿主 App 共享同一个数据容器，
/// 所以日志写在这里，App 侧直接读同一个文件就能看到隧道内部的判定过程。
public enum TunnelLog {

    static var fileURL: URL? {
        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return caches.appendingPathComponent("tunnel.log")
        }
        let home = NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/tunnel.log")
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public static func append(_ line: String) {
        guard let url = fileURL else { return }
        let text = "[\(stamp.string(from: Date()))] \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        trimIfNeeded(url)
    }

    public static func reset() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public static func readAll() -> String {
        guard let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "（没有日志：隧道还没启动过，或容器路径不可写）"
        }
        return text
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 96_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let keep = String(text.suffix(48_000))
        try? keep.write(to: url, atomically: true, encoding: .utf8)
    }
}
