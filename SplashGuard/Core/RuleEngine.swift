import Foundation

public enum RuleAction: Equatable {
    case reject
    case rejectDict
    case rejectArray
    case rejectTinyGIF
    case scriptResponse(String)
    case scriptRequest(String)

    public var displayName: String {
        switch self {
        case .reject: return "REJECT"
        case .rejectDict: return "REJECT-DICT"
        case .rejectArray: return "REJECT-ARRAY"
        case .rejectTinyGIF: return "REJECT-TINYGIF"
        case .scriptResponse(let n): return "SCRIPT-RESPONSE(\(n))"
        case .scriptRequest(let n): return "SCRIPT-REQUEST(\(n))"
        }
    }
}

public final class RuleEngine {

    public static let shared = RuleEngine()
    private init() {}

    private var suffixList: BlockList?
    private var exactList: BlockList?

    public private(set) var keywords: [String] = []
    /// 关键字的 UTF-8 形式，查询时按字节比对，避免每条规则都走 String 桥接
    private var keywordBytes: [[UInt8]] = []
    public private(set) var allowExact = Set<String>()
    public private(set) var allowSuffix: [String] = []
    public private(set) var mitmHosts: [String] = []
    /// 优先于放行表判定的广告子域（放行的大 CDN 里混着的广告位）
    public private(set) var forceSuffix: [String] = []
    private var rewrites: [RewriteRule] = []

    public private(set) var isLoaded = false
    public private(set) var loadError: String?
    public private(set) var stats = Stats()

    public struct Stats {
        public var suffixCount = 0
        public var exactCount = 0
        public var keywordCount = 0
        public var rewriteCount = 0
        public var mitmCount = 0
        public var loadMillis = 0
    }

    private struct RewriteRule {
        let raw: String
        let regex: NSRegularExpression
        let action: RuleAction
    }

    // MARK: - 载入

    /// directory 里放 block_suffix.bin / block_exact.bin / rules.module
    public func load(directory: URL) {
        let t0 = Date()
        var s = Stats()

        let suf = directory.appendingPathComponent("block_suffix.bin")
        let exa = directory.appendingPathComponent("block_exact.bin")
        let mod = directory.appendingPathComponent("rules.module")

        suffixList = BlockList(url: suf)
        exactList = BlockList(url: exa)
        s.suffixCount = suffixList?.count ?? 0
        s.exactCount = exactList?.count ?? 0

        if suffixList == nil || exactList == nil {
            loadError = "block_*.bin 缺失或损坏（suffix=\(suffixList != nil) exact=\(exactList != nil)）"
        }

        if let text = try? String(contentsOf: mod, encoding: .utf8) {
            parseModule(text)
        } else {
            loadError = (loadError.map { $0 + "；" } ?? "") + "rules.module 缺失"
        }

        keywordBytes = keywords.map { Array($0.utf8) }
        s.keywordCount = keywords.count
        s.rewriteCount = rewrites.count
        s.mitmCount = mitmHosts.count
        s.loadMillis = Int(Date().timeIntervalSince(t0) * 1000)
        stats = s
        isLoaded = loadError == nil || (suffixList != nil)
    }

