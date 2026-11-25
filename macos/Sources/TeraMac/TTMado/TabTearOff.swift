import AppKit
import TeraCore

// MARK: - タブを引き出したウインドウを、元のウインドウのタブに戻す (Mac 版だけの機能)

/// 弱い参照のウインドウ
struct WeakWindow { weak var w: NSWindow? }

/// タブのバーからタブを引き出して (または「このタブを新しいウィンドウに分ける」で) 1 つのウインドウになったとき、
/// 元のウインドウ (のセッション) を覚えておき、元のウインドウのタイトルバーに寄せて離すと元のウインドウのタブに戻す。
/// 元のウインドウの中身の上で離すと、その場所に分割のペインとして入れる。
///
/// 引き出したことの見分け方: AppKit にはタブの組が変わったことを知らせる通知がないので、
/// ウインドウがキーになった・メインになった・動いた などの通知のたびに (少しあとで、AppKit がタブの組を直し終えてから)、
/// 各セッションのウインドウの「同じタブの組のほかのウインドウ」を前に見たもの (tabSiblings) と比べる。
/// - 前はほかのタブがあり、今は 1 つだけで、前のタブがまだ画面にある → そこから引き出された。
/// - 2 つのタブの組が分かれると、どちらも 1 つになる。引き出した方はキーウインドウになり、位置も変わるので、それで決める
///   (決められなければ何もしない)。
/// - 閉じたタブ・分割のペインになって隠したタブは「画面にある」に入れないので、引き出したとはみなさない。
/// - タブの組に戻ったら (どの組でも) 覚えた元のウインドウを忘れる。
enum TabTearOff {
    private static var installed = false
    private static var pending = false

