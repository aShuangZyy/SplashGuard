import Foundation
import NetworkExtension

#if SG_NO_NETWORKEXTENSION

// 诊断用桩：不调用任何 NetworkExtension API，行为与真实实现一致，
// 只把状态固定成"未连接"。用来判断闪退是不是 nehelper 干的。
public final class VPNController {

    public static let shared = VPNController()
    public static let providerBundleID = "com.splashguard.app.tunnel"

    private init() {}

    public var status: NEVPNStatus { .invalid }

    public func load(completion: @escaping (NEVPNStatus) -> Void) {
        DispatchQueue.main.async { completion(.invalid) }
    }

    public func toggle(completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    public func start(completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    public func sendMessage(_ text: String, completion: @escaping (String) -> Void) {
        completion("诊断构建：已禁用 NetworkExtension，无隧道进程可查询")
    }

    public private(set) var history: [String] = []

    public func diagnostics() -> String {
        return "诊断构建：已禁用 NetworkExtension"
    }

    public func oneClickDiagnosis(completion: @escaping (String) -> Void) {
        completion("诊断构建：已禁用 NetworkExtension")
    }

    static func syncMessage(_ text: String, timeout: TimeInterval = 4) -> String {
        return "诊断构建"
    }

    static func appVersionString() -> String { return "diag" }
    static func appexVersionString() -> String { return "diag" }
}

#else

import NetworkExtension

/// 管理 NEPacketTunnelProvider 配置与连接（App 侧）。
public final class VPNController {

    public static let shared = VPNController()
    public static let providerBundleID = "com.splashguard.app.tunnel"
    public static let appexBundleName = "SplashGuardTunnel.appex"

    /// 连接状态变化的时间线，用来判断 appex 是不是启动后立刻退出
    public private(set) var history: [String] = []

    private init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.note("NEVPNStatusDidChange")
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func note(_ text: String) {
        let line = "[\(VPNController.stamp.string(from: Date()))] \(text) status=\(status.rawValue)"
        history.append(line)
        if history.count > 40 { history.removeFirst(history.count - 40) }
    }

    public private(set) var manager: NETunnelProviderManager?

    public var status: NEVPNStatus {
        return manager?.connection.status ?? .invalid
    }

    // MARK: - 读取现有配置

    public func load(completion: @escaping (NEVPNStatus) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }
            let match = (managers ?? []).first { m in
                (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == VPNController.providerBundleID
            }
            self.manager = match ?? managers?.first
            completion(self.status)
        }
    }

    // MARK: - 开关

    public func toggle(completion: @escaping (Error?) -> Void) {
        switch status {
        case .connected, .connecting, .reasserting:
            manager?.connection.stopVPNTunnel()
            completion(nil)
        default:
            start(completion: completion)
        }
    }

    // MARK: - 与隧道进程通信（不依赖共享文件系统）

    /// 向 provider 发一条消息并取回它的状态快照。
    public func sendMessage(_ text: String, completion: @escaping (String) -> Void) {
        guard let manager = manager else {
            completion("隧道尚未创建：请先打开上方的开关，等状态变成「已启用」后再查")
            return
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            completion("当前连接不是 PacketTunnel 会话")
            return
        }
        if status != .connected {
            completion("隧道未连接（status \(status.rawValue)）：请先打开开关并等待「已启用」")
            return
        }
        let responseHandler: (Data?) -> Void = { data in
            guard let data = data, let reply = String(data: data, encoding: .utf8) else {
                completion("隧道已连接，但没有回传数据")
                return
            }
            completion(reply)
        }
        do {
            try session.sendProviderMessage(Data(text.utf8), responseHandler: responseHandler)
        } catch {
            completion("消息通道错误：\(error.localizedDescription)")
        }
    }

    public func start(completion: @escaping (Error?) -> Void) {
        note("start 请求：先清掉旧配置")
        resetConfigs { [weak self] in
            guard let self = self else { return }
            self.prepare { error in
                guard error == nil, let manager = self.manager else {
                    completion(error)
                    return
                }
                // iOS 要求先保存再重新读取，随后才能启动
                manager.saveToPreferences { saveError in
                    if let saveError = saveError {
                        completion(saveError)
                        return
                    }
                    manager.loadFromPreferences { loadError in
                        if let loadError = loadError {
                            completion(loadError)
                            return
                        }
                        manager.isEnabled = true
                        do {
                            try manager.connection.startVPNTunnel()
                            self.note("startVPNTunnel 已发出")
                            completion(nil)
                        } catch {
                            self.note("startVPNTunnel 失败：\(error.localizedDescription)")
                            completion(error)
                        }
                    }
                }
            }
        }
    }

    /// 清掉所有旧 VPN 配置。neagent 会把旧配置连同旧 appex 进程一起回收，
    /// 否则可能出现「App 已经更新、实际跑的还是旧插件」。
    private func resetConfigs(completion: @escaping () -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { completion(); return }
            let all = managers ?? []
            self.note("发现 \(all.count) 个旧配置")
            guard !all.isEmpty else { completion(); return }
            let group = DispatchGroup()
            for m in all {
                if m.connection.status != .invalid { m.connection.stopVPNTunnel() }
                group.enter()
                m.removeFromPreferences { _ in group.leave() }
            }
            group.notify(queue: .main) {
                self.manager = nil
                self.note("旧配置已清除")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { completion() }
            }
        }
    }

