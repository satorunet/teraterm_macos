import Foundation

/// 画面の言語。本家の言語ファイル (installer/release/lang_utf8/*.lng) をそのまま使う。
///
/// - 本家と同じ文言は `Lang.t("Tera Term", "MENU_FILE_NEW", "新しい接続...")` で引く (節とキーは本家の .lng と同じ)
/// - Mac 版だけの文言は `Lang.m("MENU_TOGGLE_MENUBAR", "メニューバーを開く")` で引く (Resources/lang/mac_<言語>.lng の [Tera Term Mac])
/// - 見つからないときは 選んだ言語 → 英語 (en_US) → 引数の既定 (日本語) の順に探す
/// - 返す文字列からは Windows のアクセスキー "(&F)" "&F" とショートカット "\tAlt+N" を外し、"\n" を改行にする
///
/// 言語は UserDefaults の UILanguageFile (本家の INI と同じ名前、例 "ja_JP.lng")。空なら macOS の言語設定から選ぶ
public enum Lang {
    public static let defaultsKey = "UILanguageFile"
    /// 言語が変わったとき (メニューを作り直すなど)
    public static let didChange = Notification.Name("TeraTermLanguageDidChange")

    public struct Language: Equatable {
        public let file: String        // "ja_JP.lng"
        public let name: String        // [Info] language= (例 "Japanese(日本語)")
        public var code: String { (file as NSString).deletingPathExtension }   // "ja_JP"
    }

    // MARK: 言語ファイルの場所

