import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let workQueue = DispatchQueue(label: "com.splashguard.tunnel")
    private let resolver = UpstreamResolver(host: "223.5.5.5")
    private var readLoopActive = false
    private var blockedCount = 0
    private var totalCount = 0

    // MARK: - 生命周期

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        TunnelLog.reset()
        TunnelLog.append("startTunnel")
        loadRules()

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.8.0.2")

        let v4 = NEIPv4Settings(addresses: ["10.8.0.1"], subnetMasks: ["255.255.255.0"])
        v4.includedRoutes = [NEIPv4Route(destinationAddress: "10.8.0.0", subnetMask: "255.255.255.0")]
        v4.excludedRoutes = []
        settings.ipv4Settings = v4

        let dns = NEDNSSettings(servers: ["10.8.0.2"])
        dns.matchDomains = nil          // nil = 对所有域名生效
        settings.dnsSettings = dns
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                completionHandler(error)
                return
            }
            self.readLoopActive = true
            self.readPackets()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        readLoopActive = false
        TunnelLog.append("stop reason=\(reason.rawValue) total=\(totalCount) blocked=\(blockedCount)")
        NSLog("[SplashGuard] stop, reason=%ld total=%ld blocked=%ld",
              reason.rawValue, totalCount, blockedCount)
        completionHandler()
    }

    // MARK: - 规则

    private func loadRules() {
        TunnelLog.append("bundle main=\(Bundle.main.bundlePath)")
        TunnelLog.append("bundle exe=\(Bundle(for: PacketTunnelProvider.self).executableURL?.path ?? "-")")

        // appex 里优先读自己的资源；个别情况下 appex 的资源没被拷进去，
        // 就退回到宿主 App 的 bundle（PlugIns/X.appex 的上两级）。
        var candidates: [URL] = []
        if let own = Bundle(for: PacketTunnelProvider.self).resourceURL { candidates.append(own) }
        let appexURL = Bundle(for: PacketTunnelProvider.self).bundleURL
        let appURL = appexURL.deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(appURL)
        // 再兜一层：资源被放进了 appex 内的 Resources 子目录
        candidates.append(appexURL.appendingPathComponent("Resources"))
        candidates.append(appURL.appendingPathComponent("Resources"))

        for dir in candidates {
            RuleEngine.shared.load(directory: dir)
            let st = RuleEngine.shared.stats
            TunnelLog.append("load dir=\(dir.path) suffix=\(st.suffixCount) exact=\(st.exactCount) kw=\(st.keywordCount) ms=\(st.loadMillis) err=\(RuleEngine.shared.loadError ?? "-")")
            NSLog("[SplashGuard] load dir=%@ suffix=%ld err=%@", dir.path, st.suffixCount, RuleEngine.shared.loadError ?? "-")
            if RuleEngine.shared.isLoaded && st.suffixCount > 0 { break }
        }
    }

    // MARK: - App 侧查询（不依赖文件系统）

    override func handleAppMessage(_ messageData: Data,
                                   completionHandler: ((Data?) -> Void)?) {
        let cmd = String(data: messageData, encoding: .utf8) ?? ""
        if cmd == "reload" {
            loadRules()
        }

        let st = RuleEngine.shared.stats
        let probes: [String: Any] = [
            "doubleclick.net": RuleEngine.shared.shouldBlock(host: "doubleclick.net"),
            "google-analytics.com": RuleEngine.shared.shouldBlock(host: "google-analytics.com"),
            "www.apple.com": RuleEngine.shared.shouldBlock(host: "www.apple.com")
        ]
        let info: [String: Any] = [
            "loaded": RuleEngine.shared.isLoaded,
            "suffix": st.suffixCount,
            "exact": st.exactCount,
            "keyword": st.keywordCount,
            "millis": st.loadMillis,
            "error": RuleEngine.shared.loadError ?? "-",
            "total": totalCount,
            "blocked": blockedCount,
            "probe": probes,
            "log": TunnelLog.tail(60)
        ]
        let data = try? JSONSerialization.data(withJSONObject: info,
                                               options: [.prettyPrinted, .sortedKeys])
        completionHandler?(data)
    }

    // MARK: - 收包

    private func readPackets() {
        guard readLoopActive else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            for (index, data) in packets.enumerated() {
                let proto = index < protocols.count ? protocols[index].int32Value : AF_INET
                self.handle([UInt8](data), protocolNumber: proto)
            }
            self.readPackets()
        }
    }

    private func handle(_ packet: [UInt8], protocolNumber: Int32) {
        guard protocolNumber == AF_INET else { return }
        guard let flow = IPPacket.parseUDP(packet) else { return }
        guard flow.destPort == 53 else { return }

        totalCount += 1
        let query = flow.payload
        guard let question = DNSWire.parseQuestions(query).first else {
            forward(query, flow: flow)
            return
        }

        let blocked = RuleEngine.shared.shouldBlock(host: question.name)
        if totalCount <= 40 {
            TunnelLog.append("q \(question.name) -> \(blocked ? "BLOCK" : "forward")")
        } else if totalCount % 200 == 0 {
            TunnelLog.append("stats total=\(totalCount) blocked=\(blockedCount) loaded=\(RuleEngine.shared.isLoaded)")
        }

        if blocked {
            blockedCount += 1
            let response = DNSWire.blockedResponse(query: query, question: question)
            writeBack(response, flow: flow)
            return
        }
        forward(query, flow: flow)
    }

    private func forward(_ query: [UInt8], flow: IPPacket.UDPFlow) {
        resolver.resolve(query: query) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let response):
                self.writeBack(response, flow: flow)
            case .failure:
                let fail = DNSWire.errorResponse(query: query, rcode: 2)   // SERVFAIL
                self.writeBack(fail, flow: flow)
            }
        }
    }

    private func writeBack(_ dnsPayload: [UInt8], flow: IPPacket.UDPFlow) {
        let packet = IPPacket.buildUDPResponse(for: flow, payload: dnsPayload)
        packetFlow.writePackets([Data(packet)], withProtocols: [NSNumber(value: AF_INET)])
    }
}
