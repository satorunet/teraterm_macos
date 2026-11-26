import AppKit
import ObjectiveC

/// 英数字だけを入れる欄 (ユーザー名・パスワード・ホスト・ポート・数値など):
/// その欄に入ったら入力ソースを英字 (ローマ字系) に切り替え、出たら元に戻す。
/// - asciiOnly を付けた欄
/// - パスワード欄 (NSSecureTextField)
/// - 中身が数字だけの欄 (ポート・速度・サイズなど) は自動で
enum AsciiInput {
    private static var key: UInt8 = 0
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = NSTextField.self
        guard let orig = class_getInstanceMethod(cls, #selector(NSResponder.becomeFirstResponder)),
              let repl = class_getInstanceMethod(cls, #selector(NSTextField.tt_asciiBecomeFirstResponder)) else { return }
        // NSTextField が自分で becomeFirstResponder を持っていないときは足してから入れ替える
        if class_addMethod(cls, #selector(NSResponder.becomeFirstResponder), method_getImplementation(repl), method_getTypeEncoding(repl)) {
            class_replaceMethod(cls, #selector(NSTextField.tt_asciiBecomeFirstResponder), method_getImplementation(orig), method_getTypeEncoding(orig))
        } else {
            method_exchangeImplementations(orig, repl)
        }
    }

    static func flag(_ f: NSTextField) -> Bool { (objc_getAssociatedObject(f, &key) as? Bool) ?? false }
    static func setFlag(_ f: NSTextField, _ v: Bool) { objc_setAssociatedObject(f, &key, v, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }

    static func wantsAscii(_ f: NSTextField) -> Bool {
        if flag(f) || f is NSSecureTextField || f.formatter is NumberFormatter { return true }
        let s = f.stringValue
        return !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

extension NSTextField {
    /// 英数字だけを入れる欄にする (入ったら入力ソースを英字にする)
    var asciiOnly: Bool {
        get { AsciiInput.flag(self) }
        set { AsciiInput.setFlag(self, newValue) }
    }

    @objc func tt_asciiBecomeFirstResponder() -> Bool {
        let ok = tt_asciiBecomeFirstResponder()   // 入れ替え後は元の becomeFirstResponder
        if ok, isEditable, let ctx = currentEditor()?.inputContext {
            ctx.allowedInputSourceLocales = AsciiInput.wantsAscii(self) ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
        }
        return ok
    }
}

extension NSTextField {
    /// 宣言でそのまま使う: `NSTextField().ascii()`
    @discardableResult func ascii() -> Self { asciiOnly = true; return self }
}

import Carbon

extension AsciiInput {
    /// 入力を英数字モードにする (「かな」のままでも英数に切り替える。日本語に戻すのは利用者が自由にできる)。
    /// ことえりなどの日本語入力なら同じ入力メソッドの英字モード (…Roman) に、なければ英字のキー配列にする
    static func switchToAlphanumeric() {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        if bool(cur, kTISPropertyInputSourceIsASCIICapable) { return }
        // 同じ入力メソッドの英字モード (例: com.apple.inputmethod.Kotoeri.RomajiTyping.Roman)
        if let bundle = string(cur, kTISPropertyBundleID) {
            let filter = [kTISPropertyBundleID as String: bundle, kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
            if let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
               let roman = list.first(where: { bool($0, kTISPropertyInputSourceIsASCIICapable) && bool($0, kTISPropertyInputSourceIsEnabled) }) {
                TISSelectInputSource(roman)
                return
            }
        }
        if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
            TISSelectInputSource(ascii)
        }
    }

    private static func bool(_ s: TISInputSource, _ key: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(s, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
    private static func string(_ s: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(s, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
}
