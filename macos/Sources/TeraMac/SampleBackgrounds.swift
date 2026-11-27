import AppKit
import TeraCore

/// 背景画像のサンプル。アプリの中で描いて ~/Library/Application Support/Tera Term Mac/backgrounds/ に PNG で置く
/// (画像ファイルを同梱しないので権利の心配がなく、アプリも大きくならない)
enum SampleBackgrounds {
    struct Sample { let id: String; let key: String; let ja: String; let draw: (CGContext, CGSize) -> Void }

    static var directory: String { (AppPaths.setupDirectory as NSString).appendingPathComponent("backgrounds") }

    static let all: [Sample] = [
        Sample(id: "night_sky", key: "SETUP_BGSAMPLE_NIGHT", ja: "夜空", draw: nightSky),
        Sample(id: "blueprint", key: "SETUP_BGSAMPLE_GRID", ja: "方眼", draw: blueprint),
        Sample(id: "dots", key: "SETUP_BGSAMPLE_DOTS", ja: "ドット", draw: dots),
        Sample(id: "waves", key: "SETUP_BGSAMPLE_WAVES", ja: "波", draw: waves),
        Sample(id: "sunset_teraterm", key: "SETUP_BGSAMPLE_SUNSET_LOGO", ja: "夕焼け (Tera Term Mac)", draw: sunsetLogo),
    ]

    /// サンプルのファイル (なければ描いて作る)。作れなければ nil
    static func path(for s: Sample) -> String? {
        let p = (directory as NSString).appendingPathComponent(s.id + ".png")
        if FileManager.default.fileExists(atPath: p) { return p }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return write(s, to: p) ? p : nil
    }

