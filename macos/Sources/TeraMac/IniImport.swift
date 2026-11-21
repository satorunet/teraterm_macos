import AppKit
import TeraCore

/// Windows 版 Tera Term の TERATERM.INI を読み込んで設定に反映する
enum TeraTermIniImport {
    struct Result {
        var settings: TermSettings
        var applied: [String] = []
        var skipped: [String] = []
        var hosts: [String] = []
        var serial: SerialParams?
        var service: String?
        var mode: String?
        var user: String?
    }

    static func read(_ ini: IniFile, base: TermSettings) -> Result {
        var r = Result(settings: base)
        let T = "Tera Term"
        func note(_ s: String) { r.applied.append(s) }

        // 端末
        if let v = ini.ints(T, "TerminalSize"), v.count >= 2, v[0] > 0, v[1] > 0 {
            r.settings.cols = min(500, v[0]); r.settings.rows = min(300, v[1])
            note("端末サイズ \(r.settings.cols)×\(r.settings.rows)")
        }
        if let k = ini.string(T, "KanjiReceive") ?? ini.string(T, "KanjiSend") {
            if let e = encoding(k) {
                r.settings.encoding = e
                note("文字コード \(e.rawValue)")
            } else if !k.isEmpty {
                r.skipped.append("文字コード \(k) (UTF-8 / SJIS / EUC のみ対応)")
            }
        }
        if let v = ini.string(T, "CRReceive")?.uppercased(), !v.isEmpty {
            // Tera Term の CR = そのまま → TeraMac の AUTO。CRLF = CR を改行扱い → TeraMac の CR
            switch v {
            case "CRLF": r.settings.recvNewline = "CR"
            case "LF": r.settings.recvNewline = "LF"
            default: r.settings.recvNewline = "AUTO"
            }
            note("改行コード 受信 \(v)")
        }
        if let v = ini.string(T, "CRSend")?.uppercased(), ["CR", "CRLF", "LF"].contains(v) {
            r.settings.sendNewline = v
            note("改行コード 送信 \(v)")
        }
        if let v = ini.onOff(T, "LocalEcho") { r.settings.localEcho = v; note("ローカルエコー \(v ? "on" : "off")") }
        if let v = ini.string(T, "BSKey"), !v.isEmpty {
            r.settings.bsSendsDel = v.uppercased() == "DEL"
            note("BS キー \(v.uppercased())")
        }
        if let v = ini.string(T, "MetaKey")?.lowercased(), !v.isEmpty {
            r.settings.optionAsMeta = v != "off"
            note("Meta キー \(v) (Option キー)")
        }
        if let v = ini.int(T, "ScrollBuffSize"), v >= 0 {
            r.settings.scrollback = min(1_000_000, v)
            note("スクロールバッファ \(v) 行")
        }
        if let v = ini.int(T, "UnicodeAmbiguousWidth") {
            r.settings.ambiguousWide = v == 2
            note("あいまい幅 \(v)")
        }
        if let v = ini.string(T, "CursorShape")?.lowercased(), !v.isEmpty {
            r.settings.cursorShape = ["vertical", "horizontal"].contains(v) ? v : "block"
            note("カーソル形 \(v)")
        }
        if let v = ini.onOff(T, "NonblinkingCursor") { r.settings.cursorBlink = !v; note("カーソル点滅 \(v ? "off" : "on")") }
        if let v = ini.onOff(T, "ConfirmChangePaste") { r.settings.confirmMultilinePaste = v; note("貼り付け確認 \(v ? "on" : "off")") }
        if let v = ini.onOff(T, "DisablePasteMouseRButton") { r.settings.rightClickPaste = !v; note("右クリック貼り付け \(v ? "off" : "on")") }
        if let v = ini.onOff(T, "LogTimestamp") { r.settings.logTimestamp = v; note("ログの時刻 \(v ? "on" : "off")") }
        if let v = ini.int(T, "DelayPerChar") { r.settings.charDelayMs = max(0, v) }
        if let v = ini.int(T, "DelayPerLine") { r.settings.lineDelayMs = max(0, v) }
        if r.settings.charDelayMs > 0 || r.settings.lineDelayMs > 0 {
            note("送信遅延 \(r.settings.charDelayMs) ms/文字, \(r.settings.lineDelayMs) ms/行")
        }

        // 色
        if let v = ini.ints(T, "VTColor"), v.count >= 6 {
            r.settings.fg = rgb(v[0], v[1], v[2])
            r.settings.bg = rgb(v[3], v[4], v[5])
            note("文字色・背景色")
        }
        if let v = ini.ints(T, "ANSIColor"), v.count >= 64 {
            // 足りない番号は標準色 (Tera Term の番号の並びにしてから上書き)
            let std = Palette.base16.map { rgb($0.0, $0.1, $0.2) }
            var colors = Array(std[8..<16]) + Array(std[0..<8])
            var i = 0
            while i + 3 < v.count {
                let n = v[i]
                if n >= 0 && n < 16 { colors[n] = rgb(v[i + 1], v[i + 2], v[i + 3]) }
                i += 4
            }
            // Tera Term の番号は 0-7 が明るい色、8-15 が通常の色 (ANSI と逆) なので入れ替える
            r.settings.ansi16 = Array(colors[8..<16]) + Array(colors[0..<8])
            note("ANSI 16 色")
        }

        // フォント (Windows のフォント名で Mac にあるものだけ。標準の Terminal フォントのままなら変えない)
        if let f = ini.string(T, "VTFont"), !f.isEmpty {
            let parts = f.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let name = parts.first ?? ""
            let h = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            // 高さはピクセル (負なら文字の高さ)。Windows の 96dpi をポイントに直す
            var pt = CGFloat(abs(h)) * 72 / 96
            if h > 0 { pt *= 0.85 }
            pt = max(8, min(36, pt.rounded()))
            if name.lowercased() == "terminal" {
                r.skipped.append("フォント Terminal (Windows 専用のため Mac の標準のまま)")
            } else if let font = macFont(name), font.isFixedPitch || font.fontName.lowercased().contains("mono") {
                r.settings.fontName = font.fontName
                if h != 0 { r.settings.fontSize = pt }
                note("フォント \(font.displayName ?? font.fontName) \(Int(r.settings.fontSize))pt")
            } else {
                if h != 0 { r.settings.fontSize = pt }
                r.skipped.append("フォント \(name) (Mac にないため大きさ \(Int(pt))pt だけ反映)")
            }
        }

        // シリアル
        var sp = ConnHistory.serial
        var serialTouched = false
        if let v = ini.int(T, "BaudRate"), v > 0 { sp.baud = v; serialTouched = true }
        if let v = ini.int(T, "DataBit"), v == 7 || v == 8 { sp.dataBits = v; serialTouched = true }
        if let v = ini.string(T, "Parity")?.lowercased(), !v.isEmpty {
            if ["none", "odd", "even"].contains(v) { sp.parity = v } else { r.skipped.append("パリティ \(v)") }
            serialTouched = true
        }
        if let v = ini.string(T, "StopBit") {
            if v == "2" { sp.stopBits = 2 } else if v == "1" { sp.stopBits = 1 } else if !v.isEmpty { r.skipped.append("ストップビット \(v)") }
            serialTouched = true
        }
        if let v = ini.string(T, "FlowCtrl")?.lowercased(), !v.isEmpty {
            switch v {
            case "x": sp.flow = "xon"
            case "hard", "rtscts": sp.flow = "rts"
            case "none": sp.flow = "none"
            default: r.skipped.append("フロー制御 \(v)")
            }
            serialTouched = true
        }
        if serialTouched {
            r.serial = sp
            note("シリアル \(sp.baud) bps \(sp.dataBits)\(sp.parity.prefix(1).uppercased())\(sp.stopBits) フロー \(sp.flow)")
            if let c = ini.int(T, "ComPort") {
                r.skipped.append("COM\(c) (Mac ではポート名が違うので接続ダイアログで選んでください)")
            }
        }

        // 接続ダイアログの既定
        if let port = ini.int(T, "TCPPort") {
            let telnet = ini.onOff(T, "Telnet") ?? true
            r.service = port == 22 ? "ssh" : (telnet ? "telnet" : "raw")
            note("既定のサービス \(r.service!)")
        }
        if let p = ini.string(T, "Port")?.lowercased(), !p.isEmpty {
            r.mode = p == "serial" ? "serial" : "tcp"
        }
        if let u = ini.string("TTSSH", "DefaultUserName"), !u.isEmpty {
            r.user = u
            note("SSH の既定ユーザー名 \(u)")
        }

        // [Hosts] → 接続先の履歴
        for (k, v) in ini.keys("Hosts") where k.lowercased().hasPrefix("host") {
            if let h = hostEntry(v) { r.hosts.append(h) }
        }
        if !r.hosts.isEmpty { note("ホスト履歴 \(r.hosts.count) 件") }
        return r
    }

