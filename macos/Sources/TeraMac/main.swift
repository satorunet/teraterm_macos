import AppKit
import TeraCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedByFile = false

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        if let dir = ProcessInfo.processInfo.environment["TERAMAC_SNAPSHOT"] {
            SelfTest.run(dir: dir)
            return
        }
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
            if !args.isEmpty, let spec = ConnectionSpec.parse(args.joined(separator: " ")) {
                c.connect(spec)
            } else {
                c.showConnectDialog()
            }
        }
        if !CommandLine.arguments.contains("--menu") { NSApp.activate(ignoringOtherApps: true) }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // .ttl マクロを開いたら、新しいウインドウで実行する
        // (AppKit は "/ssh" "/M=..." のようなコマンドライン引数もここに渡してくるので、実在するファイルだけ扱う)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDir), !isDir.boolValue else { return false }
        openedByFile = true
        let url = URL(fileURLWithPath: filename)
        let c = SessionWindowController()
        c.showWindow(nil)
        c.runMacro(url: url)
        return true
    }

    /// TeraTerm Menu と同じく、ウインドウを閉じても常駐し続ける
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    /// Dock アイコンの右クリックにも登録一覧を出す
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        TeraMenuController.shared.listMenu
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

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "TeraMac",
            .credits: NSAttributedString(string: "Tera Term の Mac 版。\nシリアル / SSH / Telnet / TTL マクロ対応。\nTera Term Project (BSD License) の機能をもとに Swift で作り直したものです。"),
        ])
    }

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

        _ = add("TeraMac", [
            item("TeraMac について", #selector(showAbout(_:))),
            .separator(),
            item("端末の設定…", #selector(S.showTerminalSetup(_:)), ","),
            .separator(),
            item("TeraMac を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("TeraMac を終了", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("ファイル", [
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
        let hosts = add("接続先", [])
        hosts.delegate = TeraMenuController.shared
        _ = add("コントロール", [
            item("ブレーク信号を送る", #selector(S.sendBreak(_:)), "b"),
            item("端末をリセット", #selector(S.resetTerminal(_:))),
            .separator(),
            item("マクロ実行…", #selector(S.runMacroMenu(_:)), "m", [.command, .shift]),
            item("マクロ停止", #selector(S.stopMacro(_:)), ".", [.command]),
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
                            sd.cancel()
                            menuTest(dir: dir)
                        }
                    }
                }
        }
    }
}

extension SelfTest {
    /// TeraTerm Menu の画面と自動ログインを確かめる (利用者の登録内容は最後に元に戻す)
    static func menuTest(dir: String) {
        let d = UserDefaults.standard
        let saved = d.data(forKey: "menuEntries")
        var e1 = MenuEntry(); e1.name = "本番サーバ (SSH)"; e1.host = "prod.example.com"; e1.user = "admin"; e1.useSSH = true; e1.startup = true
        var e2 = MenuEntry(); e2.name = "ルータ (Telnet)"; e2.host = "192.168.1.1"; e2.useSSH = false; e2.user = "cisco"
        var e3 = MenuEntry(); e3.name = "定期バックアップ"; e3.mode = .macro; e3.macroFile = "~/backup.ttl"
        var e4 = MenuEntry(); e4.name = "検証用 自動ログイン"; e4.useSSH = false; e4.user = "tester"
        e4.host = "127.0.0.1:" + (ProcessInfo.processInfo.environment["TERAMAC_LOGINPORT"] ?? "47124")
        e4.option = "/T=0 /passwd=s3cret"
        MenuStore.shared.entries = [e1, e2, e3, e4]
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
                try? m.items.map { $0.title }.joined(separator: "\n").write(toFile: dir + "/menu_list.txt", atomically: true, encoding: .utf8)
                if ProcessInfo.processInfo.environment["TERAMAC_LOGINPORT"] != nil {
                    TeraMenuLauncher.launch(e4)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if let c = SessionWindowController.all.last {
                        try? c.term.screenText.write(toFile: dir + "/menu_login.txt", atomically: true, encoding: .utf8)
                    }
                    if let s = saved { d.set(s, forKey: "menuEntries") } else { d.removeObject(forKey: "menuEntries") }
                    exit(0)
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
