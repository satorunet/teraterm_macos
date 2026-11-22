import AppKit
import TeraCore

// Tera Term のテーマ (themefile.cpp / theme.h / vtdisp.c の BG 部分の移植)
//
//   let t = ThemeFile.load(path, base: settings)   // ThemeLoad()
//   t.colors.apply(to: &settings)                   // ThemeSetColor()
//   t.background.isEnabled                          // DecideBGEnable()
//   t.background.render(size:...)                   // CreateBGImage() → CGImage
//
// テーマの .ini の書き方 (installer/release/theme にある見本と同じ):
//   [Color Theme]  VTColor / BoldColor / BlinkColor / ReverseColor / URLColor / VTUnderlineColor = change,enable,r,g,b,r,g,b
//                  ANSIColor = change,enable, 16 色の r,g,b ... (または ANSIColor=1 と Fore= / Red= ... の個別指定)
//   [BG Theme]     BGDestEnable / BGDestFile / BGDestPattern / BGDestColor / BGDestAlpha / BGSrc1* / BGSrc2* / BGReverseTextAlpha ...
//   [BG]           古い書き方 (BGPictureFile / BGFadeColor / BGFadeTone / VTFore / Red ... など)

// MARK: - 色

/// 文字属性ひとつの色 (TColorSetting)
struct ThemeColorSetting {
    /// TRUE = 既定の色から変える
    var change = false
    /// TRUE = この文字属性の独自色を有効にする
    var enable = false
    var fg: NSColor
    var bg: NSColor
    init(_ p: ColorPair) { fg = p.fg; bg = p.bg }
    var pair: ColorPair { ColorPair(fg: fg, bg: bg) }
}

/// カラーテーマ (TColorTheme)
struct ThemeColors {
    var name = ""
    var vt: ThemeColorSetting          // SGR 0 (文字色 / 背景色)
    var bold: ThemeColorSetting        // SGR 1
    var underline: ThemeColorSetting   // SGR 4
    var blink: ThemeColorSetting       // SGR 5
    var reverse: ThemeColorSetting     // SGR 7
    var url: ThemeColorSetting
    var ansiChange = false
    /// ANSI 256 色の先頭 16 色 (0-7 暗い色, 8-15 明るい色)
    var ansi: [NSColor]

    /// 既定値 = いまの設定の色 (ThemeGetColorDefaultTS)
    init(defaults s: TermSettings) {
        vt = ThemeColorSetting(ColorPair(fg: s.fg, bg: s.bg))
        bold = ThemeColorSetting(s.boldColor)
        underline = ThemeColorSetting(s.underlineColor)
        blink = ThemeColorSetting(s.blinkColor)
        reverse = ThemeColorSetting(s.reverseColor)
        url = ThemeColorSetting(s.urlColor)
        ansi = s.ansi16 ?? Array(Palette.colors.prefix(16))
    }

    /// 設定の色にする (ThemeSetColor と同じく、色はすべてそのまま写す)
    func apply(to s: inout TermSettings) {
        s.fg = vt.fg; s.bg = vt.bg
        s.boldColor = bold.pair
        s.underlineColor = underline.pair
        s.blinkColor = blink.pair
        s.reverseColor = reverse.pair
        s.urlColor = url.pair
        let std = Array(Palette.colors.prefix(16)).map(TermSettings.rgbString)
        s.ansi16 = ansi.map(TermSettings.rgbString) == std ? nil : ansi
    }
}

// MARK: - 背景

enum BGType: Int { case color = 0, picture, wallpaper, none }

/// 画像の表示方法 (BG_PATTERN。INI の文字列は ThemeBGPatternList と同じ)
enum BGPattern: String, CaseIterable {
    case stretch                     // 画面に合わせて伸縮 (アスペクト比は無視)
    case tile                        // 左上からタイル状に並べる
    case center                      // 中央に表示
    case fitWidth = "fit_width"
    case fitHeight = "fit_height"
    case autofit                     // アスペクト比を保って、はみ出してでも最大表示
    case autofill                    // アスペクト比を保って、はみ出さないように最大表示
}

/// 背景の要素ひとつ (TBGSrc)
struct BGSrc {
    var type: BGType
    var enable = false
    var alpha: Int
    var antiAlias = true
    var pattern = BGPattern.stretch
    /// 画像のない部分の塗りつぶし色 / type=color の色
    var color: NSColor
    /// 画像ファイル (絶対パス。ワイルドカードは読み込み時にひとつ選ばれている)
    var file = ""
}

