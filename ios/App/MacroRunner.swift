import UIKit
import TeraCore

/// TTL マクロを動かす (TeraCore の TTLInterpreter。Mac 版 MacroRunner の iPhone 版)。
/// マクロは専用の糸で動き、画面やダイアログは主の糸で出して答えを待つ
final class MacroRunner: NSObject, TTLHost {
    private weak var session: SessionViewController?
    private let terminal: Terminal
    private var interp: TTLInterpreter?
    var onFinish: (() -> Void)?

    init(session: SessionViewController, terminal: Terminal) {
        self.session = session
        self.terminal = terminal
    }

    func start(path: String, connected: Bool) {
        let t = Thread { [weak self] in
            guard let self = self else { return }
            do {
                let i = try TTLInterpreter(path: path, host: self)
                self.interp = i
                i.setComReady(connected)
                try i.run()
            } catch {
                let msg = error.localizedDescription
                _ = self.onMain { self.alert(title: "マクロ", message: msg, buttons: ["OK"]) }
            }
            DispatchQueue.main.async { self.onFinish?() }
        }
        t.stackSize = 8 << 20
        t.start()
    }

    func cancel() { interp?.cancelled = true }
    /// 受け取った文字 (wait などのため)
    func received(_ b: [UInt8]) { interp?.feed(b) }
    func connectionChanged(_ on: Bool) { interp?.setComReady(on) }

    // MARK: 主の糸で動かして答えを待つ

    private func onMain<T>(_ f: @escaping () -> T) -> T {
        if Thread.isMainThread { return f() }
        var r: T!
        DispatchQueue.main.sync { r = f() }
        return r
    }

    /// ボタンを並べたダイアログ (押したボタンの番号)。fields があれば入力欄も
    private func alert(title: String, message: String, buttons: [String], field: (text: String, secret: Bool)? = nil,
                       done: ((Int, String) -> Void)? = nil) -> Int {
        // 主の糸から呼ばれる。答えが出るまで待つため、マクロの糸から呼ぶときは ask を使う
        guard let vc = session else { return -1 }
        let a = UIAlertController(title: title.isEmpty ? "Tera Term SP" : title, message: message, preferredStyle: .alert)
        if let f = field {
            a.addTextField { tf in tf.text = f.text; tf.isSecureTextEntry = f.secret; tf.autocapitalizationType = .none; tf.autocorrectionType = .no }
        }
        for (i, b) in buttons.enumerated() {
            a.addAction(UIAlertAction(title: b, style: i == buttons.count - 1 && buttons.count > 1 ? .cancel : .default) { _ in
                done?(i, a.textFields?.first?.text ?? "")
            })
        }
        (vc.presentedViewController ?? vc).present(a, animated: true)
        return 0
    }

    /// マクロの糸から: ダイアログを出して、押されるまで待つ
    private func ask(title: String, message: String, buttons: [String], field: (text: String, secret: Bool)? = nil) -> (Int, String) {
        let sem = DispatchSemaphore(value: 0)
        var result = (-1, "")
        DispatchQueue.main.async {
            if self.session == nil { sem.signal(); return }
            _ = self.alert(title: title, message: message, buttons: buttons, field: field) { i, s in result = (i, s); sem.signal() }
        }
        sem.wait()
        return result
    }

    // MARK: TTLHost

    func ttlSend(_ bytes: [UInt8], mode: TTLSendMode) {
        DispatchQueue.main.async { self.session?.macroSend(bytes) }
    }

    func ttlIsConnected() -> Bool { onMain { self.session?.connected ?? false } }
    func ttlDisconnect(confirm: Bool) { DispatchQueue.main.async { self.session?.macroDisconnect() } }
    func ttlGetHostname() -> String? { onMain { self.session?.hostName } }

    func ttlDispStr(_ bytes: [UInt8]) {
        let s = String(decoding: bytes, as: UTF8.self)
        DispatchQueue.main.async { self.terminal.feed(s) }
    }
    func ttlBeep(_ type: Int) { DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
    func ttlSetTitle(_ s: String) { DispatchQueue.main.async { self.session?.title = s } }
    func ttlGetTitle() -> String { onMain { self.session?.title ?? "" } }
    func ttlClearScreen(_ mode: Int) { DispatchQueue.main.async { self.terminal.clearScreen() } }
    func ttlGetClipboard() -> String? { onMain { UIPasteboard.general.string } }
    func ttlSetClipboard(_ s: String) -> Bool { onMain { UIPasteboard.general.string = s }; return true }
    func ttlAppDirectory() -> String { SPPaths.macrosDir }

    func ttlMessageBox(_ text: String, title: String) -> Bool {
        ask(title: title, message: text, buttons: ["OK", "中断"]).0 == 0
    }
    func ttlInputBox(_ text: String, title: String, defaultValue: String, secret: Bool) -> String? {
        let (i, s) = ask(title: title, message: text, buttons: ["OK", "キャンセル"], field: (defaultValue, secret))
        return i == 0 ? s : nil
    }
    func ttlYesNoBox(_ text: String, title: String) -> Int {
        ask(title: title, message: text, buttons: ["はい", "いいえ"]).0 == 0 ? 1 : 0
    }
    func ttlStatusBox(_ text: String, title: String) {
        DispatchQueue.main.async { self.session?.navigationItem.prompt = text.isEmpty ? nil : text }
    }
    func ttlCloseStatus() { DispatchQueue.main.async { self.session?.navigationItem.prompt = nil } }

    func ttlError(message: String, line: Int, lineText: String, file: String, range: Range<Int>) -> Bool {
        let name = (file as NSString).lastPathComponent
        _ = ask(title: "マクロのエラー", message: "\(message)\n\(name) \(line) 行目\n\(lineText)", buttons: ["OK"])
        return true
    }
}
