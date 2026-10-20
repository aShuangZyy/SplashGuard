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