    // MARK: - 诊断

    public func diagnostics() -> String {
        var out: [String] = []
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        out.append("App \(appVer)(\(appBuild))")

        let appexInfo = Bundle.main.bundleURL
            .appendingPathComponent("PlugIns")
            .appendingPathComponent(VPNController.appexBundleName)
            .appendingPathComponent("Info.plist")
        if FileManager.default.fileExists(atPath: appexInfo.path),
           let dict = NSDictionary(contentsOf: appexInfo),
           let v = dict["CFBundleShortVersionString"] as? String,
           let b = dict["CFBundleVersion"] as? String {
            out.append("包内 appex \(v)(\(b))")
        } else {
            out.append("包内 appex：缺失")
        }

        if let m = manager, let p = m.protocolConfiguration as? NETunnelProviderProtocol {
            out.append("配置 provider=\(p.providerBundleIdentifier ?? "-") enabled=\(m.isEnabled)")
        } else {
            out.append("配置：尚未创建")
        }
        out.append(String(repeating: "-", count: 30))
        out.append(contentsOf: history.suffix(14))
        return out.joined(separator: "\n")
    }

    /// 一键诊断：清配置 → 启动 → 观察状态 → XPC ping → 直连隧道 DNS → 取隧道日志。
    /// 全部自动串起来，避免人工步骤错位。
    public func oneClickDiagnosis(completion: @escaping (String) -> Void) {
        var lines: [String] = []
        let t0 = Date()
        func stamp(_ m: String) {
            lines.append(String(format: "[%4.1fs] ", Date().timeIntervalSince(t0)) + m)
        }

        lines.append("App \(VPNController.appVersionString()) / 包内 appex \(VPNController.appexVersionString())")
        history.removeAll()

        resetConfigs { [weak self] in
            guard let self = self else { return }
            stamp("旧配置已清除")
            self.prepare { error in
                if let error = error {
                    stamp("新建配置失败：\(error.localizedDescription)")
                    completion(lines.joined(separator: "\n"))
                    return
                }
                guard let manager = self.manager else {
                    stamp("没有 manager")
                    completion(lines.joined(separator: "\n"))
                    return
                }
                manager.saveToPreferences { saveError in
                    if let saveError = saveError {
                        stamp("saveToPreferences 失败：\(saveError.localizedDescription)")
                        completion(lines.joined(separator: "\n"))
                        return
                    }
                    manager.loadFromPreferences { loadError in
                        if let loadError = loadError {
                            stamp("loadFromPreferences 失败：\(loadError.localizedDescription)")
                            completion(lines.joined(separator: "\n"))
                            return
                        }
                        manager.isEnabled = true
                        do {
                            try manager.connection.startVPNTunnel()
                            stamp("startVPNTunnel 已发出")
                        } catch {
                            stamp("startVPNTunnel 异常：\(error.localizedDescription)")
                            completion(lines.joined(separator: "\n"))
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                            stamp("观察 4 秒结束，当前 status=\(manager.connection.status.rawValue)")
                            lines.append("状态时间线：")
                            lines.append(contentsOf: self.history.map { "  " + $0 })
                            self.probeAndReport(lines: lines, t0: t0, completion: completion)
                        }
                    }
                }
            }
        }
    }

