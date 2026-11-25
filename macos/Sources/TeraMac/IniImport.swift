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
        /// UILanguageFile の言語ファイル名 (選べる言語のときだけ。例 "ja_JP.lng")。TermSettings には持たない
        var language: String?
    }

    static func read(_ ini: IniFile, base: TermSettings) -> Result {
        var r = Result(settings: base)
        let T = "Tera Term"
        func note(_ s: String) { r.applied.append(s) }

        // 端末
        if let v = ini.ints(T, "TerminalSize"), v.count >= 2, v[0] > 0, v[1] > 0 {
            r.settings.cols = min(TermLimits.widthMax, v[0]); r.settings.rows = min(TermLimits.heightMax, v[1])   // ttset.c: TermWidthMax / TermHeightMax
            note(Lang.m("SETUP_INI_TERMINAL_SIZE", "端末サイズ %d×%d", r.settings.cols, r.settings.rows))
        }
        if let k = ini.string(T, "KanjiReceive") ?? ini.string(T, "KanjiSend") {
            if let e = encoding(k) {
                r.settings.encoding = e
                r.settings.encodingSend = e
                note(Lang.m("SETUP_INI_ENCODING", "文字コード %s", e.rawValue))
            } else if !k.isEmpty {
                r.skipped.append(Lang.m("CONN2_INI_ENCODING_UNKNOWN", "文字コード %s (知らない名前)", k))
            }
        }
        if let k = ini.string(T, "KanjiSend"), let e = encoding(k) {
            r.settings.encodingSend = e
            if e != r.settings.encoding { note(Lang.m("SETUP_INI_ENCODING_SEND", "送信の文字コード %s", e.rawValue)) }
        }
        if let v = ini.string(T, "CRReceive")?.uppercased(), !v.isEmpty {
            // Tera Term の CR = そのまま → TeraMac の AUTO。CRLF = CR を改行扱い → TeraMac の CR
            switch v {
            case "CRLF": r.settings.recvNewline = "CR"
            case "LF": r.settings.recvNewline = "LF"
            case "AUTO": r.settings.recvNewline = "AUTODETECT"
            default: r.settings.recvNewline = "AUTO"
            }
            note(Lang.m("SETUP_INI_CR_RECEIVE", "改行コード 受信 %s", v))
        }
        if let v = ini.string(T, "CRSend")?.uppercased(), ["CR", "CRLF", "LF"].contains(v) {
            r.settings.sendNewline = v
            note(Lang.m("SETUP_INI_CR_SEND", "改行コード 送信 %s", v))
        }
        if let v = ini.onOff(T, "LocalEcho") { r.settings.localEcho = v; note(Lang.m("SETUP_INI_LOCAL_ECHO", "ローカルエコー %s", v ? "on" : "off")) }
        if let v = ini.string(T, "BSKey"), !v.isEmpty {
            r.settings.bsSendsDel = v.uppercased() == "DEL"
            note(Lang.m("SETUP_INI_BS_KEY", "BS キー %s", v.uppercased()))
        }
        if let v = ini.string(T, "MetaKey")?.lowercased(), !v.isEmpty {
            r.settings.optionAsMeta = v != "off"
            r.settings.metaKey = ["off", "on", "left", "right"].contains(v) ? v : "on"
            note(Lang.m("SETUP_INI_META_KEY", "Meta キー %s (Option キー)", v))
        }
        if let v = ini.int(T, "ScrollBuffSize"), v >= 0 {
            r.settings.scrollback = min(1_000_000, v)
            note(Lang.m("SETUP_INI_SCROLL_BUFFER", "スクロールバッファ %d 行", v))
        }
        if let v = ini.int(T, "UnicodeAmbiguousWidth") {
            r.settings.ambiguousWide = v == 2
            note(Lang.m("SETUP_INI_AMBIGUOUS_WIDTH", "あいまい幅 %d", v))
        }
        if let v = ini.string(T, "CursorShape")?.lowercased(), !v.isEmpty {
            r.settings.cursorShape = ["vertical", "horizontal"].contains(v) ? v : "block"
            note(Lang.m("SETUP_INI_CURSOR_SHAPE", "カーソル形 %s", v))
        }
        if let v = ini.onOff(T, "NonblinkingCursor") { r.settings.cursorBlink = !v; note(Lang.m("SETUP_INI_CURSOR_BLINK", "カーソル点滅 %s", v ? "off" : "on")) }
        if let v = ini.onOff(T, "ConfirmChangePaste") { r.settings.confirmChangePaste = v; note(Lang.m("SETUP_INI_CONFIRM_PASTE", "貼り付け確認 %s", v ? "on" : "off")) }
        if let v = ini.onOff(T, "DisablePasteMouseRButton") { r.settings.rightClickPaste = !v; note(Lang.m("SETUP_INI_RIGHT_CLICK_PASTE", "右クリック貼り付け %s", v ? "off" : "on")) }
        if let v = ini.onOff(T, "LogTimestamp") { r.settings.logTimestamp = v; note(Lang.m("SETUP_INI_LOG_TIMESTAMP", "ログの時刻 %s", v ? "on" : "off")) }
        if let v = ini.onOff(T, "ConfirmChangePasteCR") { r.settings.confirmChangePasteCR = v }
        if let v = ini.string(T, "ConfirmChangePasteStringFile") { r.settings.confirmChangePasteStringFile = v }
        if let v = ini.onOff(T, "TrimTrailingNLonPaste") { r.settings.trimTrailingNLOnPaste = v }
        if let v = ini.onOff(T, "BracketedControlOnly") { r.settings.bracketedControlOnly = v }
        if let v = ini.int(T, "PasteDelayPerLine") { r.settings.pasteDelayPerLine = max(0, min(5000, v)) }
        if let v = ini.onOff(T, "EnableContinuedLineCopy") { r.settings.continuedLineCopy = v }
        if let v = ini.onOff(T, "AutoTextCopy") { r.settings.copyOnSelect = v }
        var extra = r.settings
        let n = readExtra(ini, into: &extra)
        r.settings = extra
        if n > 0 { note(Lang.m("SETUP_INI_OTHER_SETTINGS", "その他の設定 %d 項目", n)) }
        if let v = ini.int(T, "DelayPerChar") { r.settings.charDelayMs = max(0, v) }
        if let v = ini.int(T, "DelayPerLine") { r.settings.lineDelayMs = max(0, v) }
        if r.settings.charDelayMs > 0 || r.settings.lineDelayMs > 0 {
            note(Lang.m("SETUP_INI_SEND_DELAY", "送信遅延 %d ms/文字, %d ms/行", r.settings.charDelayMs, r.settings.lineDelayMs))
        }

        // 色
        if let v = ini.ints(T, "VTColor"), v.count >= 6 {
            r.settings.fg = rgb(v[0], v[1], v[2])
            r.settings.bg = rgb(v[3], v[4], v[5])
            note(Lang.m("SETUP_INI_COLORS", "文字色・背景色"))
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
            note(Lang.m("SETUP_INI_ANSI_COLORS", "ANSI 16 色"))
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
                r.skipped.append(Lang.m("SETUP_INI_FONT_TERMINAL", "フォント Terminal (Windows 専用のため Mac の標準のまま)"))
            } else if let font = macFont(name), font.isFixedPitch || font.fontName.lowercased().contains("mono") {
                r.settings.fontName = font.fontName
                if h != 0 { r.settings.fontSize = pt }
                note(Lang.m("SETUP_INI_FONT", "フォント %s %dpt", font.displayName ?? font.fontName, Int(r.settings.fontSize)))
            } else {
                if h != 0 { r.settings.fontSize = pt }
                r.skipped.append(Lang.m("SETUP_INI_FONT_SIZE_ONLY", "フォント %s (Mac にないため大きさ %dpt だけ反映)", name, Int(pt)))
            }
        }

        // シリアル
        var sp = ConnHistory.serial
        var serialTouched = false
        if let v = ini.int(T, "BaudRate"), v > 0 { sp.baud = v; serialTouched = true }
        if let v = ini.int(T, "DataBit"), v == 7 || v == 8 { sp.dataBits = v; serialTouched = true }
        if let v = ini.string(T, "Parity")?.lowercased(), !v.isEmpty {
            if ["none", "odd", "even", "mark", "space"].contains(v) { sp.parity = v } else { r.skipped.append(Lang.m("SETUP_INI_PARITY", "パリティ %s", v)) }
            serialTouched = true
        }
        if let v = ini.string(T, "StopBit") {
            if v == "2" { sp.stopBits = 2 } else if v == "1" { sp.stopBits = 1 } else if !v.isEmpty { r.skipped.append(Lang.m("SETUP_INI_STOP_BIT", "ストップビット %s", v)) }
            serialTouched = true
        }
        if let v = ini.string(T, "FlowCtrl")?.lowercased(), !v.isEmpty {
            switch v {
            case "x": sp.flow = "xon"
            case "hard", "rtscts": sp.flow = "rts"
            case "dsrdtr": sp.flow = "dsr"
            case "none": sp.flow = "none"
            default: r.skipped.append(Lang.m("SETUP_INI_FLOW_CONTROL", "フロー制御 %s", v))
            }
            serialTouched = true
        }
        // FlowCtrlRTS / FlowCtrlDTR (ttset.c _ReadIniFile, #934 92ab12cf1)。ないときはフロー制御から
        let rtsIni = ini.int(T, "FlowCtrlRTS"), dtrIni = ini.int(T, "FlowCtrlDTR")
        if serialTouched || rtsIni != nil || dtrIni != nil {
            sp.rts = rtsIni.map { max(0, min(3, $0)) } ?? SerialParams.defaultRTS(flow: sp.flow)
            sp.dtr = dtrIni.map { max(0, min(2, $0)) } ?? SerialParams.defaultDTR(flow: sp.flow)
            serialTouched = true
        }
        if serialTouched {
            r.serial = sp
            note(Lang.m("SETUP_INI_SERIAL", "シリアル %d bps %s フロー %s", sp.baud, "\(sp.dataBits)\(sp.parity.prefix(1).uppercased())\(sp.stopBits)", sp.flow))
            if let c = ini.int(T, "ComPort") {
                r.skipped.append(Lang.m("SETUP_INI_COM_PORT", "COM%d (Mac ではポート名が違うので接続ダイアログで選んでください)", c))
            }
        }

        // 接続ダイアログの既定
        if let port = ini.int(T, "TCPPort") {
            let telnet = ini.onOff(T, "Telnet") ?? true
            r.service = port == 22 ? "ssh" : (telnet ? "telnet" : "raw")
            note(Lang.m("SETUP_INI_SERVICE", "既定のサービス %s", r.service!))
        }
        if let p = ini.string(T, "Port")?.lowercased(), !p.isEmpty {
            r.mode = p == "serial" ? "serial" : "tcp"
        }
        if let u = ini.string("TTSSH", "DefaultUserName"), !u.isEmpty {
            r.user = u
            note(Lang.m("SETUP_INI_SSH_USER", "SSH の既定ユーザー名 %s", u))
        }

        // [Hosts] → 接続先の履歴
        for (k, v) in ini.keys("Hosts") where k.lowercased().hasPrefix("host") {
            if let h = hostEntry(v) { r.hosts.append(h) }
        }
        if !r.hosts.isEmpty { note(Lang.m("SETUP_INI_HOSTS", "ホスト履歴 %d 件", r.hosts.count)) }

        // UI言語 (UILanguageFile=lang_utf8\ja_JP.lng)。選べる言語のときだけ。当てるのは利用者が読み込んだとき (adoptLanguage)
        if let v = ini.string(T, "UILanguageFile"), !v.isEmpty {
            let file = v.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? v
            if let l = Lang.available.first(where: { $0.file.caseInsensitiveCompare(file) == .orderedSame }) {
                r.language = l.file
                note(Lang.m("SETUP_INI_UI_LANGUAGE", "UI言語 %s", l.name))
            } else {
                r.skipped.append(Lang.m("SETUP_INI_UI_LANGUAGE", "UI言語 %s", v))
            }
        }
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
        adoptLanguage(r)
    }

    /// 読み込んだ INI の UILanguageFile を UI言語にする (変わるときだけ)。
    /// 同梱の TERATERM.INI から作る初期値 (TermSettings.initial) では呼ばない
    static func adoptLanguage(_ r: Result) {
        if let l = r.language, l != Lang.chosen { Lang.chosen = l }
    }

    /// ファイルを選んで読み込む (メニューから)
    static func importWithPanel() {
        let p = NSOpenPanel()
        p.title = Lang.m("SETUP_INI_CHOOSE", "TERATERM.INI を選んでください")
        p.allowedFileTypes = ["ini", "INI"]
        p.allowsOtherFileTypes = true
        p.showsHiddenFiles = true
        if p.runModal() == .OK, let u = p.url { importFile(u) }
    }

    static func importFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let ini = IniFile(data: data) else {
            alert(Lang.m("SETUP_INI_READ_FAILED", "読み込めませんでした"), url.path); return
        }
        guard ini.hasSection("Tera Term") || ini.hasSection("Hosts") else {
            alert(Lang.m("SETUP_INI_NOT_TERATERM", "TERATERM.INI ではないようです"), Lang.m("SETUP_INI_NO_SECTION", "[Tera Term] セクションがありません。\n%s", url.path)); return
        }
        let r = read(ini, base: TermSettings.load())
        apply(r)
        // ファイル転送の設定 (FileDir など) はここから読む
        UserDefaults.standard.set(url.path, forKey: "TeraTermIniPath")
        let bullet = Lang.isJapanese ? "・" : "• "   // 言語ファイルの値は前後の空白が落ちるのでここで選ぶ
        var text = Lang.m("SETUP_INI_APPLIED", "反映した設定:") + "\n" + r.applied.map { bullet + $0 }.joined(separator: "\n")
        if !r.skipped.isEmpty {
            text += "\n\n" + Lang.m("SETUP_INI_SKIPPED", "反映しなかった設定:") + "\n" + r.skipped.map { bullet + $0 }.joined(separator: "\n")
        }
        alert(Lang.m("SETUP_INI_LOADED", "%s を読み込みました", url.lastPathComponent), text)
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

    /// その他の設定の項目 (キー名は UserDefaults と同じ)
    @discardableResult
    static func readExtra(_ ini: IniFile, into s: inout TermSettings) -> Int {
        let T = "Tera Term"
        var n = 0
        for (k, p) in TermSettings.boolFields { if let v = ini.onOff(T, k) { s[keyPath: p] = v; n += 1 } }
        for (k, p) in TermSettings.intFields { if let v = ini.int(T, k) { s[keyPath: p] = v; n += 1 } }
        for (k, p) in TermSettings.stringFields where k != "MetaKey" && k != "TeraMacThemeName" {
            if let v = ini.string(T, k) { s[keyPath: p] = v; n += 1 }
        }
        for (k, p) in TermSettings.colorPairFields { if let v = ini.string(T, k), let c = ColorPair(iniString: v) { s[keyPath: p] = c; n += 1 } }
        if ini.string(T, "AlphaBlendActive") == nil, let v = ini.int(T, "AlphaBlend") { s.alphaBlendActive = v }
        if let v = ini.string(T, "Answerback") { s.answerback = v }
        // VTFontSpace=左,右,上,下。内部の fontDW / fontDH は 左+右 / 上+下 (ttset.c: FontDW += FontDX, FontDH += FontDY)
        if let v = ini.ints(T, "VTFontSpace"), v.count >= 4 { (s.fontDX, s.fontDW, s.fontDY, s.fontDH) = (v[0], v[1] + v[0], v[2], v[3] + v[2]) }
        if let v = ini.string(T, "KatakanaReceive") { s.katakanaReceive7 = v.trimmingCharacters(in: .whitespaces) == "7" }
        if let v = ini.string(T, "KatakanaSend") { s.katakanaSend7 = v.trimmingCharacters(in: .whitespaces) == "7" }
        if let v = ini.string(T, "Port") { s.portType = v.lowercased() == "serial" ? "serial" : "tcpip" }
        if let v = ini.string(T, "LogTimestampType"), v.isEmpty { s.logTimestampType = "Local" }
        // Windows の notepad.exe は Mac ではテキストエディット
        if s.viewlogEditor.lowercased() == "notepad.exe" { s.viewlogEditor = "" }
        return n
    }

    // MARK: - 変換

    static func encoding(_ s: String) -> TermEncoding? {
        // GetKanjiCodeFromStr: 本家の INI の名前 (ttlib_charset.cpp KanjiList)。ほかは前からの読み方
        if let e = TermEncoding.exactKanjiCodeStr(s) { return e }
        let l = s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        if l.hasPrefix("utf8") { return .utf8 }
        if l.hasPrefix("sjis") || l.hasPrefix("shiftjis") || l == "cp932" { return .sjis }
        if l.hasPrefix("euc") { return .eucjp }
        if l == "jis" || l.hasPrefix("iso2022jp") { return .jis }
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

/// 設定の保存: TERATERM.INI の形で書く (ttset.c WriteIniFile のうち Tera Term Mac が持つもの)
enum TeraTermIniExport {
    /// GetKanjiCodeStr (ttlib_charset.cpp)。EUC は前からの書き方 "EUC" のまま
    static func kanjiName(_ e: TermEncoding) -> String {
        e == .eucjp ? "EUC" : e.iniName
    }

    static func onOff(_ b: Bool) -> String { b ? "on" : "off" }

    static func document(settings s: TermSettings, transfer t: FileTransferOptions, extra: TransferExtraSettings? = nil,
                         base: IniDocument = IniDocument()) -> IniDocument {
        let doc = base
        let T = "Tera Term"
        func set(_ k: String, _ v: String?) { doc.set(T, k, v) }
        set("TerminalSize", "\(s.cols),\(s.rows)")
        set("KanjiReceive", kanjiName(s.encoding))
        set("KanjiSend", kanjiName(s.encodingSend))
        set("CRReceive", ["AUTO": "CR", "CR": "CRLF", "LF": "LF", "AUTODETECT": "AUTO"][s.recvNewline] ?? "CR")
        set("CRSend", s.sendNewline)
        set("LocalEcho", onOff(s.localEcho))
        set("BSKey", s.bsSendsDel ? "DEL" : "BS")
        set("ScrollBuffSize", String(s.scrollback))
        set("UnicodeAmbiguousWidth", s.ambiguousWide ? "2" : "1")
        set("CursorShape", s.cursorShape)
        set("NonblinkingCursor", onOff(!s.cursorBlink))
        set("AutoTextCopy", onOff(s.copyOnSelect))
        set("DisablePasteMouseRButton", onOff(!s.rightClickPaste))
        set("ConfirmChangePaste", onOff(s.confirmChangePaste))
        set("ConfirmChangePasteCR", onOff(s.confirmChangePasteCR))
        set("ConfirmChangePasteStringFile", s.confirmChangePasteStringFile)
        set("TrimTrailingNLonPaste", onOff(s.trimTrailingNLOnPaste))
        set("BracketedControlOnly", onOff(s.bracketedControlOnly))
        set("PasteDelayPerLine", String(s.pasteDelayPerLine))
        set("EnableContinuedLineCopy", onOff(s.continuedLineCopy))
        set("LogTimestamp", onOff(s.logTimestamp))
        set("DelayPerChar", String(s.charDelayMs))
        set("DelayPerLine", String(s.lineDelayMs))
        set("VTColor", TermSettings.rgbString(s.fg) + "," + TermSettings.rgbString(s.bg))
        // ANSIColor: Tera Term の番号は 0-7 が明るい色、8-15 が通常の色
        let ansi = s.ansi16 ?? Array(Palette.colors.prefix(16))
        let tt = Array(ansi[8..<16]) + Array(ansi[0..<8])
        set("ANSIColor", tt.enumerated().map { "\($0.offset)," + TermSettings.rgbString($0.element) }.joined(separator: ", "))
        // フォントの高さはピクセル (負 = 文字の高さ)。読み込み (pt = |h| * 72/96) の逆
        set("VTFont", "\(s.fontName),0,-\(Int((s.fontSize * 96 / 72).rounded())),1")
        set("VTFontSpace", "\(s.fontDX),\(s.fontDW - s.fontDX),\(s.fontDY),\(s.fontDH - s.fontDY)")   // 書くときは 右 / 下 に戻す
        for (k, p) in TermSettings.boolFields { set(k, onOff(s[keyPath: p])) }
        for (k, p) in TermSettings.intFields { set(k, String(s[keyPath: p])) }
        for (k, p) in TermSettings.stringFields where k != "TeraMacThemeName" { set(k, s[keyPath: p]) }
        for (k, p) in TermSettings.colorPairFields { set(k, s[keyPath: p].iniString) }
        set("Answerback", s.answerback)
        // Logging dialog show state (ttset.c _WriteIniFile, 23aa80682 #1576): 非表示なら LogDialogShowState は空
        switch s.logShowState {
        case 0: set("LogHideDialog", "on"); set("LogDialogShowState", "")
        case 2: set("LogHideDialog", "off"); set("LogDialogShowState", "normal")
        default: set("LogHideDialog", "off"); set("LogDialogShowState", "minimized")
        }
        set("KatakanaReceive", s.katakanaReceive7 ? "7" : "8")
        set("KatakanaSend", s.katakanaSend7 ? "7" : "8")
        set("FileDir", t.fileDir)
        // Sendfile (ttset.c _WriteIniFile。Send file ダイアログのオプションを保存する 5.4.0)
        set("SendfileDelayType", ["NoDelay", "PerChar", "PerLine", "PerSendSize"][max(0, min(3, t.sendfileDelayType))])
        set("SendfileDelayTick", String(t.sendfileDelayTick))
        set("SendfileSize", String(t.sendfileSize))
        if let x = extra {
            set("SendfileSequential", onOff(x.sendfileSequential))
            set("SendfileSkipOptionDialog", onOff(x.sendfileSkipOptionDialog))
        }
        // UI言語 (本家と同じ書き方。自動のときは空)
        set("UILanguageFile", Lang.chosen.map { "lang_utf8\\" + $0 } ?? "")
        // シリアル
        let sp = ConnHistory.serial
        set("BaudRate", String(sp.baud))
        set("DataBit", String(sp.dataBits))
        set("Parity", sp.parity)
        set("StopBit", String(sp.stopBits))
        set("FlowCtrl", ["xon": "x", "rts": "hard", "dsr": "dsrdtr"][sp.flow] ?? "none")
        set("FlowCtrlRTS", String(sp.rts))
        set("FlowCtrlDTR", String(sp.dtr))
        // TTSSH / TTProxy
        let ssh = SSHSettings.load()
        ssh.write(doc)
        ProxySettings.load().write(doc)
        // [Hosts] (CopyHostList)
        doc.removeSection("Hosts")
        for (i, h) in ConnHistory.hosts.enumerated() { doc.set("Hosts", "Host\(i + 1)", h) }
        return doc
    }

    /// path に書く。すでにあるファイルなら、知らないキー・セクションはそのまま残す
    static func write(settings: TermSettings, transfer: FileTransferOptions, extra: TransferExtraSettings? = nil, to path: String) throws {
        let base = FileManager.default.fileExists(atPath: path) ? IniDocument(contentsOf: path) : IniDocument()
        try document(settings: settings, transfer: transfer, extra: extra, base: base).write(to: path)
    }
}
