import AppKit
import Carbon
import TeraCore

/// セキュアキーボード入力 (Terminal.app・iTerm2 と同じ)。入のあいだ、ほかのアプリがキー入力を読めなくなる。
/// macOS の EnableSecureEventInput は回数で数えるので、アプリが前に来たら 1 回入れ、後ろに回ったら 1 回切る
/// (後ろにいるあいだまで効かせると、ほかのアプリの日本語入力などが使えなくなるため)。
final class SecureInput: NSObject, NSMenuItemValidation {
    static let shared = SecureInput()
    private static let key = "TeraMacSecureKeyboardEntry"
    private var applied = false

    var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set { UserDefaults.standard.set(newValue, forKey: Self.key); apply() }
    }

    /// 起動時に一度呼ぶ
    func install() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appChanged(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appChanged(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        apply()
    }

    @objc private func appChanged(_ n: Notification) { apply() }

    private func apply() {
        let want = isOn && NSApp.isActive
        guard want != applied else { return }
        if want { EnableSecureEventInput() } else { DisableSecureEventInput() }
        applied = want
    }

    func menuItem() -> NSMenuItem {
        let it = NSMenuItem(title: Lang.m("MENU_APP_SECURE_INPUT", "セキュアキーボード入力"),
                            action: #selector(toggle(_:)), keyEquivalent: "")
        it.target = self
        return it
    }

    @objc func toggle(_ sender: Any?) { isOn.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggle(_:)) { item.state = isOn ? .on : .off }
        return true
    }
}
