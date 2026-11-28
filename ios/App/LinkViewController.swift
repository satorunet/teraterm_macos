import UIKit
import Network
import TeraCore

/// 「Mac と連携」: 近くの Tera Term Mac を見つけて、接続先・開いている接続・マクロを取り込む。
/// インターネットや iCloud は使わない (同じ Wi-Fi か、近くならピアツーピア)
final class LinkViewController: UITableViewController {
    /// Mac の名前 → コード (QR コードで読んだもの・入れたもの)
    private static let codesKey = "TeraLinkCodes"
    static func saveCode(_ code: String, for mac: String) {
        var d = UserDefaults.standard.dictionary(forKey: codesKey) as? [String: String] ?? [:]
        d[mac] = code
        UserDefaults.standard.set(d, forKey: codesKey)
    }
    private static func code(for mac: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: codesKey) as? [String: String])?[mac]
    }

    private var browser: NWBrowser?
    private var macs: [NWBrowser.Result] = []
    /// QR コードから開いたとき: この Mac が見つかったらすぐつなぐ
    var autoConnectMac: String?

    private var channel: TeraLink.Channel?
    private var connectedMac: String?
    private var hosts: [TeraLink.Host] = []
    private var sessions: [TeraLink.Host] = []
    private var macros: [String] = []
    private var status = "近くの Mac を探しています…"
    /// 開いたら取り込むマクロ (file の答えを待っている)
    private var pendingMacros = Set<String>()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Mac と連携"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        startBrowsing()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            browser?.cancel(); channel?.cancel()
        }
    }

    // MARK: 探す

    private func startBrowsing() {
        let p = NWParameters()
        p.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: TeraLink.serviceType, domain: nil), using: p)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            self.macs = results.sorted { self.name(of: $0) < self.name(of: $1) }
            if self.channel == nil { self.status = self.macs.isEmpty ? "近くの Mac を探しています…" : "つなぐ Mac を選んでください" }
            self.tableView.reloadData()
            if let want = self.autoConnectMac, let r = self.macs.first(where: { self.name(of: $0) == want }) {
                self.autoConnectMac = nil
                self.connect(r)
            }
        }
        b.stateUpdateHandler = { [weak self] s in
            if case .failed(let e) = s { self?.status = "探せませんでした: \(e)"; self?.tableView.reloadData() }
        }
        b.start(queue: .main)
        browser = b
    }

    private func name(of r: NWBrowser.Result) -> String {
        if case let .service(name, _, _, _) = r.endpoint { return name }
        return "\(r.endpoint)"
    }

    // MARK: つなぐ

    private var retried = false
    private func connect(_ r: NWBrowser.Result, retry: Bool = false) {
        let mac = name(of: r)
        if !retry { retried = false }
        guard let code = Self.code(for: mac) else { return askCode(r) }
        channel?.cancel()
        hosts = []; sessions = []; macros = []
        status = "\(mac) につないでいます…"
        tableView.reloadData()
        let ch = TeraLink.Channel(NWConnection(to: r.endpoint, using: TeraLink.parameters(code: code)))
        ch.onState = { [weak self] s in
            guard let self = self else { return }
            switch s {
            case .ready:
                self.connectedMac = mac
                self.status = "\(mac) とつながりました"
                ["hosts", "sessions", "macros"].forEach { ch.send(TeraLink.Request(cmd: $0)) }
            case .failed, .waiting:
                // コードが違うと TLS が通らない
                self.status = "\(mac) につながりません (コードが違うか、Mac で連携が切になっています)"
                self.channel = nil
                ch.cancel()
            default: break
            }
            self.tableView.reloadData()
        }
        ch.onMessage = { [weak self] d in self?.handle(d) }
        channel = ch
        ch.start()
        // いくつかの経路を同時に試すので、閉じられた経路で待ち続けることがある。8 秒でつながらなければ 1 回つなぎ直す
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak ch] in
            guard let self = self, let ch = ch, self.channel === ch, self.connectedMac != mac || self.status.hasSuffix("…") else { return }
            if case .ready = ch.connection.state { return }
            ch.cancel()
            self.channel = nil
            if !self.retried { self.retried = true; self.connect(r, retry: true) }
            else { self.status = "\(mac) につながりません (Mac で連携が入になっているか確かめてください)"; self.tableView.reloadData() }
        }
    }

    private func askCode(_ r: NWBrowser.Result) {
        let mac = name(of: r)
        let a = UIAlertController(title: "\(mac) のコード",
                                  message: "Mac の Tera Term で「iPhone / iPad と連携…」を開き、出ている 6 けたのコードを入れてください (iPhone のカメラで QR コードを読んでも開けます)。",
                                  preferredStyle: .alert)
        a.addTextField { $0.keyboardType = .numberPad; $0.placeholder = "123456" }
        a.addAction(UIAlertAction(title: "つなぐ", style: .default) { [weak self] _ in
            let c = (a.textFields?.first?.text ?? "").filter(\.isNumber)
            guard c.count == 6 else { return }
            Self.saveCode(c, for: mac)
            self?.connect(r)
        })
        a.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        present(a, animated: true)
    }

    private func handle(_ d: Data) {
        guard let r = try? JSONDecoder().decode(TeraLink.Response.self, from: d) else { return }
        switch r.cmd {
        case "hosts": hosts = r.hosts ?? []
        case "sessions": sessions = r.sessions ?? []
        case "macros": macros = r.macros ?? []
        case "file":
            if let n = r.name, let f = r.file {
                let safe = (n as NSString).lastPathComponent
                try? f.write(to: URL(fileURLWithPath: SPPaths.macrosDir + "/" + safe))
                pendingMacros.remove(n)
                if pendingMacros.isEmpty { toast("マクロを取り込みました (macros フォルダ)") }
            }
        default: break
        }
        tableView.reloadData()
    }

    // MARK: 取り込む

    private func importHosts(_ list: [TeraLink.Host]) {
        var all = SPHostStore.all
        var added = 0
        for h in list {
            // 同じホスト・ポート・ユーザーのものはもう取り込んである
            if all.contains(where: { $0.host == h.host && $0.port == h.port && $0.user == h.user && $0.proto.rawValue == h.proto }) { continue }
            var s = SPHost()
            s.name = h.name; s.host = h.host; s.port = h.port; s.user = h.user
            s.proto = SPHost.Proto(rawValue: h.proto) ?? .ssh
            s.macro = h.macro
            all.append(s); added += 1
        }
        SPHostStore.all = all
        // 接続先が使うマクロも取ってくる
        let want = Set(list.map(\.macro).filter { !$0.isEmpty }).intersection(macros)
        fetchMacros(Array(want))
        toast(added == 0 ? "新しい接続先はありませんでした" : "接続先を \(added) 件取り込みました")
    }

    private func fetchMacros(_ names: [String]) {
        guard let ch = channel else { return }
        for n in names { pendingMacros.insert(n); ch.send(TeraLink.Request(cmd: "file", name: n)) }
    }

    private func toast(_ s: String) {
        let a = UIAlertController(title: nil, message: s, preferredStyle: .alert)
        present(a, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { a.dismiss(animated: true) }
    }

    // MARK: 表

    private enum Section: Int, CaseIterable { case macs, sessions, hosts, macros }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection s: Int) -> String? {
        switch Section(rawValue: s)! {
        case .macs: return "近くの Mac"
        case .sessions: return channel == nil ? nil : "Mac で開いている接続 (押すと続きを開く)"
        case .hosts: return channel == nil ? nil : "Mac の接続先 (TeraTerm Menu)"
        case .macros: return channel == nil ? nil : "Mac のマクロ"
        }
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection s: Int) -> String? {
        Section(rawValue: s) == .macs ? status + "\nMac の Tera Term で「iPhone / iPad と連携…」を開いて、受け付けるを入にしてください。インターネットや iCloud は使いません。" : nil
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection s: Int) -> Int {
        switch Section(rawValue: s)! {
        case .macs: return macs.count
        case .sessions: return channel == nil ? 0 : sessions.count
        case .hosts: return channel == nil ? 0 : hosts.count + (hosts.isEmpty ? 0 : 1)
        case .macros: return channel == nil ? 0 : macros.count + (macros.isEmpty ? 0 : 1)
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        c.detailTextLabel?.textColor = .secondaryLabel
        switch Section(rawValue: ip.section)! {
        case .macs:
            let n = name(of: macs[ip.row])
            c.textLabel?.text = n
            c.imageView?.image = UIImage(systemName: "desktopcomputer")
            c.detailTextLabel?.text = n == connectedMac && channel != nil ? "つながっています" : (Self.code(for: n) == nil ? "コードを入れてつなぐ" : "押すとつなぐ")
        case .sessions:
            let h = sessions[ip.row]
            c.textLabel?.text = h.name.isEmpty ? h.host : h.name
            c.detailTextLabel?.text = "\(h.proto.uppercased())  \(h.user.isEmpty ? "" : h.user + "@")\(h.host):\(h.port)"
            c.imageView?.image = UIImage(systemName: "arrow.right.circle")
        case .hosts:
            if ip.row == 0 {
                c.textLabel?.text = "すべて取り込む (\(hosts.count) 件)"
                c.textLabel?.textColor = tableView.tintColor
                c.imageView?.image = UIImage(systemName: "square.and.arrow.down.on.square")
            } else {
                let h = hosts[ip.row - 1]
                c.textLabel?.text = h.name.isEmpty ? h.host : h.name
                c.detailTextLabel?.text = "\(h.proto.uppercased())  \(h.user.isEmpty ? "" : h.user + "@")\(h.host):\(h.port)" + (h.macro.isEmpty ? "" : "  ▶︎ " + h.macro)
                c.imageView?.image = UIImage(systemName: "square.and.arrow.down")
            }
        case .macros:
            if ip.row == 0 {
                c.textLabel?.text = "すべて取り込む (\(macros.count) 件)"
                c.textLabel?.textColor = tableView.tintColor
                c.imageView?.image = UIImage(systemName: "square.and.arrow.down.on.square")
            } else {
                c.textLabel?.text = macros[ip.row - 1]
                c.imageView?.image = UIImage(systemName: "doc.text")
            }
        }
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch Section(rawValue: ip.section)! {
        case .macs: connect(macs[ip.row])
        case .sessions:
            // 続きを開く: この画面を閉じて、同じ接続先につなぐ
            let h = sessions[ip.row]
            var s = SPHost()
            s.name = h.name; s.host = h.host; s.port = h.port; s.user = h.user; s.proto = SPHost.Proto(rawValue: h.proto) ?? .ssh
            let nav = presentingViewController as? UINavigationController
            dismiss(animated: true) { nav?.pushViewController(SessionViewController(host: s), animated: true) }
        case .hosts: importHosts(ip.row == 0 ? hosts : [hosts[ip.row - 1]])
        case .macros: fetchMacros(ip.row == 0 ? macros : [macros[ip.row - 1]])
        }
    }
}
