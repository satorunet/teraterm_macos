import AppKit
import TeraCore

/// 配色の候補 (設定画面の「配色かんたん設定」)
struct ColorScheme {
    /// 名前 (設定の TeraMacThemeName に保存する。言語で変わらない)
    var name: String
    var fg: NSColor
    var bg: NSColor
    var cursor: NSColor
    /// ANSI 16 色 (0-7 通常, 8-15 明るい)。nil なら標準
    var ansi16: [NSColor]?
    /// Terminal.app のプロファイルから作ったときのプロファイル名
    var profile: String? = nil

    /// 画面に出す名前 (選んだ言語で)
    var title: String {
        if let p = profile { return Lang.m("SETUP_SCHEME_TERMINAL", "ターミナル: %s", p) }
        if let k = Self.presetKeys[name] { return Lang.m(k, name) }
        return name
    }
    /// おすすめの候補の名前 → 言語ファイルのキー
    private static let presetKeys = [
        "ダーク": "SETUP_SCHEME_DARK", "ホワイト": "SETUP_SCHEME_WHITE", "暖色": "SETUP_SCHEME_WARM",
        "暖色 (明るい)": "SETUP_SCHEME_WARM_LIGHT", "ピンク": "SETUP_SCHEME_PINK", "ピンク (ダーク)": "SETUP_SCHEME_PINK_DARK",
        "Tera Term 標準": "SETUP_SCHEME_TERATERM",
    ]

    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static func palette(_ v: [UInt32]) -> [NSColor] { v.map(hex) }

    /// Terminal.app の標準 ANSI 色
    static let terminalANSI = palette([0x000000, 0x990000, 0x00A600, 0x999900, 0x0000B2, 0xB200B2, 0x00A6B2, 0xBFBFBF,
                                      0x666666, 0xE50000, 0x00D900, 0xE5E500, 0x0000FF, 0xE500E5, 0x00E5E5, 0xE5E5E5])

    /// おすすめの候補
    static let presets: [ColorScheme] = [
        ColorScheme(name: "ダーク", fg: hex(0xD4D4D4), bg: hex(0x1E1F22), cursor: hex(0x4FC1FF),
                    ansi16: palette([0x2E3436, 0xF14C4C, 0x23D18B, 0xE5E510, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xCCCCCC,
                                     0x666666, 0xFF6E6E, 0x5AF78E, 0xF4F99D, 0x6CB6FF, 0xFF92DF, 0x9AEDFE, 0xFFFFFF])),
        ColorScheme(name: "ホワイト", fg: hex(0x1F2328), bg: hex(0xFFFFFF), cursor: hex(0x0969DA),
                    ansi16: palette([0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
                                     0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F])),
        ColorScheme(name: "暖色", fg: hex(0xF2E5C9), bg: hex(0x2A2118), cursor: hex(0xFFB454),
                    ansi16: palette([0x3C3128, 0xE06C4F, 0xA9B665, 0xE9B143, 0x7DAEA3, 0xD3869B, 0x89B482, 0xD4BE98,
                                     0x7C6F64, 0xF28A6A, 0xC4D17E, 0xF6CC6A, 0x9CC4BA, 0xE5A3B4, 0xA6CC9F, 0xFBF1C7])),
        ColorScheme(name: "暖色 (明るい)", fg: hex(0x4A3B2C), bg: hex(0xFBF1E3), cursor: hex(0xD9822B),
                    ansi16: palette([0x4A3B2C, 0xC2452F, 0x6F8B2F, 0xB57614, 0x45707A, 0x945E80, 0x4C7A5D, 0x8C7A66,
                                     0x7C6F64, 0xD65D3A, 0x83A33A, 0xD08A1C, 0x5A8C96, 0xAD7099, 0x5E9471, 0x3C3128])),
        ColorScheme(name: "ピンク", fg: hex(0x5A2A41), bg: hex(0xFFF0F6), cursor: hex(0xFF5FA2),
                    ansi16: palette([0x5A2A41, 0xD6336C, 0x2F9E6E, 0xC27C0E, 0x7048E8, 0xE64980, 0x1C9AAA, 0xB197A6,
                                     0x8C6A7B, 0xF06595, 0x40C080, 0xE09F3E, 0x845EF7, 0xF783AC, 0x3BC9DB, 0x3D1C2C])),
        ColorScheme(name: "ピンク (ダーク)", fg: hex(0xFFD6E8), bg: hex(0x2A1B24), cursor: hex(0xFF79C6),
                    ansi16: palette([0x3A2732, 0xFF6B8B, 0x7EE0A8, 0xFFD27F, 0xA48CFF, 0xFF79C6, 0x8BE9FD, 0xE8C8D8,
                                     0x7A5A6C, 0xFF8FA6, 0x9FF2BF, 0xFFE0A3, 0xBCA8FF, 0xFF9AD5, 0xA9F1FF, 0xFFFFFF])),
        ColorScheme(name: "Tera Term 標準", fg: hex(0xFFFFFF), bg: hex(0x000000), cursor: hex(0xFFFFFF),
                    ansi16: palette([0x000000, 0xC00000, 0x00C000, 0xC0C000, 0x4040C0, 0xC000C0, 0x00C0C0, 0xC0C0C0,
                                     0x404040, 0xFF0000, 0x00FF00, 0xFFFF00, 0x8080FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF])),
        ColorScheme(name: "Solarized Dark", fg: hex(0x839496), bg: hex(0x002B36), cursor: hex(0x93A1A1),
                    ansi16: palette([0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                                     0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])),
        ColorScheme(name: "Solarized Light", fg: hex(0x657B83), bg: hex(0xFDF6E3), cursor: hex(0x586E75),
                    ansi16: palette([0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                                     0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])),
    ]