    static func install() {
        guard !installed else { return }
        installed = true
        TabBarDrag.install()
        observers.removeAll()
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                                          NSWindow.didResignKeyNotification, NSWindow.didMoveNotification,
                                          NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification]
        for n in names {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: nil) { _ in schedule() })
        }
    }
    private static var observers: [NSObjectProtocol] = []

    /// 見張りをやめる (TTMado を切ったとき): 通知・タブのドラッグの見張り・ウインドウのドラッグを止め、見本を消し、元のウインドウを忘れる
    static func uninstall() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        installed = false
        TabBarDrag.uninstall()
        endDrag()
        hint.hide()
        zonePreview.hide()
        for c in SessionWindowController.all {
            c.tearOffOrigin = nil
            c.tabSiblings = []
            if let w = c.window, w.alphaValue < 1, c.tabSplit == nil { w.alphaValue = 1 }
        }
    }

    /// 少しあとで調べる (続けて来た通知はまとめる)
    static func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { check() }
    }

    /// 画面にある (または最小化した・タブの組に入っている) セッションのウインドウ。分割のペインとして隠したものは除く
    static func isPresented(_ w: NSWindow) -> Bool {
        guard let c = w.windowController as? SessionWindowController, SessionWindowController.all.contains(where: { $0 === c }) else { return false }
        guard w.contentView is TerminalContainerView || w.contentView is TabSplitRootView else { return false }
        return w.isVisible || w.isMiniaturized || (w.tabGroup?.windows.count ?? 1) > 1
    }

    /// 安全網: タブの出し入れを繰り返したあとに「画面が消えた」ままにならないようにする。
    /// 分割に入っていないセッションのウインドウが透明のまま (alphaValue 0) だったり、端末の入れ物が外れたまま
    /// (分割の後始末の漏れ) だったりしたら元に戻す。ドラッグ中・分割に入れる途中 (HiddenHandoff) は触らない
    static func repair() {
        guard HiddenHandoff.active == 0, NSEvent.pressedMouseButtons == 0 else { return }
        for c in SessionWindowController.all {
            guard let w = c.window else { continue }
            if let sp = c.tabSplit {
                // 分割しているウインドウ自身は見えていること (ペインのウインドウは隠したままでよい)
                if sp.hostWindow === w, w.alphaValue < 1 { w.alphaValue = 1 }
                continue
            }
            if !(w.contentView is TerminalContainerView) && !(w.contentView is TabSplitRootView) {
                var v: NSView? = c.termView
                while let x = v, !(x is TerminalContainerView) { v = x.superview }
                if let cont = v as? TerminalContainerView {
                    cont.removeFromSuperview()
                    cont.paneResponder = nil
                    c.paneNextResponder = nil
                    w.contentView = cont
                }
            }
            if w.alphaValue < 1 { w.alphaValue = 1 }
        }
    }

    /// 分割のペインのウインドウ (ホスト以外) は、いつも隠したままにする。
    /// タブのバーからタブを中身の上に落としたとき、AppKit がドラッグを受け付けずにタブを元の組へ戻す (戻る動きのあとで組に入れて選ぶ) ことがあり、
    /// それが分割に入れたあとだと、中身の空いた透明なウインドウが選ばれたタブになって「画面が消えた」ようになる。
    /// その場合は、組から外して隠し、分割しているウインドウ (なければ組のほかのタブ) を見せる
    static func rehidePaneWindows() {
        for c in SessionWindowController.all {
            guard let sp = c.tabSplit, let w = c.window, w !== sp.hostWindow,
                  w.isVisible || (w.tabGroup?.windows.count ?? 1) > 1 else { continue }
            let g = w.tabGroup
            let wasShown = g?.selectedWindow === w || w.isKeyWindow || w.isVisible
            let rest = (g?.windows ?? []).filter { $0 !== w }
            if let g = g, g.windows.count > 1 { g.removeWindow(w) }
            w.orderOut(nil)
            guard wasShown, let o = rest.first(where: { $0 === sp.hostWindow }) ?? rest.first ?? sp.hostWindow else { continue }
            o.tabGroup?.selectedWindow = o
            o.makeKeyAndOrderFront(nil)
            if o === sp.hostWindow, let f = sp.focused ?? sp.panes.first?.session { sp.focus(f) }
        }
    }

    private static func others(of w: NSWindow) -> [NSWindow] { (w.tabGroup?.windows ?? [w]).filter { $0 !== w } }

    /// タブの組の変化を調べ、元のウインドウを覚える・忘れる
    static func check() {
        pending = false
        guard installed else { return }
        rehidePaneWindows()
        defer { repair(); PaneCountBadge.refreshAll() }   // タブの組が変わったらバッジの出し方 (タブの右 / タイトルバー) も変える
        let list = SessionWindowController.all
        var candidates: [(c: SessionWindowController, prev: [NSWindow])] = []
        for c in list {
            guard let w = c.window, isPresented(w) else { continue }
            if !others(of: w).isEmpty {
                c.tearOffOrigin = nil   // タブの組に戻った
                continue
            }
            let group = w.tabGroup?.windows ?? [w]
            let prev = c.tabSiblings.compactMap { $0.w }.filter { $0 !== w && !group.contains($0) && isPresented($0) }
            if !prev.isEmpty { candidates.append((c, prev)) }
        }
        for (c, prev) in candidates {
            guard let w = c.window else { continue }
            // 2 つのタブの組が分かれた (お互いが前の相手): 引き出した方だけ
            if let o = candidates.first(where: { $0.c !== c && $0.c.window.map { prev.contains($0) } == true && $0.prev.contains(w) }) {
                guard tornOff(c, vs: o.c) else { continue }
            }
            guard let first = prev.first else { continue }
            let ow = first.tabGroup?.selectedWindow ?? first
            if let oc = ow.windowController as? SessionWindowController { c.tearOffOrigin = oc }
        }
        // 今のタブの組と位置を覚える
        for c in list {
            if let w = c.window, isPresented(w) {
                c.tabSiblings = others(of: w).map { WeakWindow(w: $0) }
                c.tabFrame = w.frame
            } else {
                c.tabSiblings = []
            }
        }
    }

    /// 2 つに分かれたタブのどちらが引き出された方か: キーウインドウの方。どちらも同じなら位置が変わった方
    private static func tornOff(_ c: SessionWindowController, vs o: SessionWindowController) -> Bool {
        guard let w = c.window, let ow = o.window else { return false }
        if w.isKeyWindow != ow.isKeyWindow { return w.isKeyWindow }
        let moved = w.frame != c.tabFrame, otherMoved = ow.frame != o.tabFrame
        return moved && !otherMoved
    }

    /// ウインドウ w のタブの組の、w のほかのタブ (選んでいるタブを先に)。元のウインドウとして覚える
    static func neighbor(of w: NSWindow) -> SessionWindowController? {
        let rest = others(of: w)
        let sel = w.tabGroup?.selectedWindow
        let pick = (sel !== w ? sel : nil) ?? rest.first
        return pick?.windowController as? SessionWindowController
    }

    /// 元のウインドウを覚える (メニューの「このタブを新しいウィンドウに分ける」・ペインの「新しいウィンドウに分ける」)
    static func setOrigin(_ c: SessionWindowController, _ origin: SessionWindowController?) {
        guard let o = origin, o !== c else { return }
        c.tearOffOrigin = o
        if let w = c.window, isPresented(w) {
            c.tabSiblings = []
            c.tabFrame = w.frame
        }
        schedule()
    }

    /// 戻す先のウインドウ (元のセッションが分割のペインなら、分割しているウインドウ)。戻せなければ nil
    static func originWindow(of c: SessionWindowController) -> NSWindow? {
        guard let o = c.tearOffOrigin, SessionWindowController.all.contains(where: { $0 === o }),
              let ow = o.presentingWindow, let w = c.window, ow !== w, isPresented(ow) || o.tabSplit != nil,
              ow.isVisible || ow.isMiniaturized else { return nil }
        if (ow.tabGroup?.windows ?? []).contains(where: { $0 === w }) { return nil }
        return ow
    }

    /// 元のウインドウに戻せるか: 自分のウインドウが 1 つだけで、元のウインドウがまだある
    static func canReturn(_ c: SessionWindowController) -> Bool {
        guard let w = c.window, isPresented(w), others(of: w).isEmpty, c.tabSplit == nil || c.tabSplit?.hostWindow === w else { return false }
        return originWindow(of: c) != nil
    }

    /// 元のウインドウのタブに戻して、そのタブを選ぶ
    static func returnToOrigin(_ c: SessionWindowController) {
        endDrag()
        guard canReturn(c), let w = c.window, let ow = originWindow(of: c) else { return }
        if ow.isMiniaturized { ow.deminiaturize(nil) }
        let anchor = ow.tabGroup?.windows.last ?? ow
        anchor.addTabbedWindow(w, ordered: .above)
        w.tabGroup?.selectedWindow = w
        w.makeKeyAndOrderFront(nil)
        if let f = SessionWindowController.session(for: w) { w.makeFirstResponder(f.termView) }
        c.tearOffOrigin = nil
        schedule()
    }

    // MARK: - ウインドウをほかのウインドウに寄せて離すと、タブにする・分割に入れる

    /// ドラッグ中の状態。タイトルバーのドラッグは WindowServer が行うのでアプリにはマウスの出来事が来ないことがある。
    /// そのため、マウスのボタンの状態 (NSEvent.pressedMouseButtons) と位置を短い間隔で見て、離したときを見つける
    /// (leftMouseUp のモニタも付けておく。来ればすぐに終える)
    ///
    /// - 引き出したウインドウを元のウインドウのタイトルバーに寄せる → 元のウインドウのタブに戻す (前からの動き)
    /// - どのウインドウでも、ほかのウインドウのタイトルバー・タブのバーの上で離す → そのウインドウのタブにする
    ///   (分割しているウインドウは、分割のまま 1 つのタブになる)
    /// - ほかのウインドウの中身の上で離す → そのウインドウの分割の、その場所に入れる。
    ///   ドラッグしたウインドウが分割していれば、その並べ方のまま入れる (TabSplit.mergeWindow)
    private final class Drag {
        weak var c: SessionWindowController?
        weak var w: NSWindow?
        let startFrame: NSRect
        let startMouse: NSPoint
        var timer: Timer?
        var monitor: Any?
        /// タイトルバー・タブのバーに寄せている相手 (タブにする)
        weak var near: NSWindow?
        /// 中身の上の、分割の行き先 (なければ nil)
        weak var zoneWindow: NSWindow?
        var zone: SplitDropZone.Side?
        weak var zonePane: TabPaneView?
        init(c: SessionWindowController, w: NSWindow, mouse: NSPoint) { self.c = c; self.w = w; startFrame = w.frame; startMouse = mouse }
        /// 今のウインドウの位置 (マウスの動きから見積もる。ドラッグ中は frame がすぐ変わらないことがあるため)
        var estimatedFrame: NSRect {
            let m = NSEvent.mouseLocation
            return startFrame.offsetBy(dx: m.x - startMouse.x, dy: m.y - startMouse.y)
        }
    }
    private static var drag: Drag?
    private static let hint = MergeHintWindow()
    private static let zonePreview = SplitDropPreview()

    /// windowWillMove から: セッションのウインドウ (分割しているウインドウも) のタイトルバーをドラッグし始めた
    static func dragBegan(_ c: SessionWindowController) {
        guard installed, !TabBarDrag.isActive, drag?.c !== c, NSEvent.pressedMouseButtons & 1 != 0,
              let w = c.presentingWindow, w.isVisible, isPresented(w) else { return }
        endDrag()
        let d = Drag(c: c, w: w, mouse: NSEvent.mouseLocation)
        drag = d
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        d.timer = t
        d.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { ev in
            DispatchQueue.main.async { if drag != nil { release() } }
            return ev
        }
    }

    /// マウスの下の、ドラッグしているウインドウ w 以外のセッションのウインドウ (前から順に)
    private static func windowUnder(_ mouse: NSPoint, excluding w: NSWindow) -> NSWindow? { sessionWindow(at: mouse, excluding: w) }

    /// マウス (画面の座標) の下の、いちばん前のセッションのウインドウ。excluding (とそのタブの組) は除く
    static func sessionWindow(at mouse: NSPoint, excluding w: NSWindow?) -> NSWindow? {
        let mine = w.map { $0.tabGroup?.windows ?? [$0] } ?? []
        return NSApp.orderedWindows.first { x in
            guard x !== w, !mine.contains(where: { $0 === x }), x.isVisible, !x.isMiniaturized,
                  x.windowController is SessionWindowController,
                  x.contentView is TerminalContainerView || x.contentView is TabSplitRootView else { return false }
            return x.frame.contains(mouse)
        }
    }

    /// 今の位置での行き先を決める (d.near / d.zone*)
    private static func evaluate(_ d: Drag, mouse: NSPoint) {
        d.near = nil
        d.zone = nil
        d.zoneWindow = nil
        d.zonePane = nil
        guard let c = d.c, let w = d.w else { return }
        // 引き出したウインドウを元のウインドウに寄せた
        if let ow = originWindow(of: c),
           isNear(frame: d.estimatedFrame, mouse: mouse, origin: ow)
            || (w.frame != d.startFrame && isNear(frame: w.frame, mouse: mouse, origin: ow)) {
            d.near = ow
            return
        }
        guard let tw = windowUnder(mouse, excluding: w) else { return }
        if barRect(of: tw).contains(mouse) { d.near = tw; return }
        updateZone(d, target: tw, mouse: mouse)
    }

    private static func tick() {
        guard let d = drag, d.c != nil, d.w != nil else { endDrag(); return }
        if NSEvent.pressedMouseButtons & 1 == 0 { release(); return }
        evaluate(d, mouse: NSEvent.mouseLocation)
        if let n = d.near { hint.show(over: n, above: d.w) } else { hint.hide() }
        // 行き先がなくなったら (ウインドウの外・中身でないところ・タイトルバーに寄せた) すぐに消す
        if d.zone == nil { zonePreview.hide() }
    }

    /// マウスがウインドウ tw の中身 (タイトルバー・タブのバーではない) の上にあれば、分割の行き先の見本を出す。
    /// 分割中ならマウスの下のペイン、していなければ端末全体を、左右の 25% / 上下の半分で分ける
    private static func updateZone(_ d: Drag, target tw: NSWindow, mouse: NSPoint) {
        if let z = zone(in: tw, mouse: mouse) {
            d.zone = z.side
            d.zonePane = z.pane
            d.zoneWindow = tw
            zonePreview.show(z.rect, over: tw, above: d.w, label: z.label)
        } else {
            d.zone = nil
            d.zonePane = nil
            zonePreview.hide()
        }
    }

    /// ウインドウ tw の中身 (タイトルバー・タブのバーではない) の上の、分割の行き先 (マウスは画面の座標)。
    /// 分割中ならマウスの下のペイン (except は除く)、していなければ端末全体を、左右の 25% / 上下の半分で分ける。rect は見本の場所 (画面の座標)
    /// 分割中は、根の端 (TabSplit.edgeWidth 以内) ならいちばん外側に並べる (pane は nil、label は「端に並べる」)
    static func zone(in tw: NSWindow, mouse: NSPoint, except: TabPaneView? = nil) -> (side: SplitDropZone.Side, pane: TabPaneView?, rect: NSRect, label: String?)? {
        guard let cv = tw.contentView, !barRect(of: tw).contains(mouse) else { return nil }
        let pt = tw.convertPoint(fromScreen: mouse)
        guard tw.contentLayoutRect.contains(pt) else { return nil }
        if let sp = TabSplit.split(of: tw) {
            guard let z = sp.dropAt(for: except, at: pt) else { return nil }
            return (z.side, z.pane, tw.convertToScreen(z.rect), z.label)
        }
        guard cv is TerminalContainerView else { return nil }
        let q = cv.convert(pt, from: nil)
        guard cv.bounds.contains(q), let side = SplitDropZone.side(in: cv.bounds, at: q, flipped: cv.isFlipped) else { return nil }
        return (side, nil, tw.convertToScreen(cv.convert(SplitDropZone.half(of: cv.bounds, side: side, flipped: cv.isFlipped), to: nil)), nil)
    }

    /// マウスを離した: そのときの位置で決める (近くを通っただけでは何もしない)
    private static func release() {
        guard let d = drag else { return }
        evaluate(d, mouse: NSEvent.mouseLocation)
        let c = d.c, w = d.w, near = d.near, zw = d.zoneWindow, pane = d.zonePane, side = d.zone
        endDrag()
        guard let c = c, let w = w else { return }
        finishRelease(c, w, near: near, zoneWindow: zw, pane: pane, side: side)
    }

    /// 離したあとの処理 (自己テストからも呼ぶ)
    static func finishRelease(_ c: SessionWindowController, _ w: NSWindow, near: NSWindow?, zoneWindow zw: NSWindow?, pane: TabPaneView?, side: SplitDropZone.Side?) {
        // 分割に入れるウインドウは、すぐに見えなくする (入れるまでの間、ウインドウのまま見えないように)
        if near == nil, zw != nil, side != nil { w.alphaValue = 0 }
        // WindowServer がウインドウの移動を終えてから付ける
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let n = near {
                if n === originWindow(of: c) { returnToOrigin(c) } else { mergeAsTab(w, into: n) }
            } else if let tw = zw, let s = side {
                c.tearOffOrigin = nil
                if !TabSplit.mergeWindow(w, into: tw, pane: pane, side: s) { w.alphaValue = 1 }
                schedule()
            }
        }
    }

    /// ウインドウ w を、ウインドウ tw のタブの組の最後に入れて選ぶ (分割しているウインドウは分割のまま)
    static func mergeAsTab(_ w: NSWindow, into tw: NSWindow) {
        guard w !== tw, tw.isVisible || tw.isMiniaturized else { return }
        w.alphaValue = 1
        if !w.isVisible { w.setFrame(tw.frame, display: false) }
        if tw.isMiniaturized { tw.deminiaturize(nil) }
        if let g = w.tabGroup, g.windows.count > 1 { g.removeWindow(w) }
        let anchor = tw.tabGroup?.windows.last ?? tw
        anchor.addTabbedWindow(w, ordered: .above)
        w.tabGroup?.selectedWindow = w
        w.makeKeyAndOrderFront(nil)
        if let f = TabSplit.split(of: w)?.panes.first?.session ?? SessionWindowController.session(for: w) { w.makeFirstResponder(f.termView) }
        (w.windowController as? SessionWindowController)?.tearOffOrigin = nil
        schedule()
    }

    private static func endDrag() {
        guard let d = drag else { hint.hide(); zonePreview.hide(); return }
        drag = nil
        d.timer?.invalidate()
        if let m = d.monitor { NSEvent.removeMonitor(m) }
        hint.hide()
        zonePreview.hide()
    }

    /// 元のウインドウのタイトルバー・タブのバーの範囲 (画面の座標)
    static func barRect(of w: NSWindow) -> NSRect {
        let f = w.frame
        let h = max(22, f.height - w.contentLayoutRect.height)
        return NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
    }

    /// 寄せたとみなすか: 上端が 24pt 以内で、左右が 40% 以上重なる。または、つかんでいるタイトルバー (マウス) が
    /// 元のウインドウのタイトルバー・タブのバーの上にある
    static func isNear(frame d: NSRect, mouse: NSPoint, origin ow: NSWindow) -> Bool {
        guard ow.isVisible, !ow.isMiniaturized else { return false }
        let o = ow.frame
        let overlap = max(0, min(d.maxX, o.maxX) - max(d.minX, o.minX))
        if abs(d.maxY - o.maxY) <= 24 && overlap / max(1, min(d.width, o.width)) >= 0.4 { return true }
        let bar = barRect(of: ow)
        let myBar = NSRect(x: d.minX, y: d.maxY - 28, width: d.width, height: 28)
        return bar.contains(mouse) && bar.intersects(myBar)
    }

    // 自己テスト用
    static func showHintForTest(_ c: SessionWindowController) {
        if let ow = originWindow(of: c) { hint.show(over: ow, above: c.window) }
    }
    static var hintWindow: NSWindow { hint }
}

