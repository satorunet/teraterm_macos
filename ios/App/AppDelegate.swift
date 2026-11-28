import UIKit
import TeraCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SPPaths.prepare()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

/// 画面 (シーン)。新しい iOS ではシーンの作りが必須になるので、ウインドウはここで作る
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    static weak var current: SceneDelegate?
    private var nav: UINavigationController? { window?.rootViewController as? UINavigationController }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        Self.current = self
        let w = UIWindow(windowScene: ws)
        let nav = UINavigationController(rootViewController: HostListViewController())
        w.rootViewController = nav
        w.tintColor = UIColor(red: 0.95, green: 0.72, blue: 0.0, alpha: 1)   // Tera Term の黄色
        w.makeKeyAndVisible()
        window = w
        // 起動のきっかけ (QR コードのリンク・Handoff)
        if let u = options.urlContexts.first?.url { open(u) }
        if let a = options.userActivities.first { continueActivity(a) }
        // 確認用: TERASP_OPEN="ssh user@host:22" ですぐつなぐ (シミュレーターの起動引数)
        let env = ProcessInfo.processInfo.environment
        if let s = env["TERASP_OPEN"], var h = SPHost.parse(s) {
            // TERASP_MACRO="hello.ttl": つないだあとに macros フォルダのマクロを動かす
            h.macro = env["TERASP_MACRO"] ?? ""
            nav.pushViewController(SessionViewController(host: h), animated: false)
        }
        // 確認用: TERASP_LINK="Mac の名前,コード" で「Mac と連携」を開いてすぐつなぐ (リンクの確認を通さない)
        if let s = env["TERASP_LINK"] {
            let p = s.split(separator: ",").map(String.init)
            if p.count == 2 {
                LinkViewController.saveCode(p[1], for: p[0])
                DispatchQueue.main.async { self.showLink(autoConnect: p[0]) }
            }
        }
    }

    /// Mac の QR コードを読んで開いた (teraterm-sp://pair?mac=...&code=...)
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let u = URLContexts.first?.url { open(u) }
    }
    private func open(_ url: URL) {
        guard let p = TeraLink.parsePairURL(url) else { return }
        LinkViewController.saveCode(p.code, for: p.mac)
        DispatchQueue.main.async { self.showLink(autoConnect: p.mac) }
    }

    func showLink(autoConnect: String? = nil) {
        guard let nav = nav else { return }
        nav.dismiss(animated: false)
        let v = LinkViewController()
        v.autoConnectMac = autoConnect
        nav.present(UINavigationController(rootViewController: v), animated: true)
    }

    /// Handoff: Mac で開いている接続の続きを開く
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) { continueActivity(userActivity) }
    private func continueActivity(_ userActivity: NSUserActivity) {
        guard userActivity.activityType == TeraLink.activityType, let i = userActivity.userInfo,
              let host = i["host"] as? String, let port = i["port"] as? Int else { return }
        var h = SPHost()
        h.host = host; h.port = port
        h.proto = SPHost.Proto(rawValue: i["proto"] as? String ?? "ssh") ?? .ssh
        h.user = i["user"] as? String ?? ""
        h.name = i["name"] as? String ?? ""
        DispatchQueue.main.async {
            self.nav?.popToRootViewController(animated: false)
            self.nav?.pushViewController(SessionViewController(host: h), animated: true)
        }
    }
}
