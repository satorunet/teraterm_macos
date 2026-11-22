import Foundation
import TeraCore

/// 使っているキーマップ (keyboard.c の KeyMap)。
/// キーボード設定ファイル (TermSettings.keyCnfFileName、既定は設定フォルダの KEYBOARD.CNF) を読む。
/// 「キーマップ読み込み」でファイルを選び直したときや、ファイルを書き換えたときは次のキー入力で読み直す。
/// ファイルがなければ、Tera Term が KEYBOARD.CNF として入れる IBMKEYB.CNF と同じものを使う。
///
/// Mac のキー → Tera Term のキーコード (TTKeyMap.macToScan):
///  - 文字キーは PC (106/101) の同じ位置のキーのスキャンコード。Option = Alt (+2048)、⌘ は使わない (メニュー用)
///  - 矢印・home・end・page up/down・前方削除 (⌦) は PC の拡張キー (328 など)。help キーは Insert (338)
///  - F1〜F12 は 59〜68, 87, 88。F13〜F20 は Windows の VK_F13〜VK_F20 と同じ 100〜107
///  - テンキーは刻印で対応 (clear = NumLock 325、/ = 309、* = 55、- = 74、+ = 78、enter = 284、= = 89)
///  - JIS の ¥ = 125、_ (ろ) = 115
enum KeyMapStore {
    private static var cached: TTKeyMap?
    private static var cachedPath: String?
    private static var cachedDate: Date?

    static var current: TTKeyMap {
        let p = TermSettings.keyCnfFileName
        let date = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        if cached == nil || p != cachedPath || date != cachedDate {
            cachedPath = p
            cachedDate = date
            if date == nil {
                cached = .ibmDefault
            } else {
                // 読めないファイルは Tera Term と同じく何も割り当てない
                cached = TTKeyMap(path: p) ?? TTKeyMap()
            }
        }
        return cached!
    }
}
