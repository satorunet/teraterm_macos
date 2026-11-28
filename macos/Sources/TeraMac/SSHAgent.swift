import AppKit
import TeraCore

/// SSH エージェント (Pageant にあたるもの) のソケット。Mac だけの設定。
/// Finder から起動したアプリにはシェルで設定した SSH_AUTH_SOCK が届かないので、
/// 1Password などのエージェントは ssh の IdentityAgent でソケットを直接教える。
enum SSHAgent {
    /// 1Password の SSH エージェント (1Password の設定 > 開発者 > SSH エージェント)
    static let onePasswordSocket = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

    static func expand(_ p: String) -> String { (p.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }

    static var onePasswordAvailable: Bool { FileManager.default.fileExists(atPath: expand(onePasswordSocket)) }

    static func isOnePassword(_ p: String) -> Bool { !p.isEmpty && expand(p) == expand(onePasswordSocket) }

    /// ssh に足す引数。空 (既定) なら何も足さない (~/.ssh/config の IdentityAgent か SSH_AUTH_SOCK に従う)
    static func sshArgs(_ socket: String) -> [String] {
        let s = socket.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return [] }
        // 1Password のパスには空白があるので "" で囲む (ssh の設定の書き方)
        return ["-o", "IdentityAgent=\"\(expand(s))\""]
    }
}

