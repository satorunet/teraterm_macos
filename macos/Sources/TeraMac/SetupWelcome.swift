import AppKit
import TeraCore

// はじめのセットアップ: 起動時に開くもの・設定画面のデザイン・メニューバーのアイコン・新しい機能の入/切。
// 設定の「セットアップ」ページと、初めて起動したときの「ようこそ」ウインドウで同じ部品 (SetupChoicesView) を使う。

/// 端末の検索 (⌘F) を使うか。切ると メニューから消え、⌘F でも出ない
enum FindFeature {
    static let defaultsKey = "TeraMacFindEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set {
            guard newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            (NSApp.delegate as? AppDelegate)?.rebuildMenu()
        }
    }
}

// MARK: - アプリのアイコン (新しいアイコン / クラシック)

/// Dock・メニューバー・アプリの中の画面に使うアイコン。Finder のアイコンは変えない
/// (アプリの中身を書き換えると署名がこわれるため)
enum AppIconChoice {
    static let defaultsKey = "TeraMacAppIcon"
    static var isClassic: Bool {
        get { UserDefaults.standard.string(forKey: defaultsKey) == "classic" }
        set { UserDefaults.standard.set(newValue ? "classic" : "new", forKey: defaultsKey) }
    }
    static func image(classic: Bool) -> NSImage? {
        let name = classic ? "AppIconClassic" : "AppIcon"
        if let url = Bundle.main.url(forResource: name, withExtension: "icns") { return NSImage(contentsOf: url) }
        // バンドルの外 (自己テスト) では Resources から
        return NSImage(contentsOfFile: FileManager.default.currentDirectoryPath + "/Resources/\(name).icns")
    }
    /// いまの選択をアプリに当てる (Dock・メニューバーのアイコン)
    static func apply() {
        guard let icon = image(classic: isClassic) else { return }
        NSApp.applicationIconImage = icon
        TeraMenuController.shared.refreshStatusIcon()
    }
    /// カードの絵: 明るい台の上にアイコン
    static func thumb(classic: Bool) -> NSImage {
        let icon = image(classic: classic)
        return NSImage(size: SetupThumbs.size, flipped: false) { r in
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            let side: CGFloat = 92
            NSGraphicsContext.current?.imageInterpolation = classic ? .none : .high
            icon?.draw(in: NSRect(x: (r.width - side) / 2, y: (r.height - side) / 2, width: side, height: side))
            return true
        }
    }
}

// MARK: - 見本の絵 (アプリの中で描く。言語によらず、ダークモードにも合う)

enum SetupThumbs {
    enum Kind { case startupMenu, startupTerminal, styleSidebar, styleTabs }

    static let size = NSSize(width: 176, height: 110)
    /// カードに出す大きさ (絵は size で描いて縮める)
    static let displaySize = NSSize(width: 136, height: 85)

    static func image(_ k: Kind) -> NSImage {
        NSImage(size: size, flipped: true) { r in
            draw(k, in: r)
            return true
        }
    }

    private static func fill(_ r: NSRect, _ c: NSColor, radius: CGFloat = 0) {
        c.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
    /// 線の代わりの横棒 (文字の行に見える)
    private static func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: NSColor = NSColor.labelColor.withAlphaComponent(0.28), h: CGFloat = 3) {
        fill(NSRect(x: x, y: y, width: w, height: h), c, radius: h / 2)
    }

