import AppKit

/// Windows のタブ (Win32 の複数行タブ, TCS_MULTILINE) と同じ見た目の入れ物。
/// タブを rows 行に並べ、選んだタブの行をいつも一番下 (中身のすぐ上) に回す。
/// 選んだタブは少し大きく、中身の枠とつながって見える。中身は content (noTabsNoBorder の NSTabView など) を入れる
final class MultiRowTabView: NSView {
    var titles: [String] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var rows: Int
    var selectedIndex = 0 { didSet { if oldValue != selectedIndex { needsDisplay = true } } }
    /// タブを押したとき
    var onSelect: ((Int) -> Void)?

    let rowHeight: CGFloat = 22
    private let font = NSFont.systemFont(ofSize: 12)
    private let content: NSView

    /// タブの部分の高さ (選んだタブが 2pt はみ出す分を含む)
    var barHeight: CGFloat { CGFloat(rows) * rowHeight + 2 }

    /// 行ごとのタブ数を決めるとき (nil なら均等に詰める)
    var rowSizes: [Int]?

    init(titles: [String], rows: Int = 2, rowSizes: [Int]? = nil, content: NSView) {
        self.titles = titles
        self.rowSizes = rowSizes
        self.rows = rowSizes?.count ?? rows
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: barHeight + 1),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// 行ごとのタブの番号 (前から順に詰める)
    private var rowItems: [[Int]] {
        if let sizes = rowSizes, sizes.reduce(0, +) == titles.count {
            var start = 0
            var out: [[Int]] = []
            for n in sizes { out.append(Array(start..<start + n)); start += n }
            return out
        }
        let per = Int(ceil(Double(titles.count) / Double(max(1, rows))))
        return stride(from: 0, to: titles.count, by: max(1, per)).map { Array($0..<min($0 + per, titles.count)) }
    }

    private func textWidth(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width + 16 }

    /// 一番左の行に必要な幅 (これより狭いと文字が切れる)
    var minimumWidth: CGFloat { rowItems.map { $0.reduce(0) { $0 + textWidth(titles[$1]) } }.max() ?? 0 }

    /// 各タブの四角 (選んだタブの行を一番下にする。行の幅いっぱいに広げる = Win32 の既定)
    func tabRects() -> [Int: NSRect] {
        var items = rowItems
        if let sel = items.firstIndex(where: { $0.contains(selectedIndex) }) {
            // Win32 と同じく、選んだ行を手前 (下) に回し、ほかの行は順に上へずらす
            let n = items.count
            items = (0..<n).map { items[(sel + 1 + $0) % n] }
        }
        var out: [Int: NSRect] = [:]
        let w = bounds.width
        for (r, row) in items.enumerated() {
            let y = 2 + CGFloat(r) * rowHeight
            let natural = row.reduce(0) { $0 + textWidth(titles[$1]) }
            let k = natural > 0 ? w / natural : 1
            var x: CGFloat = 0
            for (j, i) in row.enumerated() {
                let tw = j == row.count - 1 ? w - x : floor(textWidth(titles[i]) * k)
                out[i] = NSRect(x: x, y: y, width: tw, height: rowHeight)
                x += tw
            }
        }
        return out
    }

    private var paneColor: NSColor { .controlBackgroundColor }
    private var tabColor: NSColor { NSColor.windowBackgroundColor.blended(withFraction: 0.04, of: .black) ?? .windowBackgroundColor }
    private var lineColor: NSColor { NSColor.tertiaryLabelColor }

    override func draw(_ dirtyRect: NSRect) {
        let rects = tabRects()
        // 中身の枠
        let pane = NSRect(x: 0.5, y: barHeight + 0.5, width: bounds.width - 1, height: bounds.height - barHeight - 1)
        paneColor.setFill(); pane.fill()
        lineColor.setStroke()
        NSBezierPath(rect: pane).stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        func tabPath(_ r: NSRect) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX + 0.5, y: r.maxY))
            p.line(to: NSPoint(x: r.minX + 0.5, y: r.minY + 2.5))
            p.line(to: NSPoint(x: r.minX + 2.5, y: r.minY + 0.5))
            p.line(to: NSPoint(x: r.maxX - 2.5, y: r.minY + 0.5))
            p.line(to: NSPoint(x: r.maxX - 0.5, y: r.minY + 2.5))
            p.line(to: NSPoint(x: r.maxX - 0.5, y: r.maxY))
            return p
        }
        func label(_ i: Int, _ r: NSRect) {
            let s = (titles[i] as NSString).size(withAttributes: attrs)
            (titles[i] as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
        }
        // 選んでいないタブ
        for (i, r) in rects where i != selectedIndex {
            let rr = NSRect(x: r.minX, y: r.minY + 2, width: r.width, height: r.height - 2 + 0.5)
            let p = tabPath(rr)
            tabColor.setFill(); p.fill()
            lineColor.setStroke(); p.stroke()
            label(i, rr)
        }
        // 選んだタブ (2pt 大きくして、下の線を消して中身とつなげる)
        if let r = rects[selectedIndex] {
            let rr = NSRect(x: max(0, r.minX - 2), y: r.minY, width: min(bounds.width, r.width + 4) - (r.minX - 2 < 0 ? 2 : 0),
                            height: r.height + 1.5)
            let p = tabPath(rr)
            paneColor.setFill(); NSBezierPath(rect: rr.insetBy(dx: 0.5, dy: 0)).fill()
            lineColor.setStroke(); p.stroke()
            label(selectedIndex, NSRect(x: rr.minX, y: rr.minY, width: rr.width, height: rr.height - 1))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard pt.y < barHeight else { return super.mouseDown(with: event) }
        for (i, r) in tabRects() where r.contains(pt) {
            if i != selectedIndex { selectedIndex = i; onSelect?(i) }
            return
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
