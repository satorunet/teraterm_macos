import UIKit

/// SSH の確認・認証を画面で聞く (SSH の糸から呼ばれる。押されるまで待つ)
final class SSHAlertAsker: SSH2Asker {
    private weak var presenter: UIViewController?
    init(presenter: UIViewController) { self.presenter = presenter }

    /// 主の糸でダイアログを出して、答えが出るまで待つ
    private func wait<T>(_ fallback: T, _ build: @escaping (@escaping (T) -> Void) -> UIAlertController) -> T {
        let sem = DispatchSemaphore(value: 0)
        var result = fallback
        DispatchQueue.main.async {
            guard let p = self.presenter else { sem.signal(); return }
            let a = build { r in result = r; sem.signal() }
            (p.presentedViewController ?? p).present(a, animated: true)
        }
        sem.wait()
        return result
    }

    func confirmHostKey(host: String, port: Int, fingerprint: String, keyType: String, mismatch: Bool) -> (proceed: Bool, add: Bool) {
        wait((false, false)) { done in
            let msg = mismatch
                ? "⚠️ \(host) の鍵が、前に覚えたものと違います。なりすましのおそれがあります。\n\n\(keyType)\n\(fingerprint)"
                : "\(host):\(port) に初めてつなぎます。鍵の指紋を確かめてください。\n\n\(keyType)\n\(fingerprint)"
            let a = UIAlertController(title: mismatch ? "ホスト鍵が違います" : "ホスト鍵の確認", message: msg, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: mismatch ? "上書きしてつなぐ" : "覚えてつなぐ", style: mismatch ? .destructive : .default) { _ in done((true, true)) })
            a.addAction(UIAlertAction(title: "今回だけつなぐ", style: .default) { _ in done((true, false)) })
            a.addAction(UIAlertAction(title: "やめる", style: .cancel) { _ in done((false, false)) })
            return a
        }
    }

    func askAuth(user: String, host: String, methods: [String], failed: Bool, keyFile: String) -> SSH2AuthAnswer? {
        let keys = ((try? FileManager.default.contentsOfDirectory(atPath: SPPaths.keysDir)) ?? [])
            .filter { !$0.hasSuffix(".pub") && !$0.hasPrefix(".") }.sorted()
        return wait(nil) { done in
            var msg = failed ? "認証に失敗しました。もう一度入れてください。\n" : ""
            msg += "\(host)  (方法: \(methods.joined(separator: ", ")))"
            if methods.contains("publickey") && keys.isEmpty {
                msg += "\n\n鍵で入るときは、ファイル App の「Tera Term SP > keys」に秘密鍵を置いてください。"
            }
            let a = UIAlertController(title: "SSH 認証", message: msg, preferredStyle: .alert)
            a.addTextField { $0.placeholder = "ユーザー名"; $0.text = user; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
            a.addTextField { $0.placeholder = "パスワード / 鍵のパスフレーズ"; $0.isSecureTextEntry = true }
            let u: () -> String = { a.textFields?[0].text ?? user }
            let s: () -> String = { a.textFields?[1].text ?? "" }
            if methods.contains("password") || methods.isEmpty {
                a.addAction(UIAlertAction(title: "パスワードで入る", style: .default) { _ in
                    done(SSH2AuthAnswer(method: .password, user: u(), secret: s(), keyFile: "")) })
            }
            if methods.contains("publickey") {
                for k in keys.prefix(4) {
                    a.addAction(UIAlertAction(title: "鍵 \(k) で入る", style: .default) { _ in
                        done(SSH2AuthAnswer(method: .publicKey, user: u(), secret: s(), keyFile: SPPaths.keysDir + "/" + k)) })
                }
            }
            if methods.contains("keyboard-interactive") {
                a.addAction(UIAlertAction(title: "チャレンジレスポンス", style: .default) { _ in
                    done(SSH2AuthAnswer(method: .keyboardInteractive, user: u(), secret: "", keyFile: "")) })
            }
            a.addAction(UIAlertAction(title: "やめる", style: .cancel) { _ in done(nil) })
            return a
        }
    }

    func askChallenge(name: String, instruction: String, prompts: [(text: String, echo: Bool)]) -> [String]? {
        wait(nil) { done in
            let a = UIAlertController(title: name.isEmpty ? "SSH 認証" : name, message: instruction.isEmpty ? nil : instruction, preferredStyle: .alert)
            for p in prompts { a.addTextField { $0.placeholder = p.text; $0.isSecureTextEntry = !p.echo; $0.autocapitalizationType = .none } }
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in done(a.textFields?.map { $0.text ?? "" } ?? []) })
            a.addAction(UIAlertAction(title: "やめる", style: .cancel) { _ in done(nil) })
            return a
        }
    }

    /// iPhone には ~/.ssh はない (鍵は keys フォルダ)
    func askSSHFolder() -> Bool { false }
}
