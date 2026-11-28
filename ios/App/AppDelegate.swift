import UIKit
import TeraCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        SPPaths.prepare()
        let w = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: HostListViewController())
        w.rootViewController = nav
        w.tintColor = UIColor(red: 0.95, green: 0.72, blue: 0.0, alpha: 1)   // Tera Term の黄色
        w.makeKeyAndVisible()
        window = w
        // 確認用: TERASP_OPEN="ssh user@host:22" ですぐつなぐ (シミュレーターの起動引数)
        if let s = ProcessInfo.processInfo.environment["TERASP_OPEN"], var h = SPHost.parse(s) {
            // TERASP_MACRO="hello.ttl": つないだあとに macros フォルダのマクロを動かす
            h.macro = ProcessInfo.processInfo.environment["TERASP_MACRO"] ?? ""
            nav.pushViewController(SessionViewController(host: h), animated: false)
        }
        // 確認用: TERASP_LINK="Mac の名前,コード" で「Mac と連携」を開いてすぐつなぐ (リンクの確認を通さない)
        if let s = ProcessInfo.processInfo.environment["TERASP_LINK"] {
            let p = s.split(separator: ",").map(String.init)
            if p.count == 2 {
                LinkViewController.saveCode(p[1], for: p[0])
                DispatchQueue.main.async { self.showLink(autoConnect: p[0]) }
            }
        }
        return true
    }

    private var nav: UINavigationController? { window?.rootViewController as? UINavigationController }

    /// Mac の QR コードを読んで開いた (teraterm-sp://pair?mac=...&code=...)
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let p = TeraLink.parsePairURL(url) else { return false }
        LinkViewController.saveCode(p.code, for: p.mac)
        showLink(autoConnect: p.mac)
        return true
    }

    func showLink(autoConnect: String? = nil) {
        guard let nav = nav else { return }
        nav.dismiss(animated: false)
        let v = LinkViewController()
        v.autoConnectMac = autoConnect
        nav.present(UINavigationController(rootViewController: v), animated: true)
    }

    /// Handoff: Mac で開いている接続の続きを開く
    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        guard userActivity.activityType == TeraLink.activityType, let i = userActivity.userInfo,
              let host = i["host"] as? String, let port = i["port"] as? Int else { return false }
        var h = SPHost()
        h.host = host; h.port = port
        h.proto = SPHost.Proto(rawValue: i["proto"] as? String ?? "ssh") ?? .ssh
        h.user = i["user"] as? String ?? ""
        h.name = i["name"] as? String ?? ""
        nav?.popToRootViewController(animated: false)
        nav?.pushViewController(SessionViewController(host: h), animated: true)
        return true
    }
}