    /// 結果を保存し、開いている全ウインドウに反映する
    static func apply(_ r: Result) {
        r.settings.save()
        applyConnectionDefaults(r)
        for c in SessionWindowController.all { c.applySettings(r.settings) }
    }

    /// 接続ダイアログの既定 (ホスト履歴・シリアル・サービス・ユーザー名) だけ保存する
    static func applyConnectionDefaults(_ r: Result) {
        if let s = r.serial { ConnHistory.serial = s }
        if let s = r.service { ConnHistory.lastService = s }
        if let m = r.mode { ConnHistory.lastMode = m }
        if let u = r.user { ConnHistory.lastUser = u }
        for h in r.hosts.reversed() { ConnHistory.remember(host: h) }
    }

    /// ファイルを選んで読み込む (メニューから)
    static func importWithPanel() {
        let p = NSOpenPanel()
        p.title = "TERATERM.INI を選んでください"
        p.allowedFileTypes = ["ini", "INI"]
        p.allowsOtherFileTypes = true
        p.showsHiddenFiles = true
        if p.runModal() == .OK, let u = p.url { importFile(u) }
    }

    static func importFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let ini = IniFile(data: data) else {
            alert("読み込めませんでした", url.path); return
        }
        guard ini.hasSection("Tera Term") || ini.hasSection("Hosts") else {
            alert("TERATERM.INI ではないようです", "[Tera Term] セクションがありません。\n\(url.path)"); return
        }
        let r = read(ini, base: TermSettings.load())
        apply(r)
        // ファイル転送の設定 (FileDir など) はここから読む
        UserDefaults.standard.set(url.path, forKey: "TeraTermIniPath")
        var text = "反映した設定:\n" + r.applied.map { "・" + $0 }.joined(separator: "\n")
        if !r.skipped.isEmpty { text += "\n\n反映しなかった設定:\n" + r.skipped.map { "・" + $0 }.joined(separator: "\n") }
        alert("\(url.lastPathComponent) を読み込みました", text)
    }

    static func dryRunIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TERAMAC_INI_DRYRUN"] else { return false }
        let out = env["TERAMAC_INI_OUT"] ?? "/dev/stdout"
        var lines: [String] = []
        if let d = FileManager.default.contents(atPath: path), let f = IniFile(data: d) {
            let r = read(f, base: TermSettings())
            lines.append("APPLIED")
            lines += r.applied
            lines.append("SKIPPED")
            lines += r.skipped
            lines.append("HOSTS")
            for h in r.hosts {
                let spec = ConnectionSpec.parse(h)
                lines.append(h + " => " + (spec.map { String(describing: $0) } ?? "nil"))
            }
            if let a = r.settings.ansi16 { lines.append("ANSI1=" + String(describing: a[1])) }
            lines.append("FONT=" + r.settings.fontName + " " + String(describing: r.settings.fontSize))
        } else {
            lines.append("読み込めません")
        }
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - 変換

    static func encoding(_ s: String) -> TermEncoding? {
        let l = s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        if l.hasPrefix("utf8") { return .utf8 }
        if l.hasPrefix("sjis") || l.hasPrefix("shiftjis") || l == "cp932" { return .sjis }
        if l.hasPrefix("euc") { return .eucjp }
        return nil
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        func c(_ v: Int) -> CGFloat { CGFloat(max(0, min(255, v))) / 255 }
        return NSColor(srgbRed: c(r), green: c(g), blue: c(b), alpha: 1)
    }

    private static func macFont(_ name: String) -> NSFont? {
        let map: [String: String] = [
            "ｍｓ ゴシック": "Osaka-Mono", "ms gothic": "Osaka-Mono", "ｍｓ ｐゴシック": "Osaka-Mono",
            "bizud ゴシック": "Osaka-Mono", "consolas": "Menlo-Regular", "lucida console": "Menlo-Regular",
        ]
        if let f = NSFont(name: name, size: 12) { return f }
        if let m = map[name.lowercased()], let f = NSFont(name: m, size: 12) { return f }
        return nil
    }

    /// [Hosts] の 1 行を、接続ダイアログの履歴の書き方に直す
    static func hostEntry(_ raw: String) -> String? {
        var v = raw
        if let semi = v.firstIndex(of: ";") { v = String(v[..<semi]) }
        v = v.trimmingCharacters(in: .whitespaces)
        if v.isEmpty || v.hasPrefix("\\\\") || v.lowercased().hasPrefix("/r=") || v.lowercased().hasPrefix("/c=") { return nil }
        if v.lowercased().hasPrefix("ssh://") {
            v = String(v.dropFirst(6)) + " /ssh"
        } else if v.lowercased().hasPrefix("telnet://") {
            v = String(v.dropFirst(9)) + " /telnet"
        }
        // Mac で意味のないオプション (/F=設定ファイル など) は落とす
        let words = v.split(separator: " ").filter { w in
            let l = w.lowercased()
            return !(l.hasPrefix("/f=") || l.hasPrefix("/w=") || l.hasPrefix("/x=") || l.hasPrefix("/y="))
        }
        return words.joined(separator: " ")
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