    /// 標準のターミナル (Terminal.app) のプロファイルの配色。設定ファイルから実際の色を読む
    static func terminalProfiles() -> [ColorScheme] {
        guard let t = UserDefaults(suiteName: "com.apple.Terminal"),
              let all = t.dictionary(forKey: "Window Settings") else { return [] }
        func color(_ p: [String: Any], _ k: String) -> NSColor? {
            guard let d = p[k] as? Data,
                  let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: d) else { return nil }
            // 半透明の背景は不透明にする (Tera Term Mac の窓は透けないため)
            return (c.usingColorSpace(.sRGB) ?? c).withAlphaComponent(1)
        }
        let ansiKeys = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        var out: [ColorScheme] = []
        for (name, v) in all.sorted(by: { $0.key < $1.key }) {
            guard let p = v as? [String: Any] else { continue }
            let bg = color(p, "BackgroundColor") ?? .white
            let fg = color(p, "TextColor") ?? .black
            let cursor = color(p, "CursorColor") ?? hex(0x7F7F7F)
            var ansi = terminalANSI
            for (i, k) in ansiKeys.enumerated() {
                if let c = color(p, "ANSI\(k)Color") { ansi[i] = c }
                if let c = color(p, "ANSIBright\(k)Color") { ansi[i + 8] = c }
            }
            out.append(ColorScheme(name: "ターミナル: \(name)", fg: fg, bg: bg, cursor: cursor, ansi16: ansi, profile: name))
        }
        return out
    }

    /// 候補の見本 (ポップアップに出す小さな絵)
    func swatch(size: NSSize = NSSize(width: 96, height: 20)) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        let r = NSRect(origin: .zero, size: size)
        bg.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        NSColor.gray.withAlphaComponent(0.5).setStroke()
        NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
        ("Aa" as NSString).draw(at: NSPoint(x: 6, y: 2), withAttributes: [
            .font: NSFont(name: "Menlo-Bold", size: 12) ?? NSFont.boldSystemFont(ofSize: 12), .foregroundColor: fg])
        let colors = ansi16 ?? Palette.base16.map { ColorScheme.hex(UInt32($0.0 << 16 | $0.1 << 8 | $0.2)) }
        for i in 0..<6 {
            colors[i + 1].setFill()
            NSBezierPath(ovalIn: NSRect(x: 30 + CGFloat(i) * 10, y: 6, width: 8, height: 8)).fill()
        }
        img.unlockFocus()
        return img
    }
}

/// 設定画面の見本表示 (選んだ配色・フォントでの見え方)
final class SchemePreview: NSView {
    var fg = NSColor.white { didSet { needsDisplay = true } }
    var bg = NSColor.black { didSet { needsDisplay = true } }
    var cursor = NSColor.green { didSet { needsDisplay = true } }
    var ansi: [NSColor] = Palette.colors.prefix(16).map { $0 } { didSet { needsDisplay = true } }
    var font = NSFont(name: "Menlo-Regular", size: 12)! { didSet { needsDisplay = true } }
    /// テーマの背景 (BG Theme)。あれば背景色の代わりに描く
    var background: BGImageSpec? { didSet { bgImage = nil; needsDisplay = true } }
    private var bgImage: NSImage?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        bg.setFill()
        bounds.fill()
        if let b = background {
            if bgImage?.size != bounds.size {
                bgImage = b.image(size: bounds.size, scale: window?.backingScaleFactor ?? 2,
                                  windowFrame: window.map { $0.convertToScreen(convert(bounds, to: nil)) }, screen: window?.screen)
            }
            bgImage?.draw(in: bounds)
        }
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        let lh = ceil(NSLayoutManager().defaultLineHeight(for: font))
        func line(_ y: Int, _ parts: [(String, NSColor)]) {
            var x: CGFloat = 8
            for (t, c) in parts {
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c]
                (t as NSString).draw(at: NSPoint(x: x, y: 6 + CGFloat(y) * lh), withAttributes: a)
                x += (t as NSString).size(withAttributes: a).width
            }
        }
        line(0, [("user@host", ansi[2]), (":", fg), ("~/work", ansi[4]), ("$ ls -l", fg)])
        line(1, [("drwxr-xr-x  ", fg), ("src", ansi[12]), ("  ", fg), ("build.sh", ansi[10]), ("  README.md", fg)])
        line(2, [("ERROR", ansi[1]), (" " + Lang.m("SETUP_SCHEME_SAMPLE_ERROR", "接続できません") + "  ", fg), ("WARN", ansi[3]), (" " + Lang.m("SETUP_SCHEME_SAMPLE_WARN", "再試行") + "  ", fg), ("OK", ansi[2])])
        let y = 6 + 3 * lh
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        ("$ " as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: a)
        let w = ("$ " as NSString).size(withAttributes: a).width
        cursor.setFill()
        NSRect(x: 8 + w, y: y, width: ("M" as NSString).size(withAttributes: a).width, height: lh).fill()
        // ANSI 16 色の並び
        for i in 0..<16 {
            ansi[i].setFill()
            NSRect(x: 8 + CGFloat(i % 8) * 18, y: y + lh + 8 + CGFloat(i / 8) * 12, width: 16, height: 10).fill()
        }
    }
}
