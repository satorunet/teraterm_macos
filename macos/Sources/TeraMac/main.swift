import AppKit
import TeraCore
import TeraUninstall

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedByFile = false

    func applicationDidFinishLaunching(_ n: Notification) {
        AppUpdater.shared.start()
        buildMenu()
        // TERAMAC_INI_DRYRUN=<ini>: 読み込み結果を書き出して終わる (設定は変えない。確認用)
        if TeraTermIniImport.dryRunIfRequested() { exit(0) }
        // TERAMAC_TTMENU_TEST=<ttpmenu.ini>: 読んで書き出し、もう一度読んだ結果を <ini>.out.txt に (確認用・保存はしない)
        if let path = ProcessInfo.processInfo.environment["TERAMAC_TTMENU_TEST"] {
            var out: [String] = []
            if let d = FileManager.default.contents(atPath: path), let ini = IniFile(data: d) {
                let r = TTMenuIni.read(ini)
                for e in r.entries {
                    out.append("\(e.name) | host=\(e.host) mode=\(e.mode.rawValue) ssh=\(e.useSSH) user=\(e.useUser):\(e.user) pw=\(r.passwords[e.id] ?? "-") startup=\(e.startup) opt=\(e.option) macro=\(e.macroFile)")
                }
                out += r.notes
                let written = TTMenuIni.write(r.entries, includePasswords: false)
                try? written.write(to: URL(fileURLWithPath: path + ".written.ini"))
                if let again = IniFile(data: written) {
                    out.append("ROUNDTRIP " + TTMenuIni.read(again).entries.map { $0.name + "=" + $0.host }.joined(separator: ", "))
                }
                out.append("ENC " + TTMenuIni.encodePassword("pass") + "-> " + (TTMenuIni.decodePassword(TTMenuIni.encodePassword("pass")) ?? "nil"))
            }
            try? out.joined(separator: "\n").write(toFile: path + ".out.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        if let dir = ProcessInfo.processInfo.environment["TERAMAC_SNAPSHOT"] {
            SelfTest.run(dir: dir)
            return
        }
        offerMoveToApplications()
        // TeraTerm Menu: メニューバーに常駐
        TeraMenuController.shared.install()
        DispatchQueue.main.async {
            guard !self.openedByFile else { return }
            // コマンドライン: TeraMac host:22 /ssh /user=root など (Tera Term と似た書き方)
            let all = CommandLine.arguments.dropFirst()
            let menuOnly = all.contains("--menu")
            let args = all.filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") && $0 != "--menu" }
            // 「起動時に実行」の項目を開く
            let startedAny = args.isEmpty ? TeraMenuLauncher.runStartupEntries() : false
            // ログイン時の起動 (--menu) ではメニューバーだけ。起動時の項目を開いたら空のウインドウは出さない
            if args.isEmpty && (menuOnly || startedAny) { return }
            // ふつうに起動したときは TeraTerm Menu の接続先一覧を出す (単体の接続ウインドウは出さない)
            if args.isEmpty {
                TeraMenuController.shared.showEditor(nil)
                return
            }
            let c = SessionWindowController()
            c.showWindow(nil)
            // /M=マクロ.ttl でマクロを実行 (Tera Term と同じ)
            if let m = args.first(where: { $0.lowercased().hasPrefix("/m=") }) {
                let path = (String(m.dropFirst(3)) as NSString).expandingTildeInPath
                let rest = args.filter { $0 != m }
                if !rest.isEmpty, let spec = ConnectionSpec.parse(rest.joined(separator: " ")) { c.connect(spec) }
                c.runMacro(url: URL(fileURLWithPath: path))
                return
            }
            if let spec = ConnectionSpec.parse(args.joined(separator: " ")) {
                c.connect(spec)
            } else {
                c.showConnectDialog()
            }
        }
        if !CommandLine.arguments.contains("--menu") { NSApp.activate(ignoringOtherApps: true) }
        if let out = ProcessInfo.processInfo.environment["TERAMAC_DEBUG_WINDOWS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                var t = NSApp.windows.filter { $0.isVisible }.map { "\($0.className) '\($0.title)' \(Int($0.frame.width))x\(Int($0.frame.height))" }
                for i in NSApp.mainMenu?.items.first?.submenu?.items ?? [] where !i.isSeparatorItem {
                    t.append("MENU \(i.title)\(i.isHidden ? " (非表示)" : "")")
                }
                try? t.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // .ttl マクロを開いたら、新しいウインドウで実行する
        // (AppKit は "/ssh" "/M=..." のようなコマンドライン引数もここに渡してくるので、実在するファイルだけ扱う)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDir), !isDir.boolValue else { return false }
        let url = URL(fileURLWithPath: filename)
        openedByFile = true
        let c = SessionWindowController()
        c.showWindow(nil)
        c.runMacro(url: url)
        return true
    }

    /// TeraTerm Menu と同じく、ウインドウを閉じても常駐し続ける
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock のアイコンを押したとき、ウインドウがなければ接続先一覧を出す
        if !flag { TeraMenuController.shared.showEditor(nil) }
        return true
    }

    /// Dock アイコンの右クリックにも登録一覧を出す
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        TeraMenuController.shared.listMenu
    }

    /// アプリケーションフォルダにインストールされて動いているか
    var isInstalled: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// アンインストールのメニューは、インストールされているときだけ出す
    private func uninstallItem(_ i: NSMenuItem) -> NSMenuItem {
        i.isHidden = !isInstalled
        return i
    }

    @objc func uninstall(_ sender: Any?) {
        let before = TeraUninstall.appLocations()
        TeraUninstall.confirmAndRun(inApp: true)
        // 何か消したら終了する (設定を書き戻さないように、終了確認はとばす)
        let removedApp = before.contains { !FileManager.default.fileExists(atPath: $0.path) }
        let removedPrefs = UserDefaults.standard.persistentDomain(forName: TeraUninstall.bundleID)?.isEmpty ?? true
        if removedApp || removedPrefs {
            SessionWindowController.all.forEach { $0.disconnect(silent: true) }
            exit(0)
        }
    }

    /// DMG やダウンロードフォルダから起動されたら、アプリケーションフォルダへの移動をすすめる
    private func offerMoveToApplications() {
        let path = Bundle.main.bundlePath
        let env = ProcessInfo.processInfo.environment
        guard env["TERAMAC_SNAPSHOT"] == nil, env["TERAMAC_DEBUG_WINDOWS"] == nil,
              path.hasSuffix(".app"),
              !path.hasPrefix("/Applications/"), !path.hasPrefix(NSHomeDirectory() + "/Applications/"),
              path.hasPrefix("/Volumes/") || path.contains("/Downloads/") || path.contains("/AppTranslocation/") else { return }
        let a = NSAlert()
        a.messageText = "アプリケーションフォルダに移動しますか?"
        a.informativeText = "いまは \(path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") ? "ディスクイメージ" : "ダウンロードフォルダ") から動いています。アプリケーションフォルダに入れると、次からは Launchpad などから起動できます。"
        a.addButton(withTitle: "移動する")
        a.addButton(withTitle: "このまま使う")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications/" + (path as NSString).lastPathComponent)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
        } catch {
            let e = NSAlert()
            e.messageText = "移動できませんでした"
            e.informativeText = "\(error.localizedDescription)\n\nFinder で「アプリケーション」フォルダへドラッグしてください。"
            e.runModal()
            return
        }
        // ダウンロードフォルダのものは元を消す (ディスクイメージはそのまま)
        if path.contains("/Downloads/") { try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", dest.path]
        try? p.run()
        exit(0)
    }

    @objc func showMenuEditor(_ sender: Any?) { TeraMenuController.shared.showEditor(sender) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let live = SessionWindowController.all.filter { $0.isConnected }
        guard !live.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "\(live.count) 個の接続を切断して終了しますか?"
        a.addButton(withTitle: "終了")
        a.addButton(withTitle: "やめる")
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    @objc func newWindow(_ sender: Any?) {
        let c = SessionWindowController()
        c.showWindow(nil)
        c.showConnectDialog()
    }

    @objc func newShellWindow(_ sender: Any?) {
        let c = SessionWindowController()
        c.showWindow(nil)
        c.connect(.shell)
    }

    static let homepage = URL(string: "https://github.com/satorunet/teraterm_macos")!

    @objc func showAbout(_ sender: Any?) { AboutWindowController.shared.show() }

    @objc func showCredits(_ sender: Any?) { CreditsWindowController.shared.show() }

    @objc func openHomepage(_ sender: Any?) { NSWorkspace.shared.open(AppDelegate.homepage) }

    private func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m
            main.addItem(top)
            return m
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let S = SessionWindowController.self

        _ = add("Tera Term Mac", [
            item("Tera Term Mac について", #selector(showAbout(_:))),
            item("謝辞とライセンス…", #selector(showCredits(_:))),
            item("ホームページ (GitHub)…", #selector(openHomepage(_:))),
            .separator(),
        ] + AppUpdater.shared.menuItems() + [
            .separator(),
            item("端末の設定…", #selector(S.showTerminalSetup(_:)), ","),
            .separator(),
            item("Tera Term Mac を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            uninstallItem(item("Tera Term Mac をアンインストール…", #selector(uninstall(_:)))),
            item("Tera Term Mac を終了", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("接続", [
            item("新しい接続…", #selector(S.newConnection(_:)), "n", [.command, .shift]),
            item("新しいウインドウ…", #selector(newWindow(_:)), "n"),
            item("新しいローカルシェル", #selector(newShellWindow(_:)), "t"),
            item("接続を複製", #selector(S.duplicateSession(_:)), "d"),
            .separator(),
            item("ログ開始…", #selector(S.toggleLog(_:)), "l"),
            item("ファイル送信…", #selector(S.sendFile(_:))),
            .separator(),
            item("再接続", #selector(S.reconnect(_:)), "r"),
            item("切断", #selector(S.disconnectSession(_:)), "w", [.command, .shift]),
            item("閉じる", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = add("編集", [
            item("コピー", #selector(TerminalView.copy(_:)), "c"),
            item("貼り付け", #selector(TerminalView.paste(_:)), "v"),
            item("すべてを選択", #selector(TerminalView.selectAll(_:)), "a"),
            .separator(),
            item("画面クリア", #selector(S.clearScreen(_:)), "k"),
            item("バッファクリア", #selector(S.clearBuffer(_:)), "k", [.command, .shift]),
        ])
        _ = add("設定", [
            item("端末…", #selector(S.showTerminalSetup(_:))),
            item("シリアルポート…", #selector(S.serialSetup(_:))),
            .separator(),
            item("文字を大きく", #selector(S.biggerFont(_:)), "+"),
            item("文字を小さく", #selector(S.smallerFont(_:)), "-"),
        ])
        // TeraTerm Menu の一覧 (開くたびに作り直す)
        let hosts = add("接続リスト", [])
        hosts.delegate = TeraMenuController.shared
        _ = add("コントロール", [
            item("ブレーク信号を送る", #selector(S.sendBreak(_:)), "b"),
            item("端末をリセット", #selector(S.resetTerminal(_:))),
            .separator(),
            item("マクロ実行…", #selector(S.runMacroMenu(_:)), "m", [.command, .shift]),
            item("マクロ停止", #selector(S.stopMacro(_:)), ".", [.command]),
            item("ファイル転送を中止", #selector(S.cancelTransferMenu(_:))),
        ])
        let win = add("ウインドウ", [
            item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("拡大/縮小", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("前のタブ", #selector(NSWindow.selectPreviousTab(_:)), "{"),
            item("次のタブ", #selector(NSWindow.selectNextTab(_:)), "}"),
            item("すべてのウインドウを前面へ", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}

/// TERAMAC_SNAPSHOT=<dir> で起動すると、画面を PNG に書き出して終わる (見た目の確認用)
enum SelfTest {
    static func snap(_ v: NSView, _ path: String) {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func run(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let c = SessionWindowController()
        c.showWindow(nil)
        let demo = """
        \u{1B}[1mTeraMac\u{1B}[0m 表示テスト  \u{1B}[31m赤\u{1B}[32m緑\u{1B}[33m黄\u{1B}[34m青\u{1B}[35m紫\u{1B}[36m水\u{1B}[0m\r
        \u{1B}[7m反転\u{1B}[0m \u{1B}[4m下線\u{1B}[0m \u{1B}[38;5;208m256色\u{1B}[0m \u{1B}[38;2;255;105;180mTrueColor\u{1B}[0m \u{1B}[44;97m 背景 \u{1B}[0m\r
        ┌────────┬────────┐\r
        │ 日本語 │ ｶﾅ ABC │\r
        └────────┴────────┘\r
        \u{1B}(0lqqqqwqqqqk\u{1B}(B DEC 罫線\r
        $ ls -la\r

        """
        c.term.feed(demo)
        c.termView.dataArrived()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            snap(c.termView, dir + "/term.png")
            if let v = CreditsWindowController.shared.window?.contentView { snap(v, dir + "/credits.png") }
            if let about = AboutWindowController.shared.window, let v = about.contentView { snap(v, dir + "/about.png") }
            // マクロでローカルシェルと TCP 接続を実際に動かす
            c.term.feed("\u{1B}[2J\u{1B}[H")
            let ttl = """
            timeout = 10
            connect '/shell'
            wait '$' '%'
            sendln 'echo "cols=$(tput cols) lines=$(tput lines) term=$TERM"; printf "\\033[42m OK \\033[0m\\n"'
            wait ' OK '
            port = '47123'
            getenv 'TERAMAC_TCPPORT' port
            strlen port
            if result > 0 then
              s = '127.0.0.1:'
              strconcat s port
              strconcat s ' /t=0'
              disconnect 0
              connect s
              sendln 'hello-from-macro'
              wait 'hello-from-macro'
              if result = 1 sendln 'tcp-ok'
              mpause 500
            endif
            dev = ''
            getenv 'TERAMAC_SERIAL' dev
            strlen dev
            if result > 0 then
              s = '/C='
              strconcat s dev
              strconcat s ' /BAUD=115200'
              disconnect 0
              connect s
              send 'serial-ping'#13
              wait 'serial-pong'
              if result = 1 sendln 'serial-ok'
              mpause 500
            endif
            """
            let ttlPath = dir + "/test.ttl"
            try? ttl.write(toFile: ttlPath, atomically: true, encoding: .utf8)
            c.runMacro(url: URL(fileURLWithPath: ttlPath))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    snap(c.termView, dir + "/shell.png")
                    try? c.term.screenText.write(toFile: dir + "/shell.txt", atomically: true, encoding: .utf8)
                    c.disconnect(silent: true)
                    let dlg = ConnectDialog()
                    dlg.begin(on: c.window!) { _, _ in }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        snap(dlg.panel.contentView!, dir + "/connect.png")
                        dlg.cancel()
                        let sd = SetupDialog(settings: c.settings)
                        sd.begin(on: c.window!) { _ in }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            snap(sd.panel.contentView!, dir + "/setup.png")
                            schemeSheet(dir + "/schemes.png")
                            sd.cancel()
                            menuTest(dir: dir)
                        }
                    }
                }
        }
    }
}

extension SelfTest {
    /// 配色の候補を一覧の絵にする (見本 + プレビュー)
    static func schemeSheet(_ path: String) {
        let list = ColorScheme.presets + ColorScheme.terminalProfiles()
        let cols = 3, cellW: CGFloat = 330, cellH: CGFloat = 150
        let rows = (list.count + cols - 1) / cols
        let host = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH))
        for (i, s) in list.enumerated() {
            let x = CGFloat(i % cols) * cellW, y = CGFloat(rows - 1 - i / cols) * cellH
            let label = NSTextField(labelWithString: s.name)
            label.frame = NSRect(x: x + 110, y: y + cellH - 22, width: 220, height: 18)
            let sw = NSImageView(image: s.swatch())
            sw.frame = NSRect(x: x + 6, y: y + cellH - 24, width: 96, height: 20)
            let pv = SchemePreview(frame: NSRect(x: x + 6, y: y + 4, width: cellW - 12, height: cellH - 32))
            pv.fg = s.fg; pv.bg = s.bg; pv.cursor = s.cursor
            pv.ansi = s.ansi16 ?? Array(Palette.colors.prefix(16))
            pv.font = NSFont(name: "Menlo-Regular", size: 10)!
            [label, sw, pv].forEach { host.addSubview($0) }
        }
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        snap(host, path)
    }

    /// TeraTerm Menu の画面と自動ログインを確かめる (利用者の登録内容は最後に元に戻す)
    static func menuTest(dir: String) {
        let d = UserDefaults.standard
        let saved = d.data(forKey: "menuEntries")
        let savedTree = d.data(forKey: "menuTree")
        var e1 = MenuEntry(); e1.name = "本番サーバ (SSH)"; e1.host = "prod.example.com"; e1.user = "admin"; e1.useSSH = true; e1.startup = true
        var e2 = MenuEntry(); e2.name = "ルータ (Telnet)"; e2.host = "192.168.1.1"; e2.useSSH = false; e2.user = "cisco"
        var e3 = MenuEntry(); e3.name = "定期バックアップ"; e3.mode = .macro; e3.macroFile = "~/backup.ttl"
        var e4 = MenuEntry(); e4.name = "検証用 自動ログイン"; e4.useSSH = false; e4.user = "tester"
        e4.host = "127.0.0.1:" + (ProcessInfo.processInfo.environment["TERAMAC_LOGINPORT"] ?? "47124")
        e4.option = "/T=0 /passwd=s3cret"
        MenuStore.shared.entries = [e1, e2, e3, e4]
        // フォルダ分けも見る: 「ネットワーク機器」に e2、その下の「夜間」に e3
        let net = MenuNode(folder: "ネットワーク機器")
        let night = MenuNode(folder: "夜間")
        night.children = [MenuNode(entryID: e3.id)]
        net.children = [MenuNode(entryID: e2.id), night]
        MenuStore.shared.tree = [MenuNode(entryID: e1.id), net, MenuNode(entryID: e4.id)]
        let ed = MenuEditorWindowController()
        ed.showWindow(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            snap(ed.window!.contentView!, dir + "/menu_editor.png")
            let dd = MenuDetailsDialog(entry: e4)
            dd.begin(on: ed.window!) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                snap(dd.panel.contentView!, dir + "/menu_details.png")
                dd.cancel()
                let m = TeraMenuController.shared.listMenu
                func titles(_ menu: NSMenu, _ depth: Int) -> [String] {
                    menu.items.flatMap { [String(repeating: "  ", count: depth) + $0.title] + ($0.submenu.map { titles($0, depth + 1) } ?? []) }
                }
                try? titles(m, 0).joined(separator: "\n").write(toFile: dir + "/menu_list.txt", atomically: true, encoding: .utf8)
                if ProcessInfo.processInfo.environment["TERAMAC_LOGINPORT"] != nil {
                    TeraMenuLauncher.launch(e4)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if let c = SessionWindowController.all.last {
                        try? c.term.screenText.write(toFile: dir + "/menu_login.txt", atomically: true, encoding: .utf8)
                    }
                    if let s = saved { d.set(s, forKey: "menuEntries") } else { d.removeObject(forKey: "menuEntries") }
                    if let s = savedTree { d.set(s, forKey: "menuTree") } else { d.removeObject(forKey: "menuTree") }
                    exit(0)
                }
            }
        }
    }
}

// アンインストーラーから呼ばれる: 保存したパスワードを消して終わる (画面は出さない)
if CommandLine.arguments.contains("--purge-keychain") {
    exit(TeraUninstall.deleteKeychain() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
