import AppKit
import TeraCore

// MARK: - タブの分割表示 (Mac 版だけの機能。ウィンドウ > タブ)

/// ウインドウのタブ (それぞれ 1 つの SessionWindowController / NSWindow) を、1 つのウインドウの中に
/// NSSplitView のペインとして並べる。
///
/// - 分割するウインドウ (ホスト) はそのまま使い、中身 (contentView) を TabSplitRootView (NSSplitView) にする。
/// - ほかのタブのウインドウはタブの組から外して隠し (orderOut)、中身の TerminalContainerView をペインに移す。
///   隠したウインドウには空のビューを入れておき、分割をやめたら中身を戻してタブに付け直す。
/// - 並べ方は木 (tmux のような入れ子): 節は TabSplitNodeView (NSSplitView。向きを持ち、子は 2 つ以上)、葉は TabPaneView。
///   根は TabSplitRootView。「この画面を左右/上下に分割」は、フォーカスのあるペインを新しい節に置き換えて、その中を分ける。
/// - 選んだタブ (TabMarks。Shift+クリック・メニューで印を付ける) があれば、今のタブと選んだタブだけを分割する。
///   選ばなかったタブはウインドウのタブのまま残り、分割しているウインドウもその中の 1 つのタブになる。
/// - ウィンドウ内のメニューバー (タイトルバーの飾り) はウインドウごとに付いているので、ホストのものだけが見える。
/// - 応答者の順: ペインの端末 → TerminalContainerView → そのセッションのコントローラ → ペイン → 節 … → ホストのウインドウ。
///   メニューの動作・使える/使えないの判断は、フォーカスのあるペインのセッションが受ける。
final class TabSplit: NSObject, NSSplitViewDelegate {
    /// 分割しているウインドウの一覧
    static var all: [TabSplit] = []

    /// 分割しているウインドウのセッション (そのウインドウを使う。閉じたら残りのペインのどれかのウインドウに移る)
    private(set) var host: SessionWindowController
    let root = TabSplitRootView()
    /// フォーカスのあるペインのセッション
    private(set) weak var focused: SessionWindowController?
    private var resizeWork: DispatchWorkItem?

    var hostWindow: NSWindow? { host.window }
    var hostContainer: TerminalContainerView? { panes.first { $0.session === host }?.container }
    /// ペイン (木をたどった順 = 左から / 上から)
    var panes: [TabPaneView] { TabSplit.leaves(of: root) }
    /// 並びの順 (左から / 上から) のセッション
    var sessions: [SessionWindowController] { panes.compactMap { $0.session } }
    /// いちばん外側を左右に並べているか (NSSplitView の縦の区切り)
    var isSideBySide: Bool { root.isVertical }

    private init(host: SessionWindowController) {
        self.host = host
        super.init()
        setup(root)
        root.autoresizingMask = [.width, .height]
    }

    /// 節 (NSSplitView) の共通の設定
    private func setup(_ n: TabSplitNodeView) {
        n.split = self
        n.dividerStyle = .thin
        n.delegate = self
    }

    private static func leaves(of v: NSView) -> [TabPaneView] {
        if let p = v as? TabPaneView { return [p] }
        if let n = v as? TabSplitNodeView { return n.arrangedSubviews.flatMap { leaves(of: $0) } }
        return []
    }

    static func split(of w: NSWindow?) -> TabSplit? { (w?.contentView as? TabSplitRootView)?.split }

    // MARK: - メニューから

    /// メニューの操作の対象のウインドウ (キーウインドウのセッション。分割中は分割しているウインドウ)
    static var currentWindow: NSWindow? { SessionWindowController.current?.presentingWindow }

    /// ウインドウのタブのうち、まだペインになっていないセッション (タブの順)
    private static func tabSessions(of w: NSWindow) -> [SessionWindowController] {
        (w.tabGroup?.windows ?? [w]).compactMap { x -> SessionWindowController? in
            guard let c = x.windowController as? SessionWindowController, c.tabSplit == nil,
                  x.contentView is TerminalContainerView else { return nil }
            return c
        }
    }

    /// 分割できるペインの数 (分割中はペイン + まだタブのセッション)
    static func paneCount(of w: NSWindow) -> Int {
        if let sp = split(of: w) { return sp.panes.count + tabSessions(of: w).filter { $0.window !== w }.count }
        return tabSessions(of: w).count
    }

    /// タブを左右 (sideBySide) / 上下に分割して並べる。
    /// 選んだタブがあれば、今のタブと選んだタブだけ (タブの順)。なければ全部のタブ。
    /// 分割中なら いちばん外側の向きを変え、選んだタブ (なければ、あとから増えたタブ全部) をいちばん外側のペインにする
    static func splitTabs(of w: NSWindow, sideBySide: Bool) {
        guard TTMado.isEnabled else { return }
        let marked = TabMarks.marked(in: w)
        if let sp = split(of: w) {
            let extra = marked.isEmpty ? tabSessions(of: w).filter { $0.window !== w } : marked
            TabMarks.clear(marked)
            for c in extra { sp.add(c, to: sp.root) }
            sp.root.isVertical = sideBySide
            sp.equalize(sp.root)
            sp.setupResponders()
            sp.refocus()
            return
        }
        guard let host = w.windowController as? SessionWindowController, w.contentView is TerminalContainerView else { return }
        var members = tabSessions(of: w)
        if !marked.isEmpty { members = members.filter { $0 === host || marked.contains($0) } }
        start(host: host, members: members, sideBySide: sideBySide)
        TabMarks.clear(marked)
    }

    /// 分割を始める (members はタブの順。host を含む)
    private static func start(host: SessionWindowController, members: [SessionWindowController], sideBySide: Bool) {
        guard let w = host.window, members.count >= 2, let hostContainer = w.contentView as? TerminalContainerView else { return }
        TabMarks.clear(members)
        let sp = TabSplit(host: host)
        all.append(sp)
        let size = w.contentView?.frame.size ?? w.frame.size
        sp.root.frame = NSRect(origin: .zero, size: size)
        w.contentView = sp.root
        sp.root.isVertical = sideBySide
        for c in members {
            if c === host { sp.attach(c, container: hostContainer, to: sp.root) } else { sp.add(c, to: sp.root) }
        }
        w.contentResizeIncrements = NSSize(width: 1, height: 1)
        sp.equalize(sp.root)
        sp.setupResponders()
        w.makeFirstResponder(host.termView)
        sp.paneFocused(host)
    }

    /// 「この画面を左右/上下に分割」の相手: 選んだタブ (タブの順)。なければ、今のタブの次のタブ (まだペインでないもの。端なら先頭へ回る)
    /// 分割中は、選んだペイン (「この画面を選ぶ」) も相手にする (フォーカスのあるペインの隣に移す)
    static func partners(for w: NSWindow) -> [SessionWindowController] {
        var marked = TabMarks.marked(in: w).filter { $0.window !== w }
        if let sp = split(of: w) {
            let f = sp.focused ?? sp.panes.first?.session
            marked = sp.sessions.filter { $0.paneMarked && $0 !== f } + marked
        }
        if !marked.isEmpty { return marked }
        let ws = w.tabGroup?.windows ?? [w]
        guard let i = ws.firstIndex(where: { $0 === w }), ws.count > 1 else { return [] }
        for k in 1..<ws.count {
            let x = ws[(i + k) % ws.count]
            if let c = x.windowController as? SessionWindowController, c.tabSplit == nil, x.contentView is TerminalContainerView { return [c] }
        }
        return []
    }

    /// フォーカスのあるペインの場所を、左右 (sideBySide) / 上下に分けて、相手のタブを並べる。
    /// 分割していなければ、今のタブと相手で分割するのと同じ
    static func splitFocused(of w: NSWindow, sideBySide: Bool) {
        guard TTMado.isEnabled else { return }
        let list = partners(for: w)
        guard !list.isEmpty else { return }
        TabMarks.clear(TabMarks.marked(in: w))
        split(of: w)?.clearPaneMarks()
        guard let sp = split(of: w) else {
            guard let host = w.windowController as? SessionWindowController else { return }
            let members = tabSessions(of: w).filter { $0 === host || list.contains($0) }
            start(host: host, members: members, sideBySide: sideBySide)
            return
        }
        guard let f = sp.focused ?? sp.panes.first?.session, let target = sp.panes.first(where: { $0.session === f }) else { return }
        sp.splitPane(target, with: list, sideBySide: sideBySide)
    }

    static func canSplitFocused(_ w: NSWindow?) -> Bool { w.map { !partners(for: $0).isEmpty } ?? false }

    /// 分割をやめてタブに戻す (今のウインドウ)
    static func unsplitCurrent() { split(of: currentWindow)?.unsplit() }

    /// すべての分割をやめる (並べて表示・すべてのウインドウをまとめる の前)
    static func unsplitAll() { all.forEach { $0.unsplit(activate: false) } }

