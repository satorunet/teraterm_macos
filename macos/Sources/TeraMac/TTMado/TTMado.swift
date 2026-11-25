import AppKit
import TeraCore

// MARK: - TTMado: タブ・窓割り (Mac 版だけの組み込みプラグイン)

/// タブ・窓割りの機能 (タブの分割表示・合体・ドラッグでの並べ替え) をまとめた組み込みプラグイン。
/// 設定の「プラグイン」タブで入/切できる (再起動はいらない)。切ると macOS のふつうのタブと同じ動きになる。
///
/// このフォルダ (TTMado/) の中身:
/// - TabSplit.swift: 分割表示 (TabSplit・ペイン・見出し・≡ メニュー・ドラッグの行き先と見本)、タブの印 (TabMarks)
/// - TabTearOff.swift: 引き出したタブ・ウインドウのドラッグ (元のウインドウに戻す・ほかのウインドウに入れる)、
///   タブのバーからのドラッグ (TabBarDrag)、見えないままの受け渡し (HiddenHandoff)
/// - TTMado.swift: この入口 (isEnabled / install / uninstall / setEnabled)
///
/// アプリのほかの所からは、TTMado.isEnabled を見てから使う (ウインドウの移動・新しい接続の開き方・複製・並べて表示)。
enum TTMado {
    /// 設定のキー (UserDefaults)。ないときは入
    static let defaultsKey = "TTMadoEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// 起動時 (入のとき): タブの Shift+クリックの見張り、タブ・ウインドウのドラッグの見張りを始める
    static func install() {
        TabMarks.install()
        TabTearOff.install()
    }

    /// 切るとき: 分割を全部やめてタブに戻し、印を消し、見張り・タイマー・見本を止めて、引き出した元のウインドウを忘れる
    static func uninstall() {
        defer { PaneCountBadge.refreshAll() }
        TabSplit.unsplitAll()
        TabSplit.all.forEach { $0.clearPaneMarks() }
        TabMarks.uninstall()
        TabTearOff.uninstall()
        for c in SessionWindowController.all {
            c.paneMarked = false
            c.updateTitle()
        }
    }

    /// 入/切を変える (すぐに効く)
    static func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        UserDefaults.standard.set(on, forKey: defaultsKey)
        if on { install() } else { uninstall() }
    }

    /// 設定の「プラグイン」タブに出す説明
    static var title: String { "TTMado" }
    static var summary: String { Lang.m("PLUGIN_TTMADO_DESC", "タブ・窓割り (タブの分割表示・合体・ドラッグでの並べ替え)") }
}
