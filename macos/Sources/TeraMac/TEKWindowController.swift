import AppKit
import TeraCore

// TEK ウインドウ (tekwin.cpp CTEKWindow + tttek.c の画面まわり)。
// 受信は TEKParser が読み、描いたもの (TEKDrawOp) をこのウインドウのビットマップ (Tera Term の MemDC) に描く。
// キーボードの入力は VT ウインドウと同じ接続へ送る

/// ts の TEK まわりの設定 (TERATERM.INI の TEKColor / TEKColorEmulation / TEKFont / TEKGINMouseCode)
struct TEKWindowSettings {
    var foreColor: UInt32 = 0x000000
    var backColor: UInt32 = 0xFFFFFF
    var colorEmulation = false
    var ginMouseCode: UInt8 = 32
    var fontName = "Courier"
    var fontSize: CGFloat = 13

    /// Tera Term の ts はアプリ全体で 1 つ。設定 → ウィンドウ / フォント で変えたものは次の TEK ウインドウにも効く
    static var shared: TEKWindowSettings = load()

    static func load() -> TEKWindowSettings {
        var s = TEKWindowSettings()
        for p in FileTransferOptions.teraTermIniCandidates() {
            guard let d = FileManager.default.contents(atPath: p), let ini = IniFile(data: d) else { continue }
            let sec = "Tera Term"
            if let c = ini.ints(sec, "TEKColor"), c.count >= 6 {
                s.foreColor = UInt32((c[0] & 255) << 16 | (c[1] & 255) << 8 | (c[2] & 255))
                s.backColor = UInt32((c[3] & 255) << 16 | (c[4] & 255) << 8 | (c[5] & 255))
            }
            if let v = ini.onOff(sec, "TEKColorEmulation") { s.colorEmulation = v }
            if let v = ini.int(sec, "TEKGINMouseCode") { s.ginMouseCode = UInt8(truncatingIfNeeded: v) }
            // TEKFont=Courier,0,-13,0 (名前, 幅, 高さ, 文字セット)
            if let f = ini.string(sec, "TEKFont") {
                let parts = f.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if let n = parts.first, !n.isEmpty { s.fontName = n }
                if parts.count > 2, let h = Int(parts[2]), h != 0 { s.fontSize = CGFloat(abs(h)) }
            }
            break
        }
        return s
    }

    var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? NSFont.userFixedPitchFont(ofSize: fontSize) ?? NSFont.monoSystemFont(ofSize: fontSize, weight: .regular)
    }
}

extension NSColor {
    convenience init(tekRGB c: UInt32) {
        self.init(srgbRed: CGFloat((c >> 16) & 255) / 255, green: CGFloat((c >> 8) & 255) / 255,
                  blue: CGFloat(c & 255) / 255, alpha: 1)
    }
    var tekRGB: UInt32 {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        return UInt32(round(c.redComponent * 255)) << 16 | UInt32(round(c.greenComponent * 255)) << 8 | UInt32(round(c.blueComponent * 255))
    }
}

final class TEKWindowController: NSWindowController, NSWindowDelegate {
    /// VT ウインドウごとの TEK ウインドウ (HTEKWin)
    static var bySession: [ObjectIdentifier: TEKWindowController] = [:]
    static func of(_ s: SessionWindowController) -> TEKWindowController? { bySession[ObjectIdentifier(s)] }

    weak var session: SessionWindowController?
    let parser: TEKParser
    let tekView: TEKView
    private let bar = TEKMenuBar(frame: .zero)
    /// ActiveWin == IdTEK (受信を TEK が読む)
    var isActiveWin = true
    private var observers: [NSObjectProtocol] = []
    private var titleObservation: NSKeyValueObservation?
    /// 自分で大きさを変えている (AdjustSize)
    private var adjusting = false