/// 背景のテーマ (BGTheme)
struct BGImageSpec {
    /// 背景画像 (type = picture)
    var dest = BGSrc(type: .picture, alpha: 255, color: TermSettings.rgb(0, 0, 0))
    /// 壁紙 (Mac ではデスクトップのピクチャ, type = wallpaper)
    var src1 = BGSrc(type: .wallpaper, alpha: 0, color: TermSettings.rgb(255, 255, 255))
    /// 単色プレーン (type = color)
    var src2 = BGSrc(type: .color, alpha: 128, color: TermSettings.rgb(0, 0, 0))
    /// 通常属性 (SGR 0) の文字の背景の不透明度 (0 = 背景画像がそのまま見える)
    var textBackAlpha = 0
    /// 反転属性 (SGR 7) の文字の背景の不透明度
    var reverseTextAlpha = 255
    /// そのほかの文字の背景の不透明度
    var backAlpha = 0

    /// 既定値 (ThemeGetBGDefault)
    static let `default` = BGImageSpec()

    /// 背景の処理をするか (DecideBGEnable)。背景画像のファイルがなければ dest は使わない
    var isEnabled: Bool {
        let destOn = dest.enable && !dest.file.isEmpty && FileManager.default.fileExists(atPath: dest.file)
        return destOn || src1.enable || src2.enable
    }

    /// 文字の背景を塗るときの不透明度 0...1 (vtdisp.c GetDrawAttr)
    ///   isDefaultBack: 背景色が標準の背景色と同じ / reverse: 反転属性
    func cellBackAlpha(isDefaultBack: Bool, reverse: Bool) -> CGFloat {
        let a = isDefaultBack ? textBackAlpha : (reverse ? reverseTextAlpha : backAlpha)
        return CGFloat(max(0, min(255, a))) / 255
    }

