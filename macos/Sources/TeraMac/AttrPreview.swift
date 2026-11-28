import AppKit
import TeraCore

/// 設定 > 表示 の見本: 各項目 (太字・下線・点滅・反転・URL・ANSI カラー) がどの文字に効くかを 1 行ずつ見せる
final class AttrPreview: NSView {
    struct Model {
        var fg = NSColor.white, bg = NSColor.black
        var font = NSFont.monoSystemFont(ofSize: 13, weight: .regular)
        var ansi: [NSColor] = Array(Palette.colors.prefix(16))
        var ansiOn = true
        /// 属性の色 (nil = 属性の色を使わない)
        var boldColor: ColorPair?, underlineColor: ColorPair?, blinkColor: ColorPair?, reverseColor: ColorPair?, urlColor: ColorPair?
        var boldFont = true, underlineLine = true, urlUnderline = true
        var cursor = NSColor.green
        /// 背景画像 (テーマの背景・Mac 版の背景画像)
        var background: BGImageSpec?
    }
    var model = Model() { didSet { needsDisplay = true } }
    private var bgCache: (spec: String, size: NSSize, image: NSImage?)?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let m = model
        m.bg.setFill(); bounds.fill()
        if let b = m.background {
            let key = String(describing: b)
            if bgCache?.spec != key || bgCache?.size != bounds.size {
                bgCache = (key, bounds.size, b.image(size: bounds.size, scale: window?.backingScaleFactor ?? 2,
                                                     windowFrame: nil, screen: window?.screen))
            }
            bgCache?.image?.draw(in: bounds)
        }
        let lh = ceil(NSLayoutManager().defaultLineHeight(for: m.font)) + 3
        let labelFont = NSFont.systemFont(ofSize: 11)
        let labelColor = m.fg.withAlphaComponent(0.45)
        let labelW: CGFloat = 86
        var y: CGFloat = 8

        func row(_ label: String, _ draw: (CGFloat) -> Void) {
            (label as NSString).draw(at: NSPoint(x: 10, y: y + 2), withAttributes: [.font: labelFont, .foregroundColor: labelColor])
            draw(y)
            y += lh
        }
        func text(_ s: String, x: CGFloat, y: CGFloat, fg: NSColor, bg: NSColor? = nil, bold: Bool = false, underline: Bool = false) -> CGFloat {
            let f = bold ? (NSFontManager.shared.convert(m.font, toHaveTrait: .boldFontMask)) : m.font
            var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: fg]
            if underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue; a[.underlineColor] = fg }
            let sz = (s as NSString).size(withAttributes: a)
            if let bg = bg { bg.setFill(); NSRect(x: x, y: y, width: sz.width, height: lh - 3).fill() }
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: a)
            return x + sz.width
        }
        let x0 = 10 + labelW
        row(Lang.m("SETUP_ATTR_BOLD", "太字")) { y in
            // 太字の属性色は文字の色だけ (背景は端末と同じ。テーマや背景画像の上で黒い帯にならないように)
            _ = text("Bold 太字の文字", x: x0, y: y, fg: m.boldColor?.fg ?? m.fg, bold: m.boldFont)
        }
        row(Lang.m("SETUP_ATTR_UNDERLINE", "下線")) { y in
            _ = text("Underline 下線の文字", x: x0, y: y, fg: m.underlineColor?.fg ?? m.fg, underline: m.underlineLine)
        }
        row(Lang.m("SETUP_ATTR_BLINK", "点滅")) { y in
            _ = text("Blink 点滅の文字", x: x0, y: y, fg: m.blinkColor?.fg ?? m.fg)
        }
        row(Lang.m("SETUP_ATTR_REVERSE", "反転")) { y in
            let pair = m.reverseColor ?? ColorPair(fg: m.bg, bg: m.fg)
            _ = text("Reverse 反転の文字", x: x0, y: y, fg: pair.fg, bg: pair.bg)
        }
        row("URL") { y in
            _ = text("https://teraterm-mac.github.io/", x: x0, y: y, fg: m.urlColor?.fg ?? m.fg, underline: m.urlUnderline)
        }
        row(Lang.m("SETUP_ATTR_ANSI", "ANSI カラー")) { y in
            var x = x0
            let words = ["red", "green", "yellow", "blue", "magenta", "cyan"]
            for (i, w) in words.enumerated() {
                x = text(w, x: x, y: y, fg: m.ansiOn ? m.ansi[i + 1] : m.fg)
                x = text(" ", x: x, y: y, fg: m.fg)
            }
        }
    }
}
