import AppKit
import TeraCore

/// 端末画面を描き、キー入力・マウス・日本語入力を受ける
final class TerminalView: NSView, NSTextInputClient {
    let term: Terminal
    var settings: TermSettings { didSet { applyFont(); needsDisplay = true } }

    /// 端末から相手に送る文字列 (エンコード前)
    var onSendText: ((String) -> Void)?
    /// 端末から相手に送るバイト列 (キーのエスケープシーケンスなど)
    var onSendBytes: (([UInt8]) -> Void)?
    /// マクロの enablekeyb 0 で false (キー入力を送らない)
    var keyboardEnabled = true
    var onResize: ((Int, Int) -> Void)?

    private(set) var cellW: CGFloat = 8
    private(set) var cellH: CGFloat = 16
    private var baseline: CGFloat = 12
    private var font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
    private var italicFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    let pad: CGFloat = 4

    /// 何行ぶん過去にさかのぼって表示しているか
    private(set) var scrollOffset = 0
    private var marked: NSAttributedString?
    private var markedSel = NSRange(location: 0, length: 0)
    private var blinkOn = true
    private var blinkTimer: Timer?
    private var focused = false

    // 選択範囲 (行は「通算行番号」で持つので、スクロールしてもずれない)
    private struct Pos: Comparable {
        var line: Int, col: Int
        static func < (a: Pos, b: Pos) -> Bool { a.line != b.line ? a.line < b.line : a.col < b.col }
    }
    private var selAnchor: Pos?
    private var selHead: Pos?
    private var selMode = 1  // 1 = 文字, 2 = 単語, 3 = 行
    private var mouseReporting = false

