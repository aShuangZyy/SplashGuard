import UIKit

extension Notification.Name {
    static let sgRulesLoaded = Notification.Name("SGRulesLoaded")
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: ViewController())
        window.makeKeyAndVisible()
        self.window = window

        // 规则表 6MB，放到首帧之后再读，避免启动路径上做重活
        DispatchQueue.main.async {
            if let dir = Bundle.main.resourceURL {
                RuleEngine.shared.load(directory: dir)
            }
            NotificationCenter.default.post(name: .sgRulesLoaded, object: nil)
        }
        return true
    }
}
