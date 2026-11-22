import AppKit

/// 貼り付けの確認 (clipboarddlg.cpp IDD_CLIPBOARD_DIALOG)。
/// 中身を書き換えてから貼り付けられる。大きさは変えられて、次も同じ大きさで出る (PasteDialogSize)。
/// 出す位置は文字カーソルのところ (画面からはみ出さないようにずらす)
enum PasteConfirmDialog {
    private static let sizeKey = "pasteDialogSize"
    static let defaultSize = NSSize(width: 330, height: 220)

    /// OK なら (書き換えた) 文字、キャンセルなら nil
    static func run(text: String, over parent: NSWindow?, near point: NSPoint?) -> String? {
        let size = savedSize()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = "Tera Term: クリップボードの確認"
        panel.minSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: defaultSize)).size

        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.string = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        let ok = NSButton(title: "OK", target: nil, action: nil)
        ok.keyEquivalent = "\r"
        ok.keyEquivalentModifierMask = [.command]   // 改行は文字の編集に使うので OK は ⌘Return
        let cancel = NSButton(title: "キャンセル", target: nil, action: nil)
        cancel.keyEquivalent = "\u{1B}"
        let handler = Handler()
        ok.target = handler; ok.action = #selector(Handler.ok)
        cancel.target = handler; cancel.action = #selector(Handler.cancel)
        for b in [ok, cancel] { b.translatesAutoresizingMaskIntoConstraints = false }

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(ok)
        content.addSubview(cancel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -10),
            ok.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            ok.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: ok.leadingAnchor, constant: -8),
            cancel.bottomAnchor.constraint(equalTo: ok.bottomAnchor),
        ])
        panel.contentView = content
        panel.setContentSize(size)
        place(panel, near: point, parent: parent)
        panel.initialFirstResponder = tv

        let r = NSApp.runModal(for: panel)
        saveSize(panel.contentRect(forFrameRect: panel.frame).size)
        panel.orderOut(nil)
        return r == .OK ? tv.string : nil
    }

    private final class Handler: NSObject {
        @objc func ok() { NSApp.stopModal(withCode: .OK) }
        @objc func cancel() { NSApp.stopModal(withCode: .cancel) }
    }

    private static func place(_ panel: NSPanel, near point: NSPoint?, parent: NSWindow?) {
        guard let p = point else {
            if let w = parent {
                panel.setFrameOrigin(NSPoint(x: w.frame.midX - panel.frame.width / 2, y: w.frame.midY - panel.frame.height / 2))
            } else {
                panel.center()
            }
            return
        }
        var f = panel.frame
        f.origin = NSPoint(x: p.x, y: p.y - f.height)
        if let screen = (parent?.screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = min(max(f.origin.x, screen.minX), screen.maxX - f.width)
            f.origin.y = min(max(f.origin.y, screen.minY), screen.maxY - f.height)
        }
        panel.setFrame(f, display: false)
    }

    private static func savedSize() -> NSSize {
        guard let s = UserDefaults.standard.string(forKey: sizeKey) else { return defaultSize }
        let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == 2 else { return defaultSize }
        return NSSize(width: max(defaultSize.width, v[0]), height: max(defaultSize.height, v[1]))
    }

    private static func saveSize(_ s: NSSize) {
        UserDefaults.standard.set("\(Int(s.width)),\(Int(s.height))", forKey: sizeKey)
    }
}
