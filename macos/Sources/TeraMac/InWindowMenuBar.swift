import AppKit

/// Windows 版 Tera Term のように、ウィンドウの中 (タイトルバーの真下) に置くメニューバー。
/// 中身は NSApp.mainMenu の同名のメニューそのものを開く (検証・チェック印・ウィンドウ / 漢字コードの
/// NSMenuDelegate による作り直しがそのまま効く)。項目はこのバーのウィンドウをキーにしてから開くので、
/// target なしの項目は そのウィンドウの TerminalView → SessionWindowController の順で届く。
/// 「メニューバー表示」(MENU_SHOW_MENUBAR / HideMenu) にあたる設定は UserDefaults "showInWindowMenuBar"
/// (アプリ全体、既定 表示)。隠したときは Ctrl+左クリックでメニュー全体をポップアップする。
final class InWindowMenuBar: NSView {
    /// (表示名, mainMenu のタイトル, Option+○ のキー)
    static let entries: [(label: String, menu: String, key: String)] = [
        ("ファイル(F)", "ファイル", "f"), ("編集(E)", "編集", "e"), ("設定(S)", "設定", "s"),
        ("コントロール(O)", "コントロール", "o"), ("ウィンドウ(W)", "ウィンドウ", "w"),
        ("漢字コード(K)", "漢字コード", "k"), ("ヘルプ(H)", "ヘルプ", "h"),
    ]
    static let height: CGFloat = 24
    static let defaultsKey = "showInWindowMenuBar"
    static let changedNotification = Notification.Name("TeraMacInWindowMenuBarChanged")

    static var isShown: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) == nil ? true : UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
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
    private var hover: Int?
    private var pressed: Int?

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
            let r = rects[i].insetBy(dx: 1, dy: 2)
            if pressed == i || hover == i {
                (pressed == i ? NSColor.labelColor.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
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
        if i != hover { hover = i; needsDisplay = true }
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
        let it = m.addItem(withTitle: "メニューバーを隠す", action: #selector(hideBar(_:)), keyEquivalent: "")
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
        let show = NSMenuItem(title: "メニューバーを表示", action: #selector(showBar(_:)), keyEquivalent: "")
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

/// TerminalView の frame はバーの分を除いた残りなので、cols/rows は TerminalView 自身の大きさから決まる
final class TerminalContainerView: NSView {
    let bar = InWindowMenuBar(frame: .zero)
    let termView: TerminalView
    private var observer: NSObjectProtocol?

    init(termView: TerminalView) {
        self.termView = termView
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        autoresizesSubviews = false
        addSubview(bar)
        addSubview(termView)
        bar.isHidden = !InWindowMenuBar.isShown
        layoutChildren()
        observer = NotificationCenter.default.addObserver(forName: InWindowMenuBar.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.barVisibilityChanged()
        }
        Self.installMonitors()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    override var isFlipped: Bool { true }

    private var barHeight: CGFloat { bar.isHidden ? 0 : InWindowMenuBar.barHeight(forWidth: bounds.width) }

    private func layoutChildren() {
        let h = barHeight
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InWindowMenuBar.barHeight(forWidth: bounds.width))
        bar.needsDisplay = true
        let tf = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        if termView.frame != tf { termView.frame = tf }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutChildren() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }

    /// 表示 / 非表示が変わったら、端末の大きさ (cols/rows) を保ったままウィンドウを伸び縮みさせる
    private func barVisibilityChanged() {
        let show = InWindowMenuBar.isShown
        guard show == bar.isHidden else { return }
        bar.isHidden = !show
        guard let w = window else { layoutChildren(); return }
        let top = w.frame.maxY
        var size = w.contentRect(forFrameRect: w.frame).size
        let bh = InWindowMenuBar.barHeight(forWidth: bounds.width)
        size.height += show ? bh : -bh
        w.setContentSize(size)
        w.setFrameTopLeftPoint(NSPoint(x: w.frame.minX, y: top))
        layoutChildren()
        bar.needsDisplay = true
    }

    // MARK: - Option+○ (Windows の Alt+○) と、隠したときの Ctrl+左クリック

    private static var monitorsInstalled = false
    private static func installMonitors() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard let c = ev.window?.contentView as? TerminalContainerView, !c.bar.isHidden,
                  ev.window?.firstResponder === c.termView,
                  ev.modifierFlags.intersection([.command, .control, .option, .shift]) == [.option],
                  !c.termView.settings.optionAsMeta, !c.termView.hasMarkedText(),
                  let ch = ev.charactersIgnoringModifiers?.lowercased(),
                  let i = InWindowMenuBar.entries.firstIndex(where: { $0.key == ch }) else { return ev }
            DispatchQueue.main.async { c.bar.open(i) }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { ev in
            guard let w = ev.window, let c = w.contentView as? TerminalContainerView, c.bar.isHidden,
                  ev.modifierFlags.intersection([.command, .control, .option, .shift]) == [.control] else { return ev }
            let p = c.termView.convert(ev.locationInWindow, from: nil)
            guard c.termView.bounds.contains(p) else { return ev }
            w.makeKeyAndOrderFront(nil)
            InWindowMenuBar.fullPopupMenu().popUp(positioning: nil, at: p, in: c.termView)
            return nil
        }
    }
}
