import UIKit

final class MiniAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)

        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16)

        var lines: [String] = []
        lines.append("MINI OK")
        lines.append("iOS \(UIDevice.current.systemVersion)")
        lines.append("model \(UIDevice.current.model)")
        lines.append("bundle \(Bundle.main.bundleIdentifier ?? "nil")")

        // 用户目录 / 容器是否正常（no-sandbox 权限删错了会在这里暴露）
        let home = NSHomeDirectory()
        lines.append("home \(home)")
        let probe = (home as NSString).appendingPathComponent("sgprobe.txt")
        do {
            try "ok".write(toFile: probe, atomically: true, encoding: .utf8)
            lines.append("write OK")
        } catch {
            lines.append("write FAIL \(error.localizedDescription)")
        }

        // UserDefaults 域是否可用
        UserDefaults.standard.set(1, forKey: "sgprobe")
        lines.append("defaults \(UserDefaults.standard.integer(forKey: "sgprobe"))")

        label.text = lines.joined(separator: "\n")

        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        label.frame = vc.view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(label)

        window.rootViewController = vc
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