    init(term: Terminal, settings: TermSettings) {
        self.term = term
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        applyFont()
        startBlink()
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - ファイルのドロップ (Tera Term のドラッグ&ドロップ)

    /// ドロップされたファイル (パス, Control/Option を押していたか)
    var onFilesDropped: (([String], Bool) -> Void)?

    private func droppedPaths(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { $0.path }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFilesDropped != nil && !droppedPaths(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = droppedPaths(sender)
        guard !paths.isEmpty, let f = onFilesDropped else { return false }
        let mods = NSEvent.modifierFlags
        let force = mods.contains(.control) || mods.contains(.option)
        // ドロップの処理 (ダイアログ) はドラッグが終わってから
        DispatchQueue.main.async { f(paths, force) }
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func becomeFirstResponder() -> Bool { focused = true; blinkOn = true; needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { focused = false; needsDisplay = true; return true }

    private func startBlink() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self = self, self.settings.cursorBlink, self.focused else { return }
            self.blinkOn.toggle()
            self.setNeedsDisplay(self.cursorRect().insetBy(dx: -2, dy: -2))
        }
    }

    deinit { blinkTimer?.invalidate() }

    // MARK: - フォントと大きさ

    private func applyFont() {
        font = settings.font
        let fm = NSFontManager.shared
        boldFont = fm.convert(font, toHaveTrait: .boldFontMask)
        italicFont = fm.convert(font, toHaveTrait: .italicFontMask)
        let adv = ("M" as NSString).size(withAttributes: [.font: font]).width
        cellW = max(1, round(adv * 2) / 2)
        let lm = NSLayoutManager()
        cellH = ceil(lm.defaultLineHeight(for: font))
        baseline = ceil(font.ascender)
        term.ambiguousWide = settings.ambiguousWide
        term.defaultCursorStyle = settings.cursorShape == "vertical" ? .bar : (settings.cursorShape == "horizontal" ? .underline : .block)
        term.scrollbackLimit = settings.scrollback
    }

    /// cols × rows がちょうど入る中身の大きさ
    func contentSize(cols: Int, rows: Int) -> NSSize {
        NSSize(width: CGFloat(cols) * cellW + pad * 2, height: CGFloat(rows) * cellH + pad * 2)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let c = max(10, Int((newSize.width - pad * 2) / cellW))
        let r = max(2, Int((newSize.height - pad * 2) / cellH))
        if c != term.cols || r != term.rows {
            term.resize(cols: c, rows: r)
            scrollOffset = min(scrollOffset, term.scrollback.count)
            onResize?(c, r)
            needsDisplay = true
        }
    }

    // MARK: - 表示更新

    func dataArrived() {
        if scrollOffset != 0 {
            // 新しい出力が来たら一番下に戻る (Tera Term と同じ)
            scrollOffset = 0
        }
        blinkOn = true
        needsDisplay = true
    }

    private var firstLineIndex: Int { term.totalLines - term.rows - scrollOffset }
    private var lineBase: Int { term.scrolledOutTotal - term.scrollback.count }

    private func cursorRect() -> NSRect {
        NSRect(x: pad + CGFloat(term.cx) * cellW, y: pad + CGFloat(term.cy + scrollOffset) * cellH, width: cellW * 2, height: cellH)
    }

    // MARK: - 描画

    private func color(_ c: TColor, isFG: Bool, bold: Bool) -> NSColor {
        switch c {
        case .def: return isFG ? settings.fg : settings.bg
        case .idx(let i):
            var n = Int(i)
            if isFG && bold && n < 8 { n += 8 }
            if n < 16, let a = settings.ansi16 { return a[n] }
            return Palette.colors[n]
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    private func selectionRange() -> (Pos, Pos)? {
        guard let a = selAnchor, let h = selHead, a != h else { return nil }
        var s = min(a, h), e = max(a, h)
        if selMode == 3 { s.col = 0; e.col = term.cols }
        return (s, e)
    }

    private func isSelected(_ global: Int, _ col: Int, _ sel: (Pos, Pos)?) -> Bool {
        guard let (s, e) = sel else { return false }
        let p = Pos(line: global, col: col)
        return p >= s && p < e
    }

    override func draw(_ dirtyRect: NSRect) {
        // macOS の「フォントスムージング」は暗い背景の明るい文字を太く見せるので切る (Terminal.app の見た目に合わせる)
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        let screenRev = term.reverseScreen
        (screenRev ? settings.fg : settings.bg).setFill()
        dirtyRect.fill()
        let sel = selectionRange()
        let first = firstLineIndex
        let base = lineBase
        let r0 = max(0, Int((dirtyRect.minY - pad) / cellH))
        let r1 = min(term.rows - 1, Int((dirtyRect.maxY - pad) / cellH))
        guard r0 <= r1 else { return }

        for r in r0...r1 {
            let li = first + r
            guard li >= 0 && li < term.totalLines else { continue }
            let line = term.line(at: li)
            let global = base + li
            let y = pad + CGFloat(r) * cellH
            var x = 0
            // 同じ見た目の半角 ASCII はまとめて描く
            var run = ""
            var runX = 0
            var runAttrs: [NSAttributedString.Key: Any] = [:]
            func flush() {
                if !run.isEmpty {
                    (run as NSString).draw(at: NSPoint(x: pad + CGFloat(runX) * cellW, y: y), withAttributes: runAttrs)
                    run = ""
                }
            }
            while x < line.cells.count {
                let cell = line.cells[x]
                if cell.width == 0 { x += 1; continue }
                let w = Int(cell.width)
                let a = cell.attr
                var fg = color(a.fg, isFG: true, bold: a.bold)
                var bg = color(a.bg, isFG: false, bold: false)
                var rev = a.reverse
                if screenRev { rev.toggle() }
                if isSelected(global, x, sel) { rev.toggle() }
                if rev { swap(&fg, &bg) }
                if a.dim { fg = fg.withAlphaComponent(0.6) }
                if a.invisible { fg = bg }
                let defaultBG = screenRev ? settings.fg : settings.bg
                if bg != defaultBG {
                    bg.setFill()
                    NSRect(x: pad + CGFloat(x) * cellW, y: y, width: CGFloat(w) * cellW, height: cellH).fill()
                }
                if cell.ch != " " {
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: a.bold ? boldFont : (a.italic ? italicFont : font),
                        .foregroundColor: fg,
                    ]
                    if a.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if a.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    let isAscii = cell.ch.unicodeScalars.count == 1 && cell.ch.unicodeScalars.first!.value < 0x7F
                    if isAscii && w == 1 {
                        if run.isEmpty || !NSDictionary(dictionary: runAttrs).isEqual(to: attrs) || runX + run.count != x {
                            flush()
                            runX = x; runAttrs = attrs
                        }
                        run.append(cell.ch)
                    } else {
                        flush()
                        drawSingle(cell.ch, x: x, y: y, width: w, attrs: attrs)
                    }
                } else {
                    flush()
                    if a.underline || a.strike {
                        let s: NSString = w == 2 ? "  " : " "
                        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
                        if a.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                        s.draw(at: NSPoint(x: pad + CGFloat(x) * cellW, y: y), withAttributes: attrs)
                    }
                }
                x += w
            }
            flush()
        }
        drawCursor()
    }

    /// 罫線は線で描く (フォントによってすき間が出るため)。それ以外は 1 文字ずつ中央に
    private func drawSingle(_ ch: Character, x: Int, y: CGFloat, width: Int, attrs: [NSAttributedString.Key: Any]) {
        let rect = NSRect(x: pad + CGFloat(x) * cellW, y: y, width: CGFloat(width) * cellW, height: cellH)
        if let u = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, drawBoxChar(u.value, rect, attrs[.foregroundColor] as! NSColor) {
            return
        }
        let s = String(ch) as NSString
        let size = s.size(withAttributes: attrs)
        var dx: CGFloat = 0
        if size.width < rect.width { dx = (rect.width - size.width) / 2 }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: -1, dy: 0)).addClip()
        if size.width > rect.width + 1 {
            // 幅が広すぎる文字は横に縮める
            let t = NSAffineTransform()
            t.translateX(by: rect.minX, yBy: rect.minY)
            t.scaleX(by: rect.width / size.width, yBy: 1)
            t.concat()
            s.draw(at: .zero, withAttributes: attrs)
        } else {
            s.draw(at: NSPoint(x: rect.minX + dx, y: rect.minY), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBoxChar(_ v: UInt32, _ r: NSRect, _ color: NSColor) -> Bool {
        // ─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ と太線・二重線の一部
        let light: [UInt32: (Bool, Bool, Bool, Bool)] = [   // 上 下 左 右
            0x2500: (false, false, true, true), 0x2502: (true, true, false, false),
            0x250C: (false, true, false, true), 0x2510: (false, true, true, false),
            0x2514: (true, false, false, true), 0x2518: (true, false, true, false),
            0x251C: (true, true, false, true), 0x2524: (true, true, true, false),
            0x252C: (false, true, true, true), 0x2534: (true, false, true, true),
            0x253C: (true, true, true, true),
            0x2501: (false, false, true, true), 0x2503: (true, true, false, false),
            0x250F: (false, true, false, true), 0x2513: (false, true, true, false),
            0x2517: (true, false, false, true), 0x251B: (true, false, true, false),
            0x2523: (true, true, false, true), 0x252B: (true, true, true, false),
            0x2533: (false, true, true, true), 0x253B: (true, false, true, true),
            0x254B: (true, true, true, true),
            0x256D: (false, true, false, true), 0x256E: (false, true, true, false),
            0x2570: (true, false, false, true), 0x256F: (true, false, true, false),
        ]
        if (0x2588...0x2588).contains(v) { color.setFill(); r.fill(); return true }
        if v == 0x2580 { color.setFill(); NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2).fill(); return true }
        if v == 0x2584 { color.setFill(); NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2).fill(); return true }
        guard let d = light[v] else { return false }
        let heavy = (0x2501...0x254B).contains(v) && ![0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C].contains(v)
        let lw: CGFloat = heavy ? max(2, round(cellW / 4)) : max(1, round(cellW / 8))
        // 1 セル幅の罫線 (全角扱いのときは 2 セル)
        let cx = floor(r.midX) + (lw.truncatingRemainder(dividingBy: 2) == 1 ? 0.5 : 0)
        let cy = floor(r.midY) + (lw.truncatingRemainder(dividingBy: 2) == 1 ? 0.5 : 0)
        let p = NSBezierPath()
        p.lineWidth = lw
        p.lineCapStyle = .square
        if d.0 { p.move(to: NSPoint(x: cx, y: r.minY)); p.line(to: NSPoint(x: cx, y: cy)) }
        if d.1 { p.move(to: NSPoint(x: cx, y: cy)); p.line(to: NSPoint(x: cx, y: r.maxY)) }
        if d.2 { p.move(to: NSPoint(x: r.minX, y: cy)); p.line(to: NSPoint(x: cx, y: cy)) }
        if d.3 { p.move(to: NSPoint(x: cx, y: cy)); p.line(to: NSPoint(x: r.maxX, y: cy)) }
        color.setStroke()
        p.stroke()
        return true
    }

    private func drawCursor() {
        let cy = term.cy + scrollOffset
        guard cy < term.rows else { return }
        let x = pad + CGFloat(term.cx) * cellW
        let y = pad + CGFloat(cy) * cellH
        // 日本語入力の変換中の文字
        if let m = marked, m.length > 0 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: settings.fg, .backgroundColor: settings.bg,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            let s = NSAttributedString(string: m.string, attributes: attrs)
            let size = s.size()
            settings.bg.setFill()
            NSRect(x: x, y: y, width: size.width, height: cellH).fill()
            s.draw(at: NSPoint(x: x, y: y))
            settings.cursorColor.setFill()
            let selX = (NSAttributedString(string: (m.string as NSString).substring(to: min(markedSel.location, m.length)),
                                           attributes: [.font: font])).size().width
            NSRect(x: x + selX, y: y, width: 2, height: cellH).fill()
            return
        }
        guard term.cursorVisible else { return }
        var w = cellW
        if term.cy < term.rows, term.cx < term.cols, term.lines[term.cy].cells[term.cx].width == 2 { w = cellW * 2 }
        let rect = NSRect(x: x, y: y, width: w, height: cellH)
        settings.cursorColor.set()
        if !focused {
            let p = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
            return
        }
        guard blinkOn || !settings.cursorBlink else { return }
        switch term.cursorStyle {
        case .block:
            rect.fill()
            // カーソルの下の文字を背景色で描き直す
            let cell = term.lines[term.cy].cells[term.cx]
            if cell.ch != " " && cell.width != 0 {
                let attrs: [NSAttributedString.Key: Any] = [.font: cell.attr.bold ? boldFont : font, .foregroundColor: settings.bg]
                drawSingle(cell.ch, x: term.cx, y: y, width: Int(cell.width), attrs: attrs)
            }
        case .underline:
            NSRect(x: x, y: y + cellH - 2, width: w, height: 2).fill()
        case .bar:
            NSRect(x: x, y: y, width: 2, height: cellH).fill()
        }
    }

    // MARK: - キー入力

    override func keyDown(with event: NSEvent) {
        if !keyboardEnabled { NSSound.beep(); return }
        NSCursor.setHiddenUntilMouseMoves(true)
        if hasMarkedText() {
            inputContext?.handleEvent(event)
            return
        }
        if let seq = specialKey(event) {
            clearSelection()
            sendKey(seq)
            return
        }
        let mods = event.modifierFlags
        if mods.contains(.control), let raw = event.charactersIgnoringModifiers, let c = raw.unicodeScalars.first {
            if let code = controlCode(c) { sendKey([code]); return }
        }
        if mods.contains(.option) && settings.optionAsMeta,
           let s = event.characters(byApplyingModifiers: mods.intersection(.shift)), !s.isEmpty {
            onSendBytes?([0x1B])
            onSendText?(s)
            return
        }
        inputContext?.handleEvent(event)
    }

    private func sendKey(_ b: [UInt8]) {
        scrollToBottom()
        onSendBytes?(b)
    }

    private func controlCode(_ c: Unicode.Scalar) -> UInt8? {
        switch c {
        case "a"..."z": return UInt8(c.value - 0x60)
        case "A"..."Z": return UInt8(c.value - 0x40)
        case "@", " ", "2": return 0
        case "[", "3": return 27
        case "\\", "4": return 28
        case "]", "5": return 29
        case "^", "6": return 30
        case "_", "-", "7": return 31
        case "?", "8": return 127
        default: return nil
        }
    }

    private func specialKey(_ e: NSEvent) -> [UInt8]? {
        let m = e.modifierFlags
        var mod = 1
        if m.contains(.shift) { mod += 1 }
        if m.contains(.option) { mod += 2 }
        if m.contains(.control) { mod += 4 }
        func csi(_ s: String) -> [UInt8] { Array("\u{1B}[\(s)".utf8) }
        func cursorKey(_ c: String) -> [UInt8] {
            if mod > 1 { return csi("1;\(mod)\(c)") }
            return Array((term.appCursor ? "\u{1B}O" : "\u{1B}[").utf8) + Array(c.utf8)
        }
        func tilde(_ n: Int) -> [UInt8] { mod > 1 ? csi("\(n);\(mod)~") : csi("\(n)~") }
        func ss3(_ c: String) -> [UInt8] { mod > 1 ? csi("1;\(mod)\(c)") : Array("\u{1B}O\(c)".utf8) }
        switch e.keyCode {
        case 36, 76: return settings.sendNewlineBytes
        case 51:
            if m.contains(.option) && settings.optionAsMeta { return [0x1B, settings.bsSendsDel ? 0x7F : 0x08] }
            return [settings.bsSendsDel ? 0x7F : 0x08]
        case 117: return tilde(3)
        case 48: return m.contains(.shift) ? csi("Z") : [0x09]
        case 53: return [0x1B]
        case 123: return cursorKey("D")
        case 124: return cursorKey("C")
        case 125: return cursorKey("B")
        case 126: return cursorKey("A")
        case 115: return cursorKey("H")
        case 119: return cursorKey("F")
        case 116:
            if m.contains(.shift) { scrollBy(term.rows - 1); return [] }
            return tilde(5)
        case 121:
            if m.contains(.shift) { scrollBy(-(term.rows - 1)); return [] }
            return tilde(6)
        case 114: return tilde(2)
        case 122: return ss3("P")
        case 120: return ss3("Q")
        case 99: return ss3("R")
        case 118: return ss3("S")
        case 96: return tilde(15)
        case 97: return tilde(17)
        case 98: return tilde(18)
        case 100: return tilde(19)
        case 101: return tilde(20)
        case 109: return tilde(21)
        case 103: return tilde(23)
        case 111: return tilde(24)
        default: break
        }
        // テンキー (アプリケーションモード)
        if term.appKeypad && m.contains(.numericPad) {
            let map: [UInt16: String] = [82: "p", 83: "q", 84: "r", 85: "s", 86: "t", 87: "u", 88: "v", 89: "w", 91: "x", 92: "y",
                                         65: "n", 67: "j", 69: "k", 75: "o", 78: "m", 81: "X"]
            if let c = map[e.keyCode] { return Array("\u{1B}O\(c)".utf8) }
        }
        return nil
    }

    // MARK: - NSTextInputClient (日本語入力)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = nil
        needsDisplay = true
        guard !s.isEmpty else { return }
        clearSelection()
        scrollToBottom()
        onSendText?(s)
    }