    /// タブの組から外して隠す。外した瞬間に単独のウインドウとして一瞬大きく出る (開くアニメーション) のを見せないよう、
    /// 先に透明にしてアニメーションを止めてから外す
    static func hideOutOfTabGroup(_ cw: NSWindow) {
        let anim = cw.animationBehavior
        cw.animationBehavior = .none
        if let g = cw.tabGroup, g.windows.count > 1 {
            cw.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                g.removeWindow(cw)
            })
        }
        cw.orderOut(nil)
        cw.alphaValue = 1
        cw.animationBehavior = anim
    }

    /// すべてのセッションのウインドウを、今のウインドウのタブにする
    static func mergeAllWindows() {
        guard let cur = SessionWindowController.current else { return }
        unsplitAll()
        TabMarks.clearAll()
        guard let target = cur.window else { return }
        for c in SessionWindowController.all {
            guard let x = c.window, x !== target, x.isVisible || x.isMiniaturized else { continue }
            if target.tabGroup?.windows.contains(x) == true { continue }
            if x.isMiniaturized { x.deminiaturize(nil) }
            if let g = x.tabGroup, g.windows.count > 1 { g.removeWindow(x) }
            let last = target.tabGroup?.windows.last ?? target
            last.addTabbedWindow(x, ordered: .above)
        }
        target.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
        target.makeFirstResponder(cur.termView)
    }

    /// 今のタブを新しいウインドウに分ける。分割中はフォーカスのあるペインを取り出して、別のウインドウにする
    static func moveCurrentTabToNewWindow() {
        guard let c = SessionWindowController.current else { return }
        moveToNewWindow(c)
    }

    /// セッション c (タブ・ペイン) を新しいウインドウに分ける。元のウインドウを覚えておき、あとでタブに戻せるようにする (TabTearOff)
    /// mouse があれば (ペインを外にドラッグして離した)、タイトルバーがマウスの下に来るように、大きさ contentSize で置く
    static func moveToNewWindow(_ c: SessionWindowController, at mouse: NSPoint? = nil, contentSize: NSSize? = nil) {
        guard let w = c.presentingWindow else { return }
        TabMarks.clearAll()
        guard let sp = c.tabSplit else {
            let origin = TabTearOff.neighbor(of: w)
            w.moveTabToNewWindow(nil)
            TabTearOff.setOrigin(c, origin)
            return
        }
        let frame = w.frame
        sp.remove(c)
        guard let cw = c.window else { return }
        defer { TabTearOff.setOrigin(c, sp.host) }
        // ホストだったときは、そのウインドウは新しいホストとタブの組になっている
        if let g = cw.tabGroup, g.windows.count > 1 { g.removeWindow(cw) }
        if let m = mouse {
            let cs = contentSize ?? frame.size
            var f = cw.frameRect(forContentRect: NSRect(x: 0, y: 0, width: max(cs.width, 320), height: max(cs.height, 160)))
            f.origin = NSPoint(x: m.x - f.width / 2, y: m.y + 12 - f.height)
            cw.setFrame(f, display: false)
        } else {
            cw.setFrame(frame.offsetBy(dx: 24, dy: -24), display: false)
        }
        // 前に出したときに、キーウインドウのタブに自動で入らないようにする
        let mode = cw.tabbingMode
        cw.tabbingMode = .disallowed
        cw.makeKeyAndOrderFront(nil)
        cw.tabbingMode = mode
        cw.makeFirstResponder(c.termView)
    }

    /// メニューの使える/使えない (ウィンドウ > タブ)
    static func canSplit(_ w: NSWindow?) -> Bool { TTMado.isEnabled && w.map { paneCount(of: $0) >= 2 } ?? false }
    static func canMerge(_ w: NSWindow?) -> Bool {
        guard let w = w else { return false }
        if !all.isEmpty { return true }
        let mine = w.tabGroup?.windows ?? [w]
        return SessionWindowController.all.contains { c in
            guard let x = c.window, x.isVisible || x.isMiniaturized else { return false }
            return !mine.contains(x)
        }
    }
    static func canMoveToNewWindow(_ w: NSWindow?) -> Bool {
        guard let w = w else { return false }
        if split(of: w) != nil { return true }
        return (w.tabGroup?.windows.count ?? 1) > 1
    }

    /// 並べ方の木を文字にする (自己テスト用)。左右は LR(…)、上下は TB(…)
    func layoutDescription(_ name: (SessionWindowController) -> String) -> String {
        func d(_ v: NSView) -> String {
            if let p = v as? TabPaneView { return p.session.map(name) ?? "?" }
            if let n = v as? TabSplitNodeView { return (n.isVertical ? "LR(" : "TB(") + n.arrangedSubviews.map(d).joined(separator: ",") + ")" }
            return "?"
        }
        return d(root)
    }

    // MARK: - ペイン

    /// セッションのウインドウをタブの組から外して隠し、中身を節 node のペインにする
    private func add(_ c: SessionWindowController, to node: TabSplitNodeView) {
        guard let cw = c.window, let container = cw.contentView as? TerminalContainerView else { return }
        TabSplit.hideOutOfTabGroup(cw)
        // 隠したウインドウには空のビュー (中身はペインへ移す)
        cw.contentView = NSView(frame: container.frame)
        attach(c, container: container, to: node)
    }

    private func attach(_ c: SessionWindowController, container: TerminalContainerView, to node: TabSplitNodeView) {
        let pane = TabPaneView(session: c, container: container)
        wire(pane)
        c.paneMarked = false
        node.addArrangedSubview(pane)
        c.tabSplit = self
        c.updateTitle()
    }

    /// ペインの ≡ ボタンを、この分割に結ぶ
    private func wire(_ pane: TabPaneView) {
        pane.menuButton.onPress = { [weak self, weak pane] b in
            guard let self = self, let pane = pane else { return }
            self.paneMenuButtonPressed(pane, button: b)
        }
        pane.menuButton.onDragMove = { [weak self, weak pane] pt in
            guard let self = self, let pane = pane else { return }
            self.paneDragMoved(pane, to: pt)
        }
        pane.menuButton.onDragEnd = { [weak self, weak pane] pt in
            guard let self = self, let pane = pane else { return }
            self.paneDragEnded(pane, at: pt)
        }
        pane.menuButton.onExtendMove = { [weak self, weak pane] start, pt in
            guard let self = self, let pane = pane else { return }
            self.paneExtendMoved(pane, from: start, to: pt)
        }
        pane.menuButton.onExtendEnd = { [weak self, weak pane] start, pt in
            guard let self = self, let pane = pane else { return }
            self.paneExtendEnded(pane, from: start, at: pt)
        }
    }

    /// ペイン target を新しい節 (向き sideBySide) に置き換え、その中に target と list のペインを同じ大きさで並べる
    /// list に、この分割のペインのセッション (選んだペイン) があれば、今の場所から外して target の隣に移す
    private func splitPane(_ target: TabPaneView, with list: [SessionWindowController], sideBySide: Bool) {
        var moving: [TabPaneView] = []
        for c in list where c.tabSplit === self {
            guard let p = panes.first(where: { $0.session === c }), p !== target else { continue }
            let old = p.superview as? TabSplitNodeView
            p.removeFromSuperview()
            moving.append(p)
            if let n = old { collapse(n) }
        }
        guard let parent = target.superview as? TabSplitNodeView,
              let idx = parent.arrangedSubviews.firstIndex(where: { $0 === target }) else { return }
        let frame = target.frame
        let node = TabSplitNodeView(frame: frame)
        setup(node)
        node.isVertical = sideBySide
        target.removeFromSuperview()
        parent.insertArrangedSubview(node, at: idx)
        node.frame = frame
        node.addArrangedSubview(target)
        for c in list {
            if let p = moving.first(where: { $0.session === c }) { node.addArrangedSubview(p) } else if c.tabSplit == nil { add(c, to: node) }
        }
        // 根の子がこの節だけになったら、根に移す
        if root.arrangedSubviews.count == 1, root.arrangedSubviews.first === node {
            collapse(root)
            equalize(root)
        } else {
            equalize(node)
        }
        setupResponders()
        refocus()
    }

    // MARK: - ペインの ≡ メニューから

    /// ペインの「この画面を選ぶ / 選択を外す」
    func togglePaneMark(_ c: SessionWindowController) {
        guard c.tabSplit === self else { return }
        c.paneMarked.toggle()
        panes.first { $0.session === c }?.isMarked = c.paneMarked
    }

    func clearPaneMarks() {
        for p in panes {
            p.session?.paneMarked = false
            p.isMarked = false
        }
    }

    /// ペインにフォーカスを移す
    func focus(_ c: SessionWindowController) {
        guard c.tabSplit === self else { return }
        hostWindow?.makeFirstResponder(c.termView)
        paneFocused(c)
    }

    /// ペインを分割から外して、同じウインドウ (タブの組) のふつうのタブに戻す。残りが 1 つなら分割をやめる
    static func returnPaneToTab(_ c: SessionWindowController) {
        guard let sp = c.tabSplit else { return }
        let wasHost = c === sp.host
        sp.remove(c)
        // ホストだったときは、新しいホストのウインドウと同じタブの組になっている
        guard !wasHost, let cw = c.window, let anchor = sp.host.window, anchor !== cw else { return }
        cw.setFrame(anchor.frame, display: false)
        anchor.addTabbedWindow(cw, ordered: .above)
        anchor.tabGroup?.selectedWindow = anchor
        if let f = SessionWindowController.session(for: anchor) { anchor.makeFirstResponder(f.termView) }
    }

    /// ペインの ≡ メニュー
    func paneMenu(for c: SessionWindowController) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let h = PaneMenuHandler(split: self, session: c)
        PaneMenuHandler.current = h
        func item(_ t: String, _ a: Selector, enabled: Bool = true) -> NSMenuItem {
            let it = NSMenuItem(title: t, action: a, keyEquivalent: "")
            it.target = h
            it.isEnabled = enabled
            m.addItem(it)
            return it
        }
        let mark = item(c.paneMarked ? Lang.m("MENU_PANE_UNMARK", "この画面の選択を外す") : Lang.m("MENU_PANE_MARK", "この画面を選ぶ"),
                        #selector(PaneMenuHandler.toggleMark(_:)), enabled: panes.count > 1)
        mark.state = c.paneMarked ? .on : .off
        m.addItem(.separator())
        let canSplit = hostWindow.map { TabSplit.canSplitFocused($0) } ?? false
        _ = item(Lang.m("MENU_TABS_SPLIT_PANE_SIDEBYSIDE", "この画面を左右に分割"), #selector(PaneMenuHandler.splitSideBySide(_:)), enabled: canSplit)
        _ = item(Lang.m("MENU_TABS_SPLIT_PANE_STACKED", "この画面を上下に分割"), #selector(PaneMenuHandler.splitStacked(_:)), enabled: canSplit)
        // 端まで伸ばす (上下左右。伸ばせない向きは選べない)
        let ext = NSMenuItem(title: Lang.m("MENU_PANE_EXTEND", "端まで伸ばす"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let dirs: [(String, String, ExtendDirection)] = [
            ("MENU_PANE_EXTEND_UP", "上へ", .up), ("MENU_PANE_EXTEND_DOWN", "下へ", .down),
            ("MENU_PANE_EXTEND_LEFT", "左へ", .left), ("MENU_PANE_EXTEND_RIGHT", "右へ", .right)]
        var any = false
        for (i, d) in dirs.enumerated() {
            let it = NSMenuItem(title: Lang.m(d.0, d.1), action: #selector(PaneMenuHandler.extend(_:)), keyEquivalent: "")
            it.target = h
            it.tag = i
            it.isEnabled = canExtend(c, dir: d.2)
            any = any || it.isEnabled
            sub.addItem(it)
        }
        ext.submenu = sub
        ext.isEnabled = any
        m.addItem(ext)
        m.addItem(.separator())
        _ = item(Lang.m("MENU_PANE_TO_TAB", "タブに戻す"), #selector(PaneMenuHandler.returnToTab(_:)))
        _ = item(Lang.m("MENU_PANE_TO_NEW_WINDOW", "新しいウィンドウに分ける"), #selector(PaneMenuHandler.moveToNewWindow(_:)))
        m.addItem(.separator())
        _ = item(Lang.m("MENU_PANE_CLOSE", "閉じる"), #selector(PaneMenuHandler.close(_:)))
        return m
    }

    /// ペインの ≡ ボタンを押した: そのペインにフォーカスを移して、メニューを出す
    /// 見出しの右クリック: その位置にこの画面のメニューを出す
    func showPaneMenu(_ p: TabPaneView, event: NSEvent, in view: NSView) {
        guard let c = p.session else { return }
        focus(c)
        NSMenu.popUpContextMenu(paneMenu(for: c), with: event, for: view)
    }

    func paneMenuButtonPressed(_ p: TabPaneView, button: NSView) {
        guard let c = p.session else { return }
        focus(c)
        let m = paneMenu(for: c)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
    }

    // MARK: - ペインのドラッグで並べ替え (≡ ボタンをつかんで、ほかのペインの上に落とす)

    typealias DropSide = SplitDropZone.Side

    /// ドラッグ中の行き先の見本
    private let dropPreview = SplitDropPreview()

    // MARK: 根の端 (ここに落とすと、いちばん外側に並べて、その辺の端から端まで使う)

    /// 根の端の幅
    static let edgeWidth: CGFloat = 28
    /// 根の向きが違うとき (包んで並べるとき) の、新しいペインの割合
    static let edgeShare: CGFloat = 0.34
    static var edgeLabel: String { Lang.m("MENU_PANE_DROP_EDGE", "端に並べる") }

    /// ウインドウの座標 pt が根の端 (edgeWidth 以内) なら、そのいちばん近い側
    func edgeSide(at pt: NSPoint) -> DropSide? {
        let r = root.convert(root.bounds, to: nil)
        guard r.contains(pt) else { return nil }
        let d: [(DropSide, CGFloat)] = [(.left, pt.x - r.minX), (.right, r.maxX - pt.x), (.above, r.maxY - pt.y), (.below, pt.y - r.minY)]
        guard let m = d.min(by: { $0.1 < $1.1 }), m.1 < TabSplit.edgeWidth else { return nil }
        return m.0
    }

    /// 端に並べたあとの場所 (ウインドウの座標)。p は動かすペイン (ほかから入れるなら nil)。
    /// 根が同じ向きなら、根の子をそろえたときの 1 つ分。違えば edgeShare
    func edgeRect(for p: TabPaneView?, side: DropSide) -> NSRect {
        let r = root.convert(root.bounds, to: nil)
        let vertical = side.isSideBySide
        let axis = vertical ? r.width : r.height
        let kids = root.arrangedSubviews.filter { $0 !== p }
        let len: CGFloat
        if root.isVertical == vertical || kids.count <= 1 {
            let m = CGFloat(kids.count + 1)
            len = (axis - root.dividerThickness * (m - 1)) / m
        } else {
            len = (axis * TabSplit.edgeShare).rounded(.down)
        }
        switch side {
        case .left: return NSRect(x: r.minX, y: r.minY, width: len, height: r.height)
        case .right: return NSRect(x: r.maxX - len, y: r.minY, width: len, height: r.height)
        case .above: return NSRect(x: r.minX, y: r.maxY - len, width: r.width, height: len)   // ウインドウの座標は下から上
        case .below: return NSRect(x: r.minX, y: r.minY, width: r.width, height: len)
        }
    }

    /// 行き先: 根の端 (ペインは nil) を先に、なければペインの 4 つの場所。rect は見本 (ウインドウの座標)、label は見本の説明
    func dropAt(for p: TabPaneView?, at pt: NSPoint) -> (pane: TabPaneView?, side: DropSide, rect: NSRect, label: String?)? {
        if let e = edgeSide(at: pt) { return (nil, e, edgeRect(for: p, side: e), TabSplit.edgeLabel) }
        guard let (t, side) = dropTarget(for: p, at: pt) else { return nil }
        return (t, side, dropRect(for: p, target: t, side: side), nil)
    }

    /// ウインドウの座標 pt の下のペイン (ドラッグしているペイン p 以外) と、落とす場所
    func dropTarget(for p: TabPaneView?, at pt: NSPoint) -> (TabPaneView, DropSide)? {
        for t in panes where t !== p {
            let q = t.convert(pt, from: nil)
            guard t.bounds.contains(q), let side = SplitDropZone.side(in: t.bounds, at: q, flipped: t.isFlipped) else { continue }
            return (t, side)
        }
        return nil
    }

    /// 落としたあとのペイン p (新しく入れるなら nil) の場所 (ウインドウの座標)。
    /// 相手の親の節が同じ向きなら、その節の中の新しい区切り (同じ大きさにそろえたとき) の場所。違えば、相手の半分
    func dropRect(for p: TabPaneView?, target t: TabPaneView, side: DropSide) -> NSRect {
        let vertical = side.isSideBySide
        if let parent = t.superview as? TabSplitNodeView, parent.isVertical == vertical {
            let sibs = parent.arrangedSubviews.filter { $0 !== p }
            let m = sibs.count + 1
            let th = parent.dividerThickness
            let b = parent.bounds
            let len = ((vertical ? b.width : b.height) - th * CGFloat(m - 1)) / CGFloat(m)
            let idx = (sibs.firstIndex(where: { $0 === t }) ?? 0) + (side.isAfter ? 1 : 0)
            let start = CGFloat(idx) * (len + th)
            let r = vertical ? NSRect(x: start, y: 0, width: len, height: b.height)
                             : NSRect(x: 0, y: start, width: b.width, height: len)
            return parent.convert(r, to: nil)   // NSSplitView は上から下の座標
        }
        return t.convert(SplitDropZone.half(of: t.bounds, side: side, flipped: t.isFlipped), to: nil)
    }

    /// ウインドウの座標 pt が、分割の上 (タイトルバー・タブのバー・ウィンドウ内のメニューバー) にあるか
    private func isOverTopBar(_ pt: NSPoint) -> Bool {
        guard let w = hostWindow else { return false }
        let top = root.convert(root.bounds, to: nil).maxY
        return pt.x >= 0 && pt.x <= w.frame.width && pt.y >= top && pt.y <= w.frame.height
    }

    /// 分割の上の帯 (画面の座標)
    private func topBarRect() -> NSRect? {
        guard let w = hostWindow else { return nil }
        let top = root.convert(root.bounds, to: nil).maxY
        let f = w.frame
        return NSRect(x: f.minX, y: f.minY + top, width: f.width, height: max(22, f.height - top))
    }

    /// ≡ ボタンのドラッグの行き先
    private enum PaneDrop {
        case none
        /// 同じウインドウのペインの隣 (並べ替え)。ペインが nil なら根の端
        case pane(TabPaneView?, DropSide, NSRect, String?)
        /// 同じウインドウの上の帯 → タブに戻す
        case backToTab
        /// ほかのウインドウのタイトルバー・タブのバー → そのウインドウのタブにする
        case otherTab(NSWindow)
        /// ほかのウインドウの中身 → その分割に入れる
        case otherZone(NSWindow, TabPaneView?, DropSide, NSRect, String?)
        /// どのウインドウの上でもない → 新しいウインドウにする
        case outside(NSPoint)
    }

    private func paneDrop(for p: TabPaneView, at pt: NSPoint) -> PaneDrop {
        guard let w = hostWindow else { return .none }
        let mouse = w.convertPoint(toScreen: pt)
        let under = TabTearOff.sessionWindow(at: mouse, excluding: nil)
        if under === w || (under == nil && w.frame.contains(mouse)) {
            if isOverTopBar(pt) { return .backToTab }
            if let z = dropAt(for: p, at: pt) { return .pane(z.pane, z.side, z.rect, z.label) }
            return .none
        }
        guard let tw = under else { return .outside(mouse) }
        if TabTearOff.barRect(of: tw).contains(mouse) { return .otherTab(tw) }
        if let z = TabTearOff.zone(in: tw, mouse: mouse) { return .otherZone(tw, z.pane, z.side, z.rect, z.label) }
        return .none
    }

    /// ≡ ボタンのドラッグ中: 行き先の見本を出す (自分の上・ペインの外・ウインドウの外なら出さない)。
    /// 上の帯 (タイトルバーなど) の上なら、その帯に「タブに戻す」を出す
    func paneDragMoved(_ p: TabPaneView, to pt: NSPoint) {
        guard let w = hostWindow else { dropPreview.hide(); PaneDragGhost.shared.hide(); return }
        let drop = paneDrop(for: p, at: pt)
        // ウインドウの外へ出したら、タブを引き出したときと同じように、画面の半透明の写しをマウスに付けて見せる
        if case .outside(let mouse) = drop { PaneDragGhost.shared.show(p, at: mouse) } else { PaneDragGhost.shared.hide() }
        switch drop {
        case .backToTab:
            if let r = topBarRect() { dropPreview.show(r, over: w, above: nil, label: Lang.m("MENU_PANE_DROP_TO_TAB", "離すとタブに戻ります")) }
        case .pane(_, _, let r, let label):
            dropPreview.show(w.convertToScreen(r), over: w, above: nil, label: label)
        case .otherTab(let tw):
            dropPreview.show(TabTearOff.barRect(of: tw), over: tw, above: nil, label: Lang.m("MENU_PANE_DROP_AS_TAB", "離すとこのウィンドウのタブになります"))
        case .otherZone(let tw, _, _, let r, let label):
            dropPreview.show(r, over: tw, above: nil, label: label)
        case .none, .outside:
            dropPreview.hide()
        }
    }

    /// ≡ ボタンのドラッグを終えた (pt が nil なら Esc で取り消し)
    func paneDragEnded(_ p: TabPaneView, at pt: NSPoint?) {
        dropPreview.hide()
        PaneDragGhost.shared.hide(forget: true)
        guard let pt = pt, let c = p.session else { return }
        switch paneDrop(for: p, at: pt) {
        case .none:
            break
        case .backToTab:
            TabSplit.returnPaneToTab(c)
        case .pane(let t, let side, _, _):
            movePane(p, to: t, side: side)
        case .otherTab(let tw):
            remove(c)
            if let cw = c.window { TabTearOff.mergeAsTab(cw, into: tw) }
        case .otherZone(let tw, let pane, let side, _, _):
            remove(c)
            guard let cw = c.window else { return }
            cw.alphaValue = 0
            if !TabSplit.mergeWindow(cw, into: tw, pane: pane, side: side) { cw.alphaValue = 1 }
        case .outside(let mouse):
            TabSplit.moveToNewWindow(c, at: mouse, contentSize: p.bounds.size)
        }
    }

    /// ほかのウインドウのセッション c を、ペイン t の side に入れる (タブを引き出してこのウインドウの上に落とした)
    func insert(_ c: SessionWindowController, at t: TabPaneView?, side: DropSide) {
        guard c.tabSplit == nil, c !== host else { return }
        add(c, to: root)
        guard let p = panes.first(where: { $0.session === c }) else { return }
        setupResponders()
        movePane(p, to: t, side: side)
    }

    /// 分割していないウインドウ w の今のタブと、セッション c で分割を始める (c を side の側に置く)
    static func startSplit(in w: NSWindow, with c: SessionWindowController, side: DropSide) {
        guard split(of: w) == nil, let host = w.windowController as? SessionWindowController, host !== c,
              w.contentView is TerminalContainerView, c.tabSplit == nil else { return }
        start(host: host, members: side.isAfter ? [host, c] : [c, host], sideBySide: side.isSideBySide)
        c.tabSplit?.focus(c)
    }

    /// ペイン p を、ペイン t の side に移す。
    /// t の親の節が同じ向きなら、その節の中で t の前/後ろに入れる (並べ替え)。違えば t を新しい節に置き換えて、その中に並べる
    /// t が nil なら根の端 (いちばん外側) に並べる
    func movePane(_ p: TabPaneView, to t: TabPaneView?, side: DropSide) {
        guard p !== t, let oldParent = p.superview as? TabSplitNodeView else { return }
        let vertical = side.isSideBySide
        let after = side.isAfter
        // 同じ節の中の並べ替えなら、外して入れ直すだけ
        if let t = t, let parent = t.superview as? TabSplitNodeView, parent === oldParent, parent.isVertical == vertical {
            p.removeFromSuperview()
            guard let i = parent.arrangedSubviews.firstIndex(where: { $0 === t }) else { return }
            parent.insertArrangedSubview(p, at: i + (after ? 1 : 0))
            finishMove(p, equalizing: parent)
            return
        }
        // 今の場所から外す (子が 1 つになった節はなくす)
        p.removeFromSuperview()
        collapse(oldParent)
        guard let n = place(p, at: t, side: side) else { return }
        finishMove(p, equalizing: n)
    }

    /// 木の外のビュー v (ペインか節) を、ペイン t の side に入れる。そろえる節を返す。
    /// t の親の節が同じ向き (または子が 1 つの根) なら、その節の中の t の前/後ろに入れる。違えば t を新しい節に置き換えて、その中に並べる。
    /// v が入れる先と同じ向きの節なら、その子を直接入れる (同じ向きの節を入れ子にしない)
    private func place(_ v: NSView, at t: TabPaneView?, side: DropSide) -> TabSplitNodeView? {
        let vertical = side.isSideBySide
        let after = side.isAfter
        guard let t = t else { return placeAtEdge(v, side: side) }
        guard let parent = t.superview as? TabSplitNodeView,
              let i = parent.arrangedSubviews.firstIndex(where: { $0 === t }) else { return nil }
        if parent.isVertical == vertical || parent.arrangedSubviews.count == 1 {
            parent.isVertical = vertical
            insertFlattening(v, into: parent, at: i + (after ? 1 : 0))
            return parent
        }
        let frame = t.frame
        let node = TabSplitNodeView(frame: frame)
        setup(node)
        node.isVertical = vertical
        t.removeFromSuperview()
        parent.insertArrangedSubview(node, at: i)
        node.frame = frame
        node.addArrangedSubview(t)
        insertFlattening(v, into: node, at: after ? 1 : 0)
        // 根の子がこの節だけになったら、根に移す
        if root.arrangedSubviews.count == 1, root.arrangedSubviews.first === node {
            collapse(root)
            return root
        }
        return parent
    }

    /// 木の外のビュー v を、根の端に並べる (その辺の端から端まで)。
    /// 根が同じ向き (または子が 1 つ) なら根の最初/最後に入れる。違えば、根の子を新しい節に包んで、根をその向きにして並べる
    /// (このときは v を edgeShare の大きさにする)
    private func placeAtEdge(_ v: NSView, side: DropSide) -> TabSplitNodeView {
        let vertical = side.isSideBySide
        let after = side.isAfter
        if root.isVertical == vertical || root.arrangedSubviews.count <= 1 {
            root.isVertical = vertical
            insertFlattening(v, into: root, at: after ? root.arrangedSubviews.count : 0)
            return root
        }
        let inner = TabSplitNodeView(frame: root.bounds)
        setup(inner)
        inner.isVertical = root.isVertical
        for k in root.arrangedSubviews {
            let f = k.frame
            k.removeFromSuperview()
            inner.addArrangedSubview(k)
            k.frame = f
        }
        root.isVertical = vertical
        root.addArrangedSubview(inner)
        inner.frame = root.bounds
        insertFlattening(v, into: root, at: after ? 1 : 0)
        // そろえたあと (equalize は次の回にももう一度そろえる) に、v の大きさを決める
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak v] in
            guard let self = self, let v = v, v.superview === self.root else { return }
            let axis = vertical ? self.root.bounds.width : self.root.bounds.height
            self.setLength(of: v, in: self.root, to: (axis * TabSplit.edgeShare).rounded(.down))
        }
        return root
    }

    private func insertFlattening(_ v: NSView, into parent: TabSplitNodeView, at idx: Int) {
        if let n = v as? TabSplitNodeView, n.isVertical == parent.isVertical {
            for (k, x) in n.arrangedSubviews.enumerated() {
                x.removeFromSuperview()
                parent.insertArrangedSubview(x, at: min(idx + k, parent.arrangedSubviews.count))
            }
            return
        }
        parent.insertArrangedSubview(v, at: min(idx, parent.arrangedSubviews.count))
    }

    // MARK: - ウインドウを、ほかのウインドウの分割に入れる (タイトルバーをつかんで中身の上に落とす)

    /// ウインドウ w (分割していてもよい) を、ウインドウ tw の side に入れる。tw が分割中ならペイン pane の隣。
    /// w が分割していれば、その並べ方のまま入れる。tw が分割していなければ、tw の今のタブで分割を始める
    /// 入れたら true
    @discardableResult
    static func mergeWindow(_ w: NSWindow, into tw: NSWindow, pane: TabPaneView?, side: DropSide) -> Bool {
        guard TTMado.isEnabled, w !== tw else { return false }
        let src = split(of: w)
        let single = w.windowController as? SessionWindowController
        guard src != nil || (single != nil && single?.tabSplit == nil && w.contentView is TerminalContainerView) else { return false }
        if tw.isMiniaturized { tw.deminiaturize(nil) }
        let sp: TabSplit
        let target: TabPaneView?   // 分割中で nil なら根の端
        if let x = split(of: tw) {
            if let t = pane, !x.panes.contains(where: { $0 === t }) { return false }
            sp = x
            target = pane
        } else {
            guard let host = tw.windowController as? SessionWindowController, host !== single,
                  let x = begin(host: host), let t = x.panes.first else { return false }
            sp = x
            target = t
        }
        if let s2 = src {
            sp.adopt(s2, at: target, side: side)
        } else if let c = single {
            sp.insert(c, at: target, side: side)
            sp.focus(c)
        }
        tw.makeKeyAndOrderFront(nil)
        sp.refocus()
        return true
    }

    /// ウインドウの今のタブ 1 つだけで分割を始める (このあと、ほかのペインを入れる)
    private static func begin(host: SessionWindowController) -> TabSplit? {
        guard let w = host.window, let hc = w.contentView as? TerminalContainerView else { return nil }
        TabMarks.clear([host])
        let sp = TabSplit(host: host)
        all.append(sp)
        sp.root.frame = NSRect(origin: .zero, size: hc.frame.size)
        w.contentView = sp.root
        sp.attach(host, container: hc, to: sp.root)
        w.contentResizeIncrements = NSSize(width: 1, height: 1)
        sp.setupResponders()
        sp.paneFocused(host)
        return sp
    }

    /// ほかの分割 src の木 (節とペイン) を、並べ方のまま、ペイン t の side に移す。src のウインドウはほかのペインのウインドウと同じく隠す
    private func adopt(_ src: TabSplit, at t: TabPaneView?, side: DropSide) {
        guard src !== self else { return }
        let moved = src.panes
        let focusTo = src.focused ?? moved.first?.session
        let oldHost = src.host
        TabSplit.all.removeAll { $0 === src }
        src.resizeWork?.cancel()
        src.resizeWork = nil
        // 根の子を新しい節に移す
        let node = TabSplitNodeView(frame: src.root.bounds)
        setup(node)
        node.isVertical = src.root.isVertical
        for k in src.root.arrangedSubviews {
            let f = k.frame
            k.removeFromSuperview()
            node.addArrangedSubview(k)
            k.frame = f
        }
        func retag(_ v: NSView) {
            guard let n = v as? TabSplitNodeView else { return }
            setup(n)
            n.arrangedSubviews.forEach(retag)
        }
        node.arrangedSubviews.forEach(retag)
        for p in moved {
            wire(p)
            p.isMarked = false
            p.session?.paneMarked = false
            p.session?.tabSplit = self
            p.session?.updateTitle()
        }
        // 元の分割のウインドウは、空のビューを入れて隠す (ほかのタブはその組に残る)
        if let cw = oldHost.window {
            TabSplit.hideOutOfTabGroup(cw)
            cw.contentView = NSView(frame: src.root.frame)
        }
        var v: NSView = node
        if node.arrangedSubviews.count == 1, let only = node.arrangedSubviews.first {
            only.removeFromSuperview()
            v = only
        }
        guard let n = place(v, at: t, side: side) else { return }
        equalize(n.window != nil ? n : root)
        setupResponders()
        if let c = focusTo { focus(c) }
        scheduleResizeFlush()
    }

    // MARK: - ≡ のドラッグで、ペインをその向きの端まで伸ばす

    /// 伸ばす向き
    enum ExtendDirection { case up, down, left, right }

    /// 伸ばし方: 節 n (向きが伸ばす向きと同じ) を、ペイン p と新しい節 (直角の向き) で包む。p は side の側 (前なら true)
    private struct ExtendPlan {
        let node: TabSplitNodeView
        let pFirst: Bool
        let dir: ExtendDirection
    }

    /// 押した位置 start から今の位置 pt (ウインドウの座標) への、伸ばす向き (12pt より動いたら、大きく動いた向き)
    private func extendDirection(from start: NSPoint, to pt: NSPoint) -> ExtendDirection? {
        let dx = pt.x - start.x, dy = pt.y - start.y
        guard max(abs(dx), abs(dy)) > 12 else { return nil }
        if abs(dy) > abs(dx) { return dy < 0 ? .down : .up }
        return dx > 0 ? .right : .left
    }

    /// ペイン p を dir の向きに伸ばせるか。
    /// p から上へたどり、向きが同じで、p を含む枝 X のその向きの先に何かがある、いちばん近い節 N を探す。
    /// その途中の直角の向きの節では、p の枝がいつも同じ端 (最初か最後) にあること (その端が、伸ばしたあとの p の側)
    private func extendPlan(_ p: TabPaneView, dir: ExtendDirection) -> ExtendPlan? {
        let stacked = dir == .up || dir == .down
        let forward = dir == .down || dir == .right
        var child: NSView = p
        var node = p.superview as? TabSplitNodeView
        var canFirst = true, canLast = true, crossed = false
        while let n = node {
            let kids = n.arrangedSubviews
            guard let i = kids.firstIndex(where: { $0 === child }) else { return nil }
            if n.isVertical != stacked {
                // 同じ向き (上下に並べる節で上下に伸ばす など)
                if forward ? i < kids.count - 1 : i > 0 {
                    guard crossed, canFirst != canLast else { return nil }
                    return ExtendPlan(node: n, pFirst: canFirst, dir: dir)
                }
            } else {
                crossed = true
                if i != 0 { canFirst = false }
                if i != kids.count - 1 { canLast = false }
                if !canFirst && !canLast { return nil }
            }
            child = n
            node = n.superview as? TabSplitNodeView
        }
        return nil
    }

    /// 伸ばしたあとの p の場所 (ウインドウの座標)
    private func extendRect(_ p: TabPaneView, plan: ExtendPlan) -> NSRect {
        let r = plan.node.convert(plan.node.bounds, to: nil)
        let pr = p.convert(p.bounds, to: nil)
        switch plan.dir {
        case .up, .down:
            let w = pr.width
            return NSRect(x: plan.pFirst ? r.minX : r.maxX - w, y: r.minY, width: w, height: r.height)
        case .left, .right:
            let h = pr.height
            // ウインドウの座標は下から上。最初 (上) なら上端に
            return NSRect(x: r.minX, y: plan.pFirst ? r.maxY - h : r.minY, width: r.width, height: h)
        }
    }

    func paneExtendMoved(_ p: TabPaneView, from start: NSPoint, to pt: NSPoint) {
        guard let w = hostWindow, let dir = extendDirection(from: start, to: pt), let plan = extendPlan(p, dir: dir) else { dropPreview.hide(); return }
        dropPreview.show(w.convertToScreen(extendRect(p, plan: plan)), over: w, above: nil, label: Lang.m("MENU_PANE_EXTEND_HERE", "ここまで伸ばす"))
    }

    /// pt が nil なら Esc で取り消し
    func paneExtendEnded(_ p: TabPaneView, from start: NSPoint, at pt: NSPoint?) {
        dropPreview.hide()
        guard let pt = pt, let dir = extendDirection(from: start, to: pt), let plan = extendPlan(p, dir: dir) else { return }
        extend(p, plan: plan)
    }

    /// 伸ばす: p を外し (子が 1 つになった節はなくす)、N を [N の残り, p] (直角の向き) の節で置き換える。
    /// N が根なら、根の子を新しい節に移してから、根を直角の向きにする。p の幅 (上下に伸ばすとき) / 高さは、だいたいそのまま
    /// メニューから: セッション c のペインを dir の向きの端まで伸ばせるか / 伸ばす
    func canExtend(_ c: SessionWindowController, dir: ExtendDirection) -> Bool {
        guard let p = panes.first(where: { $0.session === c }) else { return false }
        return extendPlan(p, dir: dir) != nil
    }
    func extendPane(_ c: SessionWindowController, dir: ExtendDirection) {
        guard let p = panes.first(where: { $0.session === c }), let plan = extendPlan(p, dir: dir) else { return }
        extend(p, plan: plan)
    }

    private func extend(_ p: TabPaneView, plan: ExtendPlan) {
        let n = plan.node
        let sideBySide = plan.dir == .up || plan.dir == .down
        let keep = sideBySide ? p.frame.width : p.frame.height
        guard let old = p.superview as? TabSplitNodeView else { return }
        p.removeFromSuperview()
        collapse(old)
        guard n.window != nil else { return }
        let container: TabSplitNodeView
        if n === root {
            let inner = TabSplitNodeView(frame: root.bounds)
            setup(inner)
            inner.isVertical = root.isVertical
            for k in root.arrangedSubviews {
                let f = k.frame
                k.removeFromSuperview()
                inner.addArrangedSubview(k)
                k.frame = f
            }
            root.isVertical = sideBySide
            root.addArrangedSubview(inner)
            inner.frame = root.bounds
            container = root
        } else {
            guard let parent = n.superview as? TabSplitNodeView,
                  let i = parent.arrangedSubviews.firstIndex(where: { $0 === n }) else { return }
            let f = n.frame
            let m = TabSplitNodeView(frame: f)
            setup(m)
            m.isVertical = sideBySide
            n.removeFromSuperview()
            parent.insertArrangedSubview(m, at: i)
            m.frame = f
            m.addArrangedSubview(n)
            n.frame = m.bounds
            container = m
        }
        container.insertArrangedSubview(p, at: plan.pFirst ? 0 : container.arrangedSubviews.count)
        setLength(of: p, in: container, to: keep)
        setupResponders()
        if let c = p.session {
            hostWindow?.makeFirstResponder(c.termView)
            paneFocused(c)
        }
        scheduleResizeFlush()
    }

    /// 2 つの子の節 node で、端の子 p の長さ (節の向き) を len にする (区切りの位置で決める。レイアウトのあとにもう一度)
    private func setLength(of p: NSView, in node: TabSplitNodeView, to len: CGFloat, again: Bool = true) {
        let subs = node.arrangedSubviews
        guard subs.count >= 2, let i = subs.firstIndex(where: { $0 === p }) else { return }
        for k in 0..<subs.count { node.setHoldingPriority(.defaultLow, forSubviewAt: k) }
        node.layoutSubtreeIfNeeded()
        let total = node.isVertical ? node.bounds.width : node.bounds.height
        let t = node.dividerThickness
        let l = min(max(len, 40), max(40, total - t - 40)).rounded(.down)
        if i == 0 {
            node.setPosition(l, ofDividerAt: 0)
        } else if i == subs.count - 1 {
            node.setPosition(total - l - t, ofDividerAt: subs.count - 2)
        }
        node.adjustSubviews()
        if again {
            DispatchQueue.main.async { [weak self, weak node, weak p] in
                guard let self = self, let node = node, let p = p, node.window != nil else { return }
                self.setLength(of: p, in: node, to: len, again: false)
            }
        }
    }

    /// 移したあと: 節をそろえ、移したペインにフォーカスを置き、端末の大きさを相手に知らせる
    private func finishMove(_ p: TabPaneView, equalizing node: TabSplitNodeView) {
        equalize(node.window != nil ? node : root)
        setupResponders()
        if let c = p.session {
            hostWindow?.makeFirstResponder(c.termView)
            paneFocused(c)
        }
        scheduleResizeFlush()
    }

    /// 節の子を同じ大きさにする (入れ子の節は、その中の割合のまま大きさが変わる)
    /// 節の中のペインを同じ大きさにする。
    /// 直接 frame を決めるだけだと、NSSplitView が自動レイアウトで決め直したときに最後のペインの幅が 0 になる
    /// (見えないが存在はする) ことがあったので、どの子も同じ holdingPriority にして、区切りの位置 (setPosition) で決める。
    /// レイアウトが済んでいないと位置が効かないので、次の回でもう一度そろえる
    func equalize(_ node: TabSplitNodeView, again: Bool = true) {
        let subs = node.arrangedSubviews
        let n = subs.count
        guard n > 0 else { return }
        for i in 0..<n { node.setHoldingPriority(.defaultLow, forSubviewAt: i) }
        node.layoutSubtreeIfNeeded()
        let t = node.dividerThickness
        let b = node.bounds
        let vertical = node.isVertical
        let total = (vertical ? b.width : b.height) - t * CGFloat(n - 1)
        let len = (total / CGFloat(n)).rounded(.down)
        if n > 1, len > 0 {
            for i in 0..<(n - 1) { node.setPosition(len * CGFloat(i + 1) + t * CGFloat(i), ofDividerAt: i) }
        }
        node.adjustSubviews()
        // 入れ子の節もそろえる
        for v in subs { if let child = v as? TabSplitNodeView { equalize(child, again: false) } }
        if again {
            DispatchQueue.main.async { [weak self, weak node] in
                guard let self = self, let node = node, node.window != nil else { return }
                self.equalize(node, again: false)
            }
        }
    }

    /// ペインの端末の次の応答者を、そのセッションにする (ホストのセッションはウインドウのコントローラなので、そのまま)
    private func setupResponders() {
        PaneCountBadge.refreshAll()
        for p in panes {
            guard let c = p.session else { continue }
            if c === host {
                p.container.paneResponder = nil
                c.paneNextResponder = nil
            } else {
                p.container.paneResponder = c
                c.paneNextResponder = p
            }
        }
    }

    /// 並べ替えのあと、フォーカスのあったペインの端末にキー入力を戻す (ビューを付け替えると外れるため)
    private func refocus() {
        guard let f = focused ?? panes.first?.session else { return }
        hostWindow?.makeFirstResponder(f.termView)
        paneFocused(f)
    }

    /// ペインの端末がファーストレスポンダになった
    func paneFocused(_ c: SessionWindowController?) {
        guard let c = c else { return }
        let list = panes
        guard list.contains(where: { $0.session === c }) else { return }
        focused = c
        for p in list { p.isFocused = p.session === c }
        titlesChanged()
    }

    /// ホストのウインドウのタイトルは、フォーカスのあるペインのセッションのタイトル
    func titlesChanged() {
        PaneCountBadge.refreshAll()
        // 各ペインの見出しにタブと同じタイトル
        for p in panes { if let c = p.session, p.header.title != c.displayTitle { p.header.title = c.displayTitle } }
        guard let w = hostWindow, let f = focused ?? panes.first?.session else { return }
        if w.title != f.displayTitle { w.title = f.displayTitle }
        if w.tab.title != f.displayTitle { w.tab.title = f.displayTitle }
    }

    // MARK: - 端末の大きさ

    /// 区切りのドラッグ中は、落ち着いてから相手に知らせる (シェルがプロンプトを何度も描き直さないように)
    func scheduleResizeFlush() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushResizes() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func flushResizes() {
        resizeWork?.cancel()
        resizeWork = nil
        for c in sessions {
            guard let (cols, rows) = c.pendingResize else { continue }
            c.pendingResize = nil
            c.conn?.resize(cols: cols, rows: rows)
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if hostWindow?.inLiveResize != true { scheduleResizeFlush() }
    }

    /// ペインを小さくしすぎない (2 行・10 桁くらい。入れ子の節は中のペインの分)
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let subs = splitView.arrangedSubviews
        guard dividerIndex < subs.count else { return proposedMinimumPosition }
        let v = subs[dividerIndex], vertical = splitView.isVertical
        return max(proposedMinimumPosition, (vertical ? v.frame.minX : v.frame.minY) + minLength(v, vertical: vertical))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let subs = splitView.arrangedSubviews
        guard dividerIndex + 1 < subs.count else { return proposedMaximumPosition }
        let v = subs[dividerIndex + 1], vertical = splitView.isVertical
        return min(proposedMaximumPosition, (vertical ? v.frame.maxX : v.frame.maxY) - minLength(v, vertical: vertical) - splitView.dividerThickness)
    }

    /// ビュー (ペインか節) の、左右 (vertical) / 上下の向きのいちばん小さい長さ
    private func minLength(_ v: NSView, vertical: Bool) -> CGFloat {
        if let n = v as? TabSplitNodeView {
            let kids = n.arrangedSubviews.map { minLength($0, vertical: vertical) }
            guard !kids.isEmpty else { return 40 }
            return n.isVertical == vertical ? kids.reduce(0, +) + n.dividerThickness * CGFloat(kids.count - 1) : (kids.max() ?? 40)
        }
        guard let tv = (v as? TabPaneView)?.session?.termView else { return 40 }
        return vertical ? tv.cellW * 10 + 8 : tv.cellH * 2 + 8
    }

    // MARK: - 外す・やめる

    /// セッションをペインから外す (閉じる・新しいウインドウに分ける)。中身は自分のウインドウに戻す (隠れたまま)。
    /// ホストのセッションなら、分割は残りのペインのウインドウに移る。残りが 1 つなら分割をやめる。
    /// 子が 1 つになった節は、その子に置き換える
    func remove(_ c: SessionWindowController) {
        let before = panes
        guard let i = before.firstIndex(where: { $0.session === c }) else { return }
        let wasFocused = focused === c
        if c === host {
            let others = before.compactMap { $0.session }.filter { $0 !== c }
            if let next = others.first(where: { $0 === focused }) ?? others.first { rehost(to: next) }
        }
        let pane = before[i]
        let parent = pane.superview as? TabSplitNodeView
        detach(pane)
        if panes.count <= 1 { unsplit(); return }
        if let p = parent { collapse(p) }
        root.adjustSubviews()
        // 残ったペインをそろえ直して描き直す (外した節が畳まれて根に移ったときも)
        equalize(parent.flatMap { $0.window != nil ? $0 : nil } ?? root)
        redrawPanes()
        setupResponders()
        let after = panes
        if wasFocused, let f = after[min(i, after.count - 1)].session {
            hostWindow?.makeFirstResponder(f.termView)
            paneFocused(f)
        } else {
            refocus()
        }
    }

    /// ペインを描き直す (並べ替え・取り出し・ウインドウの移し替えのあと)
    func redrawPanes() {
        for p in panes {
            p.needsLayout = true
            p.needsDisplay = true
            p.header.needsDisplay = true
            p.container.needsLayout = true
            p.container.termView.needsDisplay = true
        }
        root.needsDisplay = true
    }

    /// 子が 1 つの節をなくす (その子を親の同じ場所に入れる)。根の子が節 1 つだけなら、その節の子を根に移す
    private func collapse(_ n: TabSplitNodeView) {
        if n === root {
            root.adjustSubviews()
            guard root.arrangedSubviews.count == 1, let only = root.arrangedSubviews.first as? TabSplitNodeView else { return }
            only.frame = root.bounds
            only.adjustSubviews()
            let kids = only.arrangedSubviews
            root.isVertical = only.isVertical
            only.removeFromSuperview()
            for k in kids {
                let f = k.frame
                k.removeFromSuperview()
                root.addArrangedSubview(k)
                k.frame = f
            }
            root.adjustSubviews()
            return
        }
        guard let parent = n.superview as? TabSplitNodeView else { return }
        let kids = n.arrangedSubviews
        if kids.count >= 2 { n.adjustSubviews(); return }
        let idx = parent.arrangedSubviews.firstIndex(where: { $0 === n }) ?? parent.arrangedSubviews.count
        let f = n.frame
        n.removeFromSuperview()
        if let only = kids.first {
            only.removeFromSuperview()
            parent.insertArrangedSubview(only, at: min(idx, parent.arrangedSubviews.count))
            only.frame = f
        }
        collapse(parent)
    }

    /// 分割をほかのセッションのウインドウに移す (ホストのセッションを閉じる・取り出すとき)。
    /// 新しいホストのウインドウは、前のホストと同じ位置・大きさで、同じタブの組に入れる
    private func rehost(to n: SessionWindowController) {
        guard let oldW = host.window, let newW = n.window else { return }
        let wasKey = oldW.isKeyWindow || oldW.isMainWindow
        // 先に前のウインドウから根を外して、空のビューを入れておく。
        // そうしないと前のウインドウは contentView として根を覚えたままになり、あとでその中身を入れ替える
        // (detach で端末を戻す) ときに、新しいウインドウに移した根が外されて、ウインドウが真っ黒になる
        oldW.contentView = NSView(frame: root.frame)
        newW.contentView = root
        newW.setFrame(oldW.frame, display: false)
        newW.contentResizeIncrements = NSSize(width: 1, height: 1)
        if oldW.isVisible || oldW.isMiniaturized {
            oldW.addTabbedWindow(newW, ordered: .above)
            newW.tabGroup?.selectedWindow = newW
        }
        host = n
        newW.alphaValue = 1
        setupResponders()
        redrawPanes()
        if wasKey { newW.makeKeyAndOrderFront(nil) }
        titlesChanged()
    }

    /// ペインの中身を、そのセッションのウインドウに戻す
    private func detach(_ p: TabPaneView) {
        let cont = p.container
        p.removeFromSuperview()
        cont.removeFromSuperview()
        cont.paneResponder = nil
        p.isFocused = false
        p.isMarked = false
        guard let c = p.session else { return }
        c.paneMarked = false
        c.paneNextResponder = nil
        c.tabSplit = nil
        if let cw = c.window {
            cw.alphaValue = 1
            cw.contentView = cont
            cw.contentResizeIncrements = NSSize(width: c.termView.cellW, height: c.termView.cellH)
        }
        c.updateTitle()
    }

    /// 分割をやめて、各ペインをそれぞれのウインドウに戻し、ホストのウインドウのタブに付け直す (木をたどった順)。
    /// フォーカスのあったペインのタブを選ぶ
    func unsplit(activate: Bool = true) {
        guard TabSplit.all.contains(where: { $0 === self }) else { return }
        TabSplit.all.removeAll { $0 === self }
        defer { PaneCountBadge.refreshAll() }
        resizeWork?.cancel()
        flushResizes()
        let list = panes
        let order = list.compactMap { $0.session }
        let sel = focused ?? host
        guard let hostW = host.window else { list.forEach { detach($0) }; return }
        let frame = hostW.frame
        let wasKey = hostW.isKeyWindow
        list.forEach { detach($0) }
        if let hi = order.firstIndex(where: { $0 === host }) {
            // ホストより後ろのタブは右へ、前のタブは左へ
            var prev = hostW
            for c in order[(hi + 1)...] {
                guard let cw = c.window else { continue }
                cw.setFrame(frame, display: false)
                prev.addTabbedWindow(cw, ordered: .above)
                prev = cw
            }
            var next = hostW
            for c in order[..<hi].reversed() {
                guard let cw = c.window else { continue }
                cw.setFrame(frame, display: false)
                next.addTabbedWindow(cw, ordered: .below)
                next = cw
            }
        }
        if let sw = sel.window {
            sw.tabGroup?.selectedWindow = sw
            if activate && wasKey { sw.makeKeyAndOrderFront(nil) }
            sw.makeFirstResponder(sel.termView)
        }
    }

    /// 分割しているウインドウの閉じるボタン: ペインを全部閉じる。接続中の TCP/IP があれば 1 回だけ「切断しますか？」
    func windowShouldCloseAll() -> Bool {
        let list = sessions
        let need = list.contains { !$0.skipCloseConfirm && $0.isConnected && $0.isTCPIP && $0.confirmDisconnectSetting }
        if need && !SessionWindowController.confirmDisconnect(hostWindow) { return false }
        let h = host
        for c in list where c !== h { c.closeWithoutConfirm() }
        // 残ったホストのセッション (分割はもうやめている) をこのまま閉じる
        h.skipCloseConfirm = true
        if h.tabSplit != nil { remove(h) }
        return true
    }
}

// MARK: - 分割に使うタブの印 (Shift+クリック・タブ > このタブを選ぶ)

/// タブに「分割に使う」印を付ける。印はタブの題の前の「✓ 」で見せる (ウインドウのタイトルには付けない)。
///
/// - タブのバーで、ほかのタブを Shift+クリックすると、そのタブの印を付け外しして、前に見ていたタブに戻る
///   (クリックしたタブは一瞬だけ出る。今のタブは分割にいつも入るので、印は「一緒に並べる相手」を選ぶもの)。
///   見分け方: キーウインドウが同じタブの組のほかのウインドウに変わったとき、今の出来事がマウスのクリックで Shift を押している。
/// - 今のタブ自身の Shift+クリックは、タブが変わらないので何もしない (メニューの「このタブを選ぶ」を使う)。
/// - 印は、分割に使ったら消す。タブがほかのウインドウに移ったら (タブの組が変わったら) 消す。
///   すべてのウインドウをまとめる・新しいウインドウに分けるときは全部消す。
enum TabMarks {
    /// タブの題の前に付ける印
    static let prefix = "✓ "
    private static var installed = false
    private static weak var lastKey: NSWindow?
    /// 前のタブに戻している間は、キーウインドウが変わってもクリックとみなさない
    private static var restoring = false

    /// キーウインドウが変わるのを見張る (起動時に 1 回)
    private static var observer: NSObjectProtocol?

    static func install() {
        guard !installed else { return }
        installed = true
        // queue: nil → 知らせた場で動かす (今の出来事 NSApp.currentEvent がまだクリックのうちに見る)
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { n in
            guard let w = n.object as? NSWindow else { return }
            let prev = lastKey
            lastKey = w
            guard !restoring, let p = prev, p !== w, isShiftClick() else { prune(); return }
            if !tabClicked(w, previous: p) { prune() }
        }
    }

    /// 見張りをやめて、印を全部消す (TTMado を切ったとき)
    static func uninstall() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        installed = false
        lastKey = nil
        clearAll()
    }

    /// 今の出来事が Shift を押したマウスのクリック
    private static func isShiftClick() -> Bool {
        guard let e = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(e.type) else { return false }
        return e.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.shift)
    }

    /// タブ w が Shift+クリックで選ばれた (前のキーウインドウ previous)。同じタブの組なら w の印を付け外しして previous に戻す。
    /// 印を付けられないタブ (分割しているウインドウ) なら false (ふつうに切り替える)
    @discardableResult
    static func tabClicked(_ w: NSWindow, previous p: NSWindow) -> Bool {
        guard let g = w.tabGroup, g.windows.contains(where: { $0 === p }),
              let c = w.windowController as? SessionWindowController, canMark(c) else { return false }
        toggle(c)
        // タブのバーのマウスの処理 (ドラッグの追跡) が終わってから戻す
        RunLoop.main.perform(inModes: [.default]) {
            restoring = true
            p.tabGroup?.selectedWindow = p
            p.makeKeyAndOrderFront(nil)
            lastKey = p
            DispatchQueue.main.async { restoring = false }
        }
        return true
    }

    /// 印を付けられるセッション: ふつうのタブ (分割のペイン・分割しているウインドウではない)
    static func canMark(_ c: SessionWindowController) -> Bool {
        c.tabSplit == nil && c.window?.contentView is TerminalContainerView
    }

    static func toggle(_ c: SessionWindowController) { set(c, !c.tabMarked) }

    static func set(_ c: SessionWindowController, _ on: Bool) {
        let v = on && canMark(c)
        guard c.tabMarked != v || (v && c.tabMarkGroup !== c.window?.tabGroup) else { return }
        c.tabMarked = v
        c.tabMarkGroup = v ? c.window?.tabGroup : nil
        c.updateTitle()
        c.tabCheck?.refresh()
    }

    /// ウインドウ w のタブの組で印のあるセッション (タブの順)
    static func marked(in w: NSWindow?) -> [SessionWindowController] {
        guard let w = w else { return [] }
        prune()
        return (w.tabGroup?.windows ?? [w]).compactMap { x in
            guard let c = x.windowController as? SessionWindowController, c.tabMarked else { return nil }
            return c
        }
    }

    static var any: Bool { prune(); return SessionWindowController.all.contains { $0.tabMarked } }

    static func clear(_ list: [SessionWindowController]) { list.forEach { set($0, false) } }
    static func clearAll() { clear(SessionWindowController.all.filter { $0.tabMarked }) }

    /// ペインになった・ほかのウインドウに移ったタブの印を消す
    static func prune() {
        for c in SessionWindowController.all where c.tabMarked {
            if !canMark(c) || c.tabMarkGroup == nil || c.window?.tabGroup !== c.tabMarkGroup { set(c, false) }
        }
    }
}

/// 分割の節 (向きを持つ NSSplitView。子はペインか節)
class TabSplitNodeView: NSSplitView {
    weak var split: TabSplit?
    /// 区切りの線: 黒い端末でも白い端末でも見えるように中間の灰色にする (既定の色は暗い背景だとほぼ見えない)
    override var dividerColor: NSColor { NSColor(white: 0.5, alpha: 1) }
    override var dividerThickness: CGFloat { 2 }
}

/// 分割しているウインドウの中身 (木の根)
final class TabSplitRootView: TabSplitNodeView {}

/// ペイン: TerminalContainerView (端末) と、フォーカスのある印 (淡いアクセント色の枠)
final class TabPaneView: NSView {
    weak var session: SessionWindowController?
    let container: TerminalContainerView
    private let ring = TabFocusRingView()
    /// 右下の ≡ ボタン (このペインのメニュー)
    let menuButton = PaneMenuButton(frame: NSRect(x: 0, y: 0, width: 22, height: 16))
    var isFocused = false { didSet { ring.isFocused = isFocused; header.isFocused = isFocused } }
    /// 「この画面を選ぶ」の印 (点線の枠と右上の ✓)
    var isMarked = false { didSet { ring.isMarked = isMarked } }

    /// 上の見出し (タブと同じく接続のタイトルを出す。つかんでドラッグすると ≡ と同じく移動できる)
    let header = TabPaneHeader()
    static let headerHeight: CGFloat = 22

    init(session: SessionWindowController, container: TerminalContainerView) {
        self.session = session
        self.container = container
        super.init(frame: container.frame)
        autoresizesSubviews = true
        let h = TabPaneView.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        header.autoresizingMask = [.width, .maxYMargin]
        header.pane = self
        addSubview(header)
        container.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        container.autoresizingMask = [.width, .height]
        addSubview(container)
        header.title = session.displayTitle
        ring.frame = bounds
        ring.autoresizingMask = [.width, .height]
        addSubview(ring, positioned: .above, relativeTo: container)
        // ≡: 見出しの右端に置き、見出しにマウスが乗っている間だけ見せる。
        // 押すとメニュー、ドラッグするとその向きの端まで伸ばす (ペインを動かすのは見出しのドラッグ)
        menuButton.frame.origin = NSPoint(x: header.bounds.maxX - menuButton.frame.width - 4, y: ((h - menuButton.frame.height) / 2).rounded())
        menuButton.autoresizingMask = [.minXMargin]
        menuButton.isHidden = true
        header.addSubview(menuButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

/// フォーカスのあるペインの枠 (クリックは下の端末へ通す)
/// 枠: フォーカスのあるペインはアクセント色の 2px、ほかのペインは灰色の 1px (どのペインにも区切りが見えるように)
private final class TabFocusRingView: NSView {
    var isFocused = false { didSet { needsDisplay = true } }
    var isMarked = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if isMarked {
            // 選んだペイン: 内側にアクセント色の点線と、右上に小さな ✓
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let d = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            d.lineWidth = 1
            d.setLineDash([4, 3], count: 2, phase: 0)
            d.stroke()
            let badge = NSRect(x: bounds.maxX - 22, y: 7, width: 15, height: 15)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let s = "✓" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: badge.midX - sz.width / 2, y: badge.midY - sz.height / 2), withAttributes: attrs)
        }
        if isFocused {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        } else {
            NSColor(white: 0.5, alpha: 0.9).setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
    }
}


/// タブの右に付けるチェックボックス (NSWindowTab.accessoryView)。
/// タブにマウスを乗せたときと、選んであるときだけ見える。押すとそのタブを分割に使うタブとして選ぶ / 外す (TabMarks)
final class TabCheckAccessory: NSView {
    private weak var session: SessionWindowController?
    private let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var hovered = false { didSet { updateVisibility() } }
    private var area: NSTrackingArea?
    private weak var areaHost: NSView?

    init(session: SessionWindowController) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 16))
        box.controlSize = .small
        box.target = self
        box.action = #selector(clicked)
        box.toolTip = Lang.m("MENU_TABS_CHECK_TIP", "分割に使うタブとして選ぶ")
        box.frame = bounds
        box.autoresizingMask = [.width, .height]
        addSubview(box)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        guard let c = session else { return }
        TabMarks.set(c, box.state == .on)
        refresh()
    }

    /// 印の状態と、選べるかどうか (分割中のタブなどは選べない) を映す
    func refresh() {
        guard let c = session else { return }
        box.state = c.tabMarked ? .on : .off
        box.isEnabled = TabMarks.canMark(c)
        updateVisibility()
    }

    private func updateVisibility() {
        let show = (session?.tabMarked ?? false) || (hovered && box.isEnabled)
        alphaValue = show ? 1 : 0
    }

    // タブ全体 (このビューを載せているタブのボタン) にマウスが乗ったかを見る
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installTracking()
    }
    private func installTracking() {
        if let a = area { areaHost?.removeTrackingArea(a); area = nil }
        guard let host = superview?.superview ?? superview else { return }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        host.addTrackingArea(a)
        area = a
        areaHost = host
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

/// ペインの ≡ メニューの動作 (メニューを開いている間だけ持つ)
final class PaneMenuHandler: NSObject {
    static var current: PaneMenuHandler?
    weak var split: TabSplit?
    weak var session: SessionWindowController?
    init(split: TabSplit, session: SessionWindowController) { self.split = split; self.session = session }

    @objc func toggleMark(_ sender: Any?) {
        guard let c = session else { return }
        split?.togglePaneMark(c)
    }
    @objc func extend(_ sender: NSMenuItem) {
        guard let c = session else { return }
        let dirs: [TabSplit.ExtendDirection] = [.up, .down, .left, .right]
        guard dirs.indices.contains(sender.tag) else { return }
        split?.extendPane(c, dir: dirs[sender.tag])
    }
    @objc func splitSideBySide(_ sender: Any?) { splitHere(true) }
    @objc func splitStacked(_ sender: Any?) { splitHere(false) }
    private func splitHere(_ sideBySide: Bool) {
        guard let sp = split, let c = session, let w = sp.hostWindow else { return }
        sp.focus(c)
        TabSplit.splitFocused(of: w, sideBySide: sideBySide)
    }
    @objc func returnToTab(_ sender: Any?) {
        guard let c = session else { return }
        TabSplit.returnPaneToTab(c)
    }
    @objc func moveToNewWindow(_ sender: Any?) {
        guard let c = session else { return }
        TabSplit.moveToNewWindow(c)
    }
    @objc func close(_ sender: Any?) { session?.performCloseSession() }
}

/// ペインの右下の小さな ≡ ボタン。ふだんは淡く、マウスを乗せると濃くする。
/// キー入力のフォーカスは取らない (押すとそのペインにフォーカスを移してメニューを出す)
final class PaneMenuButton: NSView {
    var onPress: ((PaneMenuButton) -> Void)?
    /// ドラッグ中 (ウインドウの座標)
    var onDragMove: ((NSPoint) -> Void)?
    /// ドラッグを終えた (ウインドウの座標。Esc で取り消したら nil)
    var onDragEnd: ((NSPoint?) -> Void)?
    /// ≡ 自身のドラッグ (押した位置, 今の位置。ウインドウの座標): ペインを端まで伸ばす
    var onExtendMove: ((NSPoint, NSPoint) -> Void)?
    /// ≡ 自身のドラッグを終えた (押した位置, 離した位置。Esc で取り消したら nil)
    var onExtendEnd: ((NSPoint, NSPoint?) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = Lang.m("MENU_PANE_MENU_TIP", "この画面のメニュー")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    // ≡ に乗ったら「つかめる」手のカーソル (押せばメニュー、ドラッグで移動。ドラッグ中は握った手)
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    /// 押して動かさずに離したらメニュー。動かしたら、そのペインをその向きの端まで伸ばす (ExtendDirection)。
    /// ドラッグ中は Esc で取り消す
    override func mouseDown(with event: NSEvent) {
        hovered = true
        defer { hovered = false }
        let start = event.locationInWindow
        trackDrag(event, click: { [weak self] in if let self = self { self.onPress?(self) } },
                  move: { [weak self] p in self?.onExtendMove?(start, p) },
                  end: { [weak self] p in self?.onExtendEnd?(start, p) })
    }

    /// 押した位置から追う: 動かさずに離したら click、4pt より動かしたらペインのドラッグ (見出しから使う)
    func track(_ event: NSEvent, click: () -> Void) {
        trackDrag(event, click: click, move: { [weak self] p in self?.onDragMove?(p) }, end: { [weak self] p in self?.onDragEnd?(p) })
    }

    /// 押した位置から追う: 動かさずに離したら click、4pt より動かしたら move / end。ドラッグ中は Esc で取り消す (end に nil)
    private func trackDrag(_ event: NSEvent, click: () -> Void, move: (NSPoint) -> Void, end: (NSPoint?) -> Void) {
        guard let w = window else { click(); return }
        let start = event.locationInWindow
        var dragging = false, cancelled = false
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            switch e.type {
            case .leftMouseDragged:
                guard !cancelled else { continue }
                let p = e.locationInWindow
                if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true }
                if dragging {
                    NSCursor.closedHand.set()
                    move(p)
                }
            case .leftMouseUp:
                if dragging {
                    NSCursor.arrow.set()
                    if !cancelled { end(e.locationInWindow) }
                } else if !cancelled {
                    click()
                }
                return
            case .keyDown:
                if e.keyCode == 53, dragging, !cancelled {
                    cancelled = true
                    NSCursor.arrow.set()
                    end(nil)
                }
            default:
                break
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        // 黒い端末でも白い端末でも見えるように、中間の灰色の地に白い ≡
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor(white: 0.45, alpha: hovered ? 0.85 : 0.3).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let s = "≡" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 1 : 0.65)]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }
}

// MARK: - ペインをウインドウの外へドラッグしているときの写し

/// ペインの画面を写した半透明のウインドウ。マウスに付いて動く (タブを引き出したときの macOS の見せ方に合わせる)
final class PaneDragGhost {
    static let shared = PaneDragGhost()
    private var win: NSWindow?
    private var imageView = NSImageView()
    private weak var source: TabPaneView?
    private var size = NSSize.zero

    func show(_ p: TabPaneView, at mouse: NSPoint) {
        if source !== p || win == nil {
            // ドラッグを始めて最初に外へ出たときに 1 回だけ写す
            guard let rep = p.bitmapImageRepForCachingDisplay(in: p.bounds) else { return }
            p.cacheDisplay(in: p.bounds, to: rep)
            let img = NSImage(size: p.bounds.size); img.addRepresentation(rep)
            // 大きすぎる画面は縮めて見せる
            let scale = min(1, 520 / max(1, p.bounds.width), 360 / max(1, p.bounds.height))
            size = NSSize(width: p.bounds.width * scale, height: p.bounds.height * scale)
            let w = win ?? {
                let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = true
                w.ignoresMouseEvents = true
                w.level = .floating
                w.isReleasedWhenClosed = false
                w.animationBehavior = .none
                imageView.imageScaling = .scaleAxesIndependently
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 6
                imageView.layer?.masksToBounds = true
                w.contentView = imageView
                return w
            }()
            imageView.image = img
            w.alphaValue = 0.6
            win = w
            source = p
        }
        // マウスが写しの上の辺の少し内側 (タブをつかんでいる位置) に来るように置く
        let origin = NSPoint(x: mouse.x - min(60, size.width / 2), y: mouse.y - size.height + 12)
        win?.setFrame(NSRect(origin: origin, size: size), display: true)
        win?.orderFront(nil)
    }

    var windowNumber: Int { win?.windowNumber ?? 0 }

    func hide(forget: Bool = false) {
        win?.orderOut(nil)
        if forget { source = nil; imageView.image = nil }
    }
}

// MARK: - 分割の行き先 (ペインのドラッグ・タブを引き出して落とす のどちらも使う)

/// 落とす場所の見分け方: 左右の 25% は左 / 右、それ以外は上半分が上、下半分が下
enum SplitDropZone {
    enum Side {
        case left, right, above, below
        /// 左右に並べる
        var isSideBySide: Bool { self == .left || self == .right }
        /// 相手の後ろ (右・下) に置く
        var isAfter: Bool { self == .right || self == .below }
    }

    /// 範囲 b の中の点 q の場所 (flipped: 上から下の座標)。範囲が空なら nil
    static func side(in b: NSRect, at q: NSPoint, flipped: Bool) -> Side? {
        guard b.width > 0, b.height > 0 else { return nil }
        let x = q.x - b.minX, y = q.y - b.minY
        if x < b.width * 0.25 { return .left }
        if x > b.width * 0.75 { return .right }
        let upper = flipped ? y < b.height / 2 : y > b.height / 2
        return upper ? .above : .below
    }

    /// 範囲 b の、side の側の半分
    static func half(of b: NSRect, side: Side, flipped: Bool) -> NSRect {
        let w = b.width / 2, h = b.height / 2
        switch side {
        case .left: return NSRect(x: b.minX, y: b.minY, width: w, height: b.height)
        case .right: return NSRect(x: b.minX + w, y: b.minY, width: w, height: b.height)
        case .above: return NSRect(x: b.minX, y: flipped ? b.minY : b.minY + h, width: b.width, height: h)
        case .below: return NSRect(x: b.minX, y: flipped ? b.minY + h : b.minY, width: b.width, height: h)
        }
    }
}

/// 行き先の見本: アクセント色の半透明 (25%) の角丸と 2px の枠。ウインドウの上に重ねる (クリックは通す)
final class SplitDropPreview: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = SplitDropPreviewView()
    }

    /// 画面の座標 r に出す。ow の上 (w があれば w の上)
    func show(_ r: NSRect, over ow: NSWindow, above w: NSWindow?, label: String? = nil) {
        if let v = contentView as? SplitDropPreviewView, v.label != label {
            v.label = label
            v.needsDisplay = true
        }
        let rr = r.insetBy(dx: 2, dy: 2)
        if frame != rr { setFrame(rr, display: true) }
        level = max(ow.level, w?.level ?? ow.level)
        if !isVisible || w != nil { order(.above, relativeTo: (w ?? ow).windowNumber) }
        watch.start { [weak self] in self?.hide() }
    }
    func hide() {
        watch.stop()
        if isVisible { orderOut(nil) }
    }
    private let watch = OverlayWatch()
}