    init(session: SessionWindowController) {
        self.session = session
        parser = TEKParser()
        tekView = TEKView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        super.init(window: w)
        w.delegate = self
        tekView.controller = self
        let content = TEKContainerView(bar: bar, view: tekView)
        w.contentView = content
        bar.controller = self
        parser.onBeep = { NSSound.beep() }
        parser.onSend = { [weak self] b in self?.session?.sendBytes(b, echo: false, binary: true) }
        applySettings()
        resizeWindow(scale: false)
        if let sw = session.window {
            // 位置は VT ウインドウの右下にずらす (TEKPos が既定 = おまかせ)
            w.setFrameTopLeftPoint(NSPoint(x: sw.frame.minX + 40, y: sw.frame.maxY - 40))
            titleObservation = sw.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.changeTitle() }
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: sw, queue: .main) { [weak self] _ in
                self?.isActiveWin = false   // CVTWindow::OnActivate: ActiveWin = IdVT
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: sw, queue: .main) { [weak self] _ in
                self?.close()   // VT ウインドウを閉じたら TEK も
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: InWindowMenuBar.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuBarChanged()
        })
        changeTitle()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// ChangeTitle: VT と同じタイトル (TitleFormat の 4 なら " TEK" を足す)
    func changeTitle() {
        guard let s = session, let sw = s.window else { return }
        window?.title = sw.title + ((s.settings.titleFormat & 4) != 0 ? " TEK" : "")
    }

    /// ts から TEKParser の設定へ
    func applySettings() {
        let t = TEKWindowSettings.shared
        var p = parser.settings
        p.foreColor = t.foreColor
        p.backColor = t.backColor
        p.colorEmulation = t.colorEmulation
        p.ginMouseCode = t.ginMouseCode
        if let s = session {
            p.autoWinSwitch = s.settings.autoWinSwitch
            p.crReceiveCRLF = s.term.recvCRasCRLF
            p.beep = s.settings.beep.lowercased() != "off"
        }
        parser.settings = p
    }

    // MARK: - 受信

    /// TEKParse。VT に戻るなら残りを返す
    func feed(_ bytes: [UInt8]) -> [UInt8]? {
        applySettings()
        let rest = parser.feed(bytes)
        tekView.apply(parser.takeOps())
        return rest
    }

    // MARK: - 大きさ (TEKResizeWindow / TEKWMSize)

    /// メニューバーの高さ (幅が足りなければ折り返す。InWindowMenuBar.currentHeight(forWidth:) の TEK 版)
    private func barHeight(forWidth w: CGFloat) -> CGFloat { InWindowMenuBar.isShown ? TEKMenuBar.barHeight(forWidth: w, labels: menus.map { $0.label }) : 0 }

    /// scale = false: フォントから画面の大きさを決めてウインドウを合わせる。true: 今の大きさから字の大きさを決める
    func resizeWindow(scale: Bool) {
        let font = TEKWindowSettings.shared.font
        let fw0 = max(1, Int(round(font.advancement(forGlyph: font.glyph(withName: "zero")).width)))
        let fh0 = max(1, Int(ceil(font.ascender - font.descender + font.leading)))
        let cur = tekView.bounds.size
        let l = TEKParser.layout(scale: scale, baseFW: fw0, baseFH: fh0, width: Int(cur.width), height: Int(cur.height))
        parser.resize(width: l.width, height: l.height, fw: l.fw, fh: l.fh)
        tekView.makeBitmap(width: l.width, height: l.height)
        tekView.apply(parser.takeOps())
        if !scale, let w = window {
            adjusting = true
            let top = w.frame.maxY
            w.setContentSize(NSSize(width: CGFloat(l.width), height: CGFloat(l.height) + barHeight(forWidth: CGFloat(l.width))))
            w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX, y: top))
            adjusting = false
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard !adjusting, let w = window, !w.inLiveResize else { return }
        userResized()
    }
    func windowDidEndLiveResize(_ notification: Notification) { userResized() }

    private func userResized() {
        let sz = tekView.bounds.size
        guard Int(sz.width) != parser.screenWidth || Int(sz.height) != parser.screenHeight,
              sz.width >= 1, sz.height >= 1 else { return }
        resizeWindow(scale: true)   // ScaleFont = TRUE (画面は消える)
    }

    private func menuBarChanged() {
        guard let w = window, let c = w.contentView as? TEKContainerView else { return }
        let show = InWindowMenuBar.isShown
        guard show == c.bar.isHidden else { return }
        c.bar.isHidden = !show
        adjusting = true
        let top = w.frame.maxY
        w.setContentSize(NSSize(width: CGFloat(parser.screenWidth), height: CGFloat(parser.screenHeight) + barHeight(forWidth: CGFloat(parser.screenWidth))))
        w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX, y: top))
        c.layoutChildren()
        adjusting = false
    }

    // MARK: - ウインドウ

    func windowDidBecomeKey(_ notification: Notification) {
        isActiveWin = true   // CTEKWindow::OnActivate: ActiveWin = IdTEK
        tekView.needsDisplay = true
    }
    func windowDidResignKey(_ notification: Notification) { tekView.needsDisplay = true }

    func windowWillClose(_ notification: Notification) {
        // OnDestroy: HTEKWin = NULL, ActiveWin = IdVT
        if let s = session { Self.bySession[ObjectIdentifier(s)] = nil }
        titleObservation = nil
    }

    // MARK: - メニュー (IDR_TEKMENU)

    @objc func filePrint(_ sender: Any?) {
        guard let img = tekView.image(selectionOnly: tekView.select) else { return }
        let iv = NSImageView(frame: NSRect(origin: .zero, size: img.size))
        iv.image = img
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let op = NSPrintOperation(view: iv, printInfo: info)
        op.jobTitle = session?.localTitle ?? "Tera Term"
        if let w = window { op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() }
    }

    @objc func fileExit(_ sender: Any?) { close() }

    @objc func editCopy(_ sender: Any?) {
        guard tekView.select, let img = tekView.image(selectionOnly: true) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    @objc func editCopyScreen(_ sender: Any?) {
        guard let img = tekView.image(selectionOnly: false) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    @objc func editPaste(_ sender: Any?) { session?.termView.startPaste(addCR: false) }
    @objc func editPasteCR(_ sender: Any?) { session?.termView.startPaste(addCR: true) }

    @objc func editClearScreen(_ sender: Any?) {
        parser.clearScreen()
        tekView.apply(parser.takeOps())
    }

    /// 設定 → ウィンドウ (OpenSetupTekWindow): 文字色・背景色・カラーエミュレーション
    @objc func setupWindow(_ sender: Any?) {
        guard let w = window else { return }
        var t = TEKWindowSettings.shared
        let alert = NSAlert()
        alert.messageText = Lang.t("Tera Term", "DLG_WIN_TEK_TITLE", "TEK ウィンドウの設定")
        alert.addButton(withTitle: Lang.t("Tera Term", "BTN_OK", "OK"))
        alert.addButton(withTitle: Lang.t("Tera Term", "BTN_CANCEL", "キャンセル"))
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 90))
        func label(_ s: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.frame = NSRect(x: 0, y: y, width: 120, height: 20)
            v.addSubview(l)
        }
        label(Lang.m("CONN_TEK_TEXT_COLOR", "文字色:"), 62)
        label(Lang.m("CONN_TEK_BG_COLOR", "背景色:"), 34)
        let fg = NSColorWell(frame: NSRect(x: 130, y: 60, width: 50, height: 24))
        fg.color = NSColor(tekRGB: t.foreColor)
        let bg = NSColorWell(frame: NSRect(x: 130, y: 32, width: 50, height: 24))
        bg.color = NSColor(tekRGB: t.backColor)
        let emu = NSButton(checkboxWithTitle: Lang.t("Tera Term", "DLG_WIN_COLOREMU", "カラーエミュレーション(&E)").trimmingCharacters(in: CharacterSet(charactersIn: ":：")), target: nil, action: nil)
        emu.frame = NSRect(x: 0, y: 2, width: 260, height: 20)
        emu.state = t.colorEmulation ? .on : .off
        [fg, bg, emu].forEach { v.addSubview($0) }
        alert.accessoryView = v
        alert.beginSheetModal(for: w) { [weak self] r in
            NSColorPanel.shared.orderOut(nil)
            guard r == .alertFirstButtonReturn, let self = self else { return }
            let oldEmu = t.colorEmulation
            t.foreColor = fg.color.tekRGB
            t.backColor = bg.color.tekRGB
            t.colorEmulation = emu.state == .on
            TEKWindowSettings.shared = t
            self.applySettings()
            // OnSetupPostProcess: TEKResetWin → TEKSetupFont
            self.parser.resetWin(oldColorEmulation: oldEmu)
            self.tekView.apply(self.parser.takeOps())
            self.parser.resetTextSize()
            self.resizeWindow(scale: false)
        }
    }

    /// 設定 → フォント (OpenSetupTekFont)
    @objc func setupFont(_ sender: Any?) {
        let fm = NSFontManager.shared
        fm.target = self
        fm.action = #selector(changeTEKFont(_:))
        fm.setSelectedFont(TEKWindowSettings.shared.font, isMultiple: false)
        fm.orderFrontFontPanel(self)
    }

    @objc func changeTEKFont(_ sender: Any?) {
        guard let fm = sender as? NSFontManager else { return }
        let f = fm.convert(TEKWindowSettings.shared.font)
        TEKWindowSettings.shared.fontName = f.fontName
        TEKWindowSettings.shared.fontSize = f.pointSize
        parser.resetTextSize()   // TEKSetupFont
        resizeWindow(scale: false)
    }

    /// VT-ウィンドウ (VTActivate)
    @objc func vtWindow(_ sender: Any?) { session?.tekActivateVT() }

    @objc func helpIndex(_ sender: Any?) { HelpViewer.openIndex() }
    @objc func helpAbout(_ sender: Any?) { AboutWindowController.shared.show() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { validate(item) }

    func validate(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(editCopy(_:)):
            return tekView.select
        case #selector(editPaste(_:)), #selector(editPasteCR(_:)):
            guard let s = session else { return false }
            return s.canPaste && NSPasteboard.general.string(forType: .string) != nil
        default:
            return true
        }
    }

    /// TEK のメニュー (ファイル・編集・設定・VT-ウィンドウ・ウィンドウ・ヘルプ)
    lazy var menus: [(label: String, key: String, menu: NSMenu?, action: Selector?)] = {
        func m(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            return menu
        }
        func it(_ t: String, _ a: Selector, _ k: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = [.option]
            i.target = self
            return i
        }
        /// メニューバーの見出し。本家の文言が "ファイル(&F)" の形なら "(F)" を残す (英語の "&File" なら "File")
        func top(_ key: String, _ def: String) -> String {
            let s = Lang.t("Tera Term", key, def)
            let raw = Lang.raw("Tera Term", key) ?? def
            guard let r = raw.range(of: "\\([&＆][^)）]\\)", options: .regularExpression) else { return s }
            return s + "(" + String(raw[r].dropFirst(2).prefix(1)) + ")"
        }
        let win = NSMenu(title: Lang.t("Tera Term", "TEKMENU_WINDOW", "ウィンドウ"))
        win.delegate = WindowMenuController.shared
        return [
            (top("TEKMENU_FILE", "ファイル(&F)"), "f", m(Lang.t("Tera Term", "TEKMENU_FILE", "ファイル"), [it(Lang.t("Tera Term", "TEKMENU_FILE_PRINT", "印刷..."), #selector(filePrint(_:)), "p"), .separator(),
                                              it(Lang.t("Tera Term", "TEKMENU_FILE_EXIT", "終了"), #selector(fileExit(_:)), "q")]), nil),
            (top("TEKMENU_EDIT", "編集(&E)"), "e", m(Lang.t("Tera Term", "TEKMENU_EDIT", "編集"), [it(Lang.t("Tera Term", "TEKMENU_EDIT_COPY", "コピー"), #selector(editCopy(_:)), "c"), it(Lang.t("Tera Term", "TEKMENU_EDIT_COPYSCREEN", "画面のコピー"), #selector(editCopyScreen(_:))),
                                      it(Lang.t("Tera Term", "TEKMENU_EDIT_PASTE", "貼り付け"), #selector(editPaste(_:)), "v"), it(Lang.t("Tera Term", "TEKMENU_EDIT_PASTECR", "貼り付け<CR>"), #selector(editPasteCR(_:)), "r"),
                                      .separator(), it(Lang.t("Tera Term", "TEKMENU_EDIT_CLSCREEN", "画面のクリア"), #selector(editClearScreen(_:)))]), nil),
            (top("TEKMENU_SETUP", "設定(&S)"), "s", m(Lang.t("Tera Term", "TEKMENU_SETUP", "設定"), [it(Lang.t("Tera Term", "TEKMENU_SETUP_WINDOW", "ウィンドウ..."), #selector(setupWindow(_:))), it(Lang.t("Tera Term", "TEKMENU_SETUP_FONT", "フォント..."), #selector(setupFont(_:)))]), nil),
            (top("TEKMENU_VTWIN", "VT-ウィンドウ(&O)"), "o", nil, #selector(vtWindow(_:))),
            (top("TEKMENU_WINDOW", "ウィンドウ(&W)"), "w", win, nil),
            (top("TEKMENU_HELP", "ヘルプ(&H)"), "h", m(Lang.t("Tera Term", "TEKMENU_HELP", "ヘルプ"), [it(Lang.t("Tera Term", "TEKMENU_HELP_INDEX", "目次"), #selector(helpIndex(_:))), .separator(),
                                         it(Lang.t("Tera Term", "TEKMENU_HELP_ABOUT", "Tera Termについて..."), #selector(helpAbout(_:)))]), nil),
        ]
    }()

    /// Ctrl+左クリック (メニューバーを隠しているとき) のメニュー全体
    func fullPopupMenu() -> NSMenu {
        let m = NSMenu()
        for e in menus {
            if let sub = e.menu {
                let top = NSMenuItem(title: e.label, action: nil, keyEquivalent: "")
                top.submenu = sub.copy() as? NSMenu
                m.addItem(top)
            } else if let a = e.action {
                let i = NSMenuItem(title: e.label, action: a, keyEquivalent: "")
                i.target = self
                m.addItem(i)
            }
        }
        return m
    }

    /// Alt+○ (アクセラレータとメニューを開く)
    func handleOptionKey(_ ev: NSEvent) -> Bool {
        guard ev.modifierFlags.intersection([.command, .control, .option, .shift]) == [.option],
              let ch = ev.charactersIgnoringModifiers?.lowercased() else { return false }
        for e in menus {
            guard let menu = e.menu else { continue }
            for item in menu.items where item.keyEquivalent == ch && item.action != nil {
                if validate(item) { NSApp.sendAction(item.action!, to: self, from: item) } else { NSSound.beep() }
                return true
            }
        }
        if !bar.isHidden, let i = menus.firstIndex(where: { $0.key == ch }) {
            DispatchQueue.main.async { self.bar.open(i) }
            return true
        }
        return false
    }
}

// MARK: - メニューバー (ウインドウの中。InWindowMenuBar と同じ見た目)

final class TEKMenuBar: NSView {
    weak var controller: TEKWindowController?
    private let font = NSFont.menuFont(ofSize: 12)
    private var rects: [NSRect] = []
    private var pressed: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 題の並び (InWindowMenuBar.titleRects と同じく、幅が足りなければ折り返して段を増やす)
    static func titleRects(width: CGFloat, labels: [String]) -> [NSRect] {
        let font = NSFont.menuFont(ofSize: 12)
        var out: [NSRect] = []
        var x: CGFloat = 2, y: CGFloat = 0
        for l in labels {
            let w = ceil((l as NSString).size(withAttributes: [.font: font]).width) + 12
            if x > 2 && x + w > width - 2 { x = 2; y += InWindowMenuBar.height }
            out.append(NSRect(x: x, y: y, width: w, height: InWindowMenuBar.height))
            x += w
        }
        return out
    }

    static func barHeight(forWidth width: CGFloat, labels: [String]) -> CGFloat {
        (titleRects(width: width, labels: labels).last.map { $0.maxY } ?? InWindowMenuBar.height) + 1
    }

    var labels: [String] { controller?.menus.map { $0.label } ?? [] }
    func barHeight(forWidth w: CGFloat) -> CGFloat { Self.barHeight(forWidth: w, labels: labels) }

    private func layoutTitles() {
        rects = Self.titleRects(width: bounds.width, labels: labels)
    }

    override func draw(_ dirtyRect: NSRect) {
        layoutTitles()
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for (i, e) in (controller?.menus ?? []).enumerated() {
            let r = rects[i]
            if pressed == i { NSColor.controlAccentColor.withAlphaComponent(0.30).setFill(); r.fill() }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let s = e.label as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: r.minX + 6, y: r.midY - sz.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        layoutTitles()
        let p = convert(event.locationInWindow, from: nil)
        guard let i = rects.firstIndex(where: { $0.contains(p) }) else { return }
        open(i)
    }

    func open(_ i: Int) {
        guard let c = controller, i < c.menus.count else { return }
        layoutTitles()
        let e = c.menus[i]
        if let a = e.action {
            NSApp.sendAction(a, to: c, from: self)
            return
        }
        guard let menu = e.menu else { return }
        window?.makeKeyAndOrderFront(nil)
        pressed = i
        display()
        menu.popUp(positioning: nil, at: NSPoint(x: rects[i].minX, y: bounds.height), in: self)
        pressed = nil
        needsDisplay = true
    }
}

final class TEKContainerView: NSView {
    let bar: TEKMenuBar
    let view: TEKView

    init(bar: TEKMenuBar, view: TEKView) {
        self.bar = bar
        self.view = view
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        autoresizesSubviews = false
        addSubview(bar)
        addSubview(view)
        bar.isHidden = !InWindowMenuBar.isShown
        layoutChildren()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func layoutChildren() {
        let bh = bar.barHeight(forWidth: bounds.width)
        let h = bar.isHidden ? 0 : bh
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bh)
        view.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutChildren() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }
}

// MARK: - 画面 (MemDC + TEKPaint + マウス)

final class TEKView: NSView {
    weak var controller: TEKWindowController?
    private var ctx: CGContext?
    private var scale: CGFloat = 2
    private var bitmapSize = (w: 0, h: 0)
    private var caretOn = true
    private var caretTimer: Timer?

    // 範囲選択 (Select / SelectStart / SelectEnd)
    private(set) var select = false
    private var buttonDown = false
    private var selStart = NSPoint.zero
    private var selEnd = NSPoint.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self = self, self.window?.isKeyWindow == true else { return }
            self.caretOn.toggle()
            self.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { caretTimer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    private var parser: TEKParser? { controller?.parser }

    // MARK: ビットマップ

    func makeBitmap(width: Int, height: Int) {
        scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pw = max(1, Int(CGFloat(width) * scale)), ph = max(1, Int(CGFloat(height) * scale))
        ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        // 左上を原点、y を下向き (GDI と同じ)
        ctx?.translateBy(x: 0, y: CGFloat(ph))
        ctx?.scaleBy(x: scale, y: -scale)
        bitmapSize = (width, height)
        select = false
        needsDisplay = true
    }

    private func cg(_ c: UInt32) -> CGColor { NSColor(tekRGB: c).cgColor }

    /// 文字のフォント (TEKFont[size]): 字の枠 width × height に合わせる
    private func cellFont(width: Int, height: Int, base: NSFont) -> (NSFont, CGFloat) {
        let h0 = base.ascender - base.descender + base.leading
        let size = max(1, base.pointSize * CGFloat(height) / max(1, h0))
        let f = NSFont(descriptor: base.fontDescriptor, size: size) ?? base
        let adv = f.advancement(forGlyph: f.glyph(withName: "zero")).width
        let sx = adv > 0 ? CGFloat(width) / adv : 1
        return (f, sx)
    }

    func apply(_ ops: [TEKDrawOp]) {
        guard let ctx = ctx, !ops.isEmpty, let p = parser else { return }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        ctx.setShouldAntialias(false)
        let base = TEKWindowSettings.shared.font
        for op in ops {
            switch op {
            case .clear:
                ctx.setFillColor(cg(p.settings.backColor))
                ctx.fill(CGRect(x: 0, y: 0, width: bitmapSize.w, height: bitmapSize.h))
            case .line(let a, let b, let color, let style):
                ctx.setStrokeColor(cg(color))
                ctx.setLineWidth(1)
                switch style {
                case .solid: ctx.setLineDash(phase: 0, lengths: [])
                case .dot: ctx.setLineDash(phase: 0, lengths: [3, 3])
                case .dash: ctx.setLineDash(phase: 0, lengths: [18, 6])
                case .dashDot: ctx.setLineDash(phase: 0, lengths: [9, 6, 3, 6])
                case .dashDotDot: ctx.setLineDash(phase: 0, lengths: [9, 3, 3, 3, 3, 3])
                }
                ctx.beginPath()
                ctx.move(to: CGPoint(x: CGFloat(a.x) + 0.5, y: CGFloat(a.y) + 0.5))
                ctx.addLine(to: CGPoint(x: CGFloat(b.x) + 0.5, y: CGFloat(b.y) + 0.5))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            case .pixel(let pt, let color):
                ctx.setFillColor(cg(color))
                ctx.fill(CGRect(x: pt.x, y: pt.y, width: 1, height: 1))
            case .char(let b, let at, _, let w, let h, let color):
                let (f, sx) = cellFont(width: w, height: h, base: base)
                let s = String(Character(Unicode.Scalar(b)))   // ANSI (Latin-1)
                drawText(s, font: f, sx: sx, x: CGFloat(at.x), baselineY: CGFloat(at.y) + f.descender, color: color, angle: 0)
            case .marker(let code, let at, let color):
                let s = Self.symbolChar(code)
                let f = NSFont(descriptor: base.fontDescriptor, size: base.pointSize) ?? base
                let wdt = (s as NSString).size(withAttributes: [.font: f]).width
                let bottom = CGFloat(at.y) + CGFloat(p.markerH / 2)
                drawText(s, font: f, sx: 1, x: CGFloat(at.x) - wdt / 2, baselineY: bottom + f.descender, color: color, angle: 0)
            case .graphText(let bytes, let at, let w, let h, let adv, let angle, let color):
                let (f, sx) = cellFont(width: max(1, w), height: max(1, h), base: base)
                var x = CGFloat(0)
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(at.x), y: CGFloat(at.y))
                ctx.rotate(by: -CGFloat(angle) * .pi / 2)
                for b in bytes {
                    drawText(String(Character(Unicode.Scalar(b))), font: f, sx: sx, x: x, baselineY: 0, color: color, angle: 0)
                    x += CGFloat(adv)
                }
                ctx.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        caretOn = true
        needsDisplay = true
    }

    private func drawText(_ s: String, font: NSFont, sx: CGFloat, x: CGFloat, baselineY: CGFloat, color: UInt32, angle: Int) {
        guard let ctx = ctx else { return }
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.translateBy(x: x, y: baselineY - font.ascender)
        ctx.scaleBy(x: sx, y: 1)
        (s as NSString).draw(at: .zero, withAttributes: [.font: font, .foregroundColor: NSColor(tekRGB: color)])
        ctx.restoreGState()
    }

    /// Symbol フォントの文字を Unicode に
    static func symbolChar(_ c: UInt8) -> String {
        switch c {
        case 0xB7: return "\u{2022}"
        case 0xC5: return "\u{2295}"
        case 0xB4: return "\u{00D7}"
        case 0xE0: return "\u{25CA}"
        case 0xC6: return "\u{2297}"
        case 0xA8: return "\u{2666}"
        case 0xA7: return "\u{2663}"
        default: return String(Character(Unicode.Scalar(c)))
        }
    }

    func image(selectionOnly: Bool) -> NSImage? {
        guard let ctx = ctx, let full = ctx.makeImage() else { return nil }
        var r = CGRect(x: 0, y: 0, width: bitmapSize.w, height: bitmapSize.h)
        if selectionOnly {
            guard select else { return nil }
            r = selectionRect
        }
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        guard let cut = full.cropping(to: px) else { return nil }
        return NSImage(cgImage: cut, size: r.size)
    }

    private var selectionRect: CGRect {
        CGRect(x: min(selStart.x, selEnd.x), y: min(selStart.y, selEnd.y),
               width: abs(selEnd.x - selStart.x), height: abs(selEnd.y - selStart.y))
    }

    // MARK: 描画 (TEKPaint)

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let back = parser?.settings.backColor ?? 0xFFFFFF
        let fore = parser?.settings.foreColor ?? 0
        NSColor(tekRGB: back).setFill()
        bounds.fill()
        if let img = ctx?.makeImage() {
            g.saveGState()
            g.translateBy(x: 0, y: CGFloat(bitmapSize.h))
            g.scaleBy(x: 1, y: -1)
            g.interpolationQuality = .none
            g.draw(img, in: CGRect(x: 0, y: 0, width: bitmapSize.w, height: bitmapSize.h))
            g.restoreGState()
        }
        guard let p = parser else { return }
        // キャレット (アルファモード、アクティブのとき)
        if window?.isKeyWindow == true, p.dispMode == .alpha, !p.gin, caretOn {
            NSColor(tekRGB: fore).withAlphaComponent(0.6).setFill()
            NSRect(x: p.caretX, y: p.caretY - p.fontHeight, width: p.fontWidth, height: p.fontHeight).fill()
        }
        // 範囲選択 (ラバーバンド)
        if select || buttonDown {
            let path = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
            path.setLineDash([2, 2], count: 2, phase: 0)
            NSColor(tekRGB: fore).setStroke()
            path.stroke()
        }
        // GIN の十字カーソル
        if p.gin {
            g.saveGState()
            g.setBlendMode(.difference)
            g.setStrokeColor(NSColor.white.cgColor)
            g.setLineWidth(1)
            g.move(to: CGPoint(x: CGFloat(p.ginX) + 0.5, y: 0))
            g.addLine(to: CGPoint(x: CGFloat(p.ginX) + 0.5, y: CGFloat(p.screenHeight)))
            g.move(to: CGPoint(x: 0, y: CGFloat(p.ginY) + 0.5))
            g.addLine(to: CGPoint(x: CGFloat(p.screenWidth), y: CGFloat(p.ginY) + 0.5))
            g.strokePath()
            g.restoreGState()
        }
    }

    // MARK: マウス (TEKWMLButtonDown / Up / MouseMove)

    private func point(_ ev: NSEvent) -> NSPoint { convert(ev.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        guard let p = parser, let c = controller else { return }
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control), (c.window?.contentView as? TEKContainerView)?.bar.isHidden == true {
            NSMenu.popUpContextMenu(c.fullPopupMenu(), with: event, for: self)
            return
        }
        if p.gin {
            c.reportGIN(p.settings.ginMouseCode)
            return
        }
        let pt = point(event)
        guard pt.x >= 0, pt.x < CGFloat(p.screenWidth), pt.y >= 0, pt.y < CGFloat(p.screenHeight) else { return }
        select = false
        selStart = NSPoint(x: floor(pt.x), y: floor(pt.y))
        selEnd = selStart
        buttonDown = true
        p.holdInput = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard buttonDown, let p = parser else { return }
        let pt = point(event)
        var x = floor(pt.x) + 1, y = floor(pt.y) + 1
        if x < 0 { x = 0 } else if x > CGFloat(p.screenWidth) { x = CGFloat(p.screenWidth - 1) }
        if y < 0 { y = 0 } else if y > CGFloat(p.screenHeight) { y = CGFloat(p.screenHeight - 1) }
        selEnd = NSPoint(x: x + 1, y: y + 1)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard buttonDown, let p = parser else { return }
        buttonDown = false
        select = abs(selEnd.y - selStart.y) > 2 && abs(selEnd.x - selStart.x) > 2
        p.holdInput = false
        needsDisplay = true
        controller?.flushHeldInput()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let p = parser, p.gin else { return }
        let pt = point(event)
        p.ginMove(x: Int(floor(pt.x)), y: Int(floor(pt.y)))
        needsDisplay = true
    }

    /// 右ボタン: 貼り付け (CBStartPaste)
    override func rightMouseUp(with event: NSEvent) { controller?.editPaste(nil) }
    override func rightMouseDown(with event: NSEvent) {}

    // MARK: キーボード (OnChar / OnKeyDown)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if controller?.handleOptionKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller, let s = c.session else { return }
        if c.handleOptionKey(event) { return }
        if event.modifierFlags.contains(.command) { return }
        let p = c.parser
        if p.gin {
            if let ch = event.characters?.unicodeScalars.first, ch.value < 0x100 {
                c.reportGIN(UInt8(ch.value))
            }
            return
        }
        switch event.keyCode {
        case 36, 76: s.sendBytes(s.settings.sendNewlineBytes, echo: true)   // Return / Enter
        case 51: s.sendBytes([s.settings.bsSendsDel ? 0x7F : 0x08], echo: true)
        case 117: s.sendBytes([0x7F], echo: true)
        case 123: s.sendBytes([0x1B, 0x5B, 0x44], echo: false)
        case 124: s.sendBytes([0x1B, 0x5B, 0x43], echo: false)
        case 125: s.sendBytes([0x1B, 0x5B, 0x42], echo: false)
        case 126: s.sendBytes([0x1B, 0x5B, 0x41], echo: false)
        default:
            guard let t = event.characters, !t.isEmpty,
                  !t.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return }
            s.sendText(t)
        }
    }
}

extension TEKWindowController {
    /// TEKReportGIN
    func reportGIN(_ key: UInt8) {
        parser.reportGIN(key)
        tekView.needsDisplay = true
    }

    /// ボタンを離したら止めていた受信を読む (TEKParse が 0 を返していた分)
    func flushHeldInput() {
        if let rest = feed([]) { session?.tekReturnedToVT(rest) }
    }
}