    /// 机の上のウインドウ (題名の帯と 3 つの丸)。中身の四角を返す
    @discardableResult
    private static func window(_ r: NSRect, content: NSColor = .controlBackgroundColor) -> NSRect {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        fill(r, .windowBackgroundColor, radius: 5)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            fill(NSRect(x: r.minX + 6 + CGFloat(i) * 7, y: r.minY + 4, width: 4.5, height: 4.5), c, radius: 2.25)
        }
        let body = NSRect(x: r.minX + 1, y: r.minY + 12, width: r.width - 2, height: r.height - 13)
        let p = NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4)
        content.setFill()
        p.fill()
        return body
    }

    private static func desk(_ r: NSRect) {
        let g = NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.55, blue: 0.85, alpha: 1),
                                    NSColor(srgbRed: 0.62, green: 0.45, blue: 0.78, alpha: 1)])
        g?.draw(in: NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6), angle: 90)
    }

    private static func draw(_ k: Kind, in r: NSRect) {
        desk(r)
        let w = r.insetBy(dx: 12, dy: 10)
        let accent = NSColor.controlAccentColor
        switch k {
        case .startupMenu:
            // 接続先の一覧 (TeraTerm Menu)
            let b = window(w)
            let icons: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemBlue, .systemPurple]
            for (i, c) in icons.enumerated() {
                let y = b.minY + 6 + CGFloat(i) * 15
                if i == 1 { fill(NSRect(x: b.minX + 4, y: y - 3, width: b.width - 8, height: 13), accent.withAlphaComponent(0.25), radius: 3) }
                fill(NSRect(x: b.minX + 9, y: y, width: 8, height: 7), c, radius: 2)
                bar(b.minX + 22, y + 2, [70, 52, 84, 46, 60][i])
                bar(b.maxX - 30, y + 2, 20, NSColor.labelColor.withAlphaComponent(0.15))
            }
        case .startupTerminal:
            // 端末と「新しい接続」の画面
            let b = window(w, content: NSColor(white: 0.08, alpha: 1))
            let green = NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)
            bar(b.minX + 6, b.minY + 6, 30, green)
            bar(b.minX + 6, b.minY + 13, 18, NSColor.white.withAlphaComponent(0.6))
            let d = NSRect(x: b.midX - 46, y: b.minY + 20, width: 92, height: b.height - 26)
            fill(d, .windowBackgroundColor, radius: 4)
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: d.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
            bar(d.minX + 8, d.minY + 8, 34)
            fill(NSRect(x: d.minX + 8, y: d.minY + 16, width: d.width - 16, height: 9), .textBackgroundColor, radius: 2)
            bar(d.minX + 8, d.minY + 31, 26)
            fill(NSRect(x: d.maxX - 30, y: d.maxY - 14, width: 22, height: 9), accent, radius: 3)
        case .styleSidebar:
            // 左に一覧、右に中身 (Mac のシステム設定風)
            let b = window(w)
            let side = NSRect(x: b.minX, y: b.minY, width: b.width * 0.36, height: b.height)
            fill(side, NSColor.labelColor.withAlphaComponent(0.05))
            let tiles: [NSColor] = [.systemGray, .systemPurple, .systemOrange, .systemBlue, .systemGreen]
            for (i, c) in tiles.enumerated() {
                let y = side.minY + 6 + CGFloat(i) * 14
                if i == 1 { fill(NSRect(x: side.minX + 3, y: y - 3, width: side.width - 6, height: 12), accent.withAlphaComponent(0.3), radius: 3) }
                fill(NSRect(x: side.minX + 7, y: y, width: 7, height: 7), c, radius: 2)
                bar(side.minX + 18, y + 2, side.width - 26)
            }
            let x = side.maxX + 8
            bar(x, b.minY + 7, 40, NSColor.labelColor.withAlphaComponent(0.45), h: 4)
            for i in 0..<4 {
                let y = b.minY + 20 + CGFloat(i) * 12
                NSColor.labelColor.withAlphaComponent(0.35).setStroke()
                NSBezierPath(roundedRect: NSRect(x: x, y: y - 1, width: 6, height: 6), xRadius: 1.5, yRadius: 1.5).stroke()
                bar(x + 10, y + 1, [48, 36, 54, 30][i])
            }
        case .styleTabs:
            // 上に 2 段のタブ (Windows 版と同じ)
            let b = window(w)
            let rowH: CGFloat = 9
            for row in 0..<2 {
                let widths: [CGFloat] = row == 0 ? [20, 14, 26, 22, 18, 26] : [18, 24, 16, 22, 26, 20]
                let total = widths.reduce(0, +)
                var x = b.minX + 4
                let y = b.minY + 4 + CGFloat(row) * rowH
                for (i, tw) in widths.enumerated() {
                    let ww = tw / total * (b.width - 8)
                    let sel = row == 1 && i == 2
                    let t = NSRect(x: x, y: y, width: ww - 1, height: rowH + (sel ? 1 : -1))
                    fill(t, sel ? .controlBackgroundColor : NSColor.labelColor.withAlphaComponent(0.12), radius: 2)
                    NSColor.separatorColor.setStroke()
                    NSBezierPath(roundedRect: t, xRadius: 2, yRadius: 2).stroke()
                    x += ww
                }
            }
            let c = NSRect(x: b.minX + 4, y: b.minY + 4 + rowH * 2, width: b.width - 8, height: b.height - 8 - rowH * 2)
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: c).stroke()
            for i in 0..<4 { bar(c.minX + 8, c.minY + 8 + CGFloat(i) * 11, [60, 44, 70, 36][i]) }
        }
    }
}