/// 見本・案内の重ねウインドウの見張り: マウスのボタンを離したまま少したったら隠す。
/// どのドラッグの終わり方 (AppKit のタブのドラッグ・ウインドウの移動・取り消し・待ちの打ち切り) でも、見本が残らないようにする
final class OverlayWatch {
    private var timer: Timer?
    private var upTicks = 0
    func start(_ hide: @escaping () -> Void) {
        upTicks = 0
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.upTicks = NSEvent.pressedMouseButtons & 1 == 0 ? self.upTicks + 1 : 0
            if self.upTicks >= 2 { hide() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

private final class SplitDropPreviewView: NSView {
    /// 真ん中に出す短い説明 (なければ出さない)
    var label: String?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        p.fill()
        NSColor.controlAccentColor.setStroke()
        p.lineWidth = 2
        p.stroke()
        guard let t = label as NSString? else { return }
        // 黒い端末の上でも白い端末の上でも読めるように、アクセント色の丸い地に白い字
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white]
        let sz = t.size(withAttributes: attrs)
        let pill = NSRect(x: bounds.midX - sz.width / 2 - 10, y: bounds.midY - sz.height / 2 - 4, width: sz.width + 20, height: sz.height + 8)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        t.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2), withAttributes: attrs)
    }
}


/// ペインの上の見出し。分割してもタブの情報 (接続のタイトル) が見えるように、タブと同じ見た目で出す。
/// クリックでそのペインにフォーカス、つかんでドラッグすると ≡ と同じくペインを動かせる
final class TabPaneHeader: NSView {
    weak var pane: TabPaneView?
    var title = "" { didSet { needsDisplay = true; toolTip = title } }
    var isFocused = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ふつうのタブと同じく、マウスが乗ったら左に出す × (この画面を閉じる)
    var hovered = false { didSet { needsDisplay = true } }   // 自己テスト (かんたんマニュアルの写真) からも付ける
    private var closeRect: NSRect { NSRect(x: 6, y: (bounds.height - 14) / 2, width: 14, height: 14) }

