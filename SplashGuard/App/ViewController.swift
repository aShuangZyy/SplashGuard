import UIKit
import NetworkExtension

final class ViewController: UIViewController {

    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private let testButton = UIButton(type: .system)
    private let logButton = UIButton(type: .system)
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
        resultView.heightAnchor.constraint(equalToConstant: 320).isActive = true

        logButton.setTitle("隧道日志", for: .normal)
        logButton.titleLabel?.font = .systemFont(ofSize: 16)
        logButton.addTarget(self, action: #selector(logTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, detailLabel, toggleButton, testButton, logButton, resultView])
        stack.axis = .vertical
        stack.spacing = 20
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

    @objc private func logTapped() {
        let text = TunnelLog.readAll()
        let lines = text.split(separator: "\n")
        let tail = lines.suffix(60).joined(separator: "\n")
        resultView.text = "=== 隧道日志（末 60 行）===\n" + (tail.isEmpty ? "（空）" : tail)
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