/// 寄せている間、元のウインドウのタイトルバーの上に出す淡いアクセント色の帯 (クリックは通す)
private final class MergeHintWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 28), styleMask: .borderless, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = MergeHintView()
    }

    func show(over ow: NSWindow, above w: NSWindow?) {
        let r = TabTearOff.barRect(of: ow)
        if frame != r { setFrame(r, display: true) }
        level = max(ow.level, w?.level ?? ow.level)
        if let w = w { order(.above, relativeTo: w.windowNumber) } else { order(.above, relativeTo: ow.windowNumber) }
        watch.start { [weak self] in self?.hide() }
    }
    func hide() {
        watch.stop()
        if isVisible { orderOut(nil) }
    }
    private let watch = OverlayWatch()
}

private final class MergeHintView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        p.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        p.lineWidth = 2
        p.stroke()
        let s = Lang.m("MENU_TABS_MERGE_HINT", "離すとタブに戻ります") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }
}

// MARK: - タブのバーでタブをドラッグしている間も、分割の行き先を見せる

/// タブのドラッグ (タブのバーの中・引き出し) は AppKit が行うので、マウスのボタンと位置を短い間隔で見て追う。
/// - タブのバーで押したら覚えておき、4pt より動いたらドラッグとみなす (ふつうのクリックには何もしない)。
///   ドラッグしているタブは、押したときに AppKit が選ぶので、そのときのタブの組の選んでいるタブとする。
/// - マウスがセッションのウインドウの中身 (タイトルバー・タブのバーではない) の上にあれば、
///   分割中ならマウスの下のペイン、していなければ端末全体を 4 つの場所に分けて見本を出す。
/// - 見本を出しているところで離したら、AppKit がドラッグを終えてから (タブの並べ替え・引き出し・ほかの組への移動のあと)、
///   そのウインドウの分割のその場所に入れる。分割していなければ、そのウインドウの今のタブと分割を始める
///   (ドラッグしたタブ自身が今のタブなら、元のタブの組のほかのタブと)。見本がなければ AppKit のしたままにする
enum TabBarDrag {
    private static var installed = false
    private static var monitor: Any?
    private static var timer: Timer?
    private static var startMouse = NSPoint.zero
    private static weak var startWindow: NSWindow?
    private static weak var dragged: SessionWindowController?
    /// 押したときのタブの組 (ドラッグしたタブ以外。今のタブがドラッグしたタブのときの相手を選ぶ)
    private static var group: [WeakWindow] = []
    private static var dragging = false
    private static weak var zoneWindow: NSWindow?
    private static weak var zonePane: TabPaneView?
    private static var zone: SplitDropZone.Side?
    private static let preview = SplitDropPreview()

