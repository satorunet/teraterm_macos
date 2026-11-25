import AppKit
import TeraCore

/// TERAMAC_SNAPSHOT=<dir> TERAMAC_GUIDESNAP=1: かんたんマニュアル (help-mac/*/html/easy) の画面写真を PNG に書き出して終わる。
/// 言語はコマンドラインの -UILanguageFile ja_JP.lng / en_US.lng で選ぶ (引数のドメインなので保存されない)。
/// 写真に利用者の情報 (ホストの履歴・ユーザー名・パス・登録一覧) が出ないように、例の値を引数のドメインに入れて読ませる。
/// 利用者の設定には書かない
extension SelfTest {
    private static func later(_ sec: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: f)
    }

    /// いくつかの自分のウィンドウ (メニューを含む) を重ねて 1 枚に写す。先頭が手前
    static func snapWindows(_ ids: [CGWindowID], _ path: String) {
        var ptrs: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let arr = CFArrayCreate(kCFAllocatorDefault, &ptrs, ptrs.count, nil),
              let img = CGImage(windowListFromArrayScreenBounds: .null, windowArray: arr,
                                imageOption: [.boundsIgnoreFraming, .bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// 画面に出ている自分のメニュー (ポップアップ) のウィンドウ
    static func ownMenuWindows() -> [CGWindowID] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.filter {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) && (($0[kCGWindowLayer as String] as? Int) ?? 0) > 0
        }.compactMap { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } }
    }

    /// 画面の文字に出ている利用者のホームフォルダ (/Users/<名前>) を例の /Users/user にする (写す前に呼ぶ)
    static func scrubHome(_ v: NSView) {
        let home = NSHomeDirectory()
        func fix(_ a: NSAttributedString) -> NSAttributedString? {
            guard a.string.contains(home) else { return nil }
            let m = NSMutableAttributedString(attributedString: a)
            while let r = m.string.range(of: home) { m.replaceCharacters(in: NSRange(r, in: m.string), with: "/Users/user") }
            return m
        }
        if let b = v as? NSButton, let a = fix(b.attributedTitle) { b.attributedTitle = a }
        else if let t = v as? NSTextField, let a = fix(t.attributedStringValue) { t.attributedStringValue = a }
        v.subviews.forEach { scrubHome($0) }
    }

    /// 例の値を引数のドメイン (保存されない) に入れる
    private static func guideDefaults() {
        let d = UserDefaults.standard
        var a = d.volatileDomain(forName: UserDefaults.argumentDomain)
        let ja = Lang.isJapanese
        a["recentHosts"] = ["example.com", "server1.example.com"]
        a["lastUser"] = "user"
        a["lastMode"] = "tcp"
        a["lastService"] = "ssh"
        a["lastKeyFile"] = ""
        a["FileDir"] = ""
        // ローカルシェル: 利用者の rc を読まない sh、簡単なプロンプト、例のフォルダ
        a["localShellPath"] = "/bin/sh"
        a["localShellLogin"] = false
        a["localShellHomeChdir"] = false
        a["localShellEnv1"] = "PS1=user@mac:~\\$\\040"   // 終わりの空白は設定で消えるので \\040
        // 端末の大きさ・文字の大きさ・タイトルは既定に近い値 (利用者の設定に左右されないように)
        a["cols"] = 80
        a["rows"] = 24
        a["fontSize"] = 13
        a["Title"] = "Tera Term Mac"
        a["localShellEnv2"] = "BASH_SILENCE_DEPRECATION_WARNING=1"
        // TeraTerm Menu の登録一覧 (例 2 件)
        var e1 = MenuEntry(); e1.name = "server1 (SSH)"; e1.host = "server1.example.com"; e1.user = "user"; e1.useSSH = true
        var e2 = MenuEntry(); e2.name = ja ? "テスト用サーバー (Telnet)" : "Test server (Telnet)"; e2.host = "192.0.2.10"; e2.useSSH = false
        a["menuEntries"] = try? JSONEncoder().encode([e1, e2])
        a["menuTree"] = try? JSONEncoder().encode([MenuNode(entryID: e1.id), MenuNode(entryID: e2.id)])
        d.setVolatileDomain(a, forName: UserDefaults.argumentDomain)
    }

    static func guide(dir: String) {
        guideDefaults()
        let ja = Lang.isJapanese
        NSApp.activate(ignoringOtherApps: true)
        let c = SessionWindowController()
        c.showWindow(nil)
        c.window?.center()
        c.connect(.shell)
        let w = c.window!
        later(1.5) {
            if ja {
                c.sendText("echo 'こんにちは、Tera Term Mac です'\r")
            } else {
                c.sendText("echo 'Hello, this is Tera Term Mac'\r")
            }
            c.sendText("uname -sm\r")
        }
        later(3.5) {
            snapWindow(w, dir + "/terminal.png")
            // 新しい接続 (SSH の例)
            let dlg = ConnectDialog()
            dlg.begin(on: w) { _, _ in }
            dlg.debugGuideFill(serial: false)
            later(0.9) {
                snapWindow(dlg.panel, dir + "/connect_ssh.png")
                dlg.debugGuideFill(serial: true)
                later(0.5) {
                    snapWindow(dlg.panel, dir + "/connect_serial.png")
                    dlg.cancel()
                    later(0.8) { setupScenes(c, dir) }
                }
            }
        }
    }

    private static func setupScenes(_ c: SessionWindowController, _ dir: String) {
        c.openSetupSheet(.terminal)
        let pages: [(SetupSheet.Page, String)] = [(.font, "setup_font"), (.window, "setup_window"), (.theme, "setup_theme"), (.ui, "setup_ui")]
        func next(_ i: Int) {
            guard i < pages.count else {
                SetupSheet.current?.cancel()
                later(0.8) { logScene(c, dir) }
                return
            }
            SetupSheet.current?.bringToFront(page: pages[i].0)
            later(0.6) {
                if let p = SetupSheet.current?.panel { scrubHome(p.contentView!); later(0.2) { snapWindow(p, dir + "/" + pages[i].1 + ".png"); next(i + 1) } }
            }
        }
        later(1.0) {
            if let p = SetupSheet.current?.panel { scrubHome(p.contentView!); snapWindow(p, dir + "/setup_terminal.png") }
            next(0)
        }
    }

    private static func logScene(_ c: SessionWindowController, _ dir: String) {
        let w = c.window!
        let ld = LogDialog(session: c)
        ld.begin(on: w) { _ in }
        ld.debugGuideFill("/Users/user/Documents/teraterm.log")
        later(0.9) {
            snapWindow(ld.panel, dir + "/log.png")
            ld.cancel()
            later(0.8) {
                let sf = SendFileDialog(values: .init(), initialDir: "/Users/user")
                sf.debugGuideFill("/Users/user/Documents/sample.txt")
                let f = w.frame
                sf.panel.setFrameOrigin(NSPoint(x: f.midX - sf.panel.frame.width / 2, y: f.midY - sf.panel.frame.height / 2))
                sf.panel.makeKeyAndOrderFront(nil)
                later(0.7) {
                    snapWindow(sf.panel, dir + "/sendfile.png")
                    sf.panel.orderOut(nil)
                    menuScene(c, dir)
                }
            }
        }
    }

    private static func menuScene(_ c: SessionWindowController, _ dir: String) {
        let ed = MenuEditorWindowController()
        ed.showWindow(nil)
        ed.window?.makeKeyAndOrderFront(nil)
        later(0.9) {
            if let ew = ed.window { snapWindow(ew, dir + "/ttmenu.png") }
            ed.window?.orderOut(nil)
            tileScene(c, dir)
        }
    }

    /// ウィンドウ > 上下に並べて表示 (2 つのウィンドウ)
    private static func tileScene(_ c: SessionWindowController, _ dir: String) {
        let w = c.window!
        let saved = w.frame
        let c2 = SessionWindowController()
        c2.showWindow(nil)
        c2.connect(.shell)
        later(1.5) {
            c2.sendText("echo server2\r")
            later(0.8) {
                WindowMenuController.shared.perform(Selector(("stacked:")), with: nil)
                later(1.2) {
                    if let w2 = c2.window {
                        snapWindows([CGWindowID(w.windowNumber), CGWindowID(w2.windowNumber)], dir + "/tile.png")
                    }
                    c2.disconnect(silent: true)
                    c2.window?.orderOut(nil)
                    w.setFrame(saved, display: true)
                    helpScene(c, dir)
                }
            }
        }
    }

    private static func helpScene(_ c: SessionWindowController, _ dir: String) {
        HelpViewer.openIndex()
        later(2.5) {
            if let hw = HelpWindowController.shared.window {
                snapWindow(hw, dir + "/help.png")
                hw.orderOut(nil)
            }
            menuBarScene(c, dir)
        }
    }

    /// ウィンドウ内のメニューバーで「ファイル」を開いたところ。メニューを開いている間は戻らないので、これが最後
    private static func menuBarScene(_ c: SessionWindowController, _ dir: String) {
        guard let w = c.window, let bar = (w.contentView as? TerminalContainerView)?.bar else { exit(0) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        later(0.8) {
            let t = Timer(timeInterval: 1.2, repeats: false) { _ in
                snapWindows(ownMenuWindows() + [CGWindowID(w.windowNumber)], dir + "/menu_open.png")
                c.disconnect(silent: true)
                exit(0)
            }
            RunLoop.current.add(t, forMode: .common)
            RunLoop.current.add(t, forMode: .eventTracking)
            bar.open(0)
            exit(0)
        }
    }
}
