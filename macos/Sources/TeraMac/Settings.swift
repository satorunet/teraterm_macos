import AppKit
import TeraCore

/// 端末の設定 (UserDefaults に保存。Tera Term の TERATERM.INI に相当)
struct TermSettings {
    // 標準のターミナル (Terminal.app) の既定プロファイルと同じフォントにする
    var fontName = TermSettings.terminalAppFont.fontName
    var fontSize: CGFloat = TermSettings.terminalAppFont.pointSize
    var cols = 80
    var rows = 24
    var encoding: TermEncoding = .utf8
    var recvNewline = "AUTO"   // AUTO / CR / LF
    var sendNewline = "CR"     // CR / CRLF / LF
    var localEcho = false
    var bsSendsDel = true
    var optionAsMeta = true
    var ambiguousWide = false
    var fg = NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1)
    var bg = NSColor.black
    var cursorColor = NSColor(srgbRed: 0.6, green: 1.0, blue: 0.6, alpha: 1)
    var copyOnSelect = true
    var rightClickPaste = true
    /// ConfirmChangePaste: 改行を含む文字の貼り付けを確認する (確認全体のスイッチ)
    var confirmChangePaste = true
    /// ConfirmChangePasteCR: 「貼り付け<CR>」はいつも確認する
    var confirmChangePasteCR = true
    /// ConfirmChangePasteStringFile: この中の行を含む文字を貼り付けるときも確認する
    var confirmChangePasteStringFile = ""
    /// TrimTrailingNLonPaste: 貼り付ける文字の最後の改行を除く
    var trimTrailingNLOnPaste = false
    /// BracketedControlOnly: 制御文字を含むときだけブラケットで囲む
    var bracketedControlOnly = false
    /// PasteDelayPerLine: 貼り付けで 1 行送るごとに待つミリ秒
    var pasteDelayPerLine = 10
    /// EnableContinuedLineCopy: 折り返して続く行をつなげてコピーする
    var continuedLineCopy = false
    var scrollback = 10000
    var cursorBlink = true
    var charDelayMs = 0
    var lineDelayMs = 0
    var logTimestamp = false
    /// block / vertical / horizontal (Tera Term の CursorShape)
    var cursorShape = "block"
    /// ANSI 16 色を差し替えるとき (Tera Term の ANSIColor)。nil なら標準
    var ansi16: [NSColor]?

    // MARK: その他の設定 (Tera Term の ts。UserDefaults のキーは TERATERM.INI のキー名と同じ)
    // 端末
    var encodingSend: TermEncoding = .utf8          // KanjiSend
    var termIsWin = false                           // TermIsWin
    var autoWinResize = false                       // AutoWinResize
    var terminalID = "VT100"                        // TerminalID
    var answerback = ""                             // Answerback (\xx でエスケープ)
    var autoWinSwitch = false                       // AutoWinSwitch
    // ウィンドウ
    var title = "Tera Term Mac"                     // Title (Mac の既定は "Tera Term Mac")
    var pcBoldColor = true                          // PcBoldColor (同梱の TERATERM.INI と同じ on)
    var aixterm16Color = true                       // Aixterm16Color (同梱の TERATERM.INI と同じ on)
    var xterm256Color = true                        // Xterm256Color
    var enableScrollBuff = true                     // EnableScrollBuff
    var enableBold = true                           // EnableBold
    var boldColor = ColorPair(0xFFFF00, 0x000000)      // VTBoldColor
    var blinkColor = ColorPair(0xFF0000, 0x000000)     // VTBlinkColor
    var reverseColor = ColorPair(0x000000, 0xFFFFFF)   // VTReverseColor
    var urlColor = ColorPair(0x00FFFF, 0x000000)       // URLColor
    var underlineColor = ColorPair(0x00FF00, 0x000000) // VTUnderlineColor
    var useNormalBGColor = false                    // UseNormalBGColor
    var popupMenu = false                           // PopupMenu (on = ウィンドウ内のメニューバーを隠す)
    // フォント
    var drawingResizedFont = true                   // DrawingResizedFont
    var fontDX = 0, fontDW = 0, fontDY = 0, fontDH = 0   // VTFontSpace (左, 左+右, 上, 上+下。本家 ts.FontDX〜FontDH と同じ持ち方)
    // キーボード
    var deleteKeySendsDel = false                   // DeleteKey
    var metaKey = "on"                              // MetaKey off/on/left/right (optionAsMeta と連動)
    var disableAppKeypad = false                    // DisableAppKeypad
    var disableAppCursor = false                    // DisableAppCursor
    // TCP/IP
    var historyList = true                          // HistoryList
    var telnet = true                               // Telnet
    var tcpPort = 23                                // TCPPort
    var telKeepAliveInterval = 300                  // TelKeepAliveInterval
    var autoWinClose = true                         // AutoWinClose
    var telBin = false                              // TelBin (Telnet の BINARY を自分から申し込む。/B)
    var termType = "xterm"                          // TermType
    // 全般
    var disableAcceleratorSendBreak = false         // DisableAcceleratorSendBreak
    var acceptBroadcast = true                      // AcceptBroadcast
    var autoScrollOnlyInBottomLine = false          // AutoScrollOnlyInBottomLine
    var clearOnResize = false                       // ClearOnResize
    var portType = "tcpip"                          // Port (tcpip / serial)
    var titleFormat = 13                            // TitleFormat
    var notifySound = true                          // NotifySound
    var fileDir = ""                                // FileDir
    // 制御シーケンス
    var mouseEventTracking = true                   // MouseEventTracking
    var disableMouseTrackingByCtrl = true           // DisableMouseTrackingByCtrl
    var acceptTitleChangeRequest = "overwrite"      // AcceptTitleChangeRequest off/overwrite/ahead/last
    var titleReportSequence = "empty"               // TitleReportSequence ignore/accept/empty
    var windowCtrlSequence = true                   // WindowCtrlSequence
    var windowReportSequence = true                 // WindowReportSequence
    var cursorCtrlSequence = false                  // CursorCtrlSequence
    var clipboardAccessFromRemote = "off"           // ClipboardAccessFromRemote off/write/read/on
    var notifyClipboardAccess = true                // NotifyClipboardAccess
    var clearScrollBufferFromRemote = true          // ClearScrollBufferFromRemote
    var printerCtrlSequence = false                 // PrinterCtrlSequence
    var beep = "on"                                 // Beep off/on/visual
    // コピーと貼り付け
    var confirmPasteMouseRButton = false            // ConfirmPasteMouseRButton
    var disablePasteMouseMButton = true             // DisablePasteMouseMButton
    var selectOnlyByLButton = true                  // SelectOnlyByLButton
    var delimList = "$20!\"#$24%&'()*+,-./:;<=>?@[\\]^`{|}~"   // DelimList
    var selectOnActivate = true                     // SelectOnActivate
    // 表示
    var alphaBlendActive = 255                      // AlphaBlendActive
    var alphaBlendInactive = 255                    // AlphaBlend
    var mouseCursor = "IBEAM"                       // MouseCursor ARROW/IBEAM/CROSS/HAND
    var fontQuality = "default"                     // FontQuality default/nonantialiased/antialiased/cleartype
    var enableBoldAttrColor = true                  // EnableBoldAttrColor
    var underlineAttrColor = true                   // UnderlineAttrColor
    var underlineAttrFont = true                    // UnderlineAttrFont
    var enableBlinkAttrColor = true                 // EnableBlinkAttrColor
    var enableReverseAttrColor = false              // EnableReverseAttrColor
    var enableURLColor = true                       // EnableURLColor
    var urlUnderline = true                         // URLUnderline
    var enableANSIColor = true                      // EnableANSIColor
    // ログ
    var viewlogEditor = ""                          // ViewlogEditor (空ならテキストエディット)
    var viewlogEditorArg = ""                       // ViewlogEditorArg
    var logDefaultName = "teraterm.log"             // LogDefaultName
    var logDefaultPath = ""                         // LogDefaultPath
    var logAutoStart = false                        // LogAutoStart
    var logBinary = false                           // LogBinary
    var logAppend = false                           // LogAppend
    var logTypePlainText = false                    // LogTypePlainText
    var logHideDialog = false                       // LogHideDialog
    var logIncludeScreenBuffer = false              // LogIncludeScreenBuffer
    var logTimestampType = "Local"                  // LogTimestampType Local/UTC/LoggingElapsed/ConnectionElapsed
    var logRotate = 0                               // LogRotate (0: しない 1: サイズ)
    var logRotateSize = 0                           // LogRotateSize
    var logRotateSizeType = 0                       // LogRotateSizeType (0: Byte 1: KB 2: MB)
    var logRotateStep = 0                           // LogRotateStep
    // エンコーディング
    var unicodeEmojiOverride = false                // UnicodeEmojiOverride
    var unicodeEmojiWidth = 1                       // UnicodeEmojiWidth
    var decSpMappingDir = 2                         // DecSpMappingDir
    var unicodeToDecSpMapping = 3                   // UnicodeToDecSpMapping
    var katakanaReceive7 = false                    // KatakanaReceive (7 / 8)
    var katakanaSend7 = false                       // KatakanaSend (7 / 8)
    var kanjiIn = "B"                               // KanjiIn (@ / B)
    var kanjiOut = "B"                              // KanjiOut (B / J / H)
    // テーマ
    var themeName = ""                              // (Mac) 最後に選んだ配色の名前
    // マウス
    var enableClickableUrl = false                  // EnableClickableUrl
    var mouseWheelScrollLine = 3                    // MouseWheelScrollLine
    // 設定画面にない INI の設定
    var confirmDisconnect = true                    // ConfirmDisconnect
    var sendBreakTime = 1000                        // SendBreakTime (ミリ秒)

    private static let d = UserDefaults.standard

    /// Terminal.app の既定プロファイルのフォント (読めなければ Terminal の初期値 Menlo 11pt)
    static let terminalAppFont: NSFont = {
        let fallback = NSFont(name: "Menlo-Regular", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        guard let t = UserDefaults(suiteName: "com.apple.Terminal"),
              let profile = t.string(forKey: "Default Window Settings"),
              let all = t.dictionary(forKey: "Window Settings"),
              let p = all[profile] as? [String: Any] else { return fallback }
        guard let data = p["Font"] as? Data else { return fallback }
        return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data)) ?? fallback
    }()

    /// 初期値: プログラムの既定値に、アプリに同梱した本家の TERATERM.INI (installer/release/TERATERM.INI) を重ねたもの。
    /// 本家も同梱の TERATERM.INI を読んで起動するので、初めて起動したときの設定は本家と同じになる。
    /// そのうえで Mac では次の 2 つだけ変える (macOverrides)
    static func initial() -> TermSettings {
        var s = TermSettings()
        if let url = Bundle.main.url(forResource: "TERATERM", withExtension: "INI"),
           let data = try? Data(contentsOf: url), let ini = IniFile(data: data) {
            // 設定だけ使う。ホスト履歴 (例の名前) やシリアルの既定は取り込まない
            s = TeraTermIniImport.read(ini, base: s).settings
        }
        s.macOverrides()
        return s
    }

    /// Mac での使いやすさのために、同梱の TERATERM.INI と変えている値
    private mutating func macOverrides() {
        termType = "xterm-256color"   // TermType=xterm。Mac のターミナルと同じく 256 色を使えるように
        bsSendsDel = true             // BSKey=BS。Mac の delete キーはターミナル.app と同じく DEL を送る
        title = "Tera Term Mac"       // Title=Tera Term。名称「Tera Term Mac」は許可済み
        // VTFontSpace=0,0,0,0。Mac では行が詰まって見えるので、行の上に 1 だけ隙間を足す (左,右,上,下 = 0,0,1,0)
        (fontDX, fontDW, fontDY, fontDH) = (0, 0, 1, 1)
    }

    static func load() -> TermSettings {
        var s = initial()
        let d = Self.d
        if let v = d.string(forKey: "fontName"), NSFont(name: v, size: 12) != nil { s.fontName = v }
        if d.object(forKey: "fontSize") != nil { s.fontSize = CGFloat(max(6, min(72, d.double(forKey: "fontSize")))) }
        if d.object(forKey: "cols") != nil { s.cols = max(10, min(500, d.integer(forKey: "cols"))) }
        if d.object(forKey: "rows") != nil { s.rows = max(2, min(300, d.integer(forKey: "rows"))) }
        if let v = d.string(forKey: "encoding"), let e = TermEncoding(rawValue: v) { s.encoding = e }
        if let v = d.string(forKey: "recvNewline") { s.recvNewline = v }
        if let v = d.string(forKey: "sendNewline") { s.sendNewline = v }
        if d.object(forKey: "localEcho") != nil { s.localEcho = d.bool(forKey: "localEcho") }
        if d.object(forKey: "bsSendsDel") != nil { s.bsSendsDel = d.bool(forKey: "bsSendsDel") }
        if d.object(forKey: "optionAsMeta") != nil { s.optionAsMeta = d.bool(forKey: "optionAsMeta") }
        if d.object(forKey: "ambiguousWide") != nil { s.ambiguousWide = d.bool(forKey: "ambiguousWide") }
        if d.object(forKey: "copyOnSelect") != nil { s.copyOnSelect = d.bool(forKey: "copyOnSelect") }
        if d.object(forKey: "rightClickPaste") != nil { s.rightClickPaste = d.bool(forKey: "rightClickPaste") }
        if d.object(forKey: "confirmMultilinePaste") != nil { s.confirmChangePaste = d.bool(forKey: "confirmMultilinePaste") }
        if d.object(forKey: "confirmChangePasteCR") != nil { s.confirmChangePasteCR = d.bool(forKey: "confirmChangePasteCR") }
        if let v = d.string(forKey: "confirmChangePasteStringFile") { s.confirmChangePasteStringFile = v }
        if d.object(forKey: "trimTrailingNLOnPaste") != nil { s.trimTrailingNLOnPaste = d.bool(forKey: "trimTrailingNLOnPaste") }
        if d.object(forKey: "bracketedControlOnly") != nil { s.bracketedControlOnly = d.bool(forKey: "bracketedControlOnly") }
        if d.object(forKey: "pasteDelayPerLine") != nil { s.pasteDelayPerLine = max(0, d.integer(forKey: "pasteDelayPerLine")) }
        if d.object(forKey: "continuedLineCopy") != nil { s.continuedLineCopy = d.bool(forKey: "continuedLineCopy") }
        if d.object(forKey: "cursorBlink") != nil { s.cursorBlink = d.bool(forKey: "cursorBlink") }
        if d.object(forKey: "logTimestamp") != nil { s.logTimestamp = d.bool(forKey: "logTimestamp") }
        if d.object(forKey: "scrollback") != nil { s.scrollback = max(0, d.integer(forKey: "scrollback")) }
        s.charDelayMs = d.integer(forKey: "charDelayMs")
        s.lineDelayMs = d.integer(forKey: "lineDelayMs")
        if let c = color(d.string(forKey: "fg")) { s.fg = c }
        if let c = color(d.string(forKey: "bg")) { s.bg = c }
        if let c = color(d.string(forKey: "cursorColor")) { s.cursorColor = c }
        if let v = d.string(forKey: "cursorShape") { s.cursorShape = v }
        if let list = d.string(forKey: "ansi16") {
            let cs = list.split(separator: ",").compactMap { color(String($0)) }
            if cs.count == 16 { s.ansi16 = cs }
        }
        s.loadExtra(d)
        return s
    }

    func save() {
        let d = Self.d
        d.set(fontName, forKey: "fontName")
        d.set(Double(fontSize), forKey: "fontSize")
        d.set(cols, forKey: "cols")
        d.set(rows, forKey: "rows")
        d.set(encoding.rawValue, forKey: "encoding")
        d.set(recvNewline, forKey: "recvNewline")
        d.set(sendNewline, forKey: "sendNewline")
        d.set(localEcho, forKey: "localEcho")
        d.set(bsSendsDel, forKey: "bsSendsDel")
        d.set(optionAsMeta, forKey: "optionAsMeta")
        d.set(ambiguousWide, forKey: "ambiguousWide")
        d.set(copyOnSelect, forKey: "copyOnSelect")
        d.set(rightClickPaste, forKey: "rightClickPaste")
        d.set(confirmChangePaste, forKey: "confirmMultilinePaste")
        d.set(confirmChangePasteCR, forKey: "confirmChangePasteCR")
        d.set(confirmChangePasteStringFile, forKey: "confirmChangePasteStringFile")
        d.set(trimTrailingNLOnPaste, forKey: "trimTrailingNLOnPaste")
        d.set(bracketedControlOnly, forKey: "bracketedControlOnly")
        d.set(pasteDelayPerLine, forKey: "pasteDelayPerLine")
        d.set(continuedLineCopy, forKey: "continuedLineCopy")
        d.set(cursorBlink, forKey: "cursorBlink")
        d.set(logTimestamp, forKey: "logTimestamp")
        d.set(scrollback, forKey: "scrollback")
        d.set(charDelayMs, forKey: "charDelayMs")
        d.set(lineDelayMs, forKey: "lineDelayMs")
        d.set(hex(fg), forKey: "fg")
        d.set(hex(bg), forKey: "bg")
        d.set(hex(cursorColor), forKey: "cursorColor")
        d.set(cursorShape, forKey: "cursorShape")
        if let a = ansi16 { d.set(a.map { hex($0) }.joined(separator: ","), forKey: "ansi16") } else { d.removeObject(forKey: "ansi16") }
        saveExtra(d)
    }

    /// ConfirmChangePasteStringFile の空でない行 (相対パスは設定フォルダから)。ファイルがなければ nil
    func confirmChangePasteWords() -> [String]? {
        guard !confirmChangePasteStringFile.isEmpty else { return nil }
        var path = (confirmChangePasteStringFile as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (AppPaths.setupDirectory as NSString).appendingPathComponent(path) }
        guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return t.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var sendNewlineBytes: [UInt8] {
        switch sendNewline {
        case "CRLF": return [0x0D, 0x0A]
        case "LF": return [0x0A]
        default: return [0x0D]
        }
    }

    private static func color(_ s: String?) -> NSColor? {
        guard let s = s, s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    private func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "%02X%02X%02X", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)),
                      Int(round(s.blueComponent * 255)))
    }
}

