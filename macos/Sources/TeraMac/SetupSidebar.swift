import AppKit
import TeraCore

/// その他の設定: Mac のシステム設定風に、左に見出し付きの一覧・右に中身
final class SetupSidebarView: NSView {
    struct Item { let title: String; let symbol: String; let color: NSColor }
    struct Section { let title: String; let items: [Int] }

    let items: [Item]
    let sections: [Section]
    var selectedIndex = 0 {
        didSet {
            guard oldValue != selectedIndex else { return }
            list.needsDisplay = true
            header.stringValue = items[selectedIndex].title
        }
    }
    var onSelect: ((Int) -> Void)?
    /// 「デフォルトに戻す」(右上。今のページが既定と違うときだけ出す)
    var onReset: (() -> Void)?
    var resetVisible = false { didSet { resetButton.isHidden = !resetVisible } }
    private lazy var resetButton: NSButton = {
        let b = NSButton(title: Lang.m("SETUP_PAGE_RESET", "デフォルトに戻す"), target: self, action: #selector(resetTapped))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.isHidden = true
        return b
    }()
    @objc private func resetTapped() { onReset?() }

    static let sidebarWidth: CGFloat = 196
    private let list: SidebarList
    private let header = NSTextField(labelWithString: "")

    init(items: [Item], sections: [Section], content: NSView) {
        self.items = items
        self.sections = sections
        list = SidebarList()
        super.init(frame: .zero)
        list.owner = self

        let fx = NSVisualEffectView()
        fx.material = .sidebar
        fx.blendingMode = .behindWindow
        fx.state = .followsWindowActiveState
        let sep = NSBox(); sep.boxType = .separator
        header.font = .systemFont(ofSize: 20, weight: .bold)
        header.stringValue = items.first?.title ?? ""
        for v in [fx, list, sep, header, content, resetButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let w = Self.sidebarWidth
        NSLayoutConstraint.activate([
            fx.leadingAnchor.constraint(equalTo: leadingAnchor),
            fx.topAnchor.constraint(equalTo: topAnchor),
            fx.bottomAnchor.constraint(equalTo: bottomAnchor),
            fx.widthAnchor.constraint(equalToConstant: w),
            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.topAnchor.constraint(equalTo: topAnchor),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.widthAnchor.constraint(equalToConstant: w),
            list.heightAnchor.constraint(greaterThanOrEqualToConstant: list.contentHeight),
            sep.leadingAnchor.constraint(equalTo: fx.trailingAnchor),
            sep.topAnchor.constraint(equalTo: topAnchor),
            sep.bottomAnchor.constraint(equalTo: bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),
            header.leadingAnchor.constraint(equalTo: sep.trailingAnchor, constant: 20),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            resetButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: sep.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    fileprivate func pick(_ i: Int) {
        guard i != selectedIndex, items.indices.contains(i) else { return }
        selectedIndex = i
        onSelect?(i)
    }

    /// 一覧の順 (見出しの順) で上下に動く
    fileprivate var order: [Int] { sections.flatMap(\.items) }
}

/// 左の一覧 (見出し + アイコン付きの行)
private final class SidebarList: NSView {
    weak var owner: SetupSidebarView?
    private let rowH: CGFloat = 28
    private let headH: CGFloat = 26
    private let top: CGFloat = 12
    private var iconCache: [Int: NSImage] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var contentHeight: CGFloat {
        guard let o = owner else { return 0 }
        return top + CGFloat(o.sections.count) * headH + CGFloat(o.sections.reduce(0) { $0 + $1.items.count }) * rowH + 12
    }

    /// (見出しの位置, 行の位置)
    private func geometry() -> (heads: [(String, CGFloat)], rows: [Int: NSRect]) {
        guard let o = owner else { return ([], [:]) }
        var y = top
        var heads: [(String, CGFloat)] = []
        var rows: [Int: NSRect] = [:]
        for s in o.sections {
            heads.append((s.title, y))
            y += headH
            for i in s.items {
                rows[i] = NSRect(x: 10, y: y, width: bounds.width - 20, height: rowH)
                y += rowH
            }
        }
        return (heads, rows)
    }

    private func icon(_ i: Int) -> NSImage? {
        if let c = iconCache[i] { return c }
        guard let o = owner else { return nil }
        let it = o.items[i]
        let side: CGFloat = 20
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        guard let sym = NSImage(systemSymbolName: it.symbol, accessibilityDescription: it.title)?.withSymbolConfiguration(cfg) else { return nil }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            it.color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            // 白抜きのシンボル
            let s = sym.size
            let sr = NSRect(x: (side - s.width) / 2, y: (side - s.height) / 2, width: s.width, height: s.height)
            let white = NSImage(size: s, flipped: false) { rr in
                sym.draw(in: rr)
                NSColor.white.set()
                rr.fill(using: .sourceAtop)
                return true
            }
            white.draw(in: sr)
            return true
        }
        iconCache[i] = img
        return img
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner else { return }
        let g = geometry()
        let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
        for (t, y) in g.heads {
            (t as NSString).draw(at: NSPoint(x: 20, y: y + 8), withAttributes: headAttrs)
        }
        let active = window?.isKeyWindow ?? true
        for (i, r) in g.rows {
            let sel = i == o.selectedIndex
            if sel {
                (active ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            if let ic = icon(i) {
                ic.draw(in: NSRect(x: r.minX + 6, y: r.midY - 10, width: 20, height: 20))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13),
                                                        .foregroundColor: sel && active ? NSColor.white : NSColor.labelColor]
            let t = o.items[i].title as NSString
            let ts = t.size(withAttributes: attrs)
            t.draw(at: NSPoint(x: r.minX + 34, y: r.midY - ts.height / 2), withAttributes: attrs)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let w = window else { return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: n, object: w)
        }
    }
    @objc private func keyChanged() { needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { iconCache = [:]; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        for (i, r) in geometry().rows where r.contains(pt) {
            window?.makeFirstResponder(self)
            owner?.pick(i)
            return
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let o = owner, let k = event.specialKey, k == .upArrow || k == .downArrow else {
            return super.keyDown(with: event)
        }
        let ord = o.order
        guard let p = ord.firstIndex(of: o.selectedIndex) else { return }
        let n = k == .upArrow ? p - 1 : p + 1
        if ord.indices.contains(n) { o.pick(ord[n]) }
    }
}