    /// 背景の絵を作る (vtdisp.c CreateBGImage)。size はポイント、scale は backingScaleFactor。
    /// windowFrame (画面座標) と screen を渡すと、壁紙 (src1) をウインドウの位置に合わせて切り出す
    func render(size: NSSize, scale: CGFloat = 2, windowFrame: NSRect? = nil, screen: NSScreen? = nil) -> CGImage? {
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        // 下地は黒 (CreateScreenCompatibleBitmap の中身)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(full)

        // 壁紙
        if src1.enable { drawSrc(src1, ctx, full, scale: scale, windowFrame: windowFrame, screen: screen) }
        // 指定画像
        let destImage = dest.enable ? ThemeImageCache.image(dest.file) : nil
        if dest.enable, destImage != nil {
            if !src1.enable { ctx.setFillColor(dest.color.cgColor); ctx.fill(full) }   // 壁紙がなければ塗っておく
            ctx.saveGState()
            ctx.setAlpha(CGFloat(max(0, min(255, dest.alpha))) / 255)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawSrc(dest, ctx, full, scale: scale, windowFrame: windowFrame, screen: screen)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        // 単色プレーン (ブレンドするものがなければ単純な塗りつぶし)
        if src2.enable {
            ctx.saveGState()
            let blend = (dest.enable && destImage != nil) || src1.enable
            ctx.setAlpha(blend ? CGFloat(max(0, min(255, src2.alpha))) / 255 : 1)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawSrc(src2, ctx, full, scale: scale, windowFrame: windowFrame, screen: screen)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// render() の NSImage 版 (大きさはポイント)
    func image(size: NSSize, scale: CGFloat = 2, windowFrame: NSRect? = nil, screen: NSScreen? = nil) -> NSImage? {
        guard let cg = render(size: size, scale: scale, windowFrame: windowFrame, screen: screen) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    /// BGLoadSrc
    private func drawSrc(_ src: BGSrc, _ ctx: CGContext, _ full: CGRect, scale: CGFloat, windowFrame: NSRect?, screen: NSScreen?) {
        switch src.type {
        case .color:
            ctx.setFillColor(src.color.cgColor); ctx.fill(full)
        case .picture:
            // BGLoadPicture: まず塗りつぶし色で塗って画像を置く
            ctx.setFillColor(src.color.cgColor); ctx.fill(full)
            guard let img = ThemeImageCache.image(src.file) else { return }
            ctx.interpolationQuality = src.antiAlias ? .high : .none
            Self.place(img, pattern: src.pattern, in: full, scale: scale, ctx)
        case .wallpaper:
            Self.drawWallpaper(ctx, full, scale: scale, windowFrame: windowFrame, screen: screen ?? NSScreen.main)
        case .none:
            break
        }
    }

    /// 画像を pattern どおりに置く (CG の座標は左下が原点なので、上下は Windows と逆に数える)
    private static func place(_ img: CGImage, pattern: BGPattern, in r: CGRect, scale: CGFloat, _ ctx: CGContext) {
        // 画像の大きさ (Windows の 1 ピクセル = Mac の 1 ポイント)
        let iw = CGFloat(img.width) * scale, ih = CGFloat(img.height) * scale
        guard iw > 0, ih > 0 else { return }
        var p = pattern
        if p == .autofit { p = ih * r.width > r.height * iw ? .fitWidth : .fitHeight }
        else if p == .autofill { p = ih * r.width > r.height * iw ? .fitHeight : .fitWidth }
        switch p {
        case .stretch, .autofit, .autofill:
            ctx.draw(img, in: r)
        case .fitWidth:
            let h = ih * r.width / iw
            ctx.draw(img, in: CGRect(x: 0, y: (r.height - h) / 2, width: r.width, height: h))
        case .fitHeight:
            let w = iw * r.height / ih
            ctx.draw(img, in: CGRect(x: (r.width - w) / 2, y: 0, width: w, height: r.height))
        case .tile:
            // 左上から並べる
            var y = r.height - ih
            while y > -ih {
                var x: CGFloat = 0
                while x < r.width { ctx.draw(img, in: CGRect(x: x, y: y, width: iw, height: ih)); x += iw }
                y -= ih
            }
        case .center:
            ctx.draw(img, in: CGRect(x: (r.width - iw) / 2, y: (r.height - ih) / 2, width: iw, height: ih))
        }
    }

    /// 壁紙 (BGLoadWallpaper): デスクトップのピクチャを画面いっぱいに置き、ウインドウの位置の部分を使う
    private static func drawWallpaper(_ ctx: CGContext, _ full: CGRect, scale: CGFloat, windowFrame: NSRect?, screen: NSScreen?) {
        guard let screen = screen, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let img = ThemeImageCache.image(url.path) else { return }
        let sf = screen.frame
        let win = windowFrame ?? sf
        // 画面を「画面いっぱいに表示」(アスペクト比を保って埋める) で塗ったときの画像の位置
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let k = max(sf.width / iw, sf.height / ih)
        let dw = iw * k, dh = ih * k
        let imgRect = CGRect(x: sf.midX - dw / 2, y: sf.midY - dh / 2, width: dw, height: dh)
        // ウインドウ (full) の座標に直す
        let sx = full.width / max(1, win.width), sy = full.height / max(1, win.height)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: (imgRect.minX - win.minX) * sx, y: (imgRect.minY - win.minY) * sy,
                                 width: imgRect.width * sx, height: imgRect.height * sy))
    }
}

/// 背景画像の読み込み (同じファイルは読み直さない)
enum ThemeImageCache {
    private static var cache: [String: CGImage] = [:]
    static func image(_ path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        if let c = cache[path] { return c }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if cache.count > 16 { cache.removeAll() }
        cache[path] = img
        return img
    }
}

// MARK: - テーマファイル

/// 読み込んだテーマ
struct ThemeData {
    /// 読み込んだファイル (nil = テーマ無し / 既定値)
    var path: String?
    var colors: ThemeColors
    var background: BGImageSpec
}

enum ThemeFile {
    private static let bgSectionOld = "BG"
    private static let bgSectionNew = "BG Theme"
    private static let colorSection = "Color Theme"

    /// テーマファイルを読む (ThemeLoad)。path が nil や読めないファイルのときは既定値
    ///   base: 色の既定値にする設定 (いまの文字色・背景色・ANSI 色など)
    static func load(_ path: String?, base: TermSettings) -> ThemeData {
        var colors = ThemeColors(defaults: base)
        var bg = BGImageSpec.default
        guard let path = path, let d = FileManager.default.contents(atPath: path), let ini = IniFile(data: d) else {
            return ThemeData(path: nil, colors: colors, background: bg)
        }
        // テーマファイルからの相対パスで画像を探す
        let dir = (path as NSString).deletingLastPathComponent
        let r = Reader(ini: ini, dir: dir)
        let names = ini.sectionNames.map { $0.lowercased() }
        let hasBG = names.contains(bgSectionNew.lowercased()) || names.contains(bgSectionOld.lowercased())
        let hasColor = names.contains(colorSection.lowercased())
        if hasBG && hasColor {
            loadBG(r, &bg)
            loadColor(r, &colors)
        } else if hasBG {
            loadBG(r, &bg)
            loadColorOld(r, &colors)
        } else if hasColor {
            loadColor(r, &colors)
        }
        return ThemeData(path: path, colors: colors, background: bg)
    }

    // MARK: 読み込みの部品 (GetPrivateProfile* と同じ読み方)

    private struct Reader {
        let ini: IniFile
        let dir: String

        func str(_ s: String, _ k: String) -> String? { ini.string(s, k) }

        /// GetPrivateProfileInt: キーがない・値が空なら既定値、数字でなければ 0
        func int(_ s: String, _ k: String, _ def: Int) -> Int {
            guard let v = str(s, k), !v.isEmpty else { return def }
            return ThemeFile.atoi(v)
        }

        /// LoadColorOneANSI: "#RRGGBB" か "R, G, B"
        func color(_ s: String, _ k: String, _ def: NSColor) -> NSColor {
            guard let v = str(s, k), !v.isEmpty else { return def }
            if v.hasPrefix("#") {
                let hex = v.dropFirst().prefix { $0.isHexDigit }
                if !hex.isEmpty, let n = UInt32(hex.prefix(8), radix: 16) {
                    return TermSettings.rgb(Int((n >> 16) & 0xFF), Int((n >> 8) & 0xFF), Int(n & 0xFF))
                }
            }
            let n = ThemeFile.scanInts(v, max: 3)
            return n.count == 3 ? TermSettings.rgb(n[0], n[1], n[2]) : def
        }

        /// BGGetStrIndex: キーがなければ既定、あっても一覧になければ 0 番目
        func index(_ s: String, _ k: String, _ def: Int, _ list: [String]) -> Int {
            guard let v = str(s, k) else { return def }
            return list.firstIndex { $0.caseInsensitiveCompare(v) == .orderedSame } ?? 0
        }
        func onOff(_ s: String, _ k: String, _ def: Bool) -> Bool { index(s, k, def ? 1 : 0, ["Off", "On"]) == 1 }
        func type(_ s: String, _ k: String, _ def: BGType) -> BGType {
            BGType(rawValue: index(s, k, def.rawValue, ["color", "picture", "wallpaper"])) ?? .color
        }
        /// BGGetPattern: 空や知らない値なら既定値
        func pattern(_ s: String, _ k: String, _ def: BGPattern) -> BGPattern {
            guard let v = str(s, k), !v.isEmpty else { return def }
            return BGPattern.allCases.first { $0.rawValue.caseInsensitiveCompare(v) == .orderedSame } ?? def
        }
    }

    /// ThemeLoadBG: 古い [BG] (BG*Enable の既定は 1) のあとに [BG Theme]
    private static func loadBG(_ r: Reader, _ bg: inout BGImageSpec) {
        if r.ini.hasSection(bgSectionOld) {
            bg.dest.enable = true; bg.src1.enable = true; bg.src2.enable = true
            loadBGSection(bgSectionOld, r, &bg)
        }
        loadBGSection(bgSectionNew, r, &bg)
    }

    /// ThemeLoadBGSection
    private static func loadBGSection(_ s: String, _ r: Reader, _ bg: inout BGImageSpec) {
        // Dest
        bg.dest.enable = r.int(s, "BGDestEnable", bg.dest.enable ? 1 : 0) != 0
        bg.dest.type = r.type(s, "BGDestType", bg.dest.type)
        bg.dest.pattern = r.pattern(s, "BGPicturePattern", bg.dest.pattern)
        bg.dest.pattern = r.pattern(s, "BGDestPattern", bg.dest.pattern)
        bg.dest.antiAlias = r.onOff(s, "BGDestAntiAlias", bg.dest.antiAlias)
        bg.dest.alpha = r.int(s, "BGDestAlpha", bg.dest.alpha)
        bg.dest.color = r.color(s, "BGPictureBaseColor", bg.dest.color)
        bg.dest.color = r.color(s, "BGDestColor", bg.dest.color)
        var file = r.str(s, "BGPictureFile") ?? bg.dest.file
        file = r.str(s, "BGDestFile") ?? file
        bg.dest.file = randomFile(file, base: r.dir) ?? ""
        // Src1
        bg.src1.enable = r.int(s, "BGSrc1Enable", bg.src1.enable ? 1 : 0) != 0
        bg.src1.type = r.type(s, "BGSrc1Type", bg.src1.type)
        bg.src1.pattern = r.pattern(s, "BGSrc1Pattern", bg.src1.pattern)
        bg.src1.antiAlias = r.onOff(s, "BGSrc1AntiAlias", bg.src1.antiAlias)
        bg.src1.alpha = 255 - r.int(s, "BGPictureTone", 255 - bg.src1.alpha)
        bg.src1.alpha = r.int(s, "BGSrc1Alpha", bg.src1.alpha)
        bg.src1.color = r.color(s, "BGSrc1Color", bg.src1.color)
        bg.src1.file = randomFile(r.str(s, "BGSrc1File") ?? bg.src1.file, base: r.dir) ?? ""
        // Src2
        bg.src2.enable = r.int(s, "BGSrc2Enable", bg.src2.enable ? 1 : 0) != 0
        bg.src2.type = r.type(s, "BGSrc2Type", bg.src2.type)
        bg.src2.pattern = r.pattern(s, "BGSrc2Pattern", bg.src2.pattern)
        bg.src2.antiAlias = r.onOff(s, "BGSrc2AntiAlias", bg.src2.antiAlias)
        bg.src2.alpha = 255 - r.int(s, "BGFadeTone", 255 - bg.src2.alpha)
        bg.src2.alpha = r.int(s, "BGSrc2Alpha", bg.src2.alpha)
        bg.src2.color = r.color(s, "BGFadeColor", bg.src2.color)
        bg.src2.color = r.color(s, "BGSrc2Color", bg.src2.color)
        bg.src2.file = randomFile(r.str(s, "BGSrc2File") ?? bg.src2.file, base: r.dir) ?? ""
        // その他
        bg.reverseTextAlpha = r.int(s, "BGReverseTextTone", bg.reverseTextAlpha) & 0xFF
        bg.reverseTextAlpha = r.int(s, "BGReverseTextAlpha", bg.reverseTextAlpha) & 0xFF
        bg.textBackAlpha = r.int(s, "BGTextBackAlpha", bg.textBackAlpha) & 0xFF
        bg.backAlpha = r.int(s, "BGBackAlpha", bg.backAlpha) & 0xFF
    }

    /// ThemeLoadColor: プラグイン版 → 古い [BG] → 新しい書き方 の順に上書き
    private static func loadColor(_ r: Reader, _ c: inout ThemeColors) {
        loadColorPlugin(r, &c)
        loadColorOld(r, &c)
        loadColorDraft(r, &c)
    }

    private static let attrKeys: [(String, WritableKeyPath<ThemeColors, ThemeColorSetting>)] = [
        ("VTColor", \.vt), ("BoldColor", \.bold), ("BlinkColor", \.blink),
        ("ReverseColor", \.reverse), ("URLColor", \.url), ("VTUnderlineColor", \.underline),
    ]

    /// LoadColorPlugin (カラーテーマプラグイン版: GetNthNum で読む)
    private static func loadColorPlugin(_ r: Reader, _ c: inout ThemeColors) {
        let s = colorSection
        c.name = r.str(s, "Theme") ?? ""
        for (k, kp) in attrKeys {
            let v = r.str(s, k) ?? "0"
            c[keyPath: kp].change = nthNum(v, 1) != 0
            c[keyPath: kp].enable = nthNum(v, 2) != 0
            if c[keyPath: kp].change && c[keyPath: kp].enable {
                c[keyPath: kp].fg = TermSettings.rgb(nthNum(v, 3), nthNum(v, 4), nthNum(v, 5))
                c[keyPath: kp].bg = TermSettings.rgb(nthNum(v, 6), nthNum(v, 7), nthNum(v, 8))
            }
        }
        // ReadANSIColorSetting
        let v = r.str(s, "ANSIColor") ?? "0"
        c.ansiChange = nthNum(v, 1) != 0
        for i in 0..<16 {
            c.ansi[i] = TermSettings.rgb(nthNum(v, i * 3 + 3), nthNum(v, i * 3 + 4), nthNum(v, i * 3 + 5))
        }
    }

    /// ThemeLoadColorOld (古い [BG] セクションの VTFore / Red ...)
    private static func loadColorOld(_ r: Reader, _ c: inout ThemeColors) {
        let s = bgSectionOld
        // IdBack=0 IdRed=1 ... IdFore=7 (Dark* は +8)
        let names = ["Back", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "Fore"]
        c.ansiChange = true
        for (i, n) in names.enumerated() {
            c.ansi[i] = r.color(s, n, c.ansi[i])
        }
        for (i, n) in names.enumerated() {
            c.ansi[i + 8] = r.color(s, "Dark" + n, c.ansi[i + 8])
        }
        func attr(_ kp: WritableKeyPath<ThemeColors, ThemeColorSetting>, _ fore: String, _ back: String) {
            c[keyPath: kp].fg = r.color(s, fore, c[keyPath: kp].fg)
            c[keyPath: kp].bg = r.color(s, back, c[keyPath: kp].bg)
            c[keyPath: kp].change = true
            c[keyPath: kp].enable = true
        }
        attr(\.vt, "VTFore", "VTBack")
        attr(\.blink, "VTBlinkFore", "VTBlinkBack")
        attr(\.bold, "VTBoldFore", "VTBoldBack")
        attr(\.underline, "VTUnderlineFore", "VTUnderlineBack")
        attr(\.reverse, "VTReverseFore", "VTReverseBack")
        attr(\.url, "URLFore", "URLBack")
    }

    /// ThemeLoadColorDraft (新しい書き方。ThemeSaveColor が書く形)
    private static func loadColorDraft(_ r: Reader, _ c: inout ThemeColors) {
        let s = colorSection
        c.name = r.str(s, "Theme") ?? ""
        for (k, kp) in attrKeys {
            guard let v = r.str(s, k), !v.isEmpty else { continue }
            loadColorAttr(v, &c[keyPath: kp])
        }
        c.ansiChange = r.int(s, "ANSIColor", 1) != 0
        // ANSI256 色のときの先頭 16 色 (ansi_list)
        let list: [(Int, String)] = [
            (15, "Fore"), (0, "Back"), (9, "Red"), (10, "Green"), (11, "Yellow"), (12, "Blue"), (13, "Magenta"), (14, "Cyan"),
            (7, "DarkFore"), (8, "DarkBack"), (1, "DarkRed"), (2, "DarkGreen"), (3, "DarkYellow"), (4, "DarkBlue"),
            (5, "DarkMagenta"), (6, "DarkCyan"),
        ]
        for (i, k) in list { c.ansi[i] = r.color(s, k, c.ansi[i]) }
    }

    /// LoadColorAttr: "c, e, #RRGGBB, #RRGGBB" / "c, e, r,g,b, r,g,b" / "c, e" / "c"
    private static func loadColorAttr(_ v: String, _ a: inout ThemeColorSetting) {
        let parts = v.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        func leadInt(_ s: String) -> Int? {
            let t = s.prefix { $0.isNumber || $0 == "-" || $0 == "+" }
            return t.isEmpty ? nil : Int(t)
        }
        func hex(_ s: String) -> UInt32? {
            guard s.hasPrefix("#") else { return nil }
            let h = s.dropFirst().prefix { $0.isHexDigit }.prefix(6)
            return h.isEmpty ? nil : UInt32(h, radix: 16)
        }
        guard parts.count >= 1, let change = leadInt(parts[0]) else { return }
        if parts.count >= 4, let enable = leadInt(parts[1]), let f = hex(parts[2]), let b = hex(parts[3]) {
            a.change = change != 0; a.enable = enable != 0
            a.fg = TermSettings.rgb(Int(f >> 16 & 0xFF), Int(f >> 8 & 0xFF), Int(f & 0xFF))
            a.bg = TermSettings.rgb(Int(b >> 16 & 0xFF), Int(b >> 8 & 0xFF), Int(b & 0xFF))
            return
        }
        let n = scanInts(v, max: 8)
        if n.count == 8 {
            a.change = n[0] != 0; a.enable = n[1] != 0
            a.fg = TermSettings.rgb(n[2], n[3], n[4]); a.bg = TermSettings.rgb(n[5], n[6], n[7])
            return
        }
        if n.count >= 2 {
            a.change = n[0] != 0
            a.enable = false   // 色が読めなかったので文字属性の独自色は無効
            return
        }
        a.change = false       // 色は変えない
    }

    // MARK: 数の読み方

    /// atoi (先頭の空白・符号・数字)
    static func atoi(_ s: String) -> Int {
        let t = s.drop { $0 == " " || $0 == "\t" }
        var digits = ""
        for (i, ch) in t.enumerated() {
            if ch.isASCII && ch.isNumber { digits.append(ch) }
            else if i == 0 && (ch == "-" || ch == "+") { digits.append(ch) }
            else { break }
        }
        return Int(digits) ?? 0
    }

    /// swscanf("%d , %d , ...") と同じ: 先頭から "," で区切られた整数を読めるだけ読む
    static func scanInts(_ s: String, max: Int) -> [Int] {
        var out: [Int] = []
        for (i, p) in s.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
            if out.count >= max { break }
            let t = p.trimmingCharacters(in: .whitespaces)
            let num = t.prefix { $0.isASCII && ($0.isNumber || $0 == "-" || $0 == "+") }
            guard !num.isEmpty, let v = Int(num) else { break }
            out.append(v)
            // 数字のあとに "," 以外があれば (";" コメントなど) そこで終わり
            if num.count != t.count { break }
            _ = i
        }
        return out
    }

    /// GetNthNum: n 番目 (1 から) の "," 区切りの数 (なければ 0)
    static func nthNum(_ s: String, _ n: Int) -> Int {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard n >= 1 && n <= parts.count else { return 0 }
        return atoi(String(parts[n - 1]))
    }

    // MARK: ファイル

    /// RandomFileW: ワイルドカード (* ?) があればその中からひとつ選ぶ。base からの相対パスも可。
    /// Windows の "\" は "/" に、%VAR% は環境変数に直す。見つからなければ nil
    static func randomFile(_ spec: String, base: String) -> String? {
        var p = spec.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        p = p.replacingOccurrences(of: "\\", with: "/")
        // %HOME% など
        if p.contains("%") {
            let env = ProcessInfo.processInfo.environment
            p = p.replacingOccurrences(of: "%([A-Za-z0-9_]+)%", with: "\u{0}$1\u{0}", options: .regularExpression)
            let parts = p.components(separatedBy: "\u{0}")
            p = parts.enumerated().map { $0.offset % 2 == 1 ? (env[$0.element] ?? "%\($0.element)%") : $0.element }.joined()
        }
        p = (p as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = (base as NSString).appendingPathComponent(p) }
        p = (p as NSString).standardizingPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: p, isDirectory: &isDir) { return isDir.boolValue ? nil : p }
        let dir = (p as NSString).deletingLastPathComponent
        let mask = (p as NSString).lastPathComponent
        guard mask.contains("*") || mask.contains("?"),
              let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let hits = names.filter { n in
            guard fnmatch(mask, n, FNM_CASEFOLD) == 0 else { return false }
            var d: ObjCBool = false
            return fm.fileExists(atPath: (dir as NSString).appendingPathComponent(n), isDirectory: &d) && !d.boolValue
        }.sorted()
        guard let pick = hits.randomElement() else { return nil }
        return (dir as NSString).appendingPathComponent(pick)
    }

