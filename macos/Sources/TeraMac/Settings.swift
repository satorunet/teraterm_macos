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
    var confirmMultilinePaste = true
    var scrollback = 10000
    var cursorBlink = true
    var charDelayMs = 0
    var lineDelayMs = 0
    var logTimestamp = false
    /// block / vertical / horizontal (Tera Term の CursorShape)
    var cursorShape = "block"
    /// ANSI 16 色を差し替えるとき (Tera Term の ANSIColor)。nil なら標準
    var ansi16: [NSColor]?

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

    static func load() -> TermSettings {
        var s = TermSettings()
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
        if d.object(forKey: "confirmMultilinePaste") != nil { s.confirmMultilinePaste = d.bool(forKey: "confirmMultilinePaste") }
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
        d.set(confirmMultilinePaste, forKey: "confirmMultilinePaste")
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
