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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { snapWindow(c.window!, snap) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
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