    /// アプリでは Contents/Resources/lang。開発中 (swift build) はソースの installer/release/lang_utf8 と macos/Resources/lang
    static var searchDirs: [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL?.appendingPathComponent("lang"),
           FileManager.default.fileExists(atPath: r.path) { dirs.append(r) }
        let src = URL(fileURLWithPath: #filePath)   // .../macos/Sources/TeraCore/Lang.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(src.appendingPathComponent("Resources/lang"))
        dirs.append(src.deletingLastPathComponent().appendingPathComponent("installer/release/lang_utf8"))
        return dirs
    }
    static func url(_ file: String) -> URL? {
        for d in searchDirs {
            let u = d.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
    static func load(_ file: String) -> IniFile? {
        guard let u = url(file), let d = try? Data(contentsOf: u) else { return nil }
        return IniFile(data: d)
    }

    /// 選べる言語 (本家の言語ファイル。Default.lng と mac_*.lng は除く)。名前の順
    public static let available: [Language] = {
        var seen = Set<String>(), r: [Language] = []
        for d in searchDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { continue }
            for f in files where f.hasSuffix(".lng") && !f.hasPrefix("mac_") && f != "Default.lng" && !seen.contains(f) {
                seen.insert(f)
                let name = load(f)?.string("Info", "language") ?? (f as NSString).deletingPathExtension
                r.append(Language(file: f, name: name))
            }
        }
        return r.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    // MARK: 選ぶ

    /// 利用者が選んだ言語 (nil = 自動)
    public static var chosen: String? {
        get {
            let v = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return v.isEmpty ? nil : (v as NSString).lastPathComponent   // 本家の "lang_utf8\ja_JP.lng" でもよい
        }
        set {
            UserDefaults.standard.set(newValue ?? "", forKey: defaultsKey)
            reload()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// macOS の言語設定 (優先順) から、いちばん近い言語ファイルを選ぶ。なければ英語
    public static func autoSelect(preferred: [String] = Locale.preferredLanguages) -> String {
        let files = Set(available.map(\.file))
        for p in preferred {
            // "zh-Hans-CN" "pt-BR" "ja-JP" "en" など
            let parts = p.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let lang = parts.first?.lowercased() else { continue }
            var cands: [String] = []
            if lang == "zh" {
                let tw = parts.contains { ["Hant", "TW", "HK", "MO"].contains($0) }
                cands = [tw ? "zh_TW.lng" : "zh_CN.lng"]
            } else {
                if parts.count > 1, let region = parts.last, region.count == 2 { cands.append("\(lang)_\(region.uppercased()).lng") }
                cands += files.filter { $0.hasPrefix(lang + "_") }.sorted()
            }
            if let f = cands.first(where: files.contains) { return f }
        }
        return files.contains("en_US.lng") ? "en_US.lng" : (available.first?.file ?? "en_US.lng")
    }

    /// 今使っている言語ファイル
    public private(set) static var current = chosen.flatMap { c in available.contains { $0.file == c } ? c : nil } ?? autoSelect()

    /// 引く順の表 (選んだ言語の本家・Mac 版 → 英語の本家・Mac 版)
    /// 各表は "節(小文字)\u{0}キー(小文字)" → 値 (速く引くため。同じキーは最初のもの)
    private static var tables: [[String: String]] = makeTables()
    private static func makeTables() -> [[String: String]] {
        let code = (current as NSString).deletingPathExtension
        var names = [current, "mac_\(code).lng"]
        if current != "en_US.lng" { names += ["en_US.lng", "mac_en_US.lng"] }
        return names.compactMap(load).map { ini in
            var d: [String: String] = [:]
            for sec in ini.sectionNames {
                for (k, v) in ini.keys(sec) where d[sec.lowercased() + "\u{0}" + k.lowercased()] == nil {
                    d[sec.lowercased() + "\u{0}" + k.lowercased()] = v
                }
            }
            return d
        }
    }
    public static func reload() {
        current = chosen.flatMap { c in available.contains { $0.file == c } ? c : nil } ?? autoSelect()
        tables = makeTables()
    }

    /// 日本語で表示しているか (ヘルプなど、日本語と英語しか無いものを選ぶとき)
    public static var isJapanese: Bool { current.hasPrefix("ja") }

    // MARK: 引く

    /// 本家の .lng の文言 (節, キー)。無ければ def
    public static func t(_ section: String, _ key: String, _ def: String) -> String {
        clean(raw(section, key) ?? def)
    }
    /// 本家の文言に printf 形式 (%s %d など) の値を順に入れる
    public static func t(_ section: String, _ key: String, _ def: String, _ args: CVarArg...) -> String {
        format(t(section, key, def), args)
    }
    /// Mac 版だけの文言 ([Tera Term Mac] 節)
    public static func m(_ key: String, _ def: String) -> String { t("Tera Term Mac", key, def) }
    public static func m(_ key: String, _ def: String, _ args: CVarArg...) -> String { format(m(key, def), args) }

    /// 手を加えない値 (アクセスキーなども残す)
    public static func raw(_ section: String, _ key: String) -> String? {
        let k = section.lowercased() + "\u{0}" + key.lowercased()
        for t in tables { if let v = t[k], !v.isEmpty { return v } }
        return nil
    }

    /// "(&F)" "&F" "\tAlt+N" を外し、"\n" "\t" を本物の改行・タブにする。"&&" は "&"
    public static func clean(_ s: String) -> String {
        var r = s
        if let tab = r.range(of: "\\t") { r = String(r[..<tab.lowerBound]) }   // メニューのショートカット表示
        r = r.replacingOccurrences(of: "\\([&＆][^)）]\\)|（[&＆][^)）]）", with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: "&&", with: "\u{1}")
        r = r.replacingOccurrences(of: "&", with: "")
        r = r.replacingOccurrences(of: "\u{1}", with: "&")
        r = r.replacingOccurrences(of: "\\n", with: "\n")
        return r
    }

    /// printf 形式の %s %d %u %ld %x などを、順に args で埋める (幅の指定は使わない)。%% は %
    public static func format(_ s: String, _ args: [CVarArg]) -> String {
        guard !args.isEmpty else { return s }
        var out = "", i = 0
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "%" else { out.append(c); continue }
            var spec = ""
            while let d = it.next() {
                spec.append(d)
                if d == "%" && spec.count == 1 { break }
                if "sdiuxXcfg@".contains(d) { break }
            }
            if spec == "%" { out.append("%"); continue }
            if i < args.count { out += "\(args[i])"; i += 1 } else { out += "%" + spec }
        }
        return out
    }
}
