import AppKit
import TeraCore

/// Windows 版 Tera Term のように、ウィンドウの中 (タイトルバーの真下) に置くメニューバー。
/// 中身は NSApp.mainMenu の同名のメニューそのものを開く (検証・チェック印・ウィンドウ / 漢字コードの
/// NSMenuDelegate による作り直しがそのまま効く)。項目はこのバーのウィンドウをキーにしてから開くので、
/// target なしの項目は そのウィンドウの TerminalView → SessionWindowController の順で届く。
/// 表示するかは本家と同じ PopupMenu の設定 (アプリ全体、既定 off = 表示)。隠したときは Ctrl+左クリックでメニュー全体をポップアップする。
final class InWindowMenuBar: NSView {
    /// (表示名, mainMenu のタイトル, Option+○ のキー)。言語を変えたら変わるので毎回作る
    /// 表示名は本家の "ファイル(&F)" を "ファイル(F)"、"&File" を "File" にしたもの
    static var entries: [(label: String, menu: String, key: String)] {
        let list: [(String, String, String, String)] = [
            ("Tera Term", "MENU_FILE", "ファイル", "f"), ("Tera Term", "MENU_EDIT", "編集", "e"),
            ("Tera Term", "MENU_SETUP", "設定", "s"), ("Tera Term", "MENU_CONTROL", "コントロール", "o"),
            ("Tera Term", "MENU_WINDOW", "ウィンドウ", "w"), ("TTXKanjiMenu", "MENU_KANJI", "漢字コード", "k"),
            ("Tera Term", "MENU_HELP", "ヘルプ", "h"),
        ]
        return list.map { sec, key, def, k in
            let raw = Lang.raw(sec, key) ?? "\(def)(&\(k.uppercased()))"
            let label = raw.replacingOccurrences(of: "(&", with: "(").replacingOccurrences(of: "（&", with: "（")
                .replacingOccurrences(of: "&&", with: "\u{1}").replacingOccurrences(of: "&", with: "")
                .replacingOccurrences(of: "\u{1}", with: "&")
            return (label, Lang.t(sec, key, def), k)
        }
    }
    static let height: CGFloat = 24
    static let defaultsKey = "showInWindowMenuBar"
    static let changedNotification = Notification.Name("TeraMacInWindowMenuBarChanged")