    /// 兼容 Loon / Surge 的模块片段写法
    private func parseModule(_ text: String) {
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().lowercased()
                continue
            }
            switch section {
            case "rule":        parseRuleLine(line)
            case "rewrite":     parseRewriteLine(line)
            case "mitm":        parseMITMLine(line)
            case "allow":       parseAllowLine(line)
            case "force":       forceSuffix.append(line.lowercased())
            default:            break
            }
        }
    }

    private func parseRuleLine(_ line: String) {
        let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return }
        let type = parts[0].uppercased()
        let value = parts[1]
        switch type {
        case "DOMAIN":
            exactInline.insert(value.lowercased())
        case "DOMAIN-SUFFIX":
            suffixInline.insert(value.lowercased())
        case "DOMAIN-KEYWORD":
            keywords.append(value.lowercased())
        default:
            break
        }
    }

    private var exactInline = Set<String>()
    private var suffixInline = Set<String>()

    private func parseRewriteLine(_ line: String) {
        // 格式： <正则>  -  <动作> [脚本名]
        let fields = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard fields.count >= 2 else { return }
        var idx = 1
        if fields[idx] == "-" { idx += 1 }
        guard idx < fields.count else { return }
        let actionWord = fields[idx].lowercased()
        var action: RuleAction?
        switch actionWord {
        case "reject":            action = .reject
        case "reject-dict":       action = .rejectDict
        case "reject-array":      action = .rejectArray
        case "reject-tinygif":    action = .rejectTinyGIF
        case "script-response-body", "script-response":
            if idx + 1 < fields.count { action = .scriptResponse(fields[idx + 1]) }
        case "script-request-body", "script-request":
            if idx + 1 < fields.count { action = .scriptRequest(fields[idx + 1]) }
        default: break
        }
        guard let act = action else { return }
        guard let re = try? NSRegularExpression(pattern: fields[0], options: [.caseInsensitive]) else { return }
        rewrites.append(RewriteRule(raw: fields[0], regex: re, action: act))
    }

    private func parseMITMLine(_ line: String) {
        var body = line
        if body.lowercased().hasPrefix("hostname") {
            if let eq = body.firstIndex(of: "=") {
                body = String(body[body.index(after: eq)...])
            }
        }
        for h in body.split(separator: ",") {
            let v = h.trimmingCharacters(in: .whitespaces).lowercased()
            if !v.isEmpty { mitmHosts.append(v) }
        }
    }

    private func parseAllowLine(_ line: String) {
        let v = line.lowercased()
        if v.hasPrefix("*.") { allowSuffix.append(String(v.dropFirst(2))) }
        else if v.hasPrefix(".") { allowSuffix.append(String(v.dropFirst())) }
        else { allowExact.insert(v) }
    }

    // MARK: - 判定

    public func shouldBlock(host rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return false }

        for f in forceSuffix where host == f || host.hasSuffix("." + f) { return true }
        if !keywordBytes.isEmpty {
            let hb = Array(host.utf8)
            for k in keywordBytes where RuleEngine.containsBytes(hb, k) { return true }
        }

        if allowExact.contains(host) { return false }
        for s in allowSuffix where host == s || host.hasSuffix("." + s) { return false }

        if let exact = exactList, exact.contains(host) { return true }
        if exactInline.contains(host) { return true }

        if let suffix = suffixList, matchSuffix(suffix, host) { return true }
        if matchInlineSuffix(host) { return true }

        return false
    }

    @inline(__always)
    private static func containsBytes(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        let first = needle[0]
        let last = hay.count - needle.count
        var i = 0
        hay.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                guard let hp = h.baseAddress, let np = n.baseAddress else { return }
                while i <= last {
                    if hp[i] == first {
                        var j = 1
                        while j < n.count && hp[i + j] == np[j] { j += 1 }
                        if j == n.count { i = -1; return }
                    }
                    i += 1
                }
            }
        }
        return i == -1
    }

    private func matchSuffix(_ list: BlockList, _ host: String) -> Bool {
        var candidate = host
        while true {
            if list.contains(candidate) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { break }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
        return false
    }

    private func matchInlineSuffix(_ host: String) -> Bool {
        guard !suffixInline.isEmpty else { return false }
        var candidate = host
        while true {
            if suffixInline.contains(candidate) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { break }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
        return false
    }

    public func rewrite(for url: String) -> RuleAction? {
        guard !rewrites.isEmpty else { return nil }
        let full = url as NSString
        let range = NSRange(location: 0, length: full.length)
        for rule in rewrites {
            if rule.regex.firstMatch(in: url, options: [], range: range) != nil {
                return rule.action
            }
        }
        return nil
    }

    /// MITM 名单：支持 * 通配
    public func needsMITM(host rawHost: String) -> Bool {
        if mitmHosts.isEmpty { return false }
        let host = rawHost.lowercased()
        for pattern in mitmHosts {
            if pattern == "*" { return true }
            if pattern.hasPrefix("*.") {
                let base = String(pattern.dropFirst(2))
                if host == base || host.hasSuffix("." + base) { return true }
            } else if host == pattern {
                return true
            }
        }
        return false
    }
}