    /// タブのドラッグを追っている
    static var isActive: Bool { dragging }

    static func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        installed = false
        stop()
    }

    static func install() {
        guard !installed else { return }
        installed = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { ev in
            mouseDown(ev)
            return ev
        }
    }

    /// タブのバーの上か (ウインドウの座標 pt。タイトルバーの中の、タブのバーのビュー)
    private static func isOnTabBar(_ w: NSWindow, _ pt: NSPoint) -> Bool {
        guard (w.tabGroup?.windows.count ?? 1) > 1, pt.y >= w.contentLayoutRect.maxY,
              var v = w.contentView?.superview?.hitTest(pt) else { return false }
        while true {
            let name = String(describing: type(of: v))
            if name.contains("TabBar") || name.contains("TabButton") { return true }
            guard let up = v.superview else { return false }
            v = up
        }
    }

    private static func mouseDown(_ ev: NSEvent) {
        stop()
        guard let w = ev.window, w.windowController is SessionWindowController,
              !ev.modifierFlags.contains(.shift), isOnTabBar(w, ev.locationInWindow) else { return }
        startWindow = w
        startMouse = NSEvent.mouseLocation
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func stop() {
        timer?.invalidate()
        timer = nil
        dragging = false
        dragged = nil
        group = []
        clearZone()
    }

    private static func clearZone() {
        zone = nil
        zoneWindow = nil
        zonePane = nil
        preview.hide()
    }

    private static func tick() {
        let mouse = NSEvent.mouseLocation
        if NSEvent.pressedMouseButtons & 1 == 0 { release(); return }
        if !dragging {
            guard hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) > 4, let w = startWindow else { return }
            let sel = w.tabGroup?.selectedWindow ?? w
            guard let c = sel.windowController as? SessionWindowController, c.tabSplit == nil,
                  sel.contentView is TerminalContainerView else { stop(); return }
            dragging = true
            dragged = c
            group = (w.tabGroup?.windows ?? [w]).filter { $0 !== sel }.map { WeakWindow(w: $0) }
        }
        updateZone(mouse)
    }

    /// 元のタブの組の残りで、今選んでいるタブ (なければ先頭)
    private static func partnerWindow() -> NSWindow? {
        let rest = group.compactMap { $0.w }.filter { $0.isVisible && $0.contentView is TerminalContainerView }
        return rest.first { $0.tabGroup?.selectedWindow === $0 } ?? rest.first
    }

    /// マウスの下のセッションのウインドウ (前から順に。中身の範囲の上)
    private static func windowUnder(_ mouse: NSPoint) -> NSWindow? {
        NSApp.orderedWindows.first { w in
            guard w.isVisible, !w.isMiniaturized, w.windowController is SessionWindowController,
                  w.contentView is TerminalContainerView || w.contentView is TabSplitRootView else { return false }
            return w.convertToScreen(w.contentLayoutRect).contains(mouse)
        }
    }

    private static func updateZone(_ mouse: NSPoint) {
        guard let c = dragged, let w = windowUnder(mouse), let cv = w.contentView else { clearZone(); return }
        let pt = w.convertPoint(fromScreen: mouse)
        var r: NSRect?
        var side: SplitDropZone.Side?
        var pane: TabPaneView?
        var label: String?
        if let sp = TabSplit.split(of: w) {
            if let z = sp.dropAt(for: nil, at: pt), z.pane == nil || z.pane?.session !== c {
                side = z.side
                pane = z.pane
                r = z.rect
                label = z.label
            }
        } else if cv is TerminalContainerView {
            let me = w.windowController as? SessionWindowController === c
            let q = cv.convert(pt, from: nil)
            if !me || partnerWindow() != nil, cv.bounds.contains(q), let s = SplitDropZone.side(in: cv.bounds, at: q, flipped: cv.isFlipped) {
                side = s
                r = cv.convert(SplitDropZone.half(of: cv.bounds, side: s, flipped: cv.isFlipped), to: nil)
            }
        }
        guard let rr = r, let s = side else { clearZone(); return }
        zone = s
        zoneWindow = w
        zonePane = pane
        // AppKit のドラッグの絵より上には出せないことがあるが、ウインドウの上には出す
        preview.show(w.convertToScreen(rr), over: w, above: nil, label: label)
    }

    /// 離した: 見本を出していれば、AppKit がドラッグを終えてから分割に入れる
    private static func release() {
        let c = dragged, w = zoneWindow, pane = zonePane, side = zone
        let partner = partnerWindow()
        let wasDragging = dragging
        stop()
        guard wasDragging, let c = c, let tw = w, let s = side else { return }
        handoff(c, into: tw, pane: pane, side: s, partner: partner)
    }

    /// 自己テスト用: 離したときと同じ処理。tearOff なら、AppKit がタブを新しいウインドウにするのをまねる
    static func dropForTest(_ c: SessionWindowController, into tw: NSWindow, pane: TabPaneView?, side: SplitDropZone.Side, partner: NSWindow?, tearOff: Bool) {
        handoff(c, into: tw, pane: pane, side: side, partner: partner)
        if tearOff { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { c.window?.moveTabToNewWindow(nil) } }
    }

    private static func handoff(_ c: SessionWindowController, into tw: NSWindow, pane: TabPaneView?, side s: SplitDropZone.Side, partner: NSWindow?) {
        // AppKit はタブを新しいウインドウにしてから終える。そのウインドウを見せないまま (毎回のランループで見えなくして)、
        // ひとりのウインドウになったら (または少し待っても変わらなければ) すぐに分割に入れる
        HiddenHandoff.run(c.window, timeout: 0.5, ready: {
            guard let cw = c.window else { return true }
            return cw.isVisible && (cw.tabGroup?.windows.count ?? 1) == 1
        }, action: {
            if !drop(c, into: tw, pane: pane, side: s, partner: partner) { c.window?.alphaValue = 1 }
        })
    }

    @discardableResult
    private static func drop(_ c: SessionWindowController, into tw: NSWindow, pane: TabPaneView?, side: SplitDropZone.Side, partner: NSWindow?) -> Bool {
        guard SessionWindowController.all.contains(where: { $0 === c }), c.tabSplit == nil,
              c.window?.contentView is TerminalContainerView else { return false }
        c.tearOffOrigin = nil
        let target: NSWindow
        if let sp = TabSplit.split(of: tw) {
            // pane が nil なら根の端
            if let t = pane, !sp.panes.contains(where: { $0 === t }) { return false }
            guard c !== sp.host else { return false }
            sp.insert(c, at: pane, side: side)
            sp.focus(c)
            target = tw
        } else {
            // ドラッグしたタブ自身のウインドウなら、元のタブの組のほかのタブと分割する
            var host = tw
            if host === c.window || (host.windowController as? SessionWindowController) === c {
                guard let p = partner, p !== c.window else { return false }
                host = p
            }
            guard host.contentView is TerminalContainerView else { return false }
            host.tabGroup?.selectedWindow = host
            TabSplit.startSplit(in: host, with: c, side: side)
            target = host
        }
        if target.isMiniaturized { target.deminiaturize(nil) }
        target.makeKeyAndOrderFront(nil)
        c.tabSplit?.focus(c)
        TabTearOff.schedule()
        return c.tabSplit != nil
    }
}