    override func mouseDown(with event: NSEvent) {
        guard let p = pane else { return }
        if hovered, closeRect.insetBy(dx: -2, dy: -2).contains(convert(event.locationInWindow, from: nil)) {
            p.session?.performCloseSession()
            return
        }
        p.menuButton.track(event) { [weak p] in
            guard let p = p, let w = p.window else { return }
            w.makeFirstResponder(p.container.termView)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    // マウスが乗っている間だけ × を見せる
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// 右クリック (control+クリック) でこの画面のメニュー
    override func rightMouseDown(with event: NSEvent) {
        guard let p = pane, let sp = p.session?.tabSplit else { return }
        p.window?.makeFirstResponder(p.container.termView)
        sp.showPaneMenu(p, event: event, in: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        // タブのバーに近い色。フォーカスのある見出しは少し明るく、文字も濃く
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg: NSColor = dark ? NSColor(white: isFocused ? 0.30 : 0.20, alpha: 1) : NSColor(white: isFocused ? 0.93 : 0.82, alpha: 1)
        bg.setFill()
        bounds.fill()
        NSColor(white: 0.5, alpha: 0.6).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: isFocused ? .semibold : .regular),
            .foregroundColor: isFocused ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: p,
        ]
        // 左の × と重ならないように、左右を同じだけ空ける (題は真ん中のまま)
        let r = bounds.insetBy(dx: 26, dy: 0)
        let h = (title as NSString).size(withAttributes: attrs).height
        (title as NSString).draw(in: NSRect(x: r.minX, y: (bounds.height - h) / 2, width: r.width, height: h), withAttributes: attrs)
        if hovered {
            let c = closeRect
            NSColor(white: 0.5, alpha: 0.25).setFill()
            NSBezierPath(roundedRect: c, xRadius: 3, yRadius: 3).fill()
            let x = NSBezierPath()
            let k = c.insetBy(dx: 4, dy: 4)
            x.move(to: NSPoint(x: k.minX, y: k.minY)); x.line(to: NSPoint(x: k.maxX, y: k.maxY))
            x.move(to: NSPoint(x: k.maxX, y: k.minY)); x.line(to: NSPoint(x: k.minX, y: k.maxY))
            x.lineWidth = 1.3
            NSColor.secondaryLabelColor.setStroke()
            x.stroke()
        }
    }
}


/// 分割しているウインドウに、中の画面 (ペイン) の数を丸いバッジで出す。
/// タブのバーがあるときはタブの右 (NSWindowTab.accessoryView)、タブが 1 つだけ (タブのバーがない) のときはタイトルバーの右
final class PaneCountBadge: NSView {
    var count = 0 { didSet { needsDisplay = true; invalidateIntrinsicContentSize(); toolTip = Lang.m("PANE_COUNT_TIP", "このウィンドウの中の画面の数: %d", count) } }
    override var intrinsicContentSize: NSSize {
        let w = max(18, ("\(count)" as NSString).size(withAttributes: [.font: PaneCountBadge.font]).width + 10)
        return NSSize(width: w, height: 16)
    }
    static let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
    override func draw(_ dirtyRect: NSRect) {
        let size = intrinsicContentSize
        let r = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        let s = "\(count)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: PaneCountBadge.font, .foregroundColor: NSColor.white]
        let t = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: r.midX - t.width / 2, y: r.midY - t.height / 2), withAttributes: attrs)
    }

    /// タイトルバーの右に出すときの入れ物 (ウインドウごとに 1 つ)
    private static var titlebar: [ObjectIdentifier: NSTitlebarAccessoryViewController] = [:]
    /// 入れ物を付けたウインドウ (閉じたウインドウと同じ番地の新しいウインドウを見分ける)
    private static var titlebarOwner: [ObjectIdentifier: WeakWindow] = [:]

    /// すべてのセッションのウインドウのバッジを今の分割に合わせる (次のランループでまとめて)
    private static var pending = false
    static func refreshAll() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async {
            pending = false
            for c in SessionWindowController.all { if let w = c.window { refresh(w) } }
        }
    }

    static func refresh(_ w: NSWindow) {
        let n = (TTMado.isEnabled ? TabSplit.split(of: w)?.panes.count : nil) ?? 0
        let tabbed = (w.tabGroup?.windows.count ?? 1) > 1
        // タブのバーがあるとき: タブの右
        if n >= 2 && tabbed {
            let b = (w.tab.accessoryView as? PaneCountBadge) ?? PaneCountBadge()
            b.count = n
            if w.tab.accessoryView !== b { w.tab.accessoryView = b }
        } else if w.tab.accessoryView is PaneCountBadge {
            w.tab.accessoryView = nil
        }
        // タブのバーがないとき: タイトルバーの右
        let key = ObjectIdentifier(w)
        // 閉じたウインドウと同じ番地の新しいウインドウだと、前の入れ物が残っている (このウインドウには付いていない) ので作り直す
        if titlebar[key] != nil, titlebarOwner[key]?.w !== w { titlebar[key] = nil }
        if n >= 2 && !tabbed {
            let vc = titlebar[key] ?? {
                let vc = NSTitlebarAccessoryViewController()
                vc.layoutAttribute = .trailing
                let holder = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
                let b = PaneCountBadge(frame: NSRect(x: 4, y: 6, width: 26, height: 16))
                b.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
                holder.addSubview(b)
                vc.view = holder
                w.addTitlebarAccessoryViewController(vc)
                titlebar[key] = vc
                titlebarOwner[key] = WeakWindow(w: w)
                return vc
            }()
            (vc.view.subviews.first as? PaneCountBadge)?.count = n
            vc.isHidden = false
        } else if let vc = titlebar[key] {
            // 隠すだけだと、タブの組に入ったウインドウでは出たままになることがあるので、外す
            if titlebarOwner[key]?.w === w, let i = w.titlebarAccessoryViewControllers.firstIndex(where: { $0 === vc }) {
                w.removeTitlebarAccessoryViewController(at: i)
            }
            vc.isHidden = true
            titlebar[key] = nil
            titlebarOwner[key] = nil
        }
    }
}
