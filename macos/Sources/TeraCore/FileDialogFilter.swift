// コモンダイアログのフィルタ (dlglib_cpp.cpp GetCommonDialogFilterWW)。
// FileSendFilter / FileReceiveFilter の "*.txt;*.log" のような Windows のワイルドカードを Mac のパネルで使う形にする
// 元のコード: Copyright (C) 2004- TeraTerm Project (BSD 3-Clause)

import Foundation

public struct FileDialogFilter: Equatable {
    /// 元の文字 ("*.txt;*.log")
    public let mask: String
    /// ";" で区切った各パターン
    public let patterns: [String]

    public init(_ mask: String) {
        self.mask = mask.trimmingCharacters(in: .whitespaces)
        patterns = self.mask.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// フィルタなし (空)
    public var isEmpty: Bool { patterns.isEmpty }

    /// "*" や "*.*" を含む (すべてのファイル)
    public var matchesEverything: Bool { patterns.contains { $0 == "*" || $0 == "*.*" } }

    /// FILEDLG_USER_FILTER_NAME: 「ユーザ定義(*.txt)」
    public var userFilterName: String { "ユーザ定義(\(mask))" }
    /// FILEDLG_ALL_FILTER
    public static let allFilterName = "すべてのファイル(*.*)"

    /// "*.ext" だけでできていれば、その拡張子 (NSSavePanel.allowedFileTypes 用)。それ以外の書き方を含むと nil
    public var allowedExtensions: [String]? {
        guard !isEmpty, !matchesEverything else { return nil }
        var r: [String] = []
        for p in patterns {
            guard p.hasPrefix("*."), p.count > 2 else { return nil }
            let ext = String(p.dropFirst(2))
            guard !ext.contains("*"), !ext.contains("?"), !ext.contains(".") else { return nil }
            if !r.contains(where: { $0.caseInsensitiveCompare(ext) == .orderedSame }) { r.append(ext) }
        }
        return r
    }

    /// ファイル名がどれかのパターンに合う (Windows と同じく大文字小文字は区別しない。"*.*" はドットのない名前にも合う)
    public func matches(_ fileName: String) -> Bool {
        if isEmpty || matchesEverything { return true }
        return patterns.contains { FileDialogFilter.wildcard($0, fileName) }
    }

    /// * と ? のワイルドカード
    public static func wildcard(_ pattern: String, _ name: String) -> Bool {
        let p = Array(pattern.lowercased()), s = Array(name.lowercased())
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) { pi += 1; si += 1 }
            else if pi < p.count && p[pi] == "*" { star = pi; mark = si; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; si = mark }
            else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        // "name.*" はドットのない "name" にも合う (Windows)
        if pi + 2 == p.count && p[pi] == "." && p[pi + 1] == "*" { return true }
        return pi == p.count
    }
}

/// ViewlogEditorArg などのコマンドラインを引数に分ける ("..." でくくった空白はそのまま)
public enum CommandLineSplit {
    public static func split(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false, has = false
        for c in s {
            if c == "\"" { quoted.toggle(); has = true; continue }
            if !quoted && (c == " " || c == "\t") {
                if has { out.append(cur); cur = ""; has = false }
                continue
            }
            cur.append(c); has = true
        }
        if has { out.append(cur) }
        return out
    }
}
