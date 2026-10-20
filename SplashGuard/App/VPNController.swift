import Foundation
import NetworkExtension

/// 管理 NEPacketTunnelProvider 配置与连接（App 侧）。
public final class VPNController {

    public static let shared = VPNController()
    public static let providerBundleID = "com.splashguard.app.tunnel"

    private init() {}

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

    public func start(completion: @escaping (Error?) -> Void) {
        prepare { [weak self] error in
            guard let self = self, error == nil, let manager = self.manager else {
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
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            }
        }
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