// MARK: - 絵で選ぶカード

final class ThumbCard: NSView {
    var isSelected = false { didSet { needsDisplay = true; badge.isHidden = !isSelected; setAccessibilityValue(isSelected) } }
    var onClick: (() -> Void)?
    private let badge = NSImageView()

    init(image: NSImage, title: String, caption: String) {
        super.init(frame: .zero)
        let iv = NSImageView(image: image)
        iv.imageScaling = .scaleProportionallyUpOrDown
        let t = NSTextField(labelWithString: title)
        t.font = .boldSystemFont(ofSize: 12)
        t.alignment = .center
        t.lineBreakMode = .byWordWrapping
        t.maximumNumberOfLines = 2
        t.preferredMaxLayoutWidth = SetupThumbs.displaySize.width + 16
        let c = NSTextField(wrappingLabelWithString: caption)
        c.font = .systemFont(ofSize: 11)
        c.textColor = .secondaryLabelColor
        c.alignment = .center
        c.isHidden = caption.isEmpty
        c.preferredMaxLayoutWidth = SetupThumbs.displaySize.width + 16
        let st = NSStackView(views: [iv, t, c])
        st.orientation = .vertical
        st.spacing = 3
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        badge.image = Sym.image("checkmark.circle.fill", nil, size: 18) ?? Sym.glyphImage("✓", size: 16, weight: .bold)
        badge.contentTintColor = .controlAccentColor
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            st.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            st.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            st.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            iv.widthAnchor.constraint(equalToConstant: SetupThumbs.displaySize.width),
            iv.heightAnchor.constraint(equalToConstant: SetupThumbs.displaySize.height),
            c.widthAnchor.constraint(equalToConstant: SetupThumbs.displaySize.width + 16),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            p.fill()
            NSColor.controlAccentColor.setStroke()
            p.lineWidth = 2.5
        } else {
            NSColor.separatorColor.setStroke()
            p.lineWidth = 1
        }
        p.stroke()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// 2 枚のカードから 1 つ選ぶ
final class ThumbChoice: NSStackView {
    private(set) var cards: [ThumbCard] = []
    var onChange: ((Int) -> Void)?
    var selectedIndex = 0 { didSet { for (i, c) in cards.enumerated() { c.isSelected = i == selectedIndex } } }

    init(_ items: [(NSImage, String, String)]) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 10
        for (i, it) in items.enumerated() {
            let c = ThumbCard(image: it.0, title: it.1, caption: it.2)
            c.onClick = { [weak self] in
                guard let self = self, self.selectedIndex != i else { return }
                self.selectedIndex = i
                self.onChange?(i)
            }
            cards.append(c)
            addArrangedSubview(c)
        }
        selectedIndex = 0
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 入/切の行 (アイコン・名前・説明・スイッチ)

final class FeatureSwitchRow: NSStackView {
    private let control: NSControl
    var onChange: ((Bool) -> Void)?
    var isOn: Bool {
        get { Self.state(of: control) }
        set { Self.set(control, newValue); updateDim() }
    }
    /// 切のときは、その行のアイコンと説明をうす暗くする
    private var dimmed: [NSView] = []
    private func updateDim() { for v in dimmed { v.alphaValue = isOn ? 1 : 0.38 } }

