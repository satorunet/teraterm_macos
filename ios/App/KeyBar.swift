import UIKit

/// キーボードの上に出すキーの列 (Esc・Ctrl・Tab・矢印・記号)。横に流せる
final class KeyBar: UIInputView {
    private weak var term: TerminalView?
    private var ctrlButton: UIButton!
    private var altButton: UIButton!

    init(term: TerminalView) {
        self.term = term
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])
        let keys: [(String, () -> Void)] = [
            ("Esc", { [weak self] in self?.term?.sendSpecial(.esc) }),
            ("Ctrl", { [weak self] in guard let t = self?.term else { return }; t.ctrlLatched.toggle() }),
            ("Alt", { [weak self] in guard let t = self?.term else { return }; t.altLatched.toggle() }),
            ("Tab", { [weak self] in self?.term?.sendSpecial(.tab) }),
            ("←", { [weak self] in self?.term?.sendSpecial(.left) }),
            ("↓", { [weak self] in self?.term?.sendSpecial(.down) }),
            ("↑", { [weak self] in self?.term?.sendSpecial(.up) }),
            ("→", { [weak self] in self?.term?.sendSpecial(.right) }),
            ("|", { [weak self] in self?.term?.insertText("|") }),
            ("/", { [weak self] in self?.term?.insertText("/") }),
            ("-", { [weak self] in self?.term?.insertText("-") }),
            ("~", { [weak self] in self?.term?.insertText("~") }),
            (":", { [weak self] in self?.term?.insertText(":") }),
            ("Home", { [weak self] in self?.term?.sendSpecial(.home) }),
            ("End", { [weak self] in self?.term?.sendSpecial(.end) }),
            ("PgUp", { [weak self] in self?.term?.sendSpecial(.pageUp) }),
            ("PgDn", { [weak self] in self?.term?.sendSpecial(.pageDown) }),
            ("^C", { [weak self] in self?.term?.send([3]) }),
            ("^D", { [weak self] in self?.term?.send([4]) }),
            ("^Z", { [weak self] in self?.term?.send([26]) }),
        ]
        for (t, f) in keys {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.gray()
            cfg.title = t
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            cfg.baseForegroundColor = .label
            b.configuration = cfg
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            b.addAction(UIAction { _ in f() }, for: .touchUpInside)
            b.accessibilityLabel = t
            stack.addArrangedSubview(b)
            if t == "Ctrl" { ctrlButton = b }
            if t == "Alt" { altButton = b }
        }
        // キーボードをしまう
        let hide = UIButton(type: .system)
        hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hide.addAction(UIAction { [weak self] _ in self?.term?.resignFirstResponder() }, for: .touchUpInside)
        hide.accessibilityLabel = "キーボードを閉じる"
        stack.addArrangedSubview(hide)
        term.onModifierChange = { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Ctrl・Alt を押している間は色を付ける
    func refresh() {
        for (b, on) in [(ctrlButton, term?.ctrlLatched ?? false), (altButton, term?.altLatched ?? false)] {
            guard let b = b else { continue }
            var cfg = on ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            cfg.title = b.configuration?.title
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            if !on { cfg.baseForegroundColor = .label }
            b.configuration = cfg
        }
    }
}
