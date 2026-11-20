import AppKit
import Carbon.HIToolbox
import Security
import TeraCore

// TeraTerm Menu (ttpmenu) の Mac 版。
// Windows のタスクトレイの代わりにメニューバーに常駐し、登録した接続先をワンクリックで開く。

// MARK: - 登録項目

struct MenuEntry: Codable, Equatable {
    enum Mode: String, Codable { case login, macro, direct }   // 自動ログイン / マクロファイル指定 / 起動のみ

    var id = UUID().uuidString
    var name = ""
    var host = ""
    var mode: Mode = .login
    var useUser = true
    var user = ""
    var usePassword = false
    var useSSH = true
    var keyFile = ""
    var macroFile = ""
    var startup = false
    // 詳細設定
    var logFile = ""
    var loginPrompt = "login:"
    var passwordPrompt = "Password:"
    var option = ""

    /// オプション欄の /KT= /KR= から文字コードを決める
    var encoding: TermEncoding? {
        for w in option.split(separator: " ") {
            let l = w.lowercased()
            guard l.hasPrefix("/kr=") || l.hasPrefix("/kt=") else { continue }
            let v = l.dropFirst(4)
            if v.hasPrefix("utf8") || v.hasPrefix("utf-8") { return .utf8 }
            if v.hasPrefix("sjis") || v.hasPrefix("shift") { return .sjis }
            if v.hasPrefix("euc") { return .eucjp }
        }
        return nil
    }

    /// オプション欄の /passwd= (Tera Term のコマンドライン互換)
    var optionPassword: String? {
        for w in option.split(separator: " ") where w.lowercased().hasPrefix("/passwd=") {
            return String(w.dropFirst(8))
        }
        return nil
    }

    /// 接続先。ホスト名が空でオプションにも /C= などが無ければ nil
    func spec(withUser: Bool) -> ConnectionSpec? {
        var parts: [String] = []
        let h = host.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty { parts.append(h) }
        parts.append(useSSH ? "/ssh" : "/telnet")
        if useSSH && withUser && useUser && !user.isEmpty { parts.append("/user=\(user)") }
        if useSSH && !keyFile.isEmpty { parts.append("/keyfile=\(keyFile)") }
        for w in option.split(separator: " ") {
            let l = w.lowercased()
            if l.hasPrefix("/kt=") || l.hasPrefix("/kr=") || l.hasPrefix("/passwd=") || l.hasPrefix("/auth=") { continue }
            parts.append(String(w))
        }
        return ConnectionSpec.parse(parts.joined(separator: " "))
    }

    var symbolName: String {
        switch mode {
        case .macro: return "doc.text"
        case .direct: return "terminal"
        case .login:
            if let s = spec(withUser: false), case .serial = s { return "cable.connector" }
            return useSSH ? "lock.shield" : "network"
        }
    }
}

// MARK: - 保存 (項目は UserDefaults、パスワードはキーチェーン。Windows 版の LockBox の代わり)