    init(icon: NSImage?, title: String, detail: String) {
        if #available(macOS 10.15, *) { control = NSSwitch() } else { control = NSButton(checkboxWithTitle: "", target: nil, action: nil) }
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
        let iv = NSImageView()
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let t = NSTextField(labelWithString: title)
        t.font = .boldSystemFont(ofSize: 13)
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.preferredMaxLayoutWidth = 290
        let texts = NSStackView(views: [t, d])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.widthAnchor.constraint(equalToConstant: 300).isActive = true
        control.target = self
        control.action = #selector(toggled)
        control.setAccessibilityLabel(title)
        // スイッチは左に (右の端だと、どの行のものか分かりにくいため)
        addArrangedSubview(control)
        addArrangedSubview(iv)
        addArrangedSubview(texts)
        dimmed = [iv, texts]
        updateDim()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled() { updateDim(); onChange?(isOn) }

    private static func state(of c: NSControl) -> Bool {
        if #available(macOS 10.15, *), let s = c as? NSSwitch { return s.state == .on }
        return (c as? NSButton)?.state == .on
    }
    private static func set(_ c: NSControl, _ on: Bool) {
        if #available(macOS 10.15, *), let s = c as? NSSwitch { s.state = on ? .on : .off; return }
        (c as? NSButton)?.state = on ? .on : .off
    }

    /// 色付きの角丸の四角に白いアイコン (設定の一覧のアイコンと同じ見た目)
    static func tile(_ symbol: String, _ color: NSColor, fallback: String) -> NSImage {
        let inner = Sym.image(symbol, nil, size: 15, weight: .semibold) ?? Sym.glyphImage(fallback, size: 15, weight: .bold)
        return NSImage(size: NSSize(width: 28, height: 28), flipped: false) { r in
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            let s = inner.size
            let dst = NSRect(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2, width: s.width, height: s.height)
            // 白で塗る (テンプレート画像を白に)
            let tinted = NSImage(size: s, flipped: false) { rr in
                inner.draw(in: rr)
                NSColor.white.set()
                rr.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: dst)
            return true
        }
    }
}

// MARK: - セットアップの中身 (設定のページと「ようこそ」で共通)

final class SetupChoicesView: NSStackView {
    enum Field { case startup, style, appIcon, statusIcon, ttmado, background, find }

    let startup = ThumbChoice([
        (SetupThumbs.image(.startupMenu), Lang.m("SETUP_STARTUP_MENU_SHORT", "接続先一覧 (TTMenu) から選ぶ"), ""),
        (SetupThumbs.image(.startupTerminal), Lang.m("SETUP_STARTUP_TERMINAL_SHORT2", "Windows 版と同じく「新しい接続」画面が開く"), ""),
    ])
    let style = ThumbChoice([
        (SetupThumbs.image(.styleSidebar), Lang.m("SETUP_STYLE_SIDEBAR_SHORT", "一覧"),
         Lang.m("SETUP_STYLE_SIDEBAR_DESC", "左の一覧からページを選びます (Mac のシステム設定風。検索もできます)")),
        (SetupThumbs.image(.styleTabs), Lang.m("SETUP_STYLE_TABS_SHORT", "タブ"),
         Lang.m("SETUP_STYLE_TABS_DESC", "上の 2 段のタブでページを切り替えます (Windows 版と同じ)")),
    ])
    let appIcon = ThumbChoice([
        (AppIconChoice.thumb(classic: false), Lang.m("SETUP_ICON_NEW", "新しいアイコン"), ""),
        (AppIconChoice.thumb(classic: true), Lang.m("SETUP_ICON_CLASSIC", "クラシック"), ""),
    ])
    let statusIcon = FeatureSwitchRow(
        icon: { let i = (NSApp.applicationIconImage.copy() as? NSImage) ?? NSImage(); i.size = NSSize(width: 28, height: 28); return i }(),
        title: Lang.m("SETUP_FEAT_STATUSICON", "メニューバーのアイコン"),
        detail: Lang.m("SETUP_FEAT_STATUSICON_DESC", "画面右上に常駐し、接続先リストからすぐ接続できます"))
    let ttmado = FeatureSwitchRow(
        icon: FeatureSwitchRow.tile("rectangle.split.2x1", .systemBlue, fallback: "◫"),
        title: Lang.m("SETUP_FEAT_TTMADO", "タブ・窓割り (TTMado)"),
        detail: Lang.m("PLUGIN_TTMADO_DESC", "タブ・窓割り (タブの分割表示・合体・ドラッグでの並べ替え)"))
    let background = FeatureSwitchRow(
        icon: FeatureSwitchRow.tile("photo.fill", .systemPink, fallback: "▧"),
        title: Lang.m("SETUP_FEAT_BG", "背景画像"),
        detail: Lang.m("SETUP_FEAT_BG_DESC", "端末の背景に画像をうっすら出します (設定 ＞ 背景 で画像を選べます)"))
    let find = FeatureSwitchRow(
        icon: FeatureSwitchRow.tile("magnifyingglass", .systemOrange, fallback: "⌕"),
        title: Lang.m("SETUP_FEAT_FIND", "端末の検索 (⌘F)"),
        detail: Lang.m("SETUP_FEAT_FIND_DESC", "画面とスクロールバッファの中の文字を探して、色を付けて見せます"))