/// 設定フォルダ (Tera Term の HomeDir にあたる。TERATERM.INI・broadcast.log などを置く)
enum AppPaths {
    static var setupDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        let dir = (base as NSString).appendingPathComponent("Tera Term Mac")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 最近つないだ接続先と、前回の接続ダイアログの内容
enum ConnHistory {
    private static let d = UserDefaults.standard

    static var hosts: [String] {
        get { d.stringArray(forKey: "recentHosts") ?? [] }
        set { d.set(Array(newValue.prefix(20)), forKey: "recentHosts") }
    }
    static func remember(host: String) {
        var h = hosts.filter { $0 != host }
        h.insert(host, at: 0)
        hosts = h
    }

    static var lastService: String {
        get { d.string(forKey: "lastService") ?? "ssh" }
        set { d.set(newValue, forKey: "lastService") }
    }
    static var lastMode: String {
        get { d.string(forKey: "lastMode") ?? "tcp" }
        set { d.set(newValue, forKey: "lastMode") }
    }
    static var lastUser: String {
        get { d.string(forKey: "lastUser") ?? NSUserName() }
        set { d.set(newValue, forKey: "lastUser") }
    }
    static var lastKeyFile: String {
        get { d.string(forKey: "lastKeyFile") ?? "" }
        set { d.set(newValue, forKey: "lastKeyFile") }
    }
    static var serial: SerialParams {
        get {
            var s = SerialParams()
            s.path = d.string(forKey: "serialPath") ?? ""
            if d.object(forKey: "serialBaud") != nil { s.baud = d.integer(forKey: "serialBaud") }
            if d.object(forKey: "serialData") != nil { s.dataBits = d.integer(forKey: "serialData") }
            s.parity = d.string(forKey: "serialParity") ?? "none"
            if d.object(forKey: "serialStop") != nil { s.stopBits = d.integer(forKey: "serialStop") }
            s.flow = d.string(forKey: "serialFlow") ?? "none"
            return s
        }
        set {
            d.set(newValue.path, forKey: "serialPath")
            d.set(newValue.baud, forKey: "serialBaud")
            d.set(newValue.dataBits, forKey: "serialData")
            d.set(newValue.parity, forKey: "serialParity")
            d.set(newValue.stopBits, forKey: "serialStop")
            d.set(newValue.flow, forKey: "serialFlow")
        }
    }
}

/// xterm 互換の 256 色
enum Palette {
    static let base16: [(Int, Int, Int)] = [
        (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
        (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
        (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
        (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
    ]

    static let colors: [NSColor] = (0..<256).map { i in
        func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        if i < 16 { let v = base16[i]; return c(v.0, v.1, v.2) }
        if i < 232 {
            let n = i - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return c(steps[n / 36], steps[(n / 6) % 6], steps[n % 6])
        }
        let g = 8 + (i - 232) * 10
        return c(g, g, g)
    }
}

/// 文字色と背景色の組 (VTBoldColor=r,g,b,r,g,b など)
struct ColorPair: Equatable {
    var fg: NSColor
    var bg: NSColor
    init(_ fg: UInt32, _ bg: UInt32) { self.fg = ColorScheme.hex(fg); self.bg = ColorScheme.hex(bg) }
    init(fg: NSColor, bg: NSColor) { self.fg = fg; self.bg = bg }

    /// "r,g,b,r,g,b" (TERATERM.INI の書き方)
    var iniString: String { TermSettings.rgbString(fg) + "," + TermSettings.rgbString(bg) }
    init?(iniString s: String) {
        let v = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count >= 6 else { return nil }
        fg = TermSettings.rgb(v[0], v[1], v[2]); bg = TermSettings.rgb(v[3], v[4], v[5])
    }
}

extension TermSettings {
    /// on/off の設定 (UserDefaults と TERATERM.INI [Tera Term] で同じキー名)
    static let boolFields: [(String, WritableKeyPath<TermSettings, Bool>)] = [
        ("TermIsWin", \.termIsWin), ("AutoWinResize", \.autoWinResize), ("AutoWinSwitch", \.autoWinSwitch),
        ("PcBoldColor", \.pcBoldColor), ("Aixterm16Color", \.aixterm16Color), ("Xterm256Color", \.xterm256Color),
        ("EnableScrollBuff", \.enableScrollBuff), ("EnableBold", \.enableBold), ("UseNormalBGColor", \.useNormalBGColor), ("PopupMenu", \.popupMenu),
        ("DrawingResizedFont", \.drawingResizedFont),
        ("DeleteKey", \.deleteKeySendsDel), ("DisableAppKeypad", \.disableAppKeypad), ("DisableAppCursor", \.disableAppCursor),
        ("HistoryList", \.historyList), ("Telnet", \.telnet), ("AutoWinClose", \.autoWinClose), ("TelBin", \.telBin),
        ("DisableAcceleratorSendBreak", \.disableAcceleratorSendBreak), ("AcceptBroadcast", \.acceptBroadcast),
        ("AutoScrollOnlyInBottomLine", \.autoScrollOnlyInBottomLine), ("ClearOnResize", \.clearOnResize),
        ("NotifySound", \.notifySound),
        ("MouseEventTracking", \.mouseEventTracking), ("DisableMouseTrackingByCtrl", \.disableMouseTrackingByCtrl),
        ("WindowCtrlSequence", \.windowCtrlSequence), ("WindowReportSequence", \.windowReportSequence),
        ("CursorCtrlSequence", \.cursorCtrlSequence), ("NotifyClipboardAccess", \.notifyClipboardAccess),
        ("ClearScrollBufferFromRemote", \.clearScrollBufferFromRemote), ("PrinterCtrlSequence", \.printerCtrlSequence),
        ("ConfirmPasteMouseRButton", \.confirmPasteMouseRButton), ("DisablePasteMouseMButton", \.disablePasteMouseMButton),
        ("SelectOnlyByLButton", \.selectOnlyByLButton), ("SelectOnActivate", \.selectOnActivate),
        ("EnableBoldAttrColor", \.enableBoldAttrColor), ("UnderlineAttrColor", \.underlineAttrColor),
        ("UnderlineAttrFont", \.underlineAttrFont), ("EnableBlinkAttrColor", \.enableBlinkAttrColor),
        ("EnableReverseAttrColor", \.enableReverseAttrColor), ("EnableURLColor", \.enableURLColor),
        ("URLUnderline", \.urlUnderline), ("EnableANSIColor", \.enableANSIColor),
        ("LogAutoStart", \.logAutoStart), ("LogBinary", \.logBinary), ("LogAppend", \.logAppend),
        ("LogTypePlainText", \.logTypePlainText), ("LogHideDialog", \.logHideDialog),
        ("LogIncludeScreenBuffer", \.logIncludeScreenBuffer),
        ("UnicodeEmojiOverride", \.unicodeEmojiOverride),
        ("EnableClickableUrl", \.enableClickableUrl), ("ConfirmDisconnect", \.confirmDisconnect),
    ]
    static let intFields: [(String, WritableKeyPath<TermSettings, Int>)] = [
        ("TCPPort", \.tcpPort), ("TelKeepAliveInterval", \.telKeepAliveInterval), ("TitleFormat", \.titleFormat),
        ("AlphaBlendActive", \.alphaBlendActive), ("AlphaBlend", \.alphaBlendInactive),
        ("LogRotate", \.logRotate), ("LogRotateSize", \.logRotateSize), ("LogRotateSizeType", \.logRotateSizeType),
        ("LogRotateStep", \.logRotateStep),
        ("UnicodeEmojiWidth", \.unicodeEmojiWidth), ("DecSpMappingDir", \.decSpMappingDir),
        ("UnicodeToDecSpMapping", \.unicodeToDecSpMapping),
        ("MouseWheelScrollLine", \.mouseWheelScrollLine), ("SendBreakTime", \.sendBreakTime),
    ]
    static let stringFields: [(String, WritableKeyPath<TermSettings, String>)] = [
        ("TerminalID", \.terminalID), ("Title", \.title), ("MetaKey", \.metaKey), ("TermType", \.termType),
        ("Port", \.portType),
        ("AcceptTitleChangeRequest", \.acceptTitleChangeRequest), ("TitleReportSequence", \.titleReportSequence),
        ("ClipboardAccessFromRemote", \.clipboardAccessFromRemote), ("Beep", \.beep),
        ("MouseCursor", \.mouseCursor), ("FontQuality", \.fontQuality),
        ("ViewlogEditor", \.viewlogEditor), ("ViewlogEditorArg", \.viewlogEditorArg),
        ("LogDefaultName", \.logDefaultName), ("LogDefaultPath", \.logDefaultPath),
        ("LogTimestampType", \.logTimestampType), ("KanjiIn", \.kanjiIn), ("KanjiOut", \.kanjiOut),
        ("TeraMacThemeName", \.themeName),
    ]
    static let colorPairFields: [(String, WritableKeyPath<TermSettings, ColorPair>)] = [
        ("VTBoldColor", \.boldColor), ("VTBlinkColor", \.blinkColor), ("VTReverseColor", \.reverseColor),
        ("URLColor", \.urlColor), ("VTUnderlineColor", \.underlineColor),
    ]

    fileprivate mutating func loadExtra(_ d: UserDefaults) {
        for (k, p) in Self.boolFields where d.object(forKey: k) != nil { self[keyPath: p] = d.bool(forKey: k) }
        for (k, p) in Self.intFields where d.object(forKey: k) != nil { self[keyPath: p] = d.integer(forKey: k) }
        for (k, p) in Self.stringFields { if let v = d.string(forKey: k) { self[keyPath: p] = v } }
        for (k, p) in Self.colorPairFields { if let v = d.string(forKey: k), let c = ColorPair(iniString: v) { self[keyPath: p] = c } }
        // 以前からのキー: Meta キーは optionAsMeta から
        if d.string(forKey: "MetaKey") == nil { metaKey = optionAsMeta ? "on" : "off" }
        optionAsMeta = metaKey.lowercased() != "off"
        if let v = d.string(forKey: "encodingSend"), let e = TermEncoding(rawValue: v) { encodingSend = e } else { encodingSend = encoding }
        if let v = d.string(forKey: "Answerback") { answerback = v }
        if let v = d.array(forKey: "VTFontSpace") as? [Int], v.count == 4 { (fontDX, fontDW, fontDY, fontDH) = (v[0], v[1], v[2], v[3]) }
        // FileDir は設定画面で決めたとき (savedFileDir) だけ保存する。なければ TERATERM.INI の FileDir
        fileDir = d.string(forKey: "FileDir") ?? FileTransferOptions.loadTeraTermIni().options.fileDir
        if d.object(forKey: "KatakanaReceive") != nil { katakanaReceive7 = d.bool(forKey: "KatakanaReceive") }
        if d.object(forKey: "KatakanaSend") != nil { katakanaSend7 = d.bool(forKey: "KatakanaSend") }
    }

    fileprivate func saveExtra(_ d: UserDefaults) {
        for (k, p) in Self.boolFields { d.set(self[keyPath: p], forKey: k) }
        for (k, p) in Self.intFields { d.set(self[keyPath: p], forKey: k) }
        for (k, p) in Self.stringFields { d.set(self[keyPath: p], forKey: k) }
        for (k, p) in Self.colorPairFields { d.set(self[keyPath: p].iniString, forKey: k) }
        d.set(encodingSend.rawValue, forKey: "encodingSend")
        d.set(answerback, forKey: "Answerback")
        d.set([fontDX, fontDW, fontDY, fontDH], forKey: "VTFontSpace")
        d.set(katakanaReceive7, forKey: "KatakanaReceive")
        d.set(katakanaSend7, forKey: "KatakanaSend")
    }

    /// 新しいウインドウのファイル転送の設定: TERATERM.INI を読み、FileDir は保存した設定を使う
    static func initialTransferOptions() -> FileTransferOptions {
        var o = FileTransferOptions.loadTeraTermIni().options
        if let v = UserDefaults.standard.string(forKey: "FileDir") { o.fileDir = v }
        return o
    }

    /// ファイル転送のフォルダ (FileDir) を保存する。新しいウインドウはこれを使う
    static func saveFileDir(_ v: String) { UserDefaults.standard.set(v, forKey: "FileDir") }

    /// Answerback の \xx エスケープを外したバイト列 (Hex2Str)
    var answerbackBytes: [UInt8] { Self.hex2bytes(answerback) }

    static func hex2bytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        let b = Array(s.utf8)
        var i = 0
        while i < b.count {
            if b[i] == 0x5C, i + 1 < b.count {
                if b[i + 1] == 0x5C { out.append(0x5C); i += 2; continue }
                if i + 2 < b.count, let v = UInt8(String(bytes: b[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                    out.append(v); i += 3; continue
                }
            }
            out.append(b[i]); i += 1
        }
        return out
    }

    /// Str2Hex: 制御文字と \ を \xx にする
    static func bytes2hex(_ b: [UInt8]) -> String {
        var s = ""
        for c in b {
            if c < 0x20 || c == 0x7F { s += String(format: "\\%02x", c) }
            else if c == 0x5C { s += "\\\\" }
            else { s.unicodeScalars.append(UnicodeScalar(c)) }
        }
        return s
    }

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        func c(_ v: Int) -> CGFloat { CGFloat(max(0, min(255, v))) / 255 }
        return NSColor(srgbRed: c(r), green: c(g), blue: c(b), alpha: 1)
    }

    static func rgbComponents(_ c: NSColor) -> (Int, Int, Int) {
        let s = c.usingColorSpace(.sRGB) ?? c
        return (Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
    }

    static func rgbString(_ c: NSColor) -> String {
        let (r, g, b) = rgbComponents(c)
        return "\(r),\(g),\(b)"
    }

    /// TERATERM.INI のファイル (SetupFNameW)。設定の保存・読み込みの既定のファイル
    static var setupFileName: String {
        get { UserDefaults.standard.string(forKey: "SetupFName") ?? (AppPaths.setupDirectory as NSString).appendingPathComponent("TERATERM.INI") }
        set { UserDefaults.standard.set(newValue, forKey: "SetupFName") }
    }

    /// キーボード設定ファイル (KeyCnfFNW)
    static var keyCnfFileName: String {
        get { UserDefaults.standard.string(forKey: "KeyCnfFN") ?? (AppPaths.setupDirectory as NSString).appendingPathComponent("KEYBOARD.CNF") }
        set { UserDefaults.standard.set(newValue, forKey: "KeyCnfFN") }
    }
}