    /// 在主线程外做阻塞探测：XPC ping、直连 10.8.0.2 的 DNS、取隧道日志。
    private func probeAndReport(lines: [String], t0: Date, completion: @escaping (String) -> Void) {
        var lines = lines
        func stamp(_ m: String) {
            lines.append(String(format: "[%4.1fs] ", Date().timeIntervalSince(t0)) + m)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // 1. XPC ping：appex 活着就一定回
            let ping = VPNController.syncMessage("ping")
            stamp("XPC ping → \(ping)")

            // 2. 直连隧道 DNS 地址：只有 utun 建好且 appex 在跑才可能拿到我方应答
            let magic = "sg-\(String(Int(Date().timeIntervalSince1970) % 100000)).splashguard.test"
            stamp("拨 10.8.0.2 查 \(magic) → \(SelfTest.askTunnel(magic))")
            stamp("拨 10.8.0.2 查 doubleclick.net → \(SelfTest.askTunnel("doubleclick.net"))")

            // 3. 隧道内日志
            let log = VPNController.syncMessage("log")
            lines.append("隧道日志：")
            lines.append(log)

            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// 同步发一条 provider 消息（带超时），在后台线程调用。
    static func syncMessage(_ text: String, timeout: TimeInterval = 4) -> String {
        guard let manager = VPNController.shared.manager,
              manager.connection.status == .connected,
              let session = manager.connection as? NETunnelProviderSession else {
            return "未连接（status=\(VPNController.shared.manager?.connection.status.rawValue ?? -1)）"
        }
        let sem = DispatchSemaphore(value: 0)
        var reply: String?
        do {
            try session.sendProviderMessage(Data(text.utf8), responseHandler: { data in
                reply = data.flatMap { String(data: $0, encoding: .utf8) }
                sem.signal()
            })
        } catch {
            return "消息通道错误：\(error.localizedDescription)"
        }
        _ = sem.wait(timeout: .now() + timeout)
        return reply ?? "无响应（\(Int(timeout))s 超时）"
    }

    static func appVersionString() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v)(\(b))"
    }

    static func appexVersionString() -> String {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("PlugIns")
            .appendingPathComponent(VPNController.appexBundleName)
            .appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: url) else { return "缺失" }
        let v = dict["CFBundleShortVersionString"] as? String ?? "?"
        let b = dict["CFBundleVersion"] as? String ?? "?"
        return "\(v)(\(b))"
    }

    /// 构造或复用 provider 配置
    private func prepare(completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }
            if let existing = (managers ?? []).first(where: { m in
                (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == VPNController.providerBundleID
            }) {
                self.manager = existing
                self.manager?.isEnabled = true
                completion(nil)
                return
            }
            let manager = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = VPNController.providerBundleID
            proto.serverAddress = "SplashGuard"
            proto.providerConfiguration = [
                "upstream": "223.5.5.5",
                "http_port": 8080
            ]
            manager.protocolConfiguration = proto
            manager.localizedDescription = "SplashGuard"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if error == nil { self.manager = manager }
                completion(error)
            }
        }
    }
}

#endif