/// 「ソケット: [既定 ▾]」と、その他のときだけ下に出るパスの欄 (接続先の編集と SSH 認証設定で使う)
final class SSHAgentSocketPicker: NSStackView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pathField = NSTextField()
    /// パスを選ぶ (接続先の編集の鍵ファイルの「…」と同じ)
    private let chooseButton = NSButton(title: "…", target: nil, action: nil)
    private let pathRow = NSStackView()
    /// その他で入れたパス (既定・1Password を選んでいるあいだも覚えておく)
    private var customPath = ""
    var onChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let label = NSTextField(labelWithString: Lang.m("SSH_AGENT_SOCKET", "ソケット:"))
        popup.addItems(withTitles: [
            Lang.m("SSH_AGENT_DEFAULT2", "既定"),
            "1Password",
            Lang.m("SSH_AGENT_OTHER2", "任意path指定する"),
        ])
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.toolTip = Lang.m("SSH_AGENT_SOCKET_TIP", "公開鍵認証で使う SSH エージェント。1Password は 1Password の設定 > 開発者 で SSH エージェントを有効にしてください")
            + "\n" + Lang.m("SSH_AGENT_DEFAULT2", "既定") + ": " + Lang.m("SSH_AGENT_DEFAULT_HINT", "~/.ssh/config の IdentityAgent か SSH_AUTH_SOCK を使います")
        pathField.placeholderString = "~/path/to/agent.sock"
        pathField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        pathField.lineBreakMode = .byTruncatingMiddle
        // 横に並べると長くなりすぎるので、パスは下の行に (ポップアップの左端にそろえる)。
        // 選び直しても高さが変わらないように、パスの行はいつも出しておき、その他のときだけ入力できる
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 6
        addArrangedSubview(row)
        chooseButton.target = self
        chooseButton.action = #selector(choosePath(_:))
        pathRow.orientation = .horizontal
        pathRow.spacing = 6
        pathRow.addArrangedSubview(pathField)
        pathRow.addArrangedSubview(chooseButton)
        addArrangedSubview(pathRow)
        pathRow.leadingAnchor.constraint(equalTo: popup.leadingAnchor).isActive = true
        update1PasswordTitle()
        popupChanged(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 1Password のエージェントがなければ「(見つかりません)」と付ける
    private func update1PasswordTitle() {
        popup.item(at: 1)?.title = SSHAgent.onePasswordAvailable
            ? "1Password" : "1Password " + Lang.m("SSH_AGENT_NOT_FOUND", "(見つかりません)")
    }

    var socket: String {
        get {
            switch popup.indexOfSelectedItem {
            case 1: return SSHAgent.onePasswordSocket
            case 2: return customPathNow.trimmingCharacters(in: .whitespaces)
            default: return ""
            }
        }
        set {
            update1PasswordTitle()
            if newValue.isEmpty { popup.selectItem(at: 0); customPath = "" }
            else if SSHAgent.isOnePassword(newValue) { popup.selectItem(at: 1); customPath = "" }
            else { popup.selectItem(at: 2); customPath = newValue }
            shownIndex = -1
            popupChanged(nil)
        }
    }

    var isEnabled: Bool = true {
        didSet { popup.isEnabled = isEnabled; updatePathRow() }
    }

    /// いまパスの欄に出している選択 (その他から離れるとき、入れたパスを覚えておくため)
    private var shownIndex = -1
    private var customPathNow: String { shownIndex == 2 ? pathField.stringValue : customPath }

    @objc private func popupChanged(_ sender: Any?) {
        if shownIndex == 2 { customPath = pathField.stringValue }
        updatePathRow()
        if sender != nil, popup.indexOfSelectedItem == 2 { window?.makeFirstResponder(pathField) }
        onChange?()
    }

    /// パスの欄: 既定・1Password では使うソケットを薄く見せるだけ、その他では入力できる
    private func updatePathRow() {
        let i = popup.indexOfSelectedItem
        shownIndex = i
        switch i {
        case 1:
            pathField.stringValue = SSHAgent.onePasswordSocket
            pathField.placeholderString = nil
        case 2:
            pathField.stringValue = customPath
            pathField.placeholderString = "~/path/to/agent.sock"
        default:
            // 既定: どこを見るかだけ短く (くわしくはポップアップのツールチップ)
            pathField.stringValue = ""
            pathField.placeholderString = "~/.ssh/config・SSH_AUTH_SOCK"
        }
        let editable = isEnabled && i == 2
        pathField.isEnabled = editable
        pathField.isEditable = editable
        chooseButton.isEnabled = editable
    }

    /// ソケットを選ぶ。ソケットはファイルとして選べないことがあるので、フォルダを選んだら中のソケットを探す
    @objc private func choosePath(_ sender: Any?) {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.showsHiddenFiles = true
        p.treatsFilePackagesAsDirectories = true
        p.prompt = Lang.m("SSH_AGENT_CHOOSE", "選択")
        p.message = Lang.m("SSH_AGENT_CHOOSE_MSG", "エージェントのソケット (agent.sock など) か、それが入っているフォルダを選んでください")
        let cur = SSHAgent.expand(pathField.stringValue)
        let start = cur.isEmpty ? NSHomeDirectory() + "/.ssh" : (cur as NSString).deletingLastPathComponent
        p.directoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: start) ? start : NSHomeDirectory())
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let u = p.url, let self = self else { return }
            var path = u.path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
               let s = Self.findSocket(in: path) { path = s }
            self.pathField.stringValue = Self.abbreviate(path)
            self.customPath = self.pathField.stringValue
            self.onChange?()
        }
        if let w = window { p.beginSheetModal(for: w, completionHandler: done) } else { done(p.runModal()) }
    }

    private static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    /// フォルダの中 (1 段下まで) のソケット。agent.sock を優先
    private static func findSocket(in dir: String) -> String? {
        let fm = FileManager.default
        var found: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let p = (dir as NSString).appendingPathComponent(name)
            if isSocket(p) { found.append(p); continue }
            var d: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &d), d.boolValue {
                for n2 in (try? fm.contentsOfDirectory(atPath: p)) ?? [] {
                    let p2 = (p as NSString).appendingPathComponent(n2)
                    if isSocket(p2) { found.append(p2) }
                }
            }
        }
        return found.first { $0.hasSuffix("/agent.sock") } ?? found.sorted().first
    }

    /// ホームは ~ で書く (ほかの Mac に設定を移しても使えるように)
    private static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
