import TeraCore
import AppKit

/// TERAMAC_LATENCY_TEST=<出力ファイル>: ローカルシェルにつないで、キーを押す (keyDown) → 文字が返る → 描く までの時間を測る。
/// キーを離す (keyUp) のは押してから 300ms 後に送るので、描くのが 300ms より前なら「押した時点で反映」
extension SelfTest {
    static func latency(out: String) {
        let c = SessionWindowController()
        c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        c.connect(.shell)
        let tv = c.termView
        var lines: [String] = []
        let keys = Array("abcdefghijklmnopqrst")
        func post(_ type: NSEvent.EventType, _ ch: Character, code: UInt16) {
            guard let w = tv.window, let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: w.windowNumber, context: nil, characters: String(ch),
                                                         charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: code) else { return }
            NSApp.postEvent(e, atStart: false)
        }
        func step(_ i: Int) {
            if i == keys.count {
                // 描き残しの確認: いくつかコマンドを打って画面を写す
                if let cmd = ProcessInfo.processInfo.environment["TERAMAC_LATENCY_CMD"] {
                    // たくさん出力したときの速さ: 例 "time seq 1 200000"
                    c.sendText("\u{15}clear; " + cmd + "\r")
                    let t0 = CFAbsoluteTimeGetCurrent()
                    func poll() {
                        let done = (0..<tv.term.rows).contains { tv.term.line(at: tv.term.totalLines - tv.term.rows + $0).text.hasPrefix("sys") }
                        if done { print(String(format: "画面に出し終わるまで %.0fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)); fflush(stdout) }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: poll) }
                    }
                    poll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                        let t = (0..<tv.term.rows).map { tv.term.line(at: tv.term.totalLines - tv.term.rows + $0).text }.filter { $0.contains("real") || $0.contains("user") || $0.contains("sys") }
                        print("CMD", cmd, t.joined(separator: " | ")); fflush(stdout); exit(0)
                    }
                    return
                }
                if let snap = ProcessInfo.processInfo.environment["TERAMAC_LATENCY_SNAP"] {
                    c.sendText("\u{15}clear; printf 'line1\\nline2 abc  def\\n\\033[1mbold text\\033[0m normal \\033[31mred words\\033[0m \\033[4munder line\\033[0m \\033[7mrev erse\\033[0m\\n\\033[42;30m green bg \\033[0m end  日本語 テスト\\n'; ls -G /; seq 1 40 | tail -3; printf '\\033[3;1Hover\\033[12;1H'\r")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        snapWindow(c.window!, snap)
                        // 履歴をさかのぼった表示 (行末を切り詰めた行を画面の幅に戻して描けているか)
                        if ProcessInfo.processInfo.environment["TERAMAC_LATENCY_SCROLLBACK"] != nil {
                            c.sendText("seq 1 30; printf '\\033[44m blue to end \\033[K\\033[0m\\n'; seq 31 60\r")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                tv.scrollBy(25)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { snapWindow(c.window!, snap.replacingOccurrences(of: ".png", with: "_back.png")) }
                            }
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (ProcessInfo.processInfo.environment["TERAMAC_LATENCY_SCROLLBACK"] != nil ? 3.5 : 1.8)) {
                    let r = tv.latencyResults
                    for (k, x) in r.enumerated() { lines.append(String(format: "key %2d: 送った %.1fms  echo来た %.1fms  描いた %.1fms", k, k < tv.latencySent.count ? tv.latencySent[k] : -1, x.data, x.drawn)) }
                    let d = r.map { $0.drawn }.sorted()
                    if !d.isEmpty {
                        lines.append(String(format: "描くまで: 最小 %.1f / 中央 %.1f / 最大 %.1f ms (n=%d, keyUp は +300ms)", d.first!, d[d.count / 2], d.last!, d.count))
                    }
                    lines.append("IME: \(TISCopyCurrentKeyboardInputSourceName())")
                    print(lines.joined(separator: "\n")); fflush(stdout)
                    do { try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) } catch { print("write error \(error)") }
                    exit(0)
                }
                return
            }
            // TERAMAC_LATENCY_KEY=return: Enter を押す (画面がいっぱいなので毎回 1 行スクロールする)
            let ret = ProcessInfo.processInfo.environment["TERAMAC_LATENCY_KEY"] == "return"
            post(.keyDown, ret ? "\r" : keys[i], code: ret ? 36 : 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { post(.keyUp, ret ? "\r" : keys[i], code: ret ? 36 : 0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { step(i + 1) }
        }
        if ProcessInfo.processInfo.environment["TERAMAC_LATENCY_KEY"] == "return" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { c.sendText("ls -G /; seq 1 200\r") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { step(0) }
    }
}

import Carbon
private func TISCopyCurrentKeyboardInputSourceName() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "?" }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

/// TERAMAC_MEMTEST=<回数>: ローカルシェルで大量の出力を何回もくり返し、そのたびにメモリ (phys_footprint) を書く。
/// 増え続けるならどこかで溜まっている
extension SelfTest {
    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func memtest(rounds: Int) {
        let c = SessionWindowController()
        c.showWindow(nil)
        c.connect(.shell)
        let cmd = ProcessInfo.processInfo.environment["TERAMAC_MEMTEST_CMD"] ?? "seq 1 300000; printf 'x%.0s' {1..2000}; echo; cat /usr/share/dict/words | head -50000"
        print(String(format: "start: %.1f MB  scrollback=%d cols=%d rows=%d", memoryFootprintMB(), c.term.scrollback.count, c.term.cols, c.term.rows)); fflush(stdout)
        func round(_ i: Int) {
            if i == rounds {
                // 最後に少し待って (遅れて解放される分) もう一度
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    print(String(format: "end(+3s): %.1f MB  scrollback=%d", memoryFootprintMB(), c.term.scrollback.count)); fflush(stdout)
                    exit(0)
                }
                return
            }
            c.sendText("clear; " + cmd + "; echo DONE\(i)MARK\r")
            func wait() {
                let t = c.term
                let done = (0..<t.rows).contains { t.line(at: t.totalLines - t.rows + $0).text.hasPrefix("DONE\(i)MARK") }
                if done {
                    print(String(format: "round %2d: %.1f MB  scrollback=%d", i + 1, memoryFootprintMB(), t.scrollback.count)); fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { round(i + 1) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: wait)
                }
            }
            wait()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { round(0) }
    }
}

/// TERAMAC_TCPTEST=<port>: 127.0.0.1:<port> に生 TCP でつなぎ、相手が送ってくる大量の出力を出し終わる ("ENDMARK" の行) までの時間を測る
extension SelfTest {
    static func tcpThroughput(port: Int) {
        let c = SessionWindowController()
        c.showWindow(nil)
        let t0 = CFAbsoluteTimeGetCurrent()
        c.connect(.rawTCP(host: "127.0.0.1", port: port))
        func poll() {
            let t = c.term
            let done = (0..<t.rows).contains { t.line(at: t.totalLines - t.rows + $0).text.hasPrefix("ENDMARK") }
            if done {
                print(String(format: "TCP: 画面に出し終わるまで %.0fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)); fflush(stdout)
                exit(0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: poll)
        }
        poll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("TCP: timeout"); exit(1) }
    }
}

/// TERAMAC_IDLETEST=<秒>: ローカルシェルにつないで何もしないで待ち、その間に使った CPU 時間を書く (待機中の無駄な仕事を見る)
extension SelfTest {
    static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }
    static func idle(seconds: Double) {
        let n = Int(ProcessInfo.processInfo.environment["TERAMAC_IDLETEST_WINDOWS"] ?? "1") ?? 1
        var keep: [SessionWindowController] = []
        for _ in 0..<n {
            let c = SessionWindowController()
            c.showWindow(nil)
            c.connect(.shell)
            keep.append(c)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let c0 = cpuSeconds(), t0 = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let used = cpuSeconds() - c0, wall = CFAbsoluteTimeGetCurrent() - t0
                print(String(format: "IDLE windows=%d: CPU %.3f 秒 / %.1f 秒 (%.2f%%)", keep.count, used, wall, used / wall * 100)); fflush(stdout)
                exit(0)
            }
        }
    }
}

/// TERAMAC_FLASHTEST=1: タブ 3 つのウインドウを「左右に並べて表示」で窓割りにし、その間 2ms ごとに画面上の自分のウインドウを数える。
/// 窓割りの元のウインドウ以外が一瞬でも見えたら (= タブが一度大きく開く) その回数と大きさを書く
extension SelfTest {
    static func flashTest() {
        let a = SessionWindowController(); a.showWindow(nil)
        let b = SessionWindowController(), c = SessionWindowController()
        a.window!.addTabbedWindow(b.window!, ordered: .above)
        b.window!.addTabbedWindow(c.window!, ordered: .above)
        a.window!.tabGroup?.selectedWindow = a.window
        a.window!.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let host = a.window!.windowNumber
            var seen: [String] = []
            let stop = CFAbsoluteTimeGetCurrent() + 1.2
            let q = DispatchQueue(label: "flash")
            q.async {
                while CFAbsoluteTimeGetCurrent() < stop {
                    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                    for w in info where (w[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) && ((w[kCGWindowLayer as String] as? Int) ?? 0) == 0 {
                        let n = w[kCGWindowNumber as String] as? Int ?? 0
                        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
                        if n != host && alpha > 0.01, let bd = w[kCGWindowBounds as String] as? [String: Any] {
                            seen.append("win\(n) \(Int(bd["Width"] as? Double ?? 0))x\(Int(bd["Height"] as? Double ?? 0)) a=\(alpha)")
                        }
                    }
                    usleep(2000)
                }
                DispatchQueue.main.async {
                    let uniq = Array(Set(seen))
                    print("FLASH: ほかのウインドウが見えた回数 \(seen.count) \(uniq.prefix(5))"); fflush(stdout)
                    exit(0)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                TabSplit.splitTabs(of: a.window!, sideBySide: true)
            }
        }
    }
}

/// TERAMAC_GHOSTSNAP=<png>: 窓割りを作り、ペインを外へドラッグしたときの写し (PaneDragGhost) を出して、窓と一緒に写す
extension SelfTest {
    static func ghostSnap(_ path: String) {
        let a = SessionWindowController(); a.showWindow(nil)
        let b = SessionWindowController()
        a.window!.addTabbedWindow(b.window!, ordered: .above)
        a.connect(.shell); b.connect(.shell)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            b.sendText("ls -G /\r")
            TabSplit.splitTabs(of: a.window!, sideBySide: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let sp = TabSplit.split(of: a.window!), let pane = sp.panes.last, let host = sp.hostWindow else { print("no split"); exit(1) }
                let f = host.frame
                PaneDragGhost.shared.show(pane, at: NSPoint(x: f.maxX + 40, y: f.midY))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    snapWindows([CGWindowID(PaneDragGhost.shared.windowNumber), CGWindowID(host.windowNumber)], path)
                    exit(0)
                }
            }
        }
    }
}

/// TERAMAC_FRAMETEST=<出力の png の頭> TERAMAC_FRAMEMODE=menu|drag: タブ 3 つを窓割りにする間、画面 (自分のウインドウ) を連続で撮って
/// コマを並べた 1 枚の絵にする。一瞬だけ出るもの (ウインドウが大きく開くなど) を目で確かめる
extension SelfTest {
    static func frameTest(_ prefix: String) {
        let mode = ProcessInfo.processInfo.environment["TERAMAC_FRAMEMODE"] ?? "menu"
        let a = SessionWindowController(); a.showWindow(nil)
        let b = SessionWindowController(), c = SessionWindowController()
        a.window!.setFrame(NSRect(x: 200, y: 300, width: 700, height: 420), display: true)
        a.window!.addTabbedWindow(b.window!, ordered: .above)
        b.window!.addTabbedWindow(c.window!, ordered: .above)
        a.connect(.shell); b.connect(.shell); c.connect(.shell)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            a.sendText("echo AAAAAAAA\r"); b.sendText("echo BBBBBBBB\r"); c.sendText("echo CCCCCCCC\r")
            // drag は選んでいるタブ (c) を a の右へ落とす。menu は「左右に並べて表示」
            let sel = mode == "drag" ? c : a
            sel.window!.tabGroup?.selectedWindow = sel.window
            sel.window!.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            var frames: [(Double, CGImage)] = []
            let t0 = CFAbsoluteTimeGetCurrent()
            let screen = NSScreen.main!.frame
            let area = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
            let q = DispatchQueue(label: "frames")
            q.async {
                while CFAbsoluteTimeGetCurrent() - t0 < 1.3 {
                    let t = CFAbsoluteTimeGetCurrent() - t0
                    // 自分のウインドウだけ (レイヤー 0 と、ドラッグの見本など)
                    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                    let ids = info.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(getpid()) }
                        .compactMap { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } }
                    var ptrs: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
                    if let arr = CFArrayCreate(kCFAllocatorDefault, &ptrs, ptrs.count, nil),
                       let img = CGImage(windowListFromArrayScreenBounds: area, windowArray: arr, imageOption: [.nominalResolution]) {
                        frames.append((t, img))
                    }
                    usleep(8000)
                }
                DispatchQueue.main.async {
                    // 続けて同じ絵のコマは省いて、変わったコマだけ並べる
                    var keep: [(Double, CGImage)] = []
                    var last: Data?
                    for (t, img) in frames {
                        let d = img.dataProvider?.data as Data?
                        if d != last { keep.append((t, img)); last = d }
                    }
                    let cols = 4, cw = 480, ch = Int(CGFloat(cw) * screen.height / screen.width)
                    var page = 0, i = 0
                    while i < keep.count {
                        let part = Array(keep[i..<min(keep.count, i + 16)])
                        let rows = (part.count + cols - 1) / cols
                        let out = NSImage(size: NSSize(width: cols * cw, height: rows * ch))
                        out.lockFocus()
                        NSColor.darkGray.setFill(); NSRect(x: 0, y: 0, width: cols * cw, height: rows * ch).fill()
                        for (k, (t, img)) in part.enumerated() {
                            let r = NSRect(x: (k % cols) * cw + 2, y: (rows - 1 - k / cols) * ch + 2, width: cw - 4, height: ch - 4)
                            NSImage(cgImage: img, size: .zero).draw(in: r)
                            (String(format: "%.0fms", t * 1000) as NSString).draw(at: NSPoint(x: r.minX + 6, y: r.maxY - 22),
                                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.yellow, .backgroundColor: NSColor.black])
                        }
                        out.unlockFocus()
                        if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)_\(mode)_\(page).png"))
                        }
                        page += 1; i += 16
                    }
                    print("FRAMES \(mode): 撮った \(frames.count) コマ、変化のあった \(keep.count) コマ、\(page) 枚"); fflush(stdout)
                    exit(0)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if mode == "drag" {
                    TabBarDrag.dropForTest(c, into: a.window!, pane: nil, side: .right, partner: a.window, tearOff: true)
                } else {
                    TabSplit.splitTabs(of: a.window!, sideBySide: true)
                }
            }
        }
    }
}

