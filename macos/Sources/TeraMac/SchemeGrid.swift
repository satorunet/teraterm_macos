import AppKit

/// 設定 > テーマ: 配色とテーマを 1 つの一覧にしたパネル (見本のタイルを並べる)
final class SchemeGrid: NSView {
    struct Entry {
        let key: String
        let title: String
        let image: NSImage?
        /// 見出し (この項目の前に入れる)
        var header: String? = nil
    }

    var onPick: ((String) -> Void)?
    var selectedKey = "" { didSet { if oldValue != selectedKey { updateSelection() } } }

    static let tileSize = NSSize(width: 112, height: 58)
    private let columns = 5
    private var tiles: [(key: String, button: NSButton, label: NSTextField)] = []
    private let scroll = NSScrollView()
    private let doc = FlippedView()

    init(height: CGFloat) {
        super.init(frame: .zero)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let w = CGFloat(columns) * Self.tileSize.width + CGFloat(columns - 1) * 12 + 18
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: w), scroll.heightAnchor.constraint(equalToConstant: height),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    /// 見出しごとのまとまり (開閉できる)
    private var sections: [(header: NSButton?, title: String, tiles: [Int])] = []
    private var expanded: Set<Int> = [0, 1]   // 見出しなしの先頭と、最初のまとまり (配色)
    private var docHeight: NSLayoutConstraint?

    func setEntries(_ entries: [Entry]) {
        doc.subviews.forEach { $0.removeFromSuperview() }
        tiles = []
        sections = []
        for e in entries {
            if let h = e.header ?? (sections.isEmpty ? "" : nil) {
                var hb: NSButton? = nil
                if !h.isEmpty {
                    let b = NSButton(title: h, target: self, action: #selector(toggleSection(_:)))
                    b.isBordered = false
                    b.alignment = .left
                    b.tag = sections.count
                    doc.addSubview(b)
                    hb = b
                }
                sections.append((hb, h, []))
            }
            let b = NSButton(title: "", target: self, action: #selector(tapped(_:)))
            b.isBordered = false
            b.image = e.image
            b.imageScaling = .scaleAxesIndependently
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.layer?.masksToBounds = true
            b.tag = tiles.count
            b.toolTip = e.title
            if e.image == nil {
                b.title = e.title
                b.font = .systemFont(ofSize: 12)
            }
            let l = NSTextField(labelWithString: e.image == nil ? "" : e.title)
            l.font = .systemFont(ofSize: 11)
            l.lineBreakMode = .byTruncatingTail
            doc.addSubview(b); doc.addSubview(l)
            sections[sections.count - 1].tiles.append(tiles.count)
            tiles.append((e.key, b, l))
        }
        relayout()
        updateSelection()
    }

    /// 選んでいるタイルのまとまりは開いておく
    func expandSelection() {
        if let i = sections.firstIndex(where: { $0.tiles.contains { tiles[$0].key == selectedKey } }), !expanded.contains(i) {
            expanded.insert(i)
            relayout()
        }
    }

    /// 自己テスト用: 全部開く
    func expandAll() { expanded = Set(sections.indices); relayout() }

    @objc private func toggleSection(_ b: NSButton) {
        if expanded.contains(b.tag) { expanded.remove(b.tag) } else { expanded.insert(b.tag) }
        relayout()
        if expanded.contains(b.tag) { doc.scrollToVisible(b.frame.insetBy(dx: 0, dy: -4).union(b.frame.offsetBy(dx: 0, dy: 120))) }
    }

    private func relayout() {
        let ts = Self.tileSize
        let width = CGFloat(columns) * ts.width + CGFloat(columns - 1) * 12
        var y: CGFloat = 0
        for (si, sec) in sections.enumerated() {
            let open = sec.header == nil || expanded.contains(si)
            if let h = sec.header {
                if si > 0 { y += 6 }
                let chev = open ? "▾" : "▸"
                h.attributedTitle = NSAttributedString(string: "\(chev)  \(sec.title)  (\(sec.tiles.count))", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
                h.frame = NSRect(x: 0, y: y, width: width, height: 22)
                y += 26
            }
            var col = 0
            let rowGap: CGFloat = sec.header == nil ? 12 : 26   // 名前の行がない先頭の段は詰める
            for ti in sec.tiles {
                let t = tiles[ti]
                t.button.isHidden = !open; t.label.isHidden = !open
                guard open else { continue }
                let x = CGFloat(col) * (ts.width + 12)
                t.button.frame = NSRect(x: x, y: y, width: ts.width, height: ts.height)
                t.label.frame = NSRect(x: x, y: y + ts.height + 2, width: ts.width, height: 16)
                col += 1
                if col == columns { col = 0; y += ts.height + rowGap }
            }
            if open && col != 0 { y += ts.height + rowGap }
        }
        docHeight?.isActive = false
        docHeight = doc.heightAnchor.constraint(equalToConstant: max(y, 1))
        docHeight?.isActive = true
    }

    private func updateSelection() {
        for t in tiles {
            let sel = t.key == selectedKey
            t.button.layer?.borderWidth = sel ? 3 : 1
            t.button.layer?.borderColor = sel ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
            t.label.font = .systemFont(ofSize: 11, weight: sel ? .semibold : .regular)
        }
    }

    /// 選んでいるタイルが見えるところまで動かす
    func scrollToSelection() {
        guard let t = tiles.first(where: { $0.key == selectedKey }), !t.button.isHidden else { return }
        layoutSubtreeIfNeeded()
        doc.scrollToVisible(t.button.frame.insetBy(dx: 0, dy: -24))
    }

    @objc private func tapped(_ b: NSButton) {
        guard tiles.indices.contains(b.tag) else { return }
        selectedKey = tiles[b.tag].key
        onPick?(selectedKey)
    }

    /// 配色の見本 (背景に Aa と ANSI の色の点)
    static func tileImage(fg: NSColor, bg: NSColor, ansi: [NSColor], background: BGImageSpec? = nil) -> NSImage {
        let size = tileSize
        // テーマの背景画像 (壁紙・画像・グラデーションなど) も小さく描いて雰囲気が分かるように
        let bgImg = background.flatMap { $0.image(size: size, scale: 2, windowFrame: nil, screen: NSScreen.main) }
        return NSImage(size: size, flipped: false) { r in
            bg.setFill(); r.fill()
            bgImg?.draw(in: r)
            ("Aa" as NSString).draw(at: NSPoint(x: 10, y: size.height - 30), withAttributes: [
                .font: NSFont(name: "Menlo-Bold", size: 16) ?? NSFont.boldSystemFont(ofSize: 16), .foregroundColor: fg])
            ("$ ls" as NSString).draw(at: NSPoint(x: 44, y: size.height - 27), withAttributes: [
                .font: NSFont(name: "Menlo", size: 11) ?? NSFont.systemFont(ofSize: 11), .foregroundColor: fg])
            for i in 0..<7 where i + 1 < ansi.count || i < ansi.count {
                let c = ansi[min(ansi.count - 1, i < 7 ? i + 1 : 9)]
                c.setFill()
                NSBezierPath(roundedRect: NSRect(x: 10 + CGFloat(i) * 14, y: 10, width: 11, height: 11), xRadius: 2.5, yRadius: 2.5).fill()
            }
            return true
        }
    }
}
