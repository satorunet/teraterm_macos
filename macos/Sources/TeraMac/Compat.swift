import AppKit

// macOS 10.14 用の代わり。10.15 以降は今までどおり新しい API を使う (新しい OS では動きは変わらない)。

extension NSFont {
    /// monospacedSystemFont (10.15〜)。10.14 では Menlo (SF Mono が OS に入っていないため)
    static func monoSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if #available(macOS 10.15, *) { return monospacedSystemFont(ofSize: size, weight: weight) }
        let regular = NSFont(name: "Menlo", size: size) ?? userFixedPitchFont(ofSize: size) ?? systemFont(ofSize: size)
        return weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask) : regular
    }
}

extension NSColor {
    /// systemIndigo (10.15〜)。10.14 では同じくらいの色
    static var compatIndigo: NSColor {
        if #available(macOS 10.15, *) { return .systemIndigo }
        return NSColor(srgbRed: 0.35, green: 0.34, blue: 0.84, alpha: 1)
    }
}

extension NSWorkspace {
    /// ファイルをアプリで開く (args はアプリに渡す引数)。completion はエラーのときだけ呼ぶ
    func compatOpen(_ file: URL, withApplicationAt app: URL, arguments args: [String] = [],
                    onError: ((Error) -> Void)? = nil) {
        if #available(macOS 10.15, *) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = args
            open([file], withApplicationAt: app, configuration: cfg) { _, err in
                if let err = err { DispatchQueue.main.async { onError?(err) } }
            }
        } else {
            do { try open([file], withApplicationAt: app, options: [], configuration: [.arguments: args]) }
            catch { onError?(error) }
        }
    }
}

extension NSEvent {
    /// Shift だけを効かせた文字 (characters(byApplyingModifiers:) は 10.15〜)。
    /// 10.14 では charactersIgnoringModifiers (Shift だけは効く) で代わりにする
    var charactersWithShiftOnly: String? {
        if #available(macOS 10.15, *) { return characters(byApplyingModifiers: modifierFlags.intersection(.shift)) }
        return charactersIgnoringModifiers
    }
}
