import UIKit
import NetworkExtension

final class ViewController: UIViewController {

    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private let testButton = UIButton(type: .system)
    private let logButton = UIButton(type: .system)
    private let diagButton = UIButton(type: .system)
    private let resultView = UITextView()
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SplashGuard"
        view.backgroundColor = .systemBackground

        statusLabel.font = .boldSystemFont(ofSize: 22)
        statusLabel.textAlignment = .center
        statusLabel.text = "未启用"

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center

        toggleButton.setTitle("开启过滤", for: .normal)
        toggleButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

        testButton.setTitle("DNS 自检", for: .normal)
        testButton.titleLabel?.font = .systemFont(ofSize: 16)
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)

        resultView.isEditable = false
        resultView.isScrollEnabled = true
        resultView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        resultView.backgroundColor = .secondarySystemBackground
        resultView.layer.cornerRadius = 8
        resultView.text = "点「DNS 自检」查看隧道是否接管了 DNS"
        resultView.heightAnchor.constraint(equalToConstant: 250).isActive = true

        logButton.setTitle("隧道日志", for: .normal)
        logButton.titleLabel?.font = .systemFont(ofSize: 16)
        logButton.addTarget(self, action: #selector(logTapped), for: .touchUpInside)

        diagButton.setTitle("连接诊断", for: .normal)
        diagButton.titleLabel?.font = .systemFont(ofSize: 16)
        diagButton.addTarget(self, action: #selector(diagTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, detailLabel, toggleButton, testButton, logButton, diagButton, resultView])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28)
        ])

        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        NotificationCenter.default.addObserver(
            forName: .sgRulesLoaded, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        VPNController.shared.load { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    @objc private func toggleTapped() {
        VPNController.shared.toggle { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.detailLabel.text = "操作失败：\(error.localizedDescription)"
                }
                self?.refresh()
            }
        }
    }

    @objc private func testTapped() {
        testButton.isEnabled = false
        resultView.text = "自检中…（每个域名最多等 2 秒）"
        DispatchQueue.global(qos: .userInitiated).async {
            let report = SelfTest.run()
            DispatchQueue.main.async { [weak self] in
                self?.resultView.text = report
                self?.testButton.isEnabled = true
            }
        }
    }

    @objc private func diagTapped() {
        resultView.text = VPNController.shared.diagnostics()
    }

    @objc private func logTapped() {
        resultView.text = "正在向隧道进程查询…"
        VPNController.shared.sendMessage("status") { [weak self] reply in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 没连上时退回到文件日志（老通道），方便对照
                let cantReach = reply.hasPrefix("隧道尚未创建")
                    || reply.hasPrefix("隧道未连接")
                    || reply.hasPrefix("当前连接不是")
                    || reply.hasPrefix("诊断构建")
                    || reply.hasPrefix("消息通道错误")
                if cantReach {
                    let text = TunnelLog.readAll()
                    let tail = text.split(separator: "\n").suffix(60).joined(separator: "\n")
                    self.resultView.text = reply
                        + "\n\n=== 文件日志（末 60 行）===\n"
                        + (tail.isEmpty ? "（空）" : tail)
                } else {
                    self.resultView.text = reply
                }
            }
        }
    }

    private func refresh() {
        let status = VPNController.shared.status
        switch status {
        case .connected:
            statusLabel.text = "已启用"
            statusLabel.textColor = .systemGreen
            toggleButton.setTitle("关闭过滤", for: .normal)
        case .connecting, .reasserting:
            statusLabel.text = "连接中…"
            statusLabel.textColor = .systemOrange
        case .disconnecting:
            statusLabel.text = "断开中…"
            statusLabel.textColor = .systemOrange
        default:
            statusLabel.text = "未启用"
            statusLabel.textColor = .label
            toggleButton.setTitle("开启过滤", for: .normal)
        }

        let stats = RuleEngine.shared.stats
        if RuleEngine.shared.isLoaded {
            detailLabel.text = """
            规则：\(stats.suffixCount) 条后缀 / \(stats.exactCount) 条精确
            关键词：\(stats.keywordCount) · 重写：\(stats.rewriteCount) · 载入 \(stats.loadMillis)ms
            """
        } else {
            detailLabel.text = RuleEngine.shared.loadError ?? "规则未载入"
        }
    }
}
