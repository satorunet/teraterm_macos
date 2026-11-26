import AppKit
import TeraCore

/// 端末画面を描き、キー入力・マウス・日本語入力を受ける
final class TerminalView: NSView, NSTextInputClient {
    let term: Terminal
    var settings: TermSettings {
        didSet {
            term.eightColorMode = !(settings.pcBoldColor || settings.aixterm16Color || settings.xterm256Color)
            applyFont()
            delimChars = TTKeyMap.hex2Str(settings.delimList)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    /// 端末から相手に送る文字列 (エンコード前)
    var onSendText: ((String) -> Void)?
    /// 端末から相手に送るバイト列 (キーのエスケープシーケンスなど)
    var onSendBytes: (([UInt8]) -> Void)?
    /// マクロの enablekeyb 0 で false (キー入力を送らない)
    var keyboardEnabled = true
    var onResize: ((Int, Int) -> Void)?
    /// ファーストレスポンダになった (タブの分割表示でフォーカスのあるペインを決める)
    var onFocus: (() -> Void)?

    private(set) var cellW: CGFloat = 8
    private(set) var cellH: CGFloat = 16
    private var baseline: CGFloat = 12
    /// 文字間スペース (VTFontSpace の DX, DY) と、1 文字ごとに足す幅 (セル幅 − 文字の幅)
    private var textDX: CGFloat = 0
    private var textDY: CGFloat = 0
    private var kern: CGFloat = 0
    private var font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
    private var italicFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private var boldItalicFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
    let pad: CGFloat = 4

    /// 何行ぶん過去にさかのぼって表示しているか
    private(set) var scrollOffset = 0
    /// 前に見たときの term.scrolledOutTotal (AutoScrollOnlyInBottomLine で表示位置を保つため)
    private var lastScrolledOut = 0
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
    /// ダブルクリックで選んだ単語の範囲 (buffer.c DblClkStart / DblClkEnd)
    private var dblClkStart: Pos?
    private var dblClkEnd: Pos?
    /// マウスのボタンを端末に送っている (押したボタン 0 = 左, 1 = 中, 2 = 右)
    private var mouseReporting = false
    private var reportButton = 0
    /// 中・右ボタンで選択を始めた (SelectOnlyByLButton がオフのとき)
    private var otherSelecting = false
    /// DelimList の $XX を外したもの
    private var delimChars = ""

    init(term: Terminal, settings: TermSettings) {
        self.term = term
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        delimChars = TTKeyMap.hex2Str(settings.delimList)
        term.eightColorMode = !(settings.pcBoldColor || settings.aixterm16Color || settings.xterm256Color)
        // OSC 4 / 10 / 11 などの問い合わせに答える色 (DispGetColor) と、色が変わったときの描き直し
        term.configuredColor = { [weak self] slot in self?.configuredRGB(slot) ?? RGB(0, 0, 0) }
        term.onColorsChanged = { [weak self] in self?.needsDisplay = true }
        applyFont()
        startBlink()
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeRuntime.didChange, object: nil)
        bgSpec = ThemeRuntime.shared.background
        lastScrolledOut = term.scrolledOutTotal
        _ = KeyMapStore.current   // 保存されたキーボード設定ファイルを読んでおく
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
    // 背景画像がある (テーマ) ときは透明 (絵を描いてから文字を重ねる)
    override var isOpaque: Bool { bgSpec == nil }

    /// SelectOnActivate: ウインドウを選んだクリックで文字の選択を始めるか (vtwin.cpp OnMouseActivate)
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { settings.selectOnActivate }

    override func becomeFirstResponder() -> Bool {
        focused = true; blinkOn = true; needsDisplay = true; onFocus?()
        // 端末に入ったら「かな」でも英数字モードにする (変換中でなければ)
        if marked == nil { AsciiInput.switchToAlphanumeric() }
        return true
    }
    override func resignFirstResponder() -> Bool { focused = false; needsDisplay = true; return true }

    private func startBlink() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self = self, self.term.cursorBlink, self.focused else { return }
            self.blinkOn.toggle()
            self.setNeedsDisplay(self.cursorRect().insetBy(dx: -2, dy: -2))
        }
    }

