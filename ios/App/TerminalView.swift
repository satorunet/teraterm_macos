import UIKit
import TeraCore

/// 端末の画面 (TeraCore の Terminal を描く) とキー入力。
/// 描き方・色の決め方は Mac 版 (TerminalView.swift の draw / drawColors / ansiColor) にならう
final class TerminalView: UIView {
    let term: Terminal
    /// 相手に送るバイト列
    var onSend: (([UInt8]) -> Void)?
    /// 桁数・行数が変わった
    var onResize: ((Int, Int) -> Void)?

    // MARK: 文字の大きさ

    var fontSize: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 14 : 11 {
        didSet { fontSize = max(7, min(30, fontSize)); updateFonts(); setNeedsLayout(); setNeedsDisplay() }
    }
    private var fonts: [UIFont] = []
    private(set) var cellW: CGFloat = 7
    private(set) var cellH: CGFloat = 14
    private var ascent: CGFloat = 11

    /// 何行さかのぼって見ているか (0 = いちばん下)
    var scrollOffset = 0 { didSet { scrollOffset = max(0, min(term.scrollback.count, scrollOffset)); setNeedsDisplay() } }

    let defaultFG = UIColor(white: 0.9, alpha: 1)
    let defaultBG = UIColor.black

    init(term: Terminal) {
        self.term = term
        super.init(frame: .zero)
        backgroundColor = defaultBG
        isOpaque = true
        contentMode = .redraw
        updateFonts()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateFonts() {
        let base = UIFont(name: "Menlo-Regular", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold = UIFont(name: "Menlo-Bold", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let it = UIFont(name: "Menlo-Italic", size: fontSize) ?? base
        let bi = UIFont(name: "Menlo-BoldItalic", size: fontSize) ?? bold
        fonts = [base, bold, it, bi]
        cellW = ceil(("M" as NSString).size(withAttributes: [.font: base]).width * 1000) / 1000
        cellH = ceil(base.lineHeight)
        ascent = base.ascender
    }

    // MARK: 大きさ

    override func layoutSubviews() {
        super.layoutSubviews()
        let cols = max(20, Int(bounds.width / cellW))
        let rows = max(5, Int(bounds.height / cellH))
        if cols != term.cols || rows != term.rows {
            onResize?(cols, rows)
            setNeedsDisplay()
        }
    }

    /// 新しいデータが来たら描き直す (見ている場所はいちばん下へ)
    func dataArrived() {
        scrollOffset = 0
        setNeedsDisplay()
    }

    // MARK: 描く

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let bg0 = term.reverseScreen ? defaultFG : defaultBG
        ctx.setFillColor(bg0.cgColor)
        ctx.fill(bounds)
        let first = term.totalLines - term.rows - scrollOffset
        for r in 0..<term.rows {
            let idx = first + r
            guard idx >= 0, idx < term.totalLines else { continue }
            let line = term.line(at: idx)
            let y = CGFloat(r) * cellH
            for (c, cell) in line.cells.enumerated() where cell.width != 0 {
                let x = CGFloat(c) * cellW
                let w = CGFloat(max(1, Int(cell.width))) * cellW
                var (fg, bg) = colors(cell.attr)
                if cell.attr.invisible { fg = bg }
                if bg != bg0 {
                    ctx.setFillColor(bg.cgColor)
                    ctx.fill(CGRect(x: x, y: y, width: w, height: cellH))
                }
                let ch = cell.ch
                if ch == " " && !cell.attr.underline && !cell.attr.strike { continue }
                let a = cell.attr
                let font = fonts[(a.bold ? 1 : 0) + (a.italic ? 2 : 0)]
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: a.dim ? fg.withAlphaComponent(0.6) : fg]
                if a.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if a.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                (String(ch) as NSString).draw(at: CGPoint(x: x, y: y + (cellH - font.lineHeight) / 2), withAttributes: attrs)
            }
        }
        // カーソル
        if term.cursorVisible, scrollOffset == 0, term.cy < term.rows {
            let x = CGFloat(term.cx) * cellW, y = CGFloat(term.cy) * cellH
            ctx.setFillColor((isFirstResponder ? UIColor.systemGreen : UIColor.gray).withAlphaComponent(0.7).cgColor)
            switch term.cursorStyle {
            case .block: ctx.fill(CGRect(x: x, y: y, width: cellW, height: cellH))
            case .underline: ctx.fill(CGRect(x: x, y: y + cellH - 2, width: cellW, height: 2))
            case .bar: ctx.fill(CGRect(x: x, y: y, width: 2, height: cellH))
            }
        }
        // 変換中の文字 (カーソルの位置に、背景を付けて下線で)
        if !markedText.isEmpty {
            let c = cursorCellRect
            let attrs: [NSAttributedString.Key: Any] = [.font: fonts[0], .foregroundColor: UIColor.white,
                                                        .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: UIColor.systemYellow]
            let w = markedTextWidth
            let x = min(c.minX, max(0, bounds.width - w))
            ctx.setFillColor(UIColor(white: 0.2, alpha: 1).cgColor)
            ctx.fill(CGRect(x: x, y: c.minY, width: w, height: c.height))
            (markedText as NSString).draw(at: CGPoint(x: x, y: c.minY + (cellH - fonts[0].lineHeight) / 2), withAttributes: attrs)
        }
        // さかのぼって見ているときは目印
        if scrollOffset > 0 {
            let s = "↑ \(scrollOffset)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.black]
            let sz = s.size(withAttributes: attrs)
            let r = CGRect(x: bounds.width - sz.width - 14, y: 4, width: sz.width + 10, height: sz.height + 4)
            ctx.setFillColor(UIColor.systemYellow.cgColor)
            UIBezierPath(roundedRect: r, cornerRadius: 4).fill()
            s.draw(at: CGPoint(x: r.minX + 5, y: r.minY + 2), withAttributes: attrs)
        }
    }

    /// 文字色と背景色 (反転・ANSI カラー・256 色・24 ビット色)
    private func colors(_ a: CellAttr) -> (UIColor, UIColor) {
        var fg = ansiColor(a.fg, bright: a.bold) ?? defaultFG
        var bg = ansiColor(a.bg, bright: false) ?? defaultBG
        if a.reverse != term.reverseScreen { swap(&fg, &bg) }
        return (fg, bg)
    }

    private func ansiColor(_ c: TColor, bright: Bool) -> UIColor? {
        switch c {
        case .def: return nil
        case let .rgb(r, g, b): return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .idx(var n):
            if bright, n < 8 { n += 8 }
            if let o = term.colorOverrides[.ansi(Int(n))] { return UIColor(red: CGFloat(o.r) / 255, green: CGFloat(o.g) / 255, blue: CGFloat(o.b) / 255, alpha: 1) }
            return Palette.colors[Int(n)]
        }
    }

    // MARK: 入力 (ソフトウェアキーボード)

    override var canBecomeFirstResponder: Bool { true }
    /// キーボードの上に出すキーの列
    var accessory: UIView? { didSet { reloadInputViews() } }
    override var inputAccessoryView: UIView? { accessory }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    /// キーの列の Ctrl / Alt (次の 1 文字だけ効く)
    var ctrlLatched = false { didSet { onModifierChange?() } }
    var altLatched = false { didSet { onModifierChange?() } }
    var onModifierChange: (() -> Void)?

    // MARK: 日本語入力 (変換の途中の文字。TerminalTextInput.swift)
    var markedText = ""
    var markedSelection = NSRange(location: 0, length: 0)
    weak var inputDelegate: UITextInputDelegate?

    /// カーソルの升目 (変換の候補をこの近くに出す)
    var cursorCellRect: CGRect {
        CGRect(x: CGFloat(term.cx) * cellW, y: CGFloat(min(term.cy, term.rows - 1)) * cellH, width: cellW, height: cellH)
    }
    var markedTextWidth: CGFloat {
        (markedText as NSString).size(withAttributes: [.font: fonts.first ?? UIFont.systemFont(ofSize: fontSize)]).width
    }

    func insertText(_ text: String) {
        // 変換を確定したときもここに来る
        if !markedText.isEmpty { markedText = ""; setNeedsDisplay() }
        sendTyped(text)
    }

    /// 打った文字を送る (Ctrl・Alt の 1 回だけの押し下げも見る)
    func sendTyped(_ text: String) {
        var out: [UInt8] = []
        for ch in text {
            if ch == "\n" { out.append(13); continue }
            if ctrlLatched, let s = ch.unicodeScalars.first, let c = Self.controlCode(s) {
                if altLatched { out.append(27) }
                out.append(c)
                ctrlLatched = false; altLatched = false
                continue
            }
            if altLatched { out.append(27); altLatched = false }
            out += term.sendEncoding.encode(String(ch))
        }
        send(out)
    }

    func deleteBackward() {
        // 変換中は UIKit が変換中の文字を直すので、ここには来ない
        send([0x7F])
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        onSend?(bytes)
    }

    /// Ctrl+文字 → 制御コード (Mac 版の controlCode と同じ)
    static func controlCode(_ s: Unicode.Scalar) -> UInt8? {
        switch s {
        case "a"..."z": return UInt8(s.value - 96)
        case "A"..."Z": return UInt8(s.value - 64)
        case "@", " ", "2": return 0
        case "[", "3": return 27
        case "\\", "4": return 28
        case "]", "5": return 29
        case "^", "6": return 30
        case "_", "7", "-": return 31
        case "?", "8": return 127
        default: return nil
        }
    }

    /// 矢印などの特別なキー (アプリケーションカーソルモードも見る)
    enum SpecialKey { case up, down, right, left, home, end, pageUp, pageDown, esc, tab, backTab, delete, insert, f(Int) }
    func sendSpecial(_ k: SpecialKey, shift: Bool = false, alt: Bool = false, ctrl: Bool = false) {
        let mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        func cursor(_ c: String) -> String {
            if mod > 1 { return "\u{1B}[1;\(mod)" + c }
            return (term.appCursor ? "\u{1B}O" : "\u{1B}[") + c
        }
        func tilde(_ n: Int) -> String { mod > 1 ? "\u{1B}[\(n);\(mod)~" : "\u{1B}[\(n)~" }
        let s: String
        switch k {
        case .up: s = cursor("A")
        case .down: s = cursor("B")
        case .right: s = cursor("C")
        case .left: s = cursor("D")
        case .home: s = cursor("H")
        case .end: s = cursor("F")
        case .pageUp: s = tilde(5)
        case .pageDown: s = tilde(6)
        case .insert: s = tilde(2)
        case .delete: s = tilde(3)
        case .esc: s = "\u{1B}"
        case .tab: s = "\t"
        case .backTab: s = "\u{1B}[Z"
        case .f(let n):
            switch n {
            case 1...4: s = "\u{1B}O" + ["P", "Q", "R", "S"][n - 1]
            default:
                let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
                s = tilde(codes[n] ?? 15)
            }
        }
        send(Array(s.utf8))
    }

    // MARK: 外付けキーボード (iPad など)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            guard let key = p.key else { continue }
            let m = key.modifierFlags
            let shift = m.contains(.shift), alt = m.contains(.alternate), ctrl = m.contains(.control)
            var special: SpecialKey?
            switch key.keyCode {
            case .keyboardUpArrow: special = .up
            case .keyboardDownArrow: special = .down
            case .keyboardRightArrow: special = .right
            case .keyboardLeftArrow: special = .left
            case .keyboardHome: special = .home
            case .keyboardEnd: special = .end
            case .keyboardPageUp: special = .pageUp
            case .keyboardPageDown: special = .pageDown
            case .keyboardEscape: special = .esc
            case .keyboardDeleteForward: special = .delete
            case .keyboardTab: special = shift ? .backTab : nil
            case .keyboardF1: special = .f(1)
            case .keyboardF2: special = .f(2)
            case .keyboardF3: special = .f(3)
            case .keyboardF4: special = .f(4)
            case .keyboardF5: special = .f(5)
            case .keyboardF6: special = .f(6)
            case .keyboardF7: special = .f(7)
            case .keyboardF8: special = .f(8)
            case .keyboardF9: special = .f(9)
            case .keyboardF10: special = .f(10)
            case .keyboardF11: special = .f(11)
            case .keyboardF12: special = .f(12)
            default: break
            }
            if let k = special {
                sendSpecial(k, shift: shift, alt: alt, ctrl: ctrl)
                handled = true
            } else if ctrl, !m.contains(.command), let s = key.charactersIgnoringModifiers.unicodeScalars.first, let c = Self.controlCode(s) {
                send(alt ? [27, c] : [c])
                handled = true
            } else if alt, !m.contains(.command), let s = key.charactersIgnoringModifiers.first {
                // Option を Meta として (ESC + 文字)
                send([27] + term.sendEncoding.encode(String(s)))
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    // MARK: 指の操作

    @objc private func tapped() {
        if !isFirstResponder { becomeFirstResponder() }
        setNeedsDisplay()
    }

    private var panStart = 0
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: panStart = scrollOffset
        case .changed: scrollOffset = panStart + Int(g.translation(in: self).y / cellH)
        default: break
        }
    }