    /// 設定の PopupMenu (TermSettings.popupMenu。on = 隠す) を読む。メニューの「ウィンドウ > メニューバーを表示」で変える。
    /// 前の版の "showInWindowMenuBar" しかなければ、それを使う
    static var isShown: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: "PopupMenu") != nil { return !d.bool(forKey: "PopupMenu") }
            return d.object(forKey: defaultsKey) == nil ? true : d.bool(forKey: defaultsKey)
        }
        set {
            // 右クリックの「隠す」・Ctrl+クリックの「表示」から: 保存した設定と開いている全ウィンドウの設定をそろえる
            var s = TermSettings.load()
            s.popupMenu = !newValue
            s.save()
            for c in SessionWindowController.all {
                var cs = c.settings; cs.popupMenu = !newValue; c.settings = cs
            }
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }
    /// 「…」(入りきらなかったメニューをまとめるボタン) の番号 = entries.count
    static var overflowIndex: Int { entries.count }
    static let overflowLabel = "…"

    /// 題の並び。1 段に入りきらない題は隠し (.zero)、右端の「…」にまとめる。
    /// 返す配列は entries の分 + 最後に「…」の枠 (いらなければ .zero)
    static func titleRects(width: CGFloat) -> [NSRect] {
        let font = NSFont.menuFont(ofSize: 12)
        let widths = entries.map { ceil(($0.label as NSString).size(withAttributes: [.font: font]).width) + 12 }
        let moreW = ceil((overflowLabel as NSString).size(withAttributes: [.font: font]).width) + 16
        let total = widths.reduce(2, +)
        var out: [NSRect] = []
        var x: CGFloat = 2
        if total <= width - 2 {
            for w in widths { out.append(NSRect(x: x, y: 0, width: w, height: height)); x += w }
            out.append(.zero)
            return out
        }
        var hiding = false
        for w in widths {
            if hiding || x + w > width - 2 - moreW { hiding = true; out.append(.zero); continue }
            out.append(NSRect(x: x, y: 0, width: w, height: height)); x += w
        }
        out.append(NSRect(x: x, y: 0, width: moreW, height: height))
        return out
    }

    /// バーの高さ (1 段 + 下の線)
    static func barHeight(forWidth width: CGFloat) -> CGFloat { height + 1 }

    /// ウィンドウの中身の高さに足す分
    static func currentHeight(forWidth width: CGFloat) -> CGFloat { isShown ? barHeight(forWidth: width) : 0 }

    static func topMenu(_ title: String) -> NSMenu? {
        NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu
    }

    private let font = NSFont.menuFont(ofSize: 12)
    /// 背景はタイトルバーと同じ素材にして、タイトルバーとひと続きに見せる (白い帯にしない)
    private let backdrop: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .titlebar
        v.blendingMode = .withinWindow
        v.state = .followsWindowActiveState
        return v
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop, positioned: .below, relativeTo: nil)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        highlight.isHidden = true
        addSubview(highlight)
        _ = overlay
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) { backdrop.frame = bounds }

    static func debugLog(_ s: String) {
        guard let path = ProcessInfo.processInfo.environment["TERAMAC_MENUBAR_TEST"] else { return }
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }
    private static var testStarted = false

    /// タイトルバーの下の線は消して、このバーの下に線を引く
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 確認用: TERAMAC_MENUBAR_TEST=<ログ> で、メニューを開いてマウスを隣の題へ動かし、切り替わるか記録して終わる
        if ProcessInfo.processInfo.environment["TERAMAC_MENUBAR_TEST"] != nil, !Self.testStarted, window != nil {
            Self.testStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, let w = self.window else { return }
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                // メニューを開いている間は GCD のメインキューが回らないので Timer (.common) で動かす
                func later(_ sec: Double, _ f: @escaping () -> Void) {
                    let t = Timer(timeInterval: sec, repeats: false) { _ in f() }
                    RunLoop.current.add(t, forMode: .common)
                }
                later(1.0) {
                    self.layoutTitles()
                    let r = self.convert(self.rects[2], to: nil)
                    let sp = w.convertPoint(toScreen: NSPoint(x: r.midX, y: r.midY))
                    let h = NSScreen.screens.first?.frame.height ?? 0
                    Self.debugLog("warp to \(sp)")
                    CGWarpMouseCursorPosition(CGPoint(x: sp.x, y: h - sp.y))
                }
                later(2.5) {
                    Self.debugLog("done pressed=\(String(describing: self.pressed))")
                    exit(0)
                }
                self.open(0)
            }
        }
        if #available(macOS 11.0, *) { window?.titlebarSeparatorStyle = .none }
    }

    /// 文字はバーの上に重ねて描く (背景の NSVisualEffectView より手前)
    private lazy var overlay: TitlesView = {
        let v = TitlesView(bar: self)
        v.autoresizingMask = [.width, .height]
        addSubview(v)
        return v
    }()
    private var rects: [NSRect] = []
    private var hover: Int? { didSet { updateHighlight() } }
    private var pressed: Int? { didSet { updateHighlight() } }
    /// 指している / 押している題の後ろの、角の丸い淡い地 (レイヤーで出すので確実に描き直される)
    private let highlight = NSView()
    private func updateHighlight() {
        layoutTitles()
        guard let i = pressed ?? hover, i < rects.count, rects[i] != .zero else { highlight.isHidden = true; return }
        highlight.frame = rects[i].insetBy(dx: 1, dy: 2)
        highlight.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(pressed != nil ? 0.2 : 0.12).cgColor
        highlight.isHidden = false
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func layoutTitles() {
        rects = Self.titleRects(width: bounds.width)
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { overlay.needsDisplay = true } }
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        overlay.frame = bounds
    }

    /// 題を描く: 押している / 指している題は Mac のツールバーのボタンのように角の丸い淡い地にする
    fileprivate func drawTitles() {
        layoutTitles()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard rects.count == Self.entries.count + 1 else { return }
        let active = window?.isKeyWindow ?? true
        let labels = Self.entries.map { $0.label } + [Self.overflowLabel]
        for (i, label) in labels.enumerated() where rects[i] != .zero {
            let color: NSColor = active ? .labelColor : .secondaryLabelColor
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let s = label as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: rects[i].minX + 7, y: rects[i].midY - sz.height / 2 - 0.5), withAttributes: attrs)
        }
    }

    private func index(at event: NSEvent) -> Int? {
        layoutTitles()
        let p = convert(event.locationInWindow, from: nil)
        return rects.firstIndex(where: { $0.contains(p) })
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        if i != hover {
            hover = i; needsDisplay = true
        }
    }
    override func mouseExited(with event: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        open(i)
    }

    /// i 番目のメニューを、そのタイトルの真下に開く (閉じるまで戻らない)
    /// メニューを開いたままマウスを横の題に動かすと、そのメニューに切り替わる (Windows のメニューバーと同じ)
    func open(_ first: Int) {
        window?.makeKeyAndOrderFront(nil)
        var next: Int? = first
        while let i = next {
            next = nil
            guard i >= 0, i <= Self.entries.count else { break }
            layoutTitles()
            let menu: NSMenu
            if i == Self.overflowIndex {
                // 「…」: 隠れているメニューをまとめて出す
                menu = NSMenu()
                for (k, e) in Self.entries.enumerated() where k < rects.count && rects[k] == .zero {
                    let top = NSMenuItem(title: e.label, action: nil, keyEquivalent: "")
                    let sub = NSMenu(title: e.menu)
                    sub.delegate = MirrorMenuDelegate.shared
                    top.submenu = sub
                    menu.addItem(top)
                }
            } else {
                // mainMenu のメニューそのものを開くと、横移動のときに閉じられない (cancelTracking が効かない) ので、
                // 開くたびに中身を写したメニューを使う (項目の動作・チェック印・使える/使えないは元と同じ)
                guard Self.topMenu(Self.entries[i].menu) != nil, rects[i] != .zero else { break }
                let m = NSMenu(title: Self.entries[i].menu)
                m.delegate = MirrorMenuDelegate.shared
                menu = m
            }
            layoutTitles()
            pressed = i; hover = nil
            display()
            let r = rects[i]
            var switchTo: Int?
            // メニューを開いている間 (イベントトラッキング中) もマウスの位置を見る
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self, weak menu] _ in
                guard let self = self, let w = self.window, switchTo == nil else { return }
                let p = self.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                Self.debugLog("tick p=\(p) rects=\(self.rects.map { $0.minX })")
                if let j = self.rects.firstIndex(where: { $0.contains(p) }), j != i {
                    Self.debugLog("switch \(i) -> \(j)")
                    switchTo = j
                    menu?.cancelTrackingWithoutAnimation()
                }
            }
            RunLoop.current.add(timer, forMode: .common)
            RunLoop.current.add(timer, forMode: .eventTracking)
            menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY), in: self)
            timer.invalidate()
            next = switchTo
        }
        pressed = nil
        if let w = window {
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            hover = rects.firstIndex(where: { $0.contains(p) })
        }
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let it = m.addItem(withTitle: Lang.m("MENU_CLOSE_MENUBAR", "メニューバーを閉じる"), action: #selector(hideBar(_:)), keyEquivalent: "")
        it.target = self
        return m
    }

    @objc func hideBar(_ sender: Any?) { Self.isShown = false }
    @objc func showBar(_ sender: Any?) { Self.isShown = true }

    // MARK: - 隠したとき (Ctrl+左クリック) のメニュー全体

    /// mainMenu の各メニューを写したメニュー (開くたびに元のメニューから項目を写す)
    static func fullPopupMenu() -> NSMenu {
        let m = NSMenu()
        for e in entries {
            let top = NSMenuItem(title: e.label, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: e.menu)
            sub.delegate = MirrorMenuDelegate.shared
            top.submenu = sub
            m.addItem(top)
        }
        m.addItem(.separator())
        let show = NSMenuItem(title: Lang.m("MENU_OPEN_MENUBAR", "メニューバーを開く"), action: #selector(showBar(_:)), keyEquivalent: "")
        show.target = barActionTarget
        m.addItem(show)
        return m
    }
    private static let barActionTarget = InWindowMenuBar(frame: .zero)
}

