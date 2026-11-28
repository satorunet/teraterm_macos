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
    /// チャレンジレスポンス認証 (keyboard-interactive) を使う (ttpmenu.ini の Challenge=。ttpmenu 1.07)
    var challenge = false
    /// Pageant を使う (ttpmenu.ini の Pageant=。ttpmenu 1.08)。Mac では ssh-agent の公開鍵認証
    var pageant = false
    /// SSH エージェントのソケット (Mac だけ。空は既定: ~/.ssh/config か SSH_AUTH_SOCK)。Pageant を使うときだけ効く
    var agentSocket = ""
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
            // 本家の名前 (GetKanjiCodeFromStr。ISO8859-x / CPxxx なども) をまず見る
            if let e = TermEncoding.exactKanjiCodeStr(String(w.dropFirst(4))) { return e }
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

    /// 自動ログインの SSH の認証方法 (ttpmenu.cpp ConnectHost: Challenge → TTDUP_SSH_CHALLENGE、Pageant → TTDUP_SSH_PAGEANT)
    var sshAuth: String? {
        guard mode == .login && useSSH else { return nil }
        return challenge ? "challenge" : (pageant ? "pageant" : nil)
    }

    /// dquote_stringW (ttdup.cpp): ",空白,;,^A-^_ を含むときは "" で囲む (中の " は "")。ttpmenu 1.13
    static func dquote(_ s: String) -> String {
        let needs = s.unicodeScalars.contains { $0 == "\"" || $0 == " " || $0 == ";" || (0x01...0x1F).contains($0.value) }
        guard needs else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 接続のコマンドライン (Tera Term + TTSSH の書き方。ttdup.cpp ConnectArgs)
    func commandLine(withUser: Bool) -> String {
        var parts: [String] = []
        let h = host.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty { parts.append(h) }
        parts.append(useSSH ? "/ssh" : "/telnet")
        if withUser, let a = sshAuth { parts.append("/auth=\(a)") }   // /auth=challenge / /auth=pageant
        if withUser && sshAuth == "pageant" && !agentSocket.isEmpty { parts.append("/agentsock=" + MenuEntry.dquote(agentSocket)) }
        if useSSH && withUser && useUser && !user.isEmpty { parts.append("/user=" + MenuEntry.dquote(user)) }
        // チャレンジ・Pageant のときは鍵ファイルを使わない (ダイアログでも入れられない)
        if useSSH && !keyFile.isEmpty && !(withUser && sshAuth != nil) { parts.append("/keyfile=" + MenuEntry.dquote(keyFile)) }
        for w in option.split(separator: " ") {
            let l = w.lowercased()
            if l.hasPrefix("/kt=") || l.hasPrefix("/kr=") || l.hasPrefix("/passwd=") || l.hasPrefix("/auth=") { continue }
            parts.append(String(w))
        }
        return parts.joined(separator: " ")
    }

    /// 接続先。ホスト名が空でオプションにも /C= などが無ければ nil
    func spec(withUser: Bool) -> ConnectionSpec? {
        ConnectionSpec.parse(commandLine(withUser: withUser))
    }

    /// ssh に足す引数 (/auth= を Connection.sshArguments と同じく ssh のオプションにする)
    func sshArguments(withUser: Bool) -> [String] {
        ConnectionSpec.sshArguments(TTCommandLine.parse(commandLine(withUser: withUser)))
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

extension MenuEntry {
    /// 前の版で保存した項目 (challenge / pageant などがない) も読めるよう、ないキーは既定値にする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MenuEntry()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        useUser = try c.decodeIfPresent(Bool.self, forKey: .useUser) ?? d.useUser
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? d.user
        usePassword = try c.decodeIfPresent(Bool.self, forKey: .usePassword) ?? d.usePassword
        useSSH = try c.decodeIfPresent(Bool.self, forKey: .useSSH) ?? d.useSSH
        keyFile = try c.decodeIfPresent(String.self, forKey: .keyFile) ?? d.keyFile
        challenge = try c.decodeIfPresent(Bool.self, forKey: .challenge) ?? d.challenge
        pageant = try c.decodeIfPresent(Bool.self, forKey: .pageant) ?? d.pageant
        agentSocket = try c.decodeIfPresent(String.self, forKey: .agentSocket) ?? d.agentSocket
        macroFile = try c.decodeIfPresent(String.self, forKey: .macroFile) ?? d.macroFile
        startup = try c.decodeIfPresent(Bool.self, forKey: .startup) ?? d.startup
        logFile = try c.decodeIfPresent(String.self, forKey: .logFile) ?? d.logFile
        loginPrompt = try c.decodeIfPresent(String.self, forKey: .loginPrompt) ?? d.loginPrompt
        passwordPrompt = try c.decodeIfPresent(String.self, forKey: .passwordPrompt) ?? d.passwordPrompt
        option = try c.decodeIfPresent(String.self, forKey: .option) ?? d.option
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

/// 一覧のツリー (フォルダと接続先)。接続先そのものは MenuStore.entries にあり、ここでは id で指す
final class MenuNode: Codable {
    var id = UUID().uuidString
    /// フォルダ名 (フォルダのとき)
    var folder: String?
    /// 接続先の id (接続先のとき)
    var entryID: String?
    var children: [MenuNode] = []

    var isFolder: Bool { folder != nil }
    init(folder: String) { self.folder = folder }
    init(entryID: String) { self.entryID = entryID }

    /// 中にある接続先の id (並び順)
    var allEntryIDs: [String] {
        if let e = entryID { return [e] }
        return children.flatMap { $0.allEntryIDs }
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

    /// フォルダ分けしたツリー。登録だけあってツリーにない接続先は最上位の最後に足す
    var tree: [MenuNode] {
        get {
            let saved = d.data(forKey: "menuTree").flatMap { try? JSONDecoder().decode([MenuNode].self, from: $0) } ?? []
            return MenuStore.normalize(saved, entries: entries)
        }
        set {
            d.set(try? JSONEncoder().encode(newValue), forKey: "menuTree")
            NotificationCenter.default.post(name: MenuStore.changed, object: nil)
        }
    }

    /// ツリーと接続先の一覧を合わせる (消えた接続先は外し、重なりも外し、ないものは足す)
    static func normalize(_ nodes: [MenuNode], entries: [MenuEntry]) -> [MenuNode] {
        let ids = Set(entries.map { $0.id })
        var seen = Set<String>()
        func clean(_ list: [MenuNode]) -> [MenuNode] {
            list.compactMap { n in
                if let e = n.entryID {
                    guard ids.contains(e), !seen.contains(e) else { return nil }
                    seen.insert(e)
                    return n
                }
                n.children = clean(n.children)
                return n
            }
        }
        var r = clean(nodes)
        for e in entries where !seen.contains(e.id) { r.append(MenuNode(entryID: e.id)) }
        return r
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
                // Pageant (TTDUP_SSH_PAGEANT) はパスワードを渡さない
                if !pw.isEmpty && e.sshAuth != "pageant" { steps.append(.init(prompt: e.passwordPrompt.isEmpty ? "password:" : e.passwordPrompt, response: pw)) }
            } else {
                // Telnet: ユーザー名 → パスワードの順にプロンプトを待って送る
                if e.useUser && !e.user.isEmpty { steps.append(.init(prompt: e.loginPrompt.isEmpty ? "login:" : e.loginPrompt, response: e.user)) }
                if !pw.isEmpty { steps.append(.init(prompt: e.passwordPrompt.isEmpty ? "Password:" : e.passwordPrompt, response: pw)) }
            }
            c.connect(spec, loginSteps: steps, sshArgs: e.sshArguments(withUser: true))
        case .macro:
            if !e.host.trimmingCharacters(in: .whitespaces).isEmpty, let spec = e.spec(withUser: true) { c.connect(spec) }
            let path = (e.macroFile as NSString).expandingTildeInPath
            if path.isEmpty || !FileManager.default.fileExists(atPath: path) {
                let a = NSAlert()
                a.messageText = Lang.m("CONN_MACRO_NOT_FOUND", "マクロファイルが見つかりません")
                a.informativeText = path
                a.beginSheetModal(for: c.presentingWindow!)
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

    /// メニューバーにアイコンを出すか (設定 > 全般。既定は出す)
    static let statusItemKey = "TTMenuShowStatusItem"
    static var showsStatusItem: Bool {
        get { UserDefaults.standard.object(forKey: statusItemKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: statusItemKey)
            shared.applyStatusItemVisibility()
        }
    }
    /// 設定に合わせて、メニューバーのアイコンを出す / 消す (すぐに効く)
    func applyStatusItemVisibility() {
        if Self.showsStatusItem {
            if statusItem == nil { install() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func install() {
        // 設定でアイコンを消しているときは出さない (ホットキーは使える)
        guard Self.showsStatusItem else { updateHotkey(); return }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            // 元の Tera Term のアイコン (アプリのアイコン) をメニューバーにも使う
            let img = (NSApp.applicationIconImage.copy() as? NSImage) ?? NSImage()
            img.size = NSSize(width: 18, height: 18)
            b.image = img
            b.toolTip = Lang.m("CONN_TTMENU_NAME", "Tera Term Mac メニュー")
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
            let i = NSMenuItem(title: Lang.m("CONN_LIST_EMPTY", "(登録がありません — %sで追加)", Lang.t("TTMenu", "MENU_LISTCONFIG", "リスト設定")), action: #selector(showEditor(_:)), keyEquivalent: "")
            i.target = self
            m.addItem(i)
            return
        }
        let size: CGFloat = store.largeIcon ? 32 : 16
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func icon(_ name: String) -> NSImage? {
            guard let sized = Sym.image(name, nil, size: size * 0.8) else { return nil }
            sized.size = NSSize(width: size, height: size)
            return sized
        }
        // フォルダはサブメニューにする
        func add(_ nodes: [MenuNode], to menu: NSMenu) {
            for n in nodes {
                if let f = n.folder {
                    let i = NSMenuItem(title: f, action: nil, keyEquivalent: "")
                    i.image = icon("folder")
                    let sub = NSMenu()
                    if let font = store.font { sub.font = font }
                    if n.children.isEmpty {
                        let empty = NSMenuItem(title: Lang.m("CONN_FOLDER_EMPTY", "(空)"), action: nil, keyEquivalent: "")
                        empty.isEnabled = false
                        sub.addItem(empty)
                    } else {
                        add(n.children, to: sub)
                    }
                    i.submenu = sub
                    menu.addItem(i)
                } else if let id = n.entryID, let e = byID[id] {
                    let i = NSMenuItem(title: e.name.isEmpty ? e.host : e.name, action: #selector(launchItem(_:)), keyEquivalent: "")
                    i.target = self
                    i.representedObject = e.id
                    i.image = icon(e.symbolName)
                    i.toolTip = e.host
                    menu.addItem(i)
                }
            }
        }
        add(store.tree, to: m)
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
        add(Lang.t("TTMenu", "MENU_LISTCONFIG", "リスト設定") + "…", #selector(showEditor(_:)))
        add(Lang.t("TTMenu", "MENU_ICON", "大きいアイコンで表示"), #selector(toggleLargeIcon(_:)), store.largeIcon)
        add(Lang.t("TTMenu", "MENU_FONT", "フォント指定") + "…", #selector(chooseFont(_:)))
        add(Lang.t("TTMenu", "MENU_LEFTPOPUP", "左クリックで一覧を表示"), #selector(toggleLeftClick(_:)), store.leftClickList)
        add(Lang.m("CONN_MENU_HOTKEY", "ホットキー (⌃⌥M) で一覧を表示"), #selector(toggleHotkey(_:)), store.hotkey)
        add(Lang.m("CONN_MENU_LOGIN_ITEM", "Mac にログインしたら Tera Term Mac を起動"), #selector(toggleLoginItem(_:)), LoginItem.enabled)
        add(Lang.t("TTMenu", "MENU_VERSION", "バージョン情報"), #selector(showVersion(_:)))
        m.addItem(.separator())
        add(Lang.m("CONN_MENU_EXECUTE", "実行 (新しい接続)…"), #selector(execute(_:)))
        m.addItem(.separator())
        add(Lang.t("TTMenu", "MENU_CLOSE", "終了"), #selector(quit(_:)))
        if !store.leftClickList {
            // 左クリックで設定メニューを出す場合も、一覧はサブメニューで選べるように
            let sub = NSMenuItem(title: Lang.m("CONN_MENU_LIST", "一覧"), action: nil, keyEquivalent: "")
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

    /// アプリのメニューバーの「接続リスト」メニュー
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let edit = NSMenuItem(title: Lang.t("TTMenu", "MENU_LISTCONFIG", "リスト設定") + "…", action: #selector(showEditor(_:)), keyEquivalent: "e")
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

final class MenuEditorWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate, NSMenuDelegate {
    private var entries = MenuStore.shared.entries
    private var roots = MenuStore.shared.tree
    private var current = MenuEntry()
    /// 新しく登録する接続先を入れるフォルダ (nil は最上位)
    private var targetFolder: MenuNode?

    private let outline = NSOutlineView()
    private let folderLabel = NSTextField(labelWithString: "")
    private let nameField = NSTextField()
    private let hostField = NSTextField().ascii()
    private let loginRadio = NSButton(radioButtonWithTitle: Lang.t("TTMenu", "DLG_CONFIG_AUTO", "自動ログイン"), target: nil, action: nil)
    private let macroRadio = NSButton(radioButtonWithTitle: Lang.t("TTMenu", "DLG_CONFIG_MACRO", "マクロファイル指定"), target: nil, action: nil)
    private let directRadio = NSButton(radioButtonWithTitle: Lang.t("TTMenu", "DLG_CONFIG_LAUNCH", "起動のみ"), target: nil, action: nil)
    private let userCheck = NSButton(checkboxWithTitle: Lang.t("TTMenu", "DLG_CONFIG_USER", "ユーザー名"), target: nil, action: nil)
    private let userField = NSTextField().ascii()
    private let passCheck = NSButton(checkboxWithTitle: Lang.t("TTMenu", "DLG_CONFIG_PASS", "パスワード"), target: nil, action: nil)
    private let passField = NSSecureTextField()
    private let sshCheck = NSButton(checkboxWithTitle: Lang.t("TTMenu", "DLG_CONFIG_SSH", "SSH を使う"), target: nil, action: nil)
    private let keyField = NSTextField()
    private let keyButton = NSButton(title: "…", target: nil, action: nil)
    private let macroField = NSTextField()
    private let macroButton = NSButton(title: "…", target: nil, action: nil)
    private let startupCheck = NSButton(checkboxWithTitle: Lang.t("TTMenu", "DLG_CONFIG_STARTUP", "起動時に実行"), target: nil, action: nil)
    // IDC_CHALLENGE_CHECK / IDC_PAGEANT_CHECK (ttpmenu.rc: 鍵ファイルの下)
    private let challengeCheck = NSButton(checkboxWithTitle: Lang.t("TTMenu", "DLG_CONFIG_CHALLENGE", "チャレンジレスポンス認証"), target: nil, action: nil)
    // Mac では Pageant の代わりに ssh-agent (1Password などのエージェントも) を使うので、名前もそう書く
    private let pageantCheck = NSButton(checkboxWithTitle: Lang.m("CONN_USE_SSH_AGENT", "ssh-agent を使う (Pageant にあたるもの)"), target: nil, action: nil)
    private let agentPicker = SSHAgentSocketPicker()
    /// パスワード欄で Ctrl+A〜Ctrl+_ を制御文字として入れる (winmisc.cpp password_wnd_proc。ttpmenu 1.11)
    private var passKeyMonitor: Any?
    private static let dragType = NSPasteboard.PasteboardType("net.satoru.teramac.menunode")

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = Lang.t("TTMenu", "DLG_CONFIG_TITLE", "リスト設定") + " - " + Lang.m("CONN_TTMENU_NAME", "Tera Term Mac メニュー")
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
        outline.expandItem(nil, expandChildren: true)
        if let first = firstEntryNode(roots) { select(first) } else { clearForm() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let m = passKeyMonitor { NSEvent.removeMonitor(m) } }

    // MARK: 画面

    private func build() {
        // 左: 登録一覧 (フォルダ分けしたツリー)
        let col = NSTableColumn(identifier: .init("name"))
        col.title = Lang.t("TTMenu", "DLG_CONFIG_ITEM", "登録一覧")
        col.width = 230
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.registerForDraggedTypes([MenuEditorWindowController.dragType])
        outline.setDraggingSourceOperationMask([.move, .delete], forLocal: true)
        // 右クリックのメニュー (押した行に合わせて menuNeedsUpdate で作る)
        let ctx = NSMenu()
        ctx.delegate = self
        outline.menu = ctx
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let up = NSButton(title: "▲", target: self, action: #selector(moveNodeUp(_:)))
        let down = NSButton(title: "▼", target: self, action: #selector(moveNodeDown(_:)))
        up.toolTip = Lang.t("Tera Term", "DLG_TCPIP_UP", "上へ")
        down.toolTip = Lang.t("Tera Term", "DLG_TCPIP_DOWN", "下へ")
        let newButton = NSButton(title: Lang.m("CONN_NEW", "新規"), target: self, action: #selector(newEntry(_:)))
        newButton.image = Sym.image("plus", nil)
        newButton.imagePosition = .imageLeading
        let folderButton = NSButton(title: Lang.m("CONN_FOLDER", "フォルダ"), target: self, action: #selector(newFolder(_:)))
        folderButton.image = Sym.image("folder.badge.plus", nil)
        folderButton.imagePosition = .imageLeading
        folderButton.toolTip = Lang.m("CONN_NEW_FOLDER_TIP", "新しいフォルダ (一覧の右クリックでも作れます)")
        let hint = NSTextField(wrappingLabelWithString: Lang.m("CONN_EDITOR_HINT", "右クリックでフォルダの作成・名前の変更。ドラッグでフォルダに入れられます"))
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 250
        let left = NSStackView(views: [scroll, hstack([newButton, folderButton, up, down]), hint])
        left.orientation = .vertical
        left.alignment = .leading

        // 中: 登録 (←) と削除
        let setButton = NSButton(title: "← " + Lang.m("CONN_REGISTER", "登録"), target: self, action: #selector(register(_:)))
        setButton.toolTip = Lang.m("CONN_REGISTER_TIP", "右の内容を一覧に登録 (同じ名前なら上書き)")
        let delButton = DropDeleteButton(title: Lang.m("CONN_DELETE", "削除"), target: self, action: #selector(deleteSelected(_:)))
        delButton.toolTip = Lang.m("CONN_DELETE_TIP", "選んでいる項目を削除 (一覧からここにドラッグしても削除できます)")
        delButton.dragType = MenuEditorWindowController.dragType
        delButton.onDrop = { [weak self] id in
            guard let self = self, let n = self.node(withID: id, in: self.roots) else { return }
            self.select(n)
            self.loadSelected()
            self.confirmDelete(n)
        }
        delButton.image = Sym.image("trash", Lang.m("CONN_DELETE", "削除"))
        delButton.imagePosition = .imageLeading
        let mid = NSStackView(views: [setButton, delButton])
        mid.orientation = .vertical

        // 右: 設定
        for f in [nameField, hostField, userField, passField, keyField, macroField] {
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        hostField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        hostField.placeholderString = Lang.m("CONN_HOST_PORT_PLACEHOLDER", "ホスト名 / ホスト名:ポート番号")
        userField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        passField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        passField.placeholderString = Lang.m("CONN_SAVED_IN_KEYCHAIN", "キーチェーンに保存")
        keyField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        macroField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        for r in [loginRadio, macroRadio, directRadio, userCheck, passCheck, sshCheck, challengeCheck, pageantCheck] { r.target = self; r.action = #selector(formChanged(_:)) }
        passKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, e.window === self.window,
                  let fe = self.window?.firstResponder as? NSTextView, fe.delegate === self.passField,
                  e.modifierFlags.intersection([.control, .command, .option]) == .control,
                  let c = e.characters?.unicodeScalars.first, (0x01...0x1F).contains(c.value) else { return e }
            fe.insertText(String(c), replacementRange: fe.selectedRange())   // EM_REPLACESEL
            return nil
        }
        keyButton.target = self; keyButton.action = #selector(chooseKey(_:))
        macroButton.target = self; macroButton.action = #selector(chooseMacro(_:))
        folderLabel.textColor = .secondaryLabelColor

        let keyLabel = NSTextField(labelWithString: Lang.t("TTMenu", "DLG_CONFIG_KEYFILE", "鍵ファイル"))
        let pattern = NSStackView(views: [
            loginRadio,
            indent(hstack([userCheck, userField])),
            indent(hstack([passCheck, passField])),
            indent(sshCheck),
            indent(hstack([keyLabel, keyField, keyButton])),
            indent(challengeCheck),
            indent(pageantCheck),
            indent(indent(agentPicker)),
            macroRadio,
            indent(hstack([macroField, macroButton])),
            directRadio,
        ])
        pattern.orientation = .vertical
        pattern.alignment = .leading
        pattern.spacing = 8
        let patternBox = NSBox()
        patternBox.title = Lang.t("TTMenu", "DLG_CONFIG_PATTERN", "起動方法")
        patternBox.contentView = pad(pattern)

        let details = NSButton(title: Lang.t("TTMenu", "DLG_CONFIG_DETAIL", "詳細") + "…", target: self, action: #selector(showDetails(_:)))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: Lang.m("CONN_FOLDER_LABEL", "フォルダ:")), folderLabel],
            [NSTextField(labelWithString: Lang.t("TTMenu", "DLG_CONFIG_NAME", "名前") + ":"), nameField],
            [NSTextField(labelWithString: Lang.t("TTMenu", "DLG_CONFIG_HOST", "ホスト名") + ":"), hostField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let right = NSStackView(views: [grid, patternBox, hstack([details, startupCheck])])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
        let configBox = NSBox()
        configBox.title = Lang.t("TTMenu", "DLG_CONFIG_CONFIG", "設定")
        configBox.contentView = pad(right)

        let top = NSStackView(views: [left, mid, configBox])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 12

        let connectButton = NSButton(title: Lang.m("CONN_CONNECT", "接続"), target: self, action: #selector(connectForm(_:)))
        connectButton.keyEquivalent = "\r"
        let closeButton = NSButton(title: Lang.t("Tera Term", "BTN_CLOSE", "閉じる"), target: self, action: #selector(closeEditor(_:)))
        closeButton.keyEquivalent = "\u{1B}"
        // ttpmenu.ini (TeraTerm Menu の接続先の一覧) の読み書きは 1 つのメニューにまとめる
        let iniMenu = NSPopUpButton(frame: .zero, pullsDown: true)
        iniMenu.addItem(withTitle: "ttpmenu.ini")
        iniMenu.item(at: 0)?.image = Sym.image("arrow.left.arrow.right", nil)
        let imp = NSMenuItem(title: Lang.m("CONN_IMPORT", "読み込み…"), action: #selector(importTTMenu(_:)), keyEquivalent: "")
        let exp = NSMenuItem(title: Lang.m("CONN_EXPORT", "書き出し…"), action: #selector(exportTTMenu(_:)), keyEquivalent: "")
        imp.target = self
        exp.target = self
        iniMenu.menu?.addItem(imp)
        iniMenu.menu?.addItem(exp)
        iniMenu.toolTip = Lang.m("CONN_INI_TIP", "接続先の一覧を ttpmenu.ini (TeraTerm Menu の形式) で読み書きします。ほかの Mac や Windows 版 TeraTerm Menu との受け渡しに")
        let bottom = hstack([iniMenu, NSView(), closeButton, connectButton])

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
            scroll.heightAnchor.constraint(equalTo: configBox.heightAnchor, constant: -50),
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

    // MARK: ツリー

    private func entry(_ n: MenuNode) -> MenuEntry? {
        guard let id = n.entryID else { return nil }
        return entries.first { $0.id == id }
    }

    private func firstEntryNode(_ list: [MenuNode]) -> MenuNode? {
        for n in list {
            if n.entryID != nil { return n }
            if let c = firstEntryNode(n.children) { return c }
        }
        return nil
    }

    /// 親のフォルダ (最上位なら nil)。ツリーから探すので、折りたたんでいても分かる
    private func parent(of node: MenuNode) -> MenuNode? {
        func find(_ list: [MenuNode], _ p: MenuNode?) -> MenuNode?? {
            for n in list {
                if n === node { return .some(p) }
                if let r = find(n.children, n) { return r }
            }
            return nil
        }
        return find(roots, nil) ?? nil
    }

    private func siblings(of node: MenuNode) -> [MenuNode] { parent(of: node)?.children ?? roots }

    private func setSiblings(_ list: [MenuNode], parent p: MenuNode?) {
        if let p = p { p.children = list } else { roots = list }
    }

    private func detach(_ node: MenuNode) {
        let p = parent(of: node)
        var list = siblings(of: node)
        list.removeAll { $0 === node }
        setSiblings(list, parent: p)
    }

    private func contains(_ a: MenuNode, _ b: MenuNode) -> Bool {
        if a === b { return true }
        return a.children.contains { contains($0, b) }
    }

    private func folderPath(_ f: MenuNode?) -> String {
        var names: [String] = []
        var n = f
        while let x = n { names.insert(x.folder ?? "", at: 0); n = parent(of: x) }
        return names.isEmpty ? Lang.m("CONN_TOP_LEVEL_PAREN", "(最上位)") : names.joined(separator: " / ")
    }

    private var selectedNode: MenuNode? { outline.item(atRow: outline.selectedRow) as? MenuNode }

    private func select(_ n: MenuNode) {
        var chain: [MenuNode] = []
        var p = parent(of: n)
        while let x = p { chain.insert(x, at: 0); p = parent(of: x) }
        for x in chain { outline.expandItem(x) }
        let r = outline.row(forItem: n)
        if r >= 0 { outline.selectRowIndexes([r], byExtendingSelection: false); outline.scrollRowToVisible(r) }
    }

    private func save() {
        roots = MenuStore.normalize(roots, entries: entries)
        MenuStore.shared.entries = entries
        MenuStore.shared.tree = roots
        outline.reloadData()
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
        challengeCheck.state = e.challenge ? .on : .off
        pageantCheck.state = e.pageant && !e.challenge ? .on : .off
        agentPicker.socket = e.agentSocket
        macroField.stringValue = e.macroFile
        startupCheck.state = e.startup ? .on : .off
        folderLabel.stringValue = folderPath(targetFolder)
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
        if e.useSSH {   // ttpmenu.cpp: bTtssh のときだけチェックを読む
            e.challenge = challengeCheck.state == .on
            e.pageant = pageantCheck.state == .on
            e.agentSocket = e.pageant ? agentPicker.socket : e.agentSocket
        }
        e.macroFile = macroField.stringValue
        e.startup = startupCheck.state == .on
        if e.name.isEmpty { e.name = e.host }
        return (e, passField.stringValue)
    }

    /// 新しい接続先の入力にする (folder の中に登録する)
    private func clearForm(in folder: MenuNode? = nil) {
        targetFolder = folder
        var e = MenuEntry()
        fillForm(e)
        outline.deselectAll(nil)
        targetFolder = folder
        folderLabel.stringValue = folderPath(folder)
        window?.makeFirstResponder(nameField)
    }

    private func updateEnabled() {
        let login = loginRadio.state == .on
        userCheck.isEnabled = login
        userField.isEnabled = login && userCheck.state == .on
        passCheck.isEnabled = login
        passField.isEnabled = login && passCheck.state == .on
        sshCheck.isEnabled = login || directRadio.state == .on
        // チャレンジ・Pageant を選ぶと鍵ファイルともう一方は使えない (IDC_CHALLENGE_CHECK / IDC_PAGEANT_CHECK の BN_CLICKED)
        let ssh = login && sshCheck.state == .on
        challengeCheck.isEnabled = ssh && pageantCheck.state != .on
        pageantCheck.isEnabled = ssh && challengeCheck.state != .on
        agentPicker.isEnabled = ssh && pageantCheck.state == .on
        keyField.isEnabled = ssh && challengeCheck.state != .on && pageantCheck.state != .on
        keyButton.isEnabled = keyField.isEnabled
        macroField.isEnabled = macroRadio.state == .on
        macroButton.isEnabled = macroField.isEnabled
    }

    @objc private func formChanged(_ sender: Any?) { updateEnabled() }

    private func loadSelected() {
        guard let n = selectedNode else { return }
        if n.isFolder {
            // フォルダを選んだら、そのフォルダに新しい接続先を作る入力にする
            targetFolder = n
            var e = MenuEntry()
            fillForm(e)
            return
        }
        targetFolder = parent(of: n)
        if let e = entry(n) { fillForm(e) }
    }

    // MARK: ボタン・右クリック

    @objc private func register(_ sender: Any?) {
        let (e, pw) = readForm()
        guard !e.name.isEmpty else { NSSound.beep(); window?.makeFirstResponder(nameField); return }
        var entry = e
        var isNew = false
        // 同じ名前があれば上書き (Windows 版と同じ。ttpmenu.ini では名前が見出しになるので、フォルダが違っても重ねない)
        if let i = entries.firstIndex(where: { $0.name == e.name }) {
            entry.id = entries[i].id
            entries[i] = entry
        } else if let i = entries.firstIndex(where: { $0.id == e.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
            isNew = true
        }
        if entry.usePassword { Keychain.set(pw, for: entry.id) } else { Keychain.delete(entry.id) }
        current = entry
        if isNew {
            let node = MenuNode(entryID: entry.id)
            if let f = targetFolder { f.children.append(node) } else { roots.append(node) }
            save()
            select(node)
        } else {
            save()
            if let n = findNode(entryID: entry.id, in: roots) { select(n) }
        }
    }

    private func findNode(entryID: String, in list: [MenuNode]) -> MenuNode? {
        for n in list {
            if n.entryID == entryID { return n }
            if let c = findNode(entryID: entryID, in: n.children) { return c }
        }
        return nil
    }

    /// 右クリックした行 (メニューから呼ばれたとき)、なければ選んでいる行
    private func node(for sender: Any?) -> MenuNode? {
        if sender is NSMenuItem, outline.clickedRow >= 0 { return outline.item(atRow: outline.clickedRow) as? MenuNode }
        if sender is NSMenuItem && outline.clickedRow < 0 { return nil }
        return selectedNode
    }

    /// その行からみた「入れる先のフォルダ」
    private func folder(for n: MenuNode?) -> MenuNode? {
        guard let n = n else { return nil }
        return n.isFolder ? n : parent(of: n)
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let n = node(for: sender) else { NSSound.beep(); return }
        confirmDelete(n)
    }

    /// 削除してよいか聞いてから消す (削除ボタン・右クリック・削除ボタンへのドラッグから)
    private func confirmDelete(_ n: MenuNode) {
        let a = NSAlert()
        if n.isFolder {
            let count = n.allEntryIDs.count
            a.messageText = Lang.m("CONN_DELETE_FOLDER_Q", "フォルダ「%s」を削除しますか?", n.folder ?? "")
            a.informativeText = count > 0 ? Lang.m("CONN_DELETE_FOLDER_COUNT", "中の接続先 %d 件も削除されます。", count) : Lang.m("CONN_FOLDER_IS_EMPTY", "空のフォルダです。")
        } else {
            a.messageText = Lang.m("CONN_DELETE_ENTRY_Q", "「%s」を削除しますか?", entry(n)?.name ?? "")
        }
        a.addButton(withTitle: Lang.m("CONN_DELETE", "削除"))
        a.addButton(withTitle: Lang.t("TTMenu", "BTN_CANCEL", "やめる"))
        a.beginSheetModal(for: window!) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let ids = Set(n.allEntryIDs)
            for id in ids { Keychain.delete(id) }
            self.entries.removeAll { ids.contains($0.id) }
            let p = self.parent(of: n)
            self.detach(n)
            self.save()
            if let p = p { self.select(p); self.loadSelected() }
            else if let f = self.firstEntryNode(self.roots) { self.select(f); self.loadSelected() }
            else { self.clearForm() }
        }
    }

    @objc private func newEntry(_ sender: Any?) {
        clearForm(in: folder(for: node(for: sender)))
    }

    @objc private func newFolder(_ sender: Any?) {
        let into = folder(for: node(for: sender))
        askName(title: Lang.m("CONN_NEW_FOLDER_NAME", "新しいフォルダ"), message: into.map { Lang.m("CONN_NEW_FOLDER_INSIDE", "「%s」の中に作ります", $0.folder ?? "") } ?? "", value: Lang.m("CONN_NEW_FOLDER_NAME", "新しいフォルダ")) { name in
            let f = MenuNode(folder: name)
            if let p = into { p.children.append(f) } else { self.roots.append(f) }
            self.save()
            self.select(f)
            self.loadSelected()
        }
    }

    @objc private func renameFolder(_ sender: Any?) {
        guard let n = node(for: sender), n.isFolder else { return }
        askName(title: Lang.m("CONN_RENAME_FOLDER", "フォルダの名前を変更"), message: "", value: n.folder ?? "") { name in
            n.folder = name
            self.save()
            self.select(n)
            self.loadSelected()
        }
    }

    private func askName(title: String, message: String, value: String, done: @escaping (String) -> Void) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = value
        a.accessoryView = f
        a.addButton(withTitle: Lang.t("TTMenu", "BTN_OK", "OK"))
        a.addButton(withTitle: Lang.t("TTMenu", "BTN_CANCEL", "キャンセル"))
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: window!) { r in
            let name = f.stringValue.trimmingCharacters(in: .whitespaces)
            if r == .alertFirstButtonReturn && !name.isEmpty { done(name) }
        }
    }

    @objc private func moveNodeUp(_ sender: Any?) { move(-1) }
    @objc private func moveNodeDown(_ sender: Any?) { move(1) }

    private func move(_ d: Int) {
        guard let n = selectedNode else { return }
        let p = parent(of: n)
        var list = siblings(of: n)
        guard let i = list.firstIndex(where: { $0 === n }) else { return }
        let t = i + d
        guard t >= 0, t < list.count else { NSSound.beep(); return }
        list.swapAt(i, t)
        setSiblings(list, parent: p)
        save()
        select(n)
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

    @objc private func connectNode(_ sender: Any?) {
        guard let n = node(for: sender), let e = entry(n) else { return }
        TeraMenuLauncher.launch(e)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let n = outline.item(atRow: outline.clickedRow) as? MenuNode else { return }
        if n.isFolder {
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        } else if let e = entry(n) {
            TeraMenuLauncher.launch(e)
        }
    }

    @objc private func closeEditor(_ sender: Any?) { window?.performClose(nil) }

    /// 右クリックのメニューを、押した行に合わせて作る
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ t: String, _ a: Selector, _ symbol: String) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: "")
            i.target = self
            i.image = Sym.image(symbol, nil)
            menu.addItem(i)
        }
        let n = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? MenuNode : nil
        let place = folder(for: n).map { $0.folder ?? "" }
        add(place.map { Lang.m("CONN_NEW_FOLDER_IN", "「%s」に新しいフォルダ…", $0) } ?? Lang.m("CONN_NEW_FOLDER_ITEM", "新しいフォルダ…"), #selector(newFolder(_:)), "folder.badge.plus")
        add(place.map { Lang.m("CONN_NEW_ENTRY_IN", "「%s」に新しい接続先", $0) } ?? Lang.m("CONN_NEW_ENTRY", "新しい接続先"), #selector(newEntry(_:)), "plus")
        if let n = n {
            menu.addItem(.separator())
            if n.isFolder {
                add(Lang.m("CONN_RENAME", "名前を変更…"), #selector(renameFolder(_:)), "pencil")
                add(Lang.m("CONN_DELETE_FOLDER", "フォルダを削除…"), #selector(deleteSelected(_:)), "trash")
            } else {
                add(Lang.m("CONN_CONNECT", "接続"), #selector(connectNode(_:)), "play")
                add(Lang.m("CONN_DELETE_ELLIPSIS", "削除…"), #selector(deleteSelected(_:)), "trash")
            }
        }
    }

    // MARK: ttpmenu.ini

    @objc private func importTTMenu(_ sender: Any?) {
        let p = NSOpenPanel()
        p.message = Lang.m("CONN_IMPORT_CHOOSE", "読み込む ttpmenu.ini を選んでください")
        p.allowedFileTypes = ["ini", "INI"]
        p.allowsOtherFileTypes = true
        p.beginSheetModal(for: window!) { r in
            guard r == .OK, let url = p.url else { return }
            guard let data = try? Data(contentsOf: url), let ini = IniFile(data: data) else {
                self.info(Lang.m("CONN_IMPORT_FAILED", "読み込めませんでした"), url.path); return
            }
            let res = TTMenuIni.read(ini)
            guard !res.entries.isEmpty else {
                self.info(Lang.m("CONN_IMPORT_NO_ENTRIES", "接続先が見つかりませんでした"), Lang.m("CONN_IMPORT_NOT_TTPMENU", "ttpmenu.ini ではないかもしれません。\n%s", url.path)); return
            }
            // 開くパネルのシートが閉じてから出す
            DispatchQueue.main.async { self.confirmImport(url: url, ini: ini, result: res) }
        }
    }

    /// 読み込む前に、何が入るかを見せて確かめる
    private func confirmImport(url: URL, ini: IniFile, result res: TTMenuIni.ImportResult) {
        let a = NSAlert()
        a.messageText = Lang.m("CONN_IMPORT_CONFIRM", "%s から %d 件の接続先を読み込みます", url.lastPathComponent, res.entries.count)
        let existing = Set(entries.map { $0.name })
        let adds = res.entries.filter { !existing.contains($0.name) }.count
        a.informativeText = Lang.m("CONN_IMPORT_SUMMARY", "新しく追加 %d 件・同じ名前を上書き %d 件", adds, res.entries.count - adds)
            + (res.passwords.isEmpty ? "" : "\n" + Lang.m("CONN_IMPORT_PASSWORDS", "パスワード %d 件はキーチェーンに保存します", res.passwords.count))

        // 一覧 (追加/上書き・名前・ホスト) と注意
        var text = ""
        for e in res.entries {
            text += (existing.contains(e.name) ? Lang.m("CONN_IMPORT_ROW_REPLACE", "上書き") : Lang.m("CONN_IMPORT_ROW_ADD", "追加")) + "\t" + e.name
            if !e.host.isEmpty && e.host != e.name { text += "　(\(e.host))" }
            if let f = res.folders[e.id] { text += "　[" + Lang.m("CONN_FOLDER_LABEL", "フォルダ:") + " " + f.joined(separator: " / ") + "]" }
            text += "\n"
        }
        if !res.notes.isEmpty { text += "\n" + Lang.m("CONN_IMPORT_NOTES", "注意:") + "\n" + res.notes.map { "・" + $0 }.joined(separator: "\n") + "\n" }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 440, height: min(220, CGFloat(res.entries.count + res.notes.count + 3) * 16 + 12))
        scroll.borderType = .bezelBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            tv.string = text
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: scroll.frame.height).isActive = true

        // 入れる先
        let dest = NSPopUpButton(frame: .zero, pullsDown: false)
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        dest.addItem(withTitle: Lang.m("CONN_TOP_LEVEL", "最上位"))
        dest.addItem(withTitle: Lang.m("CONN_IMPORT_NEW_FOLDER", "新しいフォルダ「%s」", base))
        dest.lastItem?.tag = 1
        func addFolders(_ list: [MenuNode], _ prefix: String) {
            for n in list where n.isFolder {
                dest.addItem(withTitle: prefix + (n.folder ?? ""))
                dest.lastItem?.representedObject = n
                addFolders(n.children, prefix + (n.folder ?? "") + " / ")
            }
        }
        addFolders(roots, "")
        let destNote = NSTextField(labelWithString: Lang.m("CONN_IMPORT_DEST_NOTE", "(上書きする接続先は、今ある場所のまま)"))
        destNote.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        destNote.textColor = .secondaryLabelColor
        let settings = NSButton(checkboxWithTitle: Lang.m("CONN_IMPORT_SETTINGS", "全体の設定 (アイコンの大きさ・クリックの動き・ホットキー) も読み込む"), target: nil, action: nil)
        settings.state = .on
        let destRow = NSStackView(views: [NSTextField(labelWithString: Lang.m("CONN_IMPORT_DEST", "入れる先:")), dest, destNote])
        let stack = NSStackView(views: [scroll, destRow, settings])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 440, height: stack.fittingSize.height)
        a.accessoryView = stack
        a.addButton(withTitle: Lang.m("CONN_IMPORT_BUTTON", "読み込む"))
        a.addButton(withTitle: Lang.t("TTMenu", "BTN_CANCEL", "キャンセル"))
        a.beginSheetModal(for: window!) { r in
            guard r == .alertFirstButtonReturn else { return }
            var folder = dest.selectedItem?.representedObject as? MenuNode
            if dest.selectedItem?.tag == 1 {
                let f = MenuNode(folder: base)
                self.roots.append(f)
                folder = f
            }
            let (added, replaced) = TTMenuIni.apply(res, ini: ini, includeSettings: settings.state == .on)
            self.entries = MenuStore.shared.entries
            // 新しく入った接続先を入れる先へ (上書きしたものは元の場所のまま)
            // ファイルに書いてあるフォルダ分けを、入れる先の下に作り直す
            func folderNode(_ path: [String], under base: MenuNode?) -> MenuNode? {
                var cur = base
                for name in path {
                    let list = cur?.children ?? self.roots
                    if let f = list.first(where: { $0.folder == name }) { cur = f; continue }
                    let f = MenuNode(folder: name)
                    if let c = cur { c.children.append(f) } else { self.roots.append(f) }
                    cur = f
                }
                return cur
            }
            for id in added {
                let node = MenuNode(entryID: id)
                let f = folderNode(res.folders[id] ?? [], under: folder)
                if let f = f { f.children.append(node) } else { self.roots.append(node) }
            }
            self.save()
            if let first = added.first.flatMap({ self.findNode(entryID: $0, in: self.roots) }) { self.select(first); self.loadSelected() }
            self.info(Lang.m("CONN_IMPORT_DONE", "読み込みました"), Lang.m("CONN_IMPORT_DONE_DETAIL", "追加 %d 件・上書き %d 件", added.count, replaced))
        }
    }

    @objc private func exportTTMenu(_ sender: Any?) {
        guard !entries.isEmpty else { NSSound.beep(); return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "ttpmenu.ini"
        p.message = Lang.m("CONN_EXPORT_MESSAGE", "接続先の一覧を ttpmenu.ini に書き出します")
        let scope = NSPopUpButton(frame: .zero, pullsDown: false)
        scope.addItem(withTitle: Lang.m("CONN_EXPORT_ALL", "すべての接続先 (%d 件)", entries.count))
        if let f = folder(for: selectedNode) {
            scope.addItem(withTitle: Lang.m("CONN_EXPORT_FOLDER", "フォルダ「%s」の中だけ (%d 件)", f.folder ?? "", f.allEntryIDs.count))
            scope.lastItem?.representedObject = f
        }
        let check = NSButton(checkboxWithTitle: Lang.m("CONN_EXPORT_PASSWORDS", "パスワードも書き出す (簡易な暗号化なので取り扱い注意)"), target: nil, action: nil)
        check.state = .off
        let note = NSTextField(labelWithString: Lang.m("CONN_EXPORT_NOTE", "フォルダ分けも書き出し、読み込むときに元のフォルダに戻します"))
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [NSStackView(views: [NSTextField(labelWithString: Lang.m("CONN_EXPORT_SCOPE", "書き出す範囲:")), scope]), check, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.frame = NSRect(x: 0, y: 0, width: 580, height: stack.fittingSize.height)
        p.accessoryView = stack
        p.beginSheetModal(for: window!) { r in
            guard r == .OK, let url = p.url else { return }
            // ツリーの並び順で書き出す
            let scopeNode = scope.selectedItem?.representedObject as? MenuNode
            let ids = scopeNode?.allEntryIDs ?? self.roots.flatMap { $0.allEntryIDs }
            let byID = Dictionary(self.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let list = ids.compactMap { byID[$0] }
            // フォルダの道すじ (書き出す範囲のフォルダから下)
            var paths: [String: [String]] = [:]
            func walk(_ nodes: [MenuNode], _ path: [String]) {
                for n in nodes {
                    if let id = n.entryID { if !path.isEmpty { paths[id] = path } }
                    else { walk(n.children, path + [n.folder ?? ""]) }
                }
            }
            walk(scopeNode?.children ?? self.roots, [])
            let data = TTMenuIni.write(list, includePasswords: check.state == .on, folders: paths)
            do {
                try data.write(to: url)
                self.info(Lang.m("CONN_EXPORT_DONE", "書き出しました"), Lang.m("CONN_EXPORT_DONE_DETAIL", "%d 件の接続先を書き出しました\n%s", list.count, url.path))
            } catch {
                NSAlert(error: error).beginSheetModal(for: self.window!)
            }
        }
    }

    private func info(_ title: String, _ text: String) {
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.beginSheetModal(for: self.window!)
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

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? MenuNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? MenuNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? MenuNode)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? MenuNode else { return nil }
        let cell = NSTableCellView()
        let symbol: String
        let title: String
        if let f = n.folder {
            symbol = "folder"
            title = f
            cell.toolTip = Lang.m("CONN_ENTRY_COUNT", "%d 件", n.allEntryIDs.count)
        } else {
            let e = entry(n)
            symbol = e?.symbolName ?? "questionmark"
            title = (e?.name ?? "") + ((e?.startup ?? false) ? "  ⏻" : "")
            cell.toolTip = e?.host
        }
        let img = NSImageView(image: Sym.image(symbol, nil) ?? NSImage())
        if n.isFolder { img.contentTintColor = .controlAccentColor }
        let text = NSTextField(labelWithString: title)
        text.lineBreakMode = .byTruncatingTail
        let s = NSStackView(views: [img, text])
        s.spacing = 6
        s.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            s.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            s.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { loadSelected() }

    // ドラッグで並べ替え・フォルダに入れる
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = item as? MenuNode else { return nil }
        let p = NSPasteboardItem()
        p.setString(n.id, forType: MenuEditorWindowController.dragType)
        return p
    }

    private func node(withID id: String, in list: [MenuNode]) -> MenuNode? {
        for n in list {
            if n.id == id { return n }
            if let c = node(withID: id, in: n.children) { return c }
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let id = info.draggingPasteboard.string(forType: MenuEditorWindowController.dragType),
              let dragged = node(withID: id, in: roots) else { return [] }
        let target = item as? MenuNode
        // 接続先の上に落としたら、その接続先のすぐ後ろに入れる
        if let t = target, !t.isFolder {
            if dragged === t { return [] }
            let p = parent(of: t)
            let i = (p?.children ?? roots).firstIndex { $0 === t } ?? 0
            outlineView.setDropItem(p, dropChildIndex: i + 1)
            return .move
        }
        // フォルダを自分の中に入れることはできない
        if let t = target, contains(dragged, t) { return [] }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: MenuEditorWindowController.dragType),
              let dragged = node(withID: id, in: roots) else { return false }
        let target = item as? MenuNode
        if let t = target, contains(dragged, t) { return false }
        let oldParent = parent(of: dragged)
        var oldList = siblings(of: dragged)
        let oldIndex = oldList.firstIndex { $0 === dragged } ?? 0
        oldList.remove(at: oldIndex)
        setSiblings(oldList, parent: oldParent)
        var list = target?.children ?? roots
        var at = index < 0 ? list.count : index
        if oldParent === target && index >= 0 && oldIndex < index { at -= 1 }
        list.insert(dragged, at: max(0, min(at, list.count)))
        setSiblings(list, parent: target)
        save()
        if let t = target { outlineView.expandItem(t) }
        select(dragged)
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
        logField.placeholderString = Lang.m("CONN_LOG_PLACEHOLDER", "空ならログなし  例: ~/Documents/%Y%m%d.log")
        optionField.placeholderString = Lang.m("CONN_OPTION_PLACEHOLDER", "例: /KR=SJIS /KT=SJIS  /BAUD=115200")
        let logButton = NSButton(title: "…", target: self, action: #selector(chooseLog))
        let defaults = NSButton(title: Lang.t("TTMenu", "BTN_DEFAULT", "標準に戻す"), target: self, action: #selector(resetDefaults))
        fill(entry)
        func row(_ v: [NSView]) -> NSStackView { let s = NSStackView(views: v); s.spacing = 6; return s }
        let help = NSTextField(wrappingLabelWithString:
            Lang.m("CONN_OPTION_HELP", "オプション: /KR= /KT= で文字コード (UTF8 / SJIS / EUC)、/BAUD= /C= でシリアル、/T=0 で生 TCP など、Tera Term のコマンドラインと同じ書き方です。"))
        help.font = NSFont.systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 440
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: Lang.t("TTMenu", "DLG_ETC_LOGFILE", "ログファイル") + ":"), row([logField, logButton])],
            [NSTextField(labelWithString: Lang.m("CONN_USER_PROMPT", "ユーザー名プロンプト:")), userPrompt],
            [NSTextField(labelWithString: Lang.m("CONN_PASSWORD_PROMPT", "パスワードプロンプト:")), passPrompt],
            [NSTextField(labelWithString: Lang.t("TTMenu", "DLG_ETC_OPTION", "オプション") + ":"), optionField],
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
        /// id → フォルダの道すじ (Folder= の値を / で分けたもの)
        var folders: [String: [String]] = [:]
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
            e.challenge = flag("Challenge")
            e.pageant = flag("Pageant")
            e.macroFile = str("MacroFile")
            e.startup = flag("Startup")
            e.logFile = str("Log")
            if !str("LoginPrompt").isEmpty { e.loginPrompt = str("LoginPrompt") }
            if !str("PasswdPrompt").isEmpty { e.passwordPrompt = str("PasswdPrompt") }
            e.option = str("Option")
            if e.usePassword {
                if flag("LockBoxFlag") {
                    e.usePassword = false
                    r.notes.append(Lang.m("CONN_NOTE_LOCKBOX", "「%s」のパスワードは LockBox で暗号化されているため読めません (%sで入れ直してください)", name, Lang.t("TTMenu", "MENU_LISTCONFIG", "リスト設定")))
                } else if let pw = decodePassword(str("Password")), !pw.isEmpty {
                    r.passwords[e.id] = pw
                } else {
                    e.usePassword = false
                }
            }
            for (label, path) in [(Lang.t("TTMenu", "DLG_CONFIG_KEYFILE", "鍵ファイル"), e.keyFile), (Lang.m("CONN_MACRO", "マクロ"), e.macroFile), (Lang.m("CONN_LOG", "ログ"), e.logFile)] where path.contains(":\\") {
                r.notes.append(Lang.m("CONN_NOTE_WINDOWS_PATH", "「%s」の%sは Windows のパスです: %s", name, label, path))
            }
            // このアプリが書き足すフォルダの情報 (TeraTerm Menu は知らない項目を無視するので害はない)
            let folder = str("Folder").split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !folder.isEmpty { r.folders[e.id] = folder }
            r.entries.append(e)
        }
        return r
    }

    /// Windows 版と同じ書式 (UTF-16LE, BOM 付き, CRLF) で書き出す
    static func write(_ entries: [MenuEntry], includePasswords: Bool, folders: [String: [String]] = [:]) -> Data {
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
                "Folder=\((folders[e.id] ?? []).map { $0.replacingOccurrences(of: "/", with: "／") }.joined(separator: "/"))",
                "Challenge=\(e.challenge ? 1 : 0)",
                "Pageant=\(e.pageant ? 1 : 0)",
                "",
            ]
        }
        let text = lines.joined(separator: "\r\n")
        return Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
    }

    /// 読み込んだ内容を今の一覧にまとめる (同じ名前は上書き)。追加した接続先の id と上書きした数を返す
    @discardableResult
    static func apply(_ r: ImportResult, ini: IniFile, includeSettings: Bool) -> (added: [String], replaced: Int) {
        var list = MenuStore.shared.entries
        var added: [String] = [], replaced = 0
        for var e in r.entries {
            let pw = r.passwords[e.id]
            if let i = list.firstIndex(where: { $0.name == e.name }) {
                e.id = list[i].id
                list[i] = e
                replaced += 1
            } else {
                list.append(e)
                added.append(e.id)
            }
            if let pw = pw { Keychain.set(pw, for: e.id) } else if !e.usePassword { Keychain.delete(e.id) }
        }
        MenuStore.shared.entries = list
        if includeSettings {
            let T = "TTermMenu"
            if let v = num(ini.string(T, "IconMode")) { MenuStore.shared.largeIcon = v != 0 }
            if let v = num(ini.string(T, "LeftButtonPopup")) { MenuStore.shared.leftClickList = v != 0 }
            if let v = num(ini.string(T, "Hotkey")) {
                MenuStore.shared.hotkey = v != 0
                TeraMenuController.shared.updateHotkey()
            }
        }
        return (added, replaced)
    }

    /// ファイルから読み込んで最上位にまとめる (確かめの画面なし。自動テスト用)
    static func importFile(_ url: URL) -> (ok: Bool, message: String) {
        guard let data = try? Data(contentsOf: url), let ini = IniFile(data: data) else {
            return (false, "読み込めませんでした: \(url.path)")
        }
        let r = read(ini)
        guard !r.entries.isEmpty else { return (false, "接続先が見つかりませんでした。ttpmenu.ini ではないかもしれません。") }
        let (added, replaced) = apply(r, ini: ini, includeSettings: true)
        return (true, "追加 \(added.count) 件、上書き \(replaced) 件")
    }
}

/// 一覧の項目をドラッグして落とせる削除ボタン (落とすと onDrop に項目の id を渡す。確認はその先で出す)
final class DropDeleteButton: NSButton {
    var dragType: NSPasteboard.PasteboardType? {
        didSet { if let t = dragType { registerForDraggedTypes([t]) } }
    }
    var onDrop: ((String) -> Void)?
    private var dropTarget = false { didSet { needsDisplay = true } }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let t = dragType, sender.draggingPasteboard.string(forType: t) != nil else { return [] }
        dropTarget = true
        return .delete
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget = false
        guard let t = dragType, let id = sender.draggingPasteboard.string(forType: t) else { return false }
        // 確認のシートはドラッグが終わってから出す
        DispatchQueue.main.async { self.onDrop?(id) }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard dropTarget else { return }
        NSColor.systemRed.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