    var onChange: ((Field) -> Void)?

    /// wide: 2 つの絵の組を横に並べる (ようこそ。縦に長くならないように)
    /// ようこそでは設定画面のデザインは出さず、上の段を「起動時の画面」と「アプリのアイコン」にする
    private let includeStyle: Bool

    init(wide: Bool = false, includeStyle: Bool = true) {
        self.includeStyle = includeStyle
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        func heading(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = .boldSystemFont(ofSize: 14)
            return t
        }
        func group(_ title: String, _ v: NSView) -> NSStackView {
            let g = NSStackView(views: [heading(title), v])
            g.orientation = .vertical
            g.alignment = .leading
            g.spacing = 8
            return g
        }
        let g1 = group(Lang.m("SETUP_STARTUP_HEAD", "起動したときに開く画面"), startup)
        let g2 = group(Lang.m("SETUP_STYLE_HEAD", "設定画面のデザイン"), style)
        let note = NSTextField(wrappingLabelWithString: Lang.m("SETUP_FEAT_NOTE", "Mac 版で足した機能です。使わないものは切っておけます。"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let feats = NSStackView(views: [heading(Lang.m("SETUP_FEAT_HEAD", "使う機能")), note, statusIcon, ttmado, background, find])
        feats.orientation = .vertical
        feats.alignment = .leading
        feats.spacing = 8
        let iconNote = NSTextField(wrappingLabelWithString: Lang.m("SETUP_ICON_NOTE", "Dock・メニューバー・アプリの画面のアイコンが変わります (Finder のアイコンはそのまま)"))
        iconNote.font = .systemFont(ofSize: 11)
        iconNote.textColor = .secondaryLabelColor
        iconNote.preferredMaxLayoutWidth = 2 * (SetupThumbs.displaySize.width + 32) + 10
        let g3 = group(Lang.m("SETUP_ICON_HEAD", "アプリのアイコン"), appIcon)
        g3.addArrangedSubview(iconNote)
        func hrow(_ v: [NSView]) -> NSStackView {
            let r = NSStackView(views: v)
            r.orientation = .horizontal
            r.alignment = .top
            r.spacing = 28
            return r
        }
        if !includeStyle {
            // ようこそ: 上に起動時の画面とアイコン、下に使う機能
            let row = hrow([g1, g3])
            addArrangedSubview(row)
            setCustomSpacing(22, after: row)
            addArrangedSubview(feats)
        } else if wide {
            let row = hrow([g1, g2])
            addArrangedSubview(row)
            setCustomSpacing(22, after: row)
            addArrangedSubview(hrow([feats, g3]))
        } else {
            for g in [g1, g2, g3] as [NSView] { addArrangedSubview(g); setCustomSpacing(18, after: g) }
            addArrangedSubview(feats)
        }
        startup.onChange = { [weak self] _ in self?.onChange?(.startup) }
        style.onChange = { [weak self] _ in self?.onChange?(.style) }
        appIcon.onChange = { [weak self] _ in self?.onChange?(.appIcon) }
        statusIcon.onChange = { [weak self] _ in self?.onChange?(.statusIcon) }
        ttmado.onChange = { [weak self] _ in self?.onChange?(.ttmado) }
        background.onChange = { [weak self] _ in self?.onChange?(.background) }
        find.onChange = { [weak self] _ in self?.onChange?(.find) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// アプリのいまの設定を読む (ようこそ用。設定画面ではページの項目から読む)
    func loadFromApp() {
        startup.selectedIndex = AppDelegate.startupOpensMenu ? 0 : 1
        style.selectedIndex = SetupSheet.classicTabs ? 1 : 0
        appIcon.selectedIndex = AppIconChoice.isClassic ? 1 : 0
        statusIcon.isOn = TeraMenuController.showsStatusItem
        ttmado.isOn = TTMado.isEnabled
        background.isOn = ThemeRuntime.shared.macImage.enabled
        find.isOn = FindFeature.isEnabled
    }

    /// 選んだものをアプリに当てる (ようこそ用)
    func applyToApp() {
        AppDelegate.startupOpensMenu = startup.selectedIndex == 0
        if includeStyle { SetupSheet.classicTabs = style.selectedIndex == 1 }
        AppIconChoice.isClassic = appIcon.selectedIndex == 1
        AppIconChoice.apply()
        TeraMenuController.showsStatusItem = statusIcon.isOn
        TTMado.setEnabled(ttmado.isOn)
        var m = ThemeRuntime.shared.macImage
        if background.isOn != m.enabled {
            m.enabled = background.isOn
            if m.enabled, m.file.isEmpty || !FileManager.default.fileExists(atPath: m.file) {
                m.file = SetupChoicesView.defaultBackgroundFile ?? ""
            }
            m.save()
            ThemeRuntime.shared.macImage = m
        }
        FindFeature.isEnabled = find.isOn
    }

    /// 背景を入にしたときに使う画像 (画像をまだ選んでいなければ、サンプルの 1 枚目)
    static var defaultBackgroundFile: String? {
        SampleBackgrounds.all.first.flatMap { SampleBackgrounds.path(for: $0) }
    }
}

// MARK: - 初めて起動したときの「ようこそ」

final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shownKey = "TeraMacWelcomeShown"
    /// まだ出していなければ出す。閉じたら then を呼ぶ (起動時の画面を開く)
    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: shownKey) }

    private static var current: WelcomeWindowController?
    private let choices = SetupChoicesView(wide: true, includeStyle: false)
    private var then: (() -> Void)?
    private weak var iconHeader: NSImageView?
    private var finished = false

    static func show(then: @escaping () -> Void) {
        let c = WelcomeWindowController(then: then)
        current = c
        c.window?.center()
        c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(then: @escaping () -> Void) {
        self.then = then
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = Lang.m("WELCOME_WINDOW_TITLE", "Tera Term Mac の初期設定")
        super.init(window: w)
        w.delegate = self
        w.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        iconHeader = icon
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let title = NSTextField(labelWithString: Lang.m("WELCOME_TITLE", "Tera Term Mac へようこそ"))
        title.font = .boldSystemFont(ofSize: 20)
        let sub = NSTextField(wrappingLabelWithString: Lang.m("WELCOME_SUB", "使いかたに合わせて選んでください。あとから 設定 ＞ 初期設定 でいつでも変えられます。"))
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = 640
        let texts = NSStackView(views: [title, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4
        let header = NSStackView(views: [icon, texts])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let done = NSButton(title: Lang.m("WELCOME_START", "はじめる"), target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), done])
        buttons.orientation = .horizontal

        let root = NSStackView(views: [header, choices, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 20
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            // 右にも余白 (中身の幅でウインドウを広げる)
            choices.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
        ])
        w.contentView = container
        choices.loadFromApp()
        // アイコンは選んだらすぐ Dock・メニューバーに出す (閉じるボタンで閉じたら元に戻す)
        choices.onChange = { [weak self] f in
            guard f == .appIcon, let self = self,
                  let icon = AppIconChoice.image(classic: self.choices.appIcon.selectedIndex == 1) else { return }
            NSApp.applicationIconImage = icon
            TeraMenuController.shared.refreshStatusIcon()
            self.iconHeader?.image = icon
        }
        w.setContentSize(container.fittingSize)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func finish() {
        finished = true
        choices.applyToApp()
        window?.close()
    }

    /// 「はじめる」でも閉じるボタンでも: 出したことを覚えて、起動時の画面を開く
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        if !finished { AppIconChoice.apply() }
        let t = then
        then = nil
        Self.current = nil
        DispatchQueue.main.async { t?() }
    }

    /// 自己テスト用: ようこそを写す
    static func snapshot(to path: String) {
        // バンドルの外で写すときは、アイコンを Resources/AppIcon.icns から読む
        if Bundle.main.bundleURL.pathExtension != "app", let icon = AppIconChoice.image(classic: AppIconChoice.isClassic) {
            NSApp.applicationIconImage = icon
        }
        let c = WelcomeWindowController(then: {})
        guard let v = c.window?.contentView else { return }
        v.layoutSubtreeIfNeeded()
        if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
