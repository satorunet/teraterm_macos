import AppKit
import TeraCore

/// 設定 > 検索履歴: 履歴を一覧にして、1 件ずつ × で消せる
final class FindHistoryListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var items: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("q"))
        col.width = 480
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let all = NSButton(title: Lang.m("FIND_HISTORY_DELETE_ALL", "すべて消す"), target: self, action: #selector(deleteAll))
        all.bezelStyle = .rounded
        for v in [scroll, all] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 520), scroll.heightAnchor.constraint(equalToConstant: 300),
            all.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8), all.leadingAnchor.constraint(equalTo: leadingAnchor),
            all.bottomAnchor.constraint(equalTo: bottomAnchor), trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
        ])
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: FindBar.historyChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() {
        items = FindBar.history
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: items[row])
        label.font = .monoSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        let x = NSButton(image: Sym.image("xmark.circle.fill", nil) ?? NSImage(),
                         target: self, action: #selector(deleteRow(_:)))
        x.isBordered = false
        x.contentTintColor = .secondaryLabelColor
        x.tag = row
        x.toolTip = Lang.m("SETUP_BGIMAGE_REMOVE", "リストから外す")
        let row = NSStackView(views: [label, NSView(), x])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return row
    }
    @objc private func deleteRow(_ b: NSButton) {
        guard items.indices.contains(b.tag) else { return }
        var h = FindBar.history
        h.removeAll { $0 == items[b.tag] }
        FindBar.history = h
    }
    @objc private func deleteAll() { FindBar.history = [] }
    @objc func keepToggled(_ b: NSButton) { FindBar.keepHistory = b.state == .on }
}