    /// Tera Term 同梱のテーマのフォルダ (アプリの Contents/Resources/theme。開発中は元のソースの installer/release/theme)
    static var bundledDirectory: String? {
        if let r = Bundle.main.resourcePath {
            let p = (r as NSString).appendingPathComponent("theme")
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // macos/Sources/TeraMac/ → teraterm_macos/
            .appendingPathComponent("installer/release/theme").path
        return FileManager.default.fileExists(atPath: src) ? src : nil
    }

    /// 自分のテーマのフォルダ (HomeDir\theme にあたる: ~/Library/Application Support/Tera Term Mac/theme)
    static var userDirectory: String { (AppPaths.setupDirectory as NSString).appendingPathComponent("theme") }

    /// テーマを探すフォルダ (自分のフォルダに .ini があればそこ、なければ同梱のもの)
    static var themeDirectory: String? {
        let u = userDirectory
        if let n = try? FileManager.default.contentsOfDirectory(atPath: u), n.contains(where: { $0.lowercased().hasSuffix(".ini") }) { return u }
        return bundledDirectory
    }

    /// ランダムテーマ: テーマのフォルダの *.ini からひとつ (vtdisp.c BGLoadThemeFile の 2)
    static func randomTheme() -> String? {
        guard let d = themeDirectory else { return nil }
        return randomFile((d as NSString).appendingPathComponent("*.ini"), base: d)
    }

    /// 同梱のテーマの一覧 (フォルダの *.ini と color/*.ini)
    static func bundledThemes() -> [String] {
        guard let d = bundledDirectory else { return [] }
        var out: [String] = []
        for sub in ["", "color"] {
            let dir = (d as NSString).appendingPathComponent(sub)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            out += names.filter { $0.lowercased().hasSuffix(".ini") }.sorted().map { (dir as NSString).appendingPathComponent($0) }
        }
        return out
    }

    /// BGThemeFile の値 → 絶対パス (ResolveAbsolutePath(HomeDir) と同じ。無ければ同梱のフォルダの親からも探す)
    static func resolve(_ file: String) -> String? {
        var f = file.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        guard !f.isEmpty else { return nil }
        f = (f as NSString).expandingTildeInPath
        if f.hasPrefix("/") { return FileManager.default.fileExists(atPath: f) ? f : nil }
        var bases = [AppPaths.setupDirectory]
        if let b = bundledDirectory { bases.append((b as NSString).deletingLastPathComponent) }
        for b in bases {
            let p = ((b as NSString).appendingPathComponent(f) as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// 絶対パス → BGThemeFile に書く値 (同梱のテーマなら "theme/..." の相対パスにしてアプリの場所が変わっても読めるようにする)
    static func storedName(for path: String) -> String {
        if let b = bundledDirectory {
            let parent = (b as NSString).deletingLastPathComponent + "/"
            if path.hasPrefix(parent) { return String(path.dropFirst(parent.count)) }
        }
        return path
    }

    /// 起動時 (新しいウインドウ) のテーマ (vtdisp.c BGLoadThemeFile)。テーマを使わないときは nil
    static func startupTheme(_ t: ThemeSettings = .load(), base: TermSettings) -> ThemeData? {
        switch t.bgEnable {
        case 1:
            guard let p = resolve(t.themeFile) else { return nil }
            return load(p, base: base)
        case 2:
            return load(randomTheme(), base: base)
        default:
            return nil
        }
    }
}

// MARK: - 設定 ([BG] BGEnable / BGThemeFile / BGFastSizeMove)

struct ThemeSettings: Equatable {
    /// 0 = 使用しない, 1 = 固定テーマ (テーマファイル指定), 2 = ランダムテーマ
    var bgEnable = 0
    var themeFile = ""
    /// ウィンドウ移動/リサイズ時テーマを一時的に disable する
    var fastSizeMove = true

    private static let d = UserDefaults.standard
    static func load() -> ThemeSettings {
        var t = ThemeSettings()
        if d.object(forKey: "BGEnable") != nil { t.bgEnable = max(0, min(2, d.integer(forKey: "BGEnable"))) }
        t.themeFile = d.string(forKey: "BGThemeFile") ?? ""
        if d.object(forKey: "BGFastSizeMove") != nil { t.fastSizeMove = d.bool(forKey: "BGFastSizeMove") }
        return t
    }
    func save() {
        Self.d.set(bgEnable, forKey: "BGEnable")
        Self.d.set(themeFile, forKey: "BGThemeFile")
        Self.d.set(fastSizeMove, forKey: "BGFastSizeMove")
    }

    /// テーマを当てる前の色 (「使用しない」に戻したときに戻す)。TERATERM.INI の色のキーと同じ書き方
    static var colorBackup: [String: String]? {
        get { d.dictionary(forKey: "TeraMacThemeColorBackup") as? [String: String] }
        set { if let v = newValue { d.set(v, forKey: "TeraMacThemeColorBackup") } else { d.removeObject(forKey: "TeraMacThemeColorBackup") } }
    }
    static func backup(_ s: TermSettings) -> [String: String] {
        var r = ["VTColor": ColorPair(fg: s.fg, bg: s.bg).iniString]
        for (k, kp) in TermSettings.colorPairFields { r[k] = s[keyPath: kp].iniString }
        if let a = s.ansi16 { r["ANSIColor"] = a.map(TermSettings.rgbString).joined(separator: ",") }
        return r
    }
    static func restore(_ b: [String: String], to s: inout TermSettings) {
        if let v = b["VTColor"], let p = ColorPair(iniString: v) { s.fg = p.fg; s.bg = p.bg }
        for (k, kp) in TermSettings.colorPairFields { if let v = b[k], let p = ColorPair(iniString: v) { s[keyPath: kp] = p } }
        if let v = b["ANSIColor"] {
            let n = v.split(separator: ",").compactMap { Int($0) }
            s.ansi16 = n.count == 48 ? (0..<16).map { TermSettings.rgb(n[$0 * 3], n[$0 * 3 + 1], n[$0 * 3 + 2]) } : nil
        } else { s.ansi16 = nil }
    }
}

// MARK: - いまのテーマ (ThemeEnable / ThemeIsEnabled と背景)

/// 端末の画面が背景を描くときに見るところ。変わると didChange を送る
final class ThemeRuntime {
    static let shared = ThemeRuntime()
    static let didChange = Notification.Name("TeraMacThemeDidChange")

    /// ThemeIsEnabled() (設定のテーマタブの Enable。保存はしない)
    var enabled: Bool { didSet { if enabled != oldValue { post() } } }
    /// いまのテーマ (nil = テーマ無し)
    private(set) var current: ThemeData?

    private init() { enabled = ThemeSettings.load().bgEnable != 0 }

    /// 描く背景 (テーマが無効・背景が無いときは nil)
    var background: BGImageSpec? {
        guard enabled, let bg = current?.background, bg.isEnabled else { return nil }
        return bg
    }

    func set(_ t: ThemeData?) {
        current = t
        post()
    }

    private func post() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