enum Keychain {
    private static let service = "net.satoru.teramac.menu"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        delete(account)
        guard !value.isEmpty else { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
            kSecAttrLabel as String: "Tera Term Mac メニュー",
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

final class MenuStore {
    static let shared = MenuStore()
    static let changed = Notification.Name("TeraMenuChanged")
    private let d = UserDefaults.standard

    var entries: [MenuEntry] {
        get {
            guard let data = d.data(forKey: "menuEntries"),
                  let e = try? JSONDecoder().decode([MenuEntry].self, from: data) else { return [] }
            return e
        }
        set {
            d.set(try? JSONEncoder().encode(newValue), forKey: "menuEntries")
            NotificationCenter.default.post(name: MenuStore.changed, object: nil)
        }
    }

    var largeIcon: Bool {
        get { d.bool(forKey: "menuLargeIcon") }
        set { d.set(newValue, forKey: "menuLargeIcon"); NotificationCenter.default.post(name: MenuStore.changed, object: nil) }
    }
    var leftClickList: Bool {
        get { d.object(forKey: "menuLeftClick") == nil ? true : d.bool(forKey: "menuLeftClick") }
        set { d.set(newValue, forKey: "menuLeftClick") }
    }
    var hotkey: Bool {
        get { d.object(forKey: "menuHotkey") == nil ? true : d.bool(forKey: "menuHotkey") }
        set { d.set(newValue, forKey: "menuHotkey") }
    }
    var font: NSFont? {
        get {
            guard let n = d.string(forKey: "menuFontName") else { return nil }
            return NSFont(name: n, size: CGFloat(d.double(forKey: "menuFontSize")))
        }
        set {
            d.set(newValue?.fontName, forKey: "menuFontName")
            d.set(Double(newValue?.pointSize ?? 0), forKey: "menuFontSize")
            NotificationCenter.default.post(name: MenuStore.changed, object: nil)
        }
    }
}

// MARK: - 起動

enum TeraMenuLauncher {
    static func launch(_ e: MenuEntry) {
        var s = TermSettings.load()
        if let enc = e.encoding { s.encoding = enc }
        let c = SessionWindowController(settings: s)
        c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !e.logFile.isEmpty {
            let path = expandLogName((e.logFile as NSString).expandingTildeInPath)
            _ = c.startLog(path: path)
        }
        switch e.mode {
        case .direct:
            if let spec = e.spec(withUser: false) { c.connect(spec) } else { c.showConnectDialog() }
        case .login:
            guard let spec = e.spec(withUser: true) else { c.showConnectDialog(); return }
            let pw = e.usePassword ? (Keychain.get(e.id) ?? e.optionPassword ?? "") : (e.optionPassword ?? "")
            var steps: [SessionWindowController.LoginStep] = []
            if case .ssh = spec {
                if !pw.isEmpty { steps.append(.init(prompt: e.passwordPrompt.isEmpty ? "password:" : e.passwordPrompt, response: pw)) }
            } else {
                // Telnet: ユーザー名 → パスワードの順にプロンプトを待って送る
                if e.useUser && !e.user.isEmpty { steps.append(.init(prompt: e.loginPrompt.isEmpty ? "login:" : e.loginPrompt, response: e.user)) }
                if !pw.isEmpty { steps.append(.init(prompt: e.passwordPrompt.isEmpty ? "Password:" : e.passwordPrompt, response: pw)) }
            }
            c.connect(spec, loginSteps: steps)
        case .macro:
            if !e.host.trimmingCharacters(in: .whitespaces).isEmpty, let spec = e.spec(withUser: true) { c.connect(spec) }
            let path = (e.macroFile as NSString).expandingTildeInPath
            if path.isEmpty || !FileManager.default.fileExists(atPath: path) {
                let a = NSAlert()
                a.messageText = "マクロファイルが見つかりません"
                a.informativeText = path
                a.beginSheetModal(for: c.window!)
            } else {
                c.runMacro(url: URL(fileURLWithPath: path))
            }
        }
    }

    /// ログファイル名の %Y %m %d %H %M %S を日時に置き換える
    static func expandLogName(_ s: String) -> String {
        let f = DateFormatter()
        var out = s
        for (k, v) in [("%Y", "yyyy"), ("%m", "MM"), ("%d", "dd"), ("%H", "HH"), ("%M", "mm"), ("%S", "ss")] {
            f.dateFormat = v
            out = out.replacingOccurrences(of: k, with: f.string(from: Date()))
        }
        return out
    }

    /// 「起動時に実行」の付いた項目を開く。開いたら true
    static func runStartupEntries() -> Bool {
        let list = MenuStore.shared.entries.filter { $0.startup }
        list.forEach { launch($0) }
        return !list.isEmpty
    }
}

// MARK: - メニューバー常駐

final class TeraMenuController: NSObject, NSMenuDelegate {
    static let shared = TeraMenuController()
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var editor: MenuEditorWindowController?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            // 元の Tera Term のアイコン (アプリのアイコン) をメニューバーにも使う
            let img = (NSApp.applicationIconImage.copy() as? NSImage) ?? NSImage()
            img.size = NSSize(width: 18, height: 18)
            b.image = img
            b.toolTip = "Tera Term Mac メニュー"
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        updateHotkey()
    }

    // MARK: 一覧のメニュー

    func buildListMenu(into m: NSMenu) {
        let store = MenuStore.shared
        if let f = store.font { m.font = f }
        let entries = store.entries
        if entries.isEmpty {
            let i = NSMenuItem(title: "(登録がありません — リスト設定で追加)", action: #selector(showEditor(_:)), keyEquivalent: "")
            i.target = self
            m.addItem(i)
            return
        }
        let size: CGFloat = store.largeIcon ? 32 : 16
        for (n, e) in entries.enumerated() {
            let i = NSMenuItem(title: e.name.isEmpty ? e.host : e.name, action: #selector(launchItem(_:)), keyEquivalent: "")
            i.target = self
            i.tag = n
            i.representedObject = e.id
            if let img = NSImage(systemSymbolName: e.symbolName, accessibilityDescription: nil) {
                let sized = img.withSymbolConfiguration(.init(pointSize: size * 0.8, weight: .regular)) ?? img
                sized.size = NSSize(width: size, height: size)
                sized.isTemplate = true
                i.image = sized
            }
            i.toolTip = e.host
            m.addItem(i)
        }
    }

    var listMenu: NSMenu {
        let m = NSMenu()
        buildListMenu(into: m)
        return m
    }

    /// 右クリックのメニュー (Windows 版の設定メニューと同じ並び)
    var configMenu: NSMenu {
        let store = MenuStore.shared
        let m = NSMenu()
        func add(_ t: String, _ a: Selector, _ on: Bool? = nil) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: "")
            i.target = self
            if let on = on { i.state = on ? .on : .off }
            m.addItem(i)
        }
        add("リスト設定…", #selector(showEditor(_:)))
        add("大きいアイコンで表示", #selector(toggleLargeIcon(_:)), store.largeIcon)
        add("フォント指定…", #selector(chooseFont(_:)))
        add("左クリックで一覧を表示", #selector(toggleLeftClick(_:)), store.leftClickList)
        add("ホットキー (⌃⌥M) で一覧を表示", #selector(toggleHotkey(_:)), store.hotkey)
        add("Mac にログインしたら Tera Term Mac を起動", #selector(toggleLoginItem(_:)), LoginItem.enabled)
        add("バージョン情報", #selector(showVersion(_:)))
        m.addItem(.separator())
        add("実行 (新しい接続)…", #selector(execute(_:)))
        m.addItem(.separator())
        add("終了", #selector(quit(_:)))
        if !store.leftClickList {
            // 左クリックで設定メニューを出す場合も、一覧はサブメニューで選べるように
            let sub = NSMenuItem(title: "一覧", action: nil, keyEquivalent: "")
            sub.submenu = listMenu
            m.insertItem(sub, at: 0)
            m.insertItem(.separator(), at: 1)
        }
        return m
    }

    @objc private func statusClicked(_ sender: Any?) {
        let right = NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        let showList = right ? !MenuStore.shared.leftClickList : MenuStore.shared.leftClickList
        pop(showList ? listMenu : configMenu)
    }

    private func pop(_ m: NSMenu) {
        guard let item = statusItem else { return }
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func launchItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let e = MenuStore.shared.entries.first(where: { $0.id == id }) else { return }
        TeraMenuLauncher.launch(e)
    }

    /// アプリのメニューバーの「接続先」メニュー
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let edit = NSMenuItem(title: "リスト設定…", action: #selector(showEditor(_:)), keyEquivalent: "e")
        edit.target = self
        menu.addItem(edit)
        menu.addItem(.separator())
        buildListMenu(into: menu)
        menu.font = NSFont.menuFont(ofSize: 0)
    }

    // MARK: 設定メニューの操作

    @objc func showEditor(_ sender: Any?) {
        if editor == nil { editor = MenuEditorWindowController() }
        editor?.showWindow(nil)
        editor?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLargeIcon(_ sender: Any?) { MenuStore.shared.largeIcon.toggle() }
    @objc private func toggleLeftClick(_ sender: Any?) { MenuStore.shared.leftClickList.toggle() }
    @objc private func toggleHotkey(_ sender: Any?) {
        MenuStore.shared.hotkey.toggle()
        updateHotkey()
    }

    @objc private func toggleLoginItem(_ sender: Any?) {
        LoginItem.enabled.toggle()
    }

    @objc private func chooseFont(_ sender: Any?) {
        let fm = NSFontManager.shared
        fm.target = self
        fm.action = #selector(menuFontChanged(_:))
        fm.setSelectedFont(MenuStore.shared.font ?? NSFont.menuFont(ofSize: 0), isMultiple: false)
        NSApp.activate(ignoringOtherApps: true)
        fm.fontPanel(true)?.makeKeyAndOrderFront(nil)
    }

    @objc func menuFontChanged(_ sender: Any?) {
        MenuStore.shared.font = NSFontManager.shared.convert(MenuStore.shared.font ?? NSFont.menuFont(ofSize: 0))
    }

    @objc private func showVersion(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.delegate as? AppDelegate)?.showAbout(nil)
    }

    @objc private func execute(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.delegate as? AppDelegate)?.newWindow(nil)
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    // MARK: ホットキー (Ctrl+Option+M)。Carbon の仕組みならアクセシビリティの許可は要らない

    func updateHotkey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        guard MenuStore.shared.hotkey else { return }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { TeraMenuController.shared.hotkeyPressed() }
                return noErr
            }, 1, &spec, nil, &hotKeyHandler)
        }
        let id = EventHotKeyID(signature: OSType(0x5454_4D4E), id: 1)  // 'TTMN'
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func hotkeyPressed() {
        NSApp.activate(ignoringOtherApps: true)
        listMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - ログイン時に起動 (~/Library/LaunchAgents に置く。Windows のスタートアップに相当)

enum LoginItem {
    private static let label = "net.satoru.teramac.menu"
    private static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }

    static var enabled: Bool {
        get { FileManager.default.fileExists(atPath: plistPath) }
        set {
            if newValue {
                let plist: [String: Any] = [
                    "Label": label,
                    "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--menu"],
                    "RunAtLoad": true,
                ]
                try? FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                (plist as NSDictionary).write(toFile: plistPath, atomically: true)
            } else {
                try? FileManager.default.removeItem(atPath: plistPath)
            }
        }
    }
}

// MARK: - リスト設定ウインドウ

final class MenuEditorWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var entries = MenuStore.shared.entries
    private var current = MenuEntry()

    private let table = NSTableView()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let loginRadio = NSButton(radioButtonWithTitle: "自動ログイン", target: nil, action: nil)
    private let macroRadio = NSButton(radioButtonWithTitle: "マクロファイル指定", target: nil, action: nil)
    private let directRadio = NSButton(radioButtonWithTitle: "起動のみ", target: nil, action: nil)
    private let userCheck = NSButton(checkboxWithTitle: "ユーザー名", target: nil, action: nil)
    private let userField = NSTextField()
    private let passCheck = NSButton(checkboxWithTitle: "パスワード", target: nil, action: nil)
    private let passField = NSSecureTextField()
    private let sshCheck = NSButton(checkboxWithTitle: "SSH を使う", target: nil, action: nil)
    private let keyField = NSTextField()
    private let keyButton = NSButton(title: "…", target: nil, action: nil)
    private let macroField = NSTextField()
    private let macroButton = NSButton(title: "…", target: nil, action: nil)
    private let startupCheck = NSButton(checkboxWithTitle: "起動時に実行", target: nil, action: nil)

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "リスト設定 - Tera Term Mac メニュー"
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
        if entries.isEmpty { clearForm() } else { table.selectRowIndexes([0], byExtendingSelection: false); loadSelected() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        // 左: 登録一覧
        let col = NSTableColumn(identifier: .init("name"))
        col.title = "登録一覧"
        col.width = 220
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.target = self
        table.doubleAction = #selector(connectSelected(_:))
        table.registerForDraggedTypes([.string])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let up = NSButton(title: "▲", target: self, action: #selector(moveEntryUp(_:)))
        let down = NSButton(title: "▼", target: self, action: #selector(moveEntryDown(_:)))
        let newButton = NSButton(title: "新規", target: self, action: #selector(newEntry(_:)))
        let left = NSStackView(views: [scroll, hstack([newButton, up, down])])
        left.orientation = .vertical
        left.alignment = .leading

        // 中: 登録 (←) と削除
        let setButton = NSButton(title: "← 登録", target: self, action: #selector(register(_:)))
        setButton.toolTip = "右の内容を一覧に登録 (同じ名前なら上書き)"
        let delButton = NSButton(title: "削除", target: self, action: #selector(deleteEntry(_:)))
        let mid = NSStackView(views: [setButton, delButton])
        mid.orientation = .vertical

        // 右: 設定
        for f in [nameField, hostField, userField, passField, keyField, macroField] {
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        hostField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        hostField.placeholderString = "ホスト名 / ホスト名:ポート番号"
        userField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        passField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        passField.placeholderString = "キーチェーンに保存"
        keyField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        macroField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        for r in [loginRadio, macroRadio, directRadio, userCheck, passCheck, sshCheck] { r.target = self; r.action = #selector(formChanged(_:)) }
        keyButton.target = self; keyButton.action = #selector(chooseKey(_:))
        macroButton.target = self; macroButton.action = #selector(chooseMacro(_:))

        let keyLabel = NSTextField(labelWithString: "鍵ファイル")
        let pattern = NSStackView(views: [
            loginRadio,
            indent(hstack([userCheck, userField])),
            indent(hstack([passCheck, passField])),
            indent(sshCheck),
            indent(hstack([keyLabel, keyField, keyButton])),
            macroRadio,
            indent(hstack([macroField, macroButton])),
            directRadio,
        ])
        pattern.orientation = .vertical
        pattern.alignment = .leading
        pattern.spacing = 8
        let patternBox = NSBox()
        patternBox.title = "起動方法"
        patternBox.contentView = pad(pattern)

        let details = NSButton(title: "詳細…", target: self, action: #selector(showDetails(_:)))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "名前:"), nameField],
            [NSTextField(labelWithString: "ホスト名:"), hostField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let right = NSStackView(views: [grid, patternBox, hstack([details, startupCheck])])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
        let configBox = NSBox()
        configBox.title = "設定"
        configBox.contentView = pad(right)

        let top = NSStackView(views: [left, mid, configBox])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 12

        let connectButton = NSButton(title: "接続", target: self, action: #selector(connectForm(_:)))
        connectButton.keyEquivalent = "\r"
        let closeButton = NSButton(title: "閉じる", target: self, action: #selector(closeEditor(_:)))
        closeButton.keyEquivalent = "\u{1B}"
        let importButton = NSButton(title: "ttpmenu.ini 読み込み…", target: self, action: #selector(importTTMenu(_:)))
        let exportButton = NSButton(title: "ttpmenu.ini 書き出し…", target: self, action: #selector(exportTTMenu(_:)))
        importButton.toolTip = "Windows 版 TeraTerm Menu の ttpmenu.ini から接続先を読み込む"
        exportButton.toolTip = "Windows 版 TeraTerm Menu で読める ttpmenu.ini に書き出す"
        let bottom = hstack([importButton, exportButton, NSView(), closeButton, connectButton])

        let root = NSStackView(views: [top, bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        bottom.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottom.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(equalTo: configBox.heightAnchor, constant: -30),
        ])
        window?.contentView = container
        window?.setContentSize(container.fittingSize)
    }

    private func hstack(_ v: [NSView]) -> NSStackView {
        let s = NSStackView(views: v)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func indent(_ v: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return hstack([spacer, v])
    }

    private func pad(_ v: NSView) -> NSView {
        let c = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
            v.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -10),
            v.topAnchor.constraint(equalTo: c.topAnchor, constant: 8),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -10),
        ])
        return c
    }

    // MARK: フォーム ⇔ 項目

    private func fillForm(_ e: MenuEntry) {
        current = e
        nameField.stringValue = e.name
        hostField.stringValue = e.host
        loginRadio.state = e.mode == .login ? .on : .off
        macroRadio.state = e.mode == .macro ? .on : .off
        directRadio.state = e.mode == .direct ? .on : .off
        userCheck.state = e.useUser ? .on : .off
        userField.stringValue = e.user
        passCheck.state = e.usePassword ? .on : .off
        passField.stringValue = e.usePassword ? (Keychain.get(e.id) ?? "") : ""
        sshCheck.state = e.useSSH ? .on : .off
        keyField.stringValue = e.keyFile
        macroField.stringValue = e.macroFile
        startupCheck.state = e.startup ? .on : .off
        updateEnabled()
    }

    /// フォームの内容 (パスワードは別に返す)
    private func readForm() -> (MenuEntry, String) {
        var e = current
        e.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        e.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        e.mode = macroRadio.state == .on ? .macro : (directRadio.state == .on ? .direct : .login)
        e.useUser = userCheck.state == .on
        e.user = userField.stringValue
        e.usePassword = passCheck.state == .on
        e.useSSH = sshCheck.state == .on
        e.keyFile = keyField.stringValue
        e.macroFile = macroField.stringValue
        e.startup = startupCheck.state == .on
        if e.name.isEmpty { e.name = e.host }
        return (e, passField.stringValue)
    }

    private func clearForm() {
        var e = MenuEntry()
        e.user = NSUserName()
        fillForm(e)
        table.deselectAll(nil)
        window?.makeFirstResponder(nameField)
    }

    private func updateEnabled() {
        let login = loginRadio.state == .on
        userCheck.isEnabled = login
        userField.isEnabled = login && userCheck.state == .on
        passCheck.isEnabled = login
        passField.isEnabled = login && passCheck.state == .on
        sshCheck.isEnabled = login || directRadio.state == .on
        keyField.isEnabled = login && sshCheck.state == .on
        keyButton.isEnabled = keyField.isEnabled
        macroField.isEnabled = macroRadio.state == .on
        macroButton.isEnabled = macroField.isEnabled
    }

    @objc private func formChanged(_ sender: Any?) { updateEnabled() }

    private func loadSelected() {
        let r = table.selectedRow
        guard r >= 0 && r < entries.count else { return }
        fillForm(entries[r])
    }

    private func save() {
        MenuStore.shared.entries = entries
        table.reloadData()
    }

    // MARK: ボタン

    @objc private func register(_ sender: Any?) {
        let (e, pw) = readForm()
        guard !e.name.isEmpty else { NSSound.beep(); window?.makeFirstResponder(nameField); return }
        var entry = e
        // 同じ名前があれば上書き (Windows 版と同じ)
        if let i = entries.firstIndex(where: { $0.name == e.name }) {
            entry.id = entries[i].id
            entries[i] = entry
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else if let i = entries.firstIndex(where: { $0.id == e.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        if entry.usePassword { Keychain.set(pw, for: entry.id) } else { Keychain.delete(entry.id) }
        current = entry
        save()
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { table.selectRowIndexes([i], byExtendingSelection: false) }
    }

    @objc private func deleteEntry(_ sender: Any?) {
        let r = table.selectedRow
        guard r >= 0 && r < entries.count else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "「\(entries[r].name)」を削除しますか?"
        a.addButton(withTitle: "削除")
        a.addButton(withTitle: "やめる")
        a.beginSheetModal(for: window!) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            Keychain.delete(self.entries[r].id)
            self.entries.remove(at: r)
            self.save()
            if self.entries.isEmpty { self.clearForm() } else {
                self.table.selectRowIndexes([min(r, self.entries.count - 1)], byExtendingSelection: false)
                self.loadSelected()
            }
        }
    }

    @objc private func newEntry(_ sender: Any?) { clearForm() }

    @objc private func moveEntryUp(_ sender: Any?) { move(-1) }
    @objc private func moveEntryDown(_ sender: Any?) { move(1) }

    private func move(_ d: Int) {
        let r = table.selectedRow
        let t = r + d
        guard r >= 0, t >= 0, t < entries.count else { return }
        entries.swapAt(r, t)
        save()
        table.selectRowIndexes([t], byExtendingSelection: false)
    }

    @objc private func connectForm(_ sender: Any?) {
        var (e, pw) = readForm()
        if e.host.isEmpty && e.mode != .macro && e.spec(withUser: false) == nil { NSSound.beep(); return }
        // まだ登録していないパスワードも、この接続には使う
        if e.usePassword && !pw.isEmpty && Keychain.get(e.id) != pw {
            e.option += " /passwd=\(pw)"
            e.usePassword = false
        }
        TeraMenuLauncher.launch(e)
    }

    @objc private func connectSelected(_ sender: Any?) {
        let r = table.clickedRow
        guard r >= 0 && r < entries.count else { return }
        TeraMenuLauncher.launch(entries[r])
    }

    @objc private func closeEditor(_ sender: Any?) { window?.performClose(nil) }

    @objc private func importTTMenu(_ sender: Any?) {
        let p = NSOpenPanel()
        p.message = "Windows 版 TeraTerm Menu の ttpmenu.ini を選んでください"
        p.allowedFileTypes = ["ini", "INI"]
        p.allowsOtherFileTypes = true
        p.beginSheetModal(for: window!) { r in
            guard r == .OK, let url = p.url else { return }
            let res = TTMenuIni.importFile(url)
            self.entries = MenuStore.shared.entries
            self.table.reloadData()
            if !self.entries.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false); self.loadSelected() }
            let a = NSAlert()
            a.messageText = res.ok ? "\(url.lastPathComponent) を読み込みました" : "読み込めませんでした"
            a.informativeText = res.message
            a.beginSheetModal(for: self.window!)
        }
    }

    @objc private func exportTTMenu(_ sender: Any?) {
        guard !entries.isEmpty else { NSSound.beep(); return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "ttpmenu.ini"
        p.message = "Windows 版 TeraTerm Menu で読める形式で書き出します"
        let check = NSButton(checkboxWithTitle: "パスワードも書き出す (Windows 版と同じ簡易な暗号化なので取り扱い注意)", target: nil, action: nil)
        check.state = .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 32))
        check.frame = NSRect(x: 12, y: 6, width: 500, height: 20)
        box.addSubview(check)
        p.accessoryView = box
        p.beginSheetModal(for: window!) { r in
            guard r == .OK, let url = p.url else { return }
            let data = TTMenuIni.write(self.entries, includePasswords: check.state == .on)
            do {
                try data.write(to: url)
            } catch {
                let a = NSAlert(error: error)
                a.beginSheetModal(for: self.window!)
            }
        }
    }

    @objc private func chooseKey(_ sender: Any?) {
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        p.showsHiddenFiles = true
        p.beginSheetModal(for: window!) { r in if r == .OK, let u = p.url { self.keyField.stringValue = u.path } }
    }

    @objc private func chooseMacro(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["ttl"]
        p.allowsOtherFileTypes = true
        p.beginSheetModal(for: window!) { r in if r == .OK, let u = p.url { self.macroField.stringValue = u.path } }
    }

    @objc private func showDetails(_ sender: Any?) {
        let (e, _) = readForm()
        let dlg = MenuDetailsDialog(entry: e)
        dlg.begin(on: window!) { [weak self] updated in
            guard let self = self, let u = updated else { return }
            self.current.logFile = u.logFile
            self.current.loginPrompt = u.loginPrompt
            self.current.passwordPrompt = u.passwordPrompt
            self.current.option = u.option
            // 登録済みの項目なら、詳細はその場で保存する
            if let i = self.entries.firstIndex(where: { $0.id == self.current.id }) {
                self.entries[i].logFile = u.logFile
                self.entries[i].loginPrompt = u.loginPrompt
                self.entries[i].passwordPrompt = u.passwordPrompt
                self.entries[i].option = u.option
                self.save()
            }
        }
    }

    // MARK: 一覧

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let cell = NSTableCellView()
        let img = NSImageView(image: NSImage(systemSymbolName: e.symbolName, accessibilityDescription: nil) ?? NSImage())
        let text = NSTextField(labelWithString: e.name + (e.startup ? "  ⏻" : ""))
        let s = NSStackView(views: [img, text])
        s.spacing = 6
        s.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            s.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = e.host
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { loadSelected() }

    // ドラッグで並べ替え
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        op == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: .string), let from = Int(s) else { return false }
        let e = entries.remove(at: from)
        let to = from < row ? row - 1 : row
        entries.insert(e, at: to)
        save()
        tableView.selectRowIndexes([to], byExtendingSelection: false)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        NSFontManager.shared.fontPanel(false)?.orderOut(nil)
    }
}

// MARK: - 詳細設定

final class MenuDetailsDialog: SheetDialog {
    private var entry: MenuEntry
    private var completion: ((MenuEntry?) -> Void)?
    private let logField = NSTextField()
    private let userPrompt = NSTextField()
    private let passPrompt = NSTextField()
    private let optionField = NSTextField()

    init(entry: MenuEntry) {
        self.entry = entry
        super.init()
    }

    func begin(on w: NSWindow, completion: @escaping (MenuEntry?) -> Void) {
        self.completion = completion
        for f in [logField, userPrompt, passPrompt, optionField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        logField.placeholderString = "空ならログなし  例: ~/Documents/%Y%m%d.log"
        optionField.placeholderString = "例: /KR=SJIS /KT=SJIS  /BAUD=115200"
        let logButton = NSButton(title: "…", target: self, action: #selector(chooseLog))
        let defaults = NSButton(title: "標準に戻す", target: self, action: #selector(resetDefaults))
        fill(entry)
        func row(_ v: [NSView]) -> NSStackView { let s = NSStackView(views: v); s.spacing = 6; return s }
        let help = NSTextField(wrappingLabelWithString:
            "オプション: /KR= /KT= で文字コード (UTF8 / SJIS / EUC)、/BAUD= /C= でシリアル、/T=0 で生 TCP など、Tera Term のコマンドラインと同じ書き方です。")
        help.font = NSFont.systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 440
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "ログファイル:"), row([logField, logButton])],
            [NSTextField(labelWithString: "ユーザー名プロンプト:"), userPrompt],
            [NSTextField(labelWithString: "パスワードプロンプト:"), passPrompt],
            [NSTextField(labelWithString: "オプション:"), optionField],
            [NSGridCell.emptyContentView, help],
            [NSGridCell.emptyContentView, defaults],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        layout(grid)
        present(on: w)
    }

    private func fill(_ e: MenuEntry) {
        logField.stringValue = e.logFile
        userPrompt.stringValue = e.loginPrompt
        passPrompt.stringValue = e.passwordPrompt
        optionField.stringValue = e.option
    }

    @objc private func chooseLog() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "teramac_%Y%m%d_%H%M%S.log"
        if p.runModal() == .OK, let u = p.url { logField.stringValue = u.path }
    }

    @objc private func resetDefaults() {
        let d = MenuEntry()
        userPrompt.stringValue = d.loginPrompt
        passPrompt.stringValue = d.passwordPrompt
        logField.stringValue = ""
        optionField.stringValue = ""
    }

    override func ok() {
        entry.logFile = logField.stringValue
        entry.loginPrompt = userPrompt.stringValue
        entry.passwordPrompt = passPrompt.stringValue
        entry.option = optionField.stringValue
        close()
        completion?(entry)
    }

    override func cancel() {
        close()
        completion?(nil)
    }
}

// MARK: - Windows 版 TeraTerm Menu の ttpmenu.ini の読み書き

enum TTMenuIni {
    struct ImportResult {
        var entries: [MenuEntry] = []
        var passwords: [String: String] = [:]   // id → パスワード
        var notes: [String] = []
    }

    /// Windows 版の簡易暗号: 文字を逆順にして各バイトを 0xFF で XOR (同じ操作で元に戻る)
    static func flip(_ b: [UInt8]) -> [UInt8] { b.reversed().map { $0 ^ 0xFF } }

    static func decodePassword(_ hex: String) -> String? {
        let bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard !bytes.isEmpty else { return nil }
        let raw = flip(bytes)
        return String(bytes: raw, encoding: .shiftJIS) ?? String(bytes: raw, encoding: .utf8)
    }

    static func encodePassword(_ pw: String) -> String {
        let raw = [UInt8](pw.data(using: .shiftJIS) ?? Data(pw.utf8))
        return flip(raw).map { String(format: "%02X ", $0) }.joined()
    }

    /// 数値は 10 進 (ttpmenu) と 16 進 8 桁 (付属の変換スクリプト) の両方を受ける
    private static func num(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.count == 8, let v = Int(s, radix: 16) { return v }
        return Int(s) ?? Int(s, radix: 16)
    }

    static func read(_ ini: IniFile) -> ImportResult {
        var r = ImportResult()
        for name in ini.sectionNames where name.lowercased() != "ttermmenu" {
            func str(_ k: String) -> String { ini.string(name, k) ?? "" }
            func flag(_ k: String) -> Bool { (num(ini.string(name, k)) ?? 0) != 0 }
            guard ini.string(name, "HostName") != nil || ini.string(name, "Mode") != nil else { continue }
            var e = MenuEntry()
            e.name = name
            e.host = str("HostName")
            switch num(ini.string(name, "Mode")) ?? 0 {
            case 1: e.mode = .macro
            case 2: e.mode = .direct
            default: e.mode = .login
            }
            e.useUser = flag("UserFlag")
            e.user = str("UserName")
            e.usePassword = flag("PasswdFlag")
            e.useSSH = flag("TeraTerm Mode")
            e.keyFile = str("PrivateKeyFile")
            e.macroFile = str("MacroFile")
            e.startup = flag("Startup")
            e.logFile = str("Log")
            if !str("LoginPrompt").isEmpty { e.loginPrompt = str("LoginPrompt") }
            if !str("PasswdPrompt").isEmpty { e.passwordPrompt = str("PasswdPrompt") }
            e.option = str("Option")
            if e.usePassword {
                if flag("LockBoxFlag") {
                    e.usePassword = false
                    r.notes.append("「\(name)」のパスワードは LockBox で暗号化されているため読めません (リスト設定で入れ直してください)")
                } else if let pw = decodePassword(str("Password")), !pw.isEmpty {
                    r.passwords[e.id] = pw
                } else {
                    e.usePassword = false
                }
            }
            for (label, path) in [("鍵ファイル", e.keyFile), ("マクロ", e.macroFile), ("ログ", e.logFile)] where path.contains(":\\") {
                r.notes.append("「\(name)」の\(label)は Windows のパスです: \(path)")
            }
            r.entries.append(e)
        }
        return r
    }

    /// Windows 版と同じ書式 (UTF-16LE, BOM 付き, CRLF) で書き出す
    static func write(_ entries: [MenuEntry], includePasswords: Bool) -> Data {
        let store = MenuStore.shared
        var lines = ["[TTermMenu]",
                     "IconMode=\(store.largeIcon ? 1 : 0)",
                     "LeftButtonPopup=\(store.leftClickList ? 1 : 0)",
                     "Hotkey=\(store.hotkey ? 1 : 0)", ""]
        for e in entries {
            let pw = (includePasswords && e.usePassword) ? (Keychain.get(e.id) ?? "") : ""
            let name = e.name.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            lines += [
                "[\(name)]",
                "HostName=\(e.host)",
                "Mode=\(e.mode == .macro ? 1 : (e.mode == .direct ? 2 : 0))",
                "UserFlag=\(e.useUser ? 1 : 0)",
                "UserName=\(e.user)",
                "PasswdFlag=\(pw.isEmpty ? 0 : 1)",
                "LockBoxFlag=0",
                "Password=\(pw.isEmpty ? "" : encodePassword(pw))",
                "TeraTerm=",
                "INI_File=",
                "Option=\(e.option)",
                "LoginPrompt=\(e.loginPrompt)",
                "PasswdPrompt=\(e.passwordPrompt)",
                "MacroFile=\(e.macroFile)",
                "TeraTerm Mode=\(e.useSSH ? 1 : 0)",
                "Startup=\(e.startup ? 1 : 0)",
                "Log=\(e.logFile)",
                "PrivateKeyFile=\(e.keyFile)",
                "Challenge=0",
                "Pageant=0",
                "",
            ]
        }
        let text = lines.joined(separator: "\r\n")
        return Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
    }

    /// 読み込んで今の一覧にまとめる (同じ名前は上書き)。結果の説明を返す
    static func importFile(_ url: URL) -> (ok: Bool, message: String) {
        guard let data = try? Data(contentsOf: url), let ini = IniFile(data: data) else {
            return (false, "読み込めませんでした: \(url.path)")
        }
        let r = read(ini)
        guard !r.entries.isEmpty else { return (false, "接続先が見つかりませんでした。ttpmenu.ini ではないかもしれません。") }
        var list = MenuStore.shared.entries
        var added = 0, replaced = 0
        for var e in r.entries {
            let pw = r.passwords[e.id]
            if let i = list.firstIndex(where: { $0.name == e.name }) {
                e.id = list[i].id
                list[i] = e
                replaced += 1
            } else {
                list.append(e)
                added += 1
            }
            if let pw = pw { Keychain.set(pw, for: e.id) } else if !e.usePassword { Keychain.delete(e.id) }
        }
        MenuStore.shared.entries = list
        // 全体の設定
        let T = "TTermMenu"
        if let v = num(ini.string(T, "IconMode")) { MenuStore.shared.largeIcon = v != 0 }
        if let v = num(ini.string(T, "LeftButtonPopup")) { MenuStore.shared.leftClickList = v != 0 }
        if let v = num(ini.string(T, "Hotkey")) {
            MenuStore.shared.hotkey = v != 0
            TeraMenuController.shared.updateHotkey()
        }
        var msg = "追加 \(added) 件、上書き \(replaced) 件"
        if !r.passwords.isEmpty { msg += "\nパスワード \(r.passwords.count) 件はキーチェーンに保存しました" }
        if !r.notes.isEmpty { msg += "\n\n" + r.notes.map { "・" + $0 }.joined(separator: "\n") }
        return (true, msg)
    }
}