    deinit {
        blinkTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 背景画像 (テーマの BGTheme。vtdisp.c CreateBGImage)

    /// 描く背景 (ThemeRuntime.shared.background)。nil なら設定の背景色で塗る
    private var bgSpec: BGImageSpec?
    /// bounds の大きさ × backingScaleFactor で描いておいた背景の絵
    private var bgImage: CGImage?
    private var bgImageKey: (NSSize, CGFloat, NSRect?)?
    private var moveObserver: NSObjectProtocol?

    @objc private func themeChanged() {
        bgSpec = ThemeRuntime.shared.background
        bgImage = nil
        bgImageKey = nil
        observeWindowMove()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowMove()
        bgImage = nil
    }

    /// 壁紙 (Src1) を使うときは、ウインドウを動かしたら切り出し直す
    private func observeWindowMove() {
        if let o = moveObserver { NotificationCenter.default.removeObserver(o); moveObserver = nil }
        guard let w = window, bgSpec?.src1.enable == true else { return }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if ThemeSettings.load().fastSizeMove && self.inLiveResize { return }
            self.bgImage = nil
            self.needsDisplay = true
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if bgSpec != nil { bgImage = nil; needsDisplay = true }
    }

    /// 背景の絵を描く。描けたら true (FastSizeMove なら、大きさを変えている間は描かない)
    private func drawBackgroundImage(_ dirtyRect: NSRect) -> Bool {
        guard let spec = bgSpec else { return false }
        if inLiveResize && ThemeSettings.load().fastSizeMove { return false }
        let scale = window?.backingScaleFactor ?? 2
        let wf: NSRect? = spec.src1.enable ? window.map { w in w.convertToScreen(convert(bounds, to: nil)) } : nil
        if let k = bgImageKey, bgImage != nil, k.0 == bounds.size, k.1 == scale, k.2 == wf {
            // そのまま使う
        } else {
            bgImage = spec.render(size: bounds.size, scale: scale, windowFrame: wf, screen: window?.screen)
            bgImageKey = (bounds.size, scale, wf)
        }
        guard let img = bgImage, let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.saveGState()
        ctx.clip(to: dirtyRect)
        // 反転した座標 (isFlipped) なので上下を戻して描く
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()
        return true
    }

    /// この端末のセッション (分割中はウインドウのコントローラとは限らないので、セッションが自分を入れる)
    weak var owner: SessionWindowController?
    private var session: SessionWindowController? { owner ?? window?.windowController as? SessionWindowController }

    // MARK: - フォントと大きさ

    private func applyFont() {
        font = settings.font
        let fm = NSFontManager.shared
        boldFont = fm.convert(font, toHaveTrait: .boldFontMask)
        italicFont = fm.convert(font, toHaveTrait: .italicFontMask)
        boldItalicFont = fm.convert(boldFont, toHaveTrait: .italicFontMask)
        let adv = ("M" as NSString).size(withAttributes: [.font: font]).width
        // vtdisp.c ChangeFont: CellWidth = FontWidth + FontDW, CellHeight = FontHeight + FontDH
        cellW = max(1, round(adv * 2) / 2 + CGFloat(settings.fontDW))
        let lm = NSLayoutManager()
        cellH = max(1, ceil(lm.defaultLineHeight(for: font)) + CGFloat(settings.fontDH))
        baseline = ceil(font.ascender)
        kern = cellW - adv
        textDX = CGFloat(settings.fontDX)
        textDY = CGFloat(settings.fontDY)
        term.ambiguousWide = settings.ambiguousWide
        // 点滅は相手 (DECSCUSR / ?12) が変えられるので term.cursorBlink を見る。設定はその既定値
        if term.defaultCursorBlink != settings.cursorBlink { term.defaultCursorBlink = settings.cursorBlink }
        term.defaultCursorStyle = settings.cursorShape == "vertical" ? .bar : (settings.cursorShape == "horizontal" ? .underline : .block)
        // EnableScrollBuff がオフならスクロールバッファを使わない
        term.scrollbackLimit = settings.enableScrollBuff ? settings.scrollback : 0
    }

    /// cols × rows がちょうど入る中身の大きさ
    func contentSize(cols: Int, rows: Int) -> NSSize {
        NSSize(width: CGFloat(cols) * cellW + pad * 2, height: CGFloat(rows) * cellH + pad * 2)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let c = min(TermLimits.widthMax, max(10, Int((newSize.width - pad * 2) / cellW)))
        let r = min(TermLimits.heightMax, max(2, Int((newSize.height - pad * 2) / cellH)))
        if c != term.cols || r != term.rows {
            // 幅が変わると行を折り返し直すので、選んでいた位置は合わなくなる
            if c != term.cols { selAnchor = nil; selHead = nil }
            term.resize(cols: c, rows: r)
            // ClearOnResize: 大きさを変えたら画面をクリアする (buffer.c BuffChangeWinSize)
            if settings.clearOnResize { term.clearScreen() }
            scrollOffset = min(scrollOffset, term.scrollback.count)
            lastScrolledOut = term.scrolledOutTotal
            onResize?(c, r)
            needsDisplay = true
        }
    }

    // MARK: - 表示更新

    /// 前に描くよう頼んだときの画面 (変わった行だけ描き直すための比較用)
    private var shownRows: [[Cell]] = []
    private var shownCursor = (x: -1, y: -1)
    private var shownReverse = false

    func dataArrived() {
        if TerminalView.latencyLog && latencyT0 > 0 && latencyData == 0 { latencyData = CFAbsoluteTimeGetCurrent() }
        let delta = max(0, term.scrolledOutTotal - lastScrolledOut)
        lastScrolledOut = term.scrolledOutTotal
        let oldOffset = scrollOffset
        if scrollOffset != 0 {
            if settings.autoScrollOnlyInBottomLine {
                // 一番下を見ているときだけ自動でスクロールする: さかのぼって見ている行をそのまま見せる
                scrollOffset = min(term.scrollback.count, scrollOffset + delta)
            } else {
                // 新しい出力が来たら一番下に戻る (Tera Term と同じ)
                scrollOffset = 0
            }
        }
        blinkOn = true
        invalidateChangedRows(fullIf: delta > 0 || oldOffset != scrollOffset)
    }

    /// 変わった行 (とカーソルの行) だけ描き直しを頼む。スクロールしたときや色の切り替えなどは全体
    private func invalidateChangedRows(fullIf full: Bool) {
        let first = firstLineIndex
        var rows: [[Cell]] = []
        rows.reserveCapacity(term.rows)
        for r in 0..<term.rows {
            let li = first + r
            rows.append(li >= 0 && li < term.totalLines ? term.line(at: li).cells : [])
        }
        let reverse = term.reverseScreen
        let cursor = (x: term.cx, y: term.cy + scrollOffset)
        defer { shownRows = rows; shownCursor = cursor; shownReverse = reverse }
        if full || shownRows.count != rows.count || reverse != shownReverse || !term.colorOverrides.isEmpty || marked != nil || bgSpec != nil {
            needsDisplay = true
            return
        }
        var dirty = Set<Int>()
        for r in 0..<rows.count where rows[r] != shownRows[r] {
            // URL の色付けは前後の行 (折り返し) にまたがるので、となりも描く
            dirty.insert(r); if r > 0 { dirty.insert(r - 1) }; if r + 1 < rows.count { dirty.insert(r + 1) }
        }
        if cursor.y >= 0 && cursor.y < rows.count { dirty.insert(cursor.y) }
        if shownCursor.y >= 0 && shownCursor.y < rows.count { dirty.insert(shownCursor.y) }
        for r in dirty {
            // 上下の余白・はみ出し (太字・斜体) のぶん少し広めに
            setNeedsDisplay(NSRect(x: 0, y: pad + CGFloat(r) * cellH - 1, width: bounds.width, height: cellH + 2))
        }
    }

    private var firstLineIndex: Int { term.totalLines - term.rows - scrollOffset }
    private var lineBase: Int { term.scrolledOutTotal - term.scrollback.count }

    private func cursorRect() -> NSRect {
        NSRect(x: pad + CGFloat(term.cx) * cellW, y: pad + CGFloat(term.cy + scrollOffset) * cellH, width: cellW * 2, height: cellH)
    }

    // MARK: - 色 (vtdisp.c GetDrawAttr / Get16ColorIndex)

    /// ビジュアルベル (vtterm.c VisualBell の CSQExchangeColor): 一瞬だけ画面の文字色と背景色を入れ替える
    var bellInverted = false { didSet { needsDisplay = true } }
    /// 描くときの設定 (OSC 10 / 11 / 17 / 19 などで変えた色を入れたもの。draw の始めに作る)
    private var drawSettings: TermSettings?

    /// 設定の色 (DispGetColor が返す ts.VTColor など。.ansi は 256 色表の初期値)
    private func configuredRGB(_ slot: ColorSlot) -> RGB {
        let s = settings
        let c: NSColor
        switch slot {
        case .ansi(let n): c = n < 16 ? (s.ansi16?[n] ?? Palette.colors[n]) : Palette.colors[max(0, min(255, n))]
        case .normalFG: c = s.fg
        case .normalBG: c = s.bg
        case .boldFG: c = s.boldColor.fg
        case .boldBG: c = s.boldColor.bg
        case .blinkFG: c = s.blinkColor.fg
        case .underFG: c = s.underlineColor.fg
        case .reverseBG: c = s.reverseColor.bg
        case .tekFG: c = .white
        case .tekBG: c = .black
        }
        let d = c.usingColorSpace(.sRGB) ?? c
        func v(_ x: CGFloat) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
        return RGB(v(d.redComponent), v(d.greenComponent), v(d.blueComponent))
    }

    private static func nsColor(_ c: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// settings に OSC で変えた色 (vt->BGVTColor など) を入れたもの
    private func settingsWithColorOverrides() -> TermSettings {
        var s = settings
        for (slot, c) in term.colorOverrides {
            let n = TerminalView.nsColor(c)
            switch slot {
            case .normalFG: s.fg = n
            case .normalBG: s.bg = n
            case .boldFG: s.boldColor.fg = n
            case .boldBG: s.boldColor.bg = n
            case .blinkFG: s.blinkColor.fg = n
            case .underFG: s.underlineColor.fg = n
            case .reverseBG: s.reverseColor.bg = n
            case .ansi, .tekFG, .tekBG: break
            }
        }
        return s
    }

    /// ANSI の色 (シーケンスの色番号)。nil は「ANSI の色ではない」(Attr2Fore / Attr2Back がない)
    private func ansiColor(_ c: TColor, bright: Bool) -> NSColor? {
        let s = drawSettings ?? settings
        let fullColor = s.pcBoldColor || s.aixterm16Color || s.xterm256Color
        switch c {
        case .def:
            return nil
        case .rgb(let r, let g, let b):
            // 38;2 / 48;2 は 256 色モード (Xterm256Color) のときだけ
            guard s.xterm256Color else { return nil }
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .idx(let i):
            var n = Int(i)
            // 256 色の番号は 38;5 / 48;5 から (Xterm256Color)。8〜15 は 90〜97 / 100〜107 (Aixterm16Color) か 38;5
            if n >= 16 && !s.xterm256Color { return nil }
            if n >= 8 && n < 16 && !s.aixterm16Color && !s.xterm256Color { return nil }
            if !fullColor {
                // 8 色モード: 1〜7 は明るい色
                if n > 0 && n < 8 { n += 8 }
            } else if s.pcBoldColor {
                // 16 色モード (PC 形式): 太字 (背景は点滅) の 0〜7 は明るい色
                if n < 8 && bright { n += 8 }
            }
            // OSC 4 で変えた色 (vt->ANSIColor)
            if !term.colorOverrides.isEmpty, let o = term.colorOverrides[.ansi(n)] { return TerminalView.nsColor(o) }
            if n < 16, let a = s.ansi16 { return a[n] }
            return Palette.colors[n]
        }
    }

    /// 文字と背景の色。selected: マウスで選んだところ (反転する)
    private func drawColors(_ a: CellAttr, selected: Bool, url: Bool) -> (NSColor, NSColor, Bool) {
        let s = drawSettings ?? settings
        let isURL = s.enableURLColor && url
        let isUnder = s.underlineAttrColor && a.underline
        let isBold = s.enableBoldAttrColor && a.bold
        let isBlink = s.enableBlinkAttrColor && a.blink
        var reverse = selected
        if a.reverse { reverse.toggle() }
        if term.reverseScreen != bellInverted { reverse.toggle() }
        var text = s.fg, back = s.bg
        func pair(_ p: ColorPair) {
            if !reverse {
                text = p.fg; back = s.useNormalBGColor ? s.bg : p.bg
            } else {
                text = s.useNormalBGColor ? s.bg : p.bg; back = p.fg
            }
        }
        if !(isURL || isUnder || isBold || isBlink) {
            if reverse {
                if s.enableReverseAttrColor { text = s.reverseColor.fg; back = s.reverseColor.bg } else { text = s.bg; back = s.fg }
            }
        } else if isBlink {
            pair(s.blinkColor)
        } else if isBold {
            pair(s.boldColor)
        } else if isUnder {
            pair(s.underlineColor)
        } else {
            pair(s.urlColor)
        }
        if s.enableANSIColor {
            if let c = ansiColor(a.fg, bright: isBold) { if !reverse { text = c } else { back = c } }
            if let c = ansiColor(a.bg, bright: isBlink) { if !reverse { back = c } else { text = c } }
        }
        return (text, back, reverse)
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

    // MARK: - URL (buffer.c mark_url_w。Mac では描くときと押したときに探す)

    /// 行 (term.line(at:) の番号) → URL の桁。折り返してつながった行もまとめて調べる
    private func urlColumns(_ li: Int, cache: inout [Int: Set<Int>]) -> Set<Int> {
        if let c = cache[li] { return c }
        var start = li
        var guardCount = 0
        while start > 0 && term.line(at: start - 1).wrapped && guardCount < 64 { start -= 1; guardCount += 1 }
        var end = start
        while end < term.totalLines - 1 && term.line(at: end).wrapped && end - start < 128 { end += 1 }
        var scalars: [Unicode.Scalar] = []
        var where_: [(Int, Int)] = []
        for l in start...end {
            let cells = term.line(at: l).cells
            for (x, c) in cells.enumerated() where c.width != 0 {
                let u = c.ch.unicodeScalars
                scalars.append(u.count == 1 ? u.first! : " ")
                where_.append((l, x))
            }
            cache[l] = []
        }
        for r in TTURL.urlRanges(scalars) {
            for i in r { cache[where_[i].0, default: []].insert(where_[i].1) }
        }
        return cache[li] ?? []
    }

    /// その位置の URL の文字列
    private func urlAt(_ p: Pos) -> String? {
        let li = p.line - lineBase
        guard li >= 0 && li < term.totalLines else { return nil }
        var start = li
        while start > 0 && term.line(at: start - 1).wrapped && li - start < 64 { start -= 1 }
        var end = start
        while end < term.totalLines - 1 && term.line(at: end).wrapped && end - start < 128 { end += 1 }
        var scalars: [Unicode.Scalar] = []
        var hit: Int?
        for l in start...end {
            for (x, c) in term.line(at: l).cells.enumerated() where c.width != 0 {
                if l == li && x == min(p.col, term.cols - 1) { hit = scalars.count }
                let u = c.ch.unicodeScalars
                scalars.append(u.count == 1 ? u.first! : " ")
            }
        }
        guard let h = hit, let r = TTURL.urlRanges(scalars).first(where: { $0.contains(h) }) else { return nil }
        var s = String.UnicodeScalarView()
        s.append(contentsOf: scalars[r])
        return String(s)
    }

    /// buffer.c invokeBrowserWithUrl
    private func openURL(_ s: String) {
        guard let u = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else { return }
        NSWorkspace.shared.open(u)
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        // macOS の「フォントスムージング」は暗い背景の明るい文字を太く見せるので切る (Terminal.app の見た目に合わせる)
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        drawSettings = term.colorOverrides.isEmpty ? nil : settingsWithColorOverrides()
        defer { drawSettings = nil }
        let settings = drawSettings ?? self.settings
        let screenRev = term.reverseScreen != bellInverted
        let defaultBG = screenRev ? settings.fg : settings.bg
        let bgDrawn = drawBackgroundImage(dirtyRect)
        defer {
            if TerminalView.latencyLog && latencyT0 > 0 && latencyData > 0 {
                let n = CFAbsoluteTimeGetCurrent()
                latencyResults.append((data: (latencyData - latencyT0) * 1000, drawn: (n - latencyT0) * 1000))
                latencyT0 = 0; latencyData = 0
            }
        }
        let spec = bgDrawn ? bgSpec : nil
        if !bgDrawn {
            defaultBG.setFill()
            dirtyRect.fill()
        }
        let sel = selectionRange()
        let first = firstLineIndex
        let base = lineBase
        let r0 = max(0, Int((dirtyRect.minY - pad) / cellH))
        let r1 = min(term.rows - 1, Int((dirtyRect.maxY - pad) / cellH))
        guard r0 <= r1 else { return }
        let wantURL = settings.enableURLColor || settings.urlUnderline
        var urlCache: [Int: Set<Int>] = [:]

        for r in r0...r1 {
            let li = first + r
            guard li >= 0 && li < term.totalLines else { continue }
            let line = term.line(at: li)
            let global = base + li
            let y = pad + CGFloat(r) * cellH
            let urls = wantURL ? urlColumns(li, cache: &urlCache) : []
            var x = 0
            // 同じ見た目の半角 ASCII はまとめて描く
            var run = ""
            var runX = 0
            var runLen = 0
            var runAttrs: [NSAttributedString.Key: Any] = [:]
            // 速くするため: 書式の辞書を毎回作って比べず、見た目の鍵 (フォント・色・下線・取り消し線) で比べる
            var runKey: (font: Int, fg: NSColor, underline: Bool, strike: Bool)? = nil
            // 同じ属性が続くあいだは色を計算し直さない
            var memoAttr: CellAttr? = nil, memoSel = false, memoURL = false
            var memoColors: (NSColor, NSColor, Bool) = (.black, .black, false)
            func flush() {
                if !run.isEmpty {
                    (run as NSString).draw(at: NSPoint(x: pad + CGFloat(runX) * cellW + textDX, y: y + textDY), withAttributes: runAttrs)
                    run = ""
                }
                runLen = 0
                runKey = nil
            }
            while x < line.cells.count {
                let cell = line.cells[x]
                if cell.width == 0 { x += 1; continue }
                let w = Int(cell.width)
                let a = cell.attr
                let isURL = urls.contains(x)
                let selNow = isSelected(global, x, sel)
                if memoAttr != a || memoSel != selNow || memoURL != isURL {
                    memoColors = drawColors(a, selected: selNow, url: isURL)
                    memoAttr = a; memoSel = selNow; memoURL = isURL
                }
                var (fg, bg, rev) = memoColors
                if a.dim { fg = fg.withAlphaComponent(0.6) }
                if a.invisible { fg = bg }
                if let spec = spec {
                    // 背景画像の上: 文字の背景は BGTextBackAlpha などの不透明度で塗る
                    let alpha = spec.cellBackAlpha(isDefaultBack: bg == defaultBG, reverse: rev)
                    if alpha > 0 {
                        bg.withAlphaComponent(alpha).setFill()
                        NSRect(x: pad + CGFloat(x) * cellW, y: y, width: CGFloat(w) * cellW, height: cellH).fill(using: .sourceOver)
                    }
                } else if bg != defaultBG {
                    bg.setFill()
                    NSRect(x: pad + CGFloat(x) * cellW, y: y, width: CGFloat(w) * cellW, height: cellH).fill()
                }
                // 下線: UnderlineAttrFont (下線属性) / URLUnderline (URL)
                let underline = (settings.underlineAttrFont && a.underline) || (settings.urlUnderline && isURL)
                if cell.ch == " " && w == 1 && !underline && !a.strike && runKey != nil && runX + runLen == x {
                    // 下線などのない空白は、続いている文字の並びに入れて 1 回で描く (空白は何も描かない)
                    run.append(" "); runLen += 1
                } else if cell.ch != " " {
                    let fontIndex = a.bold && settings.enableBold ? (a.italic ? 3 : 1) : (a.italic ? 2 : 0)
                    func makeAttrs() -> [NSAttributedString.Key: Any] {
                        var attrs: [NSAttributedString.Key: Any] = [
                            .font: [font, boldFont, italicFont, boldItalicFont][fontIndex],
                            .foregroundColor: fg,
                        ]
                        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                        if a.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                        return attrs
                    }
                    let isAscii = cell.ch.unicodeScalars.count == 1 && cell.ch.unicodeScalars.first!.value < 0x7F
                    if isAscii && w == 1 && !a.decSpecial {
                        if let k = runKey, k.font == fontIndex, k.fg == fg, k.underline == underline, k.strike == a.strike, runX + runLen == x {
                            // 同じ見た目が続いている
                        } else {
                            flush()
                            var attrs = makeAttrs()
                            if abs(kern) > 0.01 { attrs[.kern] = kern }
                            runX = x; runAttrs = attrs
                            runKey = (fontIndex, fg, underline, a.strike)
                        }
                        run.append(cell.ch); runLen += 1
                    } else {
                        let attrs = makeAttrs()
                        flush()
                        drawSingle(cell.ch, x: x, y: y, width: w, attrs: attrs)
                    }
                } else {
                    flush()
                    if underline || a.strike {
                        let s: NSString = w == 2 ? "  " : " "
                        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
                        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                        if a.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                        if abs(kern) > 0.01 { attrs[.kern] = kern }
                        s.draw(at: NSPoint(x: pad + CGFloat(x) * cellW + textDX, y: y + textDY), withAttributes: attrs)
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
        let tx = rect.minX + textDX, ty = rect.minY + textDY
        var dx: CGFloat = 0
        if size.width < rect.width { dx = (rect.width - size.width) / 2 }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.insetBy(dx: -1, dy: 0)).addClip()
        if size.width > rect.width + 1 && settings.drawingResizedFont {
            // DrawingResizedFont: 幅が広すぎる文字は描画幅に合わせて横に縮める
            let t = NSAffineTransform()
            t.translateX(by: tx, yBy: ty)
            t.scaleX(by: rect.width / size.width, yBy: 1)
            t.concat()
            s.draw(at: .zero, withAttributes: attrs)
        } else {
            s.draw(at: NSPoint(x: tx + dx, y: ty), withAttributes: attrs)
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
        // DEC Special Graphics: ▒ (0x61) と スキャンライン ⎺⎻⎼⎽ (0x6F〜0x73)
        if v == 0x2592 { color.withAlphaComponent(0.5).setFill(); r.fill(); return true }
        if (0x23BA...0x23BD).contains(v) {
            let lw = max(1, round(cellW / 8))
            let fy: [CGFloat] = [0, 0.25, 0.75, 1]
            let yy = r.minY + (r.height - lw) * fy[Int(v - 0x23BA)]
            color.setFill(); NSRect(x: r.minX, y: yy, width: r.width, height: lw).fill(); return true
        }
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
        let settings = drawSettings ?? self.settings
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
        guard blinkOn || !term.cursorBlink else { return }
        switch term.cursorStyle {
        case .block:
            rect.fill()
            // カーソルの下の文字を背景色で描き直す
            let cell = term.lines[term.cy].cells[term.cx]
            if cell.ch != " " && cell.width != 0 {
                let attrs: [NSAttributedString.Key: Any] = [.font: cell.attr.bold && settings.enableBold ? boldFont : font,
                                                            .foregroundColor: settings.bg]
                drawSingle(cell.ch, x: term.cx, y: y, width: Int(cell.width), attrs: attrs)
            }
        case .underline:
            NSRect(x: x, y: y + cellH - 2, width: w, height: 2).fill()
        case .bar:
            NSRect(x: x, y: y, width: 2, height: cellH).fill()
        }
    }

    // MARK: - キー入力 (keyboard.c KeyDown)

    static let latencyLog = ProcessInfo.processInfo.environment["TERAMAC_LATENCY"] != nil || ProcessInfo.processInfo.environment["TERAMAC_LATENCY_TEST"] != nil
    var latencyT0: CFAbsoluteTime = 0
    var latencyData: CFAbsoluteTime = 0
    var latencyResults: [(data: Double, drawn: Double)] = []
    var latencySent: [Double] = []
    func latencyMarkSent() { if TerminalView.latencyLog && latencyT0 > 0 && latencySent.count <= latencyResults.count { latencySent.append((CFAbsoluteTimeGetCurrent() - latencyT0) * 1000) } }
    override func keyDown(with event: NSEvent) {
        if TerminalView.latencyLog { latencyT0 = CFAbsoluteTimeGetCurrent(); latencyData = 0 }
        if !keyboardEnabled { NSSound.beep(); return }
        NSCursor.setHiddenUntilMouseMoves(true)
        if hasMarkedText() {
            inputContext?.handleEvent(event)
            return
        }
        if teraTermKeyDown(event) { return }
        // ここからは Windows の WM_CHAR にあたる
        let mods = event.modifierFlags
        let meta = isMeta(event)
        if mods.contains(.control), !mods.contains(.command), let raw = event.charactersIgnoringModifiers, let c = raw.unicodeScalars.first {
            if let code = controlCode(c) { sendKey(meta ? [0x1B, code] : [code]); return }
        }
        if meta, !mods.contains(.command),
           let s = event.characters(byApplyingModifiers: mods.intersection(.shift)), !s.isEmpty, !TerminalView.isFunctionKeyText(s) {
            clearSelection()
            scrollToBottom()
            onSendBytes?([0x1B])
            onSendText?(s)
            return
        }
        inputContext?.handleEvent(event)
    }

    /// NSEvent のファンクションキーの文字 (U+F700〜U+F8FE) は送らない
    private static func isFunctionKeyText(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0xF700...0xF8FE).contains($0.value) }
    }

    /// MetaKey: off / on / left (左 Option だけ) / right (右 Option だけ)
    private func isMeta(_ e: NSEvent) -> Bool {
        let m = e.modifierFlags
        guard m.contains(.option) else { return false }
        let raw = m.rawValue
        switch settings.metaKey.lowercased() {
        case "off": return false
        case "left": return raw & 0x20 != 0     // NX_DEVICELALTKEYMASK
        case "right": return raw & 0x40 != 0    // NX_DEVICERALTKEYMASK
        default: return true
        }
    }

    /// キーマップ (KEYBOARD.CNF) と VKey2KeyStr。送った (した) ら true
    private func teraTermKeyDown(_ event: NSEvent) -> Bool {
        let m = event.modifierFlags
        if m.contains(.command) { return false }   // ⌘ はメニューのショートカット
        let shift = m.contains(.shift), ctrl = m.contains(.control), alt = m.contains(.option)
        guard let code = TTKeyMap.keyCode(macKeyCode: event.keyCode, shift: shift, control: ctrl, alt: alt) else {
            return xtermModifiedKey(event)
        }
        let meta = isMeta(event)
        var modStat = 0
        if shift { modStat = 2 }
        if ctrl { modStat |= 4 }
        if alt && !meta { modStat |= 16 }
        let km = KeyMapStore.current
        let appK = term.appKeypad && !settings.disableAppKeypad
        let appC = term.appCursor && !settings.disableAppCursor
        var key = 0
        // DeleteKey がオンなら Delete キー (テンキーの . を除く) はキーマップを見ずに DEL
        if !(event.keyCode == 117 && settings.deleteKeySendsDel && (code & 0x1FF) != 83) {
            key = km.keyID(forCode: code)
        }
        if key == 0 {
            guard var a = vkey2KeyStr(event.keyCode, modStat: modStat, keyMap: km, appKeypad: appK, appCursor: appC) else {
                return xtermModifiedKey(event)
            }
            // Meta: 1 文字なら ESC を前に付ける (Meta8Bit はオフ)
            if meta {
                switch a {
                case .binary(let s) where s.unicodeScalars.count == 1: a = .binary("\u{1B}" + s)
                case .text(let s) where s.unicodeScalars.count == 1: a = .text("\u{1B}" + s)
                default:
                    // Mac 版の追加 (#106): Option+矢印・編集キー・ファンクションキーは
                    // Meta がオンでも xterm の修飾付き (ESC[1;3D など) で送る。本家は修飾なしで送ってしまう
                    if alt && xtermModifiedKey(event) { return true }
                }
            }
            perform(a)
            return true
        }
        guard let a = km.action(for: key, appKeypad: appK, appCursor: appC) else { return false }
        perform(a)
        return true
    }

    /// keyboard.c VKey2KeyStr (キーマップにないキー)。modStat: 0 = 修飾なし, 2 = Shift, 4 = Ctrl
    private func vkey2KeyStr(_ k: UInt16, modStat: Int, keyMap km: TTKeyMap, appKeypad: Bool, appCursor: Bool) -> TTKeyMap.Action? {
        let single = modStat == 0, shiftOnly = modStat == 2, control = modStat == 4
        func key(_ id: Int) -> TTKeyMap.Action? { km.action(for: id, appKeypad: appKeypad, appCursor: appCursor) }
        switch k {
        case 51:   // BS
            if control { return .binary(settings.bsSendsDel ? "\u{08}" : "\u{7F}") }
            if single { return .binary(settings.bsSendsDel ? "\u{7F}" : "\u{08}") }
        case 36, 76:   // Return / テンキーの Enter (VK_RETURN)
            if single { return .text("\r") }
        case 53:   // Esc
            if single { return .binary("\u{1B}") }
        case 49:   // Space
            if control { return .binary("\u{0}") }
        case 117:  // Delete (前方削除)
            if single { return settings.deleteKeySendsDel ? .binary("\u{7F}") : key(TTKeyID.remove) }
        case 126: if single { return key(TTKeyID.up) }
        case 125: if single { return key(TTKeyID.down) }
        case 124: if single { return key(TTKeyID.right) }
        case 123: if single { return key(TTKeyID.left) }
        case 114: if single { return key(TTKeyID.insert) }
        case 115: if single { return key(TTKeyID.find) }
        case 119: if single { return key(TTKeyID.select) }
        case 116: if single { return key(TTKeyID.prev) }
        case 121: if single { return key(TTKeyID.next) }
        case 122: if single { return key(TTKeyID.xf1) }
        case 120: if single { return key(TTKeyID.xf2) }
        case 99: if single { return key(TTKeyID.xf3) } else if shiftOnly { return key(TTKeyID.f13) }
        case 118: if single { return key(TTKeyID.xf4) } else if shiftOnly { return key(TTKeyID.f14) }
        case 96: if single { return key(TTKeyID.xf5) } else if shiftOnly { return key(TTKeyID.help) }
        case 97: if single { return key(TTKeyID.f6) } else if shiftOnly { return key(TTKeyID.doKey) }
        case 98: if single { return key(TTKeyID.f7) } else if shiftOnly { return key(TTKeyID.f17) }
        case 100: if single { return key(TTKeyID.f8) } else if shiftOnly { return key(TTKeyID.f18) }
        case 101: if single { return key(TTKeyID.f9) } else if shiftOnly { return key(TTKeyID.f19) }
        case 109: if single { return key(TTKeyID.f10) } else if shiftOnly { return key(TTKeyID.f20) }
        case 103: if single { return key(TTKeyID.f11) }
        case 111: if single { return key(TTKeyID.f12) }
        case 105: if single { return key(TTKeyID.f13) }
        case 107: if single { return key(TTKeyID.f14) }
        case 113: if single { return key(TTKeyID.help) }
        case 106: if single { return key(TTKeyID.doKey) }
        case 64: if single { return key(TTKeyID.f17) }
        case 79: if single { return key(TTKeyID.f18) }
        case 80: if single { return key(TTKeyID.f19) }
        case 90: if single { return key(TTKeyID.f20) }
        case 19: if control { return .binary("\u{0}") }      // Ctrl+2 → NUL
        case 20: if control { return .binary("\u{1B}") }     // Ctrl+3 → ESC
        case 21: if control { return .binary("\u{1C}") }     // Ctrl+4 → FS
        case 23: if control { return .binary("\u{1D}") }     // Ctrl+5 → GS
        case 22: if control { return .binary("\u{1E}") }     // Ctrl+6 → RS
        case 26, 44: if control { return .binary("\u{1F}") } // Ctrl+7 / Ctrl+/ → US
        case 28: if control { return .binary("\u{7F}") }     // Ctrl+8 → DEL
        case 10, 94: if modStat == 6 { return .binary("\u{7F}") }   // Shift+Ctrl+_ (VK_OEM_102)
        default: break
        }
        return nil
    }

    /// キーマップの結果をする (KeyDown の CodeType ごとの処理)
    private func perform(_ a: TTKeyMap.Action) {
        switch a {
        case .binary(let s):
            let u = Array(s.unicodeScalars)
            if u.allSatisfy({ $0.value < 0x100 }) { sendKey(u.map { UInt8($0.value) }) } else { clearSelection(); scrollToBottom(); onSendText?(s) }
        case .text(let s):
            clearSelection()
            scrollToBottom()
            // 改行の変換 (CR → 送信改行コード)
            var pending = ""
            for u in s.unicodeScalars {
                if u == "\r" {
                    if !pending.isEmpty { onSendText?(pending); pending = "" }
                    onSendBytes?(settings.sendNewlineBytes)
                } else {
                    pending.unicodeScalars.append(u)
                }
            }
            if !pending.isEmpty { onSendText?(pending) }
        case .macro(let name):
            var p = (name.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            if !p.hasPrefix("/") { p = (AppPaths.setupDirectory as NSString).appendingPathComponent(p) }
            session?.runMacro(url: URL(fileURLWithPath: p))
        case .command(let id):
            session?.macroCallMenu(id)
        case .accel(let id):
            accelCommand(id)
        }
    }

    /// vtwin.cpp OnAccelCommand
    private func accelCommand(_ id: Int) {
        switch id {
        case TTKeyID.print: session?.printMenu(nil)
        case TTKeyID.breakKey: session?.sendBreak(nil)
        case TTKeyID.cmdEditCopy: copy(nil)
        case TTKeyID.cmdEditPaste: if canPaste?() ?? true { startPaste(addCR: false) }
        case TTKeyID.cmdEditPasteCR: if canPaste?() ?? true { startPaste(addCR: true) }
        case TTKeyID.cmdEditCLS: session?.clearScreen(nil)
        case TTKeyID.cmdEditCLB: session?.clearBuffer(nil)
        case TTKeyID.cmdLineUp: scrollBy(1)
        case TTKeyID.cmdLineDown: scrollBy(-1)
        case TTKeyID.cmdPageUp: scrollBy(term.rows - 1)
        case TTKeyID.cmdPageDown: scrollBy(-(term.rows - 1))
        case TTKeyID.cmdBuffTop: scrollBy(term.scrollback.count)
        case TTKeyID.cmdBuffBottom: scrollToBottom()
        case TTKeyID.cmdNextWin: selectNextWindow(1, shownOnly: false)
        case TTKeyID.cmdPrevWin: selectNextWindow(-1, shownOnly: false)
        case TTKeyID.cmdNextSWin: selectNextWindow(1, shownOnly: true)
        case TTKeyID.cmdPrevSWin: selectNextWindow(-1, shownOnly: true)
        case TTKeyID.cmdLocalEcho: session?.settings.localEcho.toggle()
        case TTKeyID.cmdCtrlOpenTEK: _ = session?.openTEKWindow()
        case TTKeyID.cmdCtrlCloseTEK: session?.closeTEKWindow()
        default: break   // Hold・ScrollLock は Mac 版にない
        }
    }

    /// ttcmn SelectNextWin: Tera Term のウインドウを順に切り替える。shownOnly なら最小化したものは飛ばす
    /// (分割中のペインも 1 つのウインドウとして順に選ぶ)
    private func selectNextWindow(_ dir: Int, shownOnly: Bool) {
        let all = SessionWindowController.all
        guard let me = session, let i = all.firstIndex(where: { $0 === me }), all.count > 1 else { return }
        var j = i
        for _ in 0..<all.count {
            j = (j + dir + all.count) % all.count
            let c = all[j]
            if shownOnly && c.presentingWindow?.isMiniaturized == true { continue }
            WindowMenuController.bringToFront(c)
            return
        }
    }

    private func sendKey(_ b: [UInt8]) {
        clearSelection()
        scrollToBottom()
        onSendBytes?(b)
    }

    private func controlCode(_ c: Unicode.Scalar) -> UInt8? {
        switch c {
        case "a"..."z": return UInt8(c.value - 0x60)
        case "A"..."Z": return UInt8(c.value - 0x40)
        case "@", " ", "2": return 0
        case "[", "3": return 27
        case "\\", "¥", "4": return 28
        case "]", "5": return 29
        case "^", "6": return 30
        case "_", "-", "7": return 31
        case "?", "8": return 127
        default: return nil
        }
    }

    /// Mac 版の追加: キーマップにも VKey2KeyStr にもない修飾キー付きの特殊キーは xterm の書き方で送る
    /// (Shift+矢印 → ESC[1;2A など)。Tab / Shift+Tab と、Shift+PageUp/PageDown のスクロールもここ
    private func xtermModifiedKey(_ e: NSEvent) -> Bool {
        let m = e.modifierFlags
        if m.contains(.command) { return false }
        var mod = 1
        if m.contains(.shift) { mod += 1 }
        if m.contains(.option) { mod += 2 }
        if m.contains(.control) { mod += 4 }
        let appC = term.appCursor && !settings.disableAppCursor
        func csi(_ s: String) -> [UInt8] { Array("\u{1B}[\(s)".utf8) }
        func cursorKey(_ c: String) -> [UInt8] {
            if mod > 1 { return csi("1;\(mod)\(c)") }
            return Array((appC ? "\u{1B}O" : "\u{1B}[").utf8) + Array(c.utf8)
        }
        func tilde(_ n: Int) -> [UInt8] { mod > 1 ? csi("\(n);\(mod)~") : csi("\(n)~") }
        func ss3(_ c: String) -> [UInt8] { mod > 1 ? csi("1;\(mod)\(c)") : Array("\u{1B}O\(c)".utf8) }
        var seq: [UInt8]?
        switch e.keyCode {
        case 48:
            if m.contains(.shift) && !m.contains(.control) { seq = csi("Z") }
            else if !m.contains(.control) { seq = isMeta(e) ? [0x1B, 0x09] : [0x09] }
        case 117: seq = tilde(3)
        case 123: seq = cursorKey("D")
        case 124: seq = cursorKey("C")
        case 125: seq = cursorKey("B")
        case 126: seq = cursorKey("A")
        case 115: seq = cursorKey("H")
        case 119: seq = cursorKey("F")
        case 116:
            if m.contains(.shift) { scrollBy(term.rows - 1); return true }
            seq = tilde(5)
        case 121:
            if m.contains(.shift) { scrollBy(-(term.rows - 1)); return true }
            seq = tilde(6)
        case 114: seq = tilde(2)
        case 122: seq = ss3("P")
        case 120: seq = ss3("Q")
        case 99: seq = ss3("R")
        case 118: seq = ss3("S")
        case 96: seq = tilde(15)
        case 97: seq = tilde(17)
        case 98: seq = tilde(18)
        case 100: seq = tilde(19)
        case 101: seq = tilde(20)
        case 109: seq = tilde(21)
        case 103: seq = tilde(23)
        case 111: seq = tilde(24)
        default: break
        }
        guard let s = seq else { return false }
        sendKey(s)
        return true
    }

    // MARK: - NSTextInputClient (日本語入力)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // 変換中の文字があったときだけ描き直す (ふつうのキーで毎回全体を描くと、返ってきた文字を描くのが 1 回遅れる)
        if marked != nil { marked = nil; needsDisplay = true }
        guard !s.isEmpty, !TerminalView.isFunctionKeyText(s) else { return }
        latencyMarkSent()
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

    /// 日本語入力に渡す前後の文字 (vtwin.cpp ReplyIMERequestDocumentfeed の IMR_DOCUMENTFEED。4.106):
    /// カーソルのある行の、行頭からカーソルまでと、カーソルから後ろの空白の手前まで (後ろに空白がなければカーソルまで)。
    /// 変換中の文字はカーソルの位置に入れる。before はカーソルまでの文字 (UTF-16 の長さが選択の位置)
    private func imeDocument() -> (before: String, after: String) {
        guard term.cy >= 0 && term.cy < term.rows else { return ("", "") }
        let cells = term.lines[term.cy].cells
        let cx = min(term.cx, cells.count)
        var before = "", after = ""
        for c in cells[..<cx] where c.width != 0 { before.append(c.ch) }
        var tail = ""
        var found = false
        for c in cells[cx...] where c.width != 0 {
            if c.ch == " " || c.ch == "\0" { found = true; break }
            tail.append(c.ch)
        }
        if found { after = tail }
        return (before, after)
    }

    /// 文書 (imeDocument) の中の位置。再変換で前の文字を置き換えることはできない (送ってしまっている) ので、範囲を返すだけ
    func selectedRange() -> NSRange {
        let base = imeDocument().before.utf16.count
        if let m = marked, m.length > 0 {
            let loc = min(max(0, markedSel.location), m.length)
            return NSRange(location: base + loc, length: min(markedSel.length, m.length - loc))
        }
        return NSRange(location: base, length: 0)
    }
    func markedRange() -> NSRange {
        guard let m = marked, m.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: imeDocument().before.utf16.count, length: m.length)
    }
    func hasMarkedText() -> Bool { (marked?.length ?? 0) > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let d = imeDocument()
        let doc = (d.before + (marked?.string ?? "") + d.after) as NSString
        guard range.location != NSNotFound, range.location <= doc.length else { return nil }
        let r = NSRange(location: range.location, length: min(range.length, doc.length - range.location))
        actualRange?.pointee = r
        return NSAttributedString(string: doc.substring(with: r))
    }
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

    /// vtwin.cpp OnMouseWheel: 1 ノッチで MouseWheelScrollLine 行
    override func scrollWheel(with event: NSEvent) {
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            dy /= cellH
        } else if dy != 0 {
            let notches = max(1, Int(abs(dy).rounded()))
            dy = CGFloat((notches == 1 ? max(1, settings.mouseWheelScrollLine) : notches) * (dy < 0 ? -1 : 1))
        }
        accumScroll += dy
        let n = Int(accumScroll)
        guard n != 0 else { return }
        accumScroll -= CGFloat(n)
        if trackingMouse(event) {
            let p = cellAt(event)
            if event.hasPreciseScrollingDeltas {
                for _ in 0..<abs(n) { sendMouse(button: n > 0 ? 64 : 65, x: p.col, y: p.row, press: true, event: event) }
            } else {
                sendMouse(button: n > 0 ? 64 : 65, x: p.col, y: p.row, press: true, event: event)
            }
            return
        }
        if term.usingAlt {
            // vim / less などではスクロールを矢印キーとして送る
            let appC = term.appCursor && !settings.disableAppCursor
            let key: [UInt8] = Array((appC ? "\u{1B}O" : "\u{1B}[").utf8) + [n > 0 ? 0x41 : 0x42]
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

    /// 選択の始点・終点にする文字の境目 (buffer.c GetCharCell)。
    /// 全角 (2 セル) の文字は、文字全体のどちらの半分を押したかで文字の先頭か次の文字にし、全角を途中で分けない
    private func posAt(_ e: NSEvent) -> Pos {
        let c = cellAt(e)
        let idx = firstLineIndex + c.row
        var col = c.col
        let cells = idx >= 0 && idx < term.totalLines ? term.line(at: idx).cells : []
        if col < cells.count && col < term.cols {
            var xChar = col                                  // 文字の先頭
            while xChar > 0 && cells[xChar].width == 0 { xChar -= 1 }
            let cell = max(1, Int(cells[xChar].width))
            if cell % 2 == 0 {
                // 偶数長 cell の文字 (全角): 文字の中央より右なら次の文字
                col = col - xChar >= cell / 2 ? xChar + cell : xChar
            } else {
                // 奇数長 cell の文字 (半角): 真ん中の cell なら、その cell のどちらの半分か
                let xTh = xChar + (cell + 1) / 2 - 1
                if col == xTh { col = c.half ? xChar + cell : xChar }
                else { col = col < xTh ? xChar : xChar + cell }
            }
            col = min(term.cols, col)
        } else {
            col = c.half ? min(term.cols, c.col + 1) : c.col
        }
        return Pos(line: lineBase + idx, col: col)
    }

    /// 押したセル (半分より右でも次の桁にしない)
    private func cellPosAt(_ e: NSEvent) -> Pos {
        let c = cellAt(e)
        return Pos(line: lineBase + firstLineIndex + c.row, col: min(c.col, term.cols - 1))
    }

    /// マウスを端末に送るか (vtterm.c MouseReport): MouseEventTracking がオンで、相手が求めていて、
    /// DisableMouseTrackingByCtrl なら Ctrl を押していないとき。Mac 版では Shift を押しても送らない (xterm と同じ)
    private func trackingMouse(_ e: NSEvent) -> Bool {
        guard settings.mouseEventTracking, term.mouseMode != 0 else { return false }
        let m = e.modifierFlags
        if settings.disableMouseTrackingByCtrl && m.contains(.control) { return false }
        if m.contains(.shift) { return false }
        return true
    }

    private func sendMouse(button: Int, x: Int, y: Int, press: Bool, event: NSEvent? = nil) {
        var b = button
        if let m = event?.modifierFlags {
            // MouseReport: Shift = 4, Alt (Option) = 8, Ctrl = 16
            if m.contains(.shift) { b |= 4 }
            if m.contains(.option) { b |= 8 }
            if m.contains(.control) { b |= 16 }
        }
        if term.mouseSGRPixels, let e = event {
            // SGR-Pixels (MouseReport の IdMouseTrackExtSGRP): 文字の位置ではなくウインドウの中の点の座標 (1 未満は 1)
            let p = convert(e.locationInWindow, from: nil)
            let px = max(1, Int(p.x.rounded(.down))), py = max(1, Int(p.y.rounded(.down)))
            onSendBytes?(Array("\u{1B}[<\(b);\(px);\(py)\(press ? "M" : "m")".utf8))
        } else if term.mouseSGR {
            onSendBytes?(Array("\u{1B}[<\(b);\(x + 1);\(y + 1)\(press ? "M" : "m")".utf8))
        } else {
            let v = press ? b : (3 | (b & 0x1C))
            onSendBytes?([0x1B, 0x5B, 0x4D, UInt8(min(255, 32 + v)), UInt8(min(255, 33 + x)), UInt8(min(255, 33 + y))])
        }
    }

    private func reportPress(_ event: NSEvent, button: Int) -> Bool {
        guard trackingMouse(event) else { return false }
        let c = cellAt(event)
        mouseReporting = true
        reportButton = button
        sendMouse(button: button, x: min(c.col, term.cols - 1), y: c.row, press: true, event: event)
        return true
    }

    private func reportDrag(_ event: NSEvent) {
        if term.mouseMode >= 1002 {
            let c = cellAt(event)
            sendMouse(button: 32 + reportButton, x: min(c.col, term.cols - 1), y: c.row, press: true, event: event)
        }
    }

    private func reportRelease(_ event: NSEvent) {
        let c = cellAt(event)
        sendMouse(button: reportButton, x: min(c.col, term.cols - 1), y: c.row, press: false, event: event)
        mouseReporting = false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportPress(event, button: 0) { return }
        mouseReporting = false
        // クリッカブル URL: URL をダブルクリック (buffer.c BuffUrlDblClk)。Mac 版は ⌘-クリックでも開く
        if settings.enableClickableUrl && (event.clickCount == 2 || event.modifierFlags.contains(.command)),
           let u = urlAt(cellPosAt(event)) {
            clearSelection()
            openURL(u)
            return
        }
        let p = posAt(event)
        selMode = min(3, event.clickCount)
        if selMode == 1 {
            if event.modifierFlags.contains(.shift), selAnchor != nil {
                shiftClickSelect(p)
            } else {
                selAnchor = p; selHead = p
            }
        } else if selMode == 2 {
            let (s, e) = wordBounds(cellPosAt(event))
            selAnchor = s; selHead = e
            dblClkStart = s; dblClkEnd = e
        } else {
            selAnchor = Pos(line: p.line, col: 0); selHead = Pos(line: p.line, col: term.cols)
        }
        needsDisplay = true
    }

    /// Shift+左クリック (buffer.c BuffSeveralPagesSelect。4c86d4c32 / 6904b8aca #903):
    /// 選んでいなければ前にクリックした所からクリックした所まで。選んでいれば、選択より前なら始まりを、
    /// 後ろなら終わりを、中ならクリックした所に近い端を動かす。動かした端がこのあとのドラッグで動く側 (SelectEnd)
    private func shiftClickSelect(_ p: Pos) {
        guard let a = selAnchor else { selAnchor = p; selHead = p; return }
        guard let h = selHead, a != h else { selHead = p; return }   // 選んでいない: ClickCell から
        let s = min(a, h), e = max(a, h)
        // ComparePoint: 2 点のあいだの文字数 (行は桁数ぶん)
        func dist(_ p1: Pos, _ p2: Pos) -> Int { (p1.line - p2.line) * term.cols + (p1.col - p2.col) }
        if p < s {
            selAnchor = e                    // 開始位置より前方: 開始位置を動かす
        } else if e < p {
            selAnchor = s                    // 終了位置より後方: 終了位置を動かす
        } else {
            selAnchor = dist(p, s) < dist(e, p) ? e : s   // 選択の中: 近いほう
        }
        selHead = p
    }

    private func extendSelection(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y < 0 { scrollBy(1) } else if p.y > bounds.height { scrollBy(-1) }
        var pos = posAt(event)
        if selMode == 2, let ds = dblClkStart, let de = dblClkEnd {
            // ダブルクリック後のドラッグ (buffer.c BuffChangeSelect NClick == 2):
            // 単語より前なら単語の終わりを、後ろなら単語の始まりを起点にし、動く側は単語の境目まで広げる
            let cp = cellPosAt(event)
            if cp < ds {
                selAnchor = de; pos = wordBounds(cp).0
            } else if !(cp < de) {
                selAnchor = ds; pos = wordBounds(cp).1
            } else {
                selAnchor = ds; pos = de
            }
        } else if selMode == 3 {
            pos.col = pos < (selAnchor ?? pos) ? 0 : term.cols
        }
        selHead = pos
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseReporting { reportDrag(event); return }
        extendSelection(event)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseReporting { reportRelease(event); return }
        if settings.copyOnSelect, selectionRange() != nil { copy(nil) }
    }

    /// 右ボタン (vtwin.cpp ButtonDown / OnRButtonUp)
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if reportPress(event, button: 2) { return }
        mouseReporting = false
        if settings.rightClickPaste {
            // ConfirmPasteMouseRButton: 貼り付け / 貼り付け<CR> のメニューを出す (メニューから選んだときだけ貼り付ける)
            if settings.confirmPasteMouseRButton {
                if (canPaste?() ?? true) && NSPasteboard.general.string(forType: .string) != nil {
                    let m = NSMenu()
                    m.autoenablesItems = false
                    m.addItem(withTitle: Lang.t("Tera Term", "MENU_EDIT_PASTE", "貼り付け"), action: #selector(paste(_:)), keyEquivalent: "").target = self
                    m.addItem(withTitle: Lang.t("Tera Term", "MENU_EDIT_PASTECR", "貼り付け<CR>"), action: #selector(pasteCR(_:)), keyEquivalent: "").target = self
                    NSMenu.popUpContextMenu(m, with: event, for: self)
                }
                return
            }
            beginOtherSelection(event)
            return
        }
        if !settings.selectOnlyByLButton { beginOtherSelection(event); return }
        super.rightMouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if mouseReporting { reportDrag(event); return }
        if otherSelecting { extendSelection(event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if mouseReporting { reportRelease(event); return }
        endOtherSelection()
        if settings.rightClickPaste && !settings.confirmPasteMouseRButton && (canPaste?() ?? true) {
            startPaste(addCR: false)
        }
    }

    /// 中ボタン (OnMButtonDown / OnMButtonUp)。DisablePasteMouseMButton がオフなら離したときに貼り付ける
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        if reportPress(event, button: 1) { return }
        mouseReporting = false
        beginOtherSelection(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if mouseReporting { reportDrag(event); return }
        if otherSelecting { extendSelection(event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        if mouseReporting { reportRelease(event); return }
        endOtherSelection()
        if !settings.disablePasteMouseMButton && (canPaste?() ?? true) { startPaste(addCR: false) }
    }

    /// SelectOnlyByLButton がオフなら中・右ボタンでも選択を始める
    private func beginOtherSelection(_ event: NSEvent) {
        otherSelecting = false
        guard !settings.selectOnlyByLButton else { return }
        let p = posAt(event)
        selMode = 1
        selAnchor = p; selHead = p
        otherSelecting = true
        needsDisplay = true
    }

    private func endOtherSelection() {
        guard otherSelecting else { return }
        otherSelecting = false
        if settings.copyOnSelect, selectionRange() != nil { copy(nil) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if settings.rightClickPaste || !settings.selectOnlyByLButton { return nil }
        let m = NSMenu()
        m.addItem(withTitle: Lang.t("Tera Term", "MENU_EDIT_COPY", "コピー"), action: #selector(copy(_:)), keyEquivalent: "")
        m.addItem(withTitle: Lang.t("Tera Term", "MENU_EDIT_PASTE", "貼り付け"), action: #selector(paste(_:)), keyEquivalent: "")
        m.addItem(withTitle: Lang.t("Tera Term", "MENU_EDIT_PASTECR", "貼り付け<CR>"), action: #selector(pasteCR(_:)), keyEquivalent: "")
        return m
    }

    // MARK: - マウスカーソル (MouseCursor、URL の上では HAND)

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    private var baseCursor: NSCursor {
        switch settings.mouseCursor.uppercased() {
        case "ARROW": return .arrow
        case "CROSS": return .crosshair
        case "HAND": return .pointingHand
        default: return .iBeam
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: baseCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(event)
    }

    private func updateCursor(_ event: NSEvent) {
        if settings.enableClickableUrl, urlAt(cellPosAt(event)) != nil {
            NSCursor.pointingHand.set()
        } else {
            baseCursor.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        // 1003 (any event): ボタンを押していなくても動きを送る
        if term.mouseMode == 1003 && trackingMouse(event) {
            let c = cellAt(event)
            sendMouse(button: 35, x: min(c.col, term.cols - 1), y: c.row, press: true, event: event)
        }
        updateCursor(event)
    }

    // MARK: - 単語の選択 (buffer.c BuffDblClk / SearchDelimiterPrev / SearchDelimiterNext)

    /// 区切り文字 (DelimList)。DelimDBCS (オン) と同じく、半角と全角の境目でも区切る
    private func wordBounds(_ p: Pos) -> (Pos, Pos) {
        var idx = p.line - lineBase
        guard idx >= 0 && idx < term.totalLines else { return (p, p) }
        var cells = term.line(at: idx).cells
        guard !cells.isEmpty else { return (p, p) }
        var x = min(max(0, p.col), cells.count - 1)
        while x > 0 && cells[x].width == 0 { x -= 1 }   // 全角の右半分なら左半分から
        let startCh = cells[x].ch
        let startDelim = isDelimiter(startCh)
        let startWide = cells[x].width == 2
        func stop(_ c: Cell) -> Bool {
            if startDelim { return c.ch != startCh }
            return isDelimiter(c.ch) || ((c.width == 2) != startWide)
        }
        let cont = settings.continuedLineCopy
        // 前へ
        var sIdx = idx, sx = x
        while true {
            var px = sx - 1
            while px >= 0 && cells[px].width == 0 { px -= 1 }
            if px < 0 {
                // 前の行から続いている (継続行コピーのとき)
                guard cont, sIdx > 0, term.line(at: sIdx - 1).wrapped else { break }
                let prev = term.line(at: sIdx - 1).cells
                var qx = prev.count - 1
                while qx > 0 && prev[qx].width == 0 { qx -= 1 }
                guard qx >= 0, !stop(prev[qx]) else { break }
                sIdx -= 1; cells = prev; sx = qx
                continue
            }
            if stop(cells[px]) { break }
            sx = px
        }
        // 後ろへ
        idx = p.line - lineBase
        cells = term.line(at: idx).cells
        var eIdx = idx, ex = x
        while true {
            var nx = ex + max(1, Int(cells[ex].width))
            if nx >= cells.count {
                guard cont, term.line(at: eIdx).wrapped, eIdx + 1 < term.totalLines else { break }
                let next = term.line(at: eIdx + 1).cells
                guard !next.isEmpty, !stop(next[0]) else { break }
                eIdx += 1; cells = next; ex = 0
                continue
            }
            while nx < cells.count && cells[nx].width == 0 { nx += 1 }
            if nx >= cells.count || stop(cells[nx]) { break }
            ex = nx
        }
        let endCol = ex + max(1, Int(cells[ex].width))
        return (Pos(line: lineBase + sIdx, col: sx), Pos(line: lineBase + eIdx, col: endCol))
    }

    private func isDelimiter(_ ch: Character) -> Bool {
        delimChars.contains(ch)
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

    /// iswcntrl (Windows の _CONTROL): U+0000〜001F・U+007F〜009F
    static func isWControl(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x20 || (0x7F...0x9F).contains(u.value)
    }

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
        // ブラケットするかどうか (BracketedSupport / BracketedControlOnly)。制御文字は iswcntrl と同じ C0・DEL・C1
        // (CharacterSet.controlCharacters は書式文字 Cf も含むので使わない)。複数行なら改行が制御文字
        let addBracket = settings.bracketedSupport
            && (!settings.bracketedControlOnly || s.unicodeScalars.contains { TerminalView.isWControl($0) })
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