/// 写しのメニュー: 開くたびに mainMenu の同名メニューを (delegate があれば作り直させてから) 写す
final class MirrorMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = MirrorMenuDelegate()
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let src = InWindowMenuBar.topMenu(menu.title) else { return }
        src.delegate?.menuNeedsUpdate?(src)
        for it in src.items { menu.addItem(it.copy() as! NSMenuItem) }
    }
}

/// メニューバーと TerminalView を上下に並べる、ウィンドウの中身。
/// バーの題を描くだけの透明なビュー (背景の NSVisualEffectView の上に重ねる)
private final class TitlesView: NSView {
    unowned let bar: InWindowMenuBar
    init(bar: InWindowMenuBar) { self.bar = bar; super.init(frame: bar.bounds) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { bar.drawTitles() }
}

/// ウィンドウの中身 (端末)。メニューバーはタイトルバーの下の飾り (NSTitlebarAccessoryViewController) に置く。
/// タブが複数あるとき、タブの列はタイトルバーの飾りより下に出るので、メニューバーはタブより上になる
/// (Windows 版のメニューバーと同じく、タブを切り替えてもメニューの位置は変わらない)
final class TerminalContainerView: NSView {
    let bar = InWindowMenuBar(frame: .zero)
    let termView: TerminalView
    private let accessory = NSTitlebarAccessoryViewController()
    /// タイトルバーの右端のボタン。押すたびにメニューバーを出す / 隠す
    private let menuButtonAccessory = NSTitlebarAccessoryViewController()
    private lazy var menuButton: NSButton = {
        let img = NSImage(systemSymbolName: "line.horizontal.3", accessibilityDescription: Lang.m("MENU_MENU_BUTTON", "メニュー")) ?? NSImage()
        let b = HoverButton(image: img, target: self, action: #selector(openMenuFromButton(_:)))
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.toolTip = Lang.m("MENU_MENU_BUTTON", "メニュー")
        b.frame = NSRect(x: 0, y: 0, width: 36, height: 22)
        return b
    }()
    private var observer: NSObjectProtocol?
    private var langObserver: NSObjectProtocol?

    init(termView: TerminalView) {
        self.termView = termView
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        autoresizesSubviews = false
        addSubview(termView)
        bar.frame = NSRect(x: 0, y: 0, width: 600, height: InWindowMenuBar.barHeight(forWidth: 600))
        accessory.view = bar
        accessory.layoutAttribute = .bottom
        accessory.isHidden = !InWindowMenuBar.isShown
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        menuButton.frame.origin = NSPoint(x: 0, y: 0)
        holder.addSubview(menuButton)
        menuButtonAccessory.view = holder
        menuButtonAccessory.layoutAttribute = .trailing
        updateMenuButton()
        layoutChildren()
        observer = NotificationCenter.default.addObserver(forName: InWindowMenuBar.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.barVisibilityChanged()
        }
        // 言語が変わったら題とボタンの説明を描き直す (mainMenu は AppDelegate が先に作り直す)
        langObserver = NotificationCenter.default.addObserver(forName: Lang.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.languageChanged()
        }
        Self.installMonitors()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        if let o = langObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func languageChanged() {
        updateMenuButton()
        menuButton.image?.accessibilityDescription = Lang.m("MENU_MENU_BUTTON", "メニュー")
        bar.needsDisplay = true
    }

    override var isFlipped: Bool { true }

    /// メニューバーを出しているか
    var barShown: Bool { !accessory.isHidden }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let w = window, !w.titlebarAccessoryViewControllers.contains(accessory) else { return }
        w.addTitlebarAccessoryViewController(accessory)
        w.addTitlebarAccessoryViewController(menuButtonAccessory)
    }

    @objc private func openMenuFromButton(_ sender: NSButton) {
        InWindowMenuBar.isShown.toggle()
    }

    /// 出しているときは色を付け、押すと隠すと分かるようにする
    private func updateMenuButton() {
        let shown = InWindowMenuBar.isShown
        menuButton.contentTintColor = shown ? .controlAccentColor : .secondaryLabelColor
        menuButton.toolTip = shown ? Lang.m("MENU_CLOSE_MENUBAR", "メニューバーを閉じる") : Lang.m("MENU_OPEN_MENUBAR", "メニューバーを開く")
    }

    private func layoutChildren() {
        if termView.frame != bounds { termView.frame = bounds }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutChildren() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }

    /// 表示 / 非表示が変わったら、端末の大きさ (cols/rows) を保ったままウィンドウを伸び縮みさせる
    private func barVisibilityChanged() {
        let show = InWindowMenuBar.isShown
        guard show != barShown else { return }
        updateMenuButton()
        guard let w = window, w.isVisible else { accessory.isHidden = !show; return }
        // スライドして出し入れする。端末の大きさ (cols/rows) は変えず、ウィンドウの上端も動かさない
        let bh = bar.frame.height
        var target = w.frame
        target.size.height += show ? bh : -bh
        target.origin.y = w.frame.maxY - target.height
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            accessory.animator().isHidden = !show
            w.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.layoutChildren()
            self?.bar.needsDisplay = true
        })
    }