/// TERAMAC_REFLOWTEST=1: 履歴をいっぱい (1 万行) にしてから、幅を変えて折り返し直す時間を測る (ウインドウの大きさを変えるときの重さ)
extension SelfTest {
    static func reflowTest() {
        let c = SessionWindowController()
        c.showWindow(nil)
        let t = c.term
        var s = ""
        let longText = ProcessInfo.processInfo.environment["TERAMAC_REFLOWLONG"] != nil; for i in 1...12000 { s += "line \(i) the quick brown fox jumps over the lazy dog \(i * 7)" + (longText ? String(repeating: " lorem ipsum dolor", count: 8) : "") + "\r\n" }
        t.feed(s)
        print("scrollback=\(t.scrollback.count) cols=\(t.cols)")
        var times: [Double] = []
        for k in 0..<20 {
            let w = k % 2 == 0 ? t.cols - 7 : t.cols + 7
            let t0 = CFAbsoluteTimeGetCurrent()
            t.resize(cols: w, rows: t.rows)
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        times.sort()
        print(String(format: "REFLOW 1回: 最小 %.1f / 中央 %.1f / 最大 %.1f ms", times.first!, times[times.count / 2], times.last!))
        exit(0)
    }
}

/// TERAMAC_THEMESNAP=<png>: 設定のテーマのタブを開いて写す (保存はしない)
extension SelfTest {
    static func themeSnap(_ path: String) {
        let c = SessionWindowController(); c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let name = ProcessInfo.processInfo.environment["TERAMAC_THEMESNAP_PAGE"] ?? "background"
            c.openSetupSheet(SetupSheet.Page.allCases.first { "\($0)" == name } ?? .background)
            if let q = ProcessInfo.processInfo.environment["TERAMAC_THEMESNAP_SEARCH"] { SetupSheet.current?.debugSearch(q) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let sh = SetupSheet.current?.panel { snapWindow(sh, path) }
                exit(0)
            }
        }
    }
}

