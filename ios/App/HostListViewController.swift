import UIKit

/// 接続先の一覧 (TeraTerm Menu にあたる)。押すとつなぐ、i で編集、上の欄ですぐつなぐ
final class HostListViewController: UITableViewController, UISearchBarDelegate {
    private var hosts: [SPHost] = []
    private let quick = UISearchBar()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tera Term SP"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.edit(nil) }),
            UIBarButtonItem(title: "Mac と連携", image: UIImage(systemName: "laptopcomputer.and.iphone"),
                            primaryAction: UIAction { _ in (UIApplication.shared.delegate as? AppDelegate)?.showLink() }),
        ]
        navigationItem.leftBarButtonItem = editButtonItem
        quick.placeholder = "すぐつなぐ: ssh user@host:22 / telnet host"
        quick.autocapitalizationType = .none
        quick.autocorrectionType = .no
        quick.searchBarStyle = .minimal
        quick.setImage(UIImage(systemName: "bolt.horizontal"), for: .search, state: .normal)
        quick.returnKeyType = .go
        quick.delegate = self
        quick.sizeToFit()
        tableView.tableHeaderView = quick
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hosts = SPHostStore.all
        tableView.reloadData()
    }

    func searchBarSearchButtonClicked(_ bar: UISearchBar) {
        guard let h = SPHost.parse(bar.text ?? "") else { return }
        bar.resignFirstResponder()
        open(h)
    }

    private func open(_ h: SPHost) {
        navigationController?.pushViewController(SessionViewController(host: h), animated: true)
    }

    private func edit(_ h: SPHost?) {
        let e = HostEditViewController(host: h ?? SPHost())
        e.onSave = { [weak self] in self?.hosts = SPHostStore.all; self?.tableView.reloadData() }
        present(UINavigationController(rootViewController: e), animated: true)
    }

    // MARK: 表

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, hosts.count) }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { "接続先" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "SSH の鍵は ファイル App の「このiPhone内 > Tera Term SP > keys」に、マクロ (.ttl) は「macros」に置きます。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard !hosts.isEmpty else {
            c.textLabel?.text = "＋ で接続先を足してください"
            c.textLabel?.textColor = .secondaryLabel
            c.selectionStyle = .none
            return c
        }
        let h = hosts[indexPath.row]
        c.textLabel?.text = h.title
        c.detailTextLabel?.text = h.subtitle + (h.macro.isEmpty ? "" : "  ▶︎ " + h.macro)
        c.detailTextLabel?.textColor = .secondaryLabel
        c.imageView?.image = UIImage(systemName: h.proto == .ssh ? "lock.shield" : "network")
        c.accessoryType = .detailButton
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !hosts.isEmpty else { return }
        open(hosts[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        edit(hosts[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { !hosts.isEmpty }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        SPHostStore.remove(hosts[indexPath.row])
        hosts = SPHostStore.all
        if hosts.isEmpty { tableView.reloadData() } else { tableView.deleteRows(at: [indexPath], with: .automatic) }
    }
    override func tableView(_ tableView: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
        let h = hosts.remove(at: from.row)
        hosts.insert(h, at: to.row)
        SPHostStore.all = hosts
    }
}

/// 接続先の編集
final class HostEditViewController: UITableViewController, UITextFieldDelegate {
    private var host: SPHost
    var onSave: (() -> Void)?
    private var password: String
    private let protoControl = UISegmentedControl(items: ["SSH", "Telnet"])

    init(host: SPHost) {
        self.host = host
        password = Keychain.get(host.id) ?? ""
        super.init(style: .insetGrouped)
        title = host.host.isEmpty ? "新しい接続先" : "接続先の編集"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() })
        protoControl.selectedSegmentIndex = host.proto == .ssh ? 0 : 1
        protoControl.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            let old = self.host.proto
            self.host.proto = self.protoControl.selectedSegmentIndex == 0 ? .ssh : .telnet
            if self.host.port == SPHost.defaultPort[old] { self.host.port = SPHost.defaultPort[self.host.proto] ?? 22 }
            self.tableView.reloadData()
        }, for: .valueChanged)
    }

    private enum Row: Int, CaseIterable { case name, host, port, user, password, macro }
    private func label(_ r: Row) -> String {
        ["名前", "ホスト", "ポート", "ユーザー", "パスワード", "マクロ"][r.rawValue]
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : Row.allCases.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? "パスワードはこの端末のキーチェーンに保存します (空なら、つなぐときに聞きます)。マクロは macros フォルダのファイル名で、つないだあとに動かします。" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let c = UITableViewCell(style: .default, reuseIdentifier: nil)
        c.selectionStyle = .none
        if indexPath.section == 0 {
            protoControl.translatesAutoresizingMaskIntoConstraints = false
            c.contentView.addSubview(protoControl)
            NSLayoutConstraint.activate([
                protoControl.leadingAnchor.constraint(equalTo: c.contentView.layoutMarginsGuide.leadingAnchor),
                protoControl.trailingAnchor.constraint(equalTo: c.contentView.layoutMarginsGuide.trailingAnchor),
                protoControl.centerYAnchor.constraint(equalTo: c.contentView.centerYAnchor),
            ])
            return c
        }
        let r = Row(rawValue: indexPath.row)!
        let l = UILabel()
        l.text = label(r)
        l.font = .systemFont(ofSize: 16)
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let f = UITextField()
        f.tag = r.rawValue
        f.delegate = self
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.clearButtonMode = .whileEditing
        f.addAction(UIAction { [weak self, weak f] _ in self?.changed(r, f?.text ?? "") }, for: .editingChanged)
        switch r {
        case .name: f.text = host.name; f.placeholder = "(なければホスト名)"
        case .host: f.text = host.host; f.placeholder = "example.com / 192.168.0.1"; f.keyboardType = .URL
        case .port: f.text = String(host.port); f.keyboardType = .numberPad
        case .user: f.text = host.user; f.placeholder = host.proto == .ssh ? "root など" : "(Telnet では使いません)"
        case .password: f.text = password; f.isSecureTextEntry = true; f.placeholder = "(つなぐときに聞く)"; f.isEnabled = host.proto == .ssh
        case .macro: f.text = host.macro; f.placeholder = "login.ttl など (なし)"
        }
        let st = UIStackView(arrangedSubviews: [l, f])
        st.spacing = 8
        st.translatesAutoresizingMaskIntoConstraints = false
        c.contentView.addSubview(st)
        NSLayoutConstraint.activate([
            st.leadingAnchor.constraint(equalTo: c.contentView.layoutMarginsGuide.leadingAnchor),
            st.trailingAnchor.constraint(equalTo: c.contentView.layoutMarginsGuide.trailingAnchor),
            st.topAnchor.constraint(equalTo: c.contentView.topAnchor, constant: 11),
            st.bottomAnchor.constraint(equalTo: c.contentView.bottomAnchor, constant: -11),
        ])
        return c
    }

    private func changed(_ r: Row, _ s: String) {
        let v = s.trimmingCharacters(in: .whitespaces)
        switch r {
        case .name: host.name = v
        case .host: host.host = v
        case .port: host.port = Int(v) ?? host.port
        case .user: host.user = v
        case .password: password = s
        case .macro: host.macro = v
        }
    }

    private func save() {
        view.endEditing(true)
        guard !host.host.isEmpty else {
            let a = UIAlertController(title: "ホストを入れてください", message: nil, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
            return
        }
        SPHostStore.save(host)
        Keychain.set(host.proto == .ssh ? password : nil, for: host.id)
        onSave?()
        dismiss(animated: true)
    }
}