/// ウインドウを見えなくしたまま (alphaValue 0。AppKit が見せようとしても毎回のランループで戻す) 待ち、
/// ready が true になったら (または timeout で) action を行う。見えるように戻すのは action の側 (ペインになったら detach で戻す)
enum HiddenHandoff {
    /// 実行中の数 (この間は TabTearOff.repair で見える状態に戻さない)
    static var active = 0
    static func run(_ w: NSWindow?, timeout: TimeInterval, ready: @escaping () -> Bool, action: @escaping () -> Void) {
        weak var win = w
        win?.alphaValue = 0
        active += 1
        let deadline = Date().addingTimeInterval(timeout)
        var done = false
        var observer: CFRunLoopObserver?
        var timer: Timer?
        func check() {
            guard !done else { return }
            if let x = win, x.alphaValue != 0 { x.alphaValue = 0 }
            guard ready() || Date() >= deadline else { return }
            done = true
            if let o = observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
            timer?.invalidate()
            DispatchQueue.main.async {
                action()
                active -= 1
                TabTearOff.schedule()   // 入れられなかったときに見える状態へ戻す (repair)
                // AppKit のドラッグの後始末 (タブを組へ戻す) がこのあとに来ることがあるので、少しあとにもう一度見る (rehidePaneWindows)
                for t in [0.4, 1.0, 2.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { TabTearOff.schedule() } }
            }
        }
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, _ in check() }
        if let o = observer { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes) }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