    /// サンプルを描いて PNG に書く
    static func write(_ s: Sample, to p: String) -> Bool {
        let size = CGSize(width: 1920, height: 1200)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        s.draw(ctx, size)
        guard let img = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: p))) != nil
    }

    /// 選ぶ画面に出す小さな絵 (ファイルは作らない)
    static func thumbnail(_ s: Sample, width: CGFloat = 200) -> NSImage? {
        let scale = width / 1920
        let w = Int(width), h = Int(1200 * scale)
        guard let ctx = CGContext(data: nil, width: w * 2, height: h * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale * 2, y: scale * 2)
        s.draw(ctx, CGSize(width: 1920, height: 1200))
        guard let img = ctx.makeImage() else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: w, height: h))
    }

    /// サンプルのファイルか (設定画面でどのサンプルを選んでいるか見せる)
    static func sample(at path: String) -> Sample? {
        all.first { (directory as NSString).appendingPathComponent($0.id + ".png") == path }
    }

    // MARK: - 絵

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
    private static func gradient(_ ctx: CGContext, _ size: CGSize, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    /// 毎回同じ絵になる乱数
    private struct Rand { var x: UInt64; mutating func next() -> CGFloat { x = x &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(x >> 33) / CGFloat(1 << 31) } }

    private static func nightSky(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, s, [color(4, 6, 20), color(18, 30, 70), color(40, 40, 90)], from: .zero, to: CGPoint(x: 0, y: s.height))
        var r = Rand(x: 42)
        for _ in 0..<700 {
            let x = r.next() * s.width, y = r.next() * s.height, d = 0.8 + r.next() * r.next() * 3.2
            ctx.setFillColor(color(255, 255, 240, 0.35 + r.next() * 0.65))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d))
        }
    }

    private static func blueprint(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, s, [color(14, 45, 95), color(10, 30, 70)], from: .zero, to: CGPoint(x: s.width, y: s.height))
        for (step, a, w) in [(32.0, 0.12, 1.0), (160.0, 0.28, 1.5)] {
            ctx.setStrokeColor(color(170, 210, 255, CGFloat(a)))
            ctx.setLineWidth(CGFloat(w))
            var x: CGFloat = 0
            while x <= s.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: s.height)); x += CGFloat(step) }
            var y: CGFloat = 0
            while y <= s.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: s.width, y: y)); y += CGFloat(step) }
            ctx.strokePath()
        }
    }

    private static func dots(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, s, [color(30, 32, 40), color(45, 40, 60)], from: .zero, to: CGPoint(x: s.width, y: s.height))
        let step: CGFloat = 28
        var y: CGFloat = step / 2, row = 0
        while y < s.height {
            var x: CGFloat = (row % 2 == 0 ? 0 : step / 2) + step / 2
            while x < s.width {
                let t = (x / s.width + y / s.height) / 2
                ctx.setFillColor(color(120 + 100 * t, 160, 255 - 80 * t, 0.45))
                ctx.fillEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
                x += step
            }
            y += step; row += 1
        }
    }

    private static func waves(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, s, [color(8, 40, 55), color(20, 80, 100)], from: .zero, to: CGPoint(x: 0, y: s.height))
        for i in 0..<6 {
            let base = s.height * (0.15 + CGFloat(i) * 0.12)
            ctx.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x <= s.width {
                let y = base + sin(x / (160 + CGFloat(i) * 30) + CGFloat(i)) * 40 + sin(x / 70 + CGFloat(i) * 2) * 10
                ctx.addLine(to: CGPoint(x: x, y: y)); x += 8
            }
            ctx.addLine(to: CGPoint(x: s.width, y: 0)); ctx.closePath()
            ctx.setFillColor(color(40 + CGFloat(i) * 20, 170 + CGFloat(i) * 10, 190, 0.18))
            ctx.fillPath()
        }
    }

    /// 夕焼けのグラデーションに「Tera Term Mac」の透かし
    private static func sunsetLogo(_ ctx: CGContext, _ s: CGSize) {
        gradient(ctx, s, [color(255, 140, 80), color(220, 80, 120), color(90, 50, 140), color(25, 25, 70)], from: .zero, to: CGPoint(x: 0, y: s.height))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 150, weight: .heavy),
                                                    .foregroundColor: NSColor(white: 1, alpha: 0.22)]
        let t = "Tera Term Mac" as NSString
        let sz = t.size(withAttributes: attrs)
        ctx.translateBy(x: s.width / 2, y: s.height / 2)
        ctx.rotate(by: .pi / 12)
        t.draw(at: NSPoint(x: -sz.width / 2, y: -sz.height / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
}


// MARK: - 背景リスト (サンプルと、自分で足した画像をサムネイルで並べるポップオーバー)

final class SampleBackgroundPicker: NSViewController {
    /// 選んだ画像のパス
    var onPick: ((String) -> Void)?
    /// 「画像を追加…」(ファイルを選ぶ画面を開く)
    var onAdd: (() -> Void)?
    private var current: String
    /// 設定画面の中に埋め込むとき (見出しなし・高さ固定)
    private let embedded: Bool
    private let root = NSView()
    private static var thumbCache: [String: NSImage] = [:]

    init(currentPath: String, embedded: Bool = false) {
        current = currentPath
        self.embedded = embedded
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = root
        build()
    }

    /// 選んでいる画像を変えて並べ直す
    func reload(current path: String) {
        current = path
        if isViewLoaded { build() }
    }

    private weak var scrollView: NSScrollView?
    private func build() {
        // 並べ直してもスクロールの位置は変えない
        let oldOrigin = scrollView?.contentView.bounds.origin
        root.subviews.forEach { $0.removeFromSuperview() }
        selectedTile = nil
        paths = []
        let title = NSTextField(labelWithString: Lang.m("SETUP_BGIMAGE_LIST_TITLE", "背景リスト"))
        title.font = .boldSystemFont(ofSize: 13)
        let note = NSTextField(labelWithString: Lang.m("SETUP_BGIMAGE_SAMPLES_NOTE2", "背景はカラーか画像のどちらか一方です。クリックすると端末に当てて見られます (OK で確定)"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        // 設定画面の中では「使用しない」は出さない (背景カラーを選べば画像は外れる)
        var tiles: [NSView] = embedded ? [] : [noneTile()]
        tiles += SampleBackgrounds.all.map { smp in
            tile(name: Lang.m(smp.key, smp.ja), image: SampleBackgrounds.thumbnail(smp, width: 168), path: nil, sample: smp, removable: false)
        }
        for p in MacBackgroundImage.userList where FileManager.default.fileExists(atPath: p) {
            tiles.append(tile(name: (p as NSString).lastPathComponent, image: Self.thumb(p), path: p, sample: nil, removable: true))
        }
        tiles.append(addTile())
        var rows: [NSView] = []
        var i = 0
        while i < tiles.count {
            rows.append(stack(Array(tiles[i..<min(tiles.count, i + 3)]), vertical: false, spacing: 12))
            i += 3
        }
        let grid = stack(rows, vertical: true, spacing: 12)
        grid.translatesAutoresizingMaskIntoConstraints = false

        // 多くなったらスクロール
        let doc = FlippedDoc()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: doc.topAnchor), grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                                     grid.trailingAnchor.constraint(equalTo: doc.trailingAnchor), grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor)])
        let scroll = NSScrollView()
        scrollView = scroll
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let gridSize = grid.fittingSize
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: gridSize.width + 4),
            // 埋め込みのときは高さを決めておく (画像が増えても画面の大きさが変わらないように)
            scroll.heightAnchor.constraint(equalToConstant: embedded ? 280 : min(gridSize.height, 430)),
        ])

        let v = stack(embedded ? [note, scroll] : [title, note, scroll], vertical: true, spacing: 10)
        v.translatesAutoresizingMaskIntoConstraints = false
        let box = root
        box.addSubview(v)
        let inset: CGFloat = embedded ? 0 : 1
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: 14 * inset),
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16 * inset),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16 * inset),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16 * inset),
        ])
        if !embedded { preferredContentSize = box.fittingSize }
        if let o = oldOrigin {
            root.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: o)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private final class FlippedDoc: NSView { override var isFlipped: Bool { true } }

    /// 自分で足した画像の小さな絵 (縦横比を保って 168×105 に収める)
    private static func thumb(_ path: String) -> NSImage? {
        if let t = thumbCache[path] { return t }
        guard let img = NSImage(contentsOfFile: path), img.size.width > 0, img.size.height > 0 else { return nil }
        let size = NSSize(width: 168, height: 105)
        let t = NSImage(size: size)
        t.lockFocus()
        NSColor.black.setFill(); NSRect(origin: .zero, size: size).fill()
        // 画面いっぱい (はみ出す部分は切る)
        let s = max(size.width / img.size.width, size.height / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        img.draw(in: NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        t.unlockFocus()
        thumbCache[path] = t
        return t
    }

    private func stack(_ views: [NSView], vertical: Bool, spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = vertical ? .vertical : .horizontal
        s.alignment = vertical ? .leading : .top
        s.spacing = spacing
        return s
    }

    private var paths: [String] = []

    private func tile(name: String, image: NSImage?, path: String?, sample: SampleBackgrounds.Sample?, removable: Bool) -> NSView {
        let selected = path.map { $0 == current } ?? (!current.isEmpty && SampleBackgrounds.sample(at: current)?.id == sample?.id)
        let b = NSButton(title: "", target: self, action: #selector(picked(_:)))
        b.tag = paths.count
        // サンプルは選んだときにファイルを作るので、目印として "sample:<id>" を入れておく
        paths.append(path ?? "sample:" + (sample?.id ?? ""))
        b.isBordered = false
        b.imageScaling = .scaleProportionallyUpOrDown
        b.image = image
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.layer?.masksToBounds = true
        b.layer?.borderWidth = selected ? 3 : 1
        b.layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        if selected { selectedTile = b }
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 168).isActive = true
        b.heightAnchor.constraint(equalToConstant: 105).isActive = true
        b.toolTip = path ?? name
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        // サムネイルの入れ物 (自分で足した画像は右上に × を重ねる)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(b)
        NSLayoutConstraint.activate([b.topAnchor.constraint(equalTo: holder.topAnchor), b.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                                     b.trailingAnchor.constraint(equalTo: holder.trailingAnchor), b.bottomAnchor.constraint(equalTo: holder.bottomAnchor)])
        if removable {
            // リストから外す (ファイルは消さない)。押しやすいように大きめの丸い × をサムネイルの右上に
            let x = NSButton(title: "", target: self, action: #selector(removeTapped(_:)))
            x.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: Lang.m("SETUP_BGIMAGE_REMOVE", "リストから外す"))?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .bold))
            x.isBordered = false
            x.contentTintColor = NSColor.white
            x.wantsLayer = true
            x.layer?.shadowOpacity = 0.6
            x.layer?.shadowRadius = 2
            x.layer?.shadowOffset = .zero
            x.tag = b.tag
            x.toolTip = Lang.m("SETUP_BGIMAGE_REMOVE", "リストから外す")
            x.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(x)
            NSLayoutConstraint.activate([x.topAnchor.constraint(equalTo: holder.topAnchor, constant: 5),
                                         x.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -5),
                                         x.widthAnchor.constraint(equalToConstant: 26), x.heightAnchor.constraint(equalToConstant: 26)])
        }
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 168).isActive = true
        return stack([holder, label], vertical: true, spacing: 4)
    }

    /// 「使用しない」(背景画像を出さない)。current が空のとき選んでいる
    private func noneTile() -> NSView {
        let sel = current.isEmpty
        let b = NSButton(title: Lang.m("SETUP_BGIMAGE_NONE", "使用しない"), target: self, action: #selector(noneTapped))
        if sel { selectedTile = b }
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.layer?.borderWidth = sel ? 3 : 1
        b.layer?.borderColor = sel ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        b.font = .systemFont(ofSize: 13, weight: sel ? .semibold : .regular)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 168).isActive = true
        b.heightAnchor.constraint(equalToConstant: 105).isActive = true
        return stack([b], vertical: true, spacing: 4)
    }
    @objc private func noneTapped() { onPick?("") }

    /// 選んでいるタイル (見えるところまでスクロールする)
    private weak var selectedTile: NSView?
    func scrollToSelection() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        guard let t = selectedTile, let doc = t.enclosingScrollView?.documentView else { return }
        let r = t.convert(t.bounds, to: doc).insetBy(dx: 0, dy: -24)
        doc.scrollToVisible(r)
    }

    private func addTile() -> NSView {
        let b = NSButton(title: Lang.m("SETUP_BGIMAGE_ADD", "＋ 画像を追加…"), target: self, action: #selector(addTapped))
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.layer?.borderWidth = 1
        b.layer?.borderColor = NSColor.separatorColor.cgColor
        b.font = .systemFont(ofSize: 13)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 168).isActive = true
        b.heightAnchor.constraint(equalToConstant: 105).isActive = true
        return stack([b], vertical: true, spacing: 4)
    }

    @objc private func picked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < paths.count else { return }
        let p = paths[sender.tag]
        if p.hasPrefix("sample:") {
            let id = String(p.dropFirst(7))
            guard let smp = SampleBackgrounds.all.first(where: { $0.id == id }), let file = SampleBackgrounds.path(for: smp) else { return }
            onPick?(file)
        } else {
            onPick?(p)
        }
    }

    @objc private func removeTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < paths.count else { return }
        MacBackgroundImage.removeFromList(paths[sender.tag])
        // 並べ直す
        build()
        if !embedded { view.window?.setContentSize(preferredContentSize) }
    }

    @objc private func addTapped() { onAdd?() }
}
