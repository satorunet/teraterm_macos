import AppKit
import TeraCore

/// TERAMAC_SNAPSHOT=<dir> TERAMAC_MADOSNAP=1: かんたんマニュアルの「1 つのウィンドウに画面を並べる」(TTMado) の写真を
/// <dir>/mado_*.png に書き出して終わる。いろいろな並べ方を TabSplit で組み、端末には例の文字 (接続はしない) を入れて写す。
/// 言語はコマンドラインの -UILanguageFile ja_JP.lng / en_US.lng で選ぶ。利用者の設定には書かない (引数のドメインだけ)
extension SelfTest {
    private static func soon(_ sec: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: f)
    }

    /// 例の接続 (見出しの名前と、端末に入れる文字)
    private struct Sample {
        let title: String
        let text: String
    }

    private static func samples(_ ja: Bool) -> [Sample] {
        let esc = "\u{1B}"
        func prompt(_ host: String) -> String { "\(esc)[1;32muser@\(host)\(esc)[0m:\(esc)[1;34m~\(esc)[0m$ " }
        let ls = prompt("server1") + "ls -l\r\n"
            + "total 24\r\n"
            + "drwxr-xr-x 2 user user 4096 Nov 25 09:12 \(esc)[1;34mbackup\(esc)[0m\r\n"
            + "-rw-r--r-- 1 user user  812 Nov 25 09:30 config.yml\r\n"
            + "drwxr-xr-x 5 user user 4096 Nov 24 18:02 \(esc)[1;34mlogs\(esc)[0m\r\n"
            + "-rwxr-xr-x 1 user user 2310 Nov 20 11:45 \(esc)[1;32mdeploy.sh\(esc)[0m\r\n"
            + "-rw-r--r-- 1 user user  157 Nov 18 08:00 README.md\r\n"
            + prompt("server1") + "uptime\r\n"
            + " 10:42:07 up 12 days, load: 0.08 0.12 0.10\r\n"
            + prompt("server1")
        let top = prompt("server2") + "top -b -n 1 | head\r\n"
            + "top - 10:42:11 up 30 days, load: 0.52 0.41\r\n"
            + "Tasks: 112 total,   1 running, 111 sleeping\r\n"
            + "%Cpu(s):  3.1 us,  1.0 sy, 95.6 id\r\n"
            + "MiB Mem :   3936.2 total,    812.4 free\r\n"
            + "\r\n"
            + "\(esc)[7m  PID USER       RES %CPU %MEM COMMAND\(esc)[0m\r\n"
            + "  812 www-data  48212  2.0  1.2 nginx\r\n"
            + " 1024 user      10432  0.7  0.3 sshd\r\n"
            + "  640 mysql    380552  0.3  9.4 mysqld\r\n"
            + "    1 root      11872  0.0  0.3 systemd\r\n"
            + prompt("server2")
        let router = "\r\nrouter1 con0 is now available\r\n\r\nPress RETURN to get started.\r\n\r\n"
            + "router1>enable\r\n"
            + "router1#show ip interface brief\r\n"
            + "Interface  IP-Address    Status  Protocol\r\n"
            + "Gi0/0      192.0.2.1     up      \(esc)[32mup\(esc)[0m\r\n"
            + "Gi0/1      198.51.100.1  up      \(esc)[32mup\(esc)[0m\r\n"
            + "Gi0/2      unassigned    down    \(esc)[31mdown\(esc)[0m\r\n"
            + "router1#"
        let web = prompt("web1") + "tail -f access.log\r\n"
            + "192.0.2.10   10:41:52 GET  /         \(esc)[32m200\(esc)[0m\r\n"
            + "192.0.2.24   10:41:55 GET  /about    \(esc)[32m200\(esc)[0m\r\n"
            + "198.51.100.7 10:41:58 GET  /favicon  \(esc)[33m404\(esc)[0m\r\n"
            + "192.0.2.10   10:42:03 POST /login    \(esc)[32m302\(esc)[0m\r\n"
            + "203.0.113.5  10:42:09 GET  /news     \(esc)[32m200\(esc)[0m\r\n"
        let db = prompt("db1") + "df -h\r\n"
            + "Filesystem  Size  Used Avail Use% Mounted\r\n"
            + "/dev/sda1    40G   18G   20G  48% /\r\n"
            + "/dev/sdb1   200G  121G   69G  64% /data\r\n"
            + "tmpfs       1.9G     0  1.9G   0% /dev/shm\r\n"
            + prompt("db1") + "free -h\r\n"
            + "      total   used   free  cache\r\n"
            + "Mem:   3.8Gi  1.9Gi  812Mi  1.1Gi\r\n"
            + prompt("db1")
        let mac = "\(esc)[1;32muser@mac\(esc)[0m:~$ uname -sm\r\nDarwin arm64\r\n"
            + "\(esc)[1;32muser@mac\(esc)[0m:~$ ping -c 3 example.com\r\n"
            + "PING example.com (192.0.2.80)\r\n"
            + "64 bytes: icmp_seq=0 time=12.4 ms\r\n"
            + "64 bytes: icmp_seq=1 time=11.9 ms\r\n"
            + "64 bytes: icmp_seq=2 time=12.1 ms\r\n"
            + "\(esc)[1;32muser@mac\(esc)[0m:~$ "
        return [
            Sample(title: "server1 (SSH)", text: ls),
            Sample(title: "server2 (SSH)", text: top),
            Sample(title: ja ? "router1 (シリアル)" : "router1 (Serial)", text: router),
            Sample(title: "web1 (SSH)", text: web),
            Sample(title: "db1 (SSH)", text: db),
            Sample(title: ja ? "mac (ローカルシェル)" : "mac (Local shell)", text: mac),
        ]
    }

    /// 並べ方の例 (名前, ペインの数, 組み方)。組み方は、最初の 2 つで分割したあと、残りを入れる
    private enum Step { case side(Int, TabSplit.DropSide) /* i 番目のペインの隣 */, edge(TabSplit.DropSide) }

    static func madoGuide(dir: String) {
        guideDefaults()
        // TTMado は入にする (引数のドメイン。利用者の設定は変えない)
        let d = UserDefaults.standard
        var a = d.volatileDomain(forName: UserDefaults.argumentDomain)
        a[TTMado.defaultsKey] = true
        a["fontSize"] = 11   // 3 つ並べても行が折り返さない大きさ
        d.setVolatileDomain(a, forName: UserDefaults.argumentDomain)
        TTMado.install()
        NSApp.activate(ignoringOtherApps: true)
        let ja = Lang.isJapanese
        let smp = samples(ja)
        // (ファイル名, 最初の分割の向き (左右なら true), 最初に並べる数, あとから入れる手順, フォーカスするペイン, 追加のタブ, あとの撮影)
        typealias Scene = (name: String, side: Bool, first: Int, steps: [Step], focus: Int, extraTab: Bool)
        let scenes: [Scene] = [
            ("mado_lr", true, 2, [], 0, false),
            ("mado_tb", false, 2, [], 0, false),
            ("mado_3col", true, 3, [], 1, false),
            ("mado_l_rtb", true, 2, [.side(1, .below)], 0, false),
            ("mado_t2_b1", true, 2, [.edge(.below)], 2, false),
            ("mado_grid4", true, 2, [.side(0, .below), .side(1, .below)], 3, false),
            ("mado_6", true, 3, [.edge(.below), .side(3, .right), .side(4, .right)], 4, true),
        ]
        func run(_ i: Int) {
            guard i < scenes.count else { extraShots(dir, smp, ja) { exit(0) }; return }
            let sc = scenes[i]
            build(count: sc.first + sc.steps.count, first: sc.first, side: sc.side, steps: sc.steps, smp: smp) { sp, list in
                guard let sp = sp, let w = sp.hostWindow else { run(i + 1); return }
                var extra: SessionWindowController?
                if sc.extraTab {
                    // ふつうのタブを 1 つ足して、タブのバーとバッジを出す
                    let t = SessionWindowController()
                    feed(t, smp[0].text)
                    w.addTabbedWindow(t.window!, ordered: .above)
                    w.tabGroup?.selectedWindow = w
                    t.window?.tab.title = ja ? "メモ (ローカルシェル)" : "Notes (Local shell)"
                    extra = t
                }
                sp.focus(list[min(sc.focus, list.count - 1)])
                PaneCountBadge.refreshAll()
                soon(0.9) {
                    retitle(sp, list, smp)
                    if let t = extra { t.window?.tab.title = ja ? "メモ (ローカルシェル)" : "Notes (Local shell)" }
                    soon(0.3) {
                        snapWindow(w, dir + "/\(sc.name).png")
                        if let t = extra {
                            // タブのバーがないとき (タイトルバーの右にバッジ)
                            t.closeWithoutConfirm()
                            PaneCountBadge.refreshAll()
                            soon(0.8) {
                                retitle(sp, list, smp)
                                soon(0.3) {
                                    snapWindow(w, dir + "/\(sc.name)_title.png")
                                    close(list) { run(i + 1) }
                                }
                            }
                        } else {
                            close(list) { run(i + 1) }
                        }
                    }
                }
            }
        }
        run(0)
    }

    /// 端末に例の文字を入れる (接続はしない)
    private static func feed(_ c: SessionWindowController, _ s: String) {
        c.term.feed("\u{1B}[2J\u{1B}[H" + s)
        c.termView.dataArrived()
    }

    /// 見出し・ウインドウの題を例の名前にする
    private static func retitle(_ sp: TabSplit, _ list: [SessionWindowController], _ smp: [Sample]) {
        for (k, c) in list.enumerated() {
            sp.panes.first { $0.session === c }?.header.title = smp[k % smp.count].title
        }
        // 写すときのマウスの位置で × が出ないように
        for p in sp.panes { p.header.hovered = false }
        if let f = sp.focused, let k = list.firstIndex(where: { $0 === f }), let w = sp.hostWindow {
            w.title = smp[k % smp.count].title
            w.tab.title = smp[k % smp.count].title
        }
    }

    /// ほかのタブに自動で入らないように出す
    private static func showAlone(_ x: SessionWindowController) {
        guard let xw = x.window else { return }
        let mode = xw.tabbingMode
        xw.tabbingMode = .disallowed
        x.showWindow(nil)
        xw.tabbingMode = mode
    }

    /// count 個のセッションで分割を組む。最初の first 個をタブにして分割し、残りを steps の順に入れる
    private static func build(count: Int, first: Int, side: Bool, steps: [Step], smp: [Sample],
                              done: @escaping (TabSplit?, [SessionWindowController]) -> Void) {
        let list = (0..<count).map { _ in SessionWindowController() }
        showAlone(list[0])
        guard let w = list[0].window else { done(nil, list); return }
        w.setFrame(NSRect(x: 80, y: 120, width: 1100, height: 700), display: true)
        for x in list[1..<first] { (w.tabGroup?.windows.last ?? w).addTabbedWindow(x.window!, ordered: .above) }
        w.tabGroup?.selectedWindow = w
        w.makeKeyAndOrderFront(nil)
        soon(0.4) {
            TabSplit.splitTabs(of: w, sideBySide: side)
            guard let sp = TabSplit.split(of: w) else { done(nil, list); return }
            for (k, st) in steps.enumerated() {
                let c = list[first + k]
                showAlone(c)
                c.window?.orderOut(nil)
                switch st {
                case .side(let i, let s):
                    if let t = sp.panes.first(where: { $0.session === list[i] }) { sp.insert(c, at: t, side: s) }
                case .edge(let s):
                    sp.insert(c, at: nil, side: s)
                }
            }
            sp.equalize(sp.root)
            // 大きさが決まってから文字を入れる
            soon(0.6) {
                for (k, c) in list.enumerated() { feed(c, smp[k % smp.count].text) }
                done(sp, list)
            }
        }
    }

    private static func close(_ list: [SessionWindowController], then: @escaping () -> Void) {
        for c in list.reversed() { c.closeWithoutConfirm() }
        soon(0.5, then)
    }

    /// ドラッグ中の見本 (mado_drop) と、見出しの × (mado_header)
    private static func extraShots(_ dir: String, _ smp: [Sample], _ ja: Bool, done: @escaping () -> Void) {
        build(count: 3, first: 3, side: true, steps: [], smp: smp) { sp, list in
            guard let sp = sp, let w = sp.hostWindow else { done(); return }
            sp.focus(list[0])
            soon(0.9) {
                retitle(sp, list, smp)
                // 右端まで持っていったときの見本 (「端に並べる」)
                let r = sp.root.convert(sp.root.bounds, to: nil)
                let pt = NSPoint(x: r.maxX - 10, y: r.midY)
                let preview = SplitDropPreview()
                if let z = sp.dropAt(for: nil, at: pt) {
                    preview.show(w.convertToScreen(z.rect), over: w, above: nil, label: z.label)
                }
                soon(0.4) {
                    snapWindows([CGWindowID(preview.windowNumber), CGWindowID(w.windowNumber)], dir + "/mado_drop.png")
                    preview.hide()
                    // ペインの上の見本 (中ほどのペインの下半分 = 下に並べる)
                    if let t = sp.panes.first(where: { $0.session === list[1] }) {
                        let c = t.convert(NSPoint(x: t.bounds.midX, y: t.bounds.maxY - 60), to: nil)
                        if let z = sp.dropAt(for: nil, at: c) {
                            preview.show(w.convertToScreen(z.rect), over: w, above: nil, label: z.label)
                        }
                    }
                    soon(0.4) {
                        snapWindows([CGWindowID(preview.windowNumber), CGWindowID(w.windowNumber)], dir + "/mado_drop_pane.png")
                        preview.hide()
                        // 見出しにマウスが乗ったとき (左に ×)
                        if let p = sp.panes.first(where: { $0.session === list[0] }) { p.header.hovered = true }
                        soon(0.3) {
                            snapHeader(w, sp, list[0], dir + "/mado_header.png")
                            close(list, then: done)
                        }
                    }
                }
            }
        }
    }

    /// ウインドウの左上 (タイトルバーから、最初のペインの見出しと数行) を切り出して写す
    private static func snapHeader(_ w: NSWindow, _ sp: TabSplit, _ c: SessionWindowController, _ path: String) {
        guard let p = sp.panes.first(where: { $0.session === c }),
              let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return }
        let scale = CGFloat(img.width) / w.frame.width
        let pr = p.convert(p.bounds, to: nil)   // ウインドウの座標 (下から上)
        let fromTop = w.frame.height - pr.maxY + TabPaneView.headerHeight + 90
        let width = min(w.frame.width, pr.maxX + 8)
        guard let cut = img.cropping(to: CGRect(x: 0, y: 0, width: width * scale, height: fromTop * scale)) else { return }
        let rep = NSBitmapImageRep(cgImage: cut)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