    // MARK: - Option+○ (Windows の Alt+○) と、隠したときの Ctrl+左クリック

    private static var monitorsInstalled = false
    private static func installMonitors() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard let c = ev.window?.contentView as? TerminalContainerView, c.barShown,
                  ev.window?.firstResponder === c.termView,
                  ev.modifierFlags.intersection([.command, .control, .option, .shift]) == [.option],
                  !c.termView.settings.optionAsMeta, !c.termView.hasMarkedText(),
                  let ch = ev.charactersIgnoringModifiers?.lowercased(),
                  let i = InWindowMenuBar.entries.firstIndex(where: { $0.key == ch }) else { return ev }
            DispatchQueue.main.async { c.bar.open(i) }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { ev in
            guard let w = ev.window, let c = w.contentView as? TerminalContainerView, !c.barShown,
                  ev.modifierFlags.intersection([.command, .control, .option, .shift]) == [.control] else { return ev }
            let p = c.termView.convert(ev.locationInWindow, from: nil)
            guard c.termView.bounds.contains(p) else { return ev }
            w.makeKeyAndOrderFront(nil)
            InWindowMenuBar.fullPopupMenu().popUp(positioning: nil, at: p, in: c.termView)
            return nil
        }
    }
}

/// マウスが乗ると、角の丸い淡い背景を付けるボタン (メニューバーの題と同じ見た目)
final class HoverButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.2 : 0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}