    private var pinchStart: CGFloat = 11
    var onFontSizeChange: ((CGFloat) -> Void)?
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: pinchStart = fontSize
        case .changed: fontSize = (pinchStart * g.scale).rounded()
        case .ended: onFontSizeChange?(fontSize)
        default: break
        }
    }

    /// 長押しのメニュー (画面をコピー・貼り付け)。iOS 16 からは新しい仕組み (UIEditMenuInteraction)
    private var editMenu: AnyObject?
    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        becomeFirstResponder()
        let p = g.location(in: self)
        #if compiler(>=5.7)   // iOS 16 の SDK (Xcode 14) 以降で組み立てるとき
        if #available(iOS 16.0, *) {
            let m: UIEditMenuInteraction
            if let e = editMenu as? UIEditMenuInteraction { m = e } else {
                m = UIEditMenuInteraction(delegate: self)
                addInteraction(m)
                editMenu = m
            }
            m.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: p))
            return
        }
        #endif
        let m = UIMenuController.shared
        m.menuItems = [UIMenuItem(title: "画面をコピー", action: #selector(copyScreen(_:)))]
        m.showMenu(from: self, rect: CGRect(origin: p, size: CGSize(width: 1, height: 1)))
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(copyScreen(_:)) || action == #selector(paste(_:)) && UIPasteboard.general.hasStrings
    }
    @objc func copyScreen(_ sender: Any?) { UIPasteboard.general.string = term.screenText }
    override func paste(_ sender: Any?) {
        guard var s = UIPasteboard.general.string else { return }
        s = s.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if term.bracketedPaste { s = "\u{1B}[200~" + s + "\u{1B}[201~" }
        send(term.sendEncoding.encode(s))
    }
}

/// 256 色 (Mac 版 Settings.swift の Palette と同じ色)
enum Palette {
    static let colors: [UIColor] = {
        let base16: [(Int, Int, Int)] = [(0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
                                         (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)]
        func c(_ r: Int, _ g: Int, _ b: Int) -> UIColor { UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
        var out = base16.map { c($0.0, $0.1, $0.2) }
        let steps = [0, 95, 135, 175, 215, 255]
        for r in steps { for g in steps { for b in steps { out.append(c(r, g, b)) } } }
        for i in 0..<24 { let v = 8 + i * 10; out.append(c(v, v, v)) }
        return out
    }()
}

#if compiler(>=5.7)
@available(iOS 16.0, *)
extension TerminalView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var items: [UIMenuElement] = [UIAction(title: "画面をコピー", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyScreen(nil) }]
        if UIPasteboard.general.hasStrings {
            items.append(UIAction(title: "貼り付け", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste(nil) })
        }
        return UIMenu(children: items)
    }
}
#endif
