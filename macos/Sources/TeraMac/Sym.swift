import AppKit

/// SF Symbols (macOS 11 以降) のアイコン。macOS 10.15 では SF Symbols が使えないので、
/// 文字で描いた代わりの画像 (テンプレート画像なので色合わせはそのまま効く) か、
/// システム標準の画像を返す。代わりがないものは nil (メニューなどはアイコンなしで表示)。
enum Sym {
    /// - size: 省略時は SF Symbols の既定の大きさ (macOS 10.15 では 13pt 相当の文字)
    static func image(_ name: String, _ description: String? = nil,
                      size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSImage? {
        // TERAMAC_NO_SFSYMBOLS=1 で macOS 10.15 の見た目を確かめられる
        if #available(macOS 11.0, *), ProcessInfo.processInfo.environment["TERAMAC_NO_SFSYMBOLS"] == nil {
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: description) else { return nil }
            guard let size = size else { return img }
            return img.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? img
        }
        return fallback(name, description, size: size ?? 13, weight: weight)
    }

    /// macOS 10.15 用の代わりの文字
    private static let glyphs: [String: String] = [
        "xmark.circle.fill": "✕",
        "line.horizontal.3": "≡",
        "chevron.left": "‹",
        "chevron.right": "›",
        "chevron.down": "▾",
        "arrow.counterclockwise": "↺",
        "arrow.left.arrow.right": "⇄",
        "folder.badge.plus": "+",
        "plus": "+",
        "play": "▶\u{FE0E}",
        "pencil": "✎",
        "terminal": ">_",
        "doc.text": "≣",
    ]

    private static func fallback(_ name: String, _ description: String?, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        if name == "folder", let f = NSImage(named: NSImage.folderName)?.copy() as? NSImage {
            f.size = NSSize(width: size + 3, height: size + 3)
            f.accessibilityDescription = description
            return f
        }
        guard let g = glyphs[name] else { return nil }
        return glyphImage(g, size: name.hasPrefix("chevron.") && name != "chevron.down" ? size * 1.4 : size,
                          weight: weight, description: description)
    }

    /// 文字をテンプレート画像にする
    static func glyphImage(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, description: String? = nil) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let b = str.size()
        let img = NSImage(size: NSSize(width: ceil(b.width), height: ceil(b.height)), flipped: false) { r in
            str.draw(at: NSPoint(x: (r.width - b.width) / 2, y: (r.height - b.height) / 2))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = description
        return img
    }
}
