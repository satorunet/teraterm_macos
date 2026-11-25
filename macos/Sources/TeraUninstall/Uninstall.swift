import AppKit
import Security
import TeraCore

/// Tera Term Mac のアンインストール (アプリ本体のメニューと、DMG に入れるアンインストーラーの両方で使う)
public enum TeraUninstall {
    public static let bundleID = "net.satoru.teramac"
    public static let appName = "Tera Term Mac"
    static let keychainService = "net.satoru.teramac.menu"
    static let launchAgent = "net.satoru.teramac.menu"

    public struct Options {
        public var app = true
        public var settings = true
        public var passwords = true
        public init() {}
    }

    /// インストールされている場所 (/Applications など)
    public static func appLocations() -> [URL] {
        var urls: [URL] = []
        if let found = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] {
            urls += found
        }
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(appName + ".app")
            if FileManager.default.fileExists(atPath: u.path) { urls.append(u) }
        }
        // DMG の中や開発用のビルドは消さない
        var seen = Set<String>()
        return urls.map { $0.standardizedFileURL }.filter { u in
            let p = u.path
            guard !p.hasPrefix("/Volumes/"), !p.contains("/.build/"), !p.contains("/build/"), FileManager.default.fileExists(atPath: p) else { return false }
            return seen.insert(p).inserted
        }
    }

    /// 保存したパスワード (キーチェーン) を消す
    @discardableResult
    public static func deleteKeychain() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService]
        let st = SecItemDelete(q as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }

    /// 動いている Tera Term Mac を終わらせる。終わらなければ false
    public static func quitRunningApp(timeout: TimeInterval = 8) -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier != me }
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        let end = Date(timeIntervalSinceNow: timeout)
        while Date() < end {
            if running.allSatisfy({ $0.isTerminated }) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        return running.allSatisfy { $0.isTerminated }
    }

    /// 消す。結果の説明を返す
    public static func run(_ o: Options, apps: [URL]) -> [String] {
        var report: [String] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        if o.passwords {
            // アプリ本体の鍵で消すと確認が出ないので、まずアプリに頼む
            var done = false
            if let app = apps.first {
                let exe = app.appendingPathComponent("Contents/MacOS/TeraMac").path
                if fm.isExecutableFile(atPath: exe), ProcessInfo.processInfo.processIdentifier != 0 {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: exe)
                    p.arguments = ["--purge-keychain"]
                    if (try? p.run()) != nil { p.waitUntilExit(); done = p.terminationStatus == 0 }
                }
            }
            if !done { done = deleteKeychain() }
            report.append(done ? Lang.m("UNINST_PW_REMOVED", "保存したパスワードを削除しました") : Lang.m("UNINST_PW_FAILED", "パスワードの一部を削除できませんでした (キーチェーンアクセスで「Tera Term Mac メニュー」を削除してください)"))
        }

        if o.settings {
            // ログイン時の起動
            let agent = "\(home)/Library/LaunchAgents/\(launchAgent).plist"
            if fm.fileExists(atPath: agent) { try? fm.removeItem(atPath: agent) }
            // 設定と接続リスト
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
            for p in ["Library/Preferences/\(bundleID).plist",
                      "Library/Saved Application State/\(bundleID).savedState",
                      "Library/Caches/\(bundleID)",
                      "Library/HTTPStorages/\(bundleID)",
                      "Library/WebKit/\(bundleID)"] {
                let path = home + "/" + p
                if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
            }
            report.append(Lang.m("UNINST_SETTINGS_REMOVED", "設定・接続リスト・ログイン時の起動を削除しました"))
        }

        if o.app {
            if apps.isEmpty { report.append(Lang.m("UNINST_APP_NOT_FOUND", "アプリ本体は見つかりませんでした (すでに削除済み)")) }
            for u in apps {
                do {
                    try fm.trashItem(at: u, resultingItemURL: nil)
                    report.append(Lang.m("UNINST_TRASHED", "%s をゴミ箱に入れました", u.path))
                } catch {
                    report.append(Lang.m("UNINST_TRASH_FAILED", "%s を削除できませんでした: %s", u.path, error.localizedDescription))
                }
            }
        }
        return report
    }

    /// 確認の画面を出して消す。inApp = Tera Term Mac 自身のメニューから呼んだとき
    public static func confirmAndRun(inApp: Bool) {
        let apps = appLocations()
        let a = NSAlert()
        a.messageText = Lang.m("UNINST_CONFIRM", "%s をアンインストールしますか?", appName)
        var info = Lang.m("UNINST_CHOOSE", "消すものを選んでください。アプリ本体はゴミ箱に入ります。")
        if !apps.isEmpty { info += "\n\n" + Lang.m("UNINST_FOUND_APPS", "見つかったアプリ:") + "\n" + apps.map { "・" + $0.path }.joined(separator: "\n") }
        info += "\n\n" + Lang.m("UNINST_KEEP_LIST", "接続リストを残したいときは、先に TeraTerm Menu の「リスト編集」で ttpmenu.ini に書き出してください。")
        if inApp { info += "\n\n" + Lang.m("UNINST_CLOSE_WINDOWS", "接続中のウインドウはすべて閉じます。") }
        a.informativeText = info
        let appCheck = NSButton(checkboxWithTitle: Lang.m("UNINST_ITEM_APP", "アプリ本体"), target: nil, action: nil)
        let setCheck = NSButton(checkboxWithTitle: Lang.m("UNINST_ITEM_SETTINGS", "設定と接続リスト (ログイン時の起動も)"), target: nil, action: nil)
        let pwCheck = NSButton(checkboxWithTitle: Lang.m("UNINST_ITEM_PASSWORDS", "保存したパスワード (キーチェーン)"), target: nil, action: nil)
        [appCheck, setCheck, pwCheck].forEach { $0.state = .on }
        let stack = NSStackView(views: [appCheck, setCheck, pwCheck])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 70)
        a.accessoryView = stack
        a.addButton(withTitle: Lang.m("UNINST_BUTTON", "アンインストール"))
        a.addButton(withTitle: Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"))
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        var o = Options()
        o.app = appCheck.state == .on
        o.settings = setCheck.state == .on
        o.passwords = pwCheck.state == .on
        guard o.app || o.settings || o.passwords else { return }

        if !inApp && !quitRunningApp() {
            let w = NSAlert()
            w.messageText = Lang.m("UNINST_QUIT_FAILED", "%s が終了できませんでした", appName)
            w.informativeText = Lang.m("UNINST_QUIT_FAILED_INFO", "接続中の確認が出ているかもしれません。%s を終了してから、もう一度アンインストールしてください。", appName)
            w.runModal()
            return
        }
        let report = run(o, apps: apps)
        let done = NSAlert()
        done.messageText = Lang.m("UNINST_DONE", "アンインストールしました")
        done.informativeText = report.map { "・" + $0 }.joined(separator: "\n")
        done.runModal()
    }
}