    override func doCommand(by selector: Selector) {
        // keyDown で拾えなかった分 (主に変換確定直後のキー)
        switch selector {
        case #selector(insertNewline(_:)): onSendBytes?(settings.sendNewlineBytes)
        case #selector(deleteBackward(_:)): onSendBytes?([settings.bsSendsDel ? 0x7F : 0x08])
        case #selector(insertTab(_:)): onSendBytes?([0x09])
        case #selector(cancelOperation(_:)): onSendBytes?([0x1B])
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString { marked = a } else { marked = NSAttributedString(string: string as? String ?? "") }
        markedSel = selectedRange
        if marked?.length == 0 { marked = nil }
        needsDisplay = true
    }

    func unmarkText() { marked = nil; needsDisplay = true }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.map { NSRange(location: 0, length: $0.length) } ?? NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { (marked?.length ?? 0) > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // 変換候補の窓をカーソルの下に出す
        let r = NSRect(x: pad + CGFloat(term.cx) * cellW, y: pad + CGFloat(term.cy + scrollOffset) * cellH, width: cellW, height: cellH)
        guard let w = window else { return r }
        return w.convertToScreen(convert(r, to: nil))
    }

    // MARK: - スクロール

    func scrollBy(_ lines: Int) {
        let n = max(0, min(term.scrollback.count, scrollOffset + lines))
        if n != scrollOffset { scrollOffset = n; needsDisplay = true }
    }

    func scrollToBottom() {
        if scrollOffset != 0 { scrollOffset = 0; needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { dy /= cellH } else { dy *= 3 }
        accumScroll += dy
        let n = Int(accumScroll)
        guard n != 0 else { return }
        accumScroll -= CGFloat(n)
        if term.mouseMode != 0 && !event.modifierFlags.contains(.shift) {
            let p = cellAt(event)
            for _ in 0..<abs(n) { sendMouse(button: n > 0 ? 64 : 65, x: p.col, y: p.row, press: true) }
            return
        }
        if term.usingAlt {
            // vim / less などではスクロールを矢印キーとして送る
            let key: [UInt8] = Array((term.appCursor ? "\u{1B}O" : "\u{1B}[").utf8) + [n > 0 ? 0x41 : 0x42]
            for _ in 0..<abs(n) { onSendBytes?(key) }
            return
        }
        scrollBy(n)
    }
    private var accumScroll: CGFloat = 0

    // MARK: - マウス

    private func cellAt(_ e: NSEvent) -> (row: Int, col: Int, half: Bool) {
        let p = convert(e.locationInWindow, from: nil)
        let fx = (p.x - pad) / cellW
        let col = max(0, min(term.cols, Int(fx.rounded(.down))))
        let row = max(0, min(term.rows - 1, Int(((p.y - pad) / cellH).rounded(.down))))
        return (row, col, fx - CGFloat(col) > 0.5)
    }

    private func posAt(_ e: NSEvent) -> Pos {
        let c = cellAt(e)
        let col = c.half ? min(term.cols, c.col + 1) : c.col
        return Pos(line: lineBase + firstLineIndex + c.row, col: col)
    }

    private func sendMouse(button: Int, x: Int, y: Int, press: Bool) {
        if term.mouseSGR {
            onSendBytes?(Array("\u{1B}[<\(button);\(x + 1);\(y + 1)\(press ? "M" : "m")".utf8))
        } else {
            let b = press ? button : 3
            onSendBytes?([0x1B, 0x5B, 0x4D, UInt8(min(255, 32 + b)), UInt8(min(255, 33 + x)), UInt8(min(255, 33 + y))])
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if term.mouseMode != 0 && !event.modifierFlags.contains(.shift) {
            let c = cellAt(event)
            mouseReporting = true
            sendMouse(button: 0, x: min(c.col, term.cols - 1), y: c.row, press: true)
            return
        }
        mouseReporting = false
        let p = posAt(event)
        selMode = min(3, event.clickCount)
        if selMode == 1 {
            if event.modifierFlags.contains(.shift), selAnchor != nil {
                selHead = p
            } else {
                selAnchor = p; selHead = p
            }
        } else if selMode == 2 {
            let (s, e) = wordBounds(p)
            selAnchor = s; selHead = e
        } else {
            selAnchor = Pos(line: p.line, col: 0); selHead = Pos(line: p.line, col: term.cols)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseReporting {
            if term.mouseMode >= 1002 {
                let c = cellAt(event)
                sendMouse(button: 32, x: min(c.col, term.cols - 1), y: c.row, press: true)
            }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if p.y < 0 { scrollBy(1) } else if p.y > bounds.height { scrollBy(-1) }
        var pos = posAt(event)
        if selMode == 2, let a = selAnchor {
            let (s, e) = wordBounds(pos)
            pos = pos < a ? s : e
        } else if selMode == 3 {
            pos.col = pos < (selAnchor ?? pos) ? 0 : term.cols
        }
        selHead = pos
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mouseReporting {
            let c = cellAt(event)
            sendMouse(button: 0, x: min(c.col, term.cols - 1), y: c.row, press: false)
            mouseReporting = false
            return
        }
        if settings.copyOnSelect, selectionRange() != nil { copy(nil) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if settings.rightClickPaste {
            if canPaste?() ?? true { startPaste(addCR: false) }
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if settings.rightClickPaste { return nil }
        let m = NSMenu()
        m.addItem(withTitle: "コピー", action: #selector(copy(_:)), keyEquivalent: "")
        m.addItem(withTitle: "貼り付け", action: #selector(paste(_:)), keyEquivalent: "")
        m.addItem(withTitle: "貼り付け<CR>", action: #selector(pasteCR(_:)), keyEquivalent: "")
        return m
    }

    private func wordBounds(_ p: Pos) -> (Pos, Pos) {
        let idx = p.line - lineBase
        guard idx >= 0 && idx < term.totalLines else { return (p, p) }
        let cells = term.line(at: idx).cells
        func isWord(_ x: Int) -> Bool {
            guard x >= 0 && x < cells.count else { return false }
            let ch = cells[x].ch
            return !(ch == " " || "\"'`()[]{}<>|;,".contains(ch))
        }
        var s = min(p.col, cells.count - 1), e = s
        guard isWord(s) else { return (Pos(line: p.line, col: s), Pos(line: p.line, col: s + 1)) }
        while s > 0 && isWord(s - 1) { s -= 1 }
        while e < cells.count && isWord(e) { e += 1 }
        return (Pos(line: p.line, col: s), Pos(line: p.line, col: e))
    }

    func clearSelection() {
        if selAnchor != nil { selAnchor = nil; selHead = nil; needsDisplay = true }
    }

    /// 選択範囲の文字 (buffer.c BuffGetStringForCB)。行ごとに末尾の空白を除き、行の間は改行 (Mac なので LF)。
    /// 終わりは含まない。折り返して続く行は「継続行をコピー」(EnableContinuedLineCopy) のときだけつなげる
    var selectedText: String? {
        guard let (s, e) = selectionRange() else { return nil }
        var out = ""
        let base = lineBase
        for g in s.line...e.line {
            let idx = g - base
            guard idx >= 0 && idx < term.totalLines else { continue }
            let line = term.line(at: idx)
            let from = g == s.line ? s.col : 0
            let to = g == e.line ? min(e.col, line.cells.count) : line.cells.count
            var t = ""
            if from < to {
                for x in from..<to where line.cells[x].width != 0 { t.append(line.cells[x].ch) }
            }
            let continued = settings.continuedLineCopy && line.wrapped && g != e.line
            if !continued {
                while t.hasSuffix(" ") { t.removeLast() }
            }
            out += t
            if g != e.line && !continued { out += "\n" }
        }
        return out
    }

    var hasSelection: Bool { selectionRange() != nil }

    /// いま見えている画面の文字 (印刷用。行末の空白は除く)
    var visibleText: String {
        var rowsText: [String] = []
        for r in 0..<term.rows {
            let idx = firstLineIndex + r
            guard idx >= 0 && idx < term.totalLines else { continue }
            var t = term.line(at: idx).text
            while t.hasSuffix(" ") { t.removeLast() }
            rowsText.append(t)
        }
        return rowsText.joined(separator: "\n")
    }

    // MARK: - コピー・貼り付け (vtwin.cpp OnEditCopy など)

    /// コピー: 選択がなければクリップボードを空にする (CBSetTextW に空文字)
    @objc func copy(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let t = selectedText, !t.isEmpty { pb.setString(t, forType: .string) }
    }

    /// テーブルをコピー (buffer.c ConvertTable): U+0020 以下の文字の連続を 1 つの TAB に。改行はそのまま
    @objc func copyTable(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard let t = selectedText, !t.isEmpty else { return }
        pb.setString(TerminalView.convertTable(t), forType: .string)
    }

    static func convertTable(_ s: String) -> String {
        var out = ""
        var blank = false
        for u in s.unicodeScalars {
            if u == "\r" || u == "\n" {
                out.unicodeScalars.append(u); blank = false
            } else if u.value <= 0x20 {
                if !blank { out += "\t"; blank = true }
            } else {
                out.unicodeScalars.append(u); blank = false
            }
        }
        return out
    }

    /// 貼り付けた文字の送り先 (session が 1 行ごとに PasteDelayPerLine ずつ遅らせて送る)
    var onPaste: ((String) -> Void)?

    @objc func paste(_ sender: Any?) { startPaste(addCR: false) }
    @objc func pasteCR(_ sender: Any?) { startPaste(addCR: true) }

    /// clipboar.c CBPreparePaste
    func startPaste(addCR: Bool) {
        guard var s = NSPasteboard.general.string(forType: .string) else { return }
        if settings.trimTrailingNLOnPaste {
            while let c = s.last, c == "\r" || c == "\n" || c == "\r\n" { s.removeLast() }
        }
        // 確認 (CheckClipboardContentW)
        if settings.confirmChangePaste {
            var confirm = addCR ? settings.confirmChangePasteCR : s.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\r\n" })
            if !confirm, let words = settings.confirmChangePasteWords() {
                confirm = words.contains { s.contains($0) }
            }
            if confirm {
                guard let edited = PasteConfirmDialog.run(text: s, over: window, near: cursorScreenPoint()) else { return }
                s = edited
            }
        }
        if s.isEmpty && !addCR { return }
        let addBracket = !settings.bracketedControlOnly || s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        if addCR { s += "\r" }
        s = s.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if term.bracketedPaste && addBracket { s = "\u{1B}[200~" + s + "\u{1B}[201~" }
        scrollToBottom()
        onPaste?(s)
    }

    /// 文字カーソルの画面上の位置 (確認ダイアログを出す場所)
    private func cursorScreenPoint() -> NSPoint? {
        guard let w = window else { return nil }
        let r = convert(cursorRect(), to: nil)
        return w.convertPoint(toScreen: NSPoint(x: r.minX, y: r.minY))
    }

    /// 全て選択 (BuffSelectAll): バッファの先頭から最後の行の次の行の頭まで。AutoTextCopy ならすぐコピー
    @objc override func selectAll(_ sender: Any?) {
        selMode = 1
        selAnchor = Pos(line: lineBase, col: 0)
        selHead = Pos(line: lineBase + term.totalLines, col: 0)
        needsDisplay = true
        if settings.copyOnSelect { copy(nil) }
    }

    /// 表示画面を選択 (BuffSelectScreen): いま見えている画面の行すべて
    @objc func selectScreen(_ sender: Any?) {
        selMode = 1
        let top = lineBase + firstLineIndex
        selAnchor = Pos(line: top, col: 0)
        selHead = Pos(line: top + term.rows, col: 0)
        needsDisplay = true
        if settings.copyOnSelect { copy(nil) }
    }

    /// 選択を解除 (クリップボードはそのまま)
    @objc func cancelSelection(_ sender: Any?) { clearSelection() }

    /// 貼り付けてよいか (接続中・転送やファイル送信をしていない・ログの再生でない)。session が決める
    var canPaste: (() -> Bool)?

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(copyTable(_:)):
            return hasSelection
        case #selector(paste(_:)), #selector(pasteCR(_:)):
            return (canPaste?() ?? true) && NSPasteboard.general.string(forType: .string) != nil
        default:
            return true
        }
    }
}