/// TERAMAC_LANGSNAP=<png>: 言語を切り替えて、ウインドウ内のメニューバーが変わるかを写す (<png>_before / _after)。
/// 言語の設定は最後に元に戻す
extension SelfTest {
    static func langSnap(_ path: String) {
        let c = SessionWindowController(); c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let old = UserDefaults.standard.string(forKey: Lang.defaultsKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let w = c.window { snapWindow(w, path.replacingOccurrences(of: ".png", with: "_before.png")) }
            Lang.chosen = Lang.current == "en_US.lng" || Lang.current.hasPrefix("mac_en") ? "ja_JP.lng" : "en_US.lng"
            print("LANG now=\(Lang.current) file=\(Lang.raw("Tera Term", "MENU_FILE") ?? "nil") entries=\(InWindowMenuBar.entries.map(\.label))"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let w = c.window { snapWindow(w, path.replacingOccurrences(of: ".png", with: "_after.png")) }
                if let o = old { UserDefaults.standard.set(o, forKey: Lang.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: Lang.defaultsKey) }
                exit(0)
            }
        }
    }
}

/// TERAMAC_SELSNAP=<png>: 文字を出して何行か選択し、見た目を写す (TERAMAC_SELSNAP_OLD=1 で前の見た目)
extension SelfTest {
    static func selSnap(_ path: String) {
        TerminalView.debugSelectionOldLook = ProcessInfo.processInfo.environment["TERAMAC_SELSNAP_OLD"] != nil
        let c = SessionWindowController(); c.showWindow(nil)
        // TERAMAC_SELSNAP_SIZE=幅,高さ: ウインドウの中身の大きさ (写真の余白を減らすため)
        if let sz = ProcessInfo.processInfo.environment["TERAMAC_SELSNAP_SIZE"]?.split(separator: ",").compactMap({ Double($0) }), sz.count == 2 {
            c.window?.setContentSize(NSSize(width: sz[0], height: sz[1]))
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            var text = "$ ls -l\r\ntotal 24\r\n-rw-r--r--  1 user  staff  1024 README.md\r\ndrwxr-xr-x  5 user  staff   160 src\r\n\r\n-rwxr-xr-x  1 user  staff  2048 build.sh\r\n$ echo hello\r\nhello\r\n$ "
            // TERAMAC_SELSNAP_TEXT=apache: Apache のアクセスログを tail している例 (検索の写真用)
            if ProcessInfo.processInfo.environment["TERAMAC_SELSNAP_TEXT"] == "apache" {
                let esc = "\u{1B}"
                var t = "\(esc)[1;32muser@web1\(esc)[0m:\(esc)[1;34m~\(esc)[0m$ tail -f /var/log/apache2/access.log\r\n"
                let rows: [(String, String, String, Int, Int)] = [
                    ("192.0.2.10", "13:40:01", "GET /index.html", 200, 5120),
                    ("198.51.100.7", "13:40:02", "GET /css/style.css", 200, 1834),
                    ("203.0.113.42", "13:40:02", "POST /api/login", 302, 0),
                    ("192.0.2.10", "13:40:03", "GET /images/logo.png", 200, 9812),
                    ("198.51.100.23", "13:40:05", "GET /about.html", 200, 4210),
                    ("203.0.113.42", "13:40:06", "POST /api/comment", 201, 92),
                    ("192.0.2.77", "13:40:07", "GET /favicon.ico", 404, 209),
                    ("198.51.100.7", "13:40:09", "HEAD /healthz", 200, 0),
                    ("192.0.2.10", "13:40:11", "GET /js/app.js", 200, 22014),
                    ("203.0.113.8", "13:40:12", "GET /download/TeraTermMac.dmg", 200, 31457280),
                ]
                for r in rows {
                    let code = r.3 >= 400 ? "\(esc)[31m\(r.3)\(esc)[0m" : "\(r.3)"
                    t += "\(r.0) - - [27/Nov/2026:\(r.1) +0900] \"\(r.2) HTTP/1.1\" \(code) \(r.4)\r\n"
                }
                text = t
            }
            c.feedReplay(Array(text.utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if ProcessInfo.processInfo.environment["TERAMAC_SELSNAP_NOSEL"] == nil {
                    c.termView.debugSelect(row: 1, col: 3, row: 7, col: 3)
                }
                if let q = ProcessInfo.processInfo.environment["TERAMAC_SELSNAP_FIND"] {
                    if ProcessInfo.processInfo.environment["TERAMAC_SELSNAP_NOBAR"] != nil {
                        if let h = c.termView.findAll(q).last { c.termView.reveal(h) }
                    } else {
                        c.termView.showFind(nil)
                        c.termView.findBar?.debugSearch(q)
                    }
                }
                // apache の例: 検索したあとにログが 2 行増えても、新しい行に印が付くかを写す
                if ProcessInfo.processInfo.environment["TERAMAC_SELSNAP_TEXT"] == "apache" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        c.feedReplay(Array(("198.51.100.23 - - [27/Nov/2026:13:40:14 +0900] \"GET /blog/2026/11/ HTTP/1.1\" 200 7731\r\n"
                            + "192.0.2.10 - - [27/Nov/2026:13:40:15 +0900] \"POST /api/like HTTP/1.1\" 200 18\r\n").utf8))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if let w = c.window { snapWindow(w, path) }
                    exit(0)
                }
            }
        }
    }
}
